//! The inbox: asks from agents, their answers, runs on the user's machine, and delivery to agents that didn't wait. Ported
//! from the Swift app's StoreTests, which this replaces, plus the log it shares with the app.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use zerod::ask::{AgentIdentity, Ask, AskKind, AskState, Delivery, Time};
use zerod::inbox::{Fut, Inbox, InboxEvent, Runtime};

fn agent(name: &str) -> AgentIdentity {
    AgentIdentity { name: name.into(), host: "mac".into(), ..Default::default() }
}

fn ask(kind: AskKind, title: &str, options: &[&str]) -> Ask {
    let mut ask = Ask::new(kind, title, agent("test"), 3600);
    ask.options = options.iter().map(|o| o.to_string()).collect();
    ask
}

/// A runtime that reaches every agent: what it was sent, which agents it says are gone, and which it stopped.
#[derive(Default)]
struct Fake {
    sent: Mutex<Vec<(String, String)>>,
    gone: Mutex<HashSet<String>>,
    stopped: Mutex<Vec<String>>,
}

impl Runtime for Fake {
    fn name(&self) -> &str { "fake" }
    fn can_reach(&self, agent: &AgentIdentity) -> bool { agent.name != "unreachable" }
    fn send<'a>(&'a self, text: &'a str, agent: &'a AgentIdentity) -> Fut<'a, Result<(), String>> {
        Box::pin(async move { self.sent.lock().unwrap().push((agent.name.clone(), text.to_string())); Ok(()) })
    }
    fn gone<'a>(&'a self, agents: &'a [AgentIdentity]) -> Fut<'a, HashSet<String>> {
        Box::pin(async move { agents.iter().map(|a| a.name.clone()).filter(|n| self.gone.lock().unwrap().contains(n)).collect() })
    }
    fn stop<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, ()> {
        Box::pin(async move { self.stopped.lock().unwrap().push(agent.name.clone()) })
    }
}

fn inbox() -> Arc<Inbox> {
    inbox_with(vec![])
}

fn inbox_with(runtimes: Vec<Arc<dyn Runtime>>) -> Arc<Inbox> {
    let inbox = Inbox::open(None, runtimes);
    inbox.configure(Duration::from_millis(50), 3600);
    inbox
}

async fn until(inbox: &Inbox, id: &str, test: impl Fn(&Ask) -> bool) -> Ask {
    for _ in 0..300 {
        if let Some(ask) = inbox.ask(id) && test(&ask) { return ask }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out: {:#?}", inbox.ask(id));
}

#[tokio::test]
async fn a_choice_can_be_taken_back_and_then_answered() {
    let s = inbox();
    let a = s.create(ask(AskKind::Choice, "Pick", &["Yes", "No"]), false);
    s.choose(&a.id, 0);
    assert_eq!(s.ask(&a.id).unwrap().state, AskState::Pending);
    assert!(s.take_back(&a.id));
    assert_eq!(s.ask(&a.id).unwrap().state, AskState::Waiting);
    s.choose(&a.id, 1);
    let done = until(&s, &a.id, |a| a.state == AskState::Answered).await;
    assert_eq!((done.answer.as_deref(), done.choice), (Some("No"), Some(1)));
}

#[tokio::test]
async fn the_options_after_the_first_decline_an_approval() {
    let s = inbox();
    let a = s.create(ask(AskKind::Approve, "Go?", &["Yes", "No", "No, and say why…"]), false);
    s.choose(&a.id, 1);
    until(&s, &a.id, |a| a.state == AskState::Declined).await;
    let b = s.create(ask(AskKind::Approve, "Go?", &["Yes", "No", "No, and say why…"]), false);
    s.answer(&b.id, 2, "use pnpm");
    let declined = until(&s, &b.id, |a| a.state == AskState::Declined).await;
    assert_eq!(declined.answer.as_deref(), Some("No, and say why: use pnpm"));
    let permission = s.create(ask(AskKind::Permission, "Run", &["Allow", "Always allow", "Deny"]), false);
    s.choose(&permission.id, 1);
    assert_eq!(until(&s, &permission.id, |a| a.state.is_final()).await.state, AskState::Answered, "a permission declines only with Deny");
}

#[tokio::test]
async fn a_typed_reply_answers() {
    let s = inbox();
    let a = s.create(ask(AskKind::Question, "Which?", &[]), false);
    s.reply(&a.id, "the second one");
    let done = until(&s, &a.id, |a| a.state == AskState::Answered).await;
    assert_eq!(done.answer.as_deref(), Some("the second one"));
}

#[tokio::test(start_paused = true)]
async fn an_unanswered_ask_expires() {
    let s = inbox();
    let mut slow = ask(AskKind::Question, "Slow", &[]);
    slow.expires_at = Time(slow.created_at.0 + 60);
    let a = s.create(slow, false);
    tokio::time::sleep(Duration::from_secs(59)).await;
    assert_eq!(s.ask(&a.id).unwrap().state, AskState::Waiting);
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(s.ask(&a.id).unwrap().state, AskState::Expired);
}

#[tokio::test]
async fn a_run_streams_its_output_and_ends_with_its_exit_code() {
    let s = inbox();
    let mut events = s.subscribe();
    let mut run = ask(AskKind::Run, "Run", &["Run", "Decline"]);
    run.command = Some("printf hi; exit 3".into());
    run.cwd = Some("/tmp".into());
    let a = s.create(run, false);
    s.choose(&a.id, 0);
    let done = until(&s, &a.id, |a| a.state == AskState::Answered).await;
    assert_eq!(done.exit_code, Some(3));
    assert!(done.output.contains("hi"));
    let mut streamed = String::new();
    while let Ok(event) = events.try_recv() { if let InboxEvent::Output { chunk, .. } = event { streamed += &chunk } }
    assert!(streamed.contains("hi"));
}

#[tokio::test]
async fn a_run_that_prints_megabytes_keeps_only_its_end() {
    let s = inbox();
    let mut run = ask(AskKind::Run, "Big", &["Run", "Decline"]);
    run.command = Some("head -c 3000000 /dev/zero | tr '\\0' x; echo; echo THE-END".into());
    let a = s.create(run, false);
    s.choose(&a.id, 0);
    let done = until(&s, &a.id, |a| a.state == AskState::Answered).await;
    assert!(done.output.len() <= 300_000, "{} bytes kept", done.output.len());
    assert!(done.output.trim_end().ends_with("THE-END"));
    assert!(done.output.starts_with("(Zero kept only the end"), "{}", &done.output[..80]);
}

#[tokio::test]
async fn async_answers_are_delivered_and_show_when_they_cannot_be() {
    let fake = Arc::new(Fake::default());
    let s = inbox_with(vec![fake.clone()]);
    let mut unwaited = ask(AskKind::Choice, "Pick", &["Yes", "No"]);
    unwaited.waits = Some(false);
    let a = s.create(unwaited.clone(), false);
    s.choose(&a.id, 0);
    let delivered = until(&s, &a.id, |a| a.delivery == Some(Delivery::Delivered)).await;
    assert_eq!(delivered.state, AskState::Answered);
    let sent = fake.sent.lock().unwrap().clone();
    assert_eq!(sent[0].1, format!("The user answered your ask {} (\"Pick\"): Yes", a.id));
    let mut lost = unwaited.clone();
    lost.agent = agent("unreachable");
    let b = s.create(lost, false);
    s.choose(&b.id, 0);
    assert_eq!(until(&s, &b.id, |a| a.delivery.is_some() && a.delivery != Some(Delivery::Sending)).await.delivery, Some(Delivery::Failed));
    let c = s.create(ask(AskKind::Choice, "Pick", &["Yes", "No"]), false);
    s.choose(&c.id, 0);
    assert_eq!(until(&s, &c.id, |a| a.state == AskState::Answered).await.delivery, None, "a waiting agent reads its own answer");
}

#[tokio::test]
async fn agents_closed_in_their_runtime_leave_and_removed_ones_stop() {
    let fake = Arc::new(Fake::default());
    let s = inbox_with(vec![fake.clone()]);
    for name in ["a", "b"] {
        let mut note = Ask::new(AskKind::Note, "Hi", agent(name), 3600);
        note.status = None;
        s.create(note, false);
    }
    fake.gone.lock().unwrap().insert("a".into());
    s.refresh_liveness().await;
    assert!(s.is_closed("a") && !s.is_closed("b"));
    assert!(fake.stopped.lock().unwrap().is_empty(), "already gone: nothing to stop");
    s.close_agent("b", true);
    for _ in 0..50 { if !fake.stopped.lock().unwrap().is_empty() { break } tokio::time::sleep(Duration::from_millis(10)).await }
    assert_eq!(*fake.stopped.lock().unwrap(), ["b"]);
}

#[tokio::test]
async fn removing_an_agent_withdraws_its_open_asks() {
    let s = inbox();
    let a = s.create(ask(AskKind::Question, "Merge?", &[]), false);
    s.close_agent("test", true);
    assert_eq!(s.ask(&a.id).unwrap().state, AskState::Expired);
    assert!(s.is_closed("test"));
    assert!(!s.can_stop("test"), "no runtime reaches it");
}

#[test]
fn agents_that_did_not_wait_are_told_what_happened() {
    let mut run = ask(AskKind::Run, "Count", &[]);
    run.command = Some("sh count.sh".into());
    run.state = AskState::Answered;
    run.exit_code = Some(1);
    run.output = "count.sh: line 3: psql: command not found\n".into();
    let text = Inbox::delivery_text(&run);
    assert!(text.contains("FAILED with exit 1") && text.contains("psql: command not found") && text.contains("sh count.sh"), "{text}");
    run.state = AskState::Declined;
    run.answer = Some("use the replica".into());
    assert_eq!(Inbox::delivery_text(&run), format!("The user rejected your command {} (`sh count.sh`): use the replica", run.id));
    let mut expired = ask(AskKind::Question, "Merge?", &[]);
    expired.state = AskState::Expired;
    assert!(Inbox::delivery_text(&expired).contains("expired without an answer"));
}

#[tokio::test]
async fn open_asks_survive_a_relaunch_and_a_run_cut_off_by_one_expires() {
    let log = std::env::temp_dir().join(format!("zerod-inbox-{}.jsonl", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let first = Inbox::open(Some(log.clone()), vec![]);
    first.configure(Duration::from_secs(60), 3600);
    let open = first.create(ask(AskKind::Question, "Merge?", &[]), false);
    let staged = first.create(ask(AskKind::Choice, "Pick", &["Yes", "No"]), false);
    first.choose(&staged.id, 0);
    let again = Inbox::open(Some(log.clone()), vec![]);
    assert_eq!(again.ask(&open.id).unwrap().state, AskState::Waiting);
    let back = again.ask(&staged.id).unwrap();
    assert_eq!((back.state, back.answer), (AskState::Waiting, None), "an answer still being staged waits again");
    let _ = std::fs::remove_file(&log);
}

#[test]
fn trouble_an_agent_cannot_report_is_read_off_its_screen() {
    assert_eq!(Inbox::trouble("⏺ working\n⎿ Not logged in · Please run /login\n❯ ").as_deref(), Some("Not logged in · Please run /login"));
    assert_eq!(Inbox::trouble("⏺ All tests pass.\n❯ "), None);
}

#[tokio::test]
async fn words_typed_in_the_terminal_withdraw_open_questions_but_not_runs() {
    let s = inbox();
    let question = s.create(ask(AskKind::Choice, "Merge?", &["Yes", "No"]), false);
    let mut run = ask(AskKind::Run, "Count", &[]);
    run.command = Some("sh c.sh".into());
    let run = s.create(run, false);
    assert_eq!(s.prompted(&agent("test"), "go ahead and merge it"), "human");
    let withdrawn = s.ask(&question.id).unwrap();
    assert_eq!((withdrawn.state, withdrawn.status.as_deref()), (AskState::Expired, Some("withdrawn")));
    assert_eq!(s.ask(&run.id).unwrap().state, AskState::Waiting);
}

#[tokio::test]
async fn saying_where_it_is_again_rewrites_the_last_note() {
    let s = inbox();
    let mut first = Ask::new(AskKind::Note, "Update", agent("test"), 3600);
    first.body = "Running specs".into();
    let first = s.create(first, false);
    let mut second = Ask::new(AskKind::Note, "Update", agent("test"), 3600);
    second.body = "Still running specs".into();
    second.needs = Some("review the plan".into());
    let second = s.create(second, false);
    assert_eq!(first.id, second.id);
    let rewritten = s.ask(&first.id).unwrap();
    assert_eq!((rewritten.body.as_str(), rewritten.needs.as_deref()), ("Still running specs", Some("review the plan")));
    let mut done = Ask::new(AskKind::Note, "Update", agent("test"), 3600);
    done.status = Some("done".into());
    assert_ne!(s.create(done, false).id, first.id);
}

#[tokio::test]
async fn identical_runs_share_one_card_and_its_outcome() {
    let s = inbox();
    let mut run = ask(AskKind::Run, "Renew", &["Run", "Reject"]);
    run.command = Some("bin/renew".into());
    run.cwd = Some("/tmp".into());
    let a = s.create(run.clone(), false);
    run.agent = agent("other");
    let b = s.create(run, false);
    assert_eq!(b.same_as.as_deref(), Some(a.id.as_str()));
    s.choose(&a.id, 1);
    until(&s, &a.id, |a| a.state == AskState::Declined).await;
    assert_eq!(until(&s, &b.id, |a| a.state.is_final()).await.state, AskState::Declined);
}

#[tokio::test]
async fn a_cli_call_joins_the_agent_zero_knows_on_the_same_process() {
    let s = inbox();
    let mut started = Ask::new(AskKind::Note, "Started", AgentIdentity { solo_process_id: Some(7), solo_project_id: Some(13), ..agent("claude-7") }, 3600);
    started.status = Some("done".into());
    s.create(started, false);
    let note = s.create(Ask::new(AskKind::Note, "Update", AgentIdentity { solo_process_id: Some(7), ..agent("solo-7") }, 3600), false);
    assert_eq!(note.agent.name, "claude-7");
    assert_eq!(note.agent.solo_project_id, Some(13));
}

#[test]
fn a_prompts_gist_is_its_first_five_words() {
    assert_eq!(Inbox::gist("fix the flaky checkout spec, then open a PR\nmore detail").as_deref(), Some("Fix the flaky checkout spec…"));
    assert_eq!(Inbox::gist("add dark mode").as_deref(), Some("Add dark mode"));
    assert_eq!(Inbox::gist("hi"), None);
}

/// Every field the Swift app writes, read and written back as the same JSON.
#[test]
fn the_log_reads_and_writes_as_the_app_wrote_it() {
    let line = r#"{"id":"nds8sn","kind":"permission","title":"Write notes.md","body":"why","options":["Allow","Deny"],"command":"notes.md",
        "cwd":"/w","agent":{"name":"zerod-01a1","host":"mac","cwd":"/w","soloProcessID":7,"soloProjectID":13,"ticket":"WEB-1","label":"L",
        "session":"s","account":"a@b","runtime":"zerod","ref":"01a1","refGroup":"g","launch":["claude","-p"]},"createdAt":"2026-10-26T12:44:00Z",
        "expiresAt":"2026-10-27T12:44:00Z","state":"answered","answer":"Allow","output":"","exitCode":0,"answeredAt":"2026-10-26T12:44:34Z",
        "status":"withdrawn","choice":0,"waits":false,"delivery":"delivered","detail":"d","script":"echo","sameAs":"abc123","request":"r1"}"#;
    let parsed: serde_json::Value = serde_json::from_str(line).unwrap();
    let ask: Ask = serde_json::from_str(line).unwrap();
    assert_eq!(serde_json::to_value(&ask).unwrap(), parsed);
    // And the real log, where there is one: nothing in it may be lost on the way through zerod.
    let real = std::path::Path::new(&std::env::var("HOME").unwrap_or_default()).join(".zero/asks.jsonl");
    if let Ok(text) = std::fs::read_to_string(real) {
        for line in text.lines() {
            let parsed: serde_json::Value = serde_json::from_str(line).unwrap();
            let ask: Ask = serde_json::from_str(line).unwrap_or_else(|e| panic!("{e}: {line}"));
            assert_eq!(serde_json::to_value(&ask).unwrap(), parsed);
        }
    }
}
