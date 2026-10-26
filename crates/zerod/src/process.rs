//! Starting a runtime's process: in the session's folder, through Arsen's login shell so his PATH applies (as
//! zero-host does for terminals), with an environment of only what an agent needs, so the daemon's own
//! variables (or those of whatever started it) don't leak into the agent.

use std::path::Path;
use std::process::Stdio;

use tokio::process::Command;

use crate::session::Transport;

/// Kept from the daemon's environment; everything else is left out.
const KEPT: [&str; 6] = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"];

/// Runs `command` to its end through the same login shell and environment as the session's agent, in `cwd`: its exit
/// code (None if it was killed) and the end of what it printed, stdout and stderr together.
pub async fn run(command: &str, cwd: &Path, id: &str) -> (Option<i32>, String) {
    let mut shell = Command::new("/bin/zsh");
    shell.args(["-lic", command]).current_dir(cwd).env_clear()
        .envs(std::env::vars().filter(|(key, _)| KEPT.contains(&key.as_str())))
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin").env("TERM", "dumb").env("ZERO_SESSION", id)
        .stdin(Stdio::null());
    match shell.output().await {
        Ok(output) => {
            let printed = String::from_utf8_lossy(&output.stdout).to_string() + &String::from_utf8_lossy(&output.stderr);
            let tail: String = printed.chars().rev().take(2000).collect::<Vec<_>>().into_iter().rev().collect();
            (output.status.code(), tail.trim().to_string())
        }
        Err(error) => (None, format!("couldn't run it: {error}")),
    }
}

/// Starts `argv` in `cwd` for session `id`, its stderr appended to `stderr` (else discarded).
pub fn spawn(argv: &[String], cwd: &Path, id: &str, stderr: Option<&Path>) -> std::io::Result<Transport> {
    let (program, arguments) = argv.split_first().ok_or_else(|| std::io::Error::other("no command to start"))?;
    let mut command = Command::new(program);
    command.args(arguments).current_dir(cwd).env_clear()
        .envs(std::env::vars().filter(|(key, _)| KEPT.contains(&key.as_str())))
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("TERM", "dumb")
        .env("ZERO_SESSION", id)
        // The name its `zero` calls go by, the same the inbox shows its approvals under.
        .env("ZERO_AGENT", format!("zerod-{id}"))
        // Zero's Claude Code plugin brings permission prompts to the inbox through hooks; zerod answers them itself.
        .env("ZERO_MANAGED", "0")
        .stdin(Stdio::piped()).stdout(Stdio::piped());
    match stderr {
        Some(path) => { command.stderr(std::fs::OpenOptions::new().create(true).append(true).open(path)?); }
        None => { command.stderr(Stdio::null()); }
    }
    let mut child = command.spawn()?;
    let (Some(input), Some(output)) = (child.stdin.take(), child.stdout.take()) else { return Err(std::io::Error::other("no stdio")) };
    Ok(Transport::new(output, input).with_child(child))
}
