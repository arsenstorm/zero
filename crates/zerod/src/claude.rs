//! Claude Code through its own headless mode: the installed `claude`, unmodified, with stream-json both ways and
//! its permission prompts on stdio (`--permission-prompt-tool stdio`, as Anthropic's Agent SDK starts it). It
//! signs in as it always does; Zero never reads or holds its credentials. The message shapes are those of the
//! SDK's control protocol (`@anthropic-ai/claude-agent-sdk`'s sdk.d.ts), checked against recordings.

use std::collections::HashMap;

use serde_json::{Value, json};

use crate::adapter::{Adapter, Effects, after_approval, login_shell};
use crate::codex::file_title;
use crate::model::{Approval, ApprovalKind, Change, Choice, ChoiceKind, Conversation, FileChange, Item, ItemKind, ItemStatus, Status};
use crate::session::{Session, Transport};

#[derive(Default)]
pub struct Claude {
    /// Messages sent and not yet finished: a message sent mid-turn waits its turn inside Claude.
    queued: u32,
    turns: u64,
    /// Claude's permission requests waiting for Zero: request id → the tool's input and Claude's suggested rules.
    requests: HashMap<String, (Value, Value)>,
    /// Text blocks seen per Claude message, streamed and finished, so both name the same item.
    streamed: HashMap<String, u32>,
    finished: HashMap<String, u32>,
    /// (message, block index) of a streaming text block → its item.
    blocks: HashMap<(String, u64), String>,
    /// The latest thing Claude said this turn: its answer, once the turn ends.
    said: Option<String>,
}

pub fn command(conversation: &Conversation, resume: bool, model: Option<&str>, effort: Option<&str>) -> Vec<String> {
    let mut args = vec!["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--include-partial-messages", "--permission-prompt-tool", "stdio"];
    if let Some(thread) = conversation.thread.as_deref() { args.extend([if resume { "--resume" } else { "--session-id" }, thread]) }
    if let Some(model) = model { args.extend(["--model", model]) }
    if let Some(effort) = effort { args.extend(["--effort", effort]) }
    login_shell(&args)
}

/// A fresh conversation id for a new Claude session, a UUID as `--session-id` wants.
pub fn new_session_id() -> String {
    let mut bytes = [0u8; 16];
    if let Ok(mut random) = std::fs::File::open("/dev/urandom") { let _ = std::io::Read::read_exact(&mut random, &mut bytes); }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

fn user(text: &str) -> Value {
    json!({"type": "user", "message": {"role": "user", "content": text}})
}

impl Adapter for Claude {
    fn sent(&mut self, conversation: &Conversation, message: &Value) -> Vec<Change> {
        match message["type"].as_str() {
            Some("user") => {
                let text = message["message"]["content"].as_str().unwrap_or("").to_string();
                let mut changes = vec![Change::Item { item: Item { id: format!("user-{}", conversation.seq + 1), turn: conversation.turn.clone(), kind: ItemKind::User { text }, status: ItemStatus::Done } }];
                if self.queued == 0 {
                    self.turns += 1;
                    changes.push(Change::Status { status: Status::Working, turn: Some(format!("turn-{}", self.turns)), error: None });
                }
                self.queued += 1;
                changes
            }
            Some("control_response") => {
                let id = message["response"]["request_id"].as_str().unwrap_or("");
                if self.requests.remove(id).is_none() { return vec![] }
                vec![Change::Resolved { approval: id.into() }, after_approval(conversation, id)]
            }
            _ => vec![],
        }
    }

    fn receive(&mut self, conversation: &Conversation, message: &Value) -> Effects {
        let mut effects = Effects::default();
        match message["type"].as_str() {
            Some("system") if message["subtype"] == "init" => {
                if let Some(thread) = message["session_id"].as_str() {
                    effects.changes.push(Change::Thread { thread: thread.into(), model: message["model"].as_str().map(Into::into), effort: None });
                }
            }
            Some("stream_event") => self.stream(conversation, message, &mut effects),
            Some("assistant") => self.assistant(conversation, message, &mut effects),
            Some("user") => results(conversation, message, &mut effects),
            Some("control_request") => self.request(conversation, message, &mut effects),
            Some("control_cancel_request") => {
                let id = message["request_id"].as_str().unwrap_or("");
                if self.requests.remove(id).is_some() {
                    effects.changes.push(Change::Resolved { approval: id.into() });
                    effects.changes.push(after_approval(conversation, id));
                }
            }
            Some("result") => self.result(conversation, message, &mut effects),
            // Status lines, thinking-token counts, rate limits: kept in the transcript, not shown.
            _ => {}
        }
        effects
    }

    fn answers(&self, message: &Value) -> Option<(String, Result<Value, String>)> {
        if message["type"] != "control_response" { return None }
        let response = &message["response"];
        let outcome = match response["subtype"].as_str() {
            Some("success") => Ok(response["response"].clone()),
            _ => Err(response["error"].as_str().unwrap_or("Claude refused the request").to_string()),
        };
        Some((response["request_id"].as_str()?.to_string(), outcome))
    }

    fn answer(&self, approval: &Approval, choice: &str) -> Result<Value, String> {
        let (input, suggestions) = self.requests.get(&approval.id).ok_or_else(|| format!("Claude isn't waiting on \"{}\" any more", approval.title))?;
        let response = match choice {
            "allow" => json!({"behavior": "allow", "updatedInput": input}),
            "always" | "session" => json!({"behavior": "allow", "updatedInput": input, "updatedPermissions": suggestions}),
            "deny" => json!({"behavior": "deny", "message": "Denied in Zero"}),
            "stop" => json!({"behavior": "deny", "message": "Denied in Zero", "interrupt": true}),
            other => return Err(format!("No choice {other}")),
        };
        Ok(json!({"type": "control_response", "response": {"subtype": "success", "request_id": approval.id, "response": response}}))
    }

    fn ended(&mut self) {
        self.requests.clear();
        self.queued = 0;
        self.said = None;
    }
}

impl Claude {
    /// Text as it streams in: a block starts an item, its deltas grow it, and the finished message replaces it.
    fn stream(&mut self, conversation: &Conversation, message: &Value, effects: &mut Effects) {
        let event = &message["event"];
        let Some(msg) = message["api_message_id"].as_str() else { return };
        let index = event["index"].as_u64().unwrap_or(0);
        match event["type"].as_str() {
            Some("content_block_start") if event["content_block"]["type"] == "text" => {
                let count = self.streamed.entry(msg.into()).or_insert(0);
                let id = format!("{msg}:{count}");
                *count += 1;
                self.blocks.insert((msg.into(), index), id.clone());
                let kind = ItemKind::Agent { text: String::new(), final_answer: false };
                effects.changes.push(Change::Item { item: Item { id: id.clone(), turn: conversation.turn.clone(), kind, status: ItemStatus::Running } });
                self.said = Some(id);
            }
            Some("content_block_delta") if event["delta"]["type"] == "text_delta" => {
                if let (Some(id), Some(text)) = (self.blocks.get(&(msg.into(), index)), event["delta"]["text"].as_str()) {
                    effects.changes.push(Change::Delta { item: id.clone(), text: text.into() });
                }
            }
            _ => {}
        }
    }

    /// A finished message from Claude, one content block at a time: what it said, thought, or used a tool for.
    fn assistant(&mut self, conversation: &Conversation, message: &Value, effects: &mut Effects) {
        let msg = message["message"]["id"].as_str().unwrap_or("message").to_string();
        let turn = conversation.turn.clone();
        for block in message["message"]["content"].as_array().cloned().unwrap_or_default() {
            let (id, kind, status) = match block["type"].as_str() {
                Some("text") => {
                    let count = self.finished.entry(msg.clone()).or_insert(0);
                    let id = format!("{msg}:{count}");
                    *count += 1;
                    self.said = Some(id.clone());
                    (id, ItemKind::Agent { text: block["text"].as_str().unwrap_or("").into(), final_answer: false }, ItemStatus::Done)
                }
                // Claude's thinking comes back empty unless it is set to show it; empty says nothing.
                Some("thinking") => match block["thinking"].as_str().filter(|t| !t.is_empty()) {
                    Some(text) => (format!("{msg}:thinking"), ItemKind::Reasoning { text: text.into() }, ItemStatus::Done),
                    None => continue,
                },
                Some("tool_use") => (block["id"].as_str().unwrap_or("tool").into(), tool(conversation, &block["name"], &block["input"]), ItemStatus::Running),
                _ => continue,
            };
            effects.changes.push(Change::Item { item: Item { id, turn: turn.clone(), kind, status } });
        }
    }

    fn request(&mut self, conversation: &Conversation, message: &Value, effects: &mut Effects) {
        let request = &message["request"];
        let id = message["request_id"].as_str().unwrap_or("").to_string();
        if request["subtype"] != "can_use_tool" {
            let subtype = request["subtype"].as_str().unwrap_or("request");
            effects.notice(conversation, &format!("Claude asked something Zero can't answer yet ({subtype}), so it was refused"), true);
            effects.replies.push(json!({"type": "control_response", "response": {"subtype": "error", "request_id": id, "error": format!("Zero can't answer {subtype} yet")}}));
            return;
        }
        let (name, input) = (request["tool_name"].as_str().unwrap_or("a tool"), &request["input"]);
        let reason = request["description"].as_str().or(input["description"].as_str()).map(String::from);
        let (kind, title, command, cwd, changes) = match tool(conversation, &request["tool_name"], input) {
            ItemKind::Command { command, cwd, .. } => (ApprovalKind::Command, format!("Run {command}"), Some(command), Some(cwd), vec![]),
            ItemKind::FileChange { changes } => {
                let title = if name == "Write" { format!("Write {}", basename(&changes[0].path)) } else { file_title(&changes) };
                (ApprovalKind::FileChange, title, None, None, changes)
            }
            _ => (ApprovalKind::Tool, format!("Use {}", request["display_name"].as_str().unwrap_or(name)), None, None, vec![]),
        };
        let suggestions = request["permission_suggestions"].clone();
        let mut choices = vec![Choice { id: "allow".into(), label: "Allow".into(), kind: ChoiceKind::Allow }];
        if let Some(choice) = remember(&suggestions) { choices.push(choice) }
        choices.push(Choice { id: "deny".into(), label: "Deny".into(), kind: ChoiceKind::Deny });
        choices.push(Choice { id: "stop".into(), label: "Deny and stop".into(), kind: ChoiceKind::Stop });
        self.requests.insert(id.clone(), (input.clone(), suggestions));
        let approval = Approval { id, item: request["tool_use_id"].as_str().map(Into::into), kind, title, command, cwd, reason, changes, choices };
        effects.changes.push(Change::Approval { approval });
        effects.changes.push(Change::Status { status: Status::Waiting, turn: conversation.turn.clone(), error: conversation.error.clone() });
    }

    /// The end of a turn: its last words become its answer, and the session is idle unless a message waits.
    fn result(&mut self, conversation: &Conversation, message: &Value, effects: &mut Effects) {
        self.queued = self.queued.saturating_sub(1);
        let mut error = None;
        if message["is_error"] == true || message["subtype"] != "success" {
            let text = message["result"].as_str().or(message["subtype"].as_str()).unwrap_or("The turn failed").to_string();
            effects.notice(conversation, &text, true);
            error = Some(text);
        }
        if let Some(id) = self.said.take() && let Some(mut item) = conversation.item(&id).cloned() {
            if let ItemKind::Agent { final_answer, .. } = &mut item.kind { *final_answer = true }
            item.status = ItemStatus::Done;
            effects.changes.push(Change::Item { item });
        }
        let (status, turn) = if self.queued == 0 { (Status::Idle, None) } else {
            self.turns += 1;
            (Status::Working, Some(format!("turn-{}", self.turns)))
        };
        effects.changes.push(Change::Status { status, turn, error });
    }
}

/// Tool results, which Claude sends back as a user message: each fills in the item of the tool it answers.
fn results(conversation: &Conversation, message: &Value, effects: &mut Effects) {
    let outcome = &message["tool_use_result"];
    for block in message["message"]["content"].as_array().cloned().unwrap_or_default() {
        if block["type"] != "tool_result" { continue }
        let Some(mut item) = block["tool_use_id"].as_str().and_then(|id| conversation.item(id)).cloned() else { continue };
        item.status = if block["is_error"] == true { ItemStatus::Failed } else { ItemStatus::Done };
        match &mut item.kind {
            ItemKind::Command { output, .. } => {
                *output = match outcome["stdout"].as_str() {
                    // Claude's "(Bash completed with no output)" is its note to itself, not output.
                    Some(stdout) => [stdout, outcome["stderr"].as_str().unwrap_or("")].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join("\n"),
                    None => text(&block["content"]),
                };
            }
            ItemKind::FileChange { changes } => {
                if let (Some(kind), Some(first)) = (outcome["type"].as_str(), changes.first_mut()) {
                    first.kind = if kind == "create" { "add".into() } else { "update".into() };
                }
            }
            _ => {}
        }
        effects.changes.push(Change::Item { item });
    }
}

/// What a tool call is in Zero's terms: a command, a change to files, or another tool.
fn tool(conversation: &Conversation, name: &Value, input: &Value) -> ItemKind {
    let field = |key: &str| input[key].as_str().unwrap_or("").to_string();
    match name.as_str().unwrap_or("") {
        "Bash" => ItemKind::Command { command: field("command"), cwd: conversation.cwd.clone(), output: String::new(), exit_code: None, duration_ms: None },
        "Write" => ItemKind::FileChange { changes: vec![FileChange { path: field("file_path"), kind: "add".into(), move_path: None, diff: field("content") }] },
        "Edit" => ItemKind::FileChange { changes: vec![FileChange { path: field("file_path"), kind: "update".into(), move_path: None, diff: replaced(&field("old_string"), &field("new_string")) }] },
        "MultiEdit" => {
            let diff = input["edits"].as_array().cloned().unwrap_or_default().iter()
                .map(|edit| replaced(edit["old_string"].as_str().unwrap_or(""), edit["new_string"].as_str().unwrap_or(""))).collect();
            ItemKind::FileChange { changes: vec![FileChange { path: field("file_path"), kind: "update".into(), move_path: None, diff }] }
        }
        other => {
            let detail = ["file_path", "pattern", "url", "query", "description", "notebook_path"].iter().find_map(|key| input[key].as_str()).map(String::from)
                .unwrap_or_else(|| input.to_string());
            ItemKind::Tool { name: other.into(), detail }
        }
    }
}

/// `old` replaced by `new`, as diff lines.
fn replaced(old: &str, new: &str) -> String {
    let mut diff = String::new();
    for line in old.lines() { diff += &format!("-{line}\n") }
    for line in new.lines() { diff += &format!("+{line}\n") }
    diff
}

/// The choice that keeps Claude's suggested rule: rules to allow from now on, or a mode for this session.
fn remember(suggestions: &Value) -> Option<Choice> {
    let suggestions = suggestions.as_array().filter(|s| !s.is_empty())?;
    let rules: Vec<String> = suggestions.iter().filter(|s| s["type"] == "addRules" && s["behavior"] == "allow")
        .flat_map(|s| s["rules"].as_array().cloned().unwrap_or_default())
        .map(|rule| match rule["ruleContent"].as_str() {
            Some(content) => format!("{}({content})", rule["toolName"].as_str().unwrap_or("")),
            None => rule["toolName"].as_str().unwrap_or("").to_string(),
        }).collect();
    if !rules.is_empty() { return Some(Choice { id: "always".into(), label: format!("Always allow {}", rules.join(", ")), kind: ChoiceKind::AllowAlways }) }
    if suggestions.iter().any(|s| s["type"] == "setMode" && s["mode"] == "acceptEdits") {
        return Some(Choice { id: "session".into(), label: "Allow all edits this session".into(), kind: ChoiceKind::AllowSession });
    }
    Some(Choice { id: "always".into(), label: "Always allow".into(), kind: ChoiceKind::AllowAlways })
}

fn text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts.iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("\n"),
        _ => String::new(),
    }
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

// The session's side: what Zero says to Claude, in order.

/// Claude's process was started with the model and effort; it waits for its first message.
pub async fn start(session: &Session, transport: Transport, prompt: &str) -> Result<(), String> {
    session.attach(transport);
    session.write(user(prompt))
}

/// Started again with `--resume`, it is the same conversation, waiting for the next message.
pub async fn resume(session: &Session, transport: Transport) -> Result<(), String> {
    session.attach(transport);
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    Ok(())
}

/// A message: Claude takes it now or queues it behind the turn in progress. A new model switches first; effort
/// is set at start (`--effort`) and stays.
pub async fn send(session: &Session, text: &str, model: Option<&str>) -> Result<(), String> {
    if let Some(model) = model && session.snapshot().model.as_deref() != Some(model) {
        session.request(|id| json!({"type": "control_request", "request_id": id, "request": {"subtype": "set_model", "model": model}})).await?;
        let thread = session.snapshot().thread.unwrap_or_default();
        session.change(Change::Thread { thread, model: Some(model.into()), effort: None });
    }
    session.write(user(text))
}

pub async fn interrupt(session: &Session) -> Result<(), String> {
    if session.snapshot().turn.is_none() { return Err("Nothing is running to interrupt".into()) }
    session.request(|id| json!({"type": "control_request", "request_id": id, "request": {"subtype": "interrupt"}})).await.map(|_| ())
}

#[cfg(test)]
mod tests {
    #[test]
    fn session_ids_are_version_4_uuids() {
        let id = super::new_session_id();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        assert!("89ab".contains(&id[19..20]));
        assert_ne!(id, super::new_session_id());
    }
}
