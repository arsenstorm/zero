//! Asks over files, for agents on machines that only share a folder with the user's (a synced folder, a mount):
//! every folder matching a pattern is a drop, `asks/<id>.json` in and `answers/<id>.json` out. Ported from the Swift
//! app's DropWatcher, which this replaces.

use std::path::{Path, PathBuf};
use std::time::Duration;

use zerod::ask::{AgentIdentity, Ask, AskKind, AskState};
use zerod::drops::Drops;
use zerod::inbox::Inbox;

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("zerod-drops-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.canonicalize().unwrap()
}

fn write_ask(drop: &Path, ask: &Ask) {
    std::fs::create_dir_all(drop.join("asks")).unwrap();
    std::fs::write(drop.join("asks").join(format!("{}.json", ask.id)), serde_json::to_vec(ask).unwrap()).unwrap();
}

fn remote(kind: AskKind, id: &str) -> Ask {
    let mut ask =
        Ask::new(kind, "From the bench", AgentIdentity { name: "bench-agent".into(), host: "bench".into(), ..Default::default() }, 3600);
    ask.id = id.into();
    ask.options = vec!["Yes".into(), "No".into()];
    ask
}

async fn eventually(test: impl Fn() -> bool) {
    for _ in 0..300 {
        if test() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await
    }
    panic!("timed out");
}

fn setup(name: &str) -> (std::sync::Arc<Inbox>, std::sync::Arc<Drops>, PathBuf) {
    let root = temp(name);
    let inbox = Inbox::open(None, vec![]);
    inbox.configure(Duration::from_millis(20), 3600);
    let resources = root.join("resources");
    std::fs::create_dir_all(&resources).unwrap();
    std::fs::write(resources.join("zero-drop-linux-x86_64"), b"linux client").unwrap();
    let drops = Drops::new(inbox.clone(), resources);
    (inbox, drops, root)
}

#[tokio::test]
async fn an_ask_dropped_in_a_folder_is_asked_and_answered_back_there() {
    let (inbox, drops, root) = setup("answer");
    let drop = root.join("bench").join(".zero");
    std::fs::create_dir_all(&drop).unwrap();
    drops.set_patterns(vec![drop.to_str().unwrap().into()]);
    write_ask(&drop, &remote(AskKind::Choice, "abc234"));
    drops.scan();
    drops.scan();
    let ask = inbox.ask("abc234").expect("the drop client named it; the name is kept");
    assert_eq!(inbox.asks().len(), 1, "a file is read once");
    inbox.choose(&ask.id, 1);
    let answer = drop.join("answers/abc234.json");
    eventually(|| answer.exists()).await;
    let back: Ask = serde_json::from_slice(&std::fs::read(&answer).unwrap()).unwrap();
    assert_eq!((back.state, back.answer.as_deref()), (AskState::Answered, Some("No")));
    assert!(!drop.join("asks/abc234.json").exists());
}

#[tokio::test]
async fn a_dropped_note_is_read_and_removed_and_a_withdraw_file_withdraws() {
    let (inbox, drops, root) = setup("note");
    let drop = root.join(".zero");
    std::fs::create_dir_all(&drop).unwrap();
    drops.set_patterns(vec![drop.to_str().unwrap().into()]);
    write_ask(&drop, &remote(AskKind::Note, "note22"));
    write_ask(&drop, &remote(AskKind::Question, "quest2"));
    drops.scan();
    assert!(!drop.join("asks/note22.json").exists(), "nobody waits for a note's answer");
    assert_eq!(inbox.ask("note22").unwrap().kind, AskKind::Note);
    std::fs::write(drop.join("asks/quest2.withdraw"), "found it myself").unwrap();
    drops.scan();
    let withdrawn = inbox.ask("quest2").unwrap();
    assert_eq!((withdrawn.state, withdrawn.answer.as_deref()), (AskState::Expired, Some("found it myself")));
    assert!(!drop.join("asks/quest2.withdraw").exists());
}

#[tokio::test]
async fn patterns_find_folders_and_make_the_drop_inside_each() {
    let (_inbox, drops, root) = setup("patterns");
    for app in ["api", "web"] {
        std::fs::create_dir_all(root.join("worktrees/alpha").join(app)).unwrap()
    }
    std::fs::create_dir_all(root.join("worktrees/beta/api")).unwrap();
    std::fs::create_dir_all(root.join("worktrees/beta/notes.txt.d")).unwrap();
    // "*/*/.zero": every app folder gets a `.zero` drop, made here so the other side finds the client.
    drops.set_patterns(vec![format!("{}/worktrees/*/{{api,web}}/.zero", root.display())]);
    let mut found: Vec<String> = drops.folders().iter().map(|p| p.strip_prefix(&root).unwrap().display().to_string()).collect();
    found.sort();
    assert_eq!(found, ["worktrees/alpha/api/.zero", "worktrees/alpha/web/.zero", "worktrees/beta/api/.zero"]);
}

#[tokio::test]
async fn a_drop_holds_the_client_and_its_shim() {
    let (_inbox, drops, root) = setup("client");
    let drop = root.join(".zero");
    std::fs::create_dir_all(&drop).unwrap();
    drops.set_patterns(vec![drop.to_str().unwrap().into()]);
    drops.scan();
    assert_eq!(std::fs::read(drop.join("zero-drop-linux-x86_64")).unwrap(), b"linux client");
    let shim = std::fs::read_to_string(drop.join("zero")).unwrap();
    assert!(shim.starts_with("#!/bin/sh") && shim.contains("zero-drop-$(uname -s"), "{shim}");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(drop.join("zero")).unwrap().permissions().mode() & 0o777, 0o755);
}
