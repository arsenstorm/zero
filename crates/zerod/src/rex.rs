//! Agents in Rex terminals (a server that keeps terminals running whether or not anything shows them), reached through
//! the `rex` CLI: `send`/`send-key` type, `capture` reads the screen, `block call … process` says whether its program runs
//! (exit 3: no such terminal), `run` starts one again.

use std::collections::HashSet;
use std::path::PathBuf;
use std::time::Duration;

use crate::ask::AgentIdentity;
use crate::inbox::{Fut, Runtime};
use crate::terminal::{self, ClaudeSessions, State, Terminal};

pub struct Rex {
    pub executable: Option<PathBuf>,
    pub sessions: ClaudeSessions,
    pub poll: Duration,
}

impl Rex {
    /// The `rex` Rex's own server keeps current, else one on the PATH.
    pub fn installed() -> Rex {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let bundled = home.join("Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex");
        let on_path = std::env::var("PATH").unwrap_or_default().split(':').map(|d| PathBuf::from(d).join("rex"))
            .chain(["/opt/homebrew/bin/rex".into(), "/usr/local/bin/rex".into()]).find(|p| p.is_file());
        Rex { executable: if bundled.is_file() { Some(bundled) } else { on_path }, sessions: ClaudeSessions::default(), poll: Duration::from_secs(2) }
    }

    /// One `rex` call: its exit status (0 ok, 3 not found, 4 server unreachable) and what it printed.
    async fn rex(&self, args: &[&str]) -> (i32, String) {
        let Some(rex) = &self.executable else { return (127, String::new()) };
        match tokio::process::Command::new(rex).args(args).stderr(std::process::Stdio::null()).output().await {
            Ok(output) => (output.status.code().unwrap_or(-1), String::from_utf8_lossy(&output.stdout).to_string()),
            Err(_) => (127, String::new()),
        }
    }

    fn block_id(output: &str) -> Option<String> {
        let start = output.find("block:")?;
        let id: String = output[start..].chars().take_while(|c| c.is_ascii_alphanumeric() || *c == ':' || *c == '-').collect();
        (id.len() > 6).then_some(id)
    }
}

impl Terminal for Rex {
    fn name(&self) -> &str { "Rex" }
    fn poll(&self) -> Duration { self.poll }
    fn type_text<'a>(&'a self, text: &'a str, reference: &'a str) -> Fut<'a, bool> {
        Box::pin(async move { self.rex(&["send", "-b", reference, text]).await.0 == 0 })
    }
    fn write<'a>(&'a self, bytes: &'a [u8], reference: &'a str) -> Fut<'a, ()> {
        Box::pin(async move {
            let key = match bytes { [13] => Some("enter"), [27] => Some("escape"), [127] => Some("backspace"), [3] => Some("ctrl+c"),
                                    [27, 91, 65] => Some("up"), [27, 91, 66] => Some("down"), [27, 91, 67] => Some("right"), [27, 91, 68] => Some("left"), _ => None };
            match key {
                Some(key) => { self.rex(&["send-key", "-b", reference, key]).await; }
                None => { self.rex(&["send", "-b", reference, &String::from_utf8_lossy(bytes)]).await; }
            }
        })
    }
    fn capture<'a>(&'a self, reference: &'a str) -> Fut<'a, Option<String>> {
        Box::pin(async move { let (status, output) = self.rex(&["capture", "-b", reference, "--trim"]).await; (status == 0).then_some(output) })
    }
    fn state<'a>(&'a self, reference: &'a str) -> Fut<'a, State> {
        Box::pin(async move {
            match self.rex(&["block", "call", "-b", reference, "process"]).await {
                (0, output) => match serde_json::from_str::<serde_json::Value>(&output) {
                    Ok(json) if json["child"].is_object() => State::Running,
                    Ok(_) => State::Exited,
                    Err(_) => State::Unknown,
                },
                (3, _) => State::Missing,
                _ => State::Unknown,
            }
        })
    }
}

impl Runtime for Rex {
    fn name(&self) -> &str { "Rex" }
    fn can_reach(&self, agent: &AgentIdentity) -> bool { agent.runtime.as_deref() == Some("rex") && agent.reference.is_some() }
    fn send<'a>(&'a self, text: &'a str, agent: &'a AgentIdentity) -> Fut<'a, Result<(), String>> { Box::pin(terminal::send(self, text, agent)) }
    fn reply<'a>(&'a self, agent: &'a AgentIdentity, text: &'a str) -> Fut<'a, Option<String>> { Box::pin(terminal::reply(self, agent, text)) }
    fn display_name<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, Option<String>> {
        Box::pin(async move { self.sessions.title(agent.session.as_deref()?, agent.cwd.as_deref()?) })
    }
    fn find_session<'a>(&'a self, agent: &'a AgentIdentity, prompt: &'a str) -> Fut<'a, Option<String>> {
        Box::pin(async move { self.sessions.find(prompt, agent.cwd.as_deref()?) })
    }
    fn screen<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, Option<String>> { Box::pin(async move { self.capture(agent.reference.as_deref()?).await }) }
    fn press<'a>(&'a self, bytes: &'a [u8], agent: &'a AgentIdentity) -> Fut<'a, Result<Option<String>, String>> {
        Box::pin(async move {
            let reference = agent.reference.as_deref().ok_or("no terminal")?;
            self.write(bytes, reference).await;
            tokio::time::sleep(Duration::from_millis(350)).await;
            Ok(self.capture(reference).await)
        })
    }
    fn switch_model<'a>(&'a self, agent: &'a AgentIdentity, model: Option<&'a str>, level: Option<&'a str>) -> Fut<'a, Result<(), String>> {
        Box::pin(switch_model(self, agent, model, level))
    }
    fn offline<'a>(&'a self, agents: &'a [AgentIdentity]) -> Fut<'a, HashSet<String>> { Box::pin(states(self, agents, State::Exited)) }
    fn gone<'a>(&'a self, agents: &'a [AgentIdentity]) -> Fut<'a, HashSet<String>> { Box::pin(states(self, agents, State::Missing)) }
    fn stop<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, ()> { Box::pin(terminal::stop(self, agent)) }
    /// The agent's terminal if its program runs; otherwise the agent again in the same Rex session, on its conversation.
    fn connect<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, Result<AgentIdentity, String>> {
        Box::pin(async move {
            let block = agent.reference.clone().ok_or("no Rex terminal")?;
            let now = self.state(&block).await;
            match now { State::Running => return Ok(agent.clone()), State::Unknown => return Err("Rex isn't running".into()), _ => {} }
            let cwd = agent.cwd.clone().ok_or_else(|| format!("{}'s session is gone", terminal::label(agent)))?;
            let command = terminal::resume_command(agent)?;
            let mut args: Vec<&str> = vec!["run", "--json", "--keep-open", "--cwd", &cwd];
            if let Some(group) = &agent.ref_group { args.extend(["-s", group]) }
            args.push("--");
            args.extend(command.iter().map(String::as_str));
            let (status, output) = self.rex(&args).await;
            let fresh = Rex::block_id(&output).filter(|_| status == 0).ok_or_else(|| format!("Rex couldn't start {} again", terminal::label(agent)))?;
            if now == State::Exited { self.rex(&["block", "close", &block]).await; }
            terminal::wait_until_ready(self, &fresh, terminal::label(agent)).await?;
            Ok(AgentIdentity { reference: Some(fresh), ..agent.clone() })
        })
    }
}

/// Claude Code takes `/model <id>` and `/effort <level>`, each typed on its own once the last one is handled.
pub async fn switch_model(terminal: &dyn Terminal, agent: &AgentIdentity, model: Option<&str>, level: Option<&str>) -> Result<(), String> {
    if let Some(model) = model { terminal::send(terminal, &format!("/model {model}"), agent).await? }
    if let Some(level) = level.filter(|l| !l.is_empty()) {
        if model.is_some() { tokio::time::sleep(Duration::from_millis(1500)).await }
        terminal::send(terminal, &format!("/effort {level}"), agent).await?;
    }
    Ok(())
}

/// The names among `agents` on this runtime whose terminal is in `wanted`; a host that can't be reached says nothing
/// either way.
pub async fn states<T: Terminal + Runtime>(terminal: &T, agents: &[AgentIdentity], wanted: State) -> HashSet<String> {
    let mut found = HashSet::new();
    for agent in agents.iter().filter(|a| terminal.can_reach(a)) {
        if let Some(reference) = agent.reference.as_deref() && terminal.state(reference).await == wanted { found.insert(agent.name.clone()); }
    }
    found
}
