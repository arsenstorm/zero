//! Going back to a message of yours, in any provider: the conversation as it was just before it (the provider given a
//! thread made from Zero's record up to there), the folder as it was when it was sent if wanted, or a new task branched
//! from there that leaves this one as it is.

use std::path::Path;
use std::process::Command;
use std::sync::Arc;

use crate::common::temp_dir;
use serde_json::json;
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::*;

fn quiet() -> Runtime {
    Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())))
}

fn git(dir: &Path, args: &[&str]) {
    // The fixture's own commits unsigned: the user's global config may sign through an agent that's locked.
    assert!(
        Command::new("git").args(["-c", "commit.gpgsign=false"]).args(args).current_dir(dir).output().unwrap().status.success(),
        "git {args:?}"
    );
}

/// A Claude Code session of two turns, taken in from a git folder.
fn task(name: &str) -> (Arc<Daemon>, String, std::path::PathBuf, std::path::PathBuf) {
    let home = temp_dir(name);
    let (user, project) = (home.join("user"), home.join("project"));
    std::fs::create_dir_all(&project).unwrap();
    git(&project, &["init", "-q"]);
    std::fs::write(project.join("a.txt"), "one\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "start"]);
    let daemon = Daemon::open(&home.join("zerod"), quiet()).unwrap();
    daemon.place(&user);
    let cwd = project.to_str().unwrap();
    let file = zerod::handoff::claude_folder(&user, cwd).join("t1.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let said = |uuid: &str, role: &str, text: &str| json!({"type": role, "uuid": uuid, "message": {"role": role, "content": [{"type": "text", "text": text}]}});
    let records = [
        said("u1", "user", "first"),
        said("a1", "assistant", "done one"),
        said("u2", "user", "second"),
        said("a2", "assistant", "done two"),
    ];
    std::fs::write(&file, records.iter().map(|r| r.to_string() + "\n").collect::<String>()).unwrap();
    let id = daemon.adopt(Provider::Claude, "t1", cwd, Options { label: Some("Fix it".into()), ..Default::default() }).unwrap();
    (daemon, id, project, user)
}

fn texts(conversation: &Conversation) -> Vec<String> {
    conversation
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::User { text, .. } | ItemKind::Agent { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect()
}

fn message(daemon: &Daemon, id: &str, text: &str) -> String {
    daemon.get(id).unwrap().items.iter().find(|i| matches!(&i.kind, ItemKind::User { text: t, .. } if t == text)).unwrap().id.clone()
}

#[tokio::test]
async fn rewinding_takes_the_conversation_back_and_can_bring_the_folder_back() {
    let (daemon, id, project, user) = task("rewind");
    let second = message(&daemon, &id, "second");
    daemon.snapshot_for(&id, &second).expect("the folder kept when the message went");
    // What the agent did after it.
    std::fs::write(project.join("a.txt"), "one\nchanged\n").unwrap();
    std::fs::write(project.join("b.txt"), "new\n").unwrap();

    let preview = daemon.rewind_preview(&id, &second).unwrap();
    assert_eq!((preview["snapshot"].as_bool(), preview["files"].as_u64()), (Some(true), Some(2)));

    let rewound = daemon.rewind(&id, &second, zerod::daemon::Rewind::Both).await.unwrap();
    assert_eq!(rewound["text"], "second", "the message, to send again or change");
    assert_eq!(texts(&daemon.get(&id).unwrap()), ["first", "done one"]);
    assert_eq!(std::fs::read_to_string(project.join("a.txt")).unwrap(), "one\n");
    assert!(!project.join("b.txt").exists());

    // Claude Code resumes a thread of its own made from Zero's record up to there.
    let thread = daemon.get(&id).unwrap().thread.unwrap();
    assert_ne!(thread, "t1");
    let file = zerod::handoff::claude_folder(&user, project.to_str().unwrap()).join(format!("{thread}.jsonl"));
    assert!(std::fs::read_to_string(file).unwrap().contains("done one"));

    // Kept: zerod's next start has it rewound.
    let again = Daemon::open(&project.parent().unwrap().join("zerod"), quiet()).unwrap();
    assert_eq!(texts(&again.get(&id).unwrap()), ["first", "done one"]);
}

#[tokio::test]
async fn the_preview_names_the_files_changed_and_the_messages_that_go() {
    let (daemon, id, project, _) = task("rewind-preview");
    let second = message(&daemon, &id, "second");
    daemon.snapshot_for(&id, &second).unwrap();
    std::fs::write(project.join("a.txt"), "one\nchanged\n").unwrap();
    std::fs::write(project.join("b.txt"), "new\n").unwrap();
    let preview = daemon.rewind_preview(&id, &second).unwrap();
    assert_eq!(preview["messages"], 2, "the message and its answer");
    let changes: Vec<(&str, u64, u64)> = preview["changes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["path"].as_str().unwrap(), c["insertions"].as_u64().unwrap(), c["deletions"].as_u64().unwrap()))
        .collect();
    assert_eq!(changes, [("a.txt", 1, 0), ("b.txt", 1, 0)]);
}

#[tokio::test]
async fn a_rewind_can_be_undone_conversation_and_files() {
    let (daemon, id, project, _) = task("rewind-undo");
    let second = message(&daemon, &id, "second");
    daemon.snapshot_for(&id, &second).unwrap();
    std::fs::write(project.join("a.txt"), "one\nchanged\n").unwrap();
    std::fs::write(project.join("b.txt"), "new\n").unwrap();

    let rewound = daemon.rewind(&id, &second, zerod::daemon::Rewind::Both).await.unwrap();
    let undo = rewound["undo"].as_str().expect("the folder as it was before the rewind");
    assert_eq!(texts(&daemon.get(&id).unwrap()).len(), 2);

    daemon.unrewind(&id, Some(undo), true).await.unwrap();
    let back = daemon.get(&id).unwrap();
    assert_eq!(texts(&back), ["first", "done one", "second", "done two"]);
    assert_eq!(back.thread.as_deref(), Some("t1"), "on its own thread again, which has it all");
    assert!(back.snapshots.contains_key(&second), "the message's snapshot back with it");
    assert_eq!(std::fs::read_to_string(project.join("a.txt")).unwrap(), "one\nchanged\n");
    assert_eq!(std::fs::read_to_string(project.join("b.txt")).unwrap(), "new\n");
    assert!(daemon.unrewind(&id, None, true).await.is_err(), "once");

    // Kept: zerod's next start has it undone.
    let again = Daemon::open(&project.parent().unwrap().join("zerod"), quiet()).unwrap();
    assert_eq!(texts(&again.get(&id).unwrap()).len(), 4);
}

#[tokio::test]
async fn a_rewind_said_over_since_isnt_undone() {
    let (daemon, id, _, _) = task("rewind-undo-late");
    let second = message(&daemon, &id, "second");
    daemon.rewind(&id, &second, zerod::daemon::Rewind::Conversation).await.unwrap();
    daemon.sessions().into_iter().find(|s| s.id() == id).unwrap().change(Change::Item {
        item: Item {
            at: None,
            id: "later".into(),
            turn: None,
            kind: ItemKind::User { text: "something else".into(), images: vec![], sent: None },
            status: ItemStatus::Done,
        },
    });
    assert!(daemon.unrewind(&id, None, true).await.is_err());
    assert_eq!(texts(&daemon.get(&id).unwrap()), ["first", "done one", "something else"]);
}

#[tokio::test]
async fn rewinding_only_the_conversation_leaves_the_folder_and_the_first_message_starts_afresh() {
    let (daemon, id, project, _) = task("rewind-first");
    let first = message(&daemon, &id, "first");
    std::fs::write(project.join("a.txt"), "agent's\n").unwrap();
    assert!(daemon.rewind(&id, &first, zerod::daemon::Rewind::Code).await.is_err(), "no snapshot of the folder for it");
    daemon.rewind(&id, &first, zerod::daemon::Rewind::Conversation).await.unwrap();
    let task = daemon.get(&id).unwrap();
    assert!(task.items.is_empty());
    assert_eq!(task.thread, None, "nothing to resume: the next message starts a new thread");
    assert_eq!(std::fs::read_to_string(project.join("a.txt")).unwrap(), "agent's\n", "the folder stays as it is");
}

#[tokio::test]
async fn only_a_message_of_yours_can_be_gone_back_to() {
    let (daemon, id, _, _) = task("rewind-answer");
    let answer = daemon.get(&id).unwrap().items.iter().find(|i| matches!(i.kind, ItemKind::Agent { .. })).unwrap().id.clone();
    assert!(daemon.rewind(&id, &answer, zerod::daemon::Rewind::Conversation).await.is_err());
    assert!(daemon.branch(&id, &answer).is_err());
}

#[tokio::test]
async fn a_branch_is_a_new_task_from_before_the_message_and_this_one_stays() {
    let (daemon, id, project, _) = task("branch");
    let second = message(&daemon, &id, "second");
    daemon.snapshot_for(&id, &second).unwrap();
    let branched = daemon.branch(&id, &second).unwrap();
    assert_eq!(branched["text"], "second");
    let branch = daemon.get(branched["session"].as_str().unwrap()).unwrap();
    assert_eq!(texts(&branch), ["first", "done one"]);
    assert_eq!(
        (branch.cwd.as_str(), branch.label.as_deref(), branch.provider),
        (project.to_str().unwrap(), Some("Fix it (branch)"), Provider::Claude)
    );
    assert!(branch.thread.is_some_and(|t| t != "t1"), "a thread of its own");
    assert_eq!(texts(&daemon.get(&id).unwrap()).len(), 4, "the original is as it was");
}

#[test]
fn opencode_gets_the_earlier_conversation_as_context_not_as_your_words() {
    let mut core = zerod::core::Core::new(Conversation::new("s", Provider::Opencode, "/w"));
    core.sent(&json!({"jsonrpc": "2.0", "id": "z1", "method": "session/prompt", "params": {"sessionId": "o1", "prompt": [
        {"type": "text", "text": "User: first\n\nYou: done one", "_meta": {"zero": "context"}}, {"type": "text", "text": "second"}]}}));
    assert_eq!(texts(core.conversation()), ["second"]);
}
