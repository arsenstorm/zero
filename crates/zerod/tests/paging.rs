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
    assert_eq!(ids(&summary.items), ["a49"], "its answer, for the board's Now; not the conversation");
    assert_eq!(summary.answer(), Some("answer 49"));
}
