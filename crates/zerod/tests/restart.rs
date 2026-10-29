//! zerod replacing itself with a new build without losing anyone's work: each turn under way is paused between steps
//! (a command running is waited for, never cut off), noted to carry on, and carried on by the new zerod.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::temp_dir;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

/// An agent that stays connected and says nothing: a process behind the session, as a turn under way has.
fn alive() -> Runtime {
    Arc::new(|_, _, _| {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        std::mem::forget(theirs);
        Ok(zerod::session::Transport::new(ours, tokio::io::sink()))
    })
}

fn command(status: ItemStatus) -> Change {
    Change::Item { item: Item { id: "c1".into(), turn: None, kind: ItemKind::Command { command: "make test".into(), cwd: "/".into(), output: String::new(), exit_code: None, duration_ms: None }, status, at: None } }
}

#[tokio::test]
async fn a_restart_waits_for_a_running_command_then_pauses_the_turn_to_carry_on() {
    let home = temp_dir("restart");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let working = daemon.start(Provider::Claude, cwd, "build it", None, None, Permissions::Auto).unwrap();
    let idle = daemon.start(Provider::Claude, cwd, "done already", None, None, Permissions::Auto).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await; // their processes connect
    let session = daemon.session(&working).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    session.change(command(ItemStatus::Running));
    daemon.session(&idle).unwrap().change(Change::Status { status: Status::Idle, turn: None, error: None });

    let pausing = tokio::spawn({ let daemon = daemon.clone(); async move { daemon.pause_for_restart().await } });
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(!pausing.is_finished(), "the command is left to finish");

    session.change(command(ItemStatus::Done));
    let paused = tokio::time::timeout(Duration::from_secs(10), pausing).await.unwrap().unwrap(); // its interrupt goes unanswered here: 5 s
    assert_eq!(paused, std::slice::from_ref(&working), "only what was under way");
    let words = std::fs::read_to_string(home.join("zerod/sessions").join(&working).join("pending.json")).unwrap();
    assert!(words.contains("carry on"), "kept for the new zerod to give it: {words}");
    assert!(!home.join("zerod/sessions").join(&idle).join("pending.json").exists());
}

#[tokio::test]
async fn after_a_restart_only_what_it_paused_carries_on() {
    let home = temp_dir("restart-carry");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let paused = daemon.start(Provider::Claude, cwd, "build it", None, None, Permissions::Auto).unwrap();
    let parked = daemon.start(Provider::Claude, cwd, "parked", None, None, Permissions::Auto).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await; // their processes connect
    daemon.session(&paused).unwrap().change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    daemon.session(&parked).unwrap().change(Change::Status { status: Status::Offline, turn: None, error: None });
    // Words left for a parked task (a note for when it's next resumed) aren't a reason to resume it.
    std::fs::write(home.join("zerod/sessions").join(&parked).join("pending.json"), r#"["for when you're back"]"#).unwrap();
    assert_eq!(daemon.pause_for_restart().await, std::slice::from_ref(&paused));
    drop(daemon);

    let again = Daemon::open(&home.join("zerod"), alive()).unwrap();
    assert_eq!(again.carry_on(), std::slice::from_ref(&paused), "the paused turn, not the parked task with words waiting");
    assert!(again.carry_on().is_empty(), "once");
}

#[tokio::test]
async fn an_offline_session_whose_status_still_says_working_isnt_paused() {
    let home = temp_dir("restart-stale");
    // Its process gone at once, as one that ended is.
    let gone: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home.join("zerod"), gone).unwrap();
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "old", None, None, Permissions::Auto).unwrap();
    let session = daemon.session(&id).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    assert!(daemon.pause_for_restart().await.is_empty(), "no process, no turn to pause");
}
