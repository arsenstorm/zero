//! Pausing turns: for zerod's restart (paused between steps, carried on by the new zerod) and by the user.

use super::*;

impl Daemon {
    /// Before zerod becomes a new build: every turn under way is paused between steps (a command running is left to
    /// finish, up to COMMAND_WAIT), its session told to carry on once the new zerod is up. All at once, so one long
    /// command holds up only its own turn. Gives the sessions paused.
    pub async fn pause_for_restart(&self) -> Vec<String> {
        self.restarting.store(true, Ordering::Relaxed);
        let mut pausing = tokio::task::JoinSet::new();
        for session in self.sessions() {
            let conversation = session.summary();
            // Only a turn with a process behind it: an offline session's last status may still say it was working.
            if !session.is_attached() || !matches!(conversation.status, Status::Working | Status::Waiting | Status::Starting) { continue }
            let me = self.me.clone();
            pausing.spawn(async move {
                let deadline = tokio::time::Instant::now() + COMMAND_WAIT;
                // What it's waiting for, for the app to show while it waits.
                let (recent, _) = session.recent(50);
                let running = recent.items.iter().rev().find_map(|i| match (&i.kind, i.status) {
                    (ItemKind::Command { command, .. }, crate::model::ItemStatus::Running) => Some(command.clone()), _ => None });
                if let (Some(command), Some(daemon)) = (running, me.upgrade()) { daemon.held_up.lock().unwrap().insert(conversation.id.clone(), command); }
                // A session closed or gone offline meanwhile has no command to wait for, whatever its last item says.
                while session.is_attached() && (session.running_command() || session.summary().status == Status::Starting) && tokio::time::Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
                session.pause_for_update();
                if session.is_attached() { let _ = tokio::time::timeout(Duration::from_secs(5), session.interrupt()).await; }
                // The agent's own note of the stop says it's paused for the update; a moment for it, else Zero's.
                let noted = || session.recent(5).0.items.iter().any(|i| matches!(&i.kind, ItemKind::Notice { text, .. } if text == PAUSED_FOR_UPDATE));
                for _ in 0..10 { if noted() { break } tokio::time::sleep(Duration::from_millis(100)).await }
                if !noted() { note_pause(&session, PAUSED_FOR_UPDATE) }
                if let Some(daemon) = me.upgrade() {
                    daemon.held_up.lock().unwrap().remove(&conversation.id);
                    daemon.updating.lock().unwrap().insert(conversation.id.clone());
                    let _ = daemon.queues.send(());
                }
                conversation.id
            });
        }
        let mut paused = vec![];
        while let Some(done) = pausing.join_next().await { if let Ok(id) = done { paused.push(id) } }
        for id in &paused {
            // Once, however many restarts paused it before it carried on.
            let mut pending = self.pending.lock().unwrap();
            let list = pending.entry(id.clone()).or_default();
            if list.iter().any(|q| q.text == CARRY_ON) { continue }
            list.push(Queued { id: new_id(), text: CARRY_ON.into(), images: vec![], report: true });
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
            if session.is_attached() || session.summary().terminal.is_some() || self.is_paused(&id) { continue }
            // The turn was paused for the update and carried on, not stopped: said in the conversation, in place of the
            // pause's "Interrupted" when that was noted, on a line of its own when it wasn't (the old zerod may have
            // gone before the interrupt's result was recorded).
            note_pause(&session, CARRIED);
            let Some(daemon) = self.me.upgrade() else { break };
            resumed.push(id.clone());
            tokio::spawn(async move { if let Err(error) = daemon.resume(&id).await { eprintln!("zerod: couldn't resume {id} to carry on: {error}") } });
        }
        resumed
    }

    /// Whether a restart is under way, and the turns it's waiting on: each one's task and the command it lets finish
    /// (at most COMMAND_WAIT), for the app to say what Zero is waiting for.
    pub fn restart_status(&self) -> serde_json::Value {
        let waiting: Vec<serde_json::Value> = self.held_up.lock().unwrap().iter().map(|(id, command)| {
            let task = self.session(id).map(|s| { let c = s.summary(); c.label.or(c.title).unwrap_or_default() }).unwrap_or_default();
            serde_json::json!({"session": id, "task": task, "command": command})
        }).collect();
        serde_json::json!({"restarting": self.restarting.load(Ordering::Relaxed), "waiting": waiting, "most": COMMAND_WAIT.as_secs()})
    }

    /// Paused by a restart, until the new zerod carries it on: the board shows it as paused.
    pub fn is_paused_for_update(&self, id: &str) -> bool { self.updating.lock().unwrap().contains(id) }

    pub fn is_paused(&self, id: &str) -> bool { self.paused.lock().unwrap().contains(id) }

    /// Puts `ids` and their workers (every lead's, `ids` empty) on hold: each working one is asked to wrap up, given
    /// `wait` to end its turn, then stopped (a running command left to finish first, as for a restart); then parked.
    /// Words for them wait until they're resumed. Gives the sessions paused.
    pub async fn pause(&self, ids: &[String], wait: Duration) -> Vec<String> {
        let targets = if ids.is_empty() { self.list().into_iter().filter(|c| c.parent.is_none()).map(|c| c.id).collect() } else { ids.to_vec() };
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
                    daemon.pending.lock().unwrap().entry(id.clone()).or_default()
                        .push(Queued { id: new_id(), text: crate::model::from_line("zero", RESUMED), images: vec![], report: true });
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

    /// Takes `ids` (every paused session, `ids` empty) off hold. Those with words waiting are resumed for them; the
    /// rest stay parked until they're written to, as any finished task. Gives the sessions taken off hold.
    pub async fn unpause(&self, ids: &[String]) -> Vec<String> {
        let ids = if ids.is_empty() { self.paused.lock().unwrap().iter().cloned().collect() } else { self.with_workers(ids.to_vec()) };
        let resumed: Vec<String> = {
            let mut paused = self.paused.lock().unwrap();
            ids.into_iter().filter(|id| paused.remove(id)).collect()
        };
        self.keep_paused();
        let waiting = self.pending.lock().unwrap().clone();
        for id in &resumed {
            if !waiting.get(id).is_some_and(|words| !words.is_empty()) { continue }
            if let Err(error) = self.resume(id).await { eprintln!("zerod: couldn't resume {id} after its pause: {error}") }
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
            let more: Vec<String> = all.iter().filter(|c| c.parent.as_deref() == Some(&id) && !ids.contains(&c.id)).map(|c| c.id.clone()).collect();
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
        Some(mut last) if matches!(&last.kind, ItemKind::Notice { text, error: false } if text == "Interrupted" || text == PAUSED_FOR_UPDATE) => {
            last.kind = ItemKind::Notice { text: words.into(), error: false };
            last
        }
        _ => crate::model::Item { at: None, id: format!("paused-{}", conversation.seq + 1), turn: None,
                                  kind: ItemKind::Notice { text: words.into(), error: false }, status: crate::model::ItemStatus::Done },
    };
    session.change(Change::Item { item });
}
