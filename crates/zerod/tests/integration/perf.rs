//! What a streaming turn costs zerod per piece of text: it mustn't grow with the conversation (a long task's thousands
//! of items copied for every word kept zerod at several percent of a core while agents worked).

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::common::temp_dir;
use serde_json::json;
use tokio::io::AsyncWriteExt;
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::*;

fn silent(started: Arc<Mutex<Vec<tokio::io::DuplexStream>>>) -> Runtime {
    Arc::new(move |_, _, _| {
        let (zero_side, runtime_side) = tokio::io::duplex(1 << 20);
        started.lock().unwrap().push(runtime_side);
        let (read, write) = tokio::io::split(zero_side);
        Ok(zerod::session::Transport::new(read, write))
    })
}

/// How long `pieces` streamed words take to reach a session that already holds `items` items.
async fn stream(name: &str, items: usize, pieces: usize) -> Duration {
    let home = temp_dir(name);
    let started = Arc::new(Mutex::new(vec![]));
    let daemon = Daemon::open(&home.join("zerod"), silent(started.clone())).unwrap();
    let id = daemon.start(Provider::Claude, "go", Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let session = daemon.session(&id).unwrap();
    for n in 0..items {
        let kind = ItemKind::Agent { text: format!("{n} {}", "x".repeat(2000)), final_answer: false };
        session.change(Change::Item { item: Item { at: None, id: format!("old-{n}"), turn: None, kind, status: ItemStatus::Done } });
    }
    let mut runtime = started.lock().unwrap().remove(0);
    let event = |event: serde_json::Value| json!({"type": "stream_event", "api_message_id": "m1", "event": event}).to_string() + "\n";
    let mut lines = event(json!({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}));
    for _ in 0..pieces {
        lines += &event(json!({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "w "}}));
    }
    let mut heard = daemon.subscribe();
    let began = Instant::now();
    runtime.write_all(lines.as_bytes()).await.unwrap();
    let mut deltas = 0;
    while deltas < pieces {
        if let Change::Delta { .. } = heard.recv().await.unwrap().change {
            deltas += 1
        }
    }
    // One thread: the daemon's own listener runs its last few before this wakes.
    tokio::time::sleep(Duration::from_millis(1)).await;
    began.elapsed()
}

#[tokio::test]
async fn streaming_costs_the_same_however_long_the_conversation() {
    let short = stream("perf-short", 0, 2000).await;
    let long = stream("perf-long", 3000, 2000).await;
    eprintln!("2000 pieces: {short:?} into an empty conversation, {long:?} into one of 3000 items");
    assert!(long < short * 4 + Duration::from_millis(200), "{long:?} against {short:?}");
}

#[tokio::test]
async fn the_inbox_looking_at_who_still_runs_leaves_a_parked_task_out_of_memory() {
    // Every few seconds, for every task with an ask: a task the user hasn't opened stays a summary on disk.
    use zerod::inbox::Runtime as _;
    let home = temp_dir("perf-liveness");
    let (events, _) = tokio::sync::broadcast::channel(16);
    let dir = home.join("zerod/sessions/s1");
    let session = zerod::session::Session::new(Conversation::new("s1", Provider::Claude, "/w"), Some(dir), events).unwrap();
    session.change(Change::Named { label: Some("Release".into()), ticket: None });
    session.change(Change::Status { status: Status::Offline, turn: None, error: None });
    drop(session);
    let daemon = Daemon::open(&home.join("zerod"), silent(Default::default())).unwrap();
    let agent = zerod::ask::AgentIdentity {
        name: "zerod-s1".into(),
        runtime: Some("zerod".into()),
        reference: Some("s1".into()),
        ..Default::default()
    };
    let sessions = zerod::daemon::Sessions::of(&daemon);
    let agents = [agent.clone()];
    assert_eq!(sessions.offline(&agents).await.len(), 1);
    assert!(sessions.gone(&agents).await.is_empty());
    assert_eq!(sessions.display_name(&agent).await.as_deref(), Some("Release"));
    assert!(!daemon.session("s1").unwrap().is_loaded(), "read from its summary, not loaded");
}
