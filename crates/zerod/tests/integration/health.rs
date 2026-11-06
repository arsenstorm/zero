//! How a session is doing, beyond its status: the usage limits its CLI reports, failures by kind, and sessions that
//! have stopped making progress. All of it adds up to one attention state, which the app's bar shows as a dot.


use std::time::Duration;

use crate::common::{fixture, play, replay};
use serde_json::json;
use tokio::sync::broadcast;
use zerod::core::Core;
use zerod::model::{Attention, Conversation, FailureKind, Provider, Status};
use zerod::session::Session;

#[test]
fn claudes_own_rate_limit_report_is_the_sessions_usage() {
    let (core, _) = replay(Provider::Claude, "claude-command");
    let usage = core.conversation().usage.clone().expect("Claude reports its limits in the stream");
    assert!(!usage.limited);
    let five = usage.windows.iter().find(|w| w.name == "5 hours").unwrap();
    assert!((five.used - 0.18).abs() < 1e-9, "{five:?}");
    assert_eq!(five.resets_at, Some(1793026800));
    assert!(usage.windows.iter().any(|w| w.name == "7 days"));
}

#[test]
fn a_rejected_claude_limit_is_limited_until_it_resets() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/w"));
    core.receive(&json!({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": 1793030000, "rateLimitType": "five_hour",
        "unifiedWindows": {"five_hour": {"utilization": 1.0, "resetsAt": 1793030000, "status": "rejected"}}}}));
    let usage = core.conversation().usage.clone().unwrap();
    assert!(usage.limited);
    assert_eq!(usage.resets_at, Some(1793030000));
    assert_eq!(core.conversation().attention(), Attention::Limited);
}

#[test]
fn codexs_rate_limits_are_its_usage() {
    let mut core = Core::new(Conversation::new("s1", Provider::Codex, "/w"));
    core.receive(&json!({"method": "account/rateLimits/updated", "params": {"rateLimits": {"limitId": "codex",
        "primary": {"usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1793031273},
        "secondary": {"usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 1793618073}}}}));
    let usage = core.conversation().usage.clone().unwrap();
    assert!(usage.limited, "a window used up is a limit");
    assert_eq!(usage.resets_at, Some(1793031273));
    let names: Vec<_> = usage.windows.iter().map(|w| (w.name.as_str(), w.used)).collect();
    assert_eq!(names, [("5 hours", 1.0), ("7 days", 0.12)]);
}

#[test]
fn failures_are_told_apart_by_kind() {
    let cases = [
        ("Not logged in · Please run /login", FailureKind::SignIn),
        ("You've hit your usage limit. Resets at 3pm", FailureKind::Limit),
        ("API Error: 529 Overloaded", FailureKind::Model),
        ("The model claude-x is not available", FailureKind::Model),
        ("getaddrinfo ENOTFOUND api.anthropic.com", FailureKind::Network),
        ("API Error: Server error mid-response. The response above may be incomplete.", FailureKind::Network),
        ("Failed to authenticate: OAuth session expired and could not be refreshed", FailureKind::SignIn),
        ("Something odd", FailureKind::Other),
    ];
    for (text, kind) in cases {
        let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/w"));
        core.sent(&json!({"type": "user", "message": {"role": "user", "content": "hi"}}));
        core.receive(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": text}));
        let failure = core.conversation().failure.clone().expect(text);
        assert_eq!((failure.kind, failure.message.as_str()), (kind, text));
    }
    // The next turn starting clears it.
    let mut core = Core::new(Conversation::new("s1", Provider::Codex, "/w"));
    core.receive(&json!({"method": "turn/completed", "params": {"turn": {"id": "u", "status": "failed", "error": {"message": "stream disconnected: network error"}}}}));
    assert_eq!(core.conversation().failure.as_ref().map(|f| f.kind), Some(FailureKind::Network));
    core.receive(&json!({"method": "turn/started", "params": {"turn": {"id": "u2"}}}));
    assert_eq!(core.conversation().failure, None);
}

#[test]
fn attention_puts_what_needs_arsen_first() {
    let mut conversation = Conversation::new("s1", Provider::Codex, "/w");
    assert_eq!(conversation.attention(), Attention::Starting);
    conversation.status = Status::Working;
    assert_eq!(conversation.attention(), Attention::Working);
    conversation.stalled = Some("No word from Codex for 10 minutes".into());
    assert_eq!(conversation.attention(), Attention::Stuck);
    conversation.status = Status::Idle;
    conversation.stalled = None;
    assert_eq!(conversation.attention(), Attention::Idle);
    conversation.items.push(zerod::model::Item { at: None, id: "a".into(), turn: None, kind: zerod::model::ItemKind::Agent { text: "Checked.".into(), final_answer: true }, status: zerod::model::ItemStatus::Done });
    assert_eq!(conversation.attention(), Attention::Answered, "a turn ended is not a task done; the answer is there to read");
    conversation.items.push(zerod::model::Item { at: None, id: "b".into(), turn: None, kind: zerod::model::ItemKind::Agent { text: "Done.\n\n[zero: done]".into(), final_answer: true }, status: zerod::model::ItemStatus::Done });
    assert_eq!(conversation.attention(), Attention::Done, "it said so: an answer is waiting to be read");
    conversation.failure = Some(zerod::model::Failure { kind: FailureKind::SignIn, message: "Not logged in".into() });
    assert_eq!(conversation.attention(), Attention::Failed);
    conversation.questions.push(zerod::model::Question { id: "q".into(), item: None, fields: vec![] });
    assert_eq!(conversation.attention(), Attention::NeedsYou, "a question beats everything");
    conversation.questions.clear();
    conversation.status = Status::Offline;
    conversation.failure = None;
    assert_eq!(conversation.attention(), Attention::Offline);
}

fn session(provider: Provider) -> Session {
    let (events, _) = broadcast::channel(4096);
    Session::new(Conversation::new("s1", provider, "/work/project"), None, events).unwrap()
}

/// Lets the paused clock run `minutes` forward, a tick at a time, so the session's watchdog runs on the way.
async fn wait_minutes(minutes: u64) {
    for _ in 0..minutes * 4 { tokio::time::sleep(Duration::from_secs(15)).await }
}

#[tokio::test(start_paused = true)]
async fn a_session_with_no_word_from_its_agent_for_ten_minutes_is_stuck() {
    let session = session(Provider::Codex);
    let script = vec![json!({"in": {"method": "turn/started", "params": {"turn": {"id": "u"}}}})];
    let (transport, _) = play(script);
    session.attach(transport);
    wait_minutes(9).await;
    assert_eq!(session.snapshot().stalled, None, "nine minutes is still thinking");
    wait_minutes(2).await;
    assert_eq!(session.snapshot().stalled.as_deref(), Some("No word from Codex for 10 minutes"));
    assert_eq!(session.snapshot().attention(), Attention::Stuck);
}

#[tokio::test(start_paused = true)]
async fn waiting_on_arsen_is_not_stuck() {
    let session = session(Provider::Codex);
    let (transport, _) = play(fixture("codex-command"));
    session.start(transport, zerod::session::Message::text("ls"), Default::default()).await.unwrap();
    wait_minutes(30).await;
    let now = session.snapshot();
    assert!(!now.approvals.is_empty());
    assert_eq!(now.stalled, None);
}

#[tokio::test(start_paused = true)]
async fn a_command_running_for_half_an_hour_is_stuck_until_it_ends() {
    let session = session(Provider::Codex);
    let started = json!({"in": {"method": "item/started", "params": {"turnId": "u", "item": {"type": "commandExecution", "id": "c1",
        "command": "bin/rails test", "cwd": "/w", "status": "inProgress", "commandActions": []}}}});
    let (zero_side, runtime_side) = tokio::io::duplex(1 << 16);
    let (read, write) = tokio::io::split(zero_side);
    let (_runtime_read, mut runtime_write) = tokio::io::split(runtime_side);
    use tokio::io::AsyncWriteExt;
    let line = |v: &serde_json::Value| format!("{}\n", v);
    runtime_write.write_all(line(&json!({"method": "turn/started", "params": {"turn": {"id": "u"}}})).as_bytes()).await.unwrap();
    runtime_write.write_all(line(&started["in"]).as_bytes()).await.unwrap();
    session.attach(zerod::session::Transport::new(read, write));
    // Output keeps coming, so the agent isn't silent, but the command never ends.
    for _ in 0..31 {
        runtime_write.write_all(line(&json!({"method": "item/commandExecution/outputDelta", "params": {"turnId": "u", "itemId": "c1", "delta": "."}})).as_bytes()).await.unwrap();
        wait_minutes(1).await;
    }
    assert_eq!(session.snapshot().stalled.as_deref(), Some("bin/rails test has been running for 30 minutes"));
    let done = json!({"method": "item/completed", "params": {"turnId": "u", "item": {"type": "commandExecution", "id": "c1", "command": "bin/rails test",
        "cwd": "/w", "status": "completed", "exitCode": 0, "commandActions": []}}});
    runtime_write.write_all(line(&done).as_bytes()).await.unwrap();
    wait_minutes(1).await;
    assert_eq!(session.snapshot().stalled, None);
}

#[tokio::test(start_paused = true)]
async fn the_same_command_five_times_in_a_row_is_stuck() {
    let session = session(Provider::Codex);
    let mut script = vec![json!({"in": {"method": "turn/started", "params": {"turn": {"id": "u"}}}})];
    let command = |i: usize| json!({"method": "item/completed", "params": {"turnId": "u", "item": {"type": "commandExecution", "id": format!("c{i}"),
        "command": "gh pr checks 42", "cwd": "/w", "status": "completed", "exitCode": 1, "commandActions": []}}});
    for i in 0..7 { script.push(json!({"in": command(i)})) }
    let (transport, seen) = play(script);
    session.attach(transport);
    wait_minutes(1).await;
    assert_eq!(session.snapshot().stalled.as_deref(), Some("Ran gh pr checks 42 7 times in a row"), "the whole run is counted, not the five that make it one");
    // Another kind of step between is work, not a loop: the run starts over.
    seen.say(json!({"method": "item/completed", "params": {"turnId": "u", "item": {"type": "mcpToolCall", "id": "t1", "server": "linear", "tool": "list_issues", "arguments": {}, "status": "completed"}}}));
    seen.say(command(7));
    wait_minutes(1).await;
    assert_eq!(session.snapshot().stalled, None);
}

/// A turn of the agent's ending on `error`, as its adapter reports one: the error, and its failure worked out from it.
async fn fails(session: &Session, n: usize, error: &str) {
    session.change(zerod::model::Change::Status { status: Status::Working, turn: Some(format!("t{n}")), error: None });
    session.change(zerod::model::Change::Failed { failure: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
    session.change(zerod::model::Change::Failed { failure: Some(zerod::model::Failure { kind: FailureKind::of(error), message: error.into() }) });
    session.change(zerod::model::Change::Status { status: Status::Idle, turn: None, error: Some(error.into()) });
    tokio::time::sleep(Duration::from_millis(300)).await;
}

/// A task whose turn ended on `error`, its agent keeping what Zero sends it.
async fn failed_task(name: &str, error: &str) -> (std::sync::Arc<zerod::daemon::Daemon>, String, std::sync::Arc<std::sync::Mutex<String>>) {
    let home = crate::common::temp_dir(name);
    let sent = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let daemon = zerod::daemon::Daemon::open(&home.join("zerod"), crate::endings::listening(sent.clone())).unwrap();
    let id = daemon.start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    fails(&daemon.session(&id).unwrap(), 1, error).await;
    (daemon, id, sent)
}

#[tokio::test]
async fn signed_out_zeros_words_wait_and_the_users_go() {
    // Every event it follows would start a turn that fails the same way: they wait for a turn that works.
    let (daemon, id, sent) = failed_task("health-signed-out", "Failed to authenticate: OAuth session expired and could not be refreshed").await;
    daemon.notify(&id, "1 new event on what you follow").unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!sent.lock().unwrap().contains("1 new event"), "nothing for Zero's words while signed out");
    // The user's own (signed in again, say so): they go.
    daemon.queue(&id, "Signed in again, carry on", &[]).unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(sent.lock().unwrap().contains("Signed in again"));
    assert!(!sent.lock().unwrap().contains("1 new event"), "still waiting for a turn that works");
}

#[tokio::test]
async fn a_turn_ended_by_a_server_error_is_carried_on_three_times_at_most() {
    let error = "API Error: Server error mid-response. The response above may be incomplete.";
    let (daemon, id, sent) = failed_task("health-server-error", error).await;
    let carried = || sent.lock().unwrap().matches(zerod::daemon::CARRY_ON_AFTER_ERROR).count();
    assert_eq!(carried(), 1);
    let session = daemon.session(&id).unwrap();
    for n in 2..6 { fails(&session, n, error).await }
    assert_eq!(carried(), 3, "then it's the user's to see");
}

#[tokio::test]
async fn signed_out_holds_zeros_words_for_every_task_on_that_account_until_a_turn_works() {
    // One task finding the sign-in expired is enough: the others on the same account wait too, rather than each
    // failing on its next event (a lead on a worker's report of it, say).
    let expired = "Failed to authenticate: OAuth session expired and could not be refreshed";
    let home = crate::common::temp_dir("health-account-out");
    let sent = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let daemon = zerod::daemon::Daemon::open(&home.join("zerod"), crate::endings::listening(sent.clone())).unwrap();
    let start = || daemon.start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap();
    let (failed, other) = (start(), start());
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&failed, &other] { daemon.session(id).unwrap().change(zerod::model::Change::Status { status: Status::Idle, turn: None, error: None }) }
    tokio::time::sleep(Duration::from_millis(100)).await;
    fails(&daemon.session(&failed).unwrap(), 1, expired).await;
    daemon.notify(&other, "A schedule came due").unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!sent.lock().unwrap().contains("A schedule came due"), "held on the account, not tried");
    // Signed in again, the user's own turn works: what was held goes.
    let session = daemon.session(&failed).unwrap();
    session.change(zerod::model::Change::Status { status: Status::Working, turn: Some("t2".into()), error: None });
    session.change(zerod::model::Change::Failed { failure: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
    session.change(zerod::model::Change::Status { status: Status::Idle, turn: None, error: None });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(sent.lock().unwrap().contains("A schedule came due"));
}
