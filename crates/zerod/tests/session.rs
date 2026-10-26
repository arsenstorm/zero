//! Live sessions against recorded runtimes: each provider's protocol spoken in the recorded order, approvals
//! answered in the provider's own words, and what every provider shares (broadcasts, transcripts, going offline).

mod common;

use common::{fixture, play, temp_dir, until};
use serde_json::json;
use tokio::sync::broadcast;
use zerod::model::{ChoiceKind, Conversation, Event, ItemKind, Provider, Status};
use zerod::session::Session;

const CLAUDE_SESSION: &str = "3f1c2b8a-0000-4000-8000-000000000001";

fn session(provider: Provider, dir: Option<std::path::PathBuf>) -> (Session, broadcast::Receiver<Event>) {
    let (events, receiver) = broadcast::channel(4096);
    let mut conversation = Conversation::new("s1", provider, "/work/project");
    if provider == Provider::Claude { conversation.thread = Some(CLAUDE_SESSION.into()) }
    (Session::new(conversation, dir, events).unwrap(), receiver)
}

fn answered(conversation: &Conversation) -> bool {
    conversation.status == Status::Idle && conversation.items.iter().any(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. }))
}

/// Answers every approval the session shows with its first choice of `kind`, until the turn has its answer.
async fn allow_all(session: &Session, kind: ChoiceKind) -> Conversation {
    loop {
        let now = until(session, |c| !c.approvals.is_empty() || answered(c)).await;
        if answered(&now) && now.approvals.is_empty() { return now }
        let approval = &now.approvals[0];
        let choice = approval.choices.iter().find(|c| c.kind == kind).unwrap();
        session.decide(&approval.id, &choice.id).await.unwrap();
        until(session, |c| c.approvals.first().map(|a| &a.id) != Some(&approval.id)).await;
    }
}

/// The Codex command fixture started and run to its end, its approval allowed.
async fn codex_finished(dir: Option<std::path::PathBuf>) -> (Session, common::Seen) {
    let (session, _) = session(Provider::Codex, dir);
    let (transport, seen) = play(fixture("codex-command"));
    session.start(transport, "Run the shell command `ls -la` here", Some("gpt-6-sol"), Some("high")).await.unwrap();
    allow_all(&session, ChoiceKind::Allow).await;
    (session, seen)
}

// Codex

#[tokio::test]
async fn codex_starts_by_initializing_then_a_thread_and_its_first_turn() {
    let (_, seen) = codex_finished(None).await;
    assert_eq!(seen.methods()[..4], ["initialize", "initialized", "thread/start", "turn/start"]);
    let thread = seen.first("thread/start").unwrap();
    assert_eq!((&thread["params"]["cwd"], &thread["params"]["model"]), (&json!("/work/project"), &json!("gpt-6-sol")));
    assert_eq!((&thread["params"]["approvalPolicy"], &thread["params"]["sandbox"]), (&json!("on-request"), &json!("workspace-write")));
    let turn = seen.first("turn/start").unwrap();
    assert_eq!(turn["params"]["threadId"], "01a177f4-5525-7141-bfb3-f350d91476d6");
    assert_eq!(turn["params"]["input"][0]["text"], "Run the shell command `ls -la` here");
    assert_eq!(turn["params"]["effort"], "high");
    assert_eq!(seen.reply_to(&json!(0)).unwrap(), json!({"id": 0, "result": {"decision": "accept"}}));
}

#[tokio::test]
async fn a_choice_not_offered_or_a_second_decision_is_refused_and_nothing_is_sent() {
    let (session, _) = session(Provider::Codex, None);
    let (transport, seen) = play(fixture("codex-command"));
    session.start(transport, "ls", None, None).await.unwrap();
    let waiting = until(&session, |c| !c.approvals.is_empty()).await;
    let id = &waiting.approvals[0].id;
    assert!(session.decide(id, "made-up").await.is_err());
    assert!(session.decide("no-such-approval", "0").await.is_err());
    assert!(seen.reply_to(&json!(0)).is_none());
    let stop = waiting.approvals[0].choices.iter().find(|c| c.kind == ChoiceKind::Stop).unwrap();
    session.decide(id, &stop.id).await.unwrap();
    assert!(session.decide(id, "0").await.is_err(), "the first decision stands");
    until(&session, |c| c.approvals.is_empty()).await;
    assert_eq!(seen.reply_to(&json!(0)).unwrap()["result"]["decision"], "cancel");
}

#[tokio::test]
async fn codex_is_steered_mid_turn_and_given_a_new_turn_otherwise() {
    let (session, _) = session(Provider::Codex, None);
    let (transport, seen) = play(fixture("codex-command"));
    session.start(transport, "ls", None, None).await.unwrap();
    let waiting = until(&session, |c| !c.approvals.is_empty()).await;
    session.send("and count the files", None, None).await.unwrap();
    let steer = seen.first("turn/steer").expect("steered");
    assert_eq!(steer["params"]["expectedTurnId"], waiting.turn.unwrap().as_str());
    assert_eq!(steer["params"]["input"][0]["text"], "and count the files");
    allow_all(&session, ChoiceKind::Allow).await;
    session.send("thanks", Some("gpt-6-luna"), Some("low")).await.unwrap();
    let turns: Vec<_> = seen.all().into_iter().filter(|m| m["method"] == "turn/start").collect();
    assert_eq!((turns.len(), &turns[1]["params"]["model"], &turns[1]["params"]["effort"]), (2, &json!("gpt-6-luna"), &json!("low")));
    assert_eq!(session.snapshot().model.as_deref(), Some("gpt-6-luna"));
}

#[tokio::test]
async fn codex_interrupts_name_the_turn_and_need_one() {
    let (session, _) = session(Provider::Codex, None);
    let (transport, seen) = play(fixture("codex-command"));
    session.start(transport, "ls", None, None).await.unwrap();
    let waiting = until(&session, |c| c.turn.is_some()).await;
    session.interrupt().await.unwrap();
    let interrupt = seen.first("turn/interrupt").unwrap();
    assert_eq!(interrupt["params"]["turnId"], waiting.turn.unwrap().as_str());
    let (idle, _) = codex_finished(None).await;
    assert!(idle.interrupt().await.is_err());
}

#[tokio::test]
async fn codex_resumes_an_offline_session_on_its_thread() {
    let dir = temp_dir("resume-codex");
    codex_finished(Some(dir.clone())).await;
    let (events, _) = broadcast::channel(16);
    let session = Session::load(&dir, events).unwrap();
    let thread = "01a177f4-5525-7141-bfb3-f350d91476d6";
    let script = vec![
        json!({"out": {"id": "a", "method": "initialize"}}), json!({"in": {"id": "a", "result": {}}}),
        json!({"out": {"method": "initialized"}}),
        json!({"out": {"id": "b", "method": "thread/resume"}}),
        json!({"in": {"id": "b", "result": {"thread": {"id": thread, "name": "Listing files"}, "model": "gpt-6-sol"}}}),
    ];
    let (transport, seen) = play(script);
    session.resume(transport).await.unwrap();
    assert_eq!(seen.first("thread/resume").unwrap()["params"]["threadId"], thread);
    assert_eq!(until(&session, |c| c.status == Status::Idle).await.title.as_deref(), Some("Listing files"));
    session.send("again", None, None).await.unwrap();
    assert_eq!(seen.first("turn/start").unwrap()["params"]["threadId"], thread);
}

// Claude Code

#[tokio::test]
async fn claude_is_told_the_prompt_and_answered_on_stdin() {
    let (session, _) = session(Provider::Claude, None);
    let (transport, seen) = play(fixture("claude-file-change"));
    session.start(transport, "Create a file named hello.txt containing exactly the line: hello from zero. Then reply done.", None, None).await.unwrap();
    let done = allow_all(&session, ChoiceKind::Allow).await;
    let first = &seen.all()[0];
    assert_eq!(first["type"], "user");
    assert!(first["message"]["content"].as_str().unwrap().starts_with("Create a file named hello.txt"));
    let answer = seen.first("control_response").unwrap();
    assert_eq!(answer["response"]["response"]["behavior"], "allow");
    assert_eq!(answer["response"]["response"]["updatedInput"]["file_path"], "/work/project/hello.txt");
    assert!(matches!(&done.items.last().unwrap().kind, ItemKind::Agent { text, .. } if text == "done"));
}

#[tokio::test]
async fn claude_queues_a_message_sent_mid_turn_and_interrupts_through_its_control_protocol() {
    let (session, _) = session(Provider::Claude, None);
    let (transport, seen) = play(fixture("claude-file-change"));
    session.start(transport, "write it", None, None).await.unwrap();
    until(&session, |c| !c.approvals.is_empty()).await;
    session.send("and say hi", None, None).await.unwrap();
    assert_eq!(seen.said("user", 2).await[1]["message"]["content"], "and say hi");
    session.interrupt().await.unwrap();
    seen.said("control_request:interrupt", 1).await;
}

#[tokio::test]
async fn claude_resumes_by_starting_again_on_its_session() {
    let dir = temp_dir("resume-claude");
    let (live, _) = session(Provider::Claude, Some(dir.clone()));
    let (transport, _) = play(fixture("claude-command"));
    live.start(transport, "uname", None, None).await.unwrap();
    until(&live, answered).await;
    let (events, _) = broadcast::channel(16);
    let session = Session::load(&dir, events).unwrap();
    assert_eq!(session.snapshot().thread.as_deref(), Some("de7c0e2b-badd-439a-a46b-9e187476cb40"), "the session Claude reported");
    let (transport, seen) = play(vec![]);
    session.resume(transport).await.unwrap();
    assert_eq!(session.snapshot().status, Status::Idle);
    session.send("again", None, None).await.unwrap();
    assert_eq!(seen.said("user", 1).await[0]["message"]["content"], "again");
}

// OpenCode

#[tokio::test]
async fn opencode_initializes_opens_a_session_sets_the_model_and_prompts() {
    let (session, _) = session(Provider::Opencode, None);
    let (transport, seen) = play(fixture("opencode-approval"));
    session.start(transport, "mkdir and write", Some("opencode-go/beam-free"), Some("high")).await.unwrap();
    let done = allow_all(&session, ChoiceKind::Allow).await;
    let methods = seen.methods();
    assert_eq!(methods[..2], ["initialize", "session/new"]);
    assert_eq!(seen.first("session/new").unwrap()["params"]["cwd"], "/work/project");
    let settings: Vec<_> = seen.all().into_iter().filter(|m| m["method"] == "session/set_config_option").map(|m| m["params"].clone()).collect();
    assert_eq!(settings[0], json!({"sessionId": "ses_e87e6f601ffeztiWsg4jmIBG4V", "configId": "model", "value": "opencode-go/beam-free"}));
    assert_eq!(settings[1]["configId"], "effort");
    assert_eq!(seen.first("session/prompt").unwrap()["params"]["prompt"][0]["text"], "mkdir and write");
    assert_eq!(seen.reply_to(&json!(0)).unwrap(), json!({"jsonrpc": "2.0", "id": 0, "result": {"outcome": {"outcome": "selected", "optionId": "once"}}}));
    assert!(seen.reply_to(&json!(1)).is_some());
    assert!(matches!(&done.items.last().unwrap().kind, ItemKind::Agent { text, final_answer: true } if text == "done"));
}

#[tokio::test]
async fn opencode_cancels_mid_turn_and_refuses_a_second_prompt_while_one_runs() {
    let (session, _) = session(Provider::Opencode, None);
    let (transport, seen) = play(fixture("opencode-approval"));
    session.start(transport, "mkdir and write", Some("opencode-go/beam-free"), None).await.unwrap();
    until(&session, |c| !c.approvals.is_empty()).await;
    let refused = session.send("also this", None, None).await.unwrap_err();
    assert!(refused.contains("OpenCode"), "{refused}");
    session.interrupt().await.unwrap();
    assert_eq!(seen.said("session/cancel", 1).await[0]["params"]["sessionId"], "ses_e87e6f601ffeztiWsg4jmIBG4V");
}

#[tokio::test]
async fn opencode_resumes_its_session_without_replaying_it() {
    let dir = temp_dir("resume-opencode");
    let (live, _) = session(Provider::Opencode, Some(dir.clone()));
    let (transport, _) = play(fixture("opencode-command"));
    live.start(transport, "mkdir", Some("opencode-go/beam-free"), None).await.unwrap();
    until(&live, answered).await;
    let (events, _) = broadcast::channel(16);
    let session = Session::load(&dir, events).unwrap();
    let (transport, seen) = play(vec![]);
    session.resume(transport).await.unwrap();
    assert_eq!(seen.methods()[..2], ["initialize", "session/resume"]);
    let resume = seen.first("session/resume").unwrap();
    assert_eq!((&resume["params"]["sessionId"], &resume["params"]["cwd"]), (&json!("ses_e87e7ec46ffe1ztiRcXd8Xelqy"), &json!("/work/project")));
}

// Every provider

#[tokio::test]
async fn every_change_is_broadcast_in_order_and_rebuilds_the_conversation() {
    for (provider, name, model) in [(Provider::Codex, "codex-command", None), (Provider::Claude, "claude-command-approval", None), (Provider::Opencode, "opencode-approval", Some("opencode-go/beam-free"))] {
        let (session, mut events) = session(provider, None);
        let (transport, _) = play(fixture(name));
        session.start(transport, "go", model, None).await.unwrap();
        let done = allow_all(&session, ChoiceKind::Allow).await;
        let mut mirror = Conversation::new("s1", provider, "/work/project");
        if provider == Provider::Claude { mirror.thread = Some(CLAUDE_SESSION.into()) }
        while let Ok(event) = events.try_recv() {
            assert_eq!(event.seq, mirror.seq + 1, "{name}: no gaps, no repeats");
            mirror.apply(event.change);
        }
        assert_eq!(mirror, done, "{name}");
    }
}

#[tokio::test]
async fn a_session_is_rebuilt_from_its_transcript_and_comes_back_offline() {
    for (provider, name, model) in [(Provider::Codex, "codex-command", None), (Provider::Claude, "claude-file-change", None), (Provider::Opencode, "opencode-approval", Some("opencode-go/beam-free"))] {
        let dir = temp_dir(&format!("transcript-{name}"));
        let (live, _) = session(provider, Some(dir.clone()));
        let (transport, _) = play(fixture(name));
        live.start(transport, "go", model, None).await.unwrap();
        let before = allow_all(&live, ChoiceKind::Allow).await;
        let (events, _) = broadcast::channel(16);
        let after = Session::load(&dir, events).unwrap().snapshot();
        assert_eq!(after.status, Status::Offline, "{name}");
        assert_eq!(after.items, before.items, "{name}");
        assert_eq!((after.thread, after.model, after.provider), (before.thread, before.model, provider), "{name}");
    }
}

#[tokio::test]
async fn the_runtime_going_away_takes_the_session_offline_and_fails_what_waited_on_it() {
    let (session, _) = session(Provider::Codex, None);
    let script = vec![fixture("codex-command")[0].clone(), fixture("codex-command")[1].clone(), json!({"hangup": true})];
    let (transport, _) = play(script);
    assert!(session.start(transport, "ls", None, None).await.is_err(), "thread/start never came back");
    let offline = until(&session, |c| c.status == Status::Offline).await;
    assert!(offline.approvals.is_empty());
    assert!(session.send("hello?", None, None).await.is_err(), "no runtime until it is resumed");
}

#[tokio::test]
async fn lines_that_are_not_json_are_skipped() {
    // A login shell's .zshrc may print before the runtime starts; that mustn't stop the session.
    let (session, _) = session(Provider::Codex, None);
    let (zero_side, runtime_side) = tokio::io::duplex(1 << 16);
    let (read, write) = tokio::io::split(zero_side);
    let (_runtime_read, mut runtime_write) = tokio::io::split(runtime_side);
    use tokio::io::AsyncWriteExt;
    runtime_write.write_all(b"Welcome to zsh!\n{\"method\":\"thread/name/updated\",\"params\":{\"threadName\":\"Hi\"}}\n").await.unwrap();
    session.attach(zerod::session::Transport::new(read, write));
    until(&session, |c| c.title.as_deref() == Some("Hi")).await;
}
