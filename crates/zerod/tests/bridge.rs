//! zerod's sessions in the inbox: each approval a permission ask, each field of a question an ask, and each session a dot
//! that follows its attention. Answered in the inbox, the session hears once; settled elsewhere, the ask is withdrawn.
//! Ported from the Swift app's Workspace tests, since the bridge is the daemon's now.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::{fixture, play, temp_dir};
use serde_json::json;
use zerod::ask::{Ask, AskKind, AskState};
use zerod::bridge::{Act, Bridge};
use zerod::daemon::{Daemon, Runtime};
use zerod::inbox::Inbox;
use zerod::model::*;

const SESSION: &str = "01a1aaaa00000001";

fn choices() -> Vec<Choice> {
    [("allow", "Allow", ChoiceKind::Allow), ("always", "Always allow Bash(make)", ChoiceKind::AllowAlways), ("deny", "Deny", ChoiceKind::Deny), ("stop", "Deny and stop", ChoiceKind::Stop)]
        .map(|(id, label, kind)| Choice { id: id.into(), label: label.into(), kind }).to_vec()
}

fn waiting() -> Conversation {
    let mut conversation = Conversation::new(SESSION, Provider::Claude, "/work");
    conversation.title = Some("Fix the build".into());
    conversation.status = Status::Waiting;
    conversation.approvals = vec![Approval {
        id: "r1".into(), item: Some("t1".into()), kind: ApprovalKind::Command, title: "Run make".into(), command: Some("make".into()),
        cwd: Some("/work".into()), reason: Some("Build it".into()), changes: vec![], choices: choices(),
    }];
    conversation
}

fn inbox(log: Option<std::path::PathBuf>) -> (Arc<Inbox>, Bridge) {
    let inbox = Inbox::open(log, vec![]);
    inbox.configure(Duration::from_millis(20), 3600);
    (inbox.clone(), Bridge::new(inbox))
}

/// The ask once its take-back window has passed.
async fn settled(inbox: &Inbox, id: &str) -> Ask {
    for _ in 0..500 {
        if let Some(ask) = inbox.ask(id).filter(|a| a.state.is_final()) { return ask }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("{id} never settled");
}

#[tokio::test]
async fn an_approval_becomes_one_permission_ask_with_the_providers_choices() {
    let (inbox, bridge) = inbox(None);
    bridge.sync(&[waiting()]);
    bridge.sync(&[waiting()]);
    let asks = inbox.open_asks();
    assert_eq!(asks.len(), 1, "a snapshot seen twice asks once");
    let ask = &asks[0];
    assert_eq!((ask.kind, ask.title.as_str(), ask.body.as_str(), ask.command.as_deref()), (AskKind::Permission, "Run make", "Build it", Some("make")));
    assert_eq!(ask.options, ["Allow", "Always allow Bash(make)", "Deny", "Deny and stop"]);
    assert_eq!((ask.agent.runtime.as_deref(), ask.agent.reference.as_deref()), (Some("zerod"), Some(SESSION)));
    assert_eq!((ask.agent.name.as_str(), ask.agent.label.as_deref()), ("zerod-01a1aaaa00000001", Some("Fix the build")));
}

#[tokio::test]
async fn answering_the_ask_tells_the_session_the_choice_once() {
    let (inbox, bridge) = inbox(None);
    bridge.sync(&[waiting()]);
    let ask = inbox.open_asks().remove(0);
    inbox.choose(&ask.id, 1);
    let ask = settled(&inbox, &ask.id).await;
    assert_eq!(bridge.heard(&ask, Some(&waiting())), Some(Act::Decide { session: SESSION.into(), approval: "r1".into(), choice: "always".into(), words: None }));
    assert_eq!(bridge.heard(&ask, Some(&waiting())), None, "once");
    bridge.sync(&[waiting()]);
    assert!(inbox.open_asks().is_empty(), "answered, not asked again while the session catches up");
}

#[tokio::test]
async fn an_approval_settled_elsewhere_withdraws_its_ask() {
    let (inbox, bridge) = inbox(None);
    bridge.sync(&[waiting()]);
    let ask = inbox.open_asks().remove(0);
    let mut resolved = waiting();
    resolved.approvals.clear();
    bridge.sync(&[resolved]);
    let withdrawn = inbox.ask(&ask.id).unwrap();
    assert_eq!((withdrawn.state, withdrawn.status.as_deref()), (AskState::Expired, Some("withdrawn")));
    assert_eq!(bridge.heard(&withdrawn, Some(&waiting())), None, "a withdrawn ask is not an answer");
}

#[tokio::test]
async fn after_a_restart_the_ask_still_waiting_is_the_one_answered() {
    let log = temp_dir("bridge-restart").join("asks.jsonl");
    let ask = {
        let (inbox, bridge) = inbox(Some(log.clone()));
        bridge.sync(&[waiting()]);
        inbox.open_asks().remove(0)
    };
    let (inbox, bridge) = inbox(Some(log));
    bridge.sync(&[waiting()]);
    assert_eq!(inbox.open_asks().iter().map(|a| a.id.clone()).collect::<Vec<_>>(), std::slice::from_ref(&ask.id), "the same ask, not a second one");
    inbox.choose(&ask.id, 0);
    let ask = settled(&inbox, &ask.id).await;
    assert!(matches!(bridge.heard(&ask, Some(&waiting())), Some(Act::Decide { choice, .. }) if choice == "allow"));
}

#[tokio::test]
async fn a_typed_reply_denies_and_says_why() {
    let (inbox, bridge) = inbox(None);
    bridge.sync(&[waiting()]);
    let ask = inbox.open_asks().remove(0);
    inbox.reply(&ask.id, "use the Makefile in build/");
    let ask = settled(&inbox, &ask.id).await;
    assert_eq!(bridge.heard(&ask, Some(&waiting())),
               Some(Act::Decide { session: SESSION.into(), approval: "r1".into(), choice: "deny".into(), words: Some("use the Makefile in build/".into()) }));
}

fn option(label: &str, description: Option<&str>) -> QuestionOption {
    QuestionOption { label: label.into(), description: description.map(String::from) }
}

fn asking(fields: Vec<Field>) -> Conversation {
    let mut conversation = waiting();
    conversation.approvals.clear();
    conversation.questions = vec![Question { id: "q1".into(), item: Some("t1".into()), fields }];
    conversation
}

fn cache() -> Field {
    Field { id: "0".into(), header: Some("Cache".into()), question: "Redis or Postgres?".into(), options: vec![option("Redis", Some("in the stack")), option("Postgres", None)],
            multiple: false, other: true, secret: false }
}

fn checks() -> Field {
    Field { id: "1".into(), header: Some("Checks".into()), question: "Which checks?".into(), options: vec![option("Lint", None), option("Tests", None)],
            multiple: false, other: false, secret: false }
}

#[tokio::test]
async fn each_field_of_a_question_is_an_ask_and_the_session_hears_once_all_are_answered() {
    let (inbox, bridge) = inbox(None);
    let conversation = asking(vec![cache(), checks()]);
    bridge.sync(std::slice::from_ref(&conversation));
    let mut asks = inbox.open_asks();
    asks.sort_by(|a, b| a.title.cmp(&b.title));
    assert_eq!(asks.iter().map(|a| a.title.as_str()).collect::<Vec<_>>(), ["Redis or Postgres?", "Which checks?"]);
    assert_eq!(asks[0].options, ["Redis", "Postgres", "Something else…"], "free text where the agent takes it");
    assert_eq!(asks[1].options, ["Lint", "Tests"]);
    assert_eq!(asks[0].detail.as_deref(), Some("Redis: in the stack"));
    inbox.answer(&asks[0].id, 2, "SQLite, it's a prototype");
    assert_eq!(bridge.heard(&settled(&inbox, &asks[0].id).await, Some(&conversation)), None, "one field still open");
    inbox.choose(&asks[1].id, 1);
    let answers = [("0", "SQLite, it's a prototype"), ("1", "Tests")].map(|(k, v)| (k.to_string(), vec![v.to_string()])).into();
    assert_eq!(bridge.heard(&settled(&inbox, &asks[1].id).await, Some(&conversation)), Some(Act::Answer { session: SESSION.into(), question: "q1".into(), answers }));
}

#[tokio::test]
async fn a_secret_is_never_asked_in_the_inbox() {
    let (inbox, bridge) = inbox(None);
    let mut token = cache();
    token.secret = true;
    bridge.sync(&[asking(vec![token])]);
    assert!(inbox.open_asks().is_empty(), "the inbox's log would keep it; the workspace window asks for it instead");
    let note = inbox.asks().pop().unwrap();
    assert_eq!((note.kind, note.status.as_deref()), (AskKind::Note, Some("blocked")));
}

#[tokio::test]
async fn every_session_has_a_dot_that_follows_its_attention() {
    let (inbox, bridge) = inbox(None);
    let name = "zerod-01a1aaaa00000003";
    let latest = || inbox.asks().into_iter().rev().find(|a| a.agent.name == name).unwrap();
    let mut session = Conversation::new("01a1aaaa00000003", Provider::Codex, "/work");
    session.status = Status::Working;
    bridge.sync(std::slice::from_ref(&session));
    assert_eq!((latest().status, latest().request.as_deref()), (None, Some(zerod::board::ATTENTION)), "working: blue, and told from the agent's own notes");
    session.status = Status::Idle;
    session.items = vec![Item { at: None, id: "a".into(), turn: None, kind: ItemKind::Agent { text: "Done.".into(), final_answer: true }, status: ItemStatus::Done }];
    bridge.sync(std::slice::from_ref(&session));
    assert_eq!((latest().status.as_deref(), latest().body.as_str()), (Some("done"), "Done."), "its answer to read");
    bridge.sync(std::slice::from_ref(&session));
    assert_eq!(inbox.asks().iter().filter(|a| a.agent.name == name).count(), 2, "the same attention again posts nothing");
    session.stalled = Some("No word from Codex for 10 minutes".into());
    session.status = Status::Working;
    bridge.sync(std::slice::from_ref(&session));
    assert_eq!((latest().status.as_deref(), latest().body.as_str()), (Some("blocked"), "No word from Codex for 10 minutes"));
    session.status = Status::Offline;
    session.stalled = None;
    bridge.sync(std::slice::from_ref(&session));
    assert!(inbox.is_closed(name), "an offline session leaves the bar until it works again");
    assert_eq!(latest().title, "Codex in work", "named after the provider and folder when nothing better");
}

/// The bridge running on a daemon: the session's approval reaches the inbox, and the inbox's answer the runtime.
#[tokio::test]
async fn a_live_session_is_answered_from_the_inbox() {
    let home = temp_dir("bridge-live");
    let (script, seen) = play(fixture("codex-command"));
    let script = std::sync::Mutex::new(Some(script));
    let runtime: Runtime = Arc::new(move |_: &Conversation, _: &std::path::Path, _: &[String]| Ok(script.lock().unwrap().take().unwrap()));
    let daemon = Daemon::open(&home, runtime).unwrap();
    let inbox = Inbox::open(None, vec![]);
    inbox.configure(Duration::from_millis(20), 3600);
    Bridge::start(daemon.clone(), inbox.clone());
    let session = daemon.start(Provider::Codex, home.to_str().unwrap(), "ls", None, None, Permissions::Auto).unwrap();
    let mut ask = None;
    for _ in 0..500 {
        ask = inbox.open_asks().into_iter().find(|a| a.kind == AskKind::Permission);
        if ask.is_some() { break }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let ask = ask.expect("the approval in the inbox");
    assert_eq!(ask.agent.reference.as_deref(), Some(session.as_str()));
    inbox.choose(&ask.id, 0);
    for _ in 0..500 {
        if seen.reply_to(&json!(0)).is_some() { break }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(seen.reply_to(&json!(0)).expect("Codex answered")["result"]["decision"], "accept");
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(inbox.open_asks().iter().all(|a| a.kind != AskKind::Permission), "nothing left to ask");
}
