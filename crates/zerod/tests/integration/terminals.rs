//! A task in its provider's own terminal: Zero's UI is the way to work with an agent, and its provider's terminal is a
//! door to what only that provider has. The terminal takes over the task's own thread (Zero stops its headless process
//! first); back in Zero, what happened there joins the task's record, so nothing is lost and switching still works.


use std::collections::HashSet;
use std::path::Path;
use std::sync::{Arc, Mutex};

use crate::common::{temp_dir, until};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

#[test]
fn each_provider_opens_its_own_terminal_on_the_tasks_thread() {
    let mut claude = Conversation::new("s", Provider::Claude, "/w");
    claude.thread = Some("3f1c".into());
    claude.model = Some("opus".into());
    // The providers' own browsers are off in Zero, whatever the user's own settings: agents use Zero for Chrome.
    assert_eq!(Provider::Claude.terminal(&claude).unwrap()[4..], ["claude", "--resume", "3f1c", "--permission-mode", "auto", "--no-chrome",
        "--settings", r#"{"idleCompaction":false}"#, "--model", "opus"]);
    let mut codex = Conversation::new("s", Provider::Codex, "/w");
    codex.thread = Some("01a1".into());
    codex.permissions = Permissions::Unrestricted;
    assert_eq!(Provider::Codex.terminal(&codex).unwrap()[4..], ["codex", "resume", "01a1", "--no-daemon", "--dangerously-bypass-approvals-and-sandbox",
        "-c", "plugins.chrome@openai-bundled.enabled=false", "-c", "plugins.browser@openai-bundled.enabled=false"]);
    assert_eq!(Provider::Codex.command(&codex, true, None, None)[4..], ["codex", "app-server",
        "-c", "plugins.chrome@openai-bundled.enabled=false", "-c", "plugins.browser@openai-bundled.enabled=false"]);
    let mut opencode = Conversation::new("s", Provider::Opencode, "/w");
    opencode.thread = Some("ses_9".into());
    assert_eq!(Provider::Opencode.terminal(&opencode).unwrap()[4..], ["opencode", "--session", "ses_9"]);
    assert_eq!(Provider::Codex.terminal(&Conversation::new("s", Provider::Codex, "/w")).unwrap_err(), "Codex hasn't started this task's thread yet");
}

/// What Claude Code writes to its session file as you work in its terminal.
fn claude_turn() -> Vec<Value> {
    vec![
        json!({"type": "user", "uuid": "u1", "isMeta": true, "message": {"role": "user", "content": "<local-command-caveat>Caveat</local-command-caveat>"}}),
        json!({"type": "user", "uuid": "u2", "message": {"role": "user", "content": "List the files"}}),
        json!({"type": "assistant", "uuid": "a1", "message": {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hmm"}, {"type": "text", "text": "Listing them."},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]}}),
        json!({"type": "user", "uuid": "u3", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "a.txt", "is_error": false}]}}),
        json!({"type": "assistant", "uuid": "a2", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t2", "name": "Read", "input": {"file_path": "/w/a.txt"}}]}}),
        json!({"type": "user", "uuid": "u4", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t2", "content": "hi"}]}}),
        json!({"type": "assistant", "uuid": "a3", "message": {"role": "assistant", "content": [{"type": "text", "text": "There is one file, a.txt."}]}}),
        json!({"type": "system", "uuid": "s1", "subtype": "turn_duration"}),
    ]
}

#[test]
fn claude_codes_session_file_comes_back_as_the_tasks_items() {
    let kinds: Vec<ItemKind> = zerod::handoff::from_claude_session(&claude_turn()).into_iter().map(|i| i.kind).collect();
    assert_eq!(kinds, [
        ItemKind::User { text: "List the files".into(), images: vec![] },
        ItemKind::Agent { text: "Listing them.".into(), final_answer: false },
        ItemKind::Command { command: "ls".into(), cwd: String::new(), output: "a.txt".into(), exit_code: Some(0), duration_ms: None },
        ItemKind::Tool { name: "Read".into(), detail: "/w/a.txt".into() },
        ItemKind::Agent { text: "There is one file, a.txt.".into(), final_answer: true },
    ], "what was said and done, in order; Claude's own bookkeeping and thinking left out, the turn's last words its answer");
}

#[test]
fn only_codex_turns_zero_doesnt_have_yet_come_back() {
    let turns = json!([
        {"id": "turn-1", "items": [{"type": "agentMessage", "id": "m1", "text": "old", "phase": "final_answer"}]},
        {"id": "turn-2", "items": [{"type": "userMessage", "id": "u2", "content": [{"type": "text", "text": "In the terminal"}]},
                                   {"type": "agentMessage", "id": "m2", "text": "Typed there", "phase": "final_answer"}]},
    ]);
    let items = zerod::codex::new_turn_items(&turns, &HashSet::from(["turn-1".to_string()]));
    let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids, ["u2", "m2"]);
    assert!(matches!(&items[1].kind, ItemKind::Agent { text, final_answer: true } if text == "Typed there"));
}

/// zero-host as a socket: answers each request from a table, and records them.
async fn fake_host(dir: &Path, answers: Value) -> (std::path::PathBuf, Arc<Mutex<Vec<Value>>>) {
    let socket = dir.join("host.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let seen = Arc::new(Mutex::new(vec![]));
    let record = seen.clone();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let (read, mut write) = stream.into_split();
            if let Ok(Some(line)) = BufReader::new(read).lines().next_line().await {
                let request: Value = serde_json::from_str(&line).unwrap();
                let reply = answers[request["op"].as_str().unwrap()].clone();
                record.lock().unwrap().push(request);
                let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
            }
        }
    });
    (socket, seen)
}

#[tokio::test]
async fn a_task_goes_to_its_terminal_and_comes_back_with_what_happened_there() {
    let home = temp_dir("terminal-flow");
    let user = home.join("user");
    let (socket, seen) = fake_host(&home, json!({
        "hello": {"ok": true}, "spawn": {"ok": true, "terminal": {"id": "term-1", "running": true}},
        "state": {"ok": true, "terminal": {"id": "term-1", "running": true}}, "close": {"ok": true},
    })).await;
    let runtime: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home.join("zerod"), runtime).unwrap();
    daemon.place(&user, &socket);
    let id = daemon.start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap();
    let session = daemon.session(&id).unwrap();
    until(&session, |c| c.status == Status::Offline).await;
    let thread = session.snapshot().thread.unwrap();
    let file = zerod::handoff::claude_folder(&user, home.to_str().unwrap()).join(format!("{thread}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, json!({"type": "user", "uuid": "u0", "message": {"role": "user", "content": "hi"}}).to_string() + "\n").unwrap();

    assert_eq!(daemon.open_terminal(&id).await.unwrap(), "term-1");
    let spawned = seen.lock().unwrap().iter().find(|r| r["op"] == "spawn").cloned().unwrap();
    assert_eq!(spawned["cwd"], home.to_str().unwrap());
    assert!(spawned["argv"].as_array().unwrap().windows(2).any(|w| w[0] == "--resume" && w[1] == thread.as_str()), "{spawned}");
    assert_eq!(session.snapshot().terminal, Some(Opened { id: "term-1".into(), mark: 1 }), "what the file held before is already in the record");
    assert_eq!(daemon.send(&id, zerod::session::Message::text("from Zero"), Default::default()).await.unwrap_err(), "Claude Code is open in its terminal; type there, or go back to Zero");

    let mut written = std::fs::read_to_string(&file).unwrap();
    for record in claude_turn() { written += &(record.to_string() + "\n") }
    std::fs::write(&file, written).unwrap();
    daemon.close_terminal(&id).await.unwrap();
    assert!(seen.lock().unwrap().iter().any(|r| r["op"] == "close" && r["id"] == "term-1"));
    let conversation = session.snapshot();
    assert_eq!(conversation.terminal, None);
    let texts: Vec<String> = conversation.items.iter().filter_map(|i| match &i.kind {
        ItemKind::User { text, .. } | ItemKind::Agent { text, .. } => Some(text.clone()),
        _ => None,
    }).collect();
    assert_eq!(texts, ["hi", "List the files", "Listing them.", "There is one file, a.txt."], "the terminal's turn joins the record, the earlier one isn't repeated");
    // Kept across a restart: the record took it in as changes in the transcript.
    drop(daemon);
    let runtime: Runtime = Arc::new(|_, _, _| Err(std::io::Error::other("not started")));
    let again = Daemon::open(&home.join("zerod"), runtime).unwrap();
    assert_eq!(again.get(&id).unwrap().items.len(), conversation.items.len());
}

#[tokio::test]
async fn a_resume_that_fails_lets_go_of_the_process_it_started() {
    // Codex refusing the thread (still held by its terminal, say): the headless Codex started for it mustn't stay
    // around holding the thread too.
    let home = temp_dir("terminal-resume-fails");
    let dir = home.join("sessions/01a100000000000a");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("meta.json"), r#"{"id":"01a100000000000a","provider":"codex","cwd":"/work","thread":"t1"}"#).unwrap();
    let script = vec![
        json!({"out": {"id": "z1", "method": "initialize"}}), json!({"in": {"id": "z1", "result": {}}}),
        json!({"out": {"method": "initialized"}}),
        json!({"out": {"id": "z2", "method": "thread/resume"}}), json!({"in": {"id": "z2", "error": {"code": -1, "message": "thread t1 already has an active writer"}}}),
    ];
    let script = Mutex::new(Some(script));
    let runtime: Runtime = Arc::new(move |_, _, _| Ok(crate::common::play(script.lock().unwrap().take().unwrap()).0));
    let daemon = Daemon::open(&home, runtime).unwrap();
    let error = daemon.resume("01a100000000000a").await.unwrap_err();
    assert!(error.contains("active writer"), "{error}");
    let session = daemon.session("01a100000000000a").unwrap();
    assert!(!session.is_attached());
    until(&session, |c| c.status == Status::Offline).await;
}

#[tokio::test(start_paused = true)]
async fn a_terminal_left_idle_is_closed_and_its_task_comes_back_to_zero() {
    let home = temp_dir("terminal-park");
    let user = home.join("user");
    // zero-host says the terminal has had nothing written or typed for 16 minutes.
    let (socket, seen) = fake_host(&home, json!({
        "hello": {"ok": true}, "spawn": {"ok": true, "terminal": {"id": "term-1", "running": true}},
        "state": {"ok": true, "terminal": {"id": "term-1", "running": true, "idle": 16 * 60}}, "close": {"ok": true},
    })).await;
    let runtime: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home.join("zerod"), runtime).unwrap();
    daemon.place(&user, &socket);
    let id = daemon.start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap();
    let session = daemon.session(&id).unwrap();
    until(&session, |c| c.status == Status::Offline).await;
    let file = zerod::handoff::claude_folder(&user, home.to_str().unwrap()).join(format!("{}.jsonl", session.snapshot().thread.unwrap()));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, "").unwrap();
    daemon.open_terminal(&id).await.unwrap();
    for _ in 0..12 { tokio::time::sleep(std::time::Duration::from_secs(15)).await }
    assert!(seen.lock().unwrap().iter().any(|r| r["op"] == "close" && r["id"] == "term-1"), "closed once idle for {:?}", zerod::daemon::TERMINAL_PARK_AFTER);
    assert_eq!(session.snapshot().terminal, None);
}
