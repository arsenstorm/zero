//! Tasks working together: one reaches another by its name, the user introduces two so each knows the other, and two
//! that keep writing to each other without the user are held until the user says.

use std::sync::Arc;
use std::time::Duration;

use crate::common::temp_dir;
use crate::endings::listening;
use zerod::daemon::{Daemon, Options};
use zerod::model::{Change, Provider, Status};

async fn two(name: &str) -> (Arc<Daemon>, String, String, Arc<std::sync::Mutex<String>>) {
    let home = temp_dir(name);
    let sent = Arc::new(std::sync::Mutex::new(String::new()));
    let daemon = Daemon::open(&home.join("zerod"), listening(sent.clone())).unwrap();
    let start = |label: &str| daemon.start(Provider::Claude, "hi", Options { cwd: Some(home.to_str().unwrap().into()), label: Some(label.into()), ..Default::default() }).unwrap();
    let (zero, dashboard) = (start("Zero"), start("Server status dashboard"));
    tokio::time::sleep(Duration::from_millis(100)).await;
    for id in [&zero, &dashboard] { daemon.session(id).unwrap().change(Change::Status { status: Status::Idle, turn: None, error: None }) }
    (daemon, zero, dashboard, sent)
}

#[tokio::test]
async fn a_task_is_reached_by_its_name_when_only_one_has_it() {
    let (daemon, zero, dashboard, _) = two("coordination-names").await;
    assert_eq!(daemon.resolve(&zero).unwrap(), zero, "its id, as ever");
    assert_eq!(daemon.resolve("zero").unwrap(), zero, "its name, whatever the case");
    assert_eq!(daemon.resolve("Server status dashboard").unwrap(), dashboard);
    assert!(daemon.resolve("Nothing like it").is_err());
    daemon.label(&dashboard, Some("Zero"), None).unwrap();
    let both = daemon.resolve("Zero").unwrap_err();
    assert!(both.contains(&zero) && both.contains(&dashboard), "two of that name: its id, then: {both}");
}

#[tokio::test]
async fn introducing_two_tasks_tells_each_how_to_reach_the_other() {
    let (daemon, zero, dashboard, sent) = two("coordination-introduce").await;
    daemon.introduce(&zero, &dashboard).unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let told = sent.lock().unwrap().clone();
    assert!(told.contains("Server status dashboard") && told.contains(&format!("zero send {dashboard}")), "{told}");
    assert!(told.contains(&format!("zero send {zero}")), "both ways: {told}");
    assert!(daemon.introduce(&zero, &zero).is_err(), "not to itself");
}

#[tokio::test]
async fn two_tasks_writing_to_each_other_without_the_user_are_held_after_ten() {
    let (daemon, zero, dashboard, _) = two("coordination-guard").await;
    for n in 0..10 {
        let (to, from) = if n % 2 == 0 { (&zero, &dashboard) } else { (&dashboard, &zero) };
        daemon.notify_from(to, from, &format!("message {n}")).unwrap();
        assert!(!daemon.holding_crossed(to), "message {n} goes");
    }
    daemon.notify_from(&zero, &dashboard, "message 10").unwrap();
    assert!(daemon.holding_crossed(&zero), "eleven without the user: held for them");
    tokio::time::sleep(Duration::from_millis(200)).await;
    let notices = daemon.get(&zero).unwrap().items.iter().any(|i| matches!(&i.kind, zerod::model::ItemKind::Notice { text, .. } if text.contains("Server status dashboard")));
    assert!(notices, "said where it happens, naming the other task");
    // The user writing to it lets them carry on.
    daemon.queue(&zero, "carry on, you two", &[]).unwrap();
    assert!(!daemon.holding_crossed(&zero));
    daemon.notify_from(&zero, &dashboard, "message 11").unwrap();
    assert!(!daemon.holding_crossed(&zero), "the count starts again");
}
