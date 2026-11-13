//! Pausing turns: for zerod's restart (paused between steps, carried on by the new zerod) and by the user.

use super::*;

impl Daemon {
    /// Before zerod becomes a new build: every session's running process is handed over (Session::hand_off), kept in
    /// handoff.json for the new zerod to take over, so turns, background commands and subagents run on through the
    /// restart. Gives the sessions handed over; what couldn't be is paused (pause_for_restart).
    pub async fn hand_off(&self) -> Vec<String> {
        self.restarting.store(true, Ordering::Relaxed);
        let mut handed = vec![];
        for session in self.sessions() {
            if let Some(handoff) = session.hand_off().await {
                handed.push(handoff)
            }
        }
        let _ = std::fs::write(self.home.join(HANDOFF), serde_json::to_vec(&handed).unwrap_or_default());
        handed.into_iter().map(|h| h.session).collect()
    }

    /// Once zerod is up after a restart: the processes the zerod before handed over, each attached to its session as it
    /// was. Gives the sessions taken over; a process that can't be is stopped, and its task resumed and told to carry
    /// on, as a restart that pauses tells it.
    pub fn take_over(&self) -> Vec<String> {
        let file = self.home.join(HANDOFF);
        let handed: Vec<crate::session::Handoff> =
            std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        let _ = std::fs::remove_file(&file);
        let mut taken = vec![];
        for handoff in handed {
            let (id, pid) = (handoff.session.clone(), handoff.pid);
            let Ok(session) = self.session(&id) else {
                stop_group(pid);
                continue;
            };
            // Handed to another zerod than this one (the app started one mid-restart, and it won the lock): the
            // numbers are no descriptors of ours, or someone else's, and closing them would cut another agent's pipe.
            if handoff.zerod.is_some_and(|zerod| zerod != std::process::id()) {
                stop_group(pid);
                self.tell(&id, CARRY_ON.into());
                continue;
            }
            if let Ok(conversation) = self.get(&id).ok_or(())
                && let Ok(servers) = self.mcp_for(&conversation)
            {
                session.set_mcp(servers)
            }
            match session.adopt(handoff) {
                Ok(()) => taken.push(id),
                Err(error) => {
                    eprintln!("zerod: couldn't take over {id}'s process: {error}");
                    stop_group(pid);
                    self.tell(&id, CARRY_ON.into());
                }
            }
        }
        taken
    }

    /// Before zerod becomes a new build: every turn under way is paused between steps (a command running is left to
    /// finish, up to COMMAND_WAIT), its session told to carry on once the new zerod is up. All at once, so one long
    /// command holds up only its own turn. Gives the sessions paused.
    pub async fn pause_for_restart(&self) -> Vec<String> {
        self.restarting.store(true, Ordering::Relaxed);
        let mut pausing = tokio::task::JoinSet::new();
        for session in self.sessions() {
            let conversation = session.summary();
            // Only a turn with a process behind it: an offline session's last status may still say it was working. Or
            // one between turns with a run still going in the background (to wake it when done): the restart ends its
            // process and the run with it.
            let under_way =
                matches!(conversation.status, Status::Working | Status::Waiting | Status::Starting) || session.running_command();
            if !session.is_attached() || !under_way {
                continue;
            }
            // Told after, as what the restart cut short: a turn, a question to the user, or a run in the background.
            let words = match conversation.status {
                Status::Waiting => CARRY_ON_WAITING,
                Status::Working | Status::Starting => CARRY_ON,
                _ => CARRY_ON_BACKGROUND,
            };
            let me = self.me.clone();
            pausing.spawn(async move {
                let deadline = tokio::time::Instant::now() + COMMAND_WAIT;
                // What it's waiting for, for the app to show while it waits.
                let (recent, _) = session.recent(50);
                let running = recent.items.iter().rev().find_map(|i| match (&i.kind, i.status) {
                    (ItemKind::Command { command, .. }, crate::model::ItemStatus::Running) => Some(command.clone()),
                    _ => None,
                });
                if let (Some(command), Some(daemon)) = (running, me.upgrade()) {
                    daemon.held_up.lock().unwrap().insert(conversation.id.clone(), command);
                }
                // A session closed or gone offline meanwhile has no command to wait for, whatever its last item says.
                while session.is_attached()
                    && (session.running_command() || session.summary().status == Status::Starting)
                    && tokio::time::Instant::now() < deadline
                {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
                session.pause_for_update();
                if session.is_attached() {
                    let _ = tokio::time::timeout(Duration::from_secs(5), session.interrupt()).await;
                }
                // The agent's own note of the stop says it's paused for the update; a moment for it, else Zero's.
                let noted = || {
                    session.recent(5).0.items.iter().any(|i| matches!(&i.kind, ItemKind::Notice { text, .. } if text == PAUSED_FOR_UPDATE))
                };
                for _ in 0..10 {
                    if noted() {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await
                }
                if !noted() {
                    note_pause(&session, PAUSED_FOR_UPDATE)
                }
                if let Some(daemon) = me.upgrade() {
                    daemon.held_up.lock().unwrap().remove(&conversation.id);
                    daemon.updating.lock().unwrap().insert(conversation.id.clone());
                    let _ = daemon.queues.send(());
                }
                (conversation.id, words)
            });
        }
        let mut paused = vec![];
        let mut told = vec![];
        while let Some(done) = pausing.join_next().await {
            if let Ok((id, words)) = done {
                paused.push(id.clone());
                told.push((id, words))
            }
        }
        for (id, words) in &told {
            // Once, however many restarts paused it before it carried on.
            let mut pending = self.pending.lock().unwrap();
            let list = pending.entry(id.clone()).or_default();
            if list.iter().any(|q| CARRIES.contains(&q.text.as_str())) {
                continue;
            }
            list.push(Queued { id: new_id(), text: (*words).into(), images: vec![], report: true });
            drop(pending);
            self.keep_pending(id);
        }
        // Which turns to carry on: these, and only these (words waiting for a parked task wait for you to resume it).
        let _ = std::fs::write(self.home.join("paused.json"), serde_json::to_vec(&paused).unwrap_or_default());
        paused
    }

    /// Once zerod is up after a restart: the turns it paused resume, and are told to carry on as soon as they're between
    /// turns. Nothing else is resumed. Gives the sessions resumed.
    pub fn carry_on(&self) -> Vec<String> {
        let file = self.home.join("paused.json");
        let paused: Vec<String> = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        let _ = std::fs::remove_file(&file);
        let mut resumed = vec![];
        for id in paused {
            let Ok(session) = self.session(&id) else { continue };
            if session.is_attached() || session.summary().terminal.is_some() || self.is_paused(&id) {
                continue;
            }
            // The turn was paused for the update and carried on, not stopped: said in the conversation, in place of the
            // pause's "Interrupted" when that was noted, on a line of its own when it wasn't (the old zerod may have
            // gone before the interrupt's result was recorded).
            note_pause(&session, CARRIED);
            let Some(daemon) = self.me.upgrade() else { break };
            resumed.push(id.clone());
            tokio::spawn(async move {
                if let Err(error) = daemon.resume(&id).await {
                    eprintln!("zerod: couldn't resume {id} to carry on: {error}")
                }
            });
        }
        resumed
    }

    /// Whether a restart is under way, and the turns it's waiting on: each one's task and the command it lets finish
    /// (at most COMMAND_WAIT), for the app to say what Zero is waiting for.
    pub fn restart_status(&self) -> serde_json::Value {
        let waiting: Vec<serde_json::Value> = self
            .held_up
            .lock()
            .unwrap()
            .iter()
            .map(|(id, command)| {
                let task = self
                    .session(id)
                    .map(|s| {
                        let c = s.summary();
                        c.label.or(c.title).unwrap_or_default()
                    })
                    .unwrap_or_default();
                serde_json::json!({"session": id, "task": task, "command": command})
            })
            .collect();
        serde_json::json!({"restarting": self.restarting.load(Ordering::Relaxed), "waiting": waiting, "most": COMMAND_WAIT.as_secs()})
    }

    /// Paused by a restart, until the new zerod carries it on: Zero's own, so the board doesn't call it paused.
    pub fn is_paused_for_update(&self, id: &str) -> bool {
        self.updating.lock().unwrap().contains(id)
    }

    pub fn is_paused(&self, id: &str) -> bool {
        self.paused.lock().unwrap().contains(id)
    }

    /// How many events (follows, reports, watches, other tasks' words) wait for a paused task's Resume: the user's
    /// own words and Zero's carry-on for the pause left out.
    pub fn held_while_paused(&self, id: &str) -> usize {
        if !self.is_paused(id) {
            return 0;
        }
        let resumed = crate::model::from_line("zero", RESUMED);
        self.pending.lock().unwrap().get(id).map_or(0, |list| list.iter().filter(|q| q.report && q.text != resumed).count())
    }

    /// Puts `ids` and their workers (every lead's, `ids` empty) on hold: each working one is asked to wrap up, given
    /// `wait` to end its turn, then stopped (a running command left to finish first, as for a restart); then parked.
    /// Words for them wait until they're resumed. Gives the sessions paused.
    pub async fn pause(&self, ids: &[String], wait: Duration) -> Vec<String> {
        let targets =
            if ids.is_empty() { self.list().into_iter().filter(|c| c.parent.is_none()).map(|c| c.id).collect() } else { ids.to_vec() };
        let targets = self.with_workers(targets);
        // Marked first: the turns ending now are the pause, not word for a lead or a reason to deliver.
        self.paused.lock().unwrap().extend(targets.iter().cloned());
        self.keep_paused();
        let mut pausing = tokio::task::JoinSet::new();
        for id in &targets {
            let Ok(session) = self.session(id) else { continue };
            let Some(daemon) = self.me.upgrade() else { break };
            let id = id.clone();
            pausing.spawn(async move {
                if session.is_attached() && busy(session.summary().attention()) {
                    // Told to carry on when resumed, since its turn is cut short.
                    daemon.pending.lock().unwrap().entry(id.clone()).or_default().push(Queued {
                        id: new_id(),
                        text: crate::model::from_line("zero", RESUMED),
                        images: vec![],
                        report: true,
                    });
                    daemon.keep_pending(&id);
                    // Steered where the provider allows it; where it doesn't (OpenCode), the wait runs out and it's stopped.
                    let _ = session.send(Message::text(&crate::model::from_line("zero", WRAP_UP)), ModelChoice::default()).await;
                    let deadline = tokio::time::Instant::now() + wait;
                    while session.is_attached() && busy(session.summary().attention()) && tokio::time::Instant::now() < deadline {
                        tokio::time::sleep(Duration::from_millis(250)).await;
                    }
                    let deadline = tokio::time::Instant::now() + COMMAND_WAIT;
                    while session.is_attached() && session.running_command() && tokio::time::Instant::now() < deadline {
                        tokio::time::sleep(Duration::from_millis(250)).await;
                    }
                    if session.is_attached() && busy(session.summary().attention()) {
                        let _ = tokio::time::timeout(Duration::from_secs(5), session.interrupt()).await;
                    }
                }
                daemon.take_offline(&session).await;
            });
        }
        while pausing.join_next().await.is_some() {}
        let _ = self.queues.send(()); // the board shows it paused, though nothing of the session's changed
        targets
    }

    pub fn is_saved(&self, id: &str) -> bool {
        self.saved.lock().unwrap().contains(id)
    }

    /// Saves a task for later, whole: off the board and on hold (paused, with its workers), not archived. Marked at
    /// once; its turns wrap up behind, as a pause's do.
    pub fn save_for_later(&self, id: &str) -> Result<(), String> {
        self.session(id)?;
        self.saved.lock().unwrap().insert(id.into());
        self.keep_saved();
        self.paused.lock().unwrap().extend(self.with_workers(vec![id.into()]));
        self.keep_paused();
        let _ = self.queues.send(());
        if let Some(daemon) = self.me.upgrade() {
            let id = id.to_string();
            tokio::spawn(async move { daemon.pause(&[id], Duration::from_secs(5 * 60)).await });
        }
        Ok(())
    }

    /// A task saved for later back on the board, off hold.
    pub async fn bring_back(&self, id: &str) -> Vec<String> {
        self.saved.lock().unwrap().remove(id);
        self.keep_saved();
        self.unpause(&[id.to_string()]).await
    }

    fn keep_saved(&self) {
        let saved: Vec<String> = self.saved.lock().unwrap().iter().cloned().collect();
        let _ = std::fs::write(self.home.join(SAVED), serde_json::to_vec(&saved).unwrap_or_default());
    }

    /// Takes `ids` (every paused session, `ids` empty) off hold. Those with words waiting are resumed for them; the
    /// rest stay parked until they're written to, as any finished task. Gives the sessions taken off hold.
    pub async fn unpause(&self, ids: &[String]) -> Vec<String> {
        let ids = if ids.is_empty() { self.paused.lock().unwrap().iter().cloned().collect() } else { self.with_workers(ids.to_vec()) };
        let resumed: Vec<String> = {
            let mut paused = self.paused.lock().unwrap();
            ids.into_iter().filter(|id| paused.remove(id)).collect()
        };
        self.keep_paused();
        // What was held for them goes first, in one wake, then the user's own words (deliver joins the reports at the
        // queue's head).
        for id in &resumed {
            if let Some(list) = self.pending.lock().unwrap().get_mut(id) {
                list.sort_by_key(|q| !q.report)
            }
            self.keep_pending(id);
        }
        let waiting = self.pending.lock().unwrap().clone();
        for id in &resumed {
            if !waiting.get(id).is_some_and(|words| !words.is_empty()) {
                continue;
            }
            if let Err(error) = self.resume(id).await {
                eprintln!("zerod: couldn't resume {id} after its pause: {error}")
            }
        }
        let _ = self.queues.send(());
        resumed
    }

    /// `ids` and their workers, theirs too, through every level.
    fn with_workers(&self, mut ids: Vec<String>) -> Vec<String> {
        let all = self.list();
        let mut i = 0;
        while i < ids.len() {
            let id = ids[i].clone();
            let more: Vec<String> =
                all.iter().filter(|c| c.parent.as_deref() == Some(&id) && !ids.contains(&c.id)).map(|c| c.id.clone()).collect();
            ids.extend(more);
            i += 1;
        }
        ids.retain(|id| self.session(id).is_ok());
        ids
    }

    fn keep_paused(&self) {
        let paused: Vec<String> = self.paused.lock().unwrap().iter().cloned().collect();
        let _ = std::fs::write(self.home.join(PAUSED), serde_json::to_vec(&paused).unwrap_or_default());
    }
}

/// A turn paused for an update says so: in place of the pause's "Interrupted" (or the line saying it's paused, once
/// it's carried on), else on a line of its own (the old zerod may have gone before the interrupt was recorded).
fn note_pause(session: &Session, words: &str) {
    let conversation = session.snapshot();
    let item = match conversation.items.last().cloned() {
        Some(mut last) if matches!(&last.kind, ItemKind::Notice { text, error: false } if text == "Interrupted" || text == PAUSED_FOR_UPDATE) =>
        {
            last.kind = ItemKind::Notice { text: words.into(), error: false };
            last
        }
        _ => crate::model::Item {
            at: None,
            id: format!("paused-{}", conversation.seq + 1),
            turn: None,
            kind: ItemKind::Notice { text: words.into(), error: false },
            status: crate::model::ItemStatus::Done,
        },
    };
    session.change(Change::Item { item });
}

unsafe extern "C" {
    safe fn kill(pid: i32, signal: i32) -> i32;
}

/// A handed-over process nothing takes over: stopped, with what it started, so it doesn't run on unseen.
fn stop_group(pid: i32) {
    kill(-pid, 9);
}
