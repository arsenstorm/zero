//! Agents that speak the Agent Client Protocol (agentclientprotocol.com): JSON-RPC 2.0 over stdio, with
//! `session/update` notifications for what the agent does and `session/request_permission` for what it asks.
//! OpenCode first, through `opencode acp`, which hands the work to OpenCode's own background service: sessions
//! outlive the process, and OpenCode signs in and applies its own permission rules.

use std::collections::HashMap;

use serde_json::{Value, json};

use crate::adapter::{Adapter, Answers, Effects, after_approval, json_rpc_answer, key};
use crate::codex::file_title;
use crate::model::{Approval, ApprovalKind, Change, Choice, ChoiceKind, Conversation, FileChange, Item, ItemKind, ItemStatus, Question, Status};
use crate::session::{Session, Transport};

#[derive(Default)]
pub struct Acp {
    /// Zero's requests waiting for an answer: id → method.
    pending: HashMap<String, String>,
    /// The agent's permission requests waiting for Zero: approval id → the JSON-RPC id to answer.
    requests: HashMap<String, Value>,
    /// Every tool call so far, its updates merged in, by id.
    calls: HashMap<String, Value>,
    /// The item the agent's streamed words (or thoughts) are going into, while nothing else comes between.
    speaking: Option<String>,
    thinking: Option<String>,
    /// The latest thing the agent said this turn: its answer, once the prompt returns.
    said: Option<String>,
}

impl Adapter for Acp {
    fn sent(&mut self, conversation: &Conversation, message: &Value) -> Vec<Change> {
        match (message.get("id"), message["method"].as_str()) {
            (Some(id), Some(method)) => {
                self.pending.insert(key(id), method.into());
                if method != "session/prompt" { return vec![] }
                // The agent doesn't echo the prompt: the words are recorded as sent, and the turn runs until it returns.
                let text = message["params"]["prompt"].as_array().cloned().unwrap_or_default().iter()
                    .filter(|block| block["_meta"]["zero"] != "context")
                    .filter_map(|block| block["text"].as_str().map(String::from)).collect::<Vec<_>>().join("\n");
                let turn = Some(key(id));
                vec![
                    Change::Item { item: Item { at: None, id: format!("user-{}", conversation.seq + 1), turn: turn.clone(), kind: ItemKind::User { text, images: vec![] }, status: ItemStatus::Done } },
                    Change::Status { status: Status::Working, turn, error: None },
                ]
            }
            (Some(id), None) => {
                let approval = key(id);
                if self.requests.remove(&approval).is_none() { return vec![] }
                vec![Change::Resolved { approval: approval.clone() }, after_approval(conversation, &approval)]
            }
            _ => vec![],
        }
    }

    fn receive(&mut self, conversation: &Conversation, message: &Value) -> Effects {
        let mut effects = Effects::default();
        match (message.get("id"), message["method"].as_str()) {
            (Some(id), Some(method)) => self.request(conversation, id, method, &message["params"], &mut effects),
            (Some(id), None) => self.response(conversation, id, message, &mut effects),
            (None, Some("session/update")) => self.update(conversation, &message["params"]["update"], &mut effects),
            _ => {}
        }
        effects
    }

    fn answers(&self, message: &Value) -> Option<(String, Result<Value, String>)> {
        json_rpc_answer(message)
    }

    fn answer(&self, approval: &Approval, choice: &str) -> Result<Value, String> {
        let id = self.requests.get(&approval.id).ok_or_else(|| format!("The agent isn't waiting on \"{}\" any more", approval.title))?;
        Ok(json!({"jsonrpc": "2.0", "id": id, "result": {"outcome": {"outcome": "selected", "optionId": choice}}}))
    }

    /// ACP's own questions (elicitation) aren't sent by OpenCode 2.1.4; none is ever open to answer.
    fn reply(&self, _: &Question, _: &Answers) -> Result<Value, String> {
        Err("The agent asked no question Zero can answer".into())
    }

    fn ended(&mut self) {
        self.pending.clear();
        self.requests.clear();
        self.speaking = None;
        self.thinking = None;
        self.said = None;
    }
}

impl Acp {
    fn response(&mut self, conversation: &Conversation, id: &Value, message: &Value, effects: &mut Effects) {
        let Some(method) = self.pending.remove(&key(id)) else { return };
        let result = &message["result"];
        if method == "session/prompt" { return self.finished(conversation, message, effects) }
        if let Some(error) = message.get("error") {
            return effects.fail(conversation, &format!("{method} failed: {}", error["message"].as_str().unwrap_or("no reason given")));
        }
        let thread = result["sessionId"].as_str().map(String::from).or(conversation.thread.clone());
        let option = |name: &str| result["configOptions"].as_array()?.iter().find(|o| o["id"] == name)?["currentValue"].as_str().map(String::from);
        if let Some(thread) = thread && (method == "session/new" || result.get("configOptions").is_some()) {
            effects.changes.push(Change::Thread { thread, model: option("model"), effort: option("effort").filter(|e| e != "default") });
        }
        // A new session is still starting until its first prompt; a resumed one is waiting for the next.
        if matches!(method.as_str(), "session/resume" | "session/load") && matches!(conversation.status, Status::Starting | Status::Offline) {
            effects.changes.push(Change::Status { status: Status::Idle, turn: None, error: None });
        }
    }

    /// The prompt returned: the turn is over, its last words are its answer.
    fn finished(&mut self, conversation: &Conversation, message: &Value, effects: &mut Effects) {
        let mut error = None;
        if let Some(failure) = message.get("error") {
            let text = failure["message"].as_str().unwrap_or("The agent refused the prompt").to_string();
            effects.notice(conversation, &text, true);
            error = Some(text);
        } else {
            match message["result"]["stopReason"].as_str() {
                Some("cancelled") => effects.notice(conversation, "Interrupted", false),
                Some("refusal") => effects.notice(conversation, "The agent refused to go on", true),
                Some("max_tokens") | Some("max_turn_requests") => effects.notice(conversation, "The agent stopped at its limit", true),
                _ => {}
            }
        }
        for item in conversation.items.iter().filter(|i| i.turn == conversation.turn && i.status == ItemStatus::Running) {
            if matches!(item.kind, ItemKind::Agent { .. } | ItemKind::Reasoning { .. }) {
                let mut done = item.clone();
                done.status = ItemStatus::Done;
                if Some(&done.id) == self.said.as_ref() && let ItemKind::Agent { final_answer, .. } = &mut done.kind { *final_answer = true }
                effects.changes.push(Change::Item { item: done });
            }
        }
        (self.speaking, self.thinking, self.said) = (None, None, None);
        effects.changes.push(Change::Status { status: Status::Idle, turn: None, error });
    }

    fn update(&mut self, conversation: &Conversation, update: &Value, effects: &mut Effects) {
        let turn = conversation.turn.clone();
        match update["sessionUpdate"].as_str() {
            Some(kind @ ("agent_message_chunk" | "agent_thought_chunk" | "user_message_chunk")) => {
                let text = match update["content"]["type"].as_str() {
                    Some("text") => update["content"]["text"].as_str().unwrap_or("").to_string(),
                    Some(other) => format!("[{other}]"),
                    None => return,
                };
                let thought = kind == "agent_thought_chunk";
                let current = if thought { &self.thinking } else { &self.speaking };
                // Words go on in the item they started in, as long as nothing else came after it.
                if let Some(id) = current && conversation.items.last().map(|i| &i.id) == Some(id) {
                    effects.changes.push(Change::Delta { item: id.clone(), text });
                    return;
                }
                let id = format!("{}-{}", kind.trim_end_matches("_chunk"), conversation.seq + 1);
                let item = match kind {
                    "agent_thought_chunk" => ItemKind::Reasoning { text },
                    "user_message_chunk" => ItemKind::User { text, images: vec![] },
                    _ => ItemKind::Agent { text, final_answer: false },
                };
                let status = if kind == "user_message_chunk" { ItemStatus::Done } else { ItemStatus::Running };
                effects.changes.push(Change::Item { item: Item { at: None, id: id.clone(), turn, kind: item, status } });
                match kind {
                    "agent_thought_chunk" => self.thinking = Some(id),
                    "agent_message_chunk" => { self.speaking = Some(id.clone()); self.said = Some(id) }
                    _ => {}
                }
            }
            Some("tool_call") | Some("tool_call_update") => {
                let Some(id) = update["toolCallId"].as_str() else { return };
                let merged = self.merge(id, update);
                effects.changes.push(Change::Item { item: Item { at: None, id: id.into(), turn, kind: tool(conversation, &merged), status: status(&merged) } });
            }
            Some("plan") => {
                let text = update["entries"].as_array().cloned().unwrap_or_default().iter().map(|entry| {
                    let mark = if entry["status"] == "completed" { "[x]" } else { "[ ]" };
                    format!("- {mark} {}", entry["content"].as_str().unwrap_or(""))
                }).collect::<Vec<_>>().join("\n");
                let id = format!("plan-{}", turn.as_deref().unwrap_or("turn"));
                effects.changes.push(Change::Item { item: Item { at: None, id, turn, kind: ItemKind::Plan { text }, status: ItemStatus::Running } });
            }
            // Usage, available commands, mode and config changes: kept in the transcript, not shown.
            _ => {}
        }
    }

    fn request(&mut self, conversation: &Conversation, id: &Value, method: &str, params: &Value, effects: &mut Effects) {
        if method != "session/request_permission" {
            // Zero offers the agent no file system or terminal of its own (its initialize says so), so nothing else should come.
            effects.notice(conversation, &format!("The agent asked something Zero can't answer yet ({method}), so it was refused"), true);
            effects.replies.push(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("Zero can't answer {method} yet")}}));
            return;
        }
        let call = &params["toolCall"];
        let call_id = call["toolCallId"].as_str().unwrap_or("").to_string();
        let merged = self.merge(&call_id, call);
        let (kind, title, command, cwd, changes) = match tool(conversation, &merged) {
            ItemKind::Command { command, cwd, .. } => (ApprovalKind::Command, format!("Run {command}"), Some(command), Some(cwd), vec![]),
            ItemKind::FileChange { changes } => {
                let title = if merged["name"] == "write" { format!("Write {}", changes[0].path.rsplit('/').next().unwrap_or("")) } else { file_title(&changes) };
                (ApprovalKind::FileChange, title, None, None, changes)
            }
            _ => (ApprovalKind::Tool, merged["title"].as_str().unwrap_or("Use a tool").to_string(), None, None, vec![]),
        };
        let choices = params["options"].as_array().cloned().unwrap_or_default().iter().filter_map(|option| {
            let kind = match option["kind"].as_str()? {
                "allow_once" => ChoiceKind::Allow,
                "allow_always" => ChoiceKind::AllowAlways,
                "reject_once" | "reject_always" => ChoiceKind::Deny,
                _ => return None,
            };
            Some(Choice { id: option["optionId"].as_str()?.into(), label: option["name"].as_str().unwrap_or("").into(), kind })
        }).collect();
        let approval = Approval { id: key(id), item: Some(call_id), kind, title, command, cwd, reason: None, changes, choices };
        self.requests.insert(approval.id.clone(), id.clone());
        effects.changes.push(Change::Approval { approval });
        effects.changes.push(Change::Status { status: Status::Waiting, turn: conversation.turn.clone(), error: conversation.error.clone() });
    }

    /// A tool call with everything its updates have said about it since.
    fn merge(&mut self, id: &str, update: &Value) -> Value {
        let call = self.calls.entry(id.into()).or_insert_with(|| json!({}));
        if let (Some(call), Some(fields)) = (call.as_object_mut(), update.as_object()) {
            for (field, value) in fields { call.insert(field.clone(), value.clone()); }
        }
        call.clone()
    }
}

/// What a tool call is in Zero's terms, from ACP's tool kinds: `execute` a command, `edit` a change to files,
/// anything else (read, search, fetch, think) a tool.
fn tool(conversation: &Conversation, call: &Value) -> ItemKind {
    let input = &call["rawInput"];
    let texts = || call["content"].as_array().cloned().unwrap_or_default().iter()
        .filter_map(|c| c["content"]["text"].as_str().map(String::from)).collect::<Vec<_>>().join("\n");
    match call["kind"].as_str() {
        Some("execute") => ItemKind::Command {
            command: input["command"].as_str().or(call["title"].as_str()).unwrap_or("").into(),
            cwd: input["cwd"].as_str().unwrap_or(&conversation.cwd).into(),
            output: texts(),
            exit_code: call["rawOutput"]["metadata"]["exit"].as_i64(),
            duration_ms: None,
        },
        Some("edit") => {
            let diffs: Vec<FileChange> = call["content"].as_array().cloned().unwrap_or_default().iter().filter(|c| c["type"] == "diff").map(|c| {
                let new = c["newText"].as_str().unwrap_or("");
                match c["oldText"].as_str() {
                    None => FileChange { path: c["path"].as_str().unwrap_or("").into(), kind: "add".into(), move_path: None, diff: new.into() },
                    Some(old) => {
                        let mut diff = String::new();
                        for line in old.lines() { diff += &format!("-{line}\n") }
                        for line in new.lines() { diff += &format!("+{line}\n") }
                        FileChange { path: c["path"].as_str().unwrap_or("").into(), kind: "update".into(), move_path: None, diff }
                    }
                }
            }).collect();
            if !diffs.is_empty() { return ItemKind::FileChange { changes: diffs } }
            let path = call["locations"][0]["path"].as_str().or(input["path"].as_str()).unwrap_or("").to_string();
            ItemKind::FileChange { changes: vec![FileChange { path, kind: "update".into(), move_path: None, diff: input["content"].as_str().unwrap_or("").into() }] }
        }
        _ => {
            let detail = call["locations"][0]["path"].as_str().map(String::from).unwrap_or_else(|| if input.is_null() { String::new() } else { input.to_string() });
            ItemKind::Tool { name: call["title"].as_str().unwrap_or("tool").into(), detail }
        }
    }
}

fn status(call: &Value) -> ItemStatus {
    match call["status"].as_str() {
        Some("completed") => ItemStatus::Done,
        Some("failed") => ItemStatus::Failed,
        _ => ItemStatus::Running,
    }
}

// The session's side: what Zero says to the agent, in order.

pub async fn start(session: &Session, transport: Transport, prompt: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
    start_with_context(session, transport, None, prompt, images, model, effort).await
}

/// A new session whose first prompt carries Zero's instructions and `context` (the conversation so far) in blocks of
/// their own, marked so they aren't taken for the user's words.
pub async fn start_with_context(session: &Session, transport: Transport, context: Option<&str>, prompt: &str, images: &[String], model: Option<&str>,
                                effort: Option<&str>) -> Result<(), String> {
    initialize(session, transport).await?;
    let snapshot = session.snapshot();
    let (cwd, servers) = (snapshot.cwd.clone(), mcp_servers(&snapshot.mcp));
    session.request(|id| json!({"jsonrpc": "2.0", "id": id, "method": "session/new", "params": {"cwd": cwd, "mcpServers": servers}})).await?;
    configure(session, model, effort).await?;
    let mut blocks = blocks(prompt, images);
    // ACP has no standing instructions (Claude's system prompt, Codex's developer ones): Zero's go first, as context.
    if let Some(list) = blocks.as_array_mut() {
        for text in context.into_iter().chain([crate::adapter::INSTRUCTIONS]) {
            list.insert(0, json!({"type": "text", "text": text, "_meta": {"zero": "context"}}));
        }
    }
    let thread = session.snapshot().thread.ok_or("The agent opened no session")?;
    session.request_later(|id| json!({"jsonrpc": "2.0", "id": id, "method": "session/prompt", "params": {"sessionId": thread, "prompt": blocks}}))
}

/// The agent's own session again, without its history replayed: the transcript already has it.
pub async fn resume(session: &Session, transport: Transport) -> Result<(), String> {
    let conversation = session.snapshot();
    let thread = conversation.thread.ok_or("This session never got as far as a session of the agent's, so there is nothing to resume")?;
    initialize(session, transport).await?;
    let params = json!({"sessionId": thread, "cwd": conversation.cwd, "mcpServers": mcp_servers(&conversation.mcp)});
    session.request(|id| json!({"jsonrpc": "2.0", "id": id, "method": "session/resume", "params": params})).await.map(|_| ())
}

async fn initialize(session: &Session, transport: Transport) -> Result<(), String> {
    session.attach(transport);
    session.request(|id| json!({"jsonrpc": "2.0", "id": id, "method": "initialize", "params": {
        "protocolVersion": 1,
        "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false},
        "clientInfo": {"name": "zero", "title": "Zero", "version": env!("CARGO_PKG_VERSION")},
    }})).await.map(|_| ())
}

/// Sets the model, then the effort (an option OpenCode adds for models that have one).
pub(crate) async fn configure(session: &Session, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
    let thread = session.snapshot().thread.ok_or("The agent opened no session")?;
    for (option, value) in [("model", model), ("effort", effort)] {
        let Some(value) = value else { continue };
        session.request(|id| json!({"jsonrpc": "2.0", "id": id, "method": "session/set_config_option", "params": {"sessionId": thread, "configId": option, "value": value}})).await?;
    }
    Ok(())
}

/// The prompt's answer comes only when the turn ends, so nothing waits on it here: the adapter ends the turn.
fn prompt(session: &Session, text: &str, images: &[String]) -> Result<(), String> {
    let thread = session.snapshot().thread.ok_or("The agent opened no session")?;
    let prompt = blocks(text, images);
    session.request_later(|id| json!({"jsonrpc": "2.0", "id": id, "method": "session/prompt", "params": {"sessionId": thread, "prompt": prompt}}))
}

/// Your words as ACP's prompt blocks, each image as data where its token stands (images.rs).
pub fn blocks(text: &str, images: &[String]) -> Value {
    if images.is_empty() { return json!([{"type": "text", "text": text}]) }
    let blocks: Vec<Value> = crate::images::parts(text, images).into_iter().filter_map(|part| match part {
        crate::images::Part::Text(text) => Some(json!({"type": "text", "text": text})),
        crate::images::Part::Image(path) => crate::images::data(path).map(|(mime, data)| json!({"type": "image", "mimeType": mime, "data": data})),
    }).collect();
    Value::Array(blocks)
}

/// ponytail: ACP has no steering and one prompt at a time, so a message mid-turn is refused; queue it in zerod if
/// that gets in the way.
pub async fn send(session: &Session, text: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
    let conversation = session.snapshot();
    if conversation.turn.is_some() {
        return Err(format!("{} takes one message at a time: wait for its answer, or stop it first", conversation.provider.title()));
    }
    configure(session, model, effort).await?;
    prompt(session, text, images)
}

pub async fn interrupt(session: &Session) -> Result<(), String> {
    let conversation = session.snapshot();
    let (Some(thread), Some(_)) = (conversation.thread, conversation.turn) else { return Err("Nothing is running to interrupt".into()) };
    session.write(json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": thread}}))
}

/// Zero's MCP servers as ACP's `mcpServers` has them: stdio ones with their environment, HTTP ones with headers.
pub fn mcp_servers(servers: &[crate::mcp_servers::Resolved]) -> Value {
    let pairs = |values: &[(String, String)]| -> Vec<Value> { values.iter().map(|(name, value)| json!({"name": name, "value": value})).collect() };
    Value::Array(servers.iter().filter_map(|server| match (&server.command, &server.url) {
        (Some(command), _) => Some(json!({"name": server.id, "command": command, "args": server.args, "env": pairs(&server.env)})),
        (None, Some(url)) => Some(json!({"type": "http", "name": server.id, "url": url, "headers": pairs(&server.headers)})),
        (None, None) => None,
    }).collect())
}
