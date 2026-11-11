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
