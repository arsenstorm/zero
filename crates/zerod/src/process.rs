//! Starting a runtime's process: in the session's folder, through the user's login shell so their PATH applies (as
//! zero-host does for terminals), with the login environment zerod has from launchd, as the provider's CLI has when
//! run by hand (so its own settings, a custom model provider's key say, come along; zerod never reads them). Only what
//! would tell the agent it runs inside whatever started zerod is left out.

use std::path::Path;
use std::process::Stdio;

use tokio::process::Command;

use crate::session::Transport;

/// What another agent or terminal sets for the processes it runs: an agent inheriting it would think it is nested in
/// Claude Code (and refuse to start), speak to Zero as Solo's process, or take a Codex sandbox for its own.
const LEFT_OUT: [&str; 11] = ["SOLO_PROCESS_ID", "SOLO_PROJECT_ID", "REX_BLOCK", "REX_SESSION", "ZERO_HOST_TERMINAL", "HF_SESSION_ID",
                              "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CODEX_THREAD_ID", "CODEX_SANDBOX"];

/// Variables for one session's processes alone (its MCP servers' values, for Claude to expand): set by zerod before
/// it starts the session's CLI, by session.
pub static SESSION_ENV: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, Variables>>> =
    std::sync::LazyLock::new(Default::default);

/// Names and values, as an environment has them.
pub type Variables = Vec<(String, String)>;

/// The environment a session's processes get: `login`, less what's left out, with Zero's own variables for the session.
pub fn environment(login: impl Iterator<Item = (String, String)>, id: &str) -> Vec<(String, String)> {
    let ours = |key: &str| key == "PATH" || key == "TERM" || key.starts_with("ZERO_");
    let mut env: Vec<(String, String)> = login.filter(|(key, _)| !LEFT_OUT.contains(&key.as_str()) && !ours(key)).collect();
    env.extend([
        ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin".to_string()),
        ("TERM", "dumb".to_string()),
        ("ZERO_SESSION", id.to_string()),
        // The name its `zero` calls go by, the same the inbox shows its approvals under.
        ("ZERO_AGENT", format!("zerod-{id}")),
        // Zero's Claude Code plugin brings permission prompts to the inbox through hooks; zerod answers them itself.
        ("ZERO_MANAGED", "0".to_string()),
    ].map(|(k, v)| (k.to_string(), v)));
    env.extend(SESSION_ENV.lock().unwrap().get(id).cloned().unwrap_or_default());
    env
}

/// Runs `command` to its end through the same login shell and environment as the session's agent, in `cwd`: its exit
/// code (None if it was killed) and the end of what it printed, stdout and stderr together.
pub async fn run(command: &str, cwd: &Path, id: &str) -> (Option<i32>, String) {
    let mut shell = Command::new("/bin/zsh");
    shell.args(["-lic", command]).current_dir(cwd).env_clear().envs(environment(std::env::vars(), id)).stdin(Stdio::null());
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
    // A group of its own, so stopping it stops what it started too (session.rs): the login shell may run the CLI as a
    // child rather than become it, and the CLI runs MCP servers, all holding its output open.
    command.args(arguments).current_dir(cwd).env_clear().envs(environment(std::env::vars(), id)).process_group(0)
        .stdin(Stdio::piped()).stdout(Stdio::piped());
    match stderr {
        Some(path) => { command.stderr(std::fs::OpenOptions::new().create(true).append(true).open(path)?); }
        None => { command.stderr(Stdio::null()); }
    }
    let mut child = command.spawn()?;
    let (Some(input), Some(output)) = (child.stdin.take(), child.stdout.take()) else { return Err(std::io::Error::other("no stdio")) };
    Ok(Transport::new(output, input).with_child(child))
}

/// This process becomes the zerod now on disk (a new build), with the same arguments. Its files close as it does,
/// which ends the agents' processes: their turns are paused first (Daemon::pause_for_restart).
pub fn replace_self() -> ! {
    use std::os::unix::process::CommandExt;
    let exe = std::env::current_exe().unwrap_or_else(|_| "zerod".into());
    let error = std::process::Command::new(&exe).args(std::env::args_os().skip(1)).exec();
    eprintln!("zerod: couldn't restart as {}: {error}", exe.display());
    std::process::exit(1)
}
