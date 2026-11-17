//! What holds a task's messages, and what gets past: the user's and its lead's words always do (unless the user paused
//! it, it's blocked on an ask, or signed out), as do the words of the task it waits on. Only the other task of a pair
//! that wrote to each other too often without the user is held. No queue outlives its reason: a task it waited on put
//! away wakes it, and words a restart or an unarchiving left behind go.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::temp_dir;
use crate::endings::{listening, turn};
use zerod::daemon::{Daemon, Options};
use zerod::model::{Change, Provider, Status};

struct Team {
    daemon: Arc<Daemon>,
    lead: String,
    fixer: String,
    verifier: String,
    sent: Arc<Mutex<String>>,
}

/// A lead and two workers, the fixer and its verifier (labelled "verifier"), each between turns.
async fn team(name: &str) -> Team {
    let home = temp_dir(name);
    let sent = Arc::new(Mutex::new(String::new()));
    let daemon = Daemon::open(&home.join("zerod"), listening(sent.clone())).unwrap();
    let lead = daemon.start(Provider::Claude, "lead", Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap();
    let fixer = daemon.spawn(&lead, Provider::Claude, "fix it", Default::default()).unwrap();
    let verifier = daemon.spawn(&lead, Provider::Claude, "verify it", Default::default()).unwrap();
    daemon.label(&verifier, Some("verifier"), None).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&lead, &fixer, &verifier] {
        idle(&daemon, id).await
    }
    Team { daemon, lead, fixer, verifier, sent }
}

async fn idle(daemon: &Daemon, id: &str) {
    daemon.session(id).unwrap().change(Change::Status { status: Status::Idle, turn: None, error: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
}

/// The fixer and the verifier write to each other eleven times: past the limit, the fixer holds the verifier's words.
async fn cross(t: &Team) {
    for n in 0..11 {
        let (to, from) = if n % 2 == 0 { (&t.fixer, &t.verifier) } else { (&t.verifier, &t.fixer) };
        t.daemon.notify_from(to, from, &format!("crossing {n}")).unwrap();
    }
    idle(&t.daemon, &t.fixer).await;
    idle(&t.daemon, &t.verifier).await;
}

fn said(t: &Team) -> String {
    t.sent.lock().unwrap().clone()
}

#[tokio::test]
async fn a_leads_words_and_zeros_reach_a_worker_holding_a_siblings() {
    let t = team("held-lead").await;
    cross(&t).await;
    assert!(t.daemon.holding_crossed(&t.fixer));
    t.daemon.notify_from(&t.verifier, &t.fixer, "fixer to verifier").unwrap();
    idle(&t.daemon, &t.fixer).await;
    let held = "verifier to fixer, held";
    t.daemon.notify_from(&t.fixer, &t.verifier, held).unwrap();
    idle(&t.daemon, &t.fixer).await;
    assert!(!said(&t).contains(held), "the verifier's words wait for the user: {}", said(&t));

    let lead = t.daemon.notify_from(&t.fixer, &t.lead, "lead: carry on").unwrap();
    assert_eq!(lead, None, "not held");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(said(&t).contains("lead: carry on"), "its lead's words go at once: {}", said(&t));
    idle(&t.daemon, &t.fixer).await;
    assert!(said(&t).contains(held), "and they lift the pair's hold: {}", said(&t));

    idle(&t.daemon, &t.fixer).await;
    t.daemon.notify(&t.fixer, "1 new event on what you follow").unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(said(&t).contains("1 new event on what you follow"), "Zero's own go too: {}", said(&t));
}

#[tokio::test]
async fn the_task_it_waits_on_reaches_it_past_the_limit() {
    let t = team("held-awaited").await;
    let fixing = t.daemon.session(&t.fixer).unwrap();
    turn(&fixing, 1, "fix it", "Fix pushed.\n\n[zero: waiting on verifier]").await;
    cross(&t).await;
    assert!(said(&t).contains("crossing 10"), "the verifier's words reach the fixer waiting on it: {}", said(&t));
    let notices = t
        .daemon
        .get(&t.fixer)
        .unwrap()
        .items
        .iter()
        .any(|i| matches!(&i.kind, zerod::model::ItemKind::Notice { text, .. } if text.contains("holding messages")));
    assert!(!notices, "nothing held, so nothing said to be");
}

#[tokio::test]
async fn an_empty_turn_end_wakes_no_one() {
    // Two tasks waiting on each other would wake each other forever on turns that say nothing.
    let t = team("held-empty").await;
    let (fixing, verifying) = (t.daemon.session(&t.fixer).unwrap(), t.daemon.session(&t.verifier).unwrap());
    turn(&fixing, 1, "fix it", "Fix pushed.\n\n[zero: waiting on verifier]").await;
    turn(&verifying, 1, "verify it", &format!("[zero: waiting on {}]", t.fixer)).await;
    assert!(!said(&t).contains("which you wait on"), "{}", said(&t));
    // One that waits on no one, ending with nothing to say, still wakes the task waiting on it.
    turn(&verifying, 2, "go on", "[zero: done]").await;
    assert!(said(&t).contains("verifier, which you wait on, ended its turn: nothing"), "{}", said(&t));
}

#[tokio::test]
async fn a_task_waiting_on_one_put_away_or_stopped_is_woken() {
    let t = team("held-archived").await;
    let fixing = t.daemon.session(&t.fixer).unwrap();
    turn(&fixing, 1, "fix it", "Fix pushed.\n\n[zero: waiting on verifier]").await;
    t.daemon.archive(&t.verifier).await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(said(&t).contains("verifier, which you wait on, was put away."), "{}", said(&t));
    assert!(!said(&t).contains("was put away.\\n"), "no way to reply to a task put away: {}", said(&t));

    // Its process ending mid-turn: stopped, not an old answer passed off as its turn's end.
    let other = t.daemon.spawn(&t.lead, Provider::Claude, "check it", Default::default()).unwrap();
    t.daemon.label(&other, Some("checker"), None).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&t.daemon, &other).await;
    turn(&fixing, 2, "go on", "Asked the checker.\n\n[zero: waiting on checker]").await;
    let checking = t.daemon.session(&other).unwrap();
    checking.change(Change::Status { status: Status::Working, turn: Some("c1".into()), error: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
    checking.change(Change::Status { status: Status::Offline, turn: None, error: None });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(said(&t).contains("checker, which you wait on, stopped"), "{}", said(&t));
}

#[tokio::test]
async fn words_a_restart_left_for_a_parked_task_go_once_zerod_is_up() {
    // A hold kept in memory (the pair's limit) is gone with the restart: what it held is no longer held, and goes.
    let home = temp_dir("held-restart");
    let sent = Arc::new(Mutex::new(String::new()));
    let daemon = Daemon::open(&home.join("zerod"), listening(sent.clone())).unwrap();
    let id = daemon.start(Provider::Claude, "hi", Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    daemon.session(&id).unwrap().change(Change::Status { status: Status::Offline, turn: None, error: None });
    drop(daemon);
    let report = zerod::model::from_line("01a1other", "round 3 findings");
    let queued = serde_json::json!([{"id": "q1", "text": report, "report": true}]);
    std::fs::write(home.join("zerod/sessions").join(&id).join("pending.json"), queued.to_string()).unwrap();

    let again = Daemon::open(&home.join("zerod"), listening(sent.clone())).unwrap();
    assert_eq!(again.deliver_stranded(), std::slice::from_ref(&id), "resumed for them");
    tokio::time::sleep(Duration::from_millis(200)).await;
    idle(&again, &id).await;
    assert!(sent.lock().unwrap().contains("round 3 findings"), "{}", sent.lock().unwrap());
    assert!(again.deliver_stranded().is_empty(), "once");
}

#[tokio::test]
async fn a_leads_words_bring_a_put_away_worker_back_past_what_it_left() {
    // Put away with words waiting, a worker comes back with them held for the user; its lead's words still go.
    let t = team("held-unarchived").await;
    t.daemon.session(&t.fixer).unwrap().change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    t.daemon.notify_from(&t.fixer, &t.verifier, "left behind").unwrap();
    t.daemon.archive(&t.fixer).await.unwrap();
    assert_eq!(t.daemon.notify_from(&t.fixer, &t.lead, "lead: back to it").unwrap(), None);
    tokio::time::sleep(Duration::from_millis(200)).await;
    idle(&t.daemon, &t.fixer).await;
    assert!(said(&t).contains("lead: back to it"), "{}", said(&t));
}

#[tokio::test]
async fn a_message_held_says_why() {
    let t = team("held-why").await;
    cross(&t).await;
    let why = t.daemon.notify_from(&t.fixer, &t.verifier, "once more").unwrap().expect("held");
    assert!(why.contains("verifier") && why.contains("writes to it"), "{why}");
    t.daemon.pause(std::slice::from_ref(&t.fixer), Duration::from_millis(10)).await;
    let why = t.daemon.notify_from(&t.fixer, &t.lead, "lead").unwrap().expect("held while paused");
    assert!(why.contains("paused"), "{why}");
}

#[tokio::test]
async fn the_users_stop_holds_its_leads_words_too() {
    let t = team("held-stopped").await;
    let fixing = t.daemon.session(&t.fixer).unwrap();
    fixing.change(Change::Status { status: Status::Working, turn: None, error: None });
    t.daemon.queue(&t.fixer, "the user's next words", &[]).unwrap();
    t.daemon.interrupt(&t.fixer).await.unwrap();
    idle(&t.daemon, &t.fixer).await;
    let why = t.daemon.notify_from(&t.fixer, &t.lead, "lead: go on").unwrap().expect("held for the user");
    assert!(why.contains("stopped"), "{why}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!said(&t).contains("lead: go on"), "{}", said(&t));
    assert!(!said(&t).contains("the user's next words"), "{}", said(&t));
}

#[tokio::test]
async fn a_leads_words_lift_the_pairs_hold() {
    let t = team("held-lifted").await;
    cross(&t).await;
    assert!(t.daemon.holding_crossed(&t.fixer));
    t.daemon.notify_from(&t.fixer, &t.lead, "lead: carry on, you two").unwrap();
    assert!(!t.daemon.holding_crossed(&t.fixer), "lifted");
    tokio::time::sleep(Duration::from_millis(200)).await;
    idle(&t.daemon, &t.fixer).await;
    assert_eq!(t.daemon.notify_from(&t.fixer, &t.verifier, "after the lead").unwrap(), None, "the count starts again");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(said(&t).contains("after the lead"), "{}", said(&t));
}

#[tokio::test]
async fn a_task_and_the_one_it_waits_on_are_held_at_a_higher_ceiling_and_its_lead_told() {
    let t = team("held-ceiling").await;
    let fixing = t.daemon.session(&t.fixer).unwrap();
    turn(&fixing, 1, "fix it", "Fix pushed.\n\n[zero: waiting on verifier]").await;
    for n in 0..40 {
        t.daemon.notify_from(&t.fixer, &t.verifier, &format!("round {n}")).unwrap();
    }
    assert!(!t.daemon.holding_crossed(&t.fixer), "forty go");
    let why = t.daemon.notify_from(&t.fixer, &t.verifier, "round 40").unwrap().expect("past the ceiling");
    assert!(why.contains("40"), "{why}");
    t.daemon.notify_from(&t.fixer, &t.verifier, "round 41").unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let pending = std::fs::read_to_string(t.daemon.home().join("sessions").join(&t.lead).join("pending.json")).unwrap_or_default();
    let told = said(&t).matches("wrote to each other 40 times").count() + pending.matches("wrote to each other 40 times").count();
    assert_eq!(told, 1, "its lead hears it once: {} {pending}", said(&t));
    // Its lead's word lets them carry on.
    t.daemon.notify_from(&t.fixer, &t.lead, "lead: one more round").unwrap();
    assert!(!t.daemon.holding_crossed(&t.fixer));
}

#[tokio::test]
async fn a_top_task_past_the_ceiling_tells_the_user() {
    let home = temp_dir("held-ceiling-top");
    let sent = Arc::new(Mutex::new(String::new()));
    let daemon = Daemon::open(&home.join("zerod"), listening(sent.clone())).unwrap();
    let start = |label: &str| {
        let options = Options { cwd: Some(home.to_str().unwrap().into()), label: Some(label.into()), ..Default::default() };
        daemon.start(Provider::Claude, "hi", options).unwrap()
    };
    let (waiter, other) = (start("waiter"), start("other"));
    tokio::time::sleep(Duration::from_millis(100)).await;
    idle(&daemon, &other).await;
    turn(&daemon.session(&waiter).unwrap(), 1, "hi", "Asked.\n\n[zero: waiting on other]").await;
    for n in 0..41 {
        daemon.notify_from(&waiter, &other, &format!("round {n}")).unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    let noted = daemon
        .get(&waiter)
        .unwrap()
        .items
        .iter()
        .any(|i| matches!(&i.kind, zerod::model::ItemKind::Notice { text, .. } if text.contains("40 times")));
    assert!(noted, "said in its conversation, for the user");
}

#[tokio::test]
async fn a_worker_waiting_on_its_lead_isnt_woken_by_its_turns() {
    // Its lead writes to it with zero send: the lead's turn ending is no news to it, or the two would ping-pong.
    let t = team("wait-lead").await;
    let (fixing, leading) = (t.daemon.session(&t.fixer).unwrap(), t.daemon.session(&t.lead).unwrap());
    turn(&fixing, 1, "fix it", &format!("Asked my lead.\n\n[zero: waiting on {}]", t.lead)).await;
    turn(&leading, 1, "go on", "Looked at the worker's question.\n\n[zero: waiting]").await;
    assert!(!said(&t).contains("which you wait on"), "{}", said(&t));
}
