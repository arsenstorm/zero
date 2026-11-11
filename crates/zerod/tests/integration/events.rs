//! Word from outside a session: anything can tell a session something, a command it runs in the background wakes
//! it when it ends, a reminder wakes it later, and a session stopped by a usage limit is told to go on once the limit
//! resets. Plus what each provider last said about its limits, so no one starts more agents into one.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::common::{Seen, fixture, play, temp_dir};
use serde_json::json;
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::{Attention, Change, Conversation, Item, ItemKind, ItemStatus, Provider};

struct World {
    daemon: Arc<Daemon>,
    project: PathBuf,
    claude: Arc<Mutex<Vec<Seen>>>,
}

fn world(name: &str) -> World {
    let home = temp_dir(name);
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let claude = Arc::new(Mutex::new(vec![]));
    let seen = claude.clone();
    let runtime: Runtime = Arc::new(move |conversation: &Conversation, _: &std::path::Path, _: &[String]| {
        let (transport, recorder) = play(if conversation.provider == Provider::Codex { fixture("codex-command") } else { vec![] });
        if conversation.provider == Provider::Claude {
            seen.lock().unwrap().push(recorder)
        }
        Ok(transport)
    });
    World { daemon: Daemon::open(&home, runtime).unwrap(), project, claude }
}

async fn until(daemon: &Daemon, session: &str, test: impl Fn(&Conversation) -> bool) -> Conversation {
    for _ in 0..1000 {
        if let Some(now) = daemon.get(session)
            && test(&now)
        {
            return now;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out: {:#?}", daemon.get(session));
}

/// A Claude session that has finished its first turn and sits idle, and what its runtime hears.
async fn idle_claude(w: &World) -> (String, Seen) {
    let id = w
        .daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(w.project.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    let mut seen = None;
    for _ in 0..500 {
        if let Some(found) = w.claude.lock().unwrap().last().cloned() {
            seen = Some(found);
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let seen = seen.expect("Claude started");
    seen.said("user", 1).await;
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"}));
    until(&w.daemon, &id, |c| c.attention() == Attention::Idle).await;
    (id, seen)
}

fn told(seen: &Seen) -> Vec<String> {
    seen.all().iter().filter(|m| m["type"] == "user").filter_map(|m| m["message"]["content"].as_str().map(String::from)).skip(1).collect()
}

#[tokio::test]
async fn anything_can_tell_a_session_something() {
    let w = world("events-notify");
    let (id, seen) = idle_claude(&w).await;
    w.daemon.notify(&id, "CI on #42 passed").unwrap();
    assert_eq!(
        seen.said("user", 2).await[1]["message"]["content"],
        zerod::model::from_line("zero", "CI on #42 passed"),
        "marked as Zero's word, not the user's"
    );
    assert!(w.daemon.notify("nope", "x").is_err());
    // Another task's words (`zero send` from inside one): marked as that task's, never the user's.
    w.daemon.notify_from(&id, "01a1worker", "Fix pushed; CI running").unwrap();
    seen.say(serde_json::json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"}));
    assert_eq!(seen.said("user", 3).await[2]["message"]["content"], zerod::model::from_line("01a1worker", "Fix pushed; CI running"));
}

#[tokio::test]
async fn a_watched_command_wakes_its_session_with_how_it_ended() {
    let w = world("events-watch");
    let (id, seen) = idle_claude(&w).await;
    w.daemon.watch(&id, "echo checks done; echo all green; exit 3").unwrap();
    let words = seen.said("user", 2).await[1]["message"]["content"].as_str().unwrap().to_string();
    assert!(
        words.starts_with("<!-- from: zero -->\n`echo checks done; echo all green; exit 3` finished with exit 3"),
        "Zero's word, not the user's: {words}"
    );
    assert!(words.contains("checks done\nall green"), "{words}");
}

#[tokio::test]
async fn a_watched_command_runs_in_the_sessions_folder() {
    let w = world("events-watch-cwd");
    let (id, seen) = idle_claude(&w).await;
    w.daemon.watch(&id, "pwd -P").unwrap();
    let words = seen.said("user", 2).await[1]["message"]["content"].as_str().unwrap().to_string();
    assert!(words.contains(w.project.canonicalize().unwrap().to_str().unwrap()), "{words}");
}

#[tokio::test(start_paused = true)]
async fn a_reminder_wakes_a_session_later() {
    let w = world("events-remind");
    let (id, seen) = idle_claude(&w).await;
    // Within the time an idle agent keeps its process (parking.rs has one woken from parked).
    w.daemon.remind(&id, Duration::from_secs(2 * 60), "Check whether the deploy finished").unwrap();
    tokio::time::sleep(Duration::from_secs(110)).await;
    assert!(told(&seen).is_empty());
    tokio::time::sleep(Duration::from_secs(20)).await;
    assert_eq!(seen.said("user", 2).await[1]["message"]["content"], "<!-- from: zero -->\nScheduled: Check whether the deploy finished");
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64
}

#[tokio::test(start_paused = true)]
async fn a_session_stopped_by_a_limit_goes_on_once_it_resets() {
    let w = world("events-reset");
    let (id, seen) = idle_claude(&w).await;
    let resets = now() + 30 * 60;
    seen.say(json!({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": resets, "unifiedWindows": {}}}));
    until(&w.daemon, &id, |c| c.attention() == Attention::Limited).await;
    tokio::time::sleep(Duration::from_secs(29 * 60)).await;
    assert!(told(&seen).is_empty(), "not before the reset");
    tokio::time::sleep(Duration::from_secs(3 * 60)).await;
    let words = seen.said("user", 2).await[1]["message"]["content"].as_str().unwrap().to_string();
    assert!(words.starts_with("<!-- from: zero -->\nThe usage limit has reset"), "{words}");
}

#[tokio::test]
async fn the_usage_view_has_each_providers_latest_limits_and_stops_new_agents_at_one() {
    let w = world("events-usage");
    let (id, seen) = idle_claude(&w).await;
    assert!(w.daemon.usage().is_empty() || w.daemon.usage().iter().all(|(p, _)| *p != Provider::Codex));
    let resets = now() + 3600;
    seen.say(json!({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": resets,
        "unifiedWindows": {"five_hour": {"utilization": 1.0, "resetsAt": resets}}}}));
    until(&w.daemon, &id, |c| c.usage.as_ref().is_some_and(|u| u.limited)).await;
    let usage = w.daemon.usage();
    let claude = usage.iter().find(|(p, _)| *p == Provider::Claude).map(|(_, u)| u.clone()).unwrap();
    assert!(claude.limited);
    assert_eq!(claude.resets_at, Some(resets));
    let refused = w.daemon.spawn(&id, Provider::Claude, "more work", Options::default()).unwrap_err();
    assert!(refused.contains("usage limit"), "{refused}");
    assert!(w.daemon.spawn(&id, Provider::Claude, "more work", Options { force: true, ..Default::default() }).is_ok(), "unless forced");
    assert!(w.daemon.spawn(&id, Provider::Codex, "other work", Options::default()).is_ok(), "another provider isn't limited");
}

#[tokio::test]
async fn an_async_ask_from_a_zerod_session_is_answered_into_that_session() {
    let w = world("events-inbox");
    let (id, seen) = idle_claude(&w).await;
    let inbox = zerod::inbox::Inbox::open(None, vec![std::sync::Arc::new(zerod::daemon::Sessions::of(&w.daemon))]);
    inbox.configure(Duration::from_millis(20), 3600);
    let agent = zerod::ask::AgentIdentity {
        name: format!("zerod-{id}"),
        host: "mac".into(),
        runtime: Some("zerod".into()),
        reference: Some(id.clone()),
        ..Default::default()
    };
    let mut ask = zerod::ask::Ask::new(zerod::ask::AskKind::Choice, "Ship it?", agent, 3600);
    ask.options = vec!["Yes".into(), "No".into()];
    ask.waits = Some(false);
    let ask = inbox.create(ask, false);
    inbox.choose(&ask.id, 0);
    let words = seen.said("user", 2).await[1]["message"]["content"].as_str().unwrap().to_string();
    assert_eq!(words, zerod::model::from_line("zero", &format!("The user answered your ask {} (\"Ship it?\"): Yes", ask.id)));
}

#[tokio::test]
async fn after_compacting_the_agent_hears_zeros_record_word_for_word_not_only_its_summary() {
    let w = world("events-recap");
    let (id, seen) = idle_claude(&w).await;
    let inbox = zerod::inbox::Inbox::open(None, vec![]);
    zerod::recap::start(w.daemon.clone(), inbox.clone());
    let agent = zerod::ask::AgentIdentity { name: format!("zerod-{id}"), host: "mac".into(), ..Default::default() };
    let mut ask = zerod::ask::Ask::new(zerod::ask::AskKind::Choice, "Ship it?", agent, 3600);
    ask.waits = Some(false);
    let ask = inbox.create(ask, false);
    let session = w.daemon.session(&id).unwrap();
    let user = |id: &str, text: &str| Change::Item {
        item: Item {
            at: None,
            id: id.into(),
            turn: None,
            kind: ItemKind::User { text: text.into(), images: vec![], sent: None },
            status: ItemStatus::Done,
        },
    };
    session.change(user("u2", "Fix the login bug, and keep the old cookie name"));
    session.change(user("u3", &zerod::model::from_line("zero", "A schedule came due")));
    let state = zerod::model::IssueState::named("working").unwrap();
    session.change(Change::Issue { issue: zerod::model::Issue::set(None, "WEB-42", state, "Reviewing the fix", 0) });
    session.change(Change::Status { status: zerod::model::Status::Working, turn: Some("t2".into()), error: None });
    seen.say(json!({"type": "system", "subtype": "status", "status": "compacting"}));
    seen.say(json!({"type": "system", "subtype": "status", "status": null, "compact_result": "success"}));
    let words = seen.said("user", 2).await[1]["message"]["content"].as_str().unwrap().to_string();
    assert!(words.starts_with(&zerod::model::from_line("zero", "")), "Zero's, not the user's: {words}");
    assert!(words.contains("Fix the login bug, and keep the old cookie name"), "{words}");
    assert!(!words.contains("A schedule came due"), "the user's words, not Zero's: {words}");
    assert!(words.contains("WEB-42") && words.contains("Reviewing the fix"), "{words}");
    assert!(words.contains(&ask.id) && words.contains("Ship it?"), "{words}");
}

#[tokio::test]
async fn a_blocking_ask_holds_what_else_comes_for_the_task_until_the_user_answers() {
    // Asked with --block: the agent can't go on without the answer, so Zero holds its events and reports meanwhile.
    // The answer itself, and the user's own words, go.
    let w = world("events-blocking");
    let (id, seen) = idle_claude(&w).await;
    let inbox = zerod::inbox::Inbox::open(None, vec![std::sync::Arc::new(zerod::daemon::Sessions::of(&w.daemon))]);
    inbox.configure(Duration::from_millis(20), 3600);
    zerod::server::hold_while_blocked(&w.daemon, &inbox);
    let agent = zerod::ask::AgentIdentity {
        name: format!("zerod-{id}"),
        host: "mac".into(),
        runtime: Some("zerod".into()),
        reference: Some(id.clone()),
        ..Default::default()
    };
    let mut ask = zerod::ask::Ask::new(zerod::ask::AskKind::Choice, "Merge it?", agent, 3600);
    ask.options = vec!["Yes".into(), "No".into()];
    ask.waits = Some(false);
    ask.blocks = true;
    let ask = inbox.create(ask, false);
    w.daemon.notify(&id, "1 new event on what you follow").unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!told(&seen).iter().any(|t| t.contains("1 new event")), "held while the ask blocks: {:?}", told(&seen));
    inbox.choose(&ask.id, 0);
    let words = seen.said("user", 2).await[1]["message"]["content"].as_str().unwrap().to_string();
    assert!(words.contains("The user answered your ask") && words.contains("1 new event"), "the answer, then what was held: {words}");
}
