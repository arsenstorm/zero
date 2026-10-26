//! Starting a runtime's process: in the session's folder, through Arsen's login shell so his PATH applies (as
//! zero-host does for terminals), with an environment of only what an agent needs, so the daemon's own
//! variables (or those of whatever started it) don't leak into the agent.

use std::path::Path;
use std::process::Stdio;

use tokio::process::Command;

use crate::session::Transport;

/// Kept from the daemon's environment; everything else is left out.
const KEPT: [&str; 6] = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"];

/// Starts `argv` in `cwd` for session `id`, its stderr appended to `stderr` (else discarded).
pub fn spawn(argv: &[String], cwd: &Path, id: &str, stderr: Option<&Path>) -> std::io::Result<Transport> {
    let (program, arguments) = argv.split_first().ok_or_else(|| std::io::Error::other("no command to start"))?;
    let mut command = Command::new(program);
    command.args(arguments).current_dir(cwd).env_clear()
        .envs(std::env::vars().filter(|(key, _)| KEPT.contains(&key.as_str())))
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("TERM", "dumb")
        .env("ZERO_SESSION", id)
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
