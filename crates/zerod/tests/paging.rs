//! Long conversations reach the app a page at a time: its latest items first, older ones as it scrolls up to them, and
//! an outline of your messages for the rail, so neither zerod's answers nor the app's memory grow with a task's length.

use serde_json::json;
use tokio::sync::broadcast;
use zerod::model::*;
use zerod::session::Session;

/// A session with `turns` turns: your message, then the agent's answer.
fn session(turns: usize) -> Session {
    let (events, _) = broadcast::channel(1024);
    let session = Session::new(Conversation::new("s", Provider::Claude, "/w"), None, events).unwrap();
    for n in 0..turns {
        let item = |id: String, kind| Item { id, turn: None, kind, status: ItemStatus::Done, at: None };
        session.change(Change::Item { item: item(format!("u{n}"), ItemKind::User { text: format!("question {n}\nmore"), images: vec![] }) });
        session.change(Change::Item { item: item(format!("a{n}"), ItemKind::Agent { text: format!("answer {n}"), final_answer: true }) });
    }
    session
}

fn ids(items: &[Item]) -> Vec<&str> { items.iter().map(|i| i.id.as_str()).collect() }

#[test]
fn a_subscriber_gets_a_sessions_latest_items_and_how_many_came_before() {
    let (recent, earlier) = session(50).recent(40);
    assert_eq!((recent.items.len(), earlier), (40, 60));
    assert_eq!(recent.items.last().unwrap().id, "a49");
    assert_eq!(session(3).recent(40).1, 0, "a short one comes whole");
}

#[test]
fn older_items_come_a_page_at_a_time_or_all_from_one_message() {
    let session = session(50);
    let page = session.items(Some("u30"), None, 6);
    assert_eq!(ids(&page), ["u27", "a27", "u28", "a28", "u29", "a29"], "the page just before, in order");
    assert_eq!(ids(&session.items(Some("u2"), Some("u1"), 100)), ["u1", "a1"], "from a message up to what's loaded");
    assert_eq!(session.items(Some("u0"), None, 10), vec![], "nothing before the first");
}

#[test]
fn the_outline_is_each_message_of_yours_with_the_start_of_its_answer() {
    let outline = session(2).outline();
    assert_eq!(outline, json!([{"id": "u0", "text": "question 0\nmore", "answer": "answer 0"}, {"id": "u1", "text": "question 1\nmore", "answer": "answer 1"}]));
}

#[test]
fn a_summary_has_only_what_a_list_or_the_board_needs() {
    let summary = session(50).summary();
    assert_eq!(ids(&summary.items), ["u0", "a49"], "its first message, for the board's label, and its answer, for the board's Now; not the conversation");
    assert_eq!(summary.answer(), Some("answer 49"));
    // Asked again unchanged, the same; after a change, the new one (it's cached by sequence number).
    let session = session(50);
    assert_eq!(session.summary(), session.summary());
    session.change(Change::Item { item: Item { id: "a50".into(), turn: None, kind: ItemKind::Agent { text: "answer 50".into(), final_answer: true }, status: ItemStatus::Done, at: None } });
    assert_eq!(session.summary().answer(), Some("answer 50"));
}

#[test]
fn a_page_starts_at_a_message_of_yours_so_a_long_turn_comes_whole() {
    let (events, _) = broadcast::channel(1024);
    let session = Session::new(Conversation::new("s", Provider::Claude, "/w"), None, events).unwrap();
    let item = |id: &str, kind| Item { id: id.into(), turn: None, kind, status: ItemStatus::Done, at: None };
    session.change(Change::Item { item: item("u0", ItemKind::User { text: "first".into(), images: vec![] }) });
    session.change(Change::Item { item: item("u1", ItemKind::User { text: "long one".into(), images: vec![] }) });
    for n in 0..50 { session.change(Change::Item { item: item(&format!("s{n}"), ItemKind::Agent { text: format!("step {n}"), final_answer: false }) }) }
    let (recent, earlier) = session.recent(40);
    assert_eq!((recent.items.first().unwrap().id.as_str(), recent.items.len(), earlier), ("u1", 51, 1), "the whole turn, not its last 40 steps");
    let page = session.items(Some("s45"), None, 10);
    assert_eq!((page.first().unwrap().id.as_str(), page.len()), ("u1", 46), "a page back to the message its turn began with");
}
