//! Bringing work in and putting it away: a Claude Code session started elsewhere (another tool's agent) becomes a task,
//! its history read from its session file, resumed on its own thread by the next message; a task archived leaves the
//! list but stays on disk.

mod common;

use std::sync::Arc;

use common::temp_dir;
use serde_json::json;
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::*;

fn quiet() -> Runtime { Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink()))) }

#[tokio::test]
async fn a_claude_code_session_from_elsewhere_becomes_a_task_with_its_history() {
    let home = temp_dir("adopt");
    let (user, project) = (home.join("user"), home.join("project"));
    std::fs::create_dir_all(&project).unwrap();
    let daemon = Daemon::open(&home.join("zerod"), quiet()).unwrap();
    daemon.place(&user, &home.join("host.sock"));
    let cwd = project.to_str().unwrap();
    let file = zerod::handoff::claude_folder(&user, cwd).join("5cb4036a-0000.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let records = [
        json!({"type": "user", "uuid": "u1", "message": {"role": "user", "content": "Read SUPERVISE.md and follow it for ENG-9767"}}),
        json!({"type": "assistant", "uuid": "a1", "message": {"role": "assistant", "content": [{"type": "text", "text": "Claimed green-elk."}]}}),
    ];
    std::fs::write(&file, records.iter().map(|r| r.to_string() + "\n").collect::<String>()).unwrap();

    let options = Options { label: Some("ENG-9767 Webhooks".into()), ticket: Some("ENG-9767".into()), ..Default::default() };
    let id = daemon.adopt(Provider::Claude, "5cb4036a-0000", cwd, options.clone()).unwrap();
    let task = daemon.get(&id).unwrap();
    assert_eq!((task.status, task.thread.as_deref(), task.ticket.as_deref(), task.label.as_deref()),
               (Status::Offline, Some("5cb4036a-0000"), Some("ENG-9767"), Some("ENG-9767 Webhooks")), "taken in offline, on the session's own thread");
    let texts: Vec<&str> = task.items.iter().filter_map(|i| match &i.kind { ItemKind::User { text } | ItemKind::Agent { text, .. } => Some(text.as_str()), _ => None }).collect();
    assert_eq!(texts, ["Read SUPERVISE.md and follow it for ENG-9767", "Claimed green-elk."]);
    assert_eq!(daemon.adopt(Provider::Claude, "5cb4036a-0000", cwd, options.clone()).unwrap(), id, "the same session is one task");
    assert_eq!(daemon.adopt(Provider::Claude, "nope", cwd, options).unwrap_err(), format!("No Claude Code session nope in {cwd}"));

    // Kept as any task is: another start of zerod has it, history and all.
    let again = Daemon::open(&home.join("zerod"), quiet()).unwrap();
    assert_eq!(again.get(&id).unwrap().items.len(), task.items.len());
}

#[tokio::test]
async fn an_archived_task_leaves_the_list_and_keeps_its_files() {
    let home = temp_dir("archive");
    let daemon = Daemon::open(&home.join("zerod"), quiet()).unwrap();
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "hi", None, None, Permissions::Auto).unwrap();
    let mut events = daemon.subscribe();
    daemon.archive(&id).await.unwrap();
    assert!(daemon.get(&id).is_none());
    assert!(home.join("zerod/archive").join(&id).join("meta.json").exists(), "kept under archive/, where it can be brought back");
    let gone = loop { let event = events.recv().await.unwrap(); if event.change == Change::Archived { break event } };
    assert_eq!(gone.session, id, "clients are told it's gone");
    assert!(Daemon::open(&home.join("zerod"), quiet()).unwrap().get(&id).is_none());
    assert_eq!(daemon.archive(&id).await.unwrap_err(), format!("No session {id}"));
}
