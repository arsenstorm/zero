//! Commands that look stuck: what they're expected to take (the agent's word, their timeout, how long they took
//! before, a default), hung (no output, no CPU) past that, shown with what's known, and stopped (only their own
//! processes) so the agent carries on.

use std::time::Duration;

use crate::common::temp_dir;
use serde_json::json;
use tokio::io::AsyncWriteExt;
use tokio::sync::broadcast;
use zerod::model::{Attention, Conversation, Provider};
use zerod::session::Session;
use zerod::stuck::{Expected, History, Seen, Settings, When, judge, key, parse_span};

#[test]
fn a_command_is_known_by_its_program_and_stable_words() {
    assert_eq!(key("cargo test -p zerod 2>&1 | tail -20"), "cargo test -p zerod");
    assert_eq!(key("cd crates/zerod && RUST_LOG=debug cargo build --release"), "cargo build --release");
    assert_eq!(key("timeout 60 npm test"), "npm test");
    assert_eq!(key("git commit -m \"fix: it\""), "git commit -m");
    assert_eq!(key("swift test --package-path apps/macos"), "swift test --package-path");
    assert_eq!(key("./bin/rails test test/models/user_test.rb"), "bin/rails test");
    assert_eq!(key("ls /tmp"), "ls");
}

fn seen(elapsed: u64, idle: u64) -> Seen {
    Seen { elapsed: Duration::from_secs(elapsed), idle: Duration::from_secs(idle), input: None }
}

#[test]
fn stuck_is_past_its_usual_time_and_hung() {
    let settings = Settings::default();
    let usual = Expected::Usual { median: 40, p90: 70 };
    let stuck = judge("cargo test 2>&1", &seen(7 * 60, 6 * 60), &usual, &settings).expect("7 min, quiet for 6, usually 40 s");
    assert_eq!(stuck.reason, "Running `cargo test` for 7 min (usually 40 s) · looks stuck");
    assert!(stuck.note.starts_with("Zero stopped `cargo test`: no output and no CPU for 6 min, past its usual 40 s"), "{}", stuck.note);
    assert_eq!(judge("cargo test", &seen(7 * 60, 60), &usual, &settings), None, "busy a minute ago: slow, not stuck");
    assert_eq!(judge("cargo test", &seen(200, 200), &usual, &settings), None, "3× its p90 is 3.5 min: not past it yet, however quiet");
    let quick = Expected::Usual { median: 1, p90: 2 };
    assert_eq!(judge("git status", &seen(170, 170), &quick, &settings), None, "never before the floor (3 min)");
    assert!(judge("git status", &seen(190, 190), &quick, &settings).is_some());
    assert_eq!(judge("zero wait 01a1", &seen(3600, 3600), &usual, &settings), None, "Zero's own commands wait by design");
    let never = Settings { when: When::Never, ..Settings::default() };
    assert_eq!(judge("cargo test", &seen(3600, 3600), &usual, &never), None, "not looked at");
}

#[test]
fn waiting_for_input_is_stuck_soon() {
    let mut paged = seen(45, 40);
    paged.input = Some("less".into());
    let stuck = judge("git log", &paged, &zerod::stuck::default_for("git log"), &Settings::default()).unwrap();
    assert_eq!(stuck.reason, "Running `git log` for 45 s · waiting for input (less)");
    assert!(stuck.note.contains("--no-pager"));
}

#[test]
fn what_the_agent_said_and_its_timeout_are_shown() {
    let settings = Settings::default();
    let said = Expected::Said { seconds: 120, what: "the full suite".into() };
    let stuck = judge("make test", &seen(400, 400), &said, &settings).unwrap();
    assert_eq!(stuck.reason, "Running `make test` for 6 min (past the 2 min the agent expected for the full suite) · looks stuck");
    assert!(stuck.note.contains("6 min, past the 2 min the agent expected for the full suite;"), "{}", stuck.note);
    assert_eq!(judge("make test", &seen(400, 400), &Expected::Timeout(600), &settings), None, "within 3× its 10 min timeout");
}

#[test]
fn a_command_the_agent_announced_is_left_alone_while_within_what_it_said() {
    let settings = Settings { when: When::Stop, ..Settings::default() };
    let said = Expected::Said { seconds: 40 * 60, what: "the migration".into() };
    let mut asking = seen(30 * 60, 30 * 60);
    asking.input = Some("less".into());
    assert_eq!(judge("bin/rails db:migrate", &seen(30 * 60, 30 * 60), &said, &settings), None, "quiet, but within its 40 min");
    assert_eq!(judge("bin/rails db:migrate", &asking, &said, &settings), None, "not even waiting for input");
    assert!(judge("bin/rails db:migrate", &seen(130 * 60, 60 * 60), &said, &settings).is_some(), "a hung one is still caught past it");
}

#[test]
fn an_old_tasks_keep_commands_is_ignored() {
    let mut saved = serde_json::to_value(Conversation::new("s", Provider::Claude, "/work")).unwrap();
    saved["keepCommands"] = json!(true);
    let loaded: Conversation = serde_json::from_value(saved).unwrap();
    assert!(serde_json::to_value(&loaded).unwrap().get("keepCommands").is_none());
}

#[test]
fn settings_say_what_zero_may_stop() {
    let stop = Settings { when: When::Stop, never: vec!["migrate".into()], ..Settings::default() };
    assert!(stop.may_stop("cargo test"));
    assert!(!stop.may_stop("bin/rails db:migrate"), "an exception");
    assert!(!Settings::default().may_stop("cargo test"), "by default Zero tells the user and stops nothing");
    let given: Settings = serde_json::from_value(json!({"when": "stop"})).unwrap();
    assert_eq!((given.when, given.hung_minutes, given.times), (When::Stop, 3.0, 3.0), "what isn't set is the default");
}

#[test]
fn durations_read_as_given() {
    assert_eq!(parse_span("20m"), Some(1200));
    assert_eq!(parse_span("1h30m"), Some(5400));
    assert_eq!(parse_span("90s"), Some(90));
    assert_eq!(parse_span("45"), Some(45));
    assert_eq!(parse_span("soon"), None);
    assert_eq!(parse_span("m"), None);
}

#[test]
fn how_long_a_command_takes_is_learned_per_repo_and_kept() {
    let dir = temp_dir("stuck-history");
    let main = dir.join("repo");
    std::fs::create_dir_all(main.join(".git/worktrees/two")).unwrap();
    let worktree = dir.join("two");
    std::fs::create_dir_all(&worktree).unwrap();
    std::fs::write(worktree.join(".git"), format!("gitdir: {}\n", main.join(".git/worktrees/two").display())).unwrap();
    let path = dir.join("durations.json");
    let mut history = History::open(path.clone());
    for seconds in [30, 40, 50, 40, 200] {
        history.record(&main.join("crates"), "cargo test -p zerod 2>&1 | tail", Duration::from_secs(seconds));
    }
    let usual = Expected::Usual { median: 40, p90: 200 };
    assert_eq!(history.usual(&worktree, "cargo test -p zerod"), Some(usual.clone()), "a worktree shares its repo's history");
    assert_eq!(History::open(path).usual(&main, "cargo test -p zerod"), Some(usual), "kept across restarts");
    assert_eq!(history.usual(&dir.join("elsewhere"), "cargo test -p zerod"), None);
}

/// Lets the paused clock run `minutes` forward, a tick at a time, so the session's watchdog runs on the way.
async fn wait_minutes(minutes: u64) {
    for _ in 0..minutes * 4 {
        tokio::time::sleep(Duration::from_secs(15)).await
    }
}

fn line(v: serde_json::Value) -> String {
    format!("{v}\n")
}

fn started(command: &str, cwd: &str) -> String {
    line(json!({"method": "item/started", "params": {"turnId": "u", "item": {"type": "commandExecution", "id": "c1",
        "command": command, "cwd": cwd, "status": "inProgress", "commandActions": []}}}))
}

#[tokio::test(start_paused = true)]
async fn a_quiet_command_past_its_usual_time_looks_stuck_and_printing_is_not() {
    let cwd = "/stuck-test/learned";
    zerod::stuck::record(std::path::Path::new(cwd), "bin/rails test", Duration::from_secs(40));
    let (events, _) = broadcast::channel(4096);
    let session = Session::new(Conversation::new("s1", Provider::Codex, cwd), None, events).unwrap();
    let (zero_side, runtime_side) = tokio::io::duplex(1 << 16);
    let (read, write) = tokio::io::split(zero_side);
    let (_runtime_read, mut runtime) = tokio::io::split(runtime_side);
    runtime.write_all(line(json!({"method": "turn/started", "params": {"turn": {"id": "u"}}})).as_bytes()).await.unwrap();
    runtime.write_all(started("bin/rails test", cwd).as_bytes()).await.unwrap();
    session.attach(zerod::session::Transport::new(read, write));
    // Printing as it goes for 20 minutes: slow, not stuck, and not the agent's silence either.
    let delta = line(json!({"method": "item/commandExecution/outputDelta", "params": {"turnId": "u", "itemId": "c1", "delta": "."}}));
    for _ in 0..20 {
        runtime.write_all(delta.as_bytes()).await.unwrap();
        wait_minutes(1).await;
    }
    assert_eq!(session.snapshot().stalled, None);
    // Then nothing: hung for 3 minutes, past 3× its usual.
    wait_minutes(1).await;
    assert_eq!(session.snapshot().stalled, None, "quiet for 2 minutes isn't hung yet");
    wait_minutes(2).await;
    let now = session.snapshot();
    let reason = now.stalled.clone().unwrap_or_default();
    assert!(reason.starts_with("Running `bin/rails test` for 2") && reason.ends_with(" min (usually 40 s) · looks stuck"), "{reason}");
    assert_eq!(now.stuck.as_deref(), Some("c1"), "the command it's stuck on, for Stop it");
    assert_eq!(now.attention(), Attention::Stuck);
    let done = json!({"method": "item/completed", "params": {"turnId": "u", "item": {"type": "commandExecution", "id": "c1",
        "command": "bin/rails test", "cwd": cwd, "status": "completed", "exitCode": 0, "commandActions": []}}});
    runtime.write_all(line(done).as_bytes()).await.unwrap();
    wait_minutes(1).await;
    let now = session.snapshot();
    assert_eq!((now.stalled, now.stuck), (None, None));
}

#[tokio::test(start_paused = true)]
async fn the_agents_word_on_how_long_it_takes_counts() {
    let cwd = "/stuck-test/said";
    let (events, _) = broadcast::channel(4096);
    let session = Session::new(Conversation::new("s1", Provider::Codex, cwd), None, events).unwrap();
    let (zero_side, runtime_side) = tokio::io::duplex(1 << 16);
    let (read, write) = tokio::io::split(zero_side);
    let (_runtime_read, mut runtime) = tokio::io::split(runtime_side);
    runtime.write_all(line(json!({"method": "turn/started", "params": {"turn": {"id": "u"}}})).as_bytes()).await.unwrap();
    session.attach(zerod::session::Transport::new(read, write));
    wait_minutes(1).await;
    session.expect(20 * 60, "the full suite");
    runtime.write_all(started("make test", cwd).as_bytes()).await.unwrap();
    wait_minutes(30).await;
    assert_eq!(session.snapshot().stalled, None, "20 minutes said: not stuck at 30");
    wait_minutes(31).await;
    let reason = session.snapshot().stalled.unwrap_or_default();
    assert!(
        reason.starts_with("Running `make test` for 1 h")
            && reason.ends_with("(past the 20 min the agent expected for the full suite) · looks stuck"),
        "{reason}"
    );
}

/// A stand-in Codex: it says a command started, then runs it as a shell of its own would, and stays.
fn cli(command: &str) -> Vec<String> {
    let turn = json!({"method": "turn/started", "params": {"turn": {"id": "u"}}});
    let item = json!({"method": "item/started", "params": {"turnId": "u", "item": {"type": "commandExecution", "id": "c1",
        "command": command, "cwd": "/stuck-test/real", "status": "inProgress", "commandActions": []}}});
    let body = format!("echo '{turn}'; echo '{item}'; /bin/sh -c '{command}; :' & sleep 599 & cat >/dev/null");
    vec!["/bin/sh".into(), "-c".into(), body]
}

/// A process with just these arguments, anywhere: the commands here are this test's own.
fn alive(args: &str) -> bool {
    std::process::Command::new("pgrep").args(["-f", &format!("^{args}$")]).output().is_ok_and(|o| o.status.success())
}

#[tokio::test]
async fn stop_it_ends_the_commands_processes_and_nothing_else() {
    let dir = temp_dir("stuck-stop").canonicalize().unwrap();
    let (events, _) = broadcast::channel(4096);
    let session = Session::new(Conversation::new("s1", Provider::Codex, dir.to_str().unwrap()), None, events).unwrap();
    session.attach(zerod::process::spawn(&cli("sleep 601"), &dir, "s1", None).unwrap());
    for _ in 0..50 {
        if session.running_command() && alive("sleep 601") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(alive("sleep 601") && alive("sleep 599"));
    assert!(session.stop_command("nope").is_err(), "only a command of its own that's running");
    let (command, note) = session.stop_command("c1").expect("its command is running");
    assert_eq!((command.as_str(), note), ("sleep 601", None), "stopped by the user: not stuck, so no note of why");
    for _ in 0..50 {
        if !alive("sleep 601") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(!alive("sleep 601"), "the command is gone");
    assert!(alive("sleep 599"), "what isn't the command stays");
    assert!(session.stop_command("c1").is_err(), "stopped once");
    session.stop();
}
