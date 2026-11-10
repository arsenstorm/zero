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
    fn name(&self) -> &str {
        "fake"
    }
    fn can_reach(&self, agent: &AgentIdentity) -> bool {
        agent.name != "unreachable"
    }
    fn send<'a>(&'a self, text: &'a str, agent: &'a AgentIdentity) -> Fut<'a, Result<(), String>> {
        Box::pin(async move {
            self.sent.lock().unwrap().push((agent.name.clone(), text.to_string()));
            Ok(())
        })
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
        if let Some(ask) = inbox.ask(id)
            && test(&ask)
        {
            return ask;
        }
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
    while let Ok(event) = events.try_recv() {
        if let InboxEvent::Output { chunk, .. } = event {
            streamed += &chunk
        }
    }
    assert!(streamed.contains("hi"));
}

#[tokio::test]
async fn done_takes_a_second_word_with_its_token() {
    // Asked to be done, it isn't yet: told what done means, and given a token to confirm it with. A wrong or used token
    // is refused; the right one marks it done, confirmed.
    let s = inbox();
    let agent = ask(AskKind::Note, "x", &[]).agent;
    let refused = s.done(&agent, "Merged and deployed", None).unwrap_err();
    assert!(refused.contains("end to end") && refused.contains("--confirm "), "{refused}");
    let token = refused
        .split("--confirm ")
        .nth(1)
        .unwrap()
        .split_whitespace()
        .next()
        .unwrap()
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_string();
    assert!(s.done(&agent, "Merged and deployed", Some("nope")).is_err(), "a wrong token");
    assert!(s.done(&agent, "Merged and deployed", Some(&token)).is_ok());
    assert!(
        s.asks()
            .iter()
            .any(|a| a.kind == AskKind::Note && a.confirmed && a.status.as_deref() == Some("done") && a.body == "Merged and deployed")
    );
    assert!(s.done(&agent, "Merged and deployed", Some(&token)).is_err(), "a token is good once");
}

#[tokio::test]
async fn blocked_takes_a_second_word_with_its_token() {
    // As done: told what blocked means (can't go on at all; waiting on a review or CI isn't it) and given a token.
    let s = inbox();
    let agent = ask(AskKind::Note, "x", &[]).agent;
    let refused = s.blocked(&agent, "The vendor's API is down", None).unwrap_err();
    assert!(refused.contains("--waiting") && refused.contains("--confirm "), "{refused}");
    let token = refused
        .split("--confirm ")
        .nth(1)
        .unwrap()
        .split_whitespace()
        .next()
        .unwrap()
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_string();
    assert!(s.done(&agent, "x", Some(&token)).is_err(), "a blocked token doesn't confirm done");
    assert!(s.blocked(&agent, "The vendor's API is down", Some(&token)).is_ok());
    assert!(s.asks().iter().any(|a| a.kind == AskKind::Note && a.confirmed && a.status.as_deref() == Some("blocked")));
    assert!(s.blocked(&agent, "The vendor's API is down", Some(&token)).is_err(), "a token is good once");
}

#[tokio::test]
async fn done_can_be_the_users_word() {
    // Unsure: the user is asked, and their Done marks it done, confirmed; Not yet doesn't.
    let s = inbox();
    let agent = ask(AskKind::Note, "x", &[]).agent;
    let question = s.ask_done(&agent, "PR open, CI green");
    s.choose(&question.id, 0);
    until(&s, &question.id, |a| a.state == AskState::Answered).await;
    assert!(s.asks().iter().any(|a| a.kind == AskKind::Note && a.confirmed && a.status.as_deref() == Some("done")));
    let other = s.ask_done(&agent, "PR open");
    let notes = s.asks().iter().filter(|a| a.confirmed).count();
    s.choose(&other.id, 1);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(s.asks().iter().filter(|a| a.confirmed).count(), notes, "not yet: nothing confirmed");
}

#[tokio::test]
async fn a_run_withdrawn_while_it_runs_is_stopped() {
    // The agent took it back (it was taking too long): nothing else would stop it, and with its ask closed the user
    // had no way to. It stops, and its ask stays withdrawn when it ends, not answered.
    let s = inbox();
    let marker = std::env::temp_dir().join(format!("zero-withdrawn-run-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);
    let mut run = ask(AskKind::Run, "Slow", &["Run", "Decline"]);
    // Slow enough that stopping it is sure to beat it, on a busy CI runner too (a second wasn't).
    run.command = Some(format!("sleep 3; touch {}", marker.display()));
    run.cwd = Some("/tmp".into());
    let a = s.create(run, false);
    s.choose(&a.id, 0);
    until(&s, &a.id, |a| a.state == AskState::Running && a.run.is_some()).await;
    s.withdraw(&a.id, Some("taking too long"));
    tokio::time::sleep(Duration::from_millis(4000)).await;
    assert!(!marker.exists(), "the command was stopped before it got further");
    let after = s.ask(&a.id).unwrap();
    assert!(after.state == AskState::Expired && after.status.as_deref() == Some("withdrawn"), "{:?} {:?}", after.state, after.status);
    assert!(after.output.contains("Stopped"), "the card says so: {}", after.output);
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
    for _ in 0..50 {
        if !fake.stopped.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await
    }
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
    // What an expired ask means is written down: the recommendation, said so; never something others would see.
    assert!(Inbox::delivery_text(&expired).contains("recommended") && Inbox::delivery_text(&expired).contains("others will see"));
}

#[tokio::test]
async fn open_asks_survive_a_relaunch() {
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
    // Steps for the user to run themselves, then say how it went: open while they run it, whatever else they type.
    let mut steps = ask(AskKind::Choice, "Run the query, then tell me", &["Ran it", "Not now"]);
    steps.command = Some("SELECT 1".into());
    let steps = s.create(steps, false);
    assert_eq!(s.prompted(&agent("test"), "go ahead and merge it"), "human");
    let withdrawn = s.ask(&question.id).unwrap();
    assert_eq!((withdrawn.state, withdrawn.status.as_deref()), (AskState::Expired, Some("withdrawn")));
    assert_eq!(s.ask(&run.id).unwrap().state, AskState::Waiting);
    assert_eq!(s.ask(&steps.id).unwrap().state, AskState::Waiting);
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

/// A run the agent marks as one of a kind (`--allow PREFIX`: a read-only query's command, any file) can be allowed for
/// the rest of the task: the next of that kind from the same task runs without asking. Only commands that are the prefix
/// and one plain path after it: anything else (another command chained on) still asks. Other tasks still ask.
#[tokio::test]
async fn a_kind_of_run_allowed_for_a_task_runs_without_asking_again() {
    let s = inbox();
    let dir = std::env::temp_dir().join(format!("allow-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let prefix = format!("cd {} && cat <", dir.display());
    std::fs::write(dir.join("q1.rb"), "one").unwrap();
    std::fs::write(dir.join("q2.rb"), "two").unwrap();
    let task = AgentIdentity { session: Some("01a1task".into()), ..agent("lead") };
    let query = |file: &str, who: &AgentIdentity| {
        let mut run = Ask::new(AskKind::Run, "Production read", who.clone(), 3600);
        run.options = ["Run", "Reject", "Suggest something else…"].map(String::from).to_vec();
        run.command = Some(format!("{prefix} {file}"));
        run.allow = Some(prefix.clone());
        run
    };
    let first = s.create(query("q1.rb", &task), false);
    let allow = first.options.iter().position(|o| o.contains("for this task")).expect("offered to allow its kind");
    assert_eq!(first.options[0], "Run");
    s.choose(&first.id, allow);
    let ran = until(&s, &first.id, |a| a.state == AskState::Answered).await;
    assert!(ran.output.contains("one"), "it runs, as Run does: {ran:?}");
    let second = s.create(query("q2.rb", &task), false);
    let ran = until(&s, &second.id, |a| a.state == AskState::Answered).await;
    assert!(ran.output.contains("two") && ran.answer.as_deref().is_some_and(|a| a.contains("allowed")), "{ran:?}");
    // Something chained on isn't that kind: asked.
    let chained = s.create(query("q2.rb; rm -rf /tmp/x", &task), false);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(s.ask(&chained.id).unwrap().state, AskState::Waiting);
    // Another task: asked.
    let other = s.create(query("q2.rb", &AgentIdentity { session: Some("01a1other".into()), ..agent("other") }), false);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(s.ask(&other.id).unwrap().state, AskState::Waiting);
    // Reject is still a no.
    let rejected = s.create(query("q1.rb", &AgentIdentity { session: Some("01a1third".into()), ..agent("third") }), false);
    s.choose(&rejected.id, rejected.options.iter().position(|o| o == "Reject").unwrap());
    until(&s, &rejected.id, |a| a.state == AskState::Declined).await;
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
    let ask: Ask = serde_json::from_str(line).unwrap();
    assert_eq!(serde_json::to_value(&ask).unwrap(), without_retired(serde_json::from_str(line).unwrap()));
    // And the real log, where there is one: nothing in it may be lost on the way through zerod.
    let real = std::path::Path::new(&std::env::var("HOME").unwrap_or_default()).join(".zero/asks.jsonl");
    if let Ok(text) = std::fs::read_to_string(real) {
        for line in text.lines() {
            let ask: Ask = serde_json::from_str(line).unwrap_or_else(|e| panic!("{e}: {line}"));
            assert_eq!(serde_json::to_value(&ask).unwrap(), without_retired(serde_json::from_str(line).unwrap()));
        }
    }
}

/// A line as zerod writes it back: what an agent had from when Zero reached Solo and Rex (its Solo process and project,
/// its Rex session) is read past.
fn without_retired(mut line: serde_json::Value) -> serde_json::Value {
    if let Some(agent) = line["agent"].as_object_mut() {
        for key in ["soloProcessID", "soloProjectID", "refGroup"] {
            agent.remove(key);
        }
    }
    line
}

#[tokio::test]
async fn a_run_outlives_zerod_and_ends_with_its_real_outcome() {
    // The user's command (a production deploy, say) runs where zerod's restart can't reach it: the zerod after picks
    // up its output and its exit code, never a guess.
    let log = std::env::temp_dir().join(format!("zerod-inbox-runs-{}.jsonl", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let first = Inbox::open(Some(log.clone()), vec![]);
    first.configure(Duration::from_millis(10), 3600);
    let mut run = ask(AskKind::Run, "Deploy", &["Run", "Reject"]);
    run.command = Some("echo started; sleep 1; echo finished; exit 3".into());
    let a = first.create(run, false);
    first.choose(&a.id, 0);
    until(&first, &a.id, |a| a.state == AskState::Running && a.output.contains("started")).await;
    drop(first); // zerod restarting mid-run
    let again = Inbox::open(Some(log.clone()), vec![]);
    assert_eq!(again.ask(&a.id).unwrap().state, AskState::Running, "still running, not expired");
    let done = until(&again, &a.id, |a| a.state == AskState::Answered).await;
    assert_eq!(done.exit_code, Some(3));
    assert!(done.output.contains("started") && done.output.contains("finished"), "{}", done.output);
    let _ = std::fs::remove_file(&log);
}

#[test]
fn a_run_zero_lost_track_of_says_so_never_success_or_expiry() {
    // Cut off with nothing to tell how it ended: the agent must check before running it again, not read "it never ran".
    let log = std::env::temp_dir().join(format!("zerod-inbox-lost-{}.jsonl", std::process::id()));
    let mut run = ask(AskKind::Run, "Deploy", &["Run", "Reject"]);
    run.command = Some("bin/deploy production".into());
    run.state = AskState::Running;
    std::fs::write(&log, serde_json::to_string(&run).unwrap() + "\n").unwrap();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let lost = rt.block_on(async { Inbox::open(Some(log.clone()), vec![]).ask(&run.id).unwrap() });
    assert_eq!((lost.state, lost.exit_code, lost.status.as_deref()), (AskState::Answered, None, Some("lost")));
    let told = Inbox::delivery_text(&lost);
    assert!(told.contains("lost track") && told.contains("before running it again"), "{told}");
    assert!(!told.contains("succeeded") && !told.contains("expired"), "{told}");
    let _ = std::fs::remove_file(&log);
}

#[test]
fn a_terminals_output_reads_as_plain_text_even_cut_mid_sequence() {
    use zerod::runs::plain;
    let mut carry = vec![];
    // Colours and a title go; CRLF is a newline; a sequence and a character cut at a read's end wait for the rest.
    let first = plain(&mut carry, b"\x1b]0;deploy\x07\x1b[32mok\x1b[0m\r\nmigrating \xe2\x9c");
    let second = plain(&mut carry, b"\x93 done\x1b[");
    let third = plain(&mut carry, b"1mbold\x1b[0m\r\n");
    assert_eq!(first + &second + &third, "ok\nmigrating \u{2713} donebold\n");
    assert!(carry.is_empty());
}

#[tokio::test]
async fn every_ask_with_options_lets_the_user_answer_in_their_own_words() {
    // The options are the agent's guesses: "Something else…" is always there, so the user is never boxed in. One the
    // agent already gave words to isn't doubled, and asks that aren't choices are left alone.
    let inbox = zerod::inbox::Inbox::open(None, vec![]);
    let agent = zerod::ask::AgentIdentity { name: "zerod-s1".into(), host: "mac".into(), ..Default::default() };
    let mut choice = zerod::ask::Ask::new(zerod::ask::AskKind::Choice, "Ship it?", agent.clone(), 3600);
    choice.options = vec!["Yes".into(), "No".into()];
    assert_eq!(inbox.create(choice, false).options, ["Yes", "No", "Something else…"]);
    let mut worded = zerod::ask::Ask::new(zerod::ask::AskKind::Choice, "Which?", agent.clone(), 3600);
    worded.options = vec!["A".into(), "Other…".into()];
    assert_eq!(inbox.create(worded, false).options, ["A", "Other…"]);
    let question = zerod::ask::Ask::new(zerod::ask::AskKind::Question, "Why?", agent, 3600);
    assert!(inbox.create(question, false).options.is_empty(), "a question is answered in words already");
}
