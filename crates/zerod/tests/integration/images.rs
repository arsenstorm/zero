//! Images with a message: each provider gets them its own way (Claude and OpenCode as data, Codex as a file), and the
//! message in the conversation keeps their files, so the app shows them, a restart included.

use crate::common::{play, temp_dir};
use serde_json::json;
use tokio::sync::broadcast;
use zerod::core::Core;
use zerod::model::*;
use zerod::session::Session;

#[test]
fn the_images_go_on_the_next_message_of_yours_seen() {
    let mut core = Core::new(Conversation::new("s", Provider::Codex, "/w"));
    core.attach(vec!["/tmp/shot.png".into()]);
    core.change(Change::Item {
        item: Item {
            id: "a".into(),
            turn: None,
            kind: ItemKind::Agent { text: "hi".into(), final_answer: false },
            status: ItemStatus::Done,
            at: None,
        },
    });
    core.change(Change::Item {
        item: Item {
            id: "u".into(),
            turn: None,
            kind: ItemKind::User { text: "look".into(), images: vec![], sent: None },
            status: ItemStatus::Done,
            at: None,
        },
    });
    core.change(Change::Item {
        item: Item {
            id: "v".into(),
            turn: None,
            kind: ItemKind::User { text: "and this".into(), images: vec![], sent: None },
            status: ItemStatus::Done,
            at: None,
        },
    });
    let images: Vec<Vec<String>> = core
        .conversation()
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::User { images, .. } => Some(images.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(images, [vec!["/tmp/shot.png".to_string()], vec![]], "once, on the first message of yours after them");
}

#[test]
fn each_provider_gets_images_its_own_way() {
    let dir = temp_dir("images-files");
    let png = dir.join("shot.png");
    std::fs::write(&png, [0x89, b'P', b'N', b'G']).unwrap();
    let path = png.to_str().unwrap().to_string();
    assert_eq!(
        zerod::claude::user_message("look", std::slice::from_ref(&path)),
        json!({"type": "user", "message": {"role": "user", "content": [
            {"type": "text", "text": "look"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw=="}},
        ]}})
    );
    assert_eq!(
        zerod::claude::user_message("look", &[]),
        json!({"type": "user", "message": {"role": "user", "content": "look"}}),
        "no images: as before"
    );
    assert_eq!(
        zerod::codex::input("look", std::slice::from_ref(&path)),
        json!([{"type": "text", "text": "look", "text_elements": []}, {"type": "localImage", "path": path}])
    );
    assert_eq!(
        zerod::acp::blocks("look", std::slice::from_ref(&path)),
        json!([{"type": "text", "text": "look"}, {"type": "image", "mimeType": "image/png", "data": "iVBORw=="}])
    );
}

/// A tiny PNG made `width`×`height` by sips, as a screenshot would be.
fn picture(dir: &std::path::Path, name: &str, width: u32, height: u32) -> String {
    const ONE: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
    let path = dir.join(name);
    std::fs::write(&path, zerod::images::unbase64(ONE).unwrap()).unwrap();
    let done =
        std::process::Command::new("/usr/bin/sips").args(["-z", &height.to_string(), &width.to_string()]).arg(&path).output().unwrap();
    assert!(done.status.success());
    path.to_str().unwrap().to_string()
}

fn size(path: &str) -> (u32, u32) {
    let out = std::process::Command::new("/usr/bin/sips").args(["-g", "pixelWidth", "-g", "pixelHeight", path]).output().unwrap();
    let words: Vec<u32> = String::from_utf8_lossy(&out.stdout).split_whitespace().filter_map(|w| w.parse().ok()).collect();
    (words[0], words[1])
}

#[test]
fn a_big_image_goes_to_the_agent_at_most_1600_a_side_its_file_kept_as_it_was() {
    // Claude Code keeps recent messages word for word through compacting, images too: full-size screenshots fill a
    // fresh context. The agent gets a JPEG copy at most 1600 px a side; the user's file stays as it was.
    let dir = temp_dir("images-big");
    let big = picture(&dir, "shot.png", 3000, 2000);
    let small = picture(&dir, "small.png", 800, 600);
    let before = std::fs::read(&big).unwrap();
    let message = zerod::claude::user_message("look", &[big.clone(), small.clone()]);
    let image = &message["message"]["content"][1]["source"];
    assert_eq!(image["media_type"], "image/jpeg");
    let sent = dir.join("sent.jpg");
    std::fs::write(&sent, zerod::images::unbase64(image["data"].as_str().unwrap()).unwrap()).unwrap();
    assert_eq!(size(sent.to_str().unwrap()), (1600, 1066));
    assert_eq!(std::fs::read(&big).unwrap(), before, "the original kept");
    assert_eq!(message["message"]["content"][2]["source"]["media_type"], "image/png", "a small one as it is");
    let input = zerod::codex::input("look", &[big.clone(), small.clone()]);
    let path = input[1]["path"].as_str().unwrap();
    assert_ne!(path, big, "Codex gets the copy's file");
    assert_eq!(size(path), (1600, 1066));
    assert_eq!(input[2]["path"], small.as_str());
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
    session
        .send(
            zerod::session::Message { text: "what's this?", images: &[png.to_str().unwrap().to_string()], context: None, sent: None },
            Default::default(),
        )
        .await
        .unwrap();
    let mine = |conversation: &Conversation| {
        conversation.items.iter().find_map(|i| match &i.kind {
            ItemKind::User { images, .. } => Some(images.clone()),
            _ => None,
        })
    };
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
    session
        .start(
            transport,
            zerod::session::Message { text: "what's this?", images: std::slice::from_ref(&path), context: None, sent: None },
            Default::default(),
        )
        .await
        .unwrap();
    let sent = recorder.said("user", 1).await;
    assert_eq!(sent[0]["message"]["content"][1]["type"], "image", "{}", sent[0]);
    let mine = session.snapshot().items.iter().find_map(|i| match &i.kind {
        ItemKind::User { images, .. } => Some(images.clone()),
        _ => None,
    });
    assert_eq!(mine, Some(vec![path]));
}

#[test]
fn an_image_goes_where_its_token_stands_in_the_words() {
    let dir = temp_dir("images-tokens");
    let (a, b) = (dir.join("a.png"), dir.join("b.png"));
    std::fs::write(&a, [0x89, b'P', b'N', b'G']).unwrap();
    std::fs::write(&b, [1, 2, 3]).unwrap();
    let images = vec![a.to_str().unwrap().to_string(), b.to_str().unwrap().to_string()];
    let image = |path: &str| json!({"type": "localImage", "path": path});
    let text = |t: &str| json!({"type": "text", "text": t, "text_elements": []});
    // Each token keeps its place in the words (the agent calls the image by its number), its image right after it.
    assert_eq!(
        zerod::codex::input("Look at [Image #2], then [Image #1]. Done", &images),
        json!([text("Look at [Image #2]"), image(&images[1]), text(", then [Image #1]"), image(&images[0]), text(". Done")])
    );
    // Images never named come after the words, as before; a number with no image stays words.
    assert_eq!(
        zerod::codex::input("see [Image #1] and [Image #3]", &images),
        json!([text("see [Image #1]"), image(&images[0]), text(" and [Image #3]"), image(&images[1])])
    );
    // The same order for Claude and OpenCode.
    let claude = zerod::claude::user_message("[Image #1] first", &images);
    let kinds: Vec<&str> = claude["message"]["content"].as_array().unwrap().iter().map(|p| p["type"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["text", "image", "text", "image"]);
    assert_eq!(claude["message"]["content"][0]["text"], "[Image #1]");
    let acp = zerod::acp::blocks("[Image #2] first", &images);
    assert_eq!(acp[1]["data"], "AQID", "the second image, right after its token");
}

#[tokio::test]
async fn the_message_of_yours_keeps_its_words_beside_its_images() {
    let dir = temp_dir("images-words");
    let (events, _) = broadcast::channel(64);
    let session = Session::new(Conversation::new("s1", Provider::Claude, "/work/project"), Some(dir.clone()), events).unwrap();
    let (transport, _recorder) = play(vec![json!({"out": {"type": "user"}})]);
    session.attach(transport);
    let png = dir.join("shot.png");
    std::fs::write(&png, [1, 2, 3]).unwrap();
    session
        .send(
            zerod::session::Message {
                text: "what's [Image #1] here?",
                images: &[png.to_str().unwrap().to_string()],
                context: None,
                sent: None,
            },
            Default::default(),
        )
        .await
        .unwrap();
    let words = session.snapshot().items.iter().find_map(|i| match &i.kind {
        ItemKind::User { text, .. } => Some(text.clone()),
        _ => None,
    });
    assert_eq!(words.as_deref(), Some("what's [Image #1] here?"));
}
