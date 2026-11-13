//! An agent between turns with nothing open is parked after a while: its process stops, so finished work doesn't hold
//! memory, and it goes offline keeping its state. Words for it (a reminder, a watch ending, a worker's report) resume it
//! on its own thread first.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::temp_dir;
use serde_json::json;
use zerod::daemon::{Daemon, Options, PARK_AFTER, Runtime};
use zerod::model::*;

/// A runtime that starts and then says nothing, kept open; how many have started.
fn silent(started: Arc<Mutex<Vec<tokio::io::DuplexStream>>>) -> Runtime {
    Arc::new(move |_, _, _| {
        let (zero_side, runtime_side) = tokio::io::duplex(1 << 16);
        started.lock().unwrap().push(runtime_side);
        let (read, write) = tokio::io::split(zero_side);
        Ok(zerod::session::Transport::new(read, write))
    })
}

async fn minutes(n: u64) {
    for _ in 0..n * 4 {
        tokio::time::sleep(Duration::from_secs(15)).await
    }
}

#[tokio::test(start_paused = true)]
async fn an_idle_agent_is_parked_and_woken_by_words_for_it() {
    let home = temp_dir("parking");
    let user = home.join("user");
    let started = Arc::new(Mutex::new(vec![]));
    let daemon = Daemon::open(&home.join("zerod"), silent(started.clone())).unwrap();
    daemon.place(&user);
    let cwd = home.to_str().unwrap();
    let file = zerod::handoff::claude_folder(&user, cwd).join("t1.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, json!({"type": "user", "uuid": "u1", "message": {"role": "user", "content": "hi"}}).to_string() + "\n").unwrap();
    let id = daemon.adopt(Provider::Claude, "t1", cwd, Options::default()).unwrap();
    daemon.resume(&id).await.unwrap();
    let session = daemon.session(&id).unwrap();
    assert!(session.is_attached());

    minutes(PARK_AFTER.as_secs() / 60 - 1).await;
    assert!(session.is_attached(), "not yet");
    minutes(2).await;
    assert!(!session.is_attached(), "parked once idle for {PARK_AFTER:?}");
    assert_eq!(session.snapshot().status, Status::Offline);

    daemon.notify(&id, "The deploy finished.").unwrap();
    for _ in 0..20 {
        if session.is_attached() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await
    }
    assert!(session.is_attached(), "words for a parked agent resume it");
    assert_eq!(started.lock().unwrap().len(), 2);
}

#[tokio::test(start_paused = true)]
async fn an_agent_waiting_on_someone_is_parked_too_unless_work_runs_in_its_background() {
    // Waiting on CI or a review, what it follows wakes it: no need to keep its process (and the settings it started
    // with) for days. Not while something of its own still runs in the background, which stopping it would end.
    use tokio::io::AsyncWriteExt;
    let home = temp_dir("parking-waiting");
    let started = Arc::new(Mutex::new(vec![]));
    let daemon = Daemon::open(&home.join("zerod"), silent(started.clone())).unwrap();
    let cwd = home.to_str().unwrap();
    let start = || daemon.start(Provider::Claude, "watch CI", Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let (waiting, busy) = (start(), start());
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&waiting, &busy] {
        let session = daemon.session(id).unwrap();
        session.change(Change::Item {
            item: Item {
                at: None,
                id: "a1".into(),
                turn: None,
                kind: ItemKind::Agent { text: "CI is running.\n\n[zero: waiting]".into(), final_answer: true },
                status: ItemStatus::Done,
            },
        });
        session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    }
    // The second has a subagent running on in the background.
    let line = json!({"type": "system", "subtype": "task_started", "task_id": "b1", "tool_use_id": "t9", "is_backgrounded": true})
        .to_string()
        + "\n";
    let mut runtime = started.lock().unwrap().remove(1);
    runtime.write_all(line.as_bytes()).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    minutes(PARK_AFTER.as_secs() / 60 + 1).await;
    assert!(!daemon.session(&waiting).unwrap().is_attached(), "waiting on someone, idle: parked");
    assert!(daemon.session(&busy).unwrap().is_attached(), "its background work runs on");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_agent_that_asked_the_user_is_parked_too_unless_its_process_holds_the_question() {
    // The answer comes as a message, which resumes it: no need to keep its process while the user is away. Not an
    // approval its CLI holds open, which would die with the process.
    let home = temp_dir("parking-asked");
    let started = Arc::new(Mutex::new(vec![]));
    let daemon = Daemon::open(&home.join("zerod"), silent(started.clone())).unwrap();
    let cwd = home.to_str().unwrap();
    let start = || daemon.start(Provider::Claude, "ask", Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let (asked, approving) = (start(), start());
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&asked, &approving] {
        let session = daemon.session(id).unwrap();
        session.change(Change::Item {
            item: Item {
                at: None,
                id: "a1".into(),
                turn: None,
                kind: ItemKind::Agent { text: "Which one?\n\n[zero: asked k1]".into(), final_answer: true },
                status: ItemStatus::Done,
            },
        });
        session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    }
    daemon.session(&approving).unwrap().change(Change::Approval {
        approval: Approval {
            id: "p1".into(),
            item: None,
            kind: ApprovalKind::Command,
            title: "Run ls".into(),
            command: Some("ls".into()),
            cwd: None,
            reason: None,
            changes: vec![],
            choices: vec![],
        },
    });
    minutes(PARK_AFTER.as_secs() / 60 + 1).await;
    assert!(!daemon.session(&asked).unwrap().is_attached(), "waiting on the user's answer, idle: parked");
    assert!(daemon.session(&approving).unwrap().is_attached(), "its CLI holds the approval open");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_resumes_at_once_start_one_agent() {
    let home = temp_dir("parking-race");
    let user = home.join("user");
    let started = Arc::new(Mutex::new(vec![]));
    let quiet = silent(started.clone());
    // As an agent's process does, it takes a moment to start.
    let slow: Runtime = Arc::new(move |c, d, a| {
        std::thread::sleep(Duration::from_millis(100));
        quiet(c, d, a)
    });
    let daemon = Daemon::open(&home.join("zerod"), slow).unwrap();
    daemon.place(&user);
    let cwd = home.to_str().unwrap();
    let file = zerod::handoff::claude_folder(&user, cwd).join("t1.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, json!({"type": "user", "uuid": "u1", "message": {"role": "user", "content": "hi"}}).to_string() + "\n").unwrap();
    let id = daemon.adopt(Provider::Claude, "t1", cwd, Options::default()).unwrap();
    // The app warming it up as the user types, and their message arriving: one agent between them.
    let (one, two) = (daemon.clone(), daemon.clone());
    let (first, second) = (id.clone(), id.clone());
    let (a, b) =
        tokio::join!(tokio::spawn(async move { one.resume(&first).await }), tokio::spawn(async move { two.resume(&second).await }));
    a.unwrap().unwrap();
    b.unwrap().unwrap();
    assert_eq!(started.lock().unwrap().len(), 1, "the second waits for the first, and finds it running");
}
