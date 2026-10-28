//! Images with a message: each provider gets them its own way (Claude and OpenCode as data, Codex as a file), and the
//! message in the conversation keeps their files, so the app shows them, a restart included.

mod common;

use common::{temp_dir, play};
use serde_json::json;
use tokio::sync::broadcast;
use zerod::core::Core;
use zerod::model::*;
use zerod::session::Session;

#[test]
fn the_images_go_on_the_next_message_of_yours_seen() {
    let mut core = Core::new(Conversation::new("s", Provider::Codex, "/w"));
    core.attach(vec!["/tmp/shot.png".into()]);
    core.change(Change::Item { item: Item { id: "a".into(), turn: None, kind: ItemKind::Agent { text: "hi".into(), final_answer: false }, status: ItemStatus::Done, at: None } });
    core.change(Change::Item { item: Item { id: "u".into(), turn: None, kind: ItemKind::User { text: "look".into(), images: vec![] }, status: ItemStatus::Done, at: None } });
    core.change(Change::Item { item: Item { id: "v".into(), turn: None, kind: ItemKind::User { text: "and this".into(), images: vec![] }, status: ItemStatus::Done, at: None } });
    let images: Vec<Vec<String>> = core.conversation().items.iter().filter_map(|i| match &i.kind { ItemKind::User { images, .. } => Some(images.clone()), _ => None }).collect();
    assert_eq!(images, [vec!["/tmp/shot.png".to_string()], vec![]], "once, on the first message of yours after them");
}

#[test]
fn each_provider_gets_images_its_own_way() {
    let dir = temp_dir("images-files");
    let png = dir.join("shot.png");
    std::fs::write(&png, [0x89, b'P', b'N', b'G']).unwrap();
    let path = png.to_str().unwrap().to_string();
    assert_eq!(zerod::claude::user_message("look", std::slice::from_ref(&path)), json!({"type": "user", "message": {"role": "user", "content": [
        {"type": "text", "text": "look"},
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw=="}},
    ]}}));
    assert_eq!(zerod::claude::user_message("look", &[]), json!({"type": "user", "message": {"role": "user", "content": "look"}}), "no images: as before");
    assert_eq!(zerod::codex::input("look", std::slice::from_ref(&path)), json!([{"type": "text", "text": "look", "text_elements": []}, {"type": "localImage", "path": path}]));
    assert_eq!(zerod::acp::blocks("look", std::slice::from_ref(&path)), json!([{"type": "text", "text": "look"}, {"type": "image", "mimeType": "image/png", "data": "iVBORw=="}]));
}

#[tokio::test]
async fn a_message_with_an_image_keeps_it_through_a_restart() {
    let dir = temp_dir("images-kept");
    let (events, _) = broadcast::channel(64);
    let session = Session::new(Conversation::new("s1", Provider::Claude, "/work/project"), Some(dir.clone()), events.clone()).unwrap();
    let (transport, _recorder) = play(vec![json!({"out": {"type": "user"}})]);
    session.attach(transport);
    let png = dir.join("shot.png");
    std::fs::write(&png, [1, 2, 3]).unwrap();
    session.send_with_images("what's this?", &[png.to_str().unwrap().to_string()], None, None).await.unwrap();
    let mine = |conversation: &Conversation| conversation.items.iter().find_map(|i| match &i.kind { ItemKind::User { images, .. } => Some(images.clone()), _ => None });
    assert_eq!(mine(&session.snapshot()), Some(vec![png.to_str().unwrap().to_string()]));
    let again = Session::load(&dir, events).unwrap();
    assert_eq!(mine(&again.snapshot()), Some(vec![png.to_str().unwrap().to_string()]));
}

#[tokio::test]
async fn a_task_starts_with_images_as_any_message_has_them() {
    let dir = temp_dir("images-start");
    let (events, _) = broadcast::channel(64);
    let session = Session::new(Conversation::new("s1", Provider::Claude, "/work/project"), Some(dir.clone()), events).unwrap();
    let png = dir.join("shot.png");
    std::fs::write(&png, [1, 2, 3]).unwrap();
    let path = png.to_str().unwrap().to_string();
    let (transport, recorder) = play(vec![json!({"out": {"type": "user"}})]);
    session.start_with_images(transport, "what's this?", std::slice::from_ref(&path), None, None).await.unwrap();
    let sent = recorder.said("user", 1).await;
    assert_eq!(sent[0]["message"]["content"][1]["type"], "image", "{}", sent[0]);
    let mine = session.snapshot().items.iter().find_map(|i| match &i.kind { ItemKind::User { images, .. } => Some(images.clone()), _ => None });
    assert_eq!(mine, Some(vec![path]));
}
