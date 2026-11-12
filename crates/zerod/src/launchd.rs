//! zerod as the LaunchAgent Zero.app registers (Contents/Library/LaunchAgents): launchd starts it at login, outside any
//! caller's process tree, and starts it again after a crash (KeepAlive with SuccessfulExit false). Not socket
//! activated: a plist in the bundle can't name a socket in the user's home, so zerod binds its own as it always has.

use std::path::Path;
use std::process::{Command, Stdio};

pub const LABEL: &str = "com.arsen.zero.zerod";

/// The exit that has launchd start a fresh zerod: any but 0, which KeepAlive leaves down.
pub const RESTART_EXIT: i32 = 75;

unsafe extern "C" {
    safe fn getuid() -> u32;
}

/// Whether this zerod is the LaunchAgent's: launchd names each job's processes after its label.
pub fn is_ours() -> bool {
    std::env::var("XPC_SERVICE_NAME").is_ok_and(|name| name == LABEL)
}

fn job() -> String {
    format!("gui/{}/{LABEL}", getuid())
}

fn launchctl(args: &[&str]) -> bool {
    Command::new("/bin/launchctl")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Whether the app registered the LaunchAgent and the user left it on in Login Items.
pub fn loaded() -> bool {
    launchctl(&["print", &job()])
}

/// Starts the LaunchAgent's zerod if it isn't running; false if there's none to start.
pub fn kickstart() -> bool {
    launchctl(&["kickstart", &job()])
}

/// The user's own zerod (~/.zero/zerod), the only one launchd starts: never a test's.
pub fn is_default_home(home: &Path) -> bool {
    std::env::var_os("HOME").is_some_and(|h| home == Path::new(&h).join(".zero/zerod"))
}

/// A zerod the app or a browser started while the LaunchAgent is there: on its next restart it leaves for launchd's.
pub fn should_hand_over(home: &Path) -> bool {
    !is_ours() && is_default_home(home) && loaded()
}

/// Out, for a new process to take over: launchd's zerod ends as a crash so launchd starts it again; any other has
/// launchd start its own (which waits for this one's lock), else the app starts one, as before.
pub fn leave_for_fresh(home: &Path) -> ! {
    if is_ours() {
        std::process::exit(RESTART_EXIT)
    }
    if is_default_home(home) && loaded() && !kickstart() {
        eprintln!("zerod: couldn't start the LaunchAgent's zerod; Zero starts one when it opens");
    }
    std::process::exit(0)
}
