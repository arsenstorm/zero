//! Runtime processes: started in the session's folder with a clean environment, their output read as the
//! session's input, their errors kept in a file, and ended by `stop`.

mod common;

use common::{temp_dir, until};
use tokio::sync::broadcast;
use zerod::model::{Conversation, Provider, Status};
use zerod::process;
use zerod::session::Session;

/// A stand-in runtime: names the thread after what it can see of its environment, then waits on its input.
fn script(body: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), body.into()]
}

#[tokio::test]
async fn a_runtime_runs_in_the_sessions_folder_with_its_own_name_for_zero() {
    let dir = temp_dir("process-env");
    let cwd = dir.canonicalize().unwrap();
    let (events, _) = broadcast::channel(16);
    let session = Session::new(Conversation::new("s1", Provider::Codex, cwd.to_str().unwrap()), None, events).unwrap();
    let body = r#"printf '{"method":"thread/name/updated","params":{"threadName":"%s %s"}}\n' "$ZERO_SESSION/$ZERO_AGENT/$ZERO_MANAGED" "$(pwd -P)"; cat >/dev/null"#;
    session.attach(process::spawn(&script(body), &cwd, "s1", None).unwrap());
    let named = until(&session, |c| c.title.is_some()).await;
    assert_eq!(named.title.unwrap(), format!("s1/zerod-s1/0 {}", cwd.display()),
        "the session's own name for its zero calls; Zero's plugin stands down, since zerod answers and brings the rules");
}

#[test]
fn a_runtime_gets_the_login_environment_but_not_who_started_zero() {
    let login = [("HOME", "/Users/u"), ("CLIPROXY_API_KEY", "k"), ("PATH", "/opt/x/bin"), ("SOLO_PROCESS_ID", "7"), ("CLAUDECODE", "1"),
                 ("CLAUDE_CODE_ENTRYPOINT", "cli"), ("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "9"), ("ZERO_AGENT", "solo-7"), ("CODEX_THREAD_ID", "t")];
    let env: std::collections::HashMap<String, String> = process::environment(login.iter().map(|(k, v)| (k.to_string(), v.to_string())), "s1").into_iter().collect();
    // As Codex gets it when run by hand: a provider's own settings (here a key for a custom model provider) come along.
    assert_eq!((env["HOME"].as_str(), env["CLIPROXY_API_KEY"].as_str(), env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"].as_str()), ("/Users/u", "k", "9"));
    // Whatever started zerod (Solo, a Claude Code session, Codex) isn't the agent's parent: it isn't told it's nested in one.
    for gone in ["SOLO_PROCESS_ID", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CODEX_THREAD_ID"] { assert!(!env.contains_key(gone), "{gone}") }
    assert_eq!((env["ZERO_AGENT"].as_str(), env["ZERO_SESSION"].as_str(), env["TERM"].as_str()), ("zerod-s1", "s1", "dumb"));
    assert_eq!(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin", "the login shell builds the PATH from the user's profile");
}

#[tokio::test]
async fn stopping_ends_the_process_and_the_session_goes_offline() {
    let dir = temp_dir("process-stop");
    let (events, _) = broadcast::channel(16);
    let session = Session::new(Conversation::new("s1", Provider::Codex, dir.to_str().unwrap()), None, events).unwrap();
    session.attach(process::spawn(&script("sleep 30"), &dir, "s1", None).unwrap());
    session.stop();
    until(&session, |c| c.status == Status::Offline).await;
}

#[tokio::test]
async fn stopping_ends_everything_the_runtime_started_too() {
    // As the login shell runs Claude Code, and Claude Code its MCP servers: children that keep its output open, so the
    // session would never see it end if only the first process were stopped.
    let dir = temp_dir("process-tree");
    let (events, _) = broadcast::channel(16);
    let session = Session::new(Conversation::new("s1", Provider::Codex, dir.to_str().unwrap()), None, events).unwrap();
    session.attach(process::spawn(&script("sleep 30 & sleep 30 & wait"), &dir, "s1", None).unwrap());
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    session.stop();
    until(&session, |c| c.status == Status::Offline).await;
}

#[tokio::test]
async fn what_the_runtime_prints_as_errors_is_kept() {
    let dir = temp_dir("process-stderr");
    let log = dir.join("stderr.log");
    let (events, _) = broadcast::channel(16);
    let session = Session::new(Conversation::new("s1", Provider::Codex, dir.to_str().unwrap()), None, events).unwrap();
    session.attach(process::spawn(&script("echo 'no auth' >&2"), &dir, "s1", Some(&log)).unwrap());
    until(&session, |c| c.status == Status::Offline).await;
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "no auth\n");
}

#[test]
fn every_runtime_starts_through_the_login_shell_so_its_path_is_arsens() {
    for provider in [Provider::Codex, Provider::Claude, Provider::Opencode] {
        let argv = provider.command(&Conversation::new("s1", provider, "/"), false, None, None);
        assert_eq!(argv[..4], ["/bin/zsh", "-lic", "exec \"$@\"", "zsh"]);
    }
    assert_eq!(Provider::Codex.command(&Conversation::new("s1", Provider::Codex, "/"), false, None, None)[4..], ["codex", "app-server"]);
}

#[test]
fn two_daemons_started_at_once_on_one_home_leave_one_running() {
    let dir = temp_dir("process-lock");
    let start = |socket: &str| std::process::Command::new(env!("CARGO_BIN_EXE_zerod"))
        .args(["--home", dir.join("data").to_str().unwrap(), "--socket", dir.join(socket).to_str().unwrap()])
        .stderr(std::process::Stdio::piped()).spawn().unwrap();
    let mut both = [start("a.sock"), start("b.sock")];
    let mut ended = None;
    for _ in 0..500 {
        ended = both.iter_mut().position(|d| d.try_wait().unwrap().is_some());
        if ended.is_some() { break }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let ended = ended.expect("one of them left");
    let mut said = String::new();
    std::io::Read::read_to_string(&mut both[ended].stderr.take().unwrap(), &mut said).unwrap();
    assert!(said.contains("another zerod has"), "{said}");
    std::thread::sleep(std::time::Duration::from_millis(100));
    let other = &mut both[1 - ended];
    assert!(other.try_wait().unwrap().is_none(), "the other keeps running");
    other.kill().unwrap();
}
