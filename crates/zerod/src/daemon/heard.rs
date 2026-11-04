//! What the daemon does as it hears a session change: a worker's end reported to its lead, a turn's ending
//! checked, a read carried on, an account switched or a reset waited for at a usage limit.

use super::*;

impl Daemon {
    /// Each provider's limits as its CLI last reported them, from the session that heard last.
    pub fn usage(&self) -> Vec<(Provider, crate::model::Usage)> {
        let mut latest: Vec<(Provider, crate::model::Usage)> = vec![];
        for conversation in self.sessions().iter().map(|s| s.summary()) {
            let Some(usage) = conversation.usage else { continue };
            latest.retain(|(p, _)| *p != conversation.provider);
            latest.push((conversation.provider, usage));
        }
        latest
    }

    /// A session stopped by a usage limit is told to go on once the limit has reset.
    /// At its account's usage limit: carried on as another of its CLI's accounts, the one the policy picks
    /// (signins.rs choose), its agent started again on the same conversation. False when there's none to go to.
    fn switch_account(&self, conversation: &Conversation) -> bool {
        if conversation.usage.as_ref().is_none_or(|u| !u.limited) { return false }
        let Some(next) = self.signins.choose(conversation.provider, now(), conversation.signin.as_deref()) else { return false };
        let Ok(session) = self.session(&conversation.id) else { return false };
        session.change(Change::SignedIn { signin: Some(next.id.clone()) });
        // The limit was the last account's: this one starts clear.
        session.change(Change::Usage { usage: crate::model::Usage { limited: false, resets_at: None, windows: vec![] } });
        // As is the error that said so (the failure is worked out from it).
        session.change(Change::Status { status: conversation.status, turn: conversation.turn.clone(), error: None });
        session.change(Change::Failed { failure: None });
        let (me, id) = (self.me.clone(), conversation.id.clone());
        tokio::spawn(async move {
            let Some(daemon) = me.upgrade() else { return };
            if let Ok(session) = daemon.session(&id) { daemon.take_offline(&session).await }
            daemon.tell(&id, crate::model::from_line("zero", "Your account reached its usage limit, so Zero carries this task on as another account: carry on with what you were doing."));
        });
        true
    }

    fn after_reset(&self, conversation: &Conversation) {
        let Some(usage) = conversation.usage.clone().filter(|u| u.limited) else { return };
        let Some(at) = usage.resets_at else { return };
        if self.resets.lock().unwrap().insert(conversation.id.clone(), at) == Some(at) { return }
        let (me, id) = (self.me.clone(), conversation.id.clone());
        let wait = Duration::from_secs((at - now()).max(0) as u64 + 60);
        tokio::spawn(async move {
            tokio::time::sleep(wait).await;
            let Some(daemon) = me.upgrade() else { return };
            let Ok(session) = daemon.session(&id) else { return };
            // The provider says nothing when a limit resets; the clock does.
            session.change(Change::Usage { usage: crate::model::Usage { limited: false, resets_at: None, ..usage } });
            daemon.tell(&id, crate::model::from_line("zero", "The usage limit has reset: carry on with what you were doing."));
        });
    }

    /// Something changed in `id`: a worker that has come to an end (or just got stuck) tells its lead, and a session
    /// between turns gets the word waiting for it. The session is read as it is now, which may be several events on
    /// from the one heard, so a worker can seem to go straight from waiting on the user to done: anything still under
    /// way counts as before, anything ended as now.
    pub(super) fn heard(&self, id: &str) {
        let Some(conversation) = self.get(id) else { return };
        let now = conversation.attention();
        let before = self.attention.lock().unwrap().insert(id.into(), now);
        let under_way = |a: Attention| matches!(a, Attention::Starting | Attention::Working | Attention::NeedsYou | Attention::Stuck);
        let ended = matches!(now, Attention::Done | Attention::Answered | Attention::Blocked | Attention::Failed | Attention::Limited | Attention::Offline | Attention::Idle);
        let came_to_an_end = before.is_some_and(under_way) && ended;
        if came_to_an_end { self.carry_read(&conversation); self.check_ending(&conversation) }
        let got_stuck = now == Attention::Stuck && before != Some(Attention::Stuck);
        // While zerod restarts, a turn ending is the pause for it: the new zerod carries it on, so its lead hears nothing.
        let restarting = self.restarting.load(Ordering::Relaxed);
        // Nor while it's paused by the user: its turn ending is the pause.
        if let Some(lead) = &conversation.parent && (came_to_an_end || got_stuck) && !restarting && !self.is_paused(id) {
            self.tell(lead, crate::model::from_line(&conversation.id, &report(&conversation, now)));
        }
        // What its CLI says of its account's usage is the account's, for choosing accounts by.
        if let (Some(signin), Some(usage)) = (&conversation.signin, &conversation.usage) { self.signins.record_usage(signin, usage) }
        if now == Attention::Limited && !self.switch_account(&conversation) { self.after_reset(&conversation) }
        if between_turns(&conversation) { self.deliver(id) }
    }

    /// The user saw a task's reply: its latest answer unless one is named, now unless a time is given (a client
    /// passing on what it recorded before zerod kept this).
    pub fn mark_seen(&self, id: &str, answer: Option<&str>, at: Option<i64>) -> Result<(), String> {
        self.session(id)?;
        let Some(answer) = answer.map(String::from).or_else(|| self.latest_answer(id)) else { return Ok(()) };
        let mut seen = self.seen.lock().unwrap();
        if seen.get(id).is_some_and(|(kept, _)| *kept == answer) && at.is_none() { return Ok(()) }
        seen.insert(id.to_string(), (answer, at.unwrap_or_else(now)));
        let _ = std::fs::write(self.home.join(SEEN), serde_json::to_vec(&*seen).unwrap_or_default());
        // Its row greys now, on every client: the board is worked out again at once, as for a queue the user changed.
        let _ = self.queues.send(());
        Ok(())
    }

    /// A task's turn has ended: if it doesn't say where it left the task (Zero's ending), or ends on a question it
    /// never asked the user, it's sent back once to end properly. A worker reports to its lead and needs none.
    /// Every task's turns end on Zero's ending from now on (zerod, as it starts).
    pub fn require_endings(&self) { self.endings.store(true, Ordering::Relaxed) }

    fn check_ending(&self, conversation: &Conversation) {
        if !self.endings.load(Ordering::Relaxed) || conversation.parent.is_some() { return }
        // Its ending after being sent back: taken as it is.
        if self.sent_back.lock().unwrap().remove(&conversation.id) { return }
        // This turn's own answer (since the last message to it): a turn stopped before it answered (by the user, by
        // a restart) didn't end, and an earlier turn's answer isn't this one's.
        let turn = conversation.items.iter().rposition(|i| matches!(i.kind, ItemKind::User { .. })).map_or(&conversation.items[..], |at| &conversation.items[at..]);
        // Stopped (its "Interrupted", or a restart pausing it): what it said so far isn't how it ended.
        if self.restarting.load(Ordering::Relaxed) || turn.last().is_some_and(|i| matches!(i.kind, ItemKind::Notice { .. })) { return }
        let Some(answer) = turn.iter().rev().find_map(|i| match &i.kind { ItemKind::Agent { text, final_answer: true } => Some(text.as_str()), _ => None }) else { return };
        let ending = crate::board::ending(answer);
        if ending.is_some() && (ending == Some("asked") || !unasked_question(answer)) { return }
        self.sent_back.lock().unwrap().insert(conversation.id.clone());
        self.pending.lock().unwrap().entry(conversation.id.clone()).or_default().push(Queued { id: new_id(), text: END_YOUR_TURN.into(), images: vec![], report: true });
        self.keep_pending(&conversation.id);
        if between_turns(conversation) { self.deliver(&conversation.id) }
    }

    /// A turn Zero started (an event it follows, a worker's report, a wake-up) has come to an end: its reply is nothing
    /// new for the user if they had read the one before it, so it's read too. One to their own message stays new.
    fn carry_read(&self, conversation: &Conversation) {
        let items = &conversation.items;
        let Some(asked) = items.iter().rposition(|i| matches!(i.kind, ItemKind::User { .. })) else { return };
        let ItemKind::User { text, .. } = &items[asked].kind else { return };
        if !text.starts_with(crate::model::FROM) { return }
        let answer = |range: &[crate::model::Item]| range.iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. })).map(|i| i.id.clone());
        let (Some(before), Some(latest)) = (answer(&items[..asked]), answer(&items[asked..])) else { return };
        let read_before = self.seen.lock().unwrap().get(&conversation.id).is_some_and(|(seen, _)| *seen == before);
        if read_before { let _ = self.mark_seen(&conversation.id, Some(&latest), None); }
    }

    /// Whether the user has read the task's reply (board::read).
    pub fn has_read(&self, id: &str) -> bool {
        let seen = self.seen.lock().unwrap().get(id).cloned();
        seen.is_some() && crate::board::read(seen.as_ref().map(|(a, at)| (a.as_str(), *at)), self.latest_answer(id).as_deref(), now())
    }

    fn latest_answer(&self, id: &str) -> Option<String> {
        self.get(id)?.items.iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. })).map(|i| i.id.clone())
    }
}

/// What a lead is told when a worker stops working, and how to answer it.
pub fn report(worker: &Conversation, attention: Attention) -> String {
    let mut name = worker.label.clone().unwrap_or_else(|| worker.id.clone());
    if let Some(ticket) = &worker.ticket { name = format!("{name} ({ticket})") }
    let what = match attention {
        Attention::Done => {
            let full = worker.answer().unwrap_or("");
            let answer = crate::board::without_ending(full);
            let answer = if answer.chars().count() > 4000 { answer.chars().take(4000).collect::<String>() + "…" } else { answer.to_string() };
            // How it ended its turn says what its answer is: a worker waiting on the user, or blocked, isn't finished.
            match crate::board::ending(full) {
                Some("asked") => {
                    let id = full.trim_end().lines().last().and_then(|l| l.trim().trim_end_matches(']').split_whitespace().nth(2)).unwrap_or("");
                    format!("is waiting on the user's answer (ask {id}): {answer}")
                }
                Some("waiting") => format!("is waiting: {answer}"),
                _ => format!("finished: {answer}"),
            }
        }
        Attention::Failed => format!("failed: {}", worker.failure.as_ref().map(|f| f.message.as_str()).unwrap_or("no reason given")),
        Attention::Stuck => format!("looks stuck: {}", worker.stalled.as_deref().unwrap_or("no progress")),
        Attention::Limited => "hit a usage limit".into(),
        Attention::Blocked => format!("is blocked: {}", worker.answer().map(crate::board::without_ending).unwrap_or("no reason given")),
        Attention::Offline => "stopped: its process ended".into(),
        _ => "stopped without an answer".into(),
    };
    format!("Worker {name} {what}\n\n(It is session {}: `zero send {} \"…\"` to reply to it, `zero wait {}` to wait on it.)", worker.id, worker.id, worker.id)
}

/// Whether an answer ends on a question to the user: one of its last few lines (Zero's ending aside) ends with "?".
fn unasked_question(answer: &str) -> bool {
    answer.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with("[zero:")).rev().take(3)
        .any(|l| l.trim_end_matches(['*', '_', ')', '"']).ends_with('?'))
}
