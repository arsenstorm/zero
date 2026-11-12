//! Sessions kept on disk start parked: a summary and their latest items (parked.json beside the transcript), not the
//! whole conversation replayed into memory. They load when something needs their conversation, and park again later.

use crate::common::temp_dir;
use tokio::sync::broadcast;
use zerod::model::*;
use zerod::session::Session;

fn kept(name: &str, turns: usize) -> std::path::PathBuf {
    let dir = temp_dir(name);
    let (events, _) = broadcast::channel(1024);
    let session = Session::new(Conversation::new("s", Provider::Claude, "/w"), Some(dir.clone()), events).unwrap();
    for n in 0..turns {
        let item = |id: String, kind| Item { id, turn: None, kind, status: ItemStatus::Done, at: None };
        session.change(Change::Item {
            item: item(format!("u{n}"), ItemKind::User { text: format!("question {n}"), images: vec![], sent: None }),
        });
        session.change(Change::Item { item: item(format!("a{n}"), ItemKind::Agent { text: format!("answer {n}"), final_answer: true }) });
    }
    dir
}

#[test]
fn a_kept_session_starts_parked_and_loads_when_its_conversation_is_wanted() {
    let dir = kept("parked", 50);
    let (events, _) = broadcast::channel(16);
    let session = Session::load(&dir, events.clone()).unwrap();
    assert!(!session.is_loaded(), "parked from the start");
    assert_eq!(session.summary().answer(), Some("answer 49"), "the board's needs, without loading");
    let (recent, earlier) = session.recent(40);
    assert_eq!((recent.items.len(), earlier, session.is_loaded()), (40, 60, false), "a snapshot's latest items too");
    assert_eq!(session.snapshot().items.len(), 100, "the whole conversation when it's wanted");
    assert!(session.is_loaded());
    session.unload();
    assert!(!session.is_loaded());
    // Parked again, it starts parked next time without replaying.
    assert!(dir.join("parked.json").exists());
    assert!(!Session::load(&dir, events).unwrap().is_loaded());
}

#[test]
fn a_park_file_behind_its_transcript_is_replayed() {
    let dir = kept("parked-stale", 2);
    let (events, _) = broadcast::channel(16);
    let session = Session::load(&dir, events.clone()).unwrap();
    session.change(Change::Title { title: Some("Renamed after parking".into()) });
    drop(session);
    // The transcript has a line parked.json doesn't: it's read again, so nothing written since is lost.
    let again = Session::load(&dir, events).unwrap();
    assert_eq!(again.summary().title.as_deref(), Some("Renamed after parking"));
}

#[test]
fn reading_its_summary_doesnt_keep_it_in_memory() {
    let dir = kept("parked-unwanted", 1);
    let (events, _) = broadcast::channel(16);
    let session = Session::load(&dir, events).unwrap();
    session.snapshot();
    std::thread::sleep(std::time::Duration::from_millis(30));
    session.summary();
    assert!(session.unwanted_for().unwrap() >= std::time::Duration::from_millis(30));
}

unsafe extern "C" {
    fn fcntl(fd: i32, cmd: i32, ...) -> i32;
}

/// Whether this process has `path` open: by each descriptor's path (F_GETPATH), as `lsof` would say.
fn open_here(path: &std::path::Path) -> bool {
    const F_GETPATH: i32 = 50;
    let want = std::fs::canonicalize(path).unwrap();
    std::fs::read_dir("/dev/fd").unwrap().filter_map(|e| e.ok()?.file_name().to_str()?.parse::<i32>().ok()).any(|fd| {
        let mut buf = [0u8; 1024];
        // Safety: F_GETPATH writes at most MAXPATHLEN (1024) bytes into buf.
        (unsafe { fcntl(fd, F_GETPATH, buf.as_mut_ptr()) } == 0)
            && std::path::Path::new(std::str::from_utf8(&buf[..buf.iter().position(|b| *b == 0).unwrap_or(0)]).unwrap_or("")) == want
    })
}

#[test]
fn a_parked_session_holds_no_file_open() {
    let dir = kept("parked-closed", 2);
    let transcript = dir.join("transcript.jsonl");
    let (events, _) = broadcast::channel(16);
    // zerod keeps every task it lists: a descriptor each ran it out of its 256.
    let session = Session::load(&dir, events.clone()).unwrap();
    assert!(!open_here(&transcript), "parked from the start");
    session.change(Change::Title { title: Some("Renamed".into()) });
    session.unload();
    assert!(!open_here(&transcript), "parked again");
    assert_eq!(Session::load(&dir, events).unwrap().summary().title.as_deref(), Some("Renamed"), "what it wrote meanwhile is kept");
}

/// Woken after it was parked, a session numbers its changes on from where it was: its streamed pieces were never
/// written down, so a replay counts fewer changes than clients have seen, and they dropped what came next as known
/// (a page froze until the count passed where it had been).
#[tokio::test]
async fn a_woken_session_numbers_on_from_where_it_was_parked() {
    use std::sync::{Arc, Mutex};
    use tokio::io::AsyncWriteExt;
    let home = crate::common::temp_dir("parked-seq");
    let started: Arc<Mutex<Vec<tokio::io::DuplexStream>>> = Arc::default();
    let runtime: zerod::daemon::Runtime = {
        let started = started.clone();
        Arc::new(move |_, _, _| {
            let (ours, theirs) = tokio::io::duplex(1 << 16);
            started.lock().unwrap().push(theirs);
            let (read, write) = tokio::io::split(ours);
            Ok(zerod::session::Transport::new(read, write))
        })
    };
    let daemon = zerod::daemon::Daemon::open(&home.join("zerod"), runtime).unwrap();
    let id = daemon
        .start(Provider::Claude, "go", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let session = daemon.session(&id).unwrap();
    let event = |e: serde_json::Value| serde_json::json!({"type": "stream_event", "api_message_id": "m1", "event": e}).to_string() + "\n";
    let mut lines = event(serde_json::json!({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}));
    for _ in 0..20 {
        lines += &event(serde_json::json!({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "w "}}));
    }
    let mut runtime_side = started.lock().unwrap().remove(0);
    runtime_side.write_all(lines.as_bytes()).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    session.stop();
    assert!(session.unload(), "offline, it parks");
    let parked_at = session.seq();
    let mut heard = daemon.subscribe();
    session.change(Change::Title { title: Some("Woken".into()) });
    let next = heard.recv().await.unwrap();
    assert_eq!(next.seq, parked_at + 1, "numbered on from where clients last saw it");
}
