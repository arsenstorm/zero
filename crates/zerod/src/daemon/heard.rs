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
        let reported = conversation.usage.as_ref().is_some_and(|u| u.limited);
        // Or said only in its CLI's error, without figures for the account's windows (a worker's process ending on it).
        let said = conversation.failure.as_ref().is_some_and(|f| f.kind == crate::model::FailureKind::Limit);
        if !reported && !said {
            return false;
        }
        if !reported && let Some(signin) = conversation.signin.as_deref() {
            // Kept as limited, so it isn't chosen again at once. Its reset unknown: an hour, until a read says otherwise.
            // ponytail: a guessed hour; the account's next usage read (Settings, a task's report) corrects it.
            let mut usage = self.signins.usage(signin).unwrap_or(crate::model::Usage { limited: true, resets_at: None, windows: vec![] });
            usage.limited = true;
            usage.resets_at = usage.resets_at.filter(|at| *at > now()).or(Some(now() + 3600));
            self.signins.record_usage(signin, &usage);
        }
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
            if let Ok(session) = daemon.session(&id) {
                daemon.take_offline(&session).await
            }
            daemon.tell(&id, crate::model::from_line("zero", "Your account reached its usage limit, so Zero carries this task on as another account: carry on with what you were doing."));
        });
        true
    }

    /// Refused its model by its account's provider (no access): that's kept of the account, and the task carries on as
    /// one not refused it, as at a limit. False when there's none.
    fn switch_for_model(&self, conversation: &Conversation) -> bool {
        let (Some(model), Some(signin)) = (conversation.model.as_deref(), conversation.signin.as_deref()) else { return false };
        if !conversation.failure.as_ref().is_some_and(|f| crate::signins::refuses_model(&f.message)) {
            return false;
        }
        self.signins.refuse(signin, model);
        let Some(next) = self.signins.choose_for(conversation.provider, now(), Some(signin), Some(model)) else { return false };
        let Ok(session) = self.session(&conversation.id) else { return false };
        session.change(Change::SignedIn { signin: Some(next.id.clone()) });
        session.change(Change::Status { status: conversation.status, turn: conversation.turn.clone(), error: None });
        session.change(Change::Failed { failure: None });
        let (me, id, model) = (self.me.clone(), conversation.id.clone(), model.to_string());
        tokio::spawn(async move {
            let Some(daemon) = me.upgrade() else { return };
            if let Ok(session) = daemon.session(&id) {
                daemon.take_offline(&session).await
            }
            daemon.tell(&id, crate::model::from_line("zero", &format!("Your account can't use {model}, so Zero carries this task on as another account that can: carry on with what you were doing.")));
        });
        true
    }

    /// A turn its CLI ended on a server or network error, past its own retries: carried on, three turns in a row at
    /// most (then it's the user's to see). A turn that ends otherwise starts the count again.
    fn carry_on_after_error(&self, conversation: &Conversation) {
        if self.restarting.load(Ordering::Relaxed) {
            return;
        }
        let mut carried = self.carried_on.lock().unwrap();
        if conversation.failure.as_ref().is_none_or(|f| f.kind != crate::model::FailureKind::Network) {
            carried.remove(&conversation.id);
            return;
        }
        let times = carried.entry(conversation.id.clone()).or_insert(0);
        if *times >= 3 {
            return;
        }
        *times += 1;
        drop(carried);
        self.tell(&conversation.id, crate::model::from_line("zero", CARRY_ON_AFTER_ERROR));
    }

    fn after_reset(&self, conversation: &Conversation) {
        let Some(usage) = conversation.usage.clone().filter(|u| u.limited) else { return };
        let Some(at) = usage.resets_at else { return };
        if self.resets.lock().unwrap().insert(conversation.id.clone(), at) == Some(at) {
            return;
        }
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
        // Or between turns on a question in its reply (needs the user, with nothing of the provider's open).
        let asking = now == Attention::NeedsYou
            && conversation.status == Status::Idle
            && conversation.questions.is_empty()
            && conversation.approvals.is_empty();
        let ended = asking
            || matches!(
                now,
                Attention::Done
                    | Attention::Answered
                    | Attention::Blocked
                    | Attention::Failed
                    | Attention::Limited
                    | Attention::Offline
                    | Attention::Idle
            );
        let came_to_an_end = before.is_some_and(under_way) && ended;
        // Before its lead hears of it: a lead on the same account holds the report rather than failing on it.
        self.sign_in_heard(&conversation, came_to_an_end && conversation.failure.is_none());
        if came_to_an_end {
            self.carry_read(&conversation);
            self.check_ending(&conversation);
            self.check_issue_row(&conversation);
            self.carry_on_after_error(&conversation)
        }
        // A turn finished counts for the account it ran as (its own, else its CLI's default): that account's activity.
        // Once per answer, by its item: the session's state passing through an end more than once a turn (it counted
        // six times the turns there were) is still the one turn.
        let answer = conversation
            .items
            .iter()
            .rev()
            .find(|i| matches!(i.kind, crate::model::ItemKind::Agent { final_answer: true, .. }))
            .map(|i| i.id.clone());
        if came_to_an_end
            && conversation.failure.is_none()
            && let Some(answer) = answer
            && self.counted.lock().unwrap().insert(id.to_string(), answer.clone()) != Some(answer)
            && let Some(account) = conversation.signin.clone().or_else(|| self.signins.default_for(conversation.provider).map(|s| s.id))
        {
            self.signins.record_turn(&account, crate::now());
        }
        let got_stuck = now == Attention::Stuck && before != Some(Attention::Stuck);
        // While zerod restarts, a turn ending is the pause for it: the new zerod carries it on, so its lead hears nothing.
        let restarting = self.restarting.load(Ordering::Relaxed);
        // Nor while it's paused by the user: its turn ending is the pause.
        // Nor while it's being archived (its lead closed it): its end is the closing. Nor when it stopped without an
        // answer while workers of its own still work: it's waiting on them, and reports once it hears from them.
        let archiving = self.archiving.lock().unwrap().contains(id);
        let unanswered = !matches!(
            now,
            Attention::Done | Attention::Failed | Attention::Stuck | Attention::Limited | Attention::Blocked | Attention::Offline
        );
        let waiting_on_workers = unanswered
            && self.workers(id).iter().any(|w| matches!(w.attention(), Attention::Starting | Attention::Working | Attention::NeedsYou));
        // Nor the turn it was just sent back from (no Zero ending): its lead hears the turn as it ends properly, once.
        let sent_back = self.sent_back.lock().unwrap().contains(id);
        if let Some(lead) = &conversation.parent
            && (came_to_an_end || got_stuck)
            && !restarting
            && !self.is_paused(id)
            && !archiving
            && !waiting_on_workers
            && !sent_back
        {
            // Done is done-done: once the lead has this report, the worker leaves its tree (deliver).
            // Only said so: a report without an ending is a turn finished, which may not be the work.
            let said_done = conversation.answer().is_some_and(|answer| crate::board::ending(answer) == Some("done"));
            if now == Attention::Done && said_done {
                self.leaving.lock().unwrap().insert(conversation.id.clone());
            } else {
                self.leaving.lock().unwrap().remove(&conversation.id);
            }
            self.tell(lead, crate::model::from_line(&conversation.id, &report(&conversation, now)));
        }
        // What its CLI says of its account's usage is the account's, for choosing accounts by.
        if let (Some(signin), Some(usage)) = (&conversation.signin, &conversation.usage) {
            self.signins.record_usage(signin, usage)
        }
        if now == Attention::Limited && !self.switch_account(&conversation) {
            self.after_reset(&conversation)
        }
        if now == Attention::Failed && before != Some(Attention::Failed) {
            self.switch_for_model(&conversation);
        }
        if between_turns(&conversation) {
            // A change kept for this moment first (a model, permissions picked mid-turn), then what's queued, on it.
            match (self.next(id).is_some() && !self.restarting.load(Ordering::Relaxed), self.me.upgrade()) {
                (true, Some(daemon)) => {
                    let id = id.to_string();
                    tokio::spawn(async move {
                        daemon.apply_next(&id).await;
                        // Stopped to start again with new permissions: started again for what's queued.
                        let waiting = daemon.pending.lock().unwrap().get(&id).is_some_and(|words| !words.is_empty());
                        let attached = daemon.session(&id).is_ok_and(|s| s.is_attached());
                        if waiting && !attached {
                            if let Err(error) = daemon.resume(&id).await {
                                eprintln!("zerod: couldn't resume {id} after its change: {error}")
                            }
                        } else {
                            daemon.deliver(&id)
                        }
                    });
                }
                _ => self.deliver(id),
            }
        }
    }

    /// The user saw a task's reply: its latest answer unless one is named, now unless a time is given (a client
    /// passing on what it recorded before zerod kept this).
    pub fn mark_seen(&self, id: &str, answer: Option<&str>, at: Option<i64>) -> Result<(), String> {
        self.session(id)?;
        let Some(answer) = answer.map(String::from).or_else(|| self.latest_answer(id)) else { return Ok(()) };
        let mut seen = self.seen.lock().unwrap();
        if seen.get(id).is_some_and(|(kept, _)| *kept == answer) && at.is_none() {
            return Ok(());
        }
        seen.insert(id.to_string(), (answer, at.unwrap_or_else(now)));
        let _ = std::fs::write(self.home.join(SEEN), serde_json::to_vec(&*seen).unwrap_or_default());
        // Its row greys now, on every client: the board is worked out again at once, as for a queue the user changed.
        let _ = self.queues.send(());
        Ok(())
    }

    /// A task's turn has ended: if it doesn't say where it left the task (Zero's ending), or ends on a question it
    /// never asked the user, it's sent back once to end properly. A worker reports to its lead and needs none.
    /// Every task's turns end on Zero's ending from now on (zerod, as it starts).
    pub fn require_endings(&self) {
        self.endings.store(true, Ordering::Relaxed)
    }

    fn check_ending(&self, conversation: &Conversation) {
        if !self.endings.load(Ordering::Relaxed) {
            return;
        }
        // A worker too: its row says where it left its work, and its lead hears how it ended.
        let worker = conversation.parent.is_some();
        // Its ending after being sent back: taken as it is.
        if self.sent_back.lock().unwrap().remove(&conversation.id) {
            return;
        }
        // This turn's own answer (since the last message to it): a turn stopped before it answered (by the user, by
        // a restart) didn't end, and an earlier turn's answer isn't this one's.
        let turn = conversation
            .items
            .iter()
            .rposition(|i| matches!(i.kind, ItemKind::User { .. }))
            .map_or(&conversation.items[..], |at| &conversation.items[at..]);
        // Stopped (its "Interrupted", or a restart pausing it): what it said so far isn't how it ended.
        if self.restarting.load(Ordering::Relaxed) || turn.last().is_some_and(|i| matches!(i.kind, ItemKind::Notice { .. })) {
            return;
        }
        // Started by the user's own words: they're in the conversation, and a question in the reply is how one goes.
        // The rule is for turns they aren't in (an event, a worker's report, a wake-up), where words reach no one.
        // A worker's first words are its brief, from its lead: no conversation with the user.
        if !worker && turn.first().is_some_and(|i| matches!(&i.kind, ItemKind::User { text, .. } if users_own(text))) {
            return;
        }
        let Some(answer) = turn.iter().rev().find_map(|i| match &i.kind {
            ItemKind::Agent { text, final_answer: true } => Some(text.as_str()),
            _ => None,
        }) else {
            return;
        };
        let ending = crate::board::ending(answer);
        // A worker's question in prose is its lead's to take up: any ending will do.
        if ending.is_some() && (worker || ending == Some("asked") || !crate::board::asks_in_prose(answer)) {
            return;
        }
        self.sent_back.lock().unwrap().insert(conversation.id.clone());
        let words = if worker { END_A_WORKERS_TURN } else { END_YOUR_TURN };
        self.pending.lock().unwrap().entry(conversation.id.clone()).or_default().push(Queued {
            id: new_id(),
            text: words.into(),
            images: vec![],
            report: true,
        });
        self.keep_pending(&conversation.id);
        if between_turns(conversation) {
            self.deliver(&conversation.id)
        }
    }

    /// A turn Zero started (an event it follows, a worker's report, a wake-up) has come to an end: its reply is nothing
    /// new for the user if they had read the one before it, so it's read too. One to their own message stays new.
    fn carry_read(&self, conversation: &Conversation) {
        let items = &conversation.items;
        let Some(asked) = items.iter().rposition(|i| matches!(i.kind, ItemKind::User { .. })) else { return };
        let ItemKind::User { text, .. } = &items[asked].kind else { return };
        if !text.starts_with(crate::model::FROM) {
            return;
        }
        let answer = |range: &[crate::model::Item]| {
            range.iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. })).map(|i| i.id.clone())
        };
        let (Some(before), Some(latest)) = (answer(&items[..asked]), answer(&items[asked..])) else { return };
        let read_before = self.seen.lock().unwrap().get(&conversation.id).is_some_and(|(seen, _)| *seen == before);
        if read_before {
            let _ = self.mark_seen(&conversation.id, Some(&latest), None);
        }
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
    if let Some(ticket) = &worker.ticket {
        name = format!("{name} ({ticket})")
    }
    let what = match attention {
        Attention::Done => {
            let full = worker.answer().unwrap_or("");
            let answer = crate::board::without_ending(full);
            let answer =
                if answer.chars().count() > 4000 { answer.chars().take(4000).collect::<String>() + "…" } else { answer.to_string() };
            // How it ended its turn says what its answer is: a worker waiting on the user, or blocked, isn't finished.
            match crate::board::ending(full) {
                Some("asked") => {
                    let id =
                        full.trim_end().lines().last().and_then(|l| l.trim().trim_end_matches(']').split_whitespace().nth(2)).unwrap_or("");
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
    format!(
        "Worker {name} {what}\n\n(It is session {}: `zero send {} \"…\"` to reply to it, `zero wait {}` to wait on it.)",
        worker.id, worker.id, worker.id
    )
}

/// How long a row set by its lead still stands for the issue, whatever reports come.
const ROW_FRESH_MS: i64 = 10 * 60 * 1000;

impl Daemon {
    /// A lead's turn started by its worker's report on a ticket: the issue's row is what the user reads coming back,
    /// so a turn that heard of it and left a stale row alone is told, once until the row is set (the reminder's own turn
    /// is Zero's, not a report). A row set in the last ten minutes still says it: most reports change nothing.
    fn check_issue_row(&self, conversation: &Conversation) {
        // A turn that failed had no chance to set it.
        if !self.endings.load(Ordering::Relaxed)
            || conversation.parent.is_some()
            || self.restarting.load(Ordering::Relaxed)
            || conversation.failure.is_some()
        {
            return;
        }
        let Some(first) = conversation.items.iter().rev().find(|i| matches!(i.kind, ItemKind::User { .. })) else { return };
        let ItemKind::User { text, .. } = &first.kind else { return };
        let Some(worker) = text.strip_prefix(crate::model::FROM).and_then(|rest| rest.split_once(" -->")).map(|(id, _)| id) else { return };
        let Some(ticket) = self.get(worker).filter(|w| w.parent.as_deref() == Some(conversation.id.as_str())).and_then(|w| w.ticket) else {
            return;
        };
        let started = first.at.unwrap_or(0);
        let set = conversation.issues.iter().find(|i| i.ticket == ticket).map_or(0, |i| i.updated);
        if set >= started || crate::now_ms() - set < ROW_FRESH_MS {
            return;
        }
        let key = (conversation.id.clone(), ticket.clone());
        let mut reminded = self.reminded_rows.lock().unwrap();
        if reminded.get(&key).is_some_and(|&at| set < at) {
            return;
        }
        reminded.insert(key, crate::now_ms());
        drop(reminded);
        self.tell(
            &conversation.id,
            crate::model::from_line(
                "zero",
                &format!(
                    "{ISSUE_ROW_MARK} after {ticket}'s report: it's what the user reads \
            coming back. Set it with `zero issue {ticket} you|working|waiting|parked|done \"…\"` (on the user: what it needs from them; \
            waiting: on whom; parked: why), then end your turn."
                ),
            ),
        );
    }
}

/// Words the user wrote themselves, not ones Zero gave the task (an event, a report, a send-back, a carry-on).
fn users_own(text: &str) -> bool {
    !text.starts_with(crate::model::FROM)
        && ![END_YOUR_TURN_MARK, WRAP_UP].iter().chain(CARRIES.iter()).any(|zeros| text.starts_with(zeros))
}
