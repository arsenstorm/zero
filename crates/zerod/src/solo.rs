//! Agents in Solo, reached through the running Solo app's bundled MCP stdio helper: one helper per call, three
//! JSON-RPC lines (initialize, initialized, tools/call), then it exits. Solo scopes calls to a project; every call about a
//! process carries it.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::ask::AgentIdentity;
use crate::inbox::{Fut, Runtime};
use crate::terminal::{self, ClaudeSessions};

pub struct Solo {
    pub helper: PathBuf,
    pub sessions: ClaudeSessions,
    pub poll: Duration,
}

/// Project paths don't move: one lookup each.
static PROJECT_PATHS: Mutex<Option<HashMap<i64, String>>> = Mutex::new(None);

impl Solo {
    pub fn installed() -> Solo {
        Solo { helper: "/Applications/Solo.app/Contents/MacOS/mcp".into(), sessions: ClaudeSessions::default(), poll: Duration::from_secs(2) }
    }

    /// One tool call: the result's text, or Solo's refusal.
    async fn call(&self, tool: &str, arguments: Value) -> Result<String, String> {
        let mut helper = tokio::process::Command::new(&self.helper)
            // zerod speaks as itself, not as whichever agent's process started it.
            .env_remove("SOLO_PROCESS_ID")
            .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null())
            .kill_on_drop(true).spawn().map_err(|e| format!("Solo's helper didn't start: {e}"))?;
        let mut input = helper.stdin.take().ok_or("no stdin")?;
        let output = helper.stdout.take().ok_or("no stdout")?;
        let lines = [
            json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "zero", "version": "0.1"}}}),
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}),
        ];
        for line in lines { input.write_all(format!("{line}\n").as_bytes()).await.map_err(|e| e.to_string())? }
        let answer = async {
            let mut lines = BufReader::new(output).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                if message["id"] != 2 { continue }
                if let Some(error) = message.get("error") { return Err(error["message"].as_str().unwrap_or("Solo returned an error").to_string()) }
                let result = &message["result"];
                let text = result["content"][0]["text"].as_str().unwrap_or("").to_string();
                return if result["isError"] == true { Err(if text.is_empty() { "Solo refused the call".into() } else { text }) } else { Ok(text) };
            }
            Err("Solo's helper closed without answering".to_string())
        };
        tokio::time::timeout(Duration::from_secs(10), answer).await.map_err(|_| "Solo didn't answer".to_string())?
    }

    async fn call_json(&self, tool: &str, arguments: Value) -> Result<Value, String> {
        let text = self.call(tool, arguments).await?;
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    /// The process's arguments, with its project.
    fn about(agent: &AgentIdentity, extra: Value) -> Value {
        let mut arguments = Map::new();
        if let Some(pid) = agent.solo_process_id { arguments.insert("process_id".into(), pid.into()); }
        if let Some(project) = agent.solo_project_id { arguments.insert("project_id".into(), project.into()); }
        if let Value::Object(extra) = extra { arguments.extend(extra) }
        Value::Object(arguments)
    }

    async fn project_path(&self, id: i64) -> Option<String> {
        if let Some(path) = PROJECT_PATHS.lock().unwrap().as_ref().and_then(|p| p.get(&id).cloned()) { return Some(path) }
        let rows = self.call_json("list_projects", json!({})).await.ok()?;
        let path = rows.as_array()?.iter().find(|r| r["id"] == id)?["path"].as_str()?.to_string();
        PROJECT_PATHS.lock().unwrap().get_or_insert_with(HashMap::new).insert(id, path.clone());
        Some(path)
    }

    async fn screen_of(&self, agent: &AgentIdentity, lines: i64) -> Option<String> {
        agent.solo_process_id?;
        self.call("get_process_output", Solo::about(agent, json!({"lines": lines}))).await.ok()
    }

    /// The agents whose process `matches` in its project's process list. A project Solo couldn't list counts for nobody.
    async fn processes(&self, agents: &[AgentIdentity], matches: impl Fn(&[Value], i64) -> bool) -> HashSet<String> {
        let mut found = HashSet::new();
        let projects: HashSet<i64> = agents.iter().filter_map(|a| a.solo_project_id).collect();
        for project in projects {
            let Ok(Value::Array(rows)) = self.call_json("list_processes", json!({"project_id": project})).await else { continue };
            for agent in agents.iter().filter(|a| a.solo_project_id == Some(project)) {
                if let Some(pid) = agent.solo_process_id && matches(&rows, pid) { found.insert(agent.name.clone()); }
            }
        }
        found
    }

    /// A prompt typed before the agent sits at its input is lost: wait for idle, then for any start-up dialog to be
    /// answered in Solo. Up to 90 s.
    async fn wait_until_ready(&self, agent: &AgentIdentity) -> Result<(), String> {
        for second in 0..90 {
            tokio::time::sleep(self.poll / 2).await;
            let status = self.call_json("get_process_status", Solo::about(agent, json!({}))).await?;
            if status["agent_state"]["idle"] != true && second < 20 { continue }
            let screen = self.screen_of(agent, 15).await.unwrap_or_default();
            if !["Enter to confirm", "trust this folder", "Esc to cancel"].iter().any(|d| screen.contains(d)) { return Ok(()) }
        }
        Err(format!("{} started, but it's waiting at a dialog in Solo. Answer it there, then message the agent.", agent.name))
    }
}

impl Runtime for Solo {
    fn name(&self) -> &str { "Solo" }
    fn can_reach(&self, agent: &AgentIdentity) -> bool { agent.solo_process_id.is_some() && self.helper.is_file() }

    fn send<'a>(&'a self, text: &'a str, agent: &'a AgentIdentity) -> Fut<'a, Result<(), String>> {
        Box::pin(async move {
            for attempt in 0..23 {
                match self.screen_of(agent, 40).await.as_deref().and_then(terminal::draft) {
                    Some(draft) if !draft.is_empty() => {
                        if attempt == 22 { return Err(format!("The user is typing in {}'s terminal", terminal::label(agent))) }
                        tokio::time::sleep(self.poll).await;
                    }
                    _ => break,
                }
            }
            self.call("send_input", Solo::about(agent, json!({"input": text, "submit": true}))).await.map(|_| ())
        })
    }

    fn screen<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, Option<String>> { Box::pin(self.screen_of(agent, 40)) }

    fn press<'a>(&'a self, bytes: &'a [u8], agent: &'a AgentIdentity) -> Fut<'a, Result<Option<String>, String>> {
        Box::pin(async move {
            let result = self.call_json("send_input", Solo::about(agent, json!({"bytes": bytes, "wait_ms": 350}))).await?;
            Ok(result["output"].as_str().map(String::from))
        })
    }

    /// Claude's title for the session; for an agent without a known session, its process's name in Solo unless that is
    /// just the tool's name.
    fn display_name<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, Option<String>> {
        Box::pin(async move {
            let project = agent.solo_project_id?;
            if let Some(session) = &agent.session && let Some(cwd) = self.project_path(project).await { return self.sessions.title(session, &cwd) }
            let rows = self.call_json("list_processes", json!({"project_id": project})).await.ok()?;
            let pid = agent.solo_process_id?;
            let name = rows.as_array()?.iter().find(|r| r["id"] == pid)?["name"].as_str()?.to_string();
            (!["claude", "codex", "agent", "terminal"].contains(&name.to_lowercase().as_str())).then_some(name)
        })
    }

    fn find_session<'a>(&'a self, agent: &'a AgentIdentity, prompt: &'a str) -> Fut<'a, Option<String>> {
        Box::pin(async move { self.sessions.find(prompt, &self.project_path(agent.solo_project_id?).await?) })
    }

    /// Solo reports only busy or idle, so the reply is read off the screen once the agent has gone idle again and a reply
    /// follows the echo of the message. Up to 450 looks.
    fn reply<'a>(&'a self, agent: &'a AgentIdentity, text: &'a str) -> Fut<'a, Option<String>> {
        Box::pin(async move {
            agent.solo_process_id?;
            for _ in 0..450 {
                tokio::time::sleep(self.poll).await;
                let Ok(status) = self.call_json("get_process_status", Solo::about(agent, json!({}))).await else { continue };
                if status["status"] == "Exited" { return None }
                if status["agent_state"]["idle"] != true || status["agent_state"]["idle_seconds"].as_f64().unwrap_or(0.0) < 1.5 { continue }
                if let Some(reply) = self.screen_of(agent, 200).await.as_deref().and_then(|s| terminal::last_reply(s, text)) { return Some(reply) }
            }
            None
        })
    }

    fn switch_model<'a>(&'a self, agent: &'a AgentIdentity, model: Option<&'a str>, level: Option<&'a str>) -> Fut<'a, Result<(), String>> {
        Box::pin(async move {
            if let Some(model) = model { self.send(&format!("/model {model}"), agent).await? }
            if let Some(level) = level.filter(|l| !l.is_empty()) {
                if model.is_some() { tokio::time::sleep(Duration::from_millis(1500)).await }
                self.send(&format!("/effort {level}"), agent).await?;
            }
            Ok(())
        })
    }

    fn offline<'a>(&'a self, agents: &'a [AgentIdentity]) -> Fut<'a, HashSet<String>> {
        Box::pin(self.processes(agents, |rows, pid| rows.iter().find(|r| r["id"] == pid).is_none_or(|r| r["status"] != "Running")))
    }

    fn gone<'a>(&'a self, agents: &'a [AgentIdentity]) -> Fut<'a, HashSet<String>> {
        Box::pin(self.processes(agents, |rows, pid| !rows.iter().any(|r| r["id"] == pid)))
    }

    fn stop<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, ()> {
        Box::pin(async move { if agent.solo_process_id.is_some() && agent.solo_project_id.is_some() { let _ = self.call("stop_process", Solo::about(agent, json!({}))).await; } })
    }

    /// Messages go to the agent's session, not a process: the process Zero knew while it still runs that session;
    /// failing that, any running process already on the session; failing that, a new process continuing the session with
    /// `--resume`, the old one closed. Without a known session, a stopped process is started again.
    fn connect<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, Result<AgentIdentity, String>> {
        Box::pin(async move {
            let project = agent.solo_project_id.ok_or_else(|| format!("{} has no Solo project", agent.name))?;
            let rows: Vec<Value> = match self.call_json("list_processes", json!({"project_id": project})).await? { Value::Array(rows) => rows, _ => vec![] };
            let rows: Vec<Value> = rows.into_iter().filter(|r| r["kind"] == "agent").collect();
            let running = |row: &Value| row["status"] == "Running";
            let known = rows.iter().find(|r| Some(r["id"].as_i64().unwrap_or(-1)) == agent.solo_process_id).cloned();
            if known.as_ref().is_some_and(running) { return Ok(agent.clone()) }
            if let Some(session) = &agent.session && let Some(host) = rows.iter().find(|r| running(r) && r["command"].as_str().unwrap_or("").contains(session.as_str())) {
                return Ok(AgentIdentity { solo_process_id: host["id"].as_i64(), ..agent.clone() });
            }
            let command = known.as_ref().and_then(|k| k["command"].as_str()).unwrap_or("").to_string();
            let mut session = agent.session.clone();
            if session.is_none() && known.is_some() {
                // A Claude that quit leaves "claude --resume <id>" on its screen.
                let screen = self.screen_of(agent, 60).await.unwrap_or_default();
                session = screen.find("--resume ").map(|i| screen[i + 9..].chars().take(36).collect::<String>()).filter(|s| s.len() == 36);
            }
            if let Some(session) = session {
                // Solo shell-quotes the arguments it shows ('{"env":…}'); the quotes aren't part of them.
                let mut words: Vec<String> = command.split(' ').map(|w| w.strip_prefix('\'').and_then(|w| w.strip_suffix('\'')).unwrap_or(w).to_string()).collect();
                let executable = if words.is_empty() || words[0].is_empty() { "claude".to_string() } else { words.remove(0) };
                if let Some(i) = words.iter().position(|w| w == "--resume") && i + 1 < words.len() { words.drain(i..=i + 1); }
                let tools = self.call_json("list_agent_tools", json!({})).await.unwrap_or(Value::Null);
                let tool = tools.as_array().and_then(|t| t.iter().find(|t| t["command"].as_str().unwrap_or("").split(' ').next() == Some(executable.as_str())))
                    .and_then(|t| t["id"].as_i64()).ok_or_else(|| format!("Solo has no {executable} tool to resume the session with"))?;
                words.extend(["--resume".into(), session.clone()]);
                let created = self.call_json("spawn_agent", json!({"project_id": project, "agent_tool_id": tool, "extra_args": words, "include_agent_instructions": false})).await?;
                let fresh = created["process_id"].as_i64().ok_or("Solo didn't return a process id")?;
                if let Some(old) = agent.solo_process_id && known.is_some() { let _ = self.call("close_process", json!({"process_id": old, "project_id": project})).await; }
                let resumed = AgentIdentity { solo_process_id: Some(fresh), session: Some(session), ..agent.clone() };
                self.wait_until_ready(&resumed).await?;
                return Ok(resumed);
            }
            if known.is_none() || agent.solo_process_id.is_none() { return Err(format!("{}'s session is gone", terminal::label(agent))) }
            self.call("start_process", Solo::about(agent, json!({}))).await?;
            self.wait_until_ready(agent).await?;
            Ok(agent.clone())
        })
    }
}
