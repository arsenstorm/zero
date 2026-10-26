//! Agents in Zero's own terminals, kept by zero-host (apps/macos/Sources/ZeroHost), which runs on its own so they keep
//! running when Zero quits. One JSON line each way per request over ~/.zero/host.sock.

use std::collections::HashSet;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::ask::AgentIdentity;
use crate::inbox::{Fut, Runtime};
use crate::rex::{states, switch_model};
use crate::terminal::{self, ClaudeSessions, State, Terminal};

pub struct Host {
    pub socket: PathBuf,
    pub sessions: ClaudeSessions,
    pub poll: Duration,
}

impl Host {
    pub fn installed() -> Host {
        let socket = PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".zero/host.sock");
        Host { socket, sessions: ClaudeSessions::default(), poll: Duration::from_secs(2) }
    }

    /// One request and its answer; None when zero-host isn't running.
    async fn call(&self, request: Value) -> Option<Value> {
        let stream = tokio::net::UnixStream::connect(&self.socket).await.ok()?;
        let (read, mut write) = stream.into_split();
        write.write_all(format!("{request}\n").as_bytes()).await.ok()?;
        let line = BufReader::new(read).lines().next_line().await.ok()??;
        serde_json::from_str(&line).ok()
    }
}

impl Terminal for Host {
    fn name(&self) -> &str { "Zero" }
    fn poll(&self) -> Duration { self.poll }
    fn type_text<'a>(&'a self, text: &'a str, reference: &'a str) -> Fut<'a, bool> {
        Box::pin(async move { self.call(json!({"op": "write", "id": reference, "text": text})).await.is_some_and(|r| r["ok"] == true) })
    }
    fn write<'a>(&'a self, bytes: &'a [u8], reference: &'a str) -> Fut<'a, ()> {
        Box::pin(async move { self.call(json!({"op": "write", "id": reference, "bytes": bytes})).await; })
    }
    fn capture<'a>(&'a self, reference: &'a str) -> Fut<'a, Option<String>> {
        Box::pin(async move { self.call(json!({"op": "screen", "id": reference})).await?["screen"].as_str().map(String::from) })
    }
    fn state<'a>(&'a self, reference: &'a str) -> Fut<'a, State> {
        Box::pin(async move {
            let Some(response) = self.call(json!({"op": "state", "id": reference})).await else { return State::Unknown };
            match response["terminal"]["running"].as_bool() { Some(true) => State::Running, Some(false) => State::Exited, None => State::Missing }
        })
    }
}

impl Runtime for Host {
    fn name(&self) -> &str { "Zero" }
    fn can_reach(&self, agent: &AgentIdentity) -> bool { agent.runtime.as_deref() == Some("zero") && agent.reference.is_some() }
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
    /// The agent's terminal if its program runs; otherwise a new one on its conversation, the old one closed.
    fn connect<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, Result<AgentIdentity, String>> {
        Box::pin(async move {
            let reference = agent.reference.clone().ok_or("no terminal")?;
            let now = self.state(&reference).await;
            if now == State::Running { return Ok(agent.clone()) }
            let cwd = agent.cwd.clone().ok_or_else(|| format!("{}'s session is gone", terminal::label(agent)))?;
            let command = terminal::resume_command(agent)?;
            let started = self.call(json!({"op": "spawn", "cwd": cwd, "argv": command, "label": terminal::label(agent)})).await
                .ok_or("Zero's terminal host isn't running")?;
            let fresh = started["terminal"]["id"].as_str().map(String::from)
                .ok_or_else(|| started["error"].as_str().unwrap_or("Zero couldn't start the agent").to_string())?;
            if now == State::Exited { self.call(json!({"op": "close", "id": reference})).await; }
            terminal::wait_until_ready(self, &fresh, terminal::label(agent)).await?;
            Ok(AgentIdentity { reference: Some(fresh), ..agent.clone() })
        })
    }
}
