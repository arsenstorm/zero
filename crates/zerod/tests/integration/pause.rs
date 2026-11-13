//! Pausing tasks: the user puts a task (a lead and its workers) or every task on hold, and picks them up later. A
//! paused session is parked and stays parked whatever arrives for it; those words wait until it's resumed.

use std::sync::Arc;
use std::time::Duration;

use crate::common::temp_dir;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

/// An agent that stays connected and says nothing: a process behind the session.
fn alive() -> Runtime {
    Arc::new(|_, _, _| {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        std::mem::forget(theirs);
        Ok(zerod::session::Transport::new(ours, tokio::io::sink()))
    })
}

fn idle(daemon: &Daemon, id: &str) {
    daemon.session(id).unwrap().change(Change::Status { status: Status::Idle, turn: None, error: None });
}

#[tokio::test]
async fn a_paused_task_is_parked_with_its_workers_and_stays_paused_across_a_restart() {
    let home = temp_dir("pause");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let lead = daemon.start(Provider::Claude, "lead it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let worker = daemon.spawn(&lead, Provider::Claude, "work", zerod::daemon::Options::default()).unwrap();
    let other =
        daemon.start(Provider::Claude, "something else", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await; // their processes connect
    for id in [&lead, &worker, &other] {
        idle(&daemon, id)
    }

    let mut paused = daemon.pause(std::slice::from_ref(&lead), Duration::from_secs(1)).await;
    paused.sort();
    let mut both = vec![lead.clone(), worker.clone()];
    both.sort();
    assert_eq!(paused, both, "the lead and its workers");
    assert!(!daemon.session(&lead).unwrap().is_attached() && !daemon.session(&worker).unwrap().is_attached(), "parked");
    assert!(daemon.session(&other).unwrap().is_attached(), "another task carries on");
    drop(daemon);

    let again = Daemon::open(&home.join("zerod"), alive()).unwrap();
    assert!(again.is_paused(&lead) && again.is_paused(&worker) && !again.is_paused(&other));
}

#[tokio::test]
async fn pausing_nothing_in_particular_pauses_every_task() {
    let home = temp_dir("pause-all");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let one = daemon.start(Provider::Claude, "one task", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let two = daemon.start(Provider::Claude, "two tasks", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&one, &two] {
        idle(&daemon, id)
    }
    assert_eq!(daemon.pause(&[], Duration::from_secs(1)).await.len(), 2);
    assert!(daemon.is_paused(&one) && daemon.is_paused(&two));
    assert_eq!(daemon.unpause(&[]).await.len(), 2, "and resuming nothing in particular resumes them all");
    assert!(!daemon.is_paused(&one) && !daemon.is_paused(&two));
}

#[tokio::test]
async fn words_for_a_paused_task_wait_until_it_is_resumed() {
    let home = temp_dir("pause-words");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &id);
    daemon.pause(std::slice::from_ref(&id), Duration::from_secs(1)).await;

    daemon.notify(&id, "CI finished").unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!daemon.session(&id).unwrap().is_attached(), "a parked task is resumed for its words, a paused one isn't");
    let waiting = std::fs::read_to_string(home.join("zerod/sessions").join(&id).join("pending.json")).unwrap();
    assert!(waiting.contains("CI finished"), "{waiting}");

    assert_eq!(daemon.unpause(std::slice::from_ref(&id)).await, std::slice::from_ref(&id));
    assert!(daemon.session(&id).unwrap().is_attached(), "resumed, for what waited");
}

#[tokio::test]
async fn a_paused_task_with_nothing_waiting_stays_parked_when_resumed() {
    let home = temp_dir("pause-nothing");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &id);
    daemon.pause(std::slice::from_ref(&id), Duration::from_secs(1)).await;
    daemon.unpause(std::slice::from_ref(&id)).await;
    assert!(!daemon.is_paused(&id));
    assert!(!daemon.session(&id).unwrap().is_attached(), "nothing to do: parked as any finished task, until it's written to");
}

#[tokio::test]
async fn the_users_message_to_a_paused_task_waits_until_it_is_resumed() {
    let home = temp_dir("pause-message");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &id);
    daemon.pause(std::slice::from_ref(&id), Duration::from_secs(1)).await;
    daemon.send(&id, zerod::session::Message::text("back again"), Default::default()).await.unwrap();
    assert!(daemon.is_paused(&id), "still paused");
    assert!(!daemon.session(&id).unwrap().is_attached(), "not resumed for it");
    assert_eq!(daemon.queued(&id).0.iter().map(|q| q.text.as_str()).collect::<Vec<_>>(), ["back again"], "queued for the resume");
}

#[tokio::test]
async fn events_held_while_paused_show_in_the_conversation_counted_and_go_first_together_on_resume() {
    let home = temp_dir("pause-events");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &id);
    daemon.pause(std::slice::from_ref(&id), Duration::from_secs(1)).await;
    assert_eq!(daemon.held_while_paused(&id), 0);

    daemon.send(&id, zerod::session::Message::text("go on"), Default::default()).await.unwrap();
    daemon.notify(&id, "CI finished").unwrap();
    daemon.notify(&id, "Review came in").unwrap();
    assert_eq!(daemon.held_while_paused(&id), 2, "the events, not the user's words");
    let notices: Vec<String> = daemon
        .session(&id)
        .unwrap()
        .snapshot()
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::Notice { text, error: false } => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert!(notices.iter().any(|n| n.contains("CI finished")) && notices.iter().any(|n| n.contains("Review came in")), "{notices:?}");

    daemon.unpause(std::slice::from_ref(&id)).await;
    assert_eq!(daemon.held_while_paused(&id), 0, "cleared on resume");
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &id);
    tokio::time::sleep(Duration::from_millis(200)).await;
    let said: Vec<String> = daemon
        .session(&id)
        .unwrap()
        .snapshot()
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::User { text, .. } if !text.contains("build it") => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert!(said[0].contains("CI finished") && said[0].contains("Review came in"), "one wake, first: {said:?}");
    assert_eq!(said.last().map(String::as_str), Some("go on"), "the user's words after it: {said:?}");
}

#[tokio::test(start_paused = true)]
async fn a_working_task_is_asked_to_wrap_up_then_stopped_and_told_to_carry_on_when_resumed() {
    let home = temp_dir("pause-working");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let lead = daemon.start(Provider::Claude, "lead it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let worker = daemon.spawn(&lead, Provider::Claude, "work", zerod::daemon::Options::default()).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &lead);
    let session = daemon.session(&worker).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Its wait runs out with the turn still going (this agent never answers): it's stopped (the interrupt goes
    // unanswered here: 5 s).
    let paused =
        tokio::time::timeout(Duration::from_secs(15), daemon.pause(std::slice::from_ref(&lead), Duration::from_millis(300))).await.unwrap();
    assert_eq!(paused.len(), 2);
    assert!(!session.is_attached());
    let told = session.snapshot().items.iter().any(|i| matches!(&i.kind, ItemKind::User { text, .. } if text.contains("pausing")));
    assert!(told, "asked to wrap up first");
    tokio::time::sleep(Duration::from_millis(100)).await;
    let waiting = std::fs::read_to_string(home.join("zerod/sessions").join(&worker).join("pending.json")).unwrap();
    assert!(waiting.contains("carry on"), "told to carry on once resumed: {waiting}");
    let lead_heard = std::fs::read_to_string(home.join("zerod/sessions").join(&lead).join("pending.json")).unwrap_or_default();
    assert!(!lead_heard.contains("Worker"), "a worker paused isn't a worker stopping: {lead_heard}");
}

#[tokio::test]
async fn a_paused_task_shows_as_paused_on_the_board() {
    let home = temp_dir("pause-board");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let lead = daemon.start(Provider::Claude, "lead it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let worker = daemon.spawn(&lead, Provider::Claude, "work", zerod::daemon::Options::default()).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&lead, &worker] {
        idle(&daemon, id)
    }
    daemon.pause(std::slice::from_ref(&lead), Duration::from_secs(1)).await;
    let conversations: Vec<Conversation> = daemon.sessions().iter().map(|s| s.summary()).collect();
    let mut rows = zerod::board::board(&conversations, &[]);
    zerod::board::mark_paused(&mut rows, &|id| daemon.is_paused(id));
    let row = rows.iter().find(|r| r.session == lead).unwrap();
    assert_eq!(
        (row.state, row.own, row.team[0].state),
        (zerod::board::State::Paused, zerod::board::State::Paused, zerod::board::State::Paused)
    );
}

#[tokio::test]
async fn restarting_the_agent_starts_a_fresh_process_on_the_same_conversation_at_once() {
    let home = temp_dir("restart-agent");
    let started = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let count = started.clone();
    let runtime: Runtime = Arc::new(move |_, _, _| {
        count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        std::mem::forget(theirs);
        Ok(zerod::session::Transport::new(ours, tokio::io::sink()))
    });
    let daemon = Daemon::open(&home.join("zerod"), runtime).unwrap();
    let id = daemon
        .start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let session = daemon.session(&id).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    let thread = session.summary().thread;

    tokio::time::timeout(Duration::from_secs(10), daemon.restart_agent(&id)).await.unwrap().unwrap();
    assert_eq!(started.load(std::sync::atomic::Ordering::SeqCst), 2, "a fresh process");
    assert!(session.is_attached(), "running again, not left stopped");
    assert_eq!(session.summary().thread, thread, "on the same conversation");
    assert!(session.summary().turn.is_none(), "its turn stopped");
    assert!(!daemon.is_paused(&id));
}
