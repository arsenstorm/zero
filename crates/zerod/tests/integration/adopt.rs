//! Bringing work in and putting it away: a Claude Code session started elsewhere (another tool's agent) becomes a task,
//! its history read from its session file, resumed on its own thread by the next message; a task archived leaves the
//! list but stays on disk.

use std::sync::Arc;

use crate::common::temp_dir;
use serde_json::json;
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::*;

fn quiet() -> Runtime {
    Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())))
}

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
    assert_eq!(
        (task.status, task.thread.as_deref(), task.ticket.as_deref(), task.label.as_deref()),
        (Status::Offline, Some("5cb4036a-0000"), Some("ENG-9767"), Some("ENG-9767 Webhooks")),
        "taken in offline, on the session's own thread"
    );
    let texts: Vec<&str> = task
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::User { text, .. } | ItemKind::Agent { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
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
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    let mut events = daemon.subscribe();
    daemon.archive(&id).await.unwrap();
    assert!(daemon.get(&id).is_none());
    assert!(home.join("zerod/archive").join(&id).join("meta.json").exists(), "kept under archive/, where it can be brought back");
    let gone = loop {
        let event = events.recv().await.unwrap();
        if event.change == Change::Archived {
            break event;
        }
    };
    assert_eq!(gone.session, id, "clients are told it's gone");
    assert!(Daemon::open(&home.join("zerod"), quiet()).unwrap().get(&id).is_none());
    assert_eq!(daemon.archive(&id).await.unwrap_err(), format!("No session {id}"));
}

/// The archive is listed from an index (archive.json), kept as tasks go and come back, not by reading every archived
/// folder: hundreds of them took tens of milliseconds a call. Missing, or older than the archive, it's rebuilt.
#[tokio::test]
async fn the_archive_is_listed_from_an_index_rebuilt_when_missing_or_stale() {
    let home = temp_dir("archive-index");
    let zerod = home.join("zerod");
    let daemon = Daemon::open(&zerod, quiet()).unwrap();
    let start = |prompt: &str| {
        daemon
            .start(Provider::Claude, prompt, zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
            .unwrap()
    };
    let (one, two) = (start("one"), start("two"));
    daemon.archive(&one).await.unwrap();
    daemon.archive(&two).await.unwrap();
    let ids = |daemon: &Daemon| daemon.archived(100).iter().map(|a| a["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    assert_eq!(ids(&daemon), [two.clone(), one.clone()]);
    let index: serde_json::Value =
        serde_json::from_slice(&std::fs::read(zerod.join("archive.json")).expect("the index is written as tasks are archived")).unwrap();
    assert_eq!(index.as_array().map(Vec::len), Some(2), "{index}");

    daemon.unarchive(&one).unwrap();
    assert_eq!(ids(&daemon), vec![two.clone()], "brought back, it leaves the index");
    assert_eq!(ids(&Daemon::open(&zerod, quiet()).unwrap()), vec![two.clone()], "another zerod reads the index");

    // A folder archived by a zerod that kept no index: the archive is newer than the index, which is rebuilt.
    std::thread::sleep(std::time::Duration::from_millis(10));
    std::fs::create_dir_all(zerod.join("archive/old")).unwrap();
    std::fs::copy(zerod.join("archive").join(&two).join("meta.json"), zerod.join("archive/old/meta.json")).unwrap();
    assert_eq!(ids(&Daemon::open(&zerod, quiet()).unwrap()).len(), 2, "the stale index is rebuilt from the folders");
    std::fs::remove_file(zerod.join("archive.json")).unwrap();
    assert_eq!(ids(&Daemon::open(&zerod, quiet()).unwrap()).len(), 2, "a missing one too");
}

#[tokio::test]
async fn a_lead_adopts_tasks_and_claude_code_sessions_as_its_workers() {
    let home = temp_dir("adopt-workers");
    let (user, project) = (home.join("user"), home.join("project"));
    std::fs::create_dir_all(&project).unwrap();
    let daemon = Daemon::open(&home.join("zerod"), quiet()).unwrap();
    daemon.place(&user, &home.join("host.sock"));
    let cwd = project.to_str().unwrap();
    let lead = daemon.start(Provider::Claude, "lead them", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let task = daemon
        .start(Provider::Claude, "one of yesterday's", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() })
        .unwrap();

    assert_eq!(daemon.adopt_into(&lead, &task).unwrap(), task, "a task Zero has, by its id");
    assert_eq!(daemon.get(&task).unwrap().parent.as_deref(), Some(lead.as_str()));
    assert!(daemon.adopt_into(&task, &lead).is_err(), "not its own worker's worker");
    assert!(daemon.adopt_into(&lead, &lead).is_err());

    // A Claude Code session Zero doesn't have, by its id alone: its folder is in its file.
    let file = zerod::handoff::claude_folder(&user, cwd).join("9f00.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(
        &file,
        json!({"type": "user", "cwd": cwd, "uuid": "u1", "message": {"role": "user", "content": "Fix ENG-1"}}).to_string() + "\n",
    )
    .unwrap();
    let adopted = daemon.adopt_into(&lead, "9f00").unwrap();
    let worker = daemon.get(&adopted).unwrap();
    assert_eq!((worker.parent.as_deref(), worker.thread.as_deref(), worker.cwd.as_str()), (Some(lead.as_str()), Some("9f00"), cwd));
    assert_eq!(daemon.adopt_into(&lead, "9f00").unwrap(), adopted, "by its thread, once Zero has it");
    assert!(daemon.adopt_into(&lead, "nope").is_err());

    // Kept: another start of zerod has it under its lead.
    assert_eq!(Daemon::open(&home.join("zerod"), quiet()).unwrap().get(&task).unwrap().parent.as_deref(), Some(lead.as_str()));

    // And let go again: a task of its own, a lead itself, by its id or its session's.
    daemon.detach("9f00").unwrap();
    assert_eq!(daemon.get(&adopted).unwrap().parent, None);
    daemon.detach(&adopted).unwrap();
    assert!(daemon.detach("nope").is_err());
    assert_eq!(Daemon::open(&home.join("zerod"), quiet()).unwrap().get(&adopted).unwrap().parent, None, "kept");
}

#[tokio::test]
async fn a_session_from_claude_code_or_codex_migrates_by_its_id_alone() {
    let home = temp_dir("migrate");
    let (user, project) = (home.join("user"), home.join("project"));
    std::fs::create_dir_all(&project).unwrap();
    let daemon = Daemon::open(&home.join("zerod"), quiet()).unwrap();
    daemon.place(&user, &home.join("host.sock"));
    let cwd = project.to_str().unwrap();
    let lines = |records: &[serde_json::Value]| records.iter().map(|r| r.to_string() + "\n").collect::<String>();
    // Claude Code's: its folder is in its records.
    let claude = zerod::handoff::claude_folder(&user, cwd).join("c1a0-0000.jsonl");
    std::fs::create_dir_all(claude.parent().unwrap()).unwrap();
    std::fs::write(&claude, lines(&[json!({"type": "user", "uuid": "u1", "cwd": cwd, "message": {"role": "user", "content": "Fix the footer"}}),
        json!({"type": "assistant", "uuid": "a1", "cwd": cwd, "message": {"role": "assistant", "content": [{"type": "text", "text": "Fixed."}]}})])).unwrap();
    // Codex's: a rollout file under its day, the folder in its first record.
    let rollout = user.join(".codex/sessions/2026/11/04/rollout-2026-11-04T10-00-00-01a1-c0de.jsonl");
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let done = |item: serde_json::Value| json!({"timestamp": "2026-11-04T10:00:05.000Z", "type": "event_msg", "payload": {"type": "item_completed", "item": item}});
    std::fs::write(&rollout, lines(&[
        json!({"timestamp": "2026-11-04T10:00:00.000Z", "type": "session_meta", "payload": {"id": "01a1-c0de", "cwd": cwd}}),
        done(json!({"type": "UserMessage", "id": "u1", "content": [{"type": "text", "text": "Fix the flaky test"}]})),
        done(json!({"type": "AgentMessage", "id": "m1", "content": [{"type": "Text", "text": "Running it first."}], "phase": "commentary"})),
        done(json!({"type": "CommandExecution", "id": "c1", "command": ["/bin/zsh", "-lc", "bin/rspec spec/x_spec.rb"], "cwd": format!("file://{cwd}"),
                    "aggregated_output": "1 example, 0 failures", "exit_code": 0, "duration": {"secs": 2, "nanos": 0}})),
        done(json!({"type": "McpToolCall", "id": "t1", "server": "linear", "tool": "get_issue", "arguments": {"id": "ENG-1"}})),
        done(json!({"type": "AgentMessage", "id": "m2", "content": [{"type": "Text", "text": "Fixed: it raced the clock."}], "phase": "final_answer"})),
    ])).unwrap();

    let from_claude = daemon.migrate("c1a0-0000", Options::default()).unwrap();
    let task = daemon.get(&from_claude).unwrap();
    assert_eq!(
        (task.provider, task.cwd.as_str(), task.thread.as_deref(), task.status),
        (Provider::Claude, cwd, Some("c1a0-0000"), Status::Offline),
        "taken in where it ran, offline until a message resumes it on its own thread"
    );
    let from_codex = daemon.migrate("01a1-c0de", Options { label: Some("Flaky test".into()), ..Default::default() }).unwrap();
    let task = daemon.get(&from_codex).unwrap();
    assert_eq!(
        (task.provider, task.cwd.as_str(), task.thread.as_deref(), task.label.as_deref()),
        (Provider::Codex, cwd, Some("01a1-c0de"), Some("Flaky test"))
    );
    let kinds: Vec<String> = task
        .items
        .iter()
        .map(|i| match &i.kind {
            ItemKind::User { text, .. } => format!("user {text}"),
            ItemKind::Agent { text, final_answer } => format!("agent{} {text}", if *final_answer { " (answer)" } else { "" }),
            ItemKind::Command { command, output, exit_code, .. } => format!("$ {command} → {exit_code:?} {output}"),
            ItemKind::Tool { name, .. } => format!("tool {name}"),
            other => format!("{other:?}"),
        })
        .collect();
    assert_eq!(
        kinds,
        [
            "user Fix the flaky test",
            "agent Running it first.",
            "$ bin/rspec spec/x_spec.rb → Some(0) 1 example, 0 failures",
            "tool linear.get_issue",
            "agent (answer) Fixed: it raced the clock."
        ]
    );
    assert_eq!(daemon.migrate("01a1-c0de", Options::default()).unwrap(), from_codex, "the same session is one task");
    assert!(daemon.migrate("nope", Options::default()).unwrap_err().contains("No Claude Code, Codex or OpenCode session nope"));
}

#[test]
fn an_opencode_export_reads_as_the_tasks_history() {
    let export = json!({"info": {"id": "ses_1", "location": {"directory": "/work/app"}}, "messages": [
        {"id": "m1", "type": "user", "time": {"created": 1_793_785_113_145_i64}, "text": "Check the CVE"},
        {"id": "m2", "type": "system", "text": "The tool catalog changed."},
        {"id": "m3", "type": "assistant", "time": {"created": 1_793_785_113_157_i64}, "content": [
            {"type": "reasoning", "text": "Let me think."},
            {"type": "text", "text": "Looking it up."},
            {"type": "tool", "id": "t1", "name": "bash", "state": {"status": "completed", "input": {"command": "git log -1"}, "content": [{"type": "text", "text": "abc123"}]}},
            {"type": "tool", "id": "t2", "name": "webfetch", "state": {"status": "completed", "input": {"url": "https://cve.example/1"}}},
            {"type": "text", "text": "Not affected."}]},
        {"id": "m4", "type": "idle", "outcome": "succeeded"}]});
    let (cwd, items) = zerod::handoff::from_opencode_export(&export).unwrap();
    assert_eq!(cwd, "/work/app");
    let kinds: Vec<String> = items
        .iter()
        .map(|i| match &i.kind {
            ItemKind::User { text, .. } => format!("user {text}"),
            ItemKind::Agent { text, final_answer } => format!("agent{} {text}", if *final_answer { " (answer)" } else { "" }),
            ItemKind::Command { command, output, .. } => format!("$ {command} {output}"),
            ItemKind::Tool { name, detail, .. } => format!("tool {name} {detail}"),
            other => format!("{other:?}"),
        })
        .collect();
    assert_eq!(
        kinds,
        [
            "user Check the CVE",
            "agent Looking it up.",
            "$ git log -1 abc123",
            "tool webfetch https://cve.example/1",
            "agent (answer) Not affected."
        ],
        "what was typed, said and run; its thinking and OpenCode's own notices stay out"
    );
}
