//! zerod as launchd's LaunchAgent (`--launchd`): it logs beside its home, waits for a zerod that's on its way out to
//! let go of the home, and a fresh restart ends so that launchd starts it again.

use std::io::Write;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::common::temp_dir;

fn zerod(dir: &std::path::Path, launchd: bool) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_zerod"));
    if launchd {
        command.arg("--launchd");
    }
    command
        .args(["--home", dir.join("data").to_str().unwrap(), "--socket", dir.join("zerod.sock").to_str().unwrap()])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

fn until(mut done: impl FnMut() -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(10) {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

fn answers(dir: &std::path::Path) -> bool {
    std::os::unix::net::UnixStream::connect(dir.join("zerod.sock")).is_ok()
}

fn ended(child: &mut Child) -> Option<i32> {
    let mut code = None;
    until(|| {
        code = child.try_wait().unwrap().map(|s| s.code().unwrap_or(-1));
        code.is_some()
    });
    code
}

#[test]
fn under_launchd_zerod_logs_beside_its_home() {
    let dir = temp_dir("launchd-log");
    let mut child = zerod(&dir, true).spawn().unwrap();
    let log = dir.join("zerod.log");
    assert!(until(|| std::fs::read_to_string(&log).is_ok_and(|l| l.contains("listening on"))), "zerod.log has its start");
    child.kill().unwrap();
    child.wait().unwrap();
}

#[test]
fn under_launchd_zerod_waits_for_the_one_leaving_to_let_go_of_the_home() {
    let dir = temp_dir("launchd-lock");
    std::fs::create_dir_all(dir.join("data")).unwrap();
    let held = std::fs::File::create(dir.join("data/zerod.lock")).unwrap();
    held.lock().unwrap();
    let mut child = zerod(&dir, true).spawn().unwrap();
    std::thread::sleep(Duration::from_secs(1));
    assert!(child.try_wait().unwrap().is_none(), "still waiting, not gone");
    drop(held);
    assert!(until(|| answers(&dir)), "serves once the home is free");
    child.kill().unwrap();
    child.wait().unwrap();
}

#[test]
fn a_fresh_restart_of_launchds_zerod_ends_as_a_crash_so_launchd_starts_it_again() {
    let dir = temp_dir("launchd-fresh");
    let mut child = zerod(&dir, true).env("XPC_SERVICE_NAME", zerod::launchd::LABEL).spawn().unwrap();
    assert!(until(|| answers(&dir)));
    let mut socket = std::os::unix::net::UnixStream::connect(dir.join("zerod.sock")).unwrap();
    socket.write_all(b"{\"id\":1,\"op\":\"restart\",\"args\":{\"fresh\":true}}\n").unwrap();
    assert_eq!(ended(&mut child), Some(zerod::launchd::RESTART_EXIT));
}

#[test]
fn a_fresh_restart_of_any_other_zerod_ends_cleanly() {
    let dir = temp_dir("launchd-fresh-other");
    let mut child = zerod(&dir, false).env_remove("XPC_SERVICE_NAME").spawn().unwrap();
    assert!(until(|| answers(&dir)));
    let mut socket = std::os::unix::net::UnixStream::connect(dir.join("zerod.sock")).unwrap();
    socket.write_all(b"{\"id\":1,\"op\":\"restart\",\"args\":{\"fresh\":true}}\n").unwrap();
    assert_eq!(ended(&mut child), Some(0));
}
