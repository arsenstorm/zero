//! Sessions that start sessions: a lead spawns workers, gives them names and references, waits on them, and hears
//! from each one when it finishes, without polling. Driven through the daemon as the `zero` CLI drives it.

mod common;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::{Seen, fixture, play, temp_dir};
use serde_json::json;
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::{Attention, Conversation, Permissions, Provider};

/// Runtimes by provider: Claude sessions (leads) accept anything and finish nothing; Codex sessions (workers) play
/// the Codex command recording, which ends in an answer once its approval is allowed.
struct World {
    daemon: Arc<Daemon>,
    home: PathBuf,
    project: PathBuf,
    claude: Arc<Mutex<Vec<Seen>>>,
}

fn runtime(claude: Arc<Mutex<Vec<Seen>>>) -> Runtime {
    Arc::new(move |conversation: &Conversation, _: &std::path::Path, _: &[String]| {
        let script = match conversation.provider {
            Provider::Codex => fixture("codex-command"),
            _ => vec![],
        };
        let (transport, seen) = play(script);
        if conversation.provider == Provider::Claude { claude.lock().unwrap().push(seen) }
        Ok(transport)
    })
}

fn world(name: &str) -> World {
    let home = temp_dir(name);
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let claude = Arc::new(Mutex::new(vec![]));
    let daemon = Daemon::open(&home, runtime(claude.clone())).unwrap();
    World { daemon, home, project, claude }
}

async fn until(daemon: &Daemon, session: &str, test: impl Fn(&Conversation) -> bool) -> Conversation {
    for _ in 0..500 {
        if let Some(now) = daemon.get(session) && test(&now) { return now }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out: {:#?}", daemon.get(session));
}

fn start(daemon: &Daemon, provider: Provider, cwd: &std::path::Path, prompt: &str) -> String {
    daemon.start(provider, cwd.to_str().unwrap(), prompt, None, None, Permissions::Auto).unwrap()
}

fn named(label: &str, ticket: Option<&str>) -> Options {
    Options { label: Some(label.into()), ticket: ticket.map(Into::into), ..Default::default() }
}

/// What ends a Claude turn: its result.
fn turn_ends() -> serde_json::Value {
    json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"})
}

/// The lead's runtime, once it has started.
async fn lead_runtime(w: &World) -> Seen {
    for _ in 0..500 {
        if let Some(seen) = w.claude.lock().unwrap().first().cloned() { return seen }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("the lead never started");
}

/// A worker of `lead`, run to its answer.
async fn finished_worker(w: &World, lead: &str) -> String {
    let worker = w.daemon.spawn(lead, Provider::Codex, "list the files", named("Listing", Some("WEB-7"))).unwrap();
    let waiting = until(&w.daemon, &worker, |c| !c.approvals.is_empty()).await;
    w.daemon.decide(&worker, &waiting.approvals[0].id, &waiting.approvals[0].choices[0].id).await.unwrap();
    until(&w.daemon, &worker, |c| c.attention() == Attention::Done).await;
    worker
}

#[tokio::test]
async fn a_worker_knows_its_lead_and_runs_in_its_folder_with_its_permissions() {
    let w = world("leads-spawn");
    let lead = w.daemon.start(Provider::Claude, w.project.to_str().unwrap(), "lead the work", None, None, Permissions::Unrestricted).unwrap();
    let worker = w.daemon.spawn(&lead, Provider::Codex, "list the files", named("Listing", Some("WEB-7"))).unwrap();
    let conversation = w.daemon.get(&worker).unwrap();
    assert_eq!(conversation.parent.as_deref(), Some(lead.as_str()));
    assert_eq!(conversation.cwd, w.project.to_str().unwrap(), "the lead's folder unless it names another");
    assert_eq!(conversation.permissions, Permissions::Unrestricted, "the lead's mode");
    assert_eq!((conversation.label.as_deref(), conversation.ticket.as_deref()), (Some("Listing"), Some("WEB-7")));
    assert!(w.daemon.spawn("no-such-lead", Provider::Codex, "x", Options::default()).is_err());
    let elsewhere = w.home.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let other = w.daemon.spawn(&lead, Provider::Codex, "x", Options { cwd: Some(elsewhere.to_str().unwrap().into()), ..Default::default() }).unwrap();
    assert_eq!(w.daemon.get(&other).unwrap().cwd, elsewhere.to_str().unwrap());
}

#[tokio::test]
async fn a_finished_worker_tells_its_lead_what_it_found() {
    let w = world("leads-tell");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    seen.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    finished_worker(&w, &lead).await;
    let told = seen.said("user", 2).await;
    let text = told[1]["message"]["content"].as_str().unwrap();
    assert!(text.starts_with("<!-- from: ") && text.contains("-->\nWorker Listing (WEB-7) finished:"), "marked as the worker's, then its report: {text}");
    assert!(text.contains("The directory is empty"), "{text}");
}

#[tokio::test]
async fn a_lead_still_working_hears_once_its_turn_ends() {
    let w = world("leads-queue");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    finished_worker(&w, &lead).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(seen.all().iter().filter(|m| m["type"] == "user").count(), 1, "not while the lead is mid-turn");
    seen.say(turn_ends());
    assert!(seen.said("user", 2).await[1]["message"]["content"].as_str().unwrap().contains("Worker Listing"));
}

#[tokio::test]
async fn word_for_an_offline_lead_waits_on_disk_until_it_resumes() {
    let w = world("leads-offline");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    w.daemon.stop(&lead).unwrap();
    until(&w.daemon, &lead, |c| c.attention() == Attention::Offline).await;
    finished_worker(&w, &lead).await;
    // A daemon restart in between: the word is kept.
    let again = Daemon::open(&w.home, runtime(w.claude.clone())).unwrap();
    again.resume(&lead).await.unwrap();
    let resumed = w.claude.lock().unwrap().last().unwrap().clone();
    assert!(resumed.said("user", 1).await[0]["message"]["content"].as_str().unwrap().contains("Worker Listing (WEB-7) finished:"));
}

#[tokio::test]
async fn a_lead_can_wait_on_its_workers_and_read_their_answers() {
    let w = world("leads-wait");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let worker = w.daemon.spawn(&lead, Provider::Codex, "list the files", named("Listing", None)).unwrap();
    let daemon = w.daemon.clone();
    let waited = tokio::spawn({ let worker = worker.clone(); async move { daemon.wait(&[worker], false, Duration::from_secs(5)).await } });
    let waiting = until(&w.daemon, &worker, |c| !c.approvals.is_empty()).await;
    let early = waited.await.unwrap().unwrap();
    assert_eq!(early[0].attention(), Attention::NeedsYou, "a worker waiting on the user stops the wait too");
    w.daemon.decide(&worker, &waiting.approvals[0].id, &waiting.approvals[0].choices[0].id).await.unwrap();
    until(&w.daemon, &worker, |c| c.approvals.is_empty()).await;
    let done = w.daemon.wait(std::slice::from_ref(&worker), false, Duration::from_secs(5)).await.unwrap();
    assert_eq!(done[0].attention(), Attention::Done);
    assert!(w.daemon.last_answer(&worker).unwrap().contains("The directory is empty"));
    assert_eq!(w.daemon.workers(&lead).iter().map(|c| c.id.clone()).collect::<Vec<_>>(), [worker]);
}

#[tokio::test]
async fn a_session_is_named_and_knows_its_branch() {
    let w = world("leads-label");
    let repo = w.home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let git = |args: &[&str]| assert!(std::process::Command::new("git").args(args).current_dir(&repo).output().unwrap().status.success());
    git(&["init", "-q", "-b", "fix-login"]);
    let session = start(&w.daemon, Provider::Codex, &repo, "fix the login");
    assert_eq!(w.daemon.get(&session).unwrap().branch.as_deref(), Some("fix-login"));
    w.daemon.label(&session, Some("Login fix"), Some("GH-42")).unwrap();
    let named = w.daemon.get(&session).unwrap();
    assert_eq!((named.label.as_deref(), named.ticket.as_deref()), (Some("Login fix"), Some("GH-42")));
    // Kept across a restart, like everything else zerod says about a session.
    let again = Daemon::open(&w.home, runtime(w.claude.clone())).unwrap();
    assert_eq!(again.get(&session).unwrap().label.as_deref(), Some("Login fix"));
}

#[tokio::test]
async fn a_model_switched_mid_session_is_still_the_model_after_a_restart() {
    let w = world("leads-model");
    let session = start(&w.daemon, Provider::Codex, &w.project, "ls");
    let waiting = until(&w.daemon, &session, |c| !c.approvals.is_empty()).await;
    w.daemon.decide(&session, &waiting.approvals[0].id, &waiting.approvals[0].choices[0].id).await.unwrap();
    until(&w.daemon, &session, |c| matches!(c.attention(), Attention::Idle | Attention::Answered | Attention::Done) && c.answer().is_some()).await;
    w.daemon.send(&session, "again, on luna", Some("gpt-6-luna"), None).await.unwrap();
    assert_eq!(w.daemon.get(&session).unwrap().model.as_deref(), Some("gpt-6-luna"));
    let again = Daemon::open(&w.home, runtime(w.claude.clone())).unwrap();
    assert_eq!(again.get(&session).unwrap().model.as_deref(), Some("gpt-6-luna"));
}

#[tokio::test]
async fn the_board_names_a_task_after_its_first_message() {
    let w = world("leads-board-label");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "rebase the three PRs onto main, one at a time");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    seen.say(json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "Rebased."}]}}));
    seen.say(turn_ends());
    until(&w.daemon, &lead, |c| c.status == zerod::model::Status::Idle && c.items.len() >= 2).await;
    // The board reads summaries (no items but the latest answer): the first message must survive the trimming.
    let summary = w.daemon.sessions().into_iter().find(|s| s.summary().id == lead).unwrap().summary();
    assert_eq!(zerod::bridge::label(&summary), "Rebase the three PRs onto…");
}

/// The user's messages a fake Claude lead has been given so far.
fn given(seen: &Seen) -> Vec<String> {
    seen.all().iter().filter(|m| m["type"] == "user").map(|m| m["message"]["content"].as_str().unwrap_or("").to_string()).collect()
}

#[tokio::test]
async fn queued_messages_go_one_turn_each_and_never_with_a_report() {
    let w = world("queue-turns");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    // Mid-turn: two messages queued, and a worker's report arriving meanwhile.
    w.daemon.queue(&lead, "first follow-up", &[]).unwrap();
    let second = w.daemon.queue(&lead, "second follow-up", &[]).unwrap();
    finished_worker(&w, &lead).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(given(&seen).len(), 1, "nothing goes mid-turn");
    assert_eq!(w.daemon.queued(&lead).0.iter().map(|q| q.text.as_str()).collect::<Vec<_>>(), ["first follow-up", "second follow-up"], "the user's, not the report");
    seen.say(turn_ends());
    assert_eq!(seen.said("user", 2).await[1]["message"]["content"], "first follow-up");
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(given(&seen).len(), 2, "one message a turn");
    // Taken back before its turn: it never goes.
    w.daemon.unqueue(&lead, &second.id).unwrap();
    seen.say(turn_ends());
    let report = seen.said("user", 3).await[2]["message"]["content"].as_str().unwrap().to_string();
    assert!(report.contains("Worker Listing (WEB-7) finished:"), "the report on its own: {report}");
    assert!(w.daemon.queued(&lead).0.is_empty());
}

#[tokio::test]
async fn a_queued_message_goes_when_the_turn_ends_asking_the_user_something() {
    // The turn ends on a question to the user: the task waits on them, and their queued message is their word.
    let w = world("queue-asked");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    w.daemon.queue(&lead, "yes, it showed", &[]).unwrap();
    seen.say(json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "Did the card show in place of its step?"}]}}));
    seen.say(turn_ends());
    assert_eq!(seen.said("user", 2).await[1]["message"]["content"], "yes, it showed");
}

#[tokio::test]
async fn stopping_the_agent_holds_its_queue_until_released() {
    let w = world("queue-hold");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    w.daemon.queue(&lead, "after this", &[]).unwrap();
    let daemon = w.daemon.clone();
    let id = lead.clone();
    tokio::spawn(async move { let _ = daemon.interrupt(&id).await; });
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(w.daemon.queued(&lead).1, "held once stopped");
    seen.say(turn_ends());
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(given(&seen).len(), 1, "held: nothing goes though the agent is idle");
    w.daemon.release(&lead).unwrap();
    assert_eq!(seen.said("user", 2).await[1]["message"]["content"], "after this");
}

#[tokio::test]
async fn an_unarchived_task_brings_its_queue_back_held() {
    let w = world("queue-unarchive");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    w.daemon.queue(&lead, "after this", &[]).unwrap();
    w.daemon.archive(&lead).await.unwrap();
    w.daemon.unarchive(&lead).unwrap();
    let (list, held) = w.daemon.queued(&lead);
    assert_eq!(list.iter().map(|q| q.text.as_str()).collect::<Vec<_>>(), ["after this"], "the words it was waiting with");
    assert!(held, "held: nothing goes until the user says so");
}

#[tokio::test]
async fn a_worker_is_in_its_leads_workspace_wherever_it_runs() {
    let w = world("leads-workspaces");
    w.daemon.workspaces.save(zerod::workspaces::Workspace { id: "work".into(), name: "Acme".into(), glyph: "".into(), folders: vec![] }).unwrap();
    let elsewhere = w.home.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    // Started from Zero into Acme: the lead is there, and its worker in another folder is too.
    let lead = w.daemon.start_with(Provider::Claude, "lead", Options { cwd: Some(w.project.to_str().unwrap().into()), workspace: Some("work".into()), ..Default::default() }).unwrap();
    let worker = w.daemon.spawn(&lead, Provider::Claude, "work", Options { cwd: Some(elsewhere.to_str().unwrap().into()), ..Default::default() }).unwrap();
    let rows = zerod::board::board_in(&w.daemon.sessions().iter().map(|s| s.summary()).collect::<Vec<_>>(), &[], &Default::default(), &Default::default(), &|c| w.daemon.workspace_of(c));
    assert_eq!(rows.iter().map(|r| (r.session.as_str(), r.workspace.as_str())).collect::<Vec<_>>(), [(lead.as_str(), "work")]);
    assert_eq!(w.daemon.workspace_of(&w.daemon.get(&worker).unwrap()), "work");
    assert_eq!(w.daemon.start_with(Provider::Claude, "x", Options { cwd: Some(w.project.to_str().unwrap().into()), workspace: Some("nope".into()), ..Default::default() }).unwrap_err(), "No workspace nope");
    // Moved, and moved back to its folder's: Zero's.
    w.daemon.place_in_workspace(&lead, None).unwrap();
    assert_eq!(w.daemon.workspace_of(&w.daemon.get(&lead).unwrap()), "zero");
    w.daemon.place_in_workspace(&lead, Some("work")).unwrap();
    let again = Daemon::open(&w.home, runtime(w.claude.clone())).unwrap();
    assert_eq!(again.workspace_of(&again.get(&lead).unwrap()), "work", "kept in the transcript");
}

#[test]
fn a_workers_report_says_how_it_ended_its_turn() {
    let worker = |answer: &str| {
        let mut c = Conversation::new("w1", Provider::Claude, "/w");
        c.label = Some("Listing".into());
        c.items.push(zerod::model::Item { at: None, id: "a".into(), turn: None, status: zerod::model::ItemStatus::Done,
            kind: zerod::model::ItemKind::Agent { text: answer.into(), final_answer: true } });
        c
    };
    let asked = zerod::daemon::report(&worker("Asked which colour.\n[zero: asked n25cmk]"), Attention::Done);
    assert!(asked.starts_with("Worker Listing is waiting on the user's answer (ask n25cmk): Asked which colour."), "{asked}");
    let blocked = zerod::daemon::report(&worker("CI is down.\n[zero: blocked]"), Attention::Done);
    assert!(blocked.starts_with("Worker Listing is blocked: CI is down."), "{blocked}");
    let done = zerod::daemon::report(&worker("All 4 files listed.\n\n[zero: done]"), Attention::Done);
    assert!(done.starts_with("Worker Listing finished: All 4 files listed.\n"), "the ending line left out: {done}");
}
