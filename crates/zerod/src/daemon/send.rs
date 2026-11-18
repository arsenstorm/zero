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
            return Err(format!("{} is open in Terminal; type there, or bring it back to Zero", conversation.provider.title()));
        }
        // Paused by the user: the message waits for their Resume, after what was held for it meanwhile.
        if self.is_paused(id) {
            return self.queue_as(id, message.text, message.images, message.sent).map(|_| ());
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
        // A local server changed since the task was given it starts again before the message (Codex's process stops
        // between turns, and the message starts it again).
        let busy_codex = session.summary().provider == Provider::Codex && session.summary().turn.is_some();
        if session.is_attached()
            && !busy_codex
            && self.mcp_stale(&session)
            && let Err(error) = self.push_mcp(id).await
        {
            eprintln!("zerod: couldn't give {id} its MCP servers again: {error}")
        }
        // The folder as it is before the agent reads the message: what rewinding to it brings back.
        let kept = self.keep_folder(&session).await;
        let conversation = session.snapshot();
        if !session.is_attached()
            && conversation.thread.is_none()
            && (conversation.items.is_empty() || conversation.provider == Provider::Opencode)
        {
            self.restart(&session, message, choice).await?;
        } else if session.is_attached() {
            session.send(message, choice).await?;
        } else {
            self.resume(id).await?;
            // Claude Code takes its message unanswered: one that dies as it starts (it couldn't read its folder) took it
            // to its grave. Under one id, so the message sent again is the same one in the conversation.
            let sent = message.sent.map_or_else(new_id, String::from);
            session.send(Message { sent: Some(&sent), ..message }, choice).await?;
            if session.summary().provider == Provider::Claude {
                self.again_if_unread(id, message.text, message.images, &sent);
            }
        }
        if let Some(commit) = kept {
            attach_snapshot(&session, commit)
        }
        Ok(())
    }

    /// A message whose freshly started process ended without a word goes to a new one, once; its failure is reported.
    fn again_if_unread(&self, id: &str, text: &str, images: &[String], sent: &str) {
        let (me, id, text, images, sent) = (self.me.clone(), id.to_string(), text.to_string(), images.to_vec(), sent.to_string());
        tokio::spawn(async move {
            let Some(session) = me.upgrade().and_then(|d| d.session(&id).ok()) else { return };
            if session.speaks(Duration::from_secs(60)).await {
                return;
            }
            let Some(daemon) = me.upgrade() else { return };
            let message = Message { text: &text, images: &images, context: None, sent: Some(&sent) };
            let again = match daemon.resume(&id).await {
                Ok(()) => session.send(message, ModelChoice::default()).await,
                Err(error) => Err(error),
            };
            if again.is_err() || !session.speaks(Duration::from_secs(60)).await {
                session.report("Claude Code ended as it started, before it read your message: send it again.");
            }
        });
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
        conversation.plain_answers = self.plain_answers(&conversation);
        session.prepare(&conversation);
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
        conversation.plain_answers = self.plain_answers(&conversation);
        session.prepare(&conversation);
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
            return Err(format!("{} is open in Terminal; bring it back to Zero first", conversation.provider.title()));
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
            return Err(format!("{} is open in Terminal; bring it back to Zero first", conversation.provider.title()));
        }
        self.take_offline(&session).await;
        session.change(Change::Permitted { permissions });
        Ok(())
    }

    /// Changes the model Claude Code consults (none: no advisor), between turns as permissions are: the next message
    /// resumes its thread with it.
    pub async fn set_advisor(&self, id: &str, advisor: Option<&str>) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        if busy_turn(&conversation) {
            let mut next = self.next(id).unwrap_or_default();
            next.advisor = (advisor != conversation.advisor.as_deref()).then(|| advisor.unwrap_or_default().to_string());
            self.keep_next(id, next);
            return Ok(());
        }
        if conversation.advisor.as_deref() == advisor {
            return Ok(());
        }
        if conversation.terminal.is_some() {
            return Err(format!("{} is open in Terminal; bring it back to Zero first", conversation.provider.title()));
        }
        self.take_offline(&session).await;
        session.change(Change::Advised { advisor: advisor.map(Into::into) });
        Ok(())
    }

    /// The compact window changed (Settings › Compact context at): Claude Code and Codex read it only as they start, so
    /// each agent started with another is stopped between turns, its next message resuming it with the new one, as
    /// for permissions. One mid-turn, with work still running in the background, or with messages queued (held: their
    /// release only delivers to a running agent), starts again as its next turn ends. OpenCode is given none (it keeps
    /// its own), so it runs on.
    pub async fn compact_window_changed(&self) {
        let window = crate::adapter::compact_window();
        for session in self.sessions() {
            let conversation = session.summary();
            if !session.is_attached() || conversation.provider == Provider::Opencode || conversation.terminal.is_some() {
                continue;
            }
            let stale = session.compact_window() != window;
            let queued = self.pending.lock().unwrap().get(&conversation.id).is_some_and(|list| !list.is_empty());
            if busy_turn(&conversation) || has_background(&session) || queued {
                let mut next = self.next(&conversation.id).unwrap_or_default();
                if next.restart != stale {
                    next.restart = stale;
                    self.keep_next(&conversation.id, next);
                }
            } else if stale {
                self.take_offline(&session).await;
            }
        }
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
        self.notify_from(id, "zero", text).map(|_| ())
    }

    /// Words from another task (`zero send` inside one), marked as its, as a worker's report is. An archived task
    /// comes back (with its lead, if it went with one) to hear them. Gives why they wait, if something holds them.
    pub fn notify_from(&self, id: &str, from: &str, text: &str) -> Result<Option<String>, String> {
        let unarchived = self.session(id).is_err() && self.exists(id);
        if unarchived {
            let root = archived_with(&self.home.join("archive").join(id)).unwrap_or_else(|| id.to_string());
            self.unarchive(&root)?;
        }
        let session = self.session(id)?;
        // Its lead's word lets it carry on with another task (the pair's hold lifted, counted afresh), and brings it
        // back past what it left when put away. The user's Stop holds it still: that's theirs to lift.
        if session.summary().parent.as_deref() == Some(from) {
            self.lift_crossing(id);
            if unarchived {
                self.hold(id, false);
            }
        }
        self.count_crossing(id, from);
        self.tell(id, crate::model::from_line(from, text));
        Ok(self.holding(&session.summary()).reason(Some(from)))
    }

    /// What holds `conversation`'s messages now, read at once: a queue is then sorted under its lock without asking the
    /// inbox or other sessions.
    pub(super) fn holding(&self, conversation: &Conversation) -> Holding {
        let id = conversation.id.as_str();
        let crossing: Vec<(String, bool)> = self
            .crossing
            .lock()
            .unwrap()
            .iter()
            .filter(|((to, _), _)| to == id)
            .map(|((_, from), ceiling)| (from.clone(), *ceiling))
            .collect();
        let everyone = if self.held_signed_out(conversation) {
            Some("is signed out: it hears this once its account works again")
        } else if self.blocked_by_ask(id) {
            Some("waits on the user's answer to its blocking ask")
        } else {
            None
        };
        Holding {
            paused: self.is_paused(id),
            stopped: self.held.lock().unwrap().contains(id),
            everyone,
            senders: crossing
                .into_iter()
                .filter(|(from, ceiling)| *ceiling || !self.waits_on_task(conversation, from))
                .map(|(from, ceiling)| (from.clone(), (self.summary(&from).map_or(from, |c| crate::bridge::label(&c)), ceiling)))
                .collect(),
        }
    }

    /// Whether `waiter`'s last answer ends `[zero: waiting on <task>]`, by `task`'s id or name.
    pub(super) fn waits_on_task(&self, waiter: &Conversation, task: &str) -> bool {
        let Some(on) = waiter.answer().and_then(crate::board::waits_on) else { return false };
        on == task || self.summary(task).is_some_and(|c| on.eq_ignore_ascii_case(&crate::bridge::label(&c)))
    }

    /// One more message between two tasks (neither the other's lead) without the user: past BETWEEN_TASKS, the
    /// receiver holds the sender's messages for the user's word, and says so. Past WAITING_CEILING for the task it
    /// waits on, whose words are what it waits for: its lead (the user, for a task of their own) is told once.
    fn count_crossing(&self, to: &str, from: &str) {
        let (Some(receiver), Some(sender)) = (self.summary(to), self.summary(from)) else { return };
        if receiver.parent.as_deref() == Some(from) || sender.parent.as_deref() == Some(to) {
            return;
        }
        let ceiling = self.waits_on_task(&receiver, from);
        let pair = if to < from { (to.to_string(), from.to_string()) } else { (from.to_string(), to.to_string()) };
        let count = {
            let mut crossed = self.crossed.lock().unwrap();
            let n = crossed.entry(pair).or_insert(0);
            *n += 1;
            *n
        };
        if count <= if ceiling { WAITING_CEILING } else { BETWEEN_TASKS } {
            return;
        }
        // Once each: held already (at the ceiling, or at the lower limit for a task it doesn't wait on), nothing new.
        {
            let mut crossing = self.crossing.lock().unwrap();
            let key = (to.to_string(), from.to_string());
            if crossing.get(&key).is_some_and(|held| *held || !ceiling) {
                return;
            }
            crossing.insert(key, ceiling);
        }
        let (name, other) = (crate::bridge::label(&sender), crate::bridge::label(&receiver));
        match (ceiling, receiver.parent.as_deref()) {
            (true, Some(lead)) => self.tell(
                lead,
                crate::model::from_line(
                    "zero",
                    &format!("Zero is holding messages from \"{name}\" to \"{other}\", which waits on it: the two wrote to each other {WAITING_CEILING} times. Write to {to} (`zero send {to} \"…\"`) to let them carry on."),
                ),
            ),
            (true, None) => {
                if let Ok(session) = self.session(to) {
                    session.report(&format!("Zero is holding messages from \"{name}\", which this task waits on: the two tasks have written to each other {WAITING_CEILING} times without you. Write to this task to let them carry on."))
                }
            }
            (false, _) => {
                if let Ok(session) = self.session(to) {
                    session.report(&format!("Zero is holding messages from \"{name}\": the two tasks have written to each other {BETWEEN_TASKS} times without you. Write to this task to let them carry on."))
                }
            }
        }
    }

    /// Holding another task's messages for the user's word (count_crossing).
    pub fn holding_crossed(&self, id: &str) -> bool {
        self.crossing.lock().unwrap().keys().any(|(to, _)| to == id)
    }

    /// Its exchanges with other tasks start counting again, and what they held goes.
    fn lift_crossing(&self, id: &str) {
        self.crossing.lock().unwrap().retain(|(to, _), _| to != id);
        self.crossed.lock().unwrap().retain(|(a, b), _| a != id && b != id);
    }

    /// The user wrote to a task: its exchanges with other tasks start counting again, and what was held goes.
    fn heard_from_user(&self, id: &str) {
        self.lift_crossing(id)
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
        self.pending.lock().unwrap().entry(id.into()).or_default().push(Queued {
            id: new_id(),
            text: words.clone(),
            images: vec![],
            report: true,
        });
        self.keep_pending(id);
        let Ok(session) = self.session(id) else { return };
        // Paused by the user: kept for their Resume, and shown in the conversation meanwhile, so they see what came.
        if self.is_paused(id) {
            let said = crate::model::from(&words).map_or(words.as_str(), |_| words.split_once('\n').map_or("", |(_, rest)| rest));
            let first = said.lines().find(|l| !l.trim().is_empty()).unwrap_or_default();
            let item = crate::model::Item {
                at: Some(crate::now_ms()),
                id: format!("held-{}", new_id()),
                turn: None,
                kind: ItemKind::Notice { text: format!("Held while paused: {first}"), error: false },
                status: crate::model::ItemStatus::Done,
            };
            session.change(Change::Item { item });
            return;
        }
        // At a limit no other account was free for when it stopped: if one is now, it carries on as that one, these
        // words with it.
        let conversation = session.summary();
        if !self.held_signed_out(&conversation)
            && conversation.attention() == Attention::Limited
            && self.switch_account(&conversation, None)
        {
            return;
        }
        self.wake(id);
    }

    /// What's queued for `id` goes on if any of it may (holds): given now between turns, or a parked task resumed for
    /// it. Gives whether it was resumed.
    pub(super) fn wake(&self, id: &str) -> bool {
        let Ok(session) = self.session(id) else { return false };
        let conversation = session.summary();
        if session.is_attached() || conversation.terminal.is_some() {
            if between_turns(&conversation) {
                self.deliver(id)
            }
            return false;
        }
        let holding = self.holding(&conversation);
        // Only others' words resume it: the user's own, queued for a parked task, wait for them to resume it.
        if !self.pending.lock().unwrap().get(id).is_some_and(|queue| queue.iter().any(|q| q.report && holding.may_go(q))) {
            return false;
        }
        let (Some(daemon), id) = (self.me.upgrade(), id.to_string()) else { return false };
        tokio::spawn(async move {
            if let Err(error) = daemon.resume(&id).await {
                eprintln!("zerod: couldn't resume {id} for its words: {error}")
            }
        });
        true
    }

    /// Once zerod is up: every parked task with words that may go, which nothing woke for them (a hold that went with
    /// the zerod before, a resume that failed), resumed for them. Gives the tasks resumed.
    pub fn deliver_stranded(&self) -> Vec<String> {
        let queued: Vec<String> = self.pending.lock().unwrap().iter().filter(|(_, l)| !l.is_empty()).map(|(id, _)| id.clone()).collect();
        queued.into_iter().filter(|id| !self.is_paused(id) && self.wake(id)).collect()
    }

    /// The next of what may go (Holding::may_go): a message of the user's on its own (one turn each, never joined to anything),
    /// or the reports before the user's next message together. The rest goes when that turn ends; what's held waits.
    pub(super) fn deliver(&self, id: &str) {
        if self.restarting.load(Ordering::Relaxed) || self.is_paused(id) {
            return;
        }
        let Ok(session) = self.session(id) else { return };
        if !session.is_attached() {
            return;
        }
        if !self.delivering.lock().unwrap().insert(id.into()) {
            return;
        }
        let holding = self.holding(&session.summary());
        let mut reporters: Vec<String> = vec![];
        let (text, images, sent) = {
            let mut pending = self.pending.lock().unwrap();
            let Some((list, first)) = pending.get_mut(id).and_then(|l| l.iter().position(|q| holding.may_go(q)).map(|at| (l, at))) else {
                self.delivering.lock().unwrap().remove(id);
                return;
            };
            if list[first].report {
                let end = list[first..].iter().position(|q| !q.report).map_or(list.len(), |n| first + n);
                let given: Vec<Queued> = list[first..end].iter().filter(|q| holding.may_go(q)).cloned().collect();
                list.retain(|q| !given.iter().any(|g| g.id == q.id));
                reporters =
                    given.iter().filter_map(|q| crate::model::from(&q.text)).filter(|who| *who != "zero").map(String::from).collect();
                (given.into_iter().map(|q| q.text).collect::<Vec<_>>().join("\n\n"), vec![], None)
            } else {
                // The user's words as they wrote them, kept so in the queue; what's open is told as they go.
                let next = list.remove(first);
                (self.noted(id, next.text), next.images, Some(next.id))
            }
        };
        self.keep_pending(id);
        let (me, id) = (self.me.clone(), id.to_string());
        tokio::spawn(async move {
            // The folder as the turn before left it, as a message sent at once has it: what rewinding to the user's
            // message brings back. Reports aren't the user's, and aren't gone back to.
            let kept = match me.upgrade().filter(|_| sent.is_some()) {
                Some(daemon) => daemon.keep_folder(&session).await,
                None => None,
            };
            // ponytail: word that fails to go through is dropped with a notice; keep it if sends start failing in practice.
            let message = Message { text: &text, images: &images, context: None, sent: sent.as_deref() };
            let sent = session.send(message, ModelChoice::default()).await;
            if let Err(error) = &sent {
                session.report(&format!("Couldn't pass on: {error}"))
            }
            if let (Ok(()), Some(commit)) = (&sent, kept) {
                attach_snapshot(&session, commit)
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
        // Parked ones too: what waited for them resumes them.
        for other in self.sessions().iter().map(|s| s.summary()) {
            if account(&other) == key {
                self.wake(&other.id);
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

    /// The user's Restart agent: its CLI's process stopped (a turn under way with it) and a fresh one started at once
    /// on the same conversation, for an agent that's stuck or to pick up a new MCP server, account or plugin.
    pub async fn restart_agent(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        if session.summary().terminal.is_some() {
            return Err("It's open in Terminal; restart it there, or bring it back to Zero".into());
        }
        self.take_offline(&session).await;
        self.resume(id).await
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

/// Work of its own still running between turns (Session::background), which stopping its process would end.
fn has_background(session: &Session) -> bool {
    session.background().is_some_and(|runs| !runs.is_empty())
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

    /// The turn ended: what was kept for the next one applied (the provider, the model and effort, the permissions, a
    /// restart),
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
        if let Some(advisor) = &next.advisor
            && let Err(error) = self.set_advisor(id, Some(advisor.as_str()).filter(|a| !a.is_empty())).await
        {
            session.report(&format!("Couldn't change its advisor: {error}"));
        }
        // A new compact window: started again for it, once nothing of its own runs in the background.
        // Not one started again since it was kept (Restart agent): that has the window already.
        if next.restart && session.compact_window() != crate::adapter::compact_window() {
            if has_background(&session) {
                self.keep_next(id, crate::model::Next { restart: true, ..Default::default() });
            } else {
                self.take_offline(&session).await;
            }
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

/// What holds a task's messages (Daemon::holding). The user's and its lead's words go, unless the user paused or
/// stopped it, it's signed out or blocked on its own ask.
pub(super) struct Holding {
    paused: bool,
    stopped: bool,
    /// Holds every task's words, and Zero's: only the user's go.
    everyone: Option<&'static str>,
    /// Tasks whose words wait for the user's (count_crossing), with their names, and whether past WAITING_CEILING.
    senders: HashMap<String, (String, bool)>,
}

impl Holding {
    /// Why words from `from` (a task's id, "zero"; none, the user's own) wait rather than go between its turns.
    pub(super) fn reason(&self, from: Option<&str>) -> Option<String> {
        if self.paused {
            return Some("is paused by the user: it hears this when they resume it".into());
        }
        if self.stopped {
            return Some("has its queue held since the user stopped it: it goes on when they write to it".into());
        }
        let from = from?;
        if let Some(why) = self.everyone {
            return Some(why.into());
        }
        self.senders.get(from).map(|(name, ceiling)| match ceiling {
            true => format!("holds messages from {name}, which it waits on: the two wrote to each other {WAITING_CEILING} times, until its lead or the user writes to it"),
            false => format!("holds messages from {name}: the two wrote to each other {BETWEEN_TASKS} times without the user, until the user writes to it"),
        })
    }

    pub(super) fn may_go(&self, queued: &Queued) -> bool {
        self.reason(queued.report.then(|| crate::model::from(&queued.text).unwrap_or("zero"))).is_none()
    }
}
