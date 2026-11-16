//! Sessions that start sessions: a lead spawns workers, gives them names and references, waits on them, and hears
//! from each one when it finishes, without polling. Driven through the daemon as the `zero` CLI drives it.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::{Seen, fixture, play, temp_dir};
use serde_json::json;
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::{Attention, Change, Conversation, Permissions, Provider, Status};

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
        if conversation.provider == Provider::Claude {
            claude.lock().unwrap().push(seen)
        }
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
        if let Some(now) = daemon.get(session)
            && test(&now)
        {
            return now;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out: {:#?}", daemon.get(session));
}

fn start(daemon: &Daemon, provider: Provider, cwd: &std::path::Path, prompt: &str) -> String {
    daemon.start(provider, prompt, zerod::daemon::Options { cwd: Some(cwd.to_str().unwrap().into()), ..Default::default() }).unwrap()
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
        if let Some(seen) = w.claude.lock().unwrap().first().cloned() {
            return seen;
        }
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
    let lead = w
        .daemon
        .start(
            Provider::Claude,
            "lead the work",
            zerod::daemon::Options {
                cwd: Some(w.project.to_str().unwrap().into()),
                permissions: Some(Permissions::Unrestricted),
                ..Default::default()
            },
        )
        .unwrap();
    let worker = w.daemon.spawn(&lead, Provider::Codex, "list the files", named("Listing", Some("WEB-7"))).unwrap();
    let conversation = w.daemon.get(&worker).unwrap();
    assert_eq!(conversation.parent.as_deref(), Some(lead.as_str()));
    assert_eq!(conversation.cwd, w.project.to_str().unwrap(), "the lead's folder unless it names another");
    assert_eq!(conversation.permissions, Permissions::Unrestricted, "the lead's mode");
    assert_eq!((conversation.label.as_deref(), conversation.ticket.as_deref()), (Some("Listing"), Some("WEB-7")));
    assert!(w.daemon.spawn("no-such-lead", Provider::Codex, "x", Options::default()).is_err());
    let elsewhere = w.home.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let other = w
        .daemon
        .spawn(&lead, Provider::Codex, "x", Options { cwd: Some(elsewhere.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
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
    assert!(
        text.starts_with("<!-- from: ") && text.contains("-->\nWorker Listing (WEB-7) finished:"),
        "marked as the worker's, then its report: {text}"
    );
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
    let waited = tokio::spawn({
        let worker = worker.clone();
        async move { daemon.wait(&[worker], false, Duration::from_secs(5)).await }
    });
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
    until(&w.daemon, &session, |c| {
        matches!(c.attention(), Attention::Idle | Attention::Answered | Attention::Done) && c.answer().is_some()
    })
    .await;
    w.daemon
        .send(
            &session,
            zerod::session::Message::text("again, on luna"),
            zerod::session::ModelChoice { model: Some("gpt-6-luna"), effort: None },
        )
        .await
        .unwrap();
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
    assert_eq!(
        w.daemon.queued(&lead).0.iter().map(|q| q.text.as_str()).collect::<Vec<_>>(),
        ["first follow-up", "second follow-up"],
        "the user's, not the report"
    );
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
async fn a_queued_message_has_the_folder_kept_as_it_went_too() {
    // Written mid-turn and given after it: rewinding to it brings back the folder as it was when it went, not before.
    let w = world("queue-snapshot");
    let git = |args: &[&str]| {
        let ok = std::process::Command::new("git").args(["-c", "commit.gpgsign=false"]).args(args).current_dir(&w.project).output();
        assert!(ok.unwrap().status.success(), "git {args:?}");
    };
    git(&["init", "-q"]);
    std::fs::write(w.project.join("a.txt"), "one\n").unwrap();
    git(&["add", "."]);
    git(&["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "start"]);
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    w.daemon.queue(&lead, "after this", &[]).unwrap();
    std::fs::write(w.project.join("a.txt"), "the turn's\n").unwrap();
    seen.say(turn_ends());
    seen.said("user", 2).await;
    let kept = until(&w.daemon, &lead, |c| c.snapshots.len() == 2).await;
    let queued = kept.items.iter().rfind(|i| matches!(&i.kind, zerod::model::ItemKind::User { text, .. } if text == "after this")).unwrap();
    let preview = w.daemon.rewind_preview(&lead, &queued.id).unwrap();
    assert_eq!(preview["files"], 0, "kept as the turn left it, when the message went: {preview}");
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
    tokio::spawn(async move {
        let _ = daemon.interrupt(&id).await;
    });
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
async fn a_held_queue_stays_held_across_a_restart() {
    let w = world("queue-held-restart");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    w.daemon.queue(&lead, "after this", &[]).unwrap();
    let daemon = w.daemon.clone();
    let id = lead.clone();
    tokio::spawn(async move {
        let _ = daemon.interrupt(&id).await;
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(w.daemon.queued(&lead).1);
    let again = Daemon::open(&w.home, runtime(w.claude.clone())).unwrap();
    assert_eq!(again.queued(&lead), (w.daemon.queued(&lead).0, true), "zerod again: still the user's to send");
    again.release(&lead).unwrap();
    assert!(!Daemon::open(&w.home, runtime(w.claude.clone())).unwrap().queued(&lead).1, "released: not held once zerod starts again");
}

#[tokio::test]
async fn a_worker_is_in_its_leads_workspace_wherever_it_runs() {
    let w = world("leads-workspaces");
    w.daemon
        .workspaces
        .save(zerod::workspaces::Workspace {
            id: "work".into(),
            name: "Acme".into(),
            glyph: "".into(),
            color: "".into(),
            plain_answers: None,
        })
        .unwrap();
    let elsewhere = w.home.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    // Started from Zero into Acme: the lead is there, and its worker in another folder is too.
    let lead = w
        .daemon
        .start(
            Provider::Claude,
            "lead",
            Options { cwd: Some(w.project.to_str().unwrap().into()), workspace: Some("work".into()), ..Default::default() },
        )
        .unwrap();
    let worker = w
        .daemon
        .spawn(&lead, Provider::Claude, "work", Options { cwd: Some(elsewhere.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    let rows = zerod::board::board_in(
        &w.daemon.sessions().iter().map(|s| s.summary()).collect::<Vec<_>>(),
        &[],
        &Default::default(),
        &Default::default(),
        &|c| w.daemon.workspace_of(c),
    );
    assert_eq!(rows.iter().map(|r| (r.session.as_str(), r.workspace.as_str())).collect::<Vec<_>>(), [(lead.as_str(), "work")]);
    assert_eq!(w.daemon.workspace_of(&w.daemon.get(&worker).unwrap()), "work");
    assert_eq!(
        w.daemon
            .start(
                Provider::Claude,
                "x",
                Options { cwd: Some(w.project.to_str().unwrap().into()), workspace: Some("nope".into()), ..Default::default() }
            )
            .unwrap_err(),
        "No workspace nope"
    );
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
        c.items.push(zerod::model::Item {
            at: None,
            id: "a".into(),
            turn: None,
            status: zerod::model::ItemStatus::Done,
            kind: zerod::model::ItemKind::Agent { text: answer.into(), final_answer: true },
        });
        c
    };
    let asked = zerod::daemon::report(&worker("Asked which colour.\n[zero: asked n25cmk]"), Attention::Done);
    assert!(asked.starts_with("Worker Listing is waiting on the user's answer (ask n25cmk): Asked which colour."), "{asked}");
    let blocked = zerod::daemon::report(&worker("CI is down.\n[zero: blocked]"), Attention::Done);
    assert!(blocked.starts_with("Worker Listing is waiting: CI is down."), "{blocked}");
    let done = zerod::daemon::report(&worker("All 4 files listed.\n\n[zero: done]"), Attention::Done);
    assert!(done.starts_with("Worker Listing finished: All 4 files listed.\n"), "the ending line left out: {done}");
}

#[tokio::test]
async fn a_task_at_its_accounts_limit_carries_on_as_another_account() {
    let w = world("signin-switch");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let account = |label: &str| {
        w.daemon
            .signins
            .save(zerod::signins::SignIn {
                id: String::new(),
                cli: Provider::Claude,
                kind: zerod::signins::Kind::ClaudeHome,
                label: label.into(),
                plan: None,
                variable: None,
                pending: false,
            })
            .unwrap()
    };
    let (first, second) = (account("a@example.com"), account("b@example.com"));
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    assert_eq!(w.daemon.get(&lead).unwrap().signin.as_deref(), Some(first.id.as_str()));
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    let resets = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64 + 3_600;
    let mut changes = w.daemon.subscribe();
    seen.say(json!({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": resets,
                    "unifiedWindows": {"five_hour": {"utilization": 1.0, "resetsAt": resets}, "seven_day": {"utilization": 0.6, "resetsAt": resets + 86_400}}}}));
    seen.say(json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": "You've hit your limit"}));
    until(&w.daemon, &lead, |c| c.signin.as_deref() == Some(second.id.as_str())).await;
    assert!(w.daemon.signins.usage(&first.id).is_some_and(|u| u.limited), "the first account's limit is known, for choosing later");
    let mut stopped = false;
    while let Ok(event) = changes.try_recv() {
        if event.session != lead {
            continue;
        }
        match event.change {
            Change::Status { status: Status::Offline, .. } => stopped = true,
            Change::SignedIn { .. } => assert!(stopped, "the old process stops before its account changes"),
            _ => {}
        }
    }
    assert!(w.daemon.signins.usage(&second.id).is_none_or(|u| !u.limited), "the rejection belongs only to the first account");
    // Its agent started again as the second account, and told to carry on.
    for _ in 0..200 {
        if w.claude.lock().unwrap().len() > 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await
    }
    let again = w.claude.lock().unwrap()[1].clone();
    assert!(again.said("user", 1).await[0]["message"]["content"].as_str().unwrap().contains("another account"));
}

/// At its limit by its CLI's error alone, no figures for its account's windows (a worker's process that ended on it): it
/// carries on as another account all the same, and the first is kept as limited for a while, not chosen again at once.
#[tokio::test]
async fn a_task_whose_cli_only_says_it_hit_its_limit_carries_on_as_another_account() {
    let w = world("signin-switch-said");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let account = |label: &str| {
        w.daemon
            .signins
            .save(zerod::signins::SignIn {
                id: String::new(),
                cli: Provider::Claude,
                kind: zerod::signins::Kind::ClaudeHome,
                label: label.into(),
                plan: None,
                variable: None,
                pending: false,
            })
            .unwrap()
    };
    let (first, second) = (account("a@example.com"), account("b@example.com"));
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    seen.say(json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": "You've hit your usage limit"}));
    until(&w.daemon, &lead, |c| c.signin.as_deref() == Some(second.id.as_str())).await;
    assert!(w.daemon.signins.usage(&first.id).is_some_and(|u| u.limited), "the first account kept as limited");
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
    assert_eq!(w.daemon.signins.choose(Provider::Claude, now, None).map(|s| s.id), Some(second.id.clone()), "not chosen again for now");
}

/// A turn a task finishes counts for the account it ran as: its own, else its CLI's default.
#[tokio::test]
async fn a_finished_turn_counts_for_its_account() {
    let w = world("signin-activity");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let first = w
        .daemon
        .signins
        .save(zerod::signins::SignIn {
            id: String::new(),
            cli: Provider::Claude,
            kind: zerod::signins::Kind::ClaudeHome,
            label: "a@example.com".into(),
            plan: None,
            variable: None,
            pending: false,
        })
        .unwrap();
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    seen.say(json!({"type": "assistant", "message": {"id": "m1", "role": "assistant", "content": [{"type": "text", "text": "Done."}]}}));
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "Done."}));
    let counted = || w.daemon.signins.activity().get(&first.id).map_or(0, |h| h.values().sum::<u32>());
    for _ in 0..300 {
        if counted() == 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(counted(), 1, "lead {lead}");
    // Its status going round again with no new answer (a restart, a resume, a wobble between steps) is no new turn: it
    // counted one turn as hundreds an hour.
    let session = w.daemon.session(&lead).unwrap();
    for _ in 0..3 {
        session.change(Change::Status { status: Status::Working, turn: None, error: None });
        session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(counted(), 1, "still the one turn");
}

/// A task whose account its provider won't let use the task's model: that's known of the account, and the task
/// carries on as an account that hasn't been refused it, its agent told why.
#[tokio::test]
async fn a_task_refused_its_model_carries_on_as_another_account() {
    let w = world("signin-refused");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let account = |label: &str| {
        w.daemon
            .signins
            .save(zerod::signins::SignIn {
                id: String::new(),
                cli: Provider::Claude,
                kind: zerod::signins::Kind::ClaudeHome,
                label: label.into(),
                plan: None,
                variable: None,
                pending: false,
            })
            .unwrap()
    };
    let (first, second) = (account("a@example.com"), account("b@example.com"));
    let lead = w
        .daemon
        .start(
            Provider::Claude,
            "lead the work",
            Options { cwd: Some(w.project.to_str().unwrap().into()), model: Some("claude-mythos-5-2".into()), ..Default::default() },
        )
        .unwrap();
    assert_eq!(w.daemon.get(&lead).unwrap().signin.as_deref(), Some(first.id.as_str()));
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    seen.say(json!({"type": "result", "subtype": "error_during_execution", "is_error": true,
                    "result": "There's an issue with the selected model (claude-mythos-5-2). It may not exist or you may not have access to it."}));
    until(&w.daemon, &lead, |c| c.signin.as_deref() == Some(second.id.as_str())).await;
    assert_eq!(w.daemon.signins.refused(&first.id), ["claude-mythos-5-2"]);
    for _ in 0..200 {
        if w.claude.lock().unwrap().len() > 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await
    }
    let again = w.claude.lock().unwrap()[1].clone();
    assert!(again.said("user", 1).await[0]["message"]["content"].as_str().unwrap().contains("can't use"));
    // A new task on that model starts as the account that can.
    let next = w
        .daemon
        .start(
            Provider::Claude,
            "more",
            Options { cwd: Some(w.project.to_str().unwrap().into()), model: Some("claude-mythos-5-2".into()), ..Default::default() },
        )
        .unwrap();
    assert_eq!(w.daemon.get(&next).unwrap().signin.as_deref(), Some(second.id.as_str()));
}

/// The nth Claude process started, once it has.
async fn nth_runtime(w: &World, n: usize) -> Seen {
    for _ in 0..500 {
        if let Some(seen) = w.claude.lock().unwrap().get(n).cloned() {
            return seen;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("process {n} never started");
}

fn users(seen: &Seen) -> usize {
    seen.all().iter().filter(|m| m["type"] == "user").count()
}

/// A worker that ends a turn without an answer while workers of its own are still working is waiting on them, not
/// stopped: its lead hears nothing until it does stop.
#[tokio::test]
async fn a_worker_waiting_on_its_own_workers_isnt_reported_as_stopped() {
    let w = world("leads-waiting-children");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    let verify = w.daemon.spawn(&lead, Provider::Claude, "verify it", named("Verify", Some("ENG-1"))).unwrap();
    let verifying = nth_runtime(&w, 1).await;
    verifying.said("user", 1).await;
    let reviewer = w.daemon.spawn(&verify, Provider::Claude, "review it", named("Reviewer", None)).unwrap();
    let reviewing = nth_runtime(&w, 2).await;
    reviewing.said("user", 1).await;
    until(&w.daemon, &reviewer, |c| c.attention() == Attention::Working).await;
    verifying.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": ""}));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(users(&led), 1, "its reviewer is still working: {:?}", led.all());
    // Its reviewer done, and it stops again without an answer: that is news.
    reviewing.say(turn_ends());
    verifying.said("user", 2).await;
    verifying.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": ""}));
    assert!(led.said("user", 2).await[1]["message"]["content"].as_str().unwrap().contains("Worker Verify (ENG-1)"));
}

/// A worker archived (its lead closed it) ends because of that: no report of its end comes back.
#[tokio::test]
async fn a_worker_closed_by_its_lead_doesnt_report_its_end() {
    let w = world("leads-closed");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    let worker = w.daemon.spawn(&lead, Provider::Claude, "check it", named("Check", None)).unwrap();
    let checking = nth_runtime(&w, 1).await;
    checking.said("user", 1).await;
    // With a worker of its own, which goes with it, and whose end it hears of first.
    let reviewer = w.daemon.spawn(&worker, Provider::Claude, "review it", named("Reviewer", None)).unwrap();
    nth_runtime(&w, 2).await.said("user", 1).await;
    checking.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": ""}));
    until(&w.daemon, &reviewer, |c| c.attention() == Attention::Working).await;
    w.daemon.archive(&worker).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(users(&led), 1, "{:?}", led.all());
}

#[tokio::test]
async fn something_an_archived_task_follows_brings_it_back_to_hear_of_it() {
    let w = world("follow-unarchive");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    seen.say(turn_ends());
    w.daemon.archive(&lead).await.unwrap();
    assert!(w.daemon.exists(&lead), "archived, it's still there to follow things: done isn't gone");
    assert!(!w.daemon.exists("nothing"));
    w.daemon.notify(&lead, "1 new event on what you follow").unwrap();
    assert!(w.daemon.get(&lead).is_some(), "back from the archive");
    assert!(!w.daemon.queued(&lead).1, "the event isn't held: it goes to the agent");
}

/// Claude's words as they stream are for the live view: the finished message carries them all, so the transcript keeps
/// that and not each piece (four in ten lines of a long task's transcript were pieces). Replayed, the words are there.
#[tokio::test]
async fn a_transcript_keeps_the_finished_words_not_each_piece() {
    let w = world("leads-transcript-pieces");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "say hello");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    let piece = |text: &str| json!({"type": "stream_event", "api_message_id": "m1", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}});
    seen.say(json!({"type": "stream_event", "api_message_id": "m1", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}}));
    seen.say(piece("Hello "));
    seen.say(piece("there."));
    seen.say(
        json!({"type": "assistant", "message": {"id": "m1", "role": "assistant", "content": [{"type": "text", "text": "Hello there."}]}}),
    );
    seen.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() != Attention::Working).await;
    let transcript = std::fs::read_to_string(w.home.join("sessions").join(&lead).join("transcript.jsonl")).unwrap();
    assert!(!transcript.contains("content_block_delta"), "{transcript}");
    let again = Daemon::open(&w.home, runtime(w.claude.clone())).unwrap();
    let said = again
        .get(&lead)
        .unwrap()
        .items
        .iter()
        .any(|i| matches!(&i.kind, zerod::model::ItemKind::Agent { text, .. } if text == "Hello there."));
    assert!(said, "replayed with its words");
}

/// Claude says who it is (system/init, 15 KB with its tools and skills) on every start: the transcript keeps it only
/// when it says something new, not again for a fresh uuid or socket. Replayed, the latest is what counts.
#[tokio::test]
async fn a_transcript_keeps_claudes_init_only_when_it_changes() {
    let w = world("leads-transcript-init");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "say hello");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    let init = |session: &str, uuid: &str| {
        json!({"type": "system", "subtype": "init", "session_id": session, "model": "claude-fable-5-1",
                                                 "uuid": uuid, "messaging_socket_path": format!("/tmp/{uuid}.sock"), "tools": ["Bash", "Edit"]})
    };
    seen.say(init("t1", "u1"));
    seen.say(init("t1", "u2"));
    seen.say(init("t2", "u3"));
    seen.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() != Attention::Working).await;
    let transcript = std::fs::read_to_string(w.home.join("sessions").join(&lead).join("transcript.jsonl")).unwrap();
    assert_eq!(transcript.matches("\"subtype\":\"init\"").count(), 2, "the same init again isn't kept: {transcript}");
    let again = Daemon::open(&w.home, runtime(w.claude.clone())).unwrap();
    assert_eq!(again.get(&lead).unwrap().thread.as_deref(), Some("t2"), "replayed, the latest init's thread");
}

/// The id the user's message went by (the app's, sent or queued with it): on the item zerod records for it.
fn sent_as(conversation: &Conversation) -> Vec<Option<String>> {
    conversation
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            zerod::model::ItemKind::User { sent, .. } => Some(sent.clone()),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_message_keeps_the_id_it_was_sent_or_queued_with() {
    // The app knows its own copy of a message (shown at once) and its queue entry by an id of its own: zerod's item for
    // that message carries it, so the two are matched by what they are, never by their words, which can repeat.
    let w = world("sent-as");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "same words");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    let queued = w.daemon.queue_as(&lead, "same words", &[], Some("queue-1")).unwrap();
    assert_eq!(queued.id, "queue-1", "queued under the app's id");
    seen.say(turn_ends());
    seen.said("user", 2).await;
    let now = until(&w.daemon, &lead, |c| sent_as(c).len() == 2).await;
    assert_eq!(sent_as(&now), [None, Some("queue-1".into())]);
    seen.say(turn_ends());
    until(&w.daemon, &lead, |c| c.status == Status::Idle).await;
    let message = zerod::session::Message { text: "same words", sent: Some("sending-1"), ..Default::default() };
    w.daemon.send(&lead, message, Default::default()).await.unwrap();
    let now = until(&w.daemon, &lead, |c| sent_as(c).len() == 3).await;
    assert_eq!(sent_as(&now)[2], Some("sending-1".into()));
    // Kept through a restart: the transcript says so.
    let again = zerod::session::Session::load(&w.home.join("sessions").join(&lead), tokio::sync::broadcast::channel(8).0).unwrap();
    assert_eq!(sent_as(&again.snapshot()), sent_as(&now));
}

/// A Claude worker that ends its turn while a command it started in the background still runs isn't stopped: Claude
/// wakes it when that finishes. Its lead hears it's waiting on that run, and then how its next turn ends, as any.
#[tokio::test]
async fn a_worker_waiting_on_a_background_run_is_reported_waiting_not_stopped() {
    let w = world("leads-background");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    let worker = w.daemon.spawn(&lead, Provider::Claude, "run the suite", named("Suite", None)).unwrap();
    let running = nth_runtime(&w, 1).await;
    running.said("user", 1).await;
    running.say(json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "t1", "name": "Bash",
        "input": {"command": "cargo test --workspace", "run_in_background": true}}]}}));
    running.say(json!({"type": "system", "subtype": "task_started", "task_id": "b1", "tool_use_id": "t1", "is_backgrounded": true}));
    running.say(json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "Running in the background"}]}}));
    running.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": ""}));
    let told = led.said("user", 2).await;
    let text = told[1]["message"]["content"].as_str().unwrap();
    assert!(
        text.contains("Worker Suite is waiting on a background run: it carries on when it finishes (running: cargo test --workspace)"),
        "{text}"
    );
    assert_eq!(w.daemon.background(&worker), Some(vec!["cargo test --workspace".to_string()]));
    // Its lead waiting on it waits on, too.
    assert!(w.daemon.wait(std::slice::from_ref(&worker), false, Duration::from_millis(200)).await.is_err(), "still running");
    led.say(turn_ends());
    // The run finishes, and Claude carries the worker on: that turn's end reaches its lead as any.
    running.say(json!({"type": "system", "subtype": "task_notification", "task_id": "b1", "tool_use_id": "t1", "status": "completed"}));
    running.say(json!({"type": "assistant", "message": {"id": "m2", "content": [{"type": "text", "text": "All 312 tests pass."}]}}));
    until(&w.daemon, &worker, |c| c.attention() == Attention::Working).await;
    running.say(turn_ends());
    let told = led.said("user", 3).await;
    assert!(told[2]["message"]["content"].as_str().unwrap().contains("Worker Suite finished: All 312 tests pass."), "{told:?}");
    assert_eq!(w.daemon.background(&worker), None);
}

/// A worker is finished once its lead has its report: in the lead's conversation, not while it's queued there.
#[tokio::test]
async fn a_worker_is_finished_once_its_lead_has_its_report() {
    let w = world("leads-reported");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    let worker = finished_worker(&w, &lead).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!w.daemon.finished(&worker), "queued behind the lead's turn");
    led.say(turn_ends());
    led.said("user", 2).await;
    for _ in 0..200 {
        if w.daemon.finished(&worker) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("never counted as reported");
}

/// A message to a closed worker isn't lost: by its id, or its name when only one task has it, the worker comes back
/// from the archive to hear it. `zero wait` finds it there as it is.
#[tokio::test]
async fn a_message_to_an_archived_worker_brings_it_back() {
    let w = world("leads-archived-send");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    let worker = finished_worker(&w, &lead).await;
    w.daemon.archive(&worker).await.unwrap();
    assert!(w.daemon.get(&worker).is_none());
    let settled = w.daemon.wait(std::slice::from_ref(&worker), false, Duration::from_secs(1)).await.unwrap();
    assert_eq!(settled[0].id, worker, "found in the archive");
    assert_eq!(w.daemon.resolve(&worker).unwrap(), worker);
    assert_eq!(w.daemon.get(&worker).unwrap().parent.as_deref(), Some(lead.as_str()), "back, under its lead");
    w.daemon.archive(&worker).await.unwrap();
    assert_eq!(w.daemon.resolve("listing").unwrap(), worker, "by its name");
    assert!(w.daemon.get(&worker).is_some());
    assert_eq!(w.daemon.resolve("nothing").unwrap_err(), "No task nothing");
}

/// A worker's limit as its CLI says it: the account's window full until `resets`, and the turn ended on it.
fn limited(seen: &Seen, resets: i64) {
    seen.say(json!({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": resets,
                    "unifiedWindows": {"seven_day": {"utilization": 1.0, "resetsAt": resets}}}}));
    seen.say(json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": "You've hit your limit"}));
}

fn claude_account(w: &World, label: &str) -> zerod::signins::SignIn {
    w.daemon
        .signins
        .save(zerod::signins::SignIn {
            id: String::new(),
            cli: Provider::Claude,
            kind: zerod::signins::Kind::ClaudeHome,
            label: label.into(),
            plan: None,
            variable: None,
            pending: false,
        })
        .unwrap()
}

/// A worker that Zero carries on as another account at its limit hasn't stopped: its lead hears neither the limit nor
/// the restart onto the new account, only how the work ends.
#[tokio::test]
async fn a_worker_switched_to_another_account_doesnt_alarm_its_lead() {
    let w = world("leads-switch-quiet");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let (_, second) = (claude_account(&w, "a@example.com"), claude_account(&w, "b@example.com"));
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    let worker = w.daemon.spawn(&lead, Provider::Claude, "fix it", named("Fix", None)).unwrap();
    let fixing = nth_runtime(&w, 1).await;
    fixing.said("user", 1).await;
    limited(&fixing, zerod::now() + 3_600);
    until(&w.daemon, &worker, |c| c.signin.as_deref() == Some(second.id.as_str())).await;
    let again = nth_runtime(&w, 2).await;
    assert!(again.said("user", 1).await[0]["message"]["content"].as_str().unwrap().contains("another account"));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(users(&led), 1, "no limit, no process ended: {:?}", led.all());
    // It carries on as the second account, and its end is the news.
    again.say(json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "text", "text": "Fixed."}]}}));
    again.say(turn_ends());
    let told = led.said("user", 2).await;
    assert!(told[1]["message"]["content"].as_str().unwrap().contains("Worker Fix finished: Fixed."), "{told:?}");
}

/// With no other account to go on as, the limit is its lead's news, with when it resets.
#[tokio::test]
async fn a_worker_at_its_only_accounts_limit_tells_its_lead() {
    let w = world("leads-limit-only");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    claude_account(&w, "a@example.com");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    w.daemon.spawn(&lead, Provider::Claude, "fix it", named("Fix", None)).unwrap();
    let fixing = nth_runtime(&w, 1).await;
    fixing.said("user", 1).await;
    let resets = 1_794_942_000;
    limited(&fixing, resets);
    let told = led.said("user", 2).await;
    let text = told[1]["message"]["content"].as_str().unwrap();
    assert!(text.contains("Worker Fix hit a usage limit (it resets at 2026-11-17T19:00:00Z)"), "{text}");
}

/// A worker at its limit when no other account was free waits for its reset; once another account is free, words for
/// it (or a read of the accounts' usage) carry it on as that account, the words with it.
async fn limited_with_none_free(w: &World) -> (String, zerod::signins::SignIn) {
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let (_, second) = (claude_account(w, "a@example.com"), claude_account(w, "b@example.com"));
    let busy = zerod::model::Usage { limited: true, resets_at: Some(zerod::now() + 7_200), ..Default::default() };
    w.daemon.signins.record_usage(&second.id, &busy);
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    let worker = w.daemon.spawn(&lead, Provider::Claude, "fix it", named("Fix", None)).unwrap();
    let fixing = nth_runtime(w, 1).await;
    fixing.said("user", 1).await;
    limited(&fixing, zerod::now() + 3_600);
    until(&w.daemon, &worker, |c| c.attention() == Attention::Limited).await;
    let free = zerod::model::Usage {
        windows: vec![zerod::model::UsageWindow {
            name: "7 days".into(),
            used: 0.1,
            resets_at: Some(zerod::now() + 86_400),
            read_at: Some(zerod::now()),
        }],
        ..Default::default()
    };
    w.daemon.signins.replace_usage(&second.id, &free);
    (worker, second)
}

#[tokio::test]
async fn words_for_a_limited_worker_carry_it_on_once_another_account_is_free() {
    let w = world("leads-limit-freed-words");
    let (worker, second) = limited_with_none_free(&w).await;
    w.daemon.tell_from_zero(&worker, "Go on with the fix.");
    until(&w.daemon, &worker, |c| c.signin.as_deref() == Some(second.id.as_str())).await;
    let said = nth_runtime(&w, 2).await.said("user", 1).await;
    let text = said[0]["message"]["content"].as_str().unwrap();
    assert!(text.contains("another account") && text.contains("Go on with the fix."), "{text}");
}

#[tokio::test]
async fn a_usage_read_carries_a_limited_worker_on_as_a_free_account() {
    let w = world("leads-limit-freed-read");
    let (worker, second) = limited_with_none_free(&w).await;
    w.daemon.carry_on_limited();
    until(&w.daemon, &worker, |c| c.signin.as_deref() == Some(second.id.as_str())).await;
    let said = nth_runtime(&w, 2).await.said("user", 1).await;
    assert!(said[0]["message"]["content"].as_str().unwrap().contains("another account"), "{said:?}");
}

/// A worker that wrote its report and ended it, then hit its account's limit on the next call: its lead gets that
/// report, once, as any turn's end, and nothing of the limit; its turn was over, so it isn't carried on to say it again.
#[tokio::test]
async fn a_worker_limited_after_its_report_hands_its_lead_the_report() {
    let w = world("leads-limit-after-report");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let (_, second) = (claude_account(&w, "a@example.com"), claude_account(&w, "b@example.com"));
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    let worker = w.daemon.spawn(&lead, Provider::Claude, "fix it", named("Fix", None)).unwrap();
    let fixing = nth_runtime(&w, 1).await;
    fixing.said("user", 1).await;
    fixing.say(json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "text", "text": "Fixed the leak in send.rs.\n\n[zero: done]"}]}}));
    limited(&fixing, zerod::now() + 3_600);
    until(&w.daemon, &worker, |c| c.signin.as_deref() == Some(second.id.as_str())).await;
    let told = led.said("user", 2).await;
    assert!(told[1]["message"]["content"].as_str().unwrap().contains("Worker Fix finished: Fixed the leak in send.rs."), "{told:?}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(users(&led), 2, "once, no alarms: {:?}", led.all());
    assert_eq!(w.claude.lock().unwrap().len(), 2, "not started again to say it again");
}

/// One that wrote its report and went on (a command after it) when the limit came: its lead gets what it wrote, and
/// it carries on as another account, told its lead has that, so its next end doesn't say it all again.
#[tokio::test]
async fn a_worker_limited_mid_turn_after_writing_its_report_carries_on_without_repeating_it() {
    let w = world("leads-limit-mid-report");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let (_, second) = (claude_account(&w, "a@example.com"), claude_account(&w, "b@example.com"));
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    let worker = w.daemon.spawn(&lead, Provider::Claude, "fix it", named("Fix", None)).unwrap();
    let fixing = nth_runtime(&w, 1).await;
    fixing.said("user", 1).await;
    fixing.say(json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "text", "text": "Fixed the leak in send.rs."},
        {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "zero done \"fixed\""}}]}}));
    fixing.say(json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "Marked done."}]}}));
    limited(&fixing, zerod::now() + 3_600);
    until(&w.daemon, &worker, |c| c.signin.as_deref() == Some(second.id.as_str())).await;
    let told = led.said("user", 2).await;
    assert!(told[1]["message"]["content"].as_str().unwrap().contains("Worker Fix finished: Fixed the leak in send.rs."), "{told:?}");
    let again = nth_runtime(&w, 2).await;
    let carry_on = again.said("user", 1).await[0]["message"]["content"].as_str().unwrap().to_string();
    assert!(carry_on.contains("another account") && carry_on.contains("don't repeat it"), "{carry_on}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(users(&led), 2, "no alarms: {:?}", led.all());
    led.say(turn_ends());
    again.say(json!({"type": "assistant", "message": {"id": "m2", "content": [{"type": "text", "text": "[zero: done]"}]}}));
    again.say(turn_ends());
    let told = led.said("user", 3).await;
    let reports = told.iter().filter(|m| m["message"]["content"].as_str().unwrap().contains("Fixed the leak")).count();
    assert_eq!(reports, 1, "the report once: {told:?}");
}

/// A worker's report without Zero's ending is sent back for one, and the turn that adds only the ending ("my part is
/// finished, the answer above has it") isn't the report: its lead gets the answer kept from the turn sent back, with
/// what the new turn adds, as the new turn's ending says.
#[tokio::test]
async fn a_worker_sent_back_for_its_ending_keeps_its_report() {
    let w = world("leads-sent-back-report");
    w.daemon.require_endings();
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let led = lead_runtime(&w).await;
    led.said("user", 1).await;
    led.say(turn_ends());
    until(&w.daemon, &lead, |c| c.attention() == Attention::Idle).await;
    w.daemon.spawn(&lead, Provider::Claude, "fix it", named("Fix", None)).unwrap();
    let fixing = nth_runtime(&w, 1).await;
    fixing.said("user", 1).await;
    fixing.say(json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "text", "text": "The cause is a race in send.rs; the fix holds the lock."}]}}));
    fixing.say(turn_ends());
    let back = fixing.said("user", 2).await;
    assert!(back[1]["message"]["content"].as_str().unwrap().contains("Zero can't tell where your turn left the task"), "{back:?}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(users(&led), 1, "nothing for the turn sent back");
    fixing.say(json!({"type": "assistant", "message": {"id": "m2", "content": [{"type": "text", "text": "My part is finished. Tests pass.\n\n[zero: done]"}]}}));
    fixing.say(turn_ends());
    let told = led.said("user", 2).await;
    let text = told[1]["message"]["content"].as_str().unwrap();
    assert!(
        text.contains("Worker Fix finished: The cause is a race in send.rs; the fix holds the lock.\n\nMy part is finished. Tests pass.\n"),
        "{text}"
    );
    assert!(!text.contains("[zero: done]"), "{text}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(users(&led), 2, "once: {:?}", led.all());
}

/// The `n`th Claude session's runtime, once it has started.
async fn claude_runtime(w: &World, n: usize) -> Seen {
    for _ in 0..500 {
        if let Some(seen) = w.claude.lock().unwrap().get(n).cloned() {
            return seen;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("Claude session {n} never started");
}

/// A Claude turn ending on `text`.
fn answers(seen: &Seen, text: &str) {
    seen.say(json!({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}));
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": text}));
}

fn told(said: &[serde_json::Value], n: usize) -> String {
    said[n]["message"]["content"].as_str().unwrap_or_default().to_string()
}

fn noticed(c: &Conversation, words: &str) -> bool {
    c.items.iter().any(|i| matches!(&i.kind, zerod::model::ItemKind::Notice { text, .. } if text.contains(words)))
}

/// The user detaches a worker: a task of its own, told it answers to them; its lead hears no more of it, a quiet line
/// in its conversation saying so, unless it was waiting on that worker, which wakes it.
#[tokio::test]
async fn a_worker_the_user_detaches_answers_to_them_and_its_lead_hears_no_more() {
    let w = world("leads-detach");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let lead_seen = claude_runtime(&w, 0).await;
    lead_seen.said("user", 1).await;
    answers(&lead_seen, "Started it.");
    until(&w.daemon, &lead, |c| c.attention() == Attention::Answered).await;
    let worker = w.daemon.spawn(&lead, Provider::Claude, "list the files", named("Listing", None)).unwrap();
    let worker_seen = claude_runtime(&w, 1).await;
    worker_seen.said("user", 1).await;

    w.daemon.set_parent(&worker, None, None).unwrap();
    assert_eq!(w.daemon.get(&worker).unwrap().parent, None);
    until(&w.daemon, &lead, |c| noticed(c, "Listing was detached by the user; it no longer reports to you")).await;
    answers(&worker_seen, "Listed: none.");
    let said = worker_seen.said("user", 2).await;
    assert!(told(&said, 1).contains("You answer to the user directly now"), "{}", told(&said, 1));
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(lead_seen.all().iter().filter(|m| m["type"] == "user").count(), 1, "its lead heard nothing more");
    assert!(w.daemon.set_parent(&worker, None, None).is_ok(), "a task of its own already: nothing to do");
}

#[tokio::test]
async fn a_lead_waiting_on_the_worker_the_user_detaches_is_told() {
    let w = world("leads-detach-waiting");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let lead_seen = claude_runtime(&w, 0).await;
    lead_seen.said("user", 1).await;
    let worker = w.daemon.spawn(&lead, Provider::Claude, "list the files", named("Listing", None)).unwrap();
    claude_runtime(&w, 1).await.said("user", 1).await;
    answers(&lead_seen, "Waiting on Listing.\n\n[zero: waiting]");
    until(&w.daemon, &lead, |c| c.attention() == Attention::Blocked).await;

    w.daemon.set_parent(&worker, None, None).unwrap();
    let said = lead_seen.said("user", 2).await;
    assert!(told(&said, 1).contains("Listing was detached by the user; it no longer reports to you"), "{}", told(&said, 1));
}

/// The user moves a task under a lead: its worker, in the lead's workspace with its own workers. The lead is told it
/// has a new worker and where it stands; the worker who its lead is; the lead hears its reports from then on.
#[tokio::test]
async fn a_task_the_user_moves_under_a_lead_reports_to_it() {
    let w = world("leads-move");
    let team = w
        .daemon
        .workspaces
        .save(zerod::workspaces::Workspace {
            id: String::new(),
            name: "Team".into(),
            glyph: "briefcase".into(),
            color: "teal".into(),
            plain_answers: None,
        })
        .unwrap()
        .id;
    let options = Options { cwd: Some(w.project.to_str().unwrap().into()), workspace: Some(team.clone()), ..Default::default() };
    let lead = w.daemon.start(Provider::Claude, "lead the work", options).unwrap();
    let lead_seen = claude_runtime(&w, 0).await;
    lead_seen.said("user", 1).await;
    answers(&lead_seen, "Leading.");
    until(&w.daemon, &lead, |c| c.attention() == Attention::Answered).await;
    let task = start(&w.daemon, Provider::Claude, &w.project, "fix the footer");
    w.daemon.label(&task, Some("Footer"), None).unwrap();
    let task_seen = claude_runtime(&w, 1).await;
    task_seen.said("user", 1).await;
    answers(&task_seen, "Fixed the footer's margin.\nIt needs a review.");
    until(&w.daemon, &task, |c| c.attention() == Attention::Answered).await;
    let helper = w.daemon.spawn(&task, Provider::Claude, "check the header", named("Header", None)).unwrap();
    assert_ne!(w.daemon.workspace_of(&w.daemon.get(&task).unwrap()), team);

    w.daemon.set_parent(&task, Some(&lead), None).unwrap();
    assert_eq!(w.daemon.get(&task).unwrap().parent.as_deref(), Some(lead.as_str()));
    assert_eq!(w.daemon.workspace_of(&w.daemon.get(&task).unwrap()), team, "in its lead's workspace");
    assert_eq!(w.daemon.workspace_of(&w.daemon.get(&helper).unwrap()), team, "its own workers with it");
    assert_eq!(w.daemon.get(&helper).unwrap().parent.as_deref(), Some(task.as_str()), "and still under it");
    let said = lead_seen.said("user", 2).await;
    let words = told(&said, 1);
    assert!(words.contains("The user gave you a worker: Footer") && words.contains("Fixed the footer's margin."), "{words}");
    assert!(!words.contains("It needs a review"), "its last answer in a line: {words}");
    let said = task_seen.said("user", 2).await;
    let words = told(&said, 1);
    assert!(words.contains("The user moved this task under") && words.contains("your lead hears how you end"), "{words}");

    answers(&lead_seen, "Noted.");
    answers(&task_seen, "Reviewed.");
    let said = lead_seen.said("user", 3).await;
    assert!(told(&said, 2).contains("Reviewed."), "its report reaches its lead: {}", told(&said, 2));
}

#[tokio::test]
async fn a_move_that_would_make_a_loop_is_refused() {
    let w = world("leads-move-loop");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let worker = w.daemon.spawn(&lead, Provider::Claude, "a part", named("Part", None)).unwrap();
    let below = w.daemon.spawn(&worker, Provider::Claude, "a smaller part", named("Smaller", None)).unwrap();
    assert!(w.daemon.set_parent(&lead, Some(&lead), None).is_err(), "not its own worker");
    assert!(w.daemon.set_parent(&lead, Some(&below), None).is_err(), "nor its worker's worker's");
    assert!(w.daemon.set_parent(&lead, Some("nope"), None).is_err());
    assert!(w.daemon.set_parent("nope", None, None).is_err());
    assert_eq!(w.daemon.get(&lead).unwrap().parent, None);
}

/// A lead's own `zero adopt` and `zero detach` take the user's path: the worker is told who did it; the lead, which did
/// it, isn't told again, its conversation keeping the quiet line.
#[tokio::test]
async fn a_lead_adopting_and_detaching_its_worker_tells_the_worker() {
    let w = world("leads-agent-move");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    w.daemon.label(&lead, Some("Release"), None).unwrap();
    let lead_seen = claude_runtime(&w, 0).await;
    lead_seen.said("user", 1).await;
    answers(&lead_seen, "Leading.");
    until(&w.daemon, &lead, |c| c.attention() == Attention::Answered).await;
    let task = start(&w.daemon, Provider::Claude, &w.project, "fix the footer");
    w.daemon.label(&task, Some("Footer"), None).unwrap();
    let task_seen = claude_runtime(&w, 1).await;
    task_seen.said("user", 1).await;
    answers(&task_seen, "Fixed the footer.");
    until(&w.daemon, &task, |c| c.attention() == Attention::Answered).await;

    assert_eq!(w.daemon.adopt_into(&lead, &task, &lead).unwrap(), task);
    let said = task_seen.said("user", 2).await;
    let words = told(&said, 1);
    assert!(
        words.contains("Release (")
            && words.contains("took this task on: you're its worker now")
            && words.contains("your lead hears how you end"),
        "{words}"
    );
    answers(&task_seen, "Reviewed.");
    let said = lead_seen.said("user", 2).await;
    assert!(told(&said, 1).contains("Reviewed."), "its report, and nothing of the adopting: {}", told(&said, 1));
    answers(&lead_seen, "Noted.");
    until(&w.daemon, &lead, |c| c.attention() == Attention::Answered).await;

    w.daemon.detach(&task, Some(&lead)).unwrap();
    assert_eq!(w.daemon.get(&task).unwrap().parent, None);
    let said = task_seen.said("user", 3).await;
    let words = told(&said, 2);
    assert!(words.contains("Release let this task go") && words.contains("You answer to the user directly now"), "{words}");
    until(&w.daemon, &lead, |c| noticed(c, "Footer was detached by Release")).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(lead_seen.all().iter().filter(|m| m["type"] == "user").count(), 2, "the lead isn't told what it did");
}

/// An agent moves only within its own tree: it detaches its own workers, and adopts a task of its own (no lead) into
/// itself or one of its workers. The user, from the task menu, moves any task.
#[tokio::test]
async fn an_agent_moves_only_tasks_of_its_own_tree() {
    let w = world("leads-agent-limits");
    let a = start(&w.daemon, Provider::Claude, &w.project, "lead A");
    let a_worker = w.daemon.spawn(&a, Provider::Claude, "a part", named("A part", None)).unwrap();
    let b = start(&w.daemon, Provider::Claude, &w.project, "lead B");
    let b_worker = w.daemon.spawn(&b, Provider::Claude, "b part", named("B part", None)).unwrap();
    let loose = start(&w.daemon, Provider::Claude, &w.project, "a loose task");
    let refused = |result: Result<(), String>, why: &str| {
        let error = result.unwrap_err();
        assert!(error.contains(why), "{error}");
    };

    refused(w.daemon.detach(&b_worker, Some(&a)), "isn't your worker");
    refused(w.daemon.detach(&a_worker, Some(&a_worker)), "isn't your worker");
    refused(w.daemon.set_parent(&b_worker, Some(&a), Some(&a)), "has a lead already");
    refused(w.daemon.set_parent(&loose, Some(&b), Some(&a)), "isn't you or one of your workers");
    refused(w.daemon.set_parent(&loose, Some(&b_worker), Some(&a)), "isn't you or one of your workers");
    refused(w.daemon.adopt_into(&b, &loose, &b).and(w.daemon.set_parent(&loose, None, Some(&a))), "isn't your worker");
    assert_eq!(w.daemon.get(&b_worker).unwrap().parent.as_deref(), Some(b.as_str()), "refused, nothing moved");

    let loose = start(&w.daemon, Provider::Claude, &w.project, "another loose task");
    w.daemon.set_parent(&loose, Some(&a_worker), Some(&a)).unwrap();
    assert_eq!(w.daemon.get(&loose).unwrap().parent.as_deref(), Some(a_worker.as_str()), "into one of its workers");
    w.daemon.detach(&a_worker, Some(&a)).unwrap();
    w.daemon.set_parent(&b_worker, Some(&a), None).unwrap();
    assert_eq!(w.daemon.get(&b_worker).unwrap().parent.as_deref(), Some(a.as_str()), "the user's move");
}

/// A task moved under a worker whose own workspace was never set joins the workspace its tree shows in: its top
/// lead's, as the board and the app have it.
#[tokio::test]
async fn a_task_moved_under_a_worker_joins_its_top_leads_workspace() {
    let w = world("leads-move-top-workspace");
    let team = w
        .daemon
        .workspaces
        .save(zerod::workspaces::Workspace {
            id: String::new(),
            name: "Team".into(),
            glyph: "briefcase".into(),
            color: "teal".into(),
            plain_answers: None,
        })
        .unwrap()
        .id;
    let options = Options { cwd: Some(w.project.to_str().unwrap().into()), workspace: Some(team.clone()), ..Default::default() };
    let lead = w.daemon.start(Provider::Claude, "lead the work", options).unwrap();
    let worker = w.daemon.spawn(&lead, Provider::Claude, "a part", named("Part", None)).unwrap();
    w.daemon.session(&worker).unwrap().change(Change::Placed { workspace: None });
    let task = start(&w.daemon, Provider::Claude, &w.project, "a loose task");

    w.daemon.set_parent(&task, Some(&worker), None).unwrap();
    assert_eq!(w.daemon.workspace_of(&w.daemon.get(&task).unwrap()), team, "its top lead's, not its worker's own");
}

/// One account at its limit isn't the CLI's: a new task starts as another account that's free, without force, even
/// while a task still reports the first one's limit. Only with every account limited is a start refused, and then with
/// the time it resets, not a count of seconds.
#[tokio::test]
async fn a_new_task_starts_as_a_free_account_while_another_is_at_its_limit() {
    let w = world("signin-start-free");
    let dot = w.home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    w.daemon.signins.set_claude_dir(dot);
    let first = claude_account(&w, "a@example.com");
    let lead = start(&w.daemon, Provider::Claude, &w.project, "lead the work");
    let seen = lead_runtime(&w).await;
    seen.said("user", 1).await;
    limited(&seen, zerod::now() + 3_600);
    until(&w.daemon, &lead, |c| c.usage.as_ref().is_some_and(|u| u.limited)).await;
    let options = || Options { cwd: Some(w.project.to_str().unwrap().into()), ..Default::default() };
    let refused = w.daemon.start(Provider::Claude, "another job", options()).unwrap_err();
    assert!(refused.ends_with("usage limit for 1 h"), "{refused}");
    let second = claude_account(&w, "b@example.com");
    let next = w.daemon.start(Provider::Claude, "another job", options()).expect("a free account to start on");
    assert_eq!(w.daemon.get(&next).unwrap().signin.as_deref(), Some(second.id.as_str()));
    assert_ne!(Some(first.id.as_str()), w.daemon.get(&next).unwrap().signin.as_deref());
}
