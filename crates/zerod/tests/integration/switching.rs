//! A task isn't tied to the provider it started on: it can move to another one (Claude Code out of usage, say, and on to
//! Codex) and carry on with the whole conversation. Zero's record is the conversation; each provider gets it in the form
//! it reads natively (a Claude Code session file, which Codex imports).


use std::sync::Arc;

use crate::common::{fixture, temp_dir};
use serde_json::{Value, json};
use zerod::daemon::{Daemon, Runtime};
use zerod::handoff;
use zerod::model::*;

fn item(id: &str, kind: ItemKind) -> Item {
    Item { at: None, id: id.into(), turn: None, kind, status: ItemStatus::Done }
}

#[test]
fn a_switch_puts_the_session_on_another_provider_with_no_thread_yet() {
    let mut conversation = Conversation::new("s", Provider::Claude, "/work");
    conversation.apply(Change::Thread { thread: "claude-thread".into(), model: Some("opus".into()), effort: Some("high".into()) });
    conversation.apply(Change::Switched { provider: Provider::Codex, model: Some("gpt-6-sol".into()), effort: None });
    assert_eq!((conversation.provider, conversation.thread.as_deref()), (Provider::Codex, None), "the new provider starts its own thread from the record");
    assert_eq!((conversation.model.as_deref(), conversation.effort.as_deref()), (Some("gpt-6-sol"), None), "the old provider's model means nothing to the new one");
    assert!(matches!(&conversation.items.last().unwrap().kind, ItemKind::Notice { text, error: false } if text == "Continued in Codex"),
        "the conversation shows where each provider took over");
}

#[tokio::test]
async fn a_transcript_replays_each_providers_lines_through_its_own_adapter() {
    let home = temp_dir("switch-replay");
    let dir = home.join("sessions/01a1000000000009");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("meta.json"), r#"{"id":"01a1000000000009","provider":"claude","cwd":"/work/project","thread":null}"#).unwrap();
    let mut lines: Vec<Value> = fixture("claude-command");
    lines.push(json!({"change": {"type": "switched", "provider": "codex", "model": null, "effort": null}}));
    lines.extend(fixture("codex-command"));
    std::fs::write(dir.join("transcript.jsonl"), lines.iter().map(|l| l.to_string() + "\n").collect::<String>()).unwrap();
    let runtime: Runtime = Arc::new(|_, _, _| Err(std::io::Error::other("not started")));
    let daemon = Daemon::open(&home, runtime).unwrap();
    let conversation = daemon.get("01a1000000000009").unwrap();
    assert_eq!(conversation.provider, Provider::Codex);
    let answers: Vec<&str> = conversation.items.iter().filter_map(|i| match &i.kind { ItemKind::Agent { text, final_answer: true } => Some(text.as_str()), _ => None }).collect();
    assert_eq!(answers.len(), 2, "Claude's answer, then Codex's, each read by its own adapter: {answers:?}");
}

#[test]
fn the_record_becomes_a_claude_code_session_with_every_message_and_command() {
    let mut conversation = Conversation::new("s", Provider::Codex, "/work/project");
    conversation.items = vec![
        item("1", ItemKind::User { text: "Remember PERIWINKLE-42.".into(), images: vec![] }),
        item("2", ItemKind::Reasoning { text: "thinking".into() }),
        item("3", ItemKind::Agent { text: "Checking the machine.".into(), final_answer: false }),
        item("4", ItemKind::Command { command: "uname -n".into(), cwd: "/work/project".into(), output: "frostbite-7\n".into(), exit_code: Some(0), duration_ms: None }),
        item("5", ItemKind::Command { command: "false".into(), cwd: "/work/project".into(), output: String::new(), exit_code: Some(1), duration_ms: None }),
        item("6", ItemKind::FileChange { changes: vec![FileChange { path: "/work/project/a.txt".into(), kind: "add".into(), move_path: None, diff: "+hello\n".into() }] }),
        item("7", ItemKind::Agent { text: "Done: PERIWINKLE-42, frostbite-7.".into(), final_answer: true }),
    ];
    let file = handoff::claude_session(&conversation, "11111111-2222-4333-8444-555555555555");
    let records: Vec<Value> = file.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    for (before, after) in records.iter().zip(&records[1..]) {
        assert_eq!(after["parentUuid"], before["uuid"], "one chain, as Claude Code writes it");
    }
    assert!(records.iter().all(|r| r["sessionId"] == "11111111-2222-4333-8444-555555555555" && r["cwd"] == "/work/project"));
    let blocks: Vec<(String, String)> = records.iter().flat_map(|r| {
        let role = r["type"].as_str().unwrap().to_string();
        match &r["message"]["content"] {
            Value::String(text) => vec![(role, format!("text:{text}"))],
            Value::Array(blocks) => blocks.iter().map(|b| (role.clone(), match b["type"].as_str().unwrap() {
                "text" => format!("text:{}", b["text"].as_str().unwrap()),
                "tool_use" => format!("bash:{}", b["input"]["command"].as_str().unwrap()),
                "tool_result" => format!("result:{}:{}", b["content"].as_str().unwrap(), b["is_error"]),
                other => other.to_string(),
            })).collect(),
            _ => vec![],
        }
    }).collect();
    let blocks: Vec<(&str, &str)> = blocks.iter().map(|(r, b)| (r.as_str(), b.as_str())).collect();
    assert_eq!(blocks, [
        ("user", "text:Remember PERIWINKLE-42."),
        ("assistant", "text:Checking the machine."),
        ("assistant", "bash:uname -n"),
        ("user", "result:frostbite-7\n:false"),
        ("assistant", "bash:false"),
        ("user", "result:Exit code 1:true"),
        ("assistant", "text:Changed /work/project/a.txt (add):\n```diff\n+hello\n```"),
        ("assistant", "text:Done: PERIWINKLE-42, frostbite-7."),
    ], "reasoning stays with the provider that had it; everything said and done comes along");
    let uses: Vec<&Value> = records.iter().flat_map(|r| r["message"]["content"].as_array().into_iter().flatten()).filter(|b| b["type"] == "tool_use").collect();
    let results: Vec<&Value> = records.iter().flat_map(|r| r["message"]["content"].as_array().into_iter().flatten()).filter(|b| b["type"] == "tool_result").collect();
    assert_eq!(uses.iter().map(|b| &b["id"]).collect::<Vec<_>>(), results.iter().map(|b| &b["tool_use_id"]).collect::<Vec<_>>(), "each call has its result");
}

#[test]
fn claude_code_keeps_a_folders_sessions_under_its_path_with_dashes() {
    assert_eq!(handoff::claude_folder(std::path::Path::new("/Users/me"), "/Users/me/src/my_app.v2"),
               std::path::PathBuf::from("/Users/me/.claude/projects/-Users-me-src-my-app-v2"));
}

#[tokio::test]
async fn a_session_switches_only_between_turns_and_only_to_a_provider_that_can_take_over() {
    let home = temp_dir("switch-daemon");
    // A runtime that ends at once: the session is left offline, as one out of usage is.
    let runtime: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home, runtime.clone()).unwrap();
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "hi", None, None, Permissions::Auto).unwrap();
    crate::common::until(&daemon.session(&id).unwrap(), |c| c.status == Status::Offline).await;
    daemon.switch(&id, Provider::Codex, Some("gpt-6-sol"), None).await.unwrap();
    assert_eq!(daemon.get(&id).unwrap().provider, Provider::Codex);
    assert_eq!(daemon.switch(&id, Provider::Opencode, None, None).await.unwrap_err(), "Zero can't hand a task to OpenCode yet");
    // Kept across a restart: the switch is in the transcript.
    drop(daemon);
    let daemon = Daemon::open(&home, runtime).unwrap();
    assert_eq!(daemon.get(&id).unwrap().provider, Provider::Codex);
}

#[tokio::test]
async fn a_model_picked_without_a_message_goes_on_the_next_turn() {
    let dir = temp_dir("switch-model");
    let (events, _) = tokio::sync::broadcast::channel(64);
    let session = zerod::session::Session::new(Conversation::new("s1", Provider::Codex, "/work/project"), Some(dir.clone()), events.clone()).unwrap();
    let (transport, recorder) = crate::common::play(vec![]);
    session.attach(transport);
    session.change(zerod::model::Change::Thread { thread: "t1".into(), model: Some("gpt-6-sol".into()), effort: None });
    session.set_model(Some("gpt-6-luna"), Some("high")).await.unwrap();
    assert_eq!(session.snapshot().model.as_deref(), Some("gpt-6-luna"));
    session.send("hi", None, None).await.unwrap();
    let turn = recorder.said("turn/start", 1).await;
    assert_eq!(turn[0]["params"]["model"], "gpt-6-luna");
    assert_eq!(turn[0]["params"]["effort"], "high");
    // Kept: a restart reads it from the transcript.
    let again = zerod::session::Session::load(&dir, events).unwrap();
    assert_eq!(again.snapshot().model.as_deref(), Some("gpt-6-luna"));
}

#[test]
fn a_switch_right_after_an_interruption_reads_as_one_notice() {
    // Stopping a provider to hand the task to another is one act: "Interrupted and continued in Claude Code", not
    // two lines.
    let mut core = zerod::core::Core::new(Conversation::new("s", Provider::Codex, "/w"));
    core.change(zerod::model::Change::Item { item: item("stop", ItemKind::Notice { text: "Interrupted".into(), error: false }) });
    core.change(zerod::model::Change::Switched { provider: Provider::Claude, model: None, effort: None });
    let notices: Vec<String> = core.conversation().items.iter().filter_map(|i| match &i.kind { ItemKind::Notice { text, .. } => Some(text.clone()), _ => None }).collect();
    assert_eq!(notices, ["Interrupted and continued in Claude Code"]);
    // Not interrupted first (out of usage, say): just where it went on.
    let mut core = zerod::core::Core::new(Conversation::new("s", Provider::Codex, "/w"));
    core.change(zerod::model::Change::Switched { provider: Provider::Claude, model: None, effort: None });
    assert!(matches!(&core.conversation().items[0].kind, ItemKind::Notice { text, .. } if text == "Continued in Claude Code"));
}

#[tokio::test]
async fn permissions_change_between_turns_and_the_next_turn_starts_the_agent_with_them() {
    let home = temp_dir("switch-permissions");
    let started = Arc::new(std::sync::Mutex::new(vec![]));
    let seen = started.clone();
    // A runtime that ends at once, as a parked session's would: what matters is the command each start used.
    let runtime: Runtime = Arc::new(move |_, _, argv| { seen.lock().unwrap().push(argv.join(" ")); Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())) });
    let daemon = Daemon::open(&home, runtime.clone()).unwrap();
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "hi", None, None, Permissions::Auto).unwrap();
    crate::common::until(&daemon.session(&id).unwrap(), |c| c.status == Status::Offline).await;
    assert!(started.lock().unwrap()[0].contains("--permission-mode auto"), "{:?}", started.lock().unwrap());

    daemon.set_permissions(&id, Permissions::Unrestricted).await.unwrap();
    let conversation = daemon.get(&id).unwrap();
    assert_eq!(conversation.permissions, Permissions::Unrestricted);
    let notices: Vec<String> = daemon.session(&id).unwrap().snapshot().items.iter().filter_map(|i| match &i.kind { ItemKind::Notice { text, .. } => Some(text.clone()), _ => None }).collect();
    assert!(notices.contains(&"Unrestricted from here: it acts without asking".to_string()), "{notices:?}");
    daemon.resume(&id).await.ok();
    assert!(started.lock().unwrap().last().unwrap().contains("--permission-mode bypassPermissions"), "{:?}", started.lock().unwrap());

    // The same again is nothing; kept across a restart; and back.
    daemon.set_permissions(&id, Permissions::Unrestricted).await.unwrap();
    drop(daemon);
    let daemon = Daemon::open(&home, runtime).unwrap();
    assert_eq!(daemon.get(&id).unwrap().permissions, Permissions::Unrestricted, "kept in the transcript");
    daemon.set_permissions(&id, Permissions::Auto).await.unwrap();
    assert_eq!(daemon.get(&id).unwrap().permissions, Permissions::Auto);
}

#[tokio::test]
async fn a_task_keeps_the_model_it_started_on_and_its_workers_take_it() {
    // Started on a model: resumed later (parked, then a message), it runs on that model, not the provider's default.
    let home = temp_dir("switch-kept-model");
    let started = Arc::new(std::sync::Mutex::new(vec![]));
    let seen = started.clone();
    let runtime: Runtime = Arc::new(move |_, _, argv| { seen.lock().unwrap().push(argv.join(" ")); Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())) });
    let daemon = Daemon::open(&home, runtime.clone()).unwrap();
    let lead = daemon.start(Provider::Claude, home.to_str().unwrap(), "lead it", Some("claude-opus-5-5"), Some("high"), Permissions::Auto).unwrap();
    crate::common::until(&daemon.session(&lead).unwrap(), |c| c.status == Status::Offline).await;
    drop(daemon);
    let daemon = Daemon::open(&home, runtime).unwrap();
    assert_eq!(daemon.get(&lead).unwrap().model.as_deref(), Some("claude-opus-5-5"), "kept with the task");
    daemon.resume(&lead).await.ok();
    assert!(started.lock().unwrap().last().unwrap().contains("--model claude-opus-5-5"), "{:?}", started.lock().unwrap());

    // A worker given no model of its own: its lead's.
    let worker = daemon.spawn(&lead, Provider::Claude, "work", zerod::daemon::Options::default()).unwrap();
    assert!(started.lock().unwrap().last().unwrap().contains("--model claude-opus-5-5"), "{:?}", started.lock().unwrap());
    assert_eq!(daemon.get(&worker).unwrap().model.as_deref(), Some("claude-opus-5-5"));
}
