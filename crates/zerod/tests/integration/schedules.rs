//! A task waking itself at a time (`zero schedule`): a check due tomorrow morning, a deploy to look at in an hour.
//! Kept on disk, so a restart loses none; told as Zero's word when due, a parked task woken for it; on the board meanwhile.

use std::sync::Arc;
use std::time::Duration;

use crate::common::temp_dir;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

fn alive() -> Runtime {
    Arc::new(|_, _, _| {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        std::mem::forget(theirs);
        Ok(zerod::session::Transport::new(ours, tokio::io::sink()))
    })
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64
}

#[tokio::test]
async fn a_scheduled_wake_is_kept_listed_and_can_be_taken_back() {
    let home = temp_dir("schedules");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(
            Provider::Claude,
            "watch the scan",
            zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() },
        )
        .unwrap();
    let morning = daemon.schedule(&id, now() + 3600, "Check the Image Scan shows no OS packages").unwrap();
    let later = daemon.schedule(&id, now() + 7200, "Look at the deploy").unwrap();
    assert!(daemon.schedule(&id, now() + 60, "  ").is_err(), "a wake says what for");
    assert_eq!(
        daemon.schedules(Some(&id)).iter().map(|s| s.text.as_str()).collect::<Vec<_>>(),
        ["Check the Image Scan shows no OS packages", "Look at the deploy"]
    );
    assert_eq!(daemon.next_wake(&id), Some(morning.at), "the board shows the soonest");
    daemon.unschedule(&morning.id).unwrap();
    // A new zerod has them still.
    drop(daemon);
    let again = Daemon::open(&home.join("zerod"), alive()).unwrap();
    assert_eq!(again.schedules(Some(&id)), [later]);
}

#[tokio::test]
async fn when_its_due_the_task_hears_it_as_zeros_word() {
    let home = temp_dir("schedules-due");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(
            Provider::Claude,
            "watch the scan",
            zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() },
        )
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    daemon.session(&id).unwrap().change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    daemon.schedule(&id, now() + 1, "Check the scan").unwrap();
    tokio::time::sleep(Duration::from_millis(2500)).await;
    let told = std::fs::read_to_string(home.join("zerod/sessions").join(&id).join("pending.json")).unwrap_or_default();
    assert!(told.contains("from: zero") && told.contains("Scheduled: Check the scan"), "{told}");
    assert!(daemon.schedules(Some(&id)).is_empty(), "told once");
}

#[tokio::test]
async fn one_due_while_zero_was_down_is_told_when_its_back_and_says_so() {
    let home = temp_dir("schedules-late");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(
            Provider::Claude,
            "watch the scan",
            zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() },
        )
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    daemon.session(&id).unwrap().change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    daemon.schedule(&id, now() + 3600, "Check the scan").unwrap();
    drop(daemon);
    // Its time came while zerod was down.
    let file = home.join("zerod/schedules.json");
    let kept = std::fs::read_to_string(&file).unwrap();
    let mut list: serde_json::Value = serde_json::from_str(&kept).unwrap();
    list[0]["at"] = serde_json::json!(now() - 600);
    std::fs::write(&file, list.to_string()).unwrap();
    let again = Daemon::open(&home.join("zerod"), alive()).unwrap();

    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(again.schedules(Some(&id)).is_empty(), "told as soon as zerod was back (its parked task woken for it)");
    // What it hears says it's late, and why.
    let late = zerod::schedules::Schedule { id: "x".into(), session: id.clone(), at: now() - 600, text: "Check the scan".into() };
    assert_eq!(late.told(now()), "Scheduled: Check the scan (late: it was due 10 minutes ago, while Zero wasn't running)");
    assert_eq!(zerod::schedules::Schedule { at: now(), ..late }.told(now()), "Scheduled: Check the scan");
}
