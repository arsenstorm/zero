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
async fn a_runtime_runs_in_the_sessions_folder_with_only_what_zero_gives_it() {
    let dir = temp_dir("process-env");
    let cwd = dir.canonicalize().unwrap();
    let (events, _) = broadcast::channel(16);
    let session = Session::new(Conversation::new("s1", Provider::Codex, cwd.to_str().unwrap()), None, events).unwrap();
    // Cargo sets CARGO_PKG_NAME for this test; the runtime mustn't inherit the daemon's environment.
    let body = r#"printf '{"method":"thread/name/updated","params":{"threadName":"%s %s %s"}}\n' "$ZERO_SESSION/$ZERO_AGENT/$ZERO_MANAGED" "${CARGO_PKG_NAME:-clean}" "$(pwd -P)"; cat >/dev/null"#;
    session.attach(process::spawn(&script(body), &cwd, "s1", None).unwrap());
    let named = until(&session, |c| c.title.is_some()).await;
    assert_eq!(named.title.unwrap(), format!("s1/zerod-s1/0 clean {}", cwd.display()),
        "the session's own name for its zero calls; Zero's plugin stands down, since zerod answers and brings the rules");
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
