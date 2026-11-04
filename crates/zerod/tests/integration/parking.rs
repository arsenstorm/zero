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
    for _ in 0..n * 4 { tokio::time::sleep(Duration::from_secs(15)).await }
}

#[tokio::test(start_paused = true)]
async fn an_idle_agent_is_parked_and_woken_by_words_for_it() {
    let home = temp_dir("parking");
    let user = home.join("user");
    let started = Arc::new(Mutex::new(vec![]));
    let daemon = Daemon::open(&home.join("zerod"), silent(started.clone())).unwrap();
    daemon.place(&user, &home.join("host.sock"));
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
    for _ in 0..20 { if session.is_attached() { break } tokio::time::sleep(Duration::from_millis(50)).await }
    assert!(session.is_attached(), "words for a parked agent resume it");
    assert_eq!(started.lock().unwrap().len(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_resumes_at_once_start_one_agent() {
    let home = temp_dir("parking-race");
    let user = home.join("user");
    let started = Arc::new(Mutex::new(vec![]));
    let quiet = silent(started.clone());
    // As an agent's process does, it takes a moment to start.
    let slow: Runtime = Arc::new(move |c, d, a| { std::thread::sleep(Duration::from_millis(100)); quiet(c, d, a) });
    let daemon = Daemon::open(&home.join("zerod"), slow).unwrap();
    daemon.place(&user, &home.join("host.sock"));
    let cwd = home.to_str().unwrap();
    let file = zerod::handoff::claude_folder(&user, cwd).join("t1.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, json!({"type": "user", "uuid": "u1", "message": {"role": "user", "content": "hi"}}).to_string() + "\n").unwrap();
    let id = daemon.adopt(Provider::Claude, "t1", cwd, Options::default()).unwrap();
    // The app warming it up as the user types, and their message arriving: one agent between them.
    let (one, two) = (daemon.clone(), daemon.clone());
    let (first, second) = (id.clone(), id.clone());
    let (a, b) = tokio::join!(tokio::spawn(async move { one.resume(&first).await }), tokio::spawn(async move { two.resume(&second).await }));
    a.unwrap().unwrap();
    b.unwrap().unwrap();
    assert_eq!(started.lock().unwrap().len(), 1, "the second waits for the first, and finds it running");
}
