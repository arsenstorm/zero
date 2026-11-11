//! zerod replacing itself with a new build without losing anyone's work: each turn under way is paused between steps
//! (a command running is waited for, never cut off), noted to carry on, and carried on by the new zerod.

use std::sync::Arc;
use std::time::Duration;

use crate::common::temp_dir;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

/// An agent that stays connected and says nothing: a process behind the session, as a turn under way has.
fn alive() -> Runtime {
    Arc::new(|_, _, _| {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        std::mem::forget(theirs);
        Ok(zerod::session::Transport::new(ours, tokio::io::sink()))
    })
}

fn command(status: ItemStatus) -> Change {
    Change::Item {
        item: Item {
            id: "c1".into(),
            turn: None,
            kind: ItemKind::Command {
                command: "make test".into(),
                cwd: "/".into(),
                output: String::new(),
                exit_code: None,
                duration_ms: None,
                description: String::new(),
            },
            status,
            at: None,
        },
    }
}

#[tokio::test]
async fn a_restart_waits_for_a_running_command_then_pauses_the_turn_to_carry_on() {
    let home = temp_dir("restart");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let working =
        daemon.start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let idle =
        daemon.start(Provider::Claude, "done already", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    // Their processes connect: a session not yet attached is one a restart has nothing to wait for. Waited for, not
    // slept on: a busy CI runner took longer than 100 ms, and the restart went ahead at once.
    for _ in 0..100 {
        if [&working, &idle].iter().all(|id| daemon.session(id).unwrap().is_attached()) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let session = daemon.session(&working).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    session.change(command(ItemStatus::Running));
    daemon.session(&idle).unwrap().change(Change::Status { status: Status::Idle, turn: None, error: None });

    let pausing = tokio::spawn({
        let daemon = daemon.clone();
        async move { daemon.pause_for_restart().await }
    });
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(!pausing.is_finished(), "the command is left to finish");
    // The app can say what Zero waits for meanwhile: this turn's command.
    let status = daemon.restart_status();
    assert_eq!(
        (status["restarting"].as_bool(), status["waiting"][0]["session"].as_str(), status["waiting"][0]["command"].as_str()),
        (Some(true), Some(working.as_str()), Some("make test"))
    );

    session.change(command(ItemStatus::Done));
    let paused = tokio::time::timeout(Duration::from_secs(10), pausing).await.unwrap().unwrap(); // its interrupt goes unanswered here: 5 s
    assert_eq!(paused, std::slice::from_ref(&working), "only what was under way");
    assert_eq!(daemon.restart_status()["waiting"], serde_json::json!([]), "nothing left to wait for");
    // Shown as paused meanwhile, as one the user paused is: not as a task with nothing to say.
    assert!(daemon.is_paused_for_update(&working) && !daemon.is_paused_for_update(&idle));
    let words = std::fs::read_to_string(home.join("zerod/sessions").join(&working).join("pending.json")).unwrap();
    assert!(words.contains("carry on"), "kept for the new zerod to give it: {words}");
    assert!(!home.join("zerod/sessions").join(&idle).join("pending.json").exists());
    // Said in the conversation as it happens, so a turn that stops reads as paused for the update, not stopped.
    assert!(
        daemon
            .get(&working)
            .unwrap()
            .items
            .iter()
            .any(|i| matches!(&i.kind, ItemKind::Notice { text, .. } if text == zerod::daemon::PAUSED_FOR_UPDATE))
    );
}

#[tokio::test]
async fn a_task_between_turns_with_a_run_in_the_background_carries_on_too() {
    // Its turn ended with a test run left going in the background, to wake it when done: a restart ends its process
    // and the run with it, so it's paused and carried on like a turn, told to start again what it still needs.
    let home = temp_dir("restart-background");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let waiting =
        daemon.start(Provider::Claude, "verify it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let session = daemon.session(&waiting).unwrap();
    session.change(command(ItemStatus::Running));
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    let pausing = tokio::spawn({
        let daemon = daemon.clone();
        async move { daemon.pause_for_restart().await }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    session.change(command(ItemStatus::Done)); // finished within the wait: the run isn't cut off when it needn't be
    let paused = tokio::time::timeout(Duration::from_secs(10), pausing).await.unwrap().unwrap();
    assert_eq!(paused, std::slice::from_ref(&waiting));
    let words = std::fs::read_to_string(home.join("zerod/sessions").join(&waiting).join("pending.json")).unwrap();
    assert!(words.contains("background"), "told what a restart stops: {words}");
}

#[tokio::test]
async fn a_task_waiting_on_the_user_is_told_its_question_went_with_the_restart() {
    // Its question (the provider's own, open in the chat) doesn't outlive the process: the new one is told so, not
    // that its turn was paused mid-step, which reads as nonsense to an agent that was only waiting.
    let home = temp_dir("restart-waiting");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let waiting =
        daemon.start(Provider::Claude, "plan it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    daemon.session(&waiting).unwrap().change(Change::Status { status: Status::Waiting, turn: Some("t1".into()), error: None });
    let paused = tokio::time::timeout(Duration::from_secs(10), daemon.pause_for_restart()).await.unwrap();
    assert_eq!(paused, std::slice::from_ref(&waiting));
    let words = std::fs::read_to_string(home.join("zerod/sessions").join(&waiting).join("pending.json")).unwrap();
    assert!(words.contains("waiting on the user") && words.contains("again"), "{words}");
    assert!(!words.contains("paused between steps"), "{words}");
}

#[tokio::test]
async fn a_restart_doesnt_wait_on_a_session_closed_while_its_command_ran() {
    // Closed (archived) mid-command, the session's last item still says a command runs: the pause moves on at once
    // rather than waiting out the whole allowance with everything else already paused.
    let home = temp_dir("restart-closed");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let working =
        daemon.start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let session = daemon.session(&working).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    session.change(command(ItemStatus::Running));
    drop(session);
    let pausing = tokio::spawn({
        let daemon = daemon.clone();
        async move { daemon.pause_for_restart().await }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    daemon.archive(&working).await.unwrap();
    let paused =
        tokio::time::timeout(Duration::from_secs(10), pausing).await.expect("the pause moved on once the session was closed").unwrap();
    assert!(paused.is_empty() || paused == [working.clone()]);
}

#[tokio::test]
async fn after_a_restart_only_what_it_paused_carries_on() {
    let home = temp_dir("restart-carry");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let paused =
        daemon.start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let parked = daemon.start(Provider::Claude, "parked", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await; // their processes connect
    daemon.session(&paused).unwrap().change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    daemon.session(&parked).unwrap().change(Change::Status { status: Status::Offline, turn: None, error: None });
    // Words left for a parked task (a note for when it's next resumed) aren't a reason to resume it.
    std::fs::write(home.join("zerod/sessions").join(&parked).join("pending.json"), r#"["for when you're back"]"#).unwrap();
    assert_eq!(daemon.pause_for_restart().await, std::slice::from_ref(&paused));
    drop(daemon);

    let again = Daemon::open(&home.join("zerod"), alive()).unwrap();
    assert_eq!(again.carry_on(), std::slice::from_ref(&paused), "the paused turn, not the parked task with words waiting");
    assert!(again.carry_on().is_empty(), "once");
}

#[tokio::test]
async fn an_offline_session_whose_status_still_says_working_isnt_paused() {
    let home = temp_dir("restart-stale");
    // Its process gone at once, as one that ended is.
    let gone: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home.join("zerod"), gone).unwrap();
    let id = daemon
        .start(Provider::Claude, "old", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    let session = daemon.session(&id).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    assert!(daemon.pause_for_restart().await.is_empty(), "no process, no turn to pause");
}

#[tokio::test]
async fn a_turn_carried_on_after_a_restart_says_so_in_place_of_interrupted() {
    // The pause interrupts the turn, which the adapter notes as "Interrupted"; the new zerod, carrying it on, makes
    // that line say what happened. A stop the user pressed stays "Interrupted".
    let home = temp_dir("restart-notice");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let session = daemon.session(&id).unwrap();
    session.change(Change::Item {
        item: Item {
            at: None,
            id: "stop".into(),
            turn: None,
            kind: ItemKind::Notice { text: "Interrupted".into(), error: false },
            status: ItemStatus::Done,
        },
    });
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    std::fs::write(home.join("zerod/paused.json"), serde_json::to_vec(std::slice::from_ref(&id)).unwrap()).unwrap();
    drop(session);
    drop(daemon);
    let again = Daemon::open(&home.join("zerod"), alive()).unwrap();
    assert_eq!(again.carry_on(), std::slice::from_ref(&id));
    let notices: Vec<String> = again
        .get(&id)
        .unwrap()
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::Notice { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(notices, [zerod::daemon::CARRIED]);
    // No "Interrupted" noted (the old zerod went before the interrupt's result): the line is added on its own.
    let other = again
        .start(Provider::Claude, "more", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    again.session(&other).unwrap().change(Change::Status { status: Status::Idle, turn: None, error: None });
    std::fs::write(home.join("zerod/paused.json"), serde_json::to_vec(std::slice::from_ref(&other)).unwrap()).unwrap();
    drop(again);
    let third = Daemon::open(&home.join("zerod"), alive()).unwrap();
    assert_eq!(third.carry_on(), std::slice::from_ref(&other));
    assert!(
        third.get(&other).unwrap().items.iter().any(|i| matches!(&i.kind, ItemKind::Notice { text, .. } if text == zerod::daemon::CARRIED))
    );
}

#[tokio::test]
async fn a_worker_paused_for_a_restart_isnt_reported_to_its_lead_as_stopped() {
    let home = temp_dir("restart-report");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let cwd = home.to_str().unwrap();
    let lead = daemon.start(Provider::Claude, "lead it", zerod::daemon::Options { cwd: Some(cwd.into()), ..Default::default() }).unwrap();
    let worker = daemon.spawn(&lead, Provider::Claude, "work", zerod::daemon::Options::default()).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await; // their processes connect
    daemon.session(&lead).unwrap().change(Change::Status { status: Status::Working, turn: Some("l1".into()), error: None });
    let session = daemon.session(&worker).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    tokio::time::sleep(Duration::from_millis(50)).await;
    let pausing = tokio::spawn({
        let daemon = daemon.clone();
        async move { daemon.pause_for_restart().await }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    // The pause ends the worker's turn: interrupted, its process gone.
    session.change(Change::Status { status: Status::Offline, turn: None, error: None });
    let _ = tokio::time::timeout(Duration::from_secs(10), pausing).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let waiting = std::fs::read_to_string(home.join("zerod/sessions").join(&lead).join("pending.json")).unwrap_or_default();
    assert!(!waiting.contains("Worker"), "a turn paused to carry on isn't a worker stopping: {waiting}");
}

#[tokio::test]
async fn a_turn_paused_for_an_update_says_so_once_however_its_agent_notes_the_stop() {
    let home = temp_dir("restart-once");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let session = daemon.session(&id).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    // Two restarts at once (the second asked for before the first had carried it on): told to carry on once.
    let pausing = tokio::spawn({
        let daemon = daemon.clone();
        async move { daemon.pause_for_restart().await }
    });
    let again = tokio::spawn({
        let daemon = daemon.clone();
        async move { daemon.pause_for_restart().await }
    });
    // The agent notes its stop as it always does, a moment after the pause began.
    tokio::time::sleep(Duration::from_millis(300)).await;
    session.change(Change::Item {
        item: Item {
            at: None,
            id: "stop".into(),
            turn: None,
            kind: ItemKind::Notice { text: "Interrupted".into(), error: false },
            status: ItemStatus::Done,
        },
    });
    tokio::time::timeout(Duration::from_secs(15), pausing).await.unwrap().unwrap();
    tokio::time::timeout(Duration::from_secs(15), again).await.unwrap().unwrap();
    let notices: Vec<String> = daemon
        .get(&id)
        .unwrap()
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::Notice { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(notices, [zerod::daemon::PAUSED_FOR_UPDATE], "one line, saying why it stopped");
    let words = std::fs::read_to_string(home.join("zerod/sessions").join(&id).join("pending.json")).unwrap();
    assert_eq!(words.matches("carry on").count(), 1, "{words}");
}

#[test]
fn zeros_carry_on_is_never_shown_as_a_message_of_the_users() {
    let carry = zerod::daemon::CARRY_ON;
    assert_eq!(zerod::core::without_carry_on(&format!("{carry}\n\n{carry}")), None, "twice over is still only Zero's");
    assert_eq!(
        zerod::core::without_carry_on(&format!("{carry}\n\nWorker done.")).as_deref(),
        Some("Worker done."),
        "what came with it stays"
    );
    assert_eq!(zerod::core::without_carry_on("Hello").as_deref(), Some("Hello"));
    // The note under the user's words listing the task's open asks: the agent's, not shown as theirs.
    let withdrew =
        format!("let's talk\n\n{} k3x9qa (\"Which first?\"). Withdraw what the user's words answered.", zerod::daemon::OPEN_ASKS_MARK);
    assert_eq!(zerod::core::without_carry_on(&withdrew).as_deref(), Some("let's talk"));
}

/// A real agent process: answers each line it reads with "echo N"; after the first, a line written in two halves a
/// second apart, so a restart can fall in the middle of it.
fn echoing(home: &std::path::Path, started: Arc<std::sync::atomic::AtomicUsize>) -> Runtime {
    let script = home.join("agent.sh");
    std::fs::write(&script, r#"n=0
while IFS= read -r line; do
  n=$((n+1))
  printf '{"type":"assistant","message":{"id":"m%s","content":[{"type":"text","text":"echo %s"}]}}\n' $n $n
  if [ $n = 1 ]; then printf '{"type":"assistant","message":{"id":"half","content":[{"type":"text","te'; sleep 1; printf 'xt":"split"}]}}\n'; fi
done
"#).unwrap();
    Arc::new(move |conversation: &Conversation, _: &std::path::Path, _: &[String]| {
        started.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        zerod::process::spawn(
            &["/bin/sh".into(), script.to_str().unwrap().into()],
            std::path::Path::new(&conversation.cwd),
            &conversation.id,
            None,
        )
    })
}

async fn says(daemon: &Daemon, id: &str, words: &str) {
    for _ in 0..500 {
        if daemon.get(id).is_some_and(|c| c.items.iter().any(|i| matches!(&i.kind, ItemKind::Agent { text, .. } if text == words))) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("never said {words}: {:?}", daemon.get(id).map(|c| c.items));
}

#[tokio::test]
async fn a_restart_hands_the_agents_running_process_to_the_new_zerod_mid_turn() {
    // The new build takes over the very process: its turn, its background commands and its subagents carry on, and
    // nothing it said across the restart (half a line included) is lost.
    let home = temp_dir("restart-handoff");
    let started = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let old = Daemon::open(&home.join("zerod"), echoing(&home, started.clone())).unwrap();
    let id = old
        .start(Provider::Claude, "build it", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    says(&old, &id, "echo 1").await;
    assert_eq!(old.hand_off().await, vec![id.clone()]);
    assert!(home.join("zerod/handoff.json").exists(), "kept for the new zerod");

    let new = Daemon::open(&home.join("zerod"), echoing(&home, started.clone())).unwrap();
    assert_eq!(new.take_over(), vec![id.clone()]);
    assert!(!home.join("zerod/handoff.json").exists(), "taken once");
    assert_eq!(new.get(&id).unwrap().status, Status::Working, "mid-turn, as it was");
    says(&new, &id, "split").await;
    new.session(&id).unwrap().send(zerod::session::Message::text("again"), zerod::session::ModelChoice::default()).await.unwrap();
    says(&new, &id, "echo 2").await;
    assert_eq!(started.load(std::sync::atomic::Ordering::SeqCst), 1, "never started again");
}

#[tokio::test]
async fn stop_on_a_task_that_reads_busy_with_nothing_running_puts_it_back_to_idle() {
    // A task left reading as working with no turn behind it (a provider that went quiet): Stop doesn't refuse with
    // "nothing is running", it sets the task right.
    let home = temp_dir("stop-nothing");
    let daemon = Daemon::open(&home.join("zerod"), alive()).unwrap();
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    daemon.session(&id).unwrap().change(Change::Status { status: Status::Working, turn: None, error: None });
    tokio::time::timeout(Duration::from_secs(5), daemon.interrupt(&id)).await.unwrap().expect("not refused");
    assert_eq!(daemon.get(&id).unwrap().status, Status::Idle);
}
