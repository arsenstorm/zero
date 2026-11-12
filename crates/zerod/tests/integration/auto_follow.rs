//! A task follows the pull requests it opens, without being told to: a step that created one (`gh pr create`, a POST
//! to the pulls API, an MCP tool's create_pull_request) or `zero attr PR <url>`. A worker's pass to its lead with its
//! report. And a turn that ends waiting with nothing to wake it (nothing followed, nothing running) is told so, once.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::temp_dir;
use crate::endings::listening;
use zerod::daemon::{Daemon, NOTHING_WAKES_MARK};
use zerod::following::{Following, opened};
use zerod::integrations::{Fetcher, Integrations};
use zerod::model::*;

struct Offline;

impl Fetcher for Offline {
    fn run(&self, _: Vec<String>, _: Option<String>) -> zerod::inbox::Fut<'_, Result<String, String>> {
        Box::pin(async { Err("offline".to_string()) })
    }
}

fn command(command: &str, output: &str) -> ItemKind {
    ItemKind::Command {
        command: command.into(),
        cwd: "/w".into(),
        output: output.into(),
        exit_code: Some(0),
        duration_ms: None,
        description: String::new(),
    }
}

fn tool(name: &str, output: &str) -> ItemKind {
    ItemKind::Tool { name: name.into(), detail: "{}".into(), output: output.into() }
}

#[test]
fn only_a_step_that_created_a_pull_request_opened_one() {
    let url = Some("https://github.com/o/r/pull/7".to_string());
    let created = "Warning: 1 uncommitted change\n\nCreating pull request for fix into main in o/r\n\nhttps://github.com/o/r/pull/7\n";
    assert_eq!(opened(&command("git push -u origin fix && gh pr create --fill", created)), url);
    let api = r#"{"url": "https://api.github.com/repos/o/r/pulls/7", "html_url": "https://github.com/o/r/pull/7", "body": "after https://github.com/o/r/pull/3"}"#;
    assert_eq!(opened(&command("gh api repos/o/r/pulls -X POST -f title=Fix -f head=fix -f base=main", api)), url);
    assert_eq!(opened(&command("gh api repos/o/r/pulls -f title=Fix -f head=fix -f base=main", api)), url, "fields make gh api POST");
    assert_eq!(opened(&tool("mcp__github__create_pull_request", api)), url);
    assert_eq!(opened(&tool("github.create_pull_request", r#"{"url":"https://github.com/o/r/pull/7"}"#)), url);
    // Mentioned, read, or only offered: not opened.
    assert_eq!(opened(&command("gh pr view 7", "title: Fix\nurl: https://github.com/o/r/pull/7")), None);
    assert_eq!(opened(&command("gh api repos/o/r/pulls/7", api)), None);
    assert_eq!(opened(&command("gh api repos/o/r/pulls", api)), None, "a GET lists them");
    let push = "remote: Create a pull request for 'fix' on GitHub by visiting:\nremote:   https://github.com/o/r/pull/new/fix\n";
    assert_eq!(opened(&command("git push -u origin fix", push)), None);
    assert_eq!(opened(&tool("mcp__github__get_pull_request", api)), None);
    let mut failed = command("gh pr create --fill", "a pull request for branch \"fix\" already exists:\nhttps://github.com/o/r/pull/7");
    if let ItemKind::Command { exit_code, .. } = &mut failed {
        *exit_code = Some(1)
    }
    assert_eq!(opened(&failed), None, "it failed: that one was opened before");
}

async fn task(name: &str) -> (Arc<Daemon>, Arc<Following>, String, Arc<Mutex<String>>) {
    let home = temp_dir(name);
    let sent = Arc::new(Mutex::new(String::new()));
    let daemon = Daemon::open(&home.join("zerod"), listening(sent.clone())).unwrap();
    daemon.require_endings();
    let fetcher = Arc::new(Offline);
    let following = Following::open(&home, fetcher.clone(), Integrations::open(&home, fetcher));
    daemon.set_following(following.clone());
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    (daemon, following, id, sent)
}

fn step(session: &zerod::session::Session, id: &str, kind: ItemKind) {
    session.change(Change::Item { item: Item { at: None, id: id.into(), turn: None, kind, status: ItemStatus::Done } });
}

fn topics(following: &Following, id: &str) -> Vec<String> {
    following.list(Some(id)).into_iter().map(|f| f.follow.topic).collect()
}

fn notices(daemon: &Daemon, id: &str) -> Vec<String> {
    daemon
        .get(id)
        .unwrap()
        .items
        .into_iter()
        .filter_map(|i| match i.kind {
            ItemKind::Notice { text, error: false } => Some(text),
            _ => None,
        })
        .collect()
}

async fn settle() {
    tokio::time::sleep(Duration::from_millis(200)).await
}

#[tokio::test]
async fn a_pull_request_a_task_opens_is_followed_and_becomes_its_pr() {
    let (daemon, following, id, _) = task("auto-follow-opened").await;
    let session = daemon.session(&id).unwrap();
    step(&session, "c1", command("gh pr view 3", "https://github.com/o/r/pull/3"));
    step(&session, "c2", command("gh pr create --fill", "https://github.com/o/r/pull/7\n"));
    settle().await;
    assert_eq!(topics(&following, &id), vec!["github/o/r/7"], "the one it opened, not the one it read");
    assert_eq!(notices(&daemon, &id), vec!["Following r#7"]);
    assert_eq!(daemon.get(&id).unwrap().attributes.get("PR").map(String::as_str), Some("https://github.com/o/r/pull/7"));
    // A second one: followed too, the PR it has stays.
    step(&session, "c3", tool("mcp__github__create_pull_request", r#"{"html_url": "https://github.com/o/r/pull/8"}"#));
    settle().await;
    assert_eq!(topics(&following, &id), vec!["github/o/r/7", "github/o/r/8"]);
    assert_eq!(daemon.get(&id).unwrap().attributes.get("PR").map(String::as_str), Some("https://github.com/o/r/pull/7"));
    // The same step heard again: nothing new.
    step(&session, "c2", command("gh pr create --fill", "https://github.com/o/r/pull/7\n"));
    settle().await;
    assert_eq!(notices(&daemon, &id).len(), 2);
}

#[tokio::test]
async fn a_pr_the_agent_sets_is_followed() {
    let (daemon, following, id, _) = task("auto-follow-attr").await;
    daemon.set_attribute(&id, "PR", Some("https://github.com/o/r/pull/9")).unwrap();
    daemon.set_attribute(&id, "Deploy", Some("https://github.com/o/r/pull/10")).unwrap();
    settle().await;
    assert_eq!(topics(&following, &id), vec!["github/o/r/9"]);
    assert_eq!(notices(&daemon, &id), vec!["Following r#9"]);
}

async fn turn(session: &zerod::session::Session, n: usize, said: &str, answer: &str) {
    session.change(Change::Status { status: Status::Working, turn: Some(format!("t{n}")), error: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
    step(session, &format!("u{n}"), ItemKind::User { text: said.into(), images: vec![], sent: None });
    step(session, &format!("a{n}"), ItemKind::Agent { text: answer.into(), final_answer: true });
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    tokio::time::sleep(Duration::from_millis(300)).await;
}

#[tokio::test]
async fn a_workers_pull_requests_pass_to_its_lead_with_its_report() {
    let (daemon, following, lead, _) = task("auto-follow-worker").await;
    daemon.session(&lead).unwrap().change(Change::Status { status: Status::Idle, turn: None, error: None });
    let worker = daemon.spawn(&lead, Provider::Claude, "fix it", Default::default()).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let session = daemon.session(&worker).unwrap();
    step(&session, "c1", command("gh pr create --fill", "https://github.com/o/r/pull/7"));
    settle().await;
    assert!(topics(&following, &lead).is_empty(), "not before its report");
    turn(&session, 1, "fix it", "Opened r#7; CI is running.\n\n[zero: waiting]").await;
    assert_eq!(topics(&following, &lead), vec!["github/o/r/7"]);
    assert_eq!(topics(&following, &worker), vec!["github/o/r/7"], "it still waits on its CI");
    assert_eq!(notices(&daemon, &lead), vec!["Following r#7"]);
}

fn warned(sent: &Mutex<String>) -> usize {
    sent.lock().unwrap().matches(NOTHING_WAKES_MARK).count()
}

#[tokio::test]
async fn waiting_with_nothing_to_wake_it_is_told_once() {
    let (daemon, following, id, sent) = task("auto-follow-nothing-wakes").await;
    let session = daemon.session(&id).unwrap();
    turn(&session, 1, "ship it", "Pushed; CI runs now.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 1, "{}", sent.lock().unwrap());
    // Its reply to that is taken as it is: it said who it waits on.
    turn(&session, 2, &zerod::model::from_line("zero", NOTHING_WAKES_MARK), "Waiting on Dana's deploy.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 1);
    // Following something, it's woken by it.
    step(&session, "c1", command("gh pr create --fill", "https://github.com/o/r/pull/7"));
    settle().await;
    assert_eq!(topics(&following, &id).len(), 1);
    turn(&session, 3, "ship it", "Opened r#7.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 1, "it follows r#7");
}

/// A note of the task's own, as `zero note` posts it.
fn note(id: &str, status: Option<&str>, needs: Option<&str>) -> zerod::ask::Ask {
    let agent = zerod::ask::AgentIdentity { name: format!("zerod-{id}"), reference: Some(id.into()), ..Default::default() };
    let mut note = zerod::ask::Ask::new(zerod::ask::AskKind::Note, "Update", agent, 0);
    note.body = "Waiting on Dana's review".into();
    note.status = status.map(String::from);
    note.needs = needs.map(String::from);
    note
}

#[tokio::test]
async fn a_waiting_note_says_who_it_waits_on() {
    let (daemon, _, id, sent) = task("auto-follow-noted").await;
    let inbox = zerod::inbox::Inbox::open(None, vec![]);
    zerod::server::know_waiting_notes(&daemon, &inbox);
    let session = daemon.session(&id).unwrap();
    inbox.create(note(&id, Some("waiting"), None), false);
    turn(&session, 1, "ship it", "Over to Dana.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 0, "a --waiting note names who it waits on");
    inbox.create(note(&id, None, Some("Merge r#7")), false);
    turn(&session, 2, "ship it", "Over to you.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 0, "so does --needs");
    inbox.create(note(&id, None, None), false);
    turn(&session, 3, "ship it", "Still waiting.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 1, "a note that names no one doesn't");
}

#[tokio::test]
async fn told_once_until_something_could_wake_it() {
    let (daemon, following, id, sent) = task("auto-follow-once").await;
    let session = daemon.session(&id).unwrap();
    turn(&session, 1, "ship it", "CI runs.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 1);
    // Other turns ending waiting the same way (an event, the user's word): not told again.
    turn(&session, 2, &zerod::model::from_line("zero", "1 new event"), "Still CI.\n\n[zero: waiting]").await;
    turn(&session, 3, "and now?", "Still CI.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 1, "{}", sent.lock().unwrap());
    // Once it followed something, the count starts again.
    step(&session, "c1", command("gh pr create --fill", "https://github.com/o/r/pull/7"));
    settle().await;
    turn(&session, 4, "ship it", "Opened r#7.\n\n[zero: waiting]").await;
    following.unfollow(&id, None);
    turn(&session, 5, "ship it", "Merged; deploy runs.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 2);
}

#[tokio::test]
async fn waiting_on_a_worker_or_said_otherwise_isnt_told() {
    let (daemon, _, id, sent) = task("auto-follow-on-a-worker").await;
    let session = daemon.session(&id).unwrap();
    turn(&session, 1, "check it", "Checked.\n\n[zero: done]").await;
    turn(&session, 2, "check it", "Next step soon.\n\n[zero: working]").await;
    let worker = daemon.spawn(&id, Provider::Claude, "fix it", Default::default()).unwrap();
    daemon.session(&worker).unwrap().change(Change::Status { status: Status::Working, turn: Some("w1".into()), error: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
    turn(&session, 3, "fix it", "A worker is on it.\n\n[zero: waiting]").await;
    assert_eq!(warned(&sent), 0, "{}", sent.lock().unwrap());
}

#[test]
fn an_mcp_tools_result_is_kept_to_read_what_it_opened() {
    use serde_json::json;
    let mut core = zerod::core::Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": "open it"}}));
    core.receive(&json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "t1",
        "name": "mcp__github__create_pull_request", "input": {"owner": "o", "repo": "r", "title": "Fix"}}]}}));
    core.receive(&json!({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "{\"html_url\": \"https://github.com/o/r/pull/7\"}"}]}]}}));
    let step = core.conversation().items.iter().find(|i| i.id == "t1").unwrap().kind.clone();
    assert_eq!(opened(&step).as_deref(), Some("https://github.com/o/r/pull/7"));
}
