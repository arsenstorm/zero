//! A new task's name, from the user's first message: asked of a small model through the task's own CLI, signed in as
//! the task is, with nothing of the user's setup (no settings, hooks, plugins, MCP servers or tools). Zero calls no
//! provider itself. Codex names its own threads (codex.rs), so this is Claude's.

/// The longest a name is; a reply longer than this is a sentence, not a name.
const LONGEST: usize = 60;

/// Claude Code asked for a name, once, on Haiku, the message an argument of its own (never read by a shell).
pub fn command(message: &str) -> Vec<String> {
    let message: String = message.chars().take(2000).collect();
    let prompt = format!("Name this coding task in two to five words, as a short title in sentence case, with no quotes and no \
full stop. Reply with the name alone.\n\nThe task:\n{message}");
    crate::adapter::login_shell(&["claude", "-p", "--model", "haiku", "--setting-sources", "", "--strict-mcp-config",
                                  "--no-session-persistence", "--tools", "", "--disable-slash-commands", &prompt])
}

/// The name in a reply: its first line, without quotes, a "Name:" before it or a full stop after it; none if that
/// isn't a short name.
pub fn clean(reply: &str) -> Option<String> {
    let line = reply.lines().map(str::trim).find(|l| !l.is_empty())?;
    let line = line.strip_prefix("Name:").unwrap_or(line).trim();
    let name = line.trim_matches(|c| matches!(c, '"' | '\'' | '`' | '*' | '“' | '”')).trim_end_matches('.').trim();
    (!name.is_empty() && name.chars().count() <= LONGEST && name.split_whitespace().count() <= 8).then(|| name.to_string())
}

/// The name for session `id`'s task, asked in its own environment (its sign-in); none if Claude didn't give one in
/// time.
pub async fn name(message: &str, cwd: &str, id: &str) -> Option<String> {
    let argv = command(message);
    let mut claude = tokio::process::Command::new(&argv[0]);
    claude.args(&argv[1..]).current_dir(cwd).env_clear().envs(crate::process::environment(std::env::vars(), id))
        .stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null()).kill_on_drop(true);
    let output = tokio::time::timeout(std::time::Duration::from_secs(60), claude.output()).await.ok()?.ok()?;
    if !output.status.success() { return None }
    clean(&String::from_utf8_lossy(&output.stdout))
}
