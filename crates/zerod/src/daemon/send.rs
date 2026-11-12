//! What's said to a task and when: sent now, queued for after its turn, told between turns; and its turn's
//! process resumed, interrupted, switched to another provider or stopped.

use super::*;

impl Daemon {
    /// A message of the user's for after the current turn: queued behind what's already waiting, one turn each.
    /// Between turns already, it goes now. Queueing releases a held queue: the user is back with it.
    pub fn queue(&self, id: &str, text: &str, images: &[String]) -> Result<Queued, String> {
        self.queue_as(id, text, images, None)
    }

    /// Queued under the app's own id for it (its copy in the strip until zerod's queue has it), or a new one: the
    /// message zerod sends on carries it.
    pub fn queue_as(&self, id: &str, text: &str, images: &[String], sent: Option<&str>) -> Result<Queued, String> {
        let session = self.session(id)?;
        if text.trim().is_empty() && images.is_empty() {
            return Err("A message needs words or an image".into());
        }
        self.heard_from_user(id);
        let item = sent.filter(|s| !s.is_empty()).map_or_else(new_id, String::from);
        let queued = Queued { id: item, text: text.into(), images: images.to_vec(), report: false };
        self.pending.lock().unwrap().entry(id.into()).or_default().push(queued.clone());
        self.hold(id, false);
        self.keep_pending(id);
        if between_turns(&session.summary()) {
            self.deliver(id)
        }
        Ok(queued)
    }

    /// Takes a queued message back.
    pub fn unqueue(&self, id: &str, item: &str) -> Result<Queued, String> {
        let taken = {
            let mut pending = self.pending.lock().unwrap();
            let list = pending.get_mut(id).ok_or("Nothing is queued")?;
            let index = list.iter().position(|q| q.id == item).ok_or("That message isn't queued any more")?;
            list.remove(index)
        };
        self.keep_pending(id);
        Ok(taken)
    }

    /// Lets a held queue go on.
    pub fn release(&self, id: &str) -> Result<(), String> {
        self.session(id)?;
        self.hold(id, false);
        self.heard_from_user(id);
        let _ = self.queues.send(());
        self.deliver(id);
        Ok(())
    }

    /// The user's messages waiting for `id`, in order (reports aren't theirs to see), and whether they're held.
    pub fn queued(&self, id: &str) -> (Vec<Queued>, bool) {
        let list = self.pending.lock().unwrap().get(id).map(|l| l.iter().filter(|q| !q.report).cloned().collect()).unwrap_or_default();
        (list, self.held.lock().unwrap().contains(id))
    }

    /// Every session's queue, for the board.
    pub fn queues(&self) -> HashMap<String, (Vec<Queued>, bool)> {
        let held = self.held.lock().unwrap();
        self.pending
            .lock()
            .unwrap()
            .iter()
            .map(|(id, list)| (id.clone(), (list.iter().filter(|q| !q.report).cloned().collect::<Vec<_>>(), held.contains(id))))
            .filter(|(_, (list, _))| !list.is_empty())
            .collect()
    }

    /// Stops the session's process, if it has one, and waits for it to be gone.
    pub(super) async fn take_offline(&self, session: &Session) {
        if !session.is_attached() {
            return;
        }
        session.stop();
        for _ in 0..100 {
            if session.summary().status == Status::Offline {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// The user's words to a session, with images (their files), resuming it first if it is offline.
    pub async fn send(&self, id: &str, message: Message<'_>, choice: ModelChoice<'_>) -> Result<(), String> {
        let session = self.session(id)?;
        self.heard_from_user(id);
        if let Some(conversation) = self.get(id)
            && conversation.terminal.is_some()
        {
            return Err(format!("{} is open in its terminal; type there, or go back to Zero", conversation.provider.title()));
        }
        // Writing to a paused task resumes it.
        if self.is_paused(id) {
            self.unpause(&[id.to_string()]).await;
        }
        // OpenCode takes one message at a time: one sent mid-turn waits for the turn's end, as Return does while it
        // works, rather than being refused (and lost from the box it was written in).
        if session.is_attached()
            && let Some(now) = self.get(id)
            && now.provider == Provider::Opencode
            && now.turn.is_some()
        {
            return self.queue_as(id, message.text, message.images, message.sent).map(|_| ());
        }
        // The folder as it is before the agent reads the message: what rewinding to it brings back.
        let kept = self.keep_folder(&session).await;
        let conversation = session.snapshot();
        if !session.is_attached()
            && conversation.thread.is_none()
            && (conversation.items.is_empty() || conversation.provider == Provider::Opencode)
        {
            self.restart(&session, message, choice).await?;
        } else {
            if !session.is_attached() {
                self.resume(id).await?
            }
            session.send(message, choice).await?;
        }
        if let Some(commit) = kept {
            attach_snapshot(&session, commit)
        }
        Ok(())
    }

    /// The task's folder kept as it is now (snapshots.rs), off the async threads: git reads the whole folder.
    async fn keep_folder(&self, session: &Session) -> Option<String> {
        let (cwd, name) = (session.summary().cwd, format!("{}/{}", session.id(), now_ms()));
        tokio::task::spawn_blocking(move || crate::snapshots::take(Path::new(&cwd), &name)).await.ok().flatten()
    }

    /// A new thread for a conversation that has none: rewound to its first message, or (OpenCode, which can't be
    /// handed a conversation) rewound anywhere, the earlier conversation then going with the message as context.
    async fn restart(&self, session: &Session, message: Message<'_>, choice: ModelChoice<'_>) -> Result<(), String> {
        let mut conversation = session.snapshot();
        let context =
            (conversation.provider == Provider::Opencode && !conversation.items.is_empty()).then(|| crate::handoff::context(&conversation));
        if conversation.provider == Provider::Claude {
            let thread = claude::new_session_id();
            session.change(Change::Thread { thread: thread.clone(), model: None, effort: None });
            conversation.thread = Some(thread);
        }
        let (model, effort) = (
            choice.model.or(conversation.model.as_deref()).map(String::from),
            choice.effort.or(conversation.effort.as_deref()).map(String::from),
        );
        conversation.mcp = self.mcp_for(&conversation)?;
        session.set_mcp(conversation.mcp.clone());
        let argv = conversation.provider.command(&conversation, false, model.as_deref(), effort.as_deref());
        let transport = (self.runtime)(&conversation, &self.home.join("sessions").join(&conversation.id), &argv)
            .map_err(|e| format!("{} didn't start: {e}", conversation.provider.title()))?;
        session
            .start(
                transport,
                Message { context: context.as_deref(), ..message },
                ModelChoice { model: model.as_deref(), effort: effort.as_deref() },
            )
            .await
    }

    /// One at a time per session: a second resume (the app warming it as the user types, their message arriving)
    /// waits for the first and finds its agent running, rather than starting another.
    pub async fn resume(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        let lock = self.resuming.lock().unwrap().entry(id.to_string()).or_default().clone();
        let _one = lock.lock().await;
        if session.is_attached() {
            return Ok(());
        }
        let mut conversation = session.snapshot();
        // Its workspace's servers as they are now: one moved since, or a server added, applies from this start.
        conversation.mcp = self.mcp_for(&conversation)?;
        session.set_mcp(conversation.mcp.clone());
        let argv = conversation.provider.command(&conversation, true, conversation.model.as_deref(), conversation.effort.as_deref());
        let transport = (self.runtime)(&conversation, &self.home.join("sessions").join(id), &argv)
            .map_err(|e| format!("{} didn't start: {e}", conversation.provider.title()))?;
        let resumed = session.resume(transport).await;
        // A process that didn't get the thread lets go of it; it would otherwise hold it from whoever does.
        if resumed.is_err() {
            self.take_offline(&session).await
        }
        resumed
    }

    /// Moves a task to another provider between turns. Its conversation stays Zero's; the next message starts the new
    /// provider on it (handoff.rs): Claude Code resumes it as one of its own session files, Codex imports that file.
    pub async fn switch(&self, id: &str, provider: Provider, choice: ModelChoice<'_>) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        // Mid-turn: kept for the next turn (what it has already, dropped from it), applied as this one ends.
        if busy_turn(&conversation) {
            let mut next = self.next(id).unwrap_or_default();
            next.provider = (provider != conversation.provider).then_some(provider);
            if let Some(model) = choice.model {
                next.model = (Some(model) != conversation.model.as_deref() || next.provider.is_some()).then(|| model.to_string())
            }
            if let Some(effort) = choice.effort {
                next.effort = (Some(effort) != conversation.effort.as_deref() || next.provider.is_some()).then(|| effort.to_string())
            }
            self.keep_next(id, next);
            return Ok(());
        }
        if provider == conversation.provider {
            return session.set_model(choice).await;
        }
        if provider == Provider::Opencode {
            return Err(format!("Zero can't hand a task to {} yet", provider.title()));
        }
        if matches!(conversation.status, Status::Working | Status::Waiting) {
            return Err(format!("{} is working; stop its turn first", conversation.provider.title()));
        }
        if conversation.terminal.is_some() {
            return Err(format!("{} is open in its terminal; go back to Zero first", conversation.provider.title()));
        }
        self.take_offline(&session).await;
        session.change(Change::Switched { provider, model: choice.model.map(Into::into), effort: choice.effort.map(Into::into) });
        self.rethread(&session)
    }

    /// Changes what the task's agent may do without asking, between turns: its process is stopped, and the next message
    /// resumes its thread started with the new permissions.
    pub async fn set_permissions(&self, id: &str, permissions: crate::model::Permissions) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        // Mid-turn: kept for the next turn, applied as this one ends (the agent starts again with them then).
        if busy_turn(&conversation) {
            let mut next = self.next(id).unwrap_or_default();
            next.permissions = (permissions != conversation.permissions).then_some(permissions);
            self.keep_next(id, next);
            return Ok(());
        }
        if conversation.permissions == permissions {
            return Ok(());
        }
        if conversation.terminal.is_some() {
            return Err(format!("{} is open in its terminal; go back to Zero first", conversation.provider.title()));
        }
        self.take_offline(&session).await;
        session.change(Change::Permitted { permissions });
        Ok(())
    }

    /// The provider given a thread made from Zero's record (handoff.rs): Claude Code a session file of its own; Codex,
    /// with no thread, imports the record when it next resumes; OpenCode, with none, starts afresh with it as context.
    pub(super) fn rethread(&self, session: &Session) -> Result<(), String> {
        let conversation = session.snapshot();
        if conversation.provider != Provider::Claude || conversation.items.is_empty() {
            return Ok(());
        }
        let thread = claude::new_session_id();
        let folder = crate::handoff::claude_folder(&self.user_home(), &conversation.cwd);
        std::fs::create_dir_all(&folder)
            .and_then(|_| std::fs::write(folder.join(format!("{thread}.jsonl")), crate::handoff::claude_session(&conversation, &thread)))
            .map_err(|e| format!("Couldn't write the conversation for Claude Code: {e}"))?;
        session.change(Change::Thread { thread, model: None, effort: None });
        Ok(())
    }

    /// Stops the turn. What's queued for the session is held: the user stopped it, so nothing of theirs goes on
    /// until they say (queueing again, or releasing).
    pub async fn interrupt(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        if !self.queued(id).0.is_empty() {
            self.hold(id, true);
            let _ = self.queues.send(());
        }
        let before = session.snapshot();
        let stopped = session.interrupt().await;
        // Reading busy with no turn behind it: nothing the provider could stop, so the task is set right, not refused.
        if before.turn.is_none() && busy_turn(&before) {
            session.change(Change::Status { status: Status::Idle, turn: None, error: before.error.clone() });
            return Ok(());
        }
        stopped
    }

    pub async fn decide(&self, id: &str, approval: &str, choice: &str) -> Result<(), String> {
        self.session(id)?.decide(approval, choice).await
    }

    pub async fn answer(&self, id: &str, question: &str, answers: &crate::adapter::Answers) -> Result<(), String> {
        self.session(id)?.answer(question, answers).await
    }

    /// Words for a session from anywhere (an event source, a script, the user): given when it is between turns, kept
    /// on disk while it is offline.
    pub fn notify(&self, id: &str, text: &str) -> Result<(), String> {
        self.notify_from(id, "zero", text)
    }

    /// Words from another task (`zero send` inside one), marked as its, as a worker's report is. An archived task
    /// comes back (with its lead, if it went with one) to hear them.
    pub fn notify_from(&self, id: &str, from: &str, text: &str) -> Result<(), String> {
        if self.session(id).is_err() && self.exists(id) {
            let root = archived_with(&self.home.join("archive").join(id)).unwrap_or_else(|| id.to_string());
            self.unarchive(&root)?;
        }
        self.session(id)?;
        self.count_crossing(id, from);
        self.tell(id, crate::model::from_line(from, text));
        Ok(())
    }

    /// One more message between two tasks (neither the other's lead) without the user: past BETWEEN_TASKS, the
    /// receiver's messages from other tasks wait for the user's word, and it says so.
    fn count_crossing(&self, to: &str, from: &str) {
        let (Some(receiver), Some(sender)) = (self.get(to), self.get(from)) else { return };
        if receiver.parent.as_deref() == Some(from) || sender.parent.as_deref() == Some(to) {
            return;
        }
        let pair = if to < from { (to.to_string(), from.to_string()) } else { (from.to_string(), to.to_string()) };
        let count = {
            let mut crossed = self.crossed.lock().unwrap();
            let n = crossed.entry(pair).or_insert(0);
            *n += 1;
            *n
        };
        if count > BETWEEN_TASKS
            && self.crossing.lock().unwrap().insert(to.to_string())
            && let Ok(session) = self.session(to)
        {
            session.report(&format!("Zero is holding messages from \"{}\": the two tasks have written to each other {BETWEEN_TASKS} times without you. Write to this task to let them carry on.", crate::bridge::label(&sender)));
        }
    }

    /// Holding messages from other tasks for the user's word (count_crossing).
    pub fn holding_crossed(&self, id: &str) -> bool {
        self.crossing.lock().unwrap().contains(id)
    }

    /// The user wrote to a task: its exchanges with other tasks start counting again, and what was held goes.
    fn heard_from_user(&self, id: &str) {
        self.crossing.lock().unwrap().remove(id);
        self.crossed.lock().unwrap().retain(|(a, b), _| a != id && b != id);
    }

    /// Stops a task's running command (the user's Stop it, or Zero's own per Settings › Stuck commands) and tells its
    /// agent why: mid-turn at once, as the user's steering goes (Codex steers, Claude reads it after the failed call),
    /// else between turns.
    pub fn stop_command(&self, id: &str, item: &str) -> Result<(), String> {
        let session = self.session(id)?;
        let (command, note) = session.stop_command(item)?;
        let note = note.unwrap_or_else(|| {
            format!(
                "The user stopped `{}` from Zero. Try another way, and run long commands in the background.",
                crate::stuck::key(&command)
            )
        });
        let words = crate::model::from_line("zero", &note);
        let summary = session.summary();
        if summary.status == Status::Working && summary.provider != Provider::Opencode {
            tokio::spawn(async move {
                let message = Message { text: &words, images: &[], context: None, sent: None };
                if let Err(error) = session.send(message, ModelChoice::default()).await {
                    session.report(&format!("Couldn't tell it why: {error}"))
                }
            });
        } else {
            self.tell(id, words)
        }
        Ok(())
    }

    /// Zero's word for a session, between its turns (a parked one resumed for it), shown as Zero's, not the user's.
    pub fn tell_from_zero(&self, id: &str, words: &str) {
        if self.session(id).is_ok() {
            self.tell(id, crate::model::from_line("zero", words))
        }
    }

    /// Keeps `words` for `id` until it can take them; a parked (offline) session is resumed for them, and they go
    /// once it's between turns.
    pub(super) fn tell(&self, id: &str, words: String) {
        self.pending.lock().unwrap().entry(id.into()).or_default().push(Queued { id: new_id(), text: words, images: vec![], report: true });
        self.keep_pending(id);
        if self.is_paused(id) {
            return;
        }
        let Ok(session) = self.session(id) else { return };
        if self.held_signed_out(&session.summary()) {
            return;
        }
        if !session.is_attached() && session.summary().terminal.is_none() {
            let (Some(daemon), id) = (self.me.upgrade(), id.to_string()) else { return };
            tokio::spawn(async move {
                if let Err(error) = daemon.resume(&id).await {
                    eprintln!("zerod: couldn't resume {id} for its words: {error}")
                }
            });
        } else if between_turns(&session.summary()) {
            self.deliver(id)
        }
    }

    /// The next of what waits: a message of the user's on its own (one turn each, never joined to anything), or the
    /// reports at the head of the queue together. The rest goes when that turn ends. A held queue waits.
    pub(super) fn deliver(&self, id: &str) {
        if self.restarting.load(Ordering::Relaxed) || self.is_paused(id) {
            return;
        }
        if self.held.lock().unwrap().contains(id) {
            return;
        }
        let Ok(session) = self.session(id) else { return };
        if !session.is_attached() {
            return;
        }
        if !self.delivering.lock().unwrap().insert(id.into()) {
            return;
        }
        let mut reporters: Vec<String> = vec![];
        let (text, images, sent) = {
            let mut pending = self.pending.lock().unwrap();
            let Some(list) = pending.get_mut(id).filter(|l| !l.is_empty()) else {
                self.delivering.lock().unwrap().remove(id);
                return;
            };
            // Signed out, or holding other tasks' messages for the user: only the user's words go.
            if self.held_signed_out(&session.summary()) || self.holding_crossed(id) || self.blocked_by_ask(id) {
                let Some(at) = list.iter().position(|q| !q.report) else {
                    self.delivering.lock().unwrap().remove(id);
                    return;
                };
                let next = list.remove(at);
                (self.noted(id, next.text), next.images, Some(next.id))
            } else if list[0].report {
                let reports = list.iter().take_while(|q| q.report).count();
                let given: Vec<Queued> = list.drain(..reports).collect();
                reporters =
                    given.iter().filter_map(|q| crate::model::from(&q.text)).filter(|who| *who != "zero").map(String::from).collect();
                (given.into_iter().map(|q| q.text).collect::<Vec<_>>().join("\n\n"), vec![], None)
            } else {
                // The user's words as they wrote them, kept so in the queue; what's open is told as they go.
                let next = list.remove(0);
                (self.noted(id, next.text), next.images, Some(next.id))
            }
        };
        self.keep_pending(id);
        let (me, id) = (self.me.clone(), id.to_string());
        tokio::spawn(async move {
            // ponytail: word that fails to go through is dropped with a notice; keep it if sends start failing in practice.
            let message = Message { text: &text, images: &images, context: None, sent: sent.as_deref() };
            let sent = session.send(message, ModelChoice::default()).await;
            if let Err(error) = &sent {
                session.report(&format!("Couldn't pass on: {error}"))
            }
            let Some(daemon) = me.upgrade() else { return };
            daemon.delivering.lock().unwrap().remove(&id);
            // Its lead has the report of a worker that ended done: the worker leaves the tree, kept in the archive.
            if sent.is_ok() {
                for worker in reporters {
                    let done = daemon.get(&worker).is_some_and(|w| w.attention() == crate::model::Attention::Done);
                    if daemon.leaving.lock().unwrap().remove(&worker)
                        && done
                        && let Err(error) = daemon.archive(&worker).await
                    {
                        eprintln!("zerod: couldn't put away done worker {worker}: {error}");
                    }
                }
            }
        });
    }

    /// Signed out, it or another task on its account: a turn of Zero's (an event, a watch, a schedule, a report) would
    /// fail the same way, so only the user's words go (signed in again, say) until a turn works.
    pub(super) fn held_signed_out(&self, conversation: &Conversation) -> bool {
        signed_out(conversation) || self.signed_out.lock().unwrap().contains(&account(conversation))
    }

    /// An account found signed out, or working again: what was held for its tasks goes.
    pub(super) fn sign_in_heard(&self, conversation: &Conversation, turn_worked: bool) {
        let key = account(conversation);
        if signed_out(conversation) {
            self.signed_out.lock().unwrap().insert(key);
            return;
        }
        if !turn_worked || !self.signed_out.lock().unwrap().remove(&key) {
            return;
        }
        for other in self.sessions().iter().map(|s| s.summary()) {
            if account(&other) == key && between_turns(&other) {
                self.deliver(&other.id)
            }
        }
    }

    /// Holds a session's queue for the user, or lets it go; kept in its folder, so zerod started again still holds it.
    pub(super) fn hold(&self, id: &str, on: bool) {
        let marker = self.home.join("sessions").join(id).join(HELD);
        if on {
            self.held.lock().unwrap().insert(id.into());
            let _ = std::fs::write(marker, b"");
        } else if self.held.lock().unwrap().remove(id) {
            let _ = std::fs::remove_file(marker);
        }
    }

    pub(super) fn keep_pending(&self, id: &str) {
        let words = self.pending.lock().unwrap().get(id).cloned().unwrap_or_default();
        let file = self.home.join("sessions").join(id).join("pending.json");
        let _ = if words.is_empty() {
            std::fs::remove_file(file)
        } else {
            std::fs::write(file, serde_json::to_vec(&words).unwrap_or_default())
        };
        let _ = self.queues.send(());
    }

    pub fn stop(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        if session.summary().status == Status::Offline {
            return Err(format!("{id} isn't running"));
        }
        session.stop();
        Ok(())
    }
}

/// A session's queue as kept in its folder. Before queues, pending.json held plain words: reports.
pub(super) fn kept_pending(dir: &Path) -> Vec<Queued> {
    let Ok(data) = std::fs::read(dir.join("pending.json")) else { return vec![] };
    serde_json::from_slice(&data).unwrap_or_else(|_| {
        serde_json::from_slice::<Vec<String>>(&data)
            .unwrap_or_default()
            .into_iter()
            .map(|text| Queued { id: new_id(), text, images: vec![], report: true })
            .collect()
    })
}

/// A turn under way: a change of model or permissions waits for it to end.
fn busy_turn(conversation: &Conversation) -> bool {
    matches!(conversation.status, Status::Working | Status::Waiting | Status::Starting)
}

impl Daemon {
    /// What's kept for a task's next turn (switch, set_permissions mid-turn); none when nothing is.
    pub fn next(&self, id: &str) -> Option<crate::model::Next> {
        std::fs::read(self.home.join("sessions").join(id).join(NEXT)).ok().and_then(|data| serde_json::from_slice(&data).ok())
    }

    fn keep_next(&self, id: &str, next: crate::model::Next) {
        let file = self.home.join("sessions").join(id).join(NEXT);
        let _ =
            if next.is_empty() { std::fs::remove_file(file) } else { std::fs::write(file, serde_json::to_vec(&next).unwrap_or_default()) };
        let _ = self.queues.send(()); // the board, at once
    }

    /// The turn ended: what was kept for the next one applied (the provider, the model and effort, the permissions),
    /// then what's queued goes, on it.
    pub(super) async fn apply_next(&self, id: &str) {
        let Some(next) = self.next(id) else { return };
        self.keep_next(id, crate::model::Next::default());
        let Ok(session) = self.session(id) else { return };
        // Permissions first: the agent starts again with them, so the model is then only kept for that start, not
        // asked of an agent about to stop.
        if let Some(permissions) = next.permissions
            && let Err(error) = self.set_permissions(id, permissions).await
        {
            session.report(&format!("Couldn't change its permissions: {error}"));
        }
        let provider = next.provider.unwrap_or(session.summary().provider);
        if next.provider.is_some() || next.model.is_some() || next.effort.is_some() {
            let choice = ModelChoice { model: next.model.as_deref(), effort: next.effort.as_deref() };
            if let Err(error) = self.switch(id, provider, choice).await {
                session.report(&format!("Couldn't change its model: {error}"))
            }
        }
    }
}

/// A task's change kept for its next turn, in its folder.
const NEXT: &str = "next.json";
