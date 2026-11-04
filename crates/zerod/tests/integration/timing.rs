//! When each step happened: an item is stamped the first time zerod sees it and keeps that time as it updates, so the
//! app can say when a message was sent and how long a turn worked. The times are kept, and a restart replays them.


use crate::common::temp_dir;
use serde_json::json;
use tokio::sync::broadcast;
use zerod::core::Core;
use zerod::model::*;
use zerod::session::Session;

fn item(id: &str, status: ItemStatus) -> Item {
    Item { id: id.into(), turn: None, kind: ItemKind::Agent { text: "hi".into(), final_answer: false }, status, at: None }
}

#[test]
fn an_item_keeps_the_time_it_was_first_seen() {
    let mut core = Core::new(Conversation::new("s", Provider::Claude, "/w"));
    core.at(1_000);
    core.change(Change::Item { item: item("a", ItemStatus::Running) });
    core.at(5_000);
    let updated = core.change(Change::Item { item: item("a", ItemStatus::Done) });
    assert!(matches!(&updated, Change::Item { item } if item.at == Some(1_000)), "the update carries the first time to clients: {updated:?}");
    core.change(Change::Item { item: item("b", ItemStatus::Done) });
    let times: Vec<Option<i64>> = core.conversation().items.iter().map(|i| i.at).collect();
    assert_eq!(times, [Some(1_000), Some(5_000)]);
}

#[test]
fn times_are_kept_across_a_restart() {
    let dir = temp_dir("timing-kept");
    let (events, _) = broadcast::channel(16);
    let session = Session::new(Conversation::new("s", Provider::Claude, "/w"), Some(dir.clone()), events.clone()).unwrap();
    session.change(Change::Item { item: item("a", ItemStatus::Done) });
    let at = session.snapshot().items[0].at.expect("stamped as it happened");
    let again = Session::load(&dir, events).unwrap();
    assert_eq!(again.snapshot().items[0].at, Some(at));
}

#[test]
fn a_claude_code_session_files_own_times_come_with_its_items() {
    let records = [
        json!({"type": "user", "uuid": "u1", "timestamp": "2026-10-27T12:23:52.151Z", "message": {"role": "user", "content": "Go"}}),
        json!({"type": "assistant", "uuid": "a1", "timestamp": "2026-10-27T12:25:02.000Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "Done."}]}}),
    ];
    let items = zerod::handoff::from_claude_session(&records);
    assert_eq!(items.iter().map(|i| i.at).collect::<Vec<_>>(), [Some(1_793_103_832_151), Some(1_793_103_902_000)]);
}
