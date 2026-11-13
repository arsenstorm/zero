//! A finished task (archived, or done) isn't woken by what only confirms its end: an issue moved to Done, its pull
//! request merged or approved, CI passing, a bot's word. Those are noted in its conversation, quietly, and it stays
//! put away; once everything it follows has ended, it stops following. What needs it (reopened, changes asked, CI
//! failing, a person's comment) brings it back as before.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::{Seen, play, temp_dir};
use serde_json::{Value, json};
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::following::*;
use zerod::integrations::{Fetcher, Integrations};
use zerod::model::{Attention, Conversation, ItemKind, Provider};

#[derive(Default)]
struct Canned(Mutex<Vec<Value>>);

impl Fetcher for Canned {
    fn run(&self, _: Vec<String>, _: Option<String>) -> zerod::inbox::Fut<'_, Result<String, String>> {
        let mut answers = self.0.lock().unwrap();
        let answer = if answers.is_empty() { Err("nothing canned".to_string()) } else { Ok(answers.remove(0).to_string()) };
        Box::pin(async move { answer })
    }
}

fn following(home: &Path, answers: Vec<Value>) -> Arc<Following> {
    std::fs::write(home.join("linear.json"), r#"{"name":"Acme","url_key":"acme","access":"lin_tok","refresh":null,"expires":9999999999}"#)
        .unwrap();
    let fetcher = Arc::new(Canned(Mutex::new(answers)));
    let following = Following::open(home, fetcher.clone(), Integrations::open(home, fetcher));
    following.set_window(0);
    following
}

/// A Linear issue in a state of the type given, with comments by people (`who`) or by a bot (`who` starting "bot:").
fn issue(state: (&str, &str), comments: &[(&str, &str, &str)]) -> Value {
    json!({"data": {"viewer": {"id": "me", "name": "Arsen"}, "issue": {
        "id": "iss", "identifier": "ENG-1", "title": "Vitals", "description": "", "url": "https://linear.app/acme/issue/ENG-1",
        "priorityLabel": "High", "estimate": null, "dueDate": null, "state": {"name": state.0, "type": state.1}, "assignee": null,
        "project": null, "cycle": null, "parent": null, "labels": {"nodes": []},
        "comments": {"nodes": comments.iter().map(|(id, who, body)| {
            let (user, bot) = match who.strip_prefix("bot:") {
                Some(name) => (Value::Null, json!({"name": name})),
                None => (json!({"id": who, "name": who}), Value::Null),
            };
            json!({"id": id, "body": body, "url": "https://linear.app/acme/issue/ENG-1", "createdAt": format!("2026-11-13T10:00:0{id}Z"),
                "updatedAt": "2026-11-13T10:00:00Z", "user": user, "botActor": bot, "parent": null})
        }).collect::<Vec<_>>()}
    }}})
}

/// A pull request in `state`, with its review decision, CI result and comments (a bot's `who` starting "bot:").
fn pr(state: &str, decision: Value, ci: &str, comments: &[(&str, &str)]) -> Value {
    json!({"data": {"viewer": {"login": "arsen"}, "repository": {"pullRequest": {
        "title": "Fix vitals", "url": "https://github.com/o/r/pull/42", "state": state, "isDraft": false, "body": "",
        "baseRefName": "main", "headRefName": "fix", "headRefOid": "abc", "mergeable": "MERGEABLE", "reviewDecision": decision,
        "author": {"login": "arsen"}, "mergedBy": if state == "MERGED" { json!({"login": "pm"}) } else { Value::Null },
        "assignees": {"nodes": []}, "labels": {"nodes": []}, "reviewRequests": {"nodes": []},
        "comments": {"nodes": comments.iter().map(|(id, who)| {
            let (login, kind) = match who.strip_prefix("bot:") { Some(name) => (name, "Bot"), None => (*who, "User") };
            json!({"id": id, "author": {"login": login, "__typename": kind}, "body": "words", "url": "u", "createdAt": "2026-11-13T10:00:00Z", "updatedAt": "2026-11-13T10:00:00Z"})
        }).collect::<Vec<_>>()},
        "reviews": {"nodes": []}, "reviewThreads": {"nodes": []},
        "commits": {"totalCount": 1, "nodes": [{"commit": {"oid": "abc", "messageHeadline": "Fix", "statusCheckRollup": {
            "state": ci, "contexts": {"nodes": [{"__typename": "CheckRun", "name": "test", "status": "COMPLETED",
                "conclusion": if ci == "FAILURE" { "FAILURE" } else { "SUCCESS" }, "detailsUrl": "https://ci/test"}]}}}}]}
    }}}})
}

type Told = Arc<Mutex<Vec<(String, String, Heard)>>>;

async fn tick(following: &Following) -> Vec<(String, String, Heard)> {
    let told: Told = Arc::default();
    following.hurry();
    following.tick(|_| true, |_| true, |s: &str, w: &str, h: Heard| told.lock().unwrap().push((s.into(), w.into(), h))).await;
    told.lock().unwrap().clone()
}

/// Each reading after the first, one tick each: how the session heard of it.
async fn heard(answers: Vec<Value>, topic: &str) -> Vec<Heard> {
    let rounds = answers.len() - 1;
    // A folder each: the tests calling this run side by side.
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let following = following(&temp_dir(&format!("settled-heard-{n}")), answers);
    following.follow("s", topic, false, vec![]).await.unwrap();
    let mut out = vec![];
    for _ in 0..rounds {
        out.extend(tick(&following).await.into_iter().map(|(_, _, h)| h))
    }
    out
}

#[tokio::test]
async fn an_issue_reaching_its_end_or_a_bots_comment_only_settles() {
    let review = ("PM review", "started");
    assert_eq!(heard(vec![issue(review, &[]), issue(("Done", "completed"), &[])], "linear/ENG-1").await, [Heard::Settled]);
    assert_eq!(heard(vec![issue(review, &[]), issue(("Canceled", "canceled"), &[])], "linear/ENG-1").await, [Heard::Settled]);
    assert_eq!(
        heard(vec![issue(("Done", "completed"), &[]), issue(("Done", "completed"), &[("1", "bot:GitHub", "PR merged")])], "linear/ENG-1")
            .await,
        [Heard::Settled],
        "a bot's comment"
    );
}

#[tokio::test]
async fn an_issue_moved_back_or_a_persons_comment_needs_the_task() {
    let done = ("Done", "completed");
    assert_eq!(
        heard(vec![issue(done, &[]), issue(("In Progress", "started"), &[])], "linear/ENG-1").await,
        [Heard::News],
        "moved back from done"
    );
    assert_eq!(
        heard(vec![issue(done, &[]), issue(done, &[("1", "pm", "Actually, there's a problem")])], "linear/ENG-1").await,
        [Heard::News],
        "a person's comment"
    );
    assert_eq!(
        heard(vec![issue(("PM review", "started"), &[]), issue(done, &[("1", "pm", "One more thing")])], "linear/ENG-1").await,
        [Heard::News],
        "with something that needs it, everything goes to it as news"
    );
}

#[tokio::test]
async fn a_pull_request_merged_approved_or_passing_only_settles() {
    let topic = "github/o/r/42";
    let open = || pr("OPEN", Value::Null, "PENDING", &[]);
    assert_eq!(heard(vec![open(), pr("MERGED", Value::Null, "PENDING", &[])], topic).await, [Heard::Settled], "merged");
    assert_eq!(heard(vec![open(), pr("OPEN", json!("APPROVED"), "PENDING", &[])], topic).await, [Heard::Settled], "approved");
    assert_eq!(heard(vec![open(), pr("OPEN", Value::Null, "SUCCESS", &[])], topic).await, [Heard::Settled], "CI passing");
    assert_eq!(heard(vec![open(), pr("OPEN", Value::Null, "PENDING", &[("c1", "bot:vercel")])], topic).await, [Heard::Settled], "a bot");
    assert_eq!(heard(vec![open(), pr("OPEN", json!("CHANGES_REQUESTED"), "PENDING", &[])], topic).await, [Heard::News], "changes asked");
    assert_eq!(heard(vec![open(), pr("OPEN", Value::Null, "FAILURE", &[])], topic).await, [Heard::News], "CI failing");
    assert_eq!(heard(vec![open(), pr("OPEN", Value::Null, "PENDING", &[("c1", "pm")])], topic).await, [Heard::News], "a person");
    assert_eq!(heard(vec![pr("CLOSED", Value::Null, "PENDING", &[]), open()], topic).await, [Heard::News], "reopened");
}

#[tokio::test]
async fn a_session_has_finished_once_everything_it_follows_has_ended() {
    let following = following(
        &temp_dir("settled-finished"),
        // Read as followed (the issue, then the pull request), then polled in order (the pull request first).
        vec![
            issue(("PM review", "started"), &[]),
            pr("OPEN", Value::Null, "PENDING", &[]),
            pr("MERGED", Value::Null, "SUCCESS", &[]),
            issue(("Done", "completed"), &[]),
        ],
    );
    following.follow("s", "linear/ENG-1", false, vec![]).await.unwrap();
    following.follow("s", "github/o/r/42", false, vec![]).await.unwrap();
    assert!(!following.finished("s"), "the issue is still in review");
    assert!(!following.finished("nobody"), "following nothing isn't finished following");
    tick(&following).await;
    assert!(following.finished("s"), "issue done, pull request merged");
}

struct World {
    daemon: Arc<Daemon>,
    home: std::path::PathBuf,
    claude: Arc<Mutex<Vec<Seen>>>,
}

fn world(name: &str) -> World {
    let home = temp_dir(name);
    std::fs::create_dir_all(home.join("project")).unwrap();
    let claude = Arc::new(Mutex::new(vec![]));
    let seen = claude.clone();
    let runtime: Runtime = Arc::new(move |_: &Conversation, _: &Path, _: &[String]| {
        let (transport, recorder) = play(vec![]);
        seen.lock().unwrap().push(recorder);
        Ok(transport)
    });
    World { daemon: Daemon::open(&home, runtime).unwrap(), home, claude }
}

/// A task that has finished its first turn and been archived.
async fn archived(w: &World) -> String {
    let cwd = Some(w.home.join("project").to_str().unwrap().to_string());
    let id = w.daemon.start(Provider::Claude, "fix it", Options { cwd, ..Default::default() }).unwrap();
    for _ in 0..500 {
        if !w.claude.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let seen = w.claude.lock().unwrap()[0].clone();
    seen.said("user", 1).await;
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "Merged. [zero: done]"}));
    for _ in 0..500 {
        if w.daemon.get(&id).is_some_and(|c| c.attention() != Attention::Working) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    w.daemon.archive(&id).await.unwrap();
    id
}

#[tokio::test]
async fn an_archived_task_hears_what_settles_quietly_and_stays_archived() {
    let w = world("settled-archived");
    let id = archived(&w).await;
    assert!(w.daemon.settle(&id, "ENG-1 status: PM review → Done", || false), "taken quietly");
    assert!(w.daemon.get(&id).is_none(), "still archived");
    let listed = w.daemon.archived(10);
    assert_eq!(listed[0]["quiet"], "ENG-1 status: PM review → Done", "the archive shows what it last heard: {listed:?}");
    assert!(listed[0]["quietAt"].as_i64().is_some_and(|at| at > 0));
    w.daemon.unarchive(&id).unwrap();
    let items = w.daemon.get(&id).unwrap().items;
    assert!(
        items.iter().any(|i| matches!(&i.kind, ItemKind::Notice { text, .. } if text.contains("ENG-1 status: PM review → Done"))),
        "noted in its conversation"
    );
    assert_eq!(w.claude.lock().unwrap()[0].all().iter().filter(|m| m["type"] == "user").count(), 1, "the agent wasn't told");
}

#[tokio::test]
async fn a_live_task_hears_what_settles_quietly_only_when_done() {
    let w = world("settled-live");
    let cwd = Some(w.home.join("project").to_str().unwrap().to_string());
    let id = w.daemon.start(Provider::Claude, "fix it", Options { cwd, ..Default::default() }).unwrap();
    assert!(!w.daemon.settle(&id, "o/r#42 PR merged", || false), "a task at work is told as news");
    assert!(w.daemon.settle(&id, "o/r#42 PR merged", || true), "a done one only notes it");
    assert!(!w.daemon.settle("nothing", "x", || true));
}

/// Archived with everything it follows ended, a task stops following: nothing more can come of them.
#[tokio::test]
async fn a_task_archived_with_its_work_ended_stops_following() {
    let w = world("settled-archive-unfollows");
    let f = following(&w.home, vec![issue(("Done", "completed"), &[])]);
    w.daemon.set_following(f.clone());
    let id = archived(&w).await;
    w.daemon.unarchive(&id).unwrap();
    f.follow(&id, "linear/ENG-1", false, vec![]).await.unwrap();
    w.daemon.archive(&id).await.unwrap();
    assert!(f.list(Some(&id)).is_empty(), "its issue is done: it stops following");
}
