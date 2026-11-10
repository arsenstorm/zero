//! Which replies are new to the user: one to their own message is, until they've seen it. One to a turn Zero started
//! (an event it follows, a worker's report, a wake-up) is only if the task's reply before it was still unread.

use std::sync::Arc;
use std::time::Duration;

use crate::common::temp_dir;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

fn alive() -> Runtime {
    Arc::new(|_, _, _| {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        std::mem::forget(theirs);
        Ok(zerod::session::Transport::new(ours, tokio::io::sink()))
    })
}

fn item(id: &str, kind: ItemKind) -> Change {
    Change::Item { item: Item { at: None, id: id.into(), turn: None, kind, status: ItemStatus::Done } }
}

/// A turn: its message in, its answer out, between turns again.
async fn turn(session: &zerod::session::Session, n: usize, said: &str) {
    session.change(Change::Status { status: Status::Working, turn: Some(format!("t{n}")), error: None });
    // A turn takes a while: zerod reads a task as it is when it hears of it, so it sees this one under way.
    tokio::time::sleep(Duration::from_millis(100)).await;
    session.change(item(&format!("u{n}"), ItemKind::User { text: said.into(), images: vec![] }));
    session.change(item(&format!("a{n}"), ItemKind::Agent { text: format!("answer {n}"), final_answer: true }));
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    tokio::time::sleep(Duration::from_millis(200)).await;
}

#[tokio::test]
async fn a_reply_to_a_turn_zero_started_is_new_only_if_the_last_one_was_unread() {
    let home = temp_dir("replies");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let session = daemon.session(&id).unwrap();
    turn(&session, 1, "Is the PR merged?").await;
    assert!(!daemon.has_read(&id), "a reply to the user is new");
    daemon.mark_seen(&id, None, None).unwrap();
    assert!(daemon.has_read(&id));
    // An event it follows: nothing new for the user, so the reply to it is read already.
    turn(&session, 2, &from_line("zero", "1 new event on what you follow")).await;
    assert!(daemon.has_read(&id), "a turn Zero started, after a reply the user had read");
    // The user's own word again, its reply unread; then a worker's report: the task still has a reply to read.
    turn(&session, 3, "And the scan?").await;
    turn(&session, 4, &from_line("worker-1", "Worker finished")).await;
    assert!(!daemon.has_read(&id), "the reply before it was still unread");
}

#[tokio::test]
async fn seeing_a_reply_shows_on_the_board_at_once() {
    let home = temp_dir("replies-seen");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    turn(&daemon.session(&id).unwrap(), 1, "Is the PR merged?").await;
    let mut board_moves = daemon.subscribe_queues();
    daemon.mark_seen(&id, None, None).unwrap();
    // The board is worked out again now, not when something else next changes.
    assert!(tokio::time::timeout(Duration::from_secs(1), board_moves.recv()).await.is_ok(), "the board hears it");
}
