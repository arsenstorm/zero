//! What reaching an agent through its terminal takes (Zero's own, kept by zero-host): reading the rendered screen for a
//! half-typed draft and for the agent's reply, waiting until it sits at its prompt, and typing commands. Plus Claude
//! Code's own record of its sessions, for resuming and titling them. ponytail: screen reading is the ceiling of a
//! terminal; zerod's own sessions speak their providers' protocols instead.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::PathBuf;
use std::time::Duration;

use crate::ask::AgentIdentity;

/// What sits in Claude Code's input box on a rendered screen: the "❯" line just under a rule. None when no input box is in
/// view; empty when the box is empty or shows only its placeholder.
pub fn draft(screen: &str) -> Option<String> {
    let lines: Vec<&str> = screen.split('\n').collect();
    let index = lines.iter().rposition(|l| l.trim().starts_with('❯'))?;
    if index == 0 || !lines[index - 1].contains("────") {
        return None;
    }
    let text = lines[index].trim().trim_start_matches('❯').trim();
    Some(if text.starts_with("Try \"") { String::new() } else { text.to_string() })
}

/// The agent's last spoken block after the echo of `prompt`: a block starts at a "⏺"/"●" line, tool calls (followed by
/// "⎿", or named like `Bash(`) are skipped, and the turn ends at a "· done" line or the next prompt.
pub fn last_reply(screen: &str, prompt: &str) -> Option<String> {
    let ending = |line: &str| {
        let t = line.trim().trim_start_matches(['⏺', '●']).trim();
        t.starts_with("[zero: ") && t.ends_with(']')
    };
    let lines: Vec<&str> = screen.split('\n').filter(|l| !ending(l)).collect();
    let needle: String = prompt.chars().take(40).collect();
    let mut start = 0;
    for (i, line) in lines.iter().enumerate() {
        let t = line.trim();
        if let Some(first) = t.chars().next()
            && "❯〉›>".contains(first)
            && t[first.len_utf8()..].trim().starts_with(&needle)
        {
            start = i + 1
        }
    }
    if start == 0 {
        return None;
    }
    let mut blocks: Vec<Vec<String>> = vec![];
    let mut current: Option<Vec<String>> = None;
    for line in &lines[start..] {
        let t = line.trim();
        if t.contains("· done") || t.chars().next().is_some_and(|c| "❯〉›─".contains(c)) {
            break;
        }
        if t.starts_with('⏺') || t.starts_with('●') {
            if let Some(block) = current.take() {
                blocks.push(block)
            }
            current = Some(vec![t.trim_start_matches(['⏺', '●']).trim().to_string()]);
        } else if t.starts_with('⎿') {
            current = None;
        } else if let Some(block) = current.as_mut() {
            block.push(line.strip_prefix("  ").unwrap_or(line).to_string());
        }
    }
    if let Some(block) = current {
        blocks.push(block)
    }
    let spoken = blocks.into_iter().rev().find(|b| b.first().is_some_and(|first| !is_tool_call(first)))?;
    let mut text = spoken.join("\n").trim().to_string();
    while text.contains("\n\n\n") {
        text = text.replace("\n\n\n", "\n\n")
    }
    (!text.is_empty()).then_some(text)
}

fn is_tool_call(line: &str) -> bool {
    let mut chars = line.chars();
    chars.next().is_some_and(|c| c.is_ascii_uppercase())
        && line.split('(').next().is_some_and(|name| name.chars().all(|c| c.is_ascii_alphabetic()))
        && line.contains('(')
}

/// Keys as bytes.
pub const ENTER: &[u8] = &[13];
pub const ESCAPE: &[u8] = &[27];
pub const CTRL_C: &[u8] = &[3];
pub const DOWN: &[u8] = &[27, 91, 66];

/// A terminal an agent runs in: how to type into it, read it, and tell whether its program runs.
pub trait Terminal: Send + Sync {
    fn name(&self) -> &str;
    fn poll(&self) -> Duration;
    fn type_text<'a>(&'a self, text: &'a str, reference: &'a str) -> crate::inbox::Fut<'a, bool>;
    fn write<'a>(&'a self, bytes: &'a [u8], reference: &'a str) -> crate::inbox::Fut<'a, ()>;
    fn capture<'a>(&'a self, reference: &'a str) -> crate::inbox::Fut<'a, Option<String>>;
    fn state<'a>(&'a self, reference: &'a str) -> crate::inbox::Fut<'a, State>;
}

/// A terminal as it is now: its program running, exited (the terminal kept), gone, or its host unreachable.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Running,
    Exited,
    Missing,
    Unknown,
}

/// Types `text` and Enter, once the input box is empty: typing into a half-written prompt would join the user's words
/// and Zero's into one message. Waits up to 23 looks for it.
pub async fn send(terminal: &dyn Terminal, text: &str, agent: &AgentIdentity) -> Result<(), String> {
    let reference = agent.reference.as_deref().ok_or_else(|| format!("{} has no terminal", agent.name))?;
    for attempt in 0..23 {
        match terminal.capture(reference).await.as_deref().and_then(draft) {
            Some(draft) if !draft.is_empty() => {
                if attempt == 22 {
                    return Err(format!("The user is typing in {}'s terminal", label(agent)));
                }
                tokio::time::sleep(terminal.poll()).await;
            }
            _ => break,
        }
    }
    if !terminal.type_text(text, reference).await {
        return Err(format!("{} couldn't type into {}", terminal.name(), label(agent)));
    }
    tokio::time::sleep(Duration::from_millis(150).min(terminal.poll() * 15)).await;
    terminal.write(ENTER, reference).await;
    Ok(())
}

/// The reply, once the agent is no longer working (Claude Code shows "esc to interrupt" while it is) and a reply follows
/// the echo of the message. Up to 450 looks.
pub async fn reply(terminal: &dyn Terminal, agent: &AgentIdentity, text: &str) -> Option<String> {
    let reference = agent.reference.as_deref()?;
    for _ in 0..450 {
        tokio::time::sleep(terminal.poll()).await;
        let screen = terminal.capture(reference).await?;
        if screen.contains("esc to interrupt") {
            continue;
        }
        if let Some(reply) = last_reply(&screen, text) {
            return Some(reply);
        }
    }
    None
}

/// Claude Code is ready once its input box is drawn. A folder it hasn't been trusted in asks first: these are folders the
/// user worked in with this agent before, so "Yes, I trust this folder" is chosen (its cursor can start on "No").
pub async fn wait_until_ready(terminal: &dyn Terminal, reference: &str, name: &str) -> Result<(), String> {
    for _ in 0..90 {
        tokio::time::sleep(terminal.poll() / 2).await;
        let text = terminal.capture(reference).await.unwrap_or_default();
        if text.contains("Yes, I trust this folder") {
            let chosen = text.lines().any(|l| l.contains('❯') && l.contains("trust this folder"));
            terminal.write(if chosen { ENTER } else { DOWN }, reference).await;
            continue;
        }
        if draft(&text).is_some() {
            return Ok(());
        }
    }
    Err(format!("{name} didn't reach its prompt in {}", terminal.name()))
}

/// Ends the agent's program (⌃C twice), keeping the terminal and the session, so a message resumes it.
pub async fn stop(terminal: &dyn Terminal, agent: &AgentIdentity) {
    let Some(reference) = agent.reference.as_deref() else { return };
    terminal.write(CTRL_C, reference).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    terminal.write(CTRL_C, reference).await;
}

/// The command line to start an agent again on its session: the one it started with, `--resume` swapped for its session.
/// An agent started as another Claude account resumes as the default one: zerod never handles sign-in tokens.
pub fn resume_command(agent: &AgentIdentity) -> Result<Vec<String>, String> {
    let (Some(session), Some(launch)) = (&agent.session, &agent.launch) else { return Err(format!("{}'s session is gone", label(agent))) };
    let mut command = launch.clone();
    if let Some(i) = command.iter().position(|a| a == "--resume")
        && i + 1 < command.len()
    {
        command.drain(i..=i + 1);
    }
    command.extend(["--resume".into(), session.clone()]);
    Ok(command)
}

pub fn label(agent: &AgentIdentity) -> &str {
    agent.label.as_deref().unwrap_or(&agent.name)
}

/// Claude Code takes `/model <id>` and `/effort <level>`, each typed on its own once the last one is handled.
pub async fn switch_model(terminal: &dyn Terminal, agent: &AgentIdentity, model: Option<&str>, level: Option<&str>) -> Result<(), String> {
    if let Some(model) = model {
        send(terminal, &format!("/model {model}"), agent).await?
    }
    if let Some(level) = level.filter(|l| !l.is_empty()) {
        if model.is_some() {
            tokio::time::sleep(Duration::from_millis(1500)).await
        }
        send(terminal, &format!("/effort {level}"), agent).await?;
    }
    Ok(())
}

/// The names among `agents` on this runtime whose terminal is in `wanted`; a host that can't be reached says nothing
/// either way.
pub async fn states<T: Terminal + crate::inbox::Runtime>(terminal: &T, agents: &[AgentIdentity], wanted: State) -> HashSet<String> {
    let mut found = HashSet::new();
    for agent in agents.iter().filter(|a| terminal.can_reach(a)) {
        if let Some(reference) = agent.reference.as_deref()
            && terminal.state(reference).await == wanted
        {
            found.insert(agent.name.clone());
        }
    }
    found
}

/// Claude Code's own record of its sessions: one JSONL per session under ~/.claude/projects/<cwd>, holding the user's turns
/// and the title Claude gives the session ("aiTitle").
#[derive(Clone)]
pub struct ClaudeSessions {
    pub root: PathBuf,
}

impl Default for ClaudeSessions {
    fn default() -> Self {
        ClaudeSessions { root: PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".claude/projects") }
    }
}

impl ClaudeSessions {
    /// Claude Code's folder name for a working directory: every "/" and "." becomes "-".
    pub fn folder(&self, cwd: &str) -> PathBuf {
        self.root.join(cwd.replace(['/', '.'], "-"))
    }

    /// The newest session in `cwd` whose first user turn is exactly `prompt`.
    pub fn find(&self, prompt: &str, cwd: &str) -> Option<String> {
        let needle = format!("\"role\":\"user\",\"content\":{}", serde_json::to_string(prompt).ok()?);
        let mut files: Vec<(std::time::SystemTime, PathBuf)> = std::fs::read_dir(self.folder(cwd))
            .ok()?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == "jsonl"))
            .map(|p| (std::fs::metadata(&p).and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH), p))
            .collect();
        files.sort_by_key(|f| std::cmp::Reverse(f.0));
        files
            .into_iter()
            .find(|(_, p)| std::fs::read_to_string(p).is_ok_and(|t| t.contains(&needle)))
            .and_then(|(_, p)| p.file_stem().map(|s| s.to_string_lossy().to_string()))
    }

    /// What Claude titled the session, once it has. Asked every few seconds of files that run to tens of megabytes, so
    /// only what was added since the last look is read.
    pub fn title(&self, session: &str, cwd: &str) -> Option<String> {
        use std::io::{Read, Seek};
        /// Per file: how far it's been read, and the title found so far.
        type Seen = HashMap<PathBuf, (u64, Option<String>)>;
        static SEEN: std::sync::LazyLock<std::sync::Mutex<Seen>> = std::sync::LazyLock::new(Default::default);
        let path = self.folder(cwd).join(format!("{session}.jsonl"));
        let mut file = std::fs::File::open(&path).ok()?;
        let mut seen = SEEN.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        // A file shorter than what was read was rewritten: read it again.
        let (offset, known) =
            seen.get(&path).cloned().filter(|(offset, _)| file.metadata().is_ok_and(|m| m.len() >= *offset)).unwrap_or((0, None));
        let mut added = vec![];
        file.seek(io::SeekFrom::Start(offset)).ok()?;
        file.read_to_end(&mut added).ok()?;
        let title = last_title(&String::from_utf8_lossy(&added)).or(known);
        // Up to the last whole line: one still being written is read again next time.
        let read = added.iter().rposition(|b| *b == b'\n').map_or(offset, |i| offset + i as u64 + 1);
        seen.insert(path, (read, title.clone()));
        title
    }
}

/// The last "aiTitle" in `text`, if it's whole.
fn last_title(text: &str) -> Option<String> {
    let start = text.rfind("\"aiTitle\":\"")? + "\"aiTitle\":\"".len();
    let bytes = &text.as_bytes()[start..];
    let mut end = 0;
    while end < bytes.len() && !(bytes[end] == b'"' && (end == 0 || bytes[end - 1] != b'\\')) {
        end += 1
    }
    (end < bytes.len()).then(|| text[start..start + end].replace("\\\"", "\""))
}
