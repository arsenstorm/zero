//! Pausing tasks: the user puts a task (a lead and its workers) or every task on hold, and picks them up later. A
//! paused session is parked and stays parked whatever arrives for it; those words wait until it's resumed.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::temp_dir;
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
    let lead = daemon.start(Provider::Claude, cwd, "lead it", None, None, Permissions::Auto).unwrap();
    let worker = daemon.spawn(&lead, Provider::Claude, "work", zerod::daemon::Options::default()).unwrap();
    let other = daemon.start(Provider::Claude, cwd, "something else", None, None, Permissions::Auto).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await; // their processes connect
    for id in [&lead, &worker, &other] { idle(&daemon, id) }

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
    let one = daemon.start(Provider::Claude, cwd, "one task", None, None, Permissions::Auto).unwrap();
    let two = daemon.start(Provider::Claude, cwd, "two tasks", None, None, Permissions::Auto).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&one, &two] { idle(&daemon, id) }
    assert_eq!(daemon.pause(&[], Duration::from_secs(1)).await.len(), 2);
    assert!(daemon.is_paused(&one) && daemon.is_paused(&two));
    assert_eq!(daemon.unpause(&[]).await.len(), 2, "and resuming nothing in particular resumes them all");
    assert!(!daemon.is_paused(&one) && !daemon.is_paused(&two));
}

#[tokio::test]
async fn words_for_a_paused_task_wait_until_it_is_resumed() {
    let home = temp_dir("pause-words");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "build it", None, None, Permissions::Auto).unwrap();
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
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "build it", None, None, Permissions::Auto).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &id);
    daemon.pause(std::slice::from_ref(&id), Duration::from_secs(1)).await;
    daemon.unpause(std::slice::from_ref(&id)).await;
    assert!(!daemon.is_paused(&id));
    assert!(!daemon.session(&id).unwrap().is_attached(), "nothing to do: parked as any finished task, until it's written to");
}

#[tokio::test]
async fn the_users_message_resumes_a_paused_task() {
    let home = temp_dir("pause-message");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "build it", None, None, Permissions::Auto).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &id);
    daemon.pause(std::slice::from_ref(&id), Duration::from_secs(1)).await;
    let _ = tokio::time::timeout(Duration::from_secs(2), daemon.send(&id, "back again", None, None)).await;
    assert!(!daemon.is_paused(&id));
}

#[tokio::test]
async fn a_working_task_is_asked_to_wrap_up_then_stopped_and_told_to_carry_on_when_resumed() {
    let home = temp_dir("pause-working");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let lead = daemon.start(Provider::Claude, cwd, "lead it", None, None, Permissions::Auto).unwrap();
    let worker = daemon.spawn(&lead, Provider::Claude, "work", zerod::daemon::Options::default()).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &lead);
    let session = daemon.session(&worker).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Its wait runs out with the turn still going (this agent never answers): it's stopped (the interrupt goes
    // unanswered here: 5 s).
    let paused = tokio::time::timeout(Duration::from_secs(15), daemon.pause(std::slice::from_ref(&lead), Duration::from_millis(300))).await.unwrap();
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
    let lead = daemon.start(Provider::Claude, cwd, "lead it", None, None, Permissions::Auto).unwrap();
    let worker = daemon.spawn(&lead, Provider::Claude, "work", zerod::daemon::Options::default()).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&lead, &worker] { idle(&daemon, id) }
    daemon.pause(std::slice::from_ref(&lead), Duration::from_secs(1)).await;
    let conversations: Vec<Conversation> = daemon.sessions().iter().map(|s| s.summary()).collect();
    let mut rows = zerod::board::board(&conversations, &[]);
    zerod::board::mark_paused(&mut rows, &|id| daemon.is_paused(id));
    let row = rows.iter().find(|r| r.session == lead).unwrap();
    assert_eq!((row.state, row.own, row.team[0].state), (zerod::board::State::Paused, zerod::board::State::Paused, zerod::board::State::Paused));
}
