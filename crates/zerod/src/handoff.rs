//! Handing a task from one provider to another. Zero's record of the conversation is the task's history; each provider
//! gets it the way it reads a conversation natively: as a Claude Code session file, which Claude Code resumes and Codex
//! imports (`externalAgentConfig/import`). Messages and commands come along as they happened; reasoning stays with the
//! provider that had it, and notices are Zero's own.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::model::{Conversation, Item, ItemKind, ItemStatus};

/// Where Claude Code keeps a folder's sessions: its path with every character but letters and digits as a dash.
pub fn claude_folder(home: &Path, cwd: &str) -> PathBuf {
    home.join(".claude/projects").join(cwd.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect::<String>())
}

/// The conversation as a Claude Code session file (JSON lines, one chain of messages) with the id `session`.
pub fn claude_session(conversation: &Conversation, session: &str) -> String {
    let mut chain = Chain { session, cwd: &conversation.cwd, parent: None, lines: vec![], calls: 0 };
    for item in &conversation.items {
        match &item.kind {
            ItemKind::User { text } => chain.add("user", json!(text)),
            ItemKind::Agent { text, .. } if !text.trim().is_empty() => chain.text(text),
            ItemKind::Plan { text } => chain.text(&format!("Plan:\n{text}")),
            ItemKind::Command { command, output, exit_code, .. } => {
                chain.calls += 1;
                let call = format!("toolu_zero_{}", chain.calls);
                chain.add("assistant", json!([{"type": "tool_use", "id": call, "name": "Bash", "input": {"command": command}}]));
                let failed = exit_code.is_some_and(|code| code != 0);
                let result = match (output.is_empty(), exit_code) {
                    (true, Some(code)) if failed => format!("Exit code {code}"),
                    (false, Some(code)) if failed => format!("{output}\nExit code {code}"),
                    _ => output.clone(),
                };
                chain.add("user", json!([{"type": "tool_result", "tool_use_id": call, "content": result, "is_error": failed}]));
            }
            ItemKind::FileChange { changes } => {
                for change in changes {
                    chain.text(&format!("Changed {} ({}):\n```diff\n{}```", change.path, change.kind, change.diff));
                }
            }
            ItemKind::Tool { name, detail } => chain.text(&format!("Used {name}: {detail}")),
            ItemKind::Agent { .. } | ItemKind::Reasoning { .. } | ItemKind::Notice { .. } => {}
        }
    }
    chain.lines.iter().map(|line| line.to_string() + "\n").collect()
}

/// What a stretch of Claude Code's session file says, as the task's items: what was typed, said and run. Its own
/// bookkeeping (meta messages, slash-command echoes, system records) and its thinking stay out; each turn's last words
/// are its answer.
pub fn from_claude_session(records: &[Value]) -> Vec<Item> {
    let mut items: Vec<Item> = vec![];
    for record in records {
        let uuid = record["uuid"].as_str().unwrap_or("");
        if record["isMeta"] == true { continue }
        let content = &record["message"]["content"];
        match (record["type"].as_str(), content) {
            (Some("user"), Value::String(text)) if !text.starts_with('<') => items.push(item(uuid, 0, ItemKind::User { text: text.clone() })),
            (Some("user"), Value::Array(blocks)) => {
                for (n, block) in blocks.iter().enumerate() {
                    match block["type"].as_str() {
                        Some("text") if !block["text"].as_str().unwrap_or("").starts_with('<') =>
                            items.push(item(uuid, n, ItemKind::User { text: block["text"].as_str().unwrap_or("").into() })),
                        Some("tool_result") => {
                            let output = match &block["content"] {
                                Value::String(text) => text.clone(),
                                Value::Array(parts) => parts.iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("\n"),
                                _ => String::new(),
                            };
                            let call = format!("claude-call-{}", block["tool_use_id"].as_str().unwrap_or(""));
                            if let Some(ran) = items.iter_mut().find(|i| i.id == call)
                                && let ItemKind::Command { output: out, exit_code, .. } = &mut ran.kind {
                                *out = output;
                                *exit_code = Some(if block["is_error"] == true { 1 } else { 0 });
                            }
                        }
                        _ => {}
                    }
                }
            }
            (Some("assistant"), Value::Array(blocks)) => {
                for (n, block) in blocks.iter().enumerate() {
                    match block["type"].as_str() {
                        Some("text") if !block["text"].as_str().unwrap_or("").trim().is_empty() =>
                            items.push(item(uuid, n, ItemKind::Agent { text: block["text"].as_str().unwrap_or("").into(), final_answer: false })),
                        Some("tool_use") => {
                            let input = &block["input"];
                            let mut used = item(uuid, n, if block["name"] == "Bash" {
                                ItemKind::Command { command: input["command"].as_str().unwrap_or("").into(), cwd: String::new(), output: String::new(), exit_code: None, duration_ms: None }
                            } else {
                                ItemKind::Tool { name: block["name"].as_str().unwrap_or("tool").into(), detail: detail(input) }
                            });
                            used.id = format!("claude-call-{}", block["id"].as_str().unwrap_or(uuid));
                            items.push(used);
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    // The last thing the agent said before you spoke again (or at the end) was its answer.
    let mut answered = false;
    for item in items.iter_mut().rev() {
        match &mut item.kind {
            ItemKind::User { .. } => answered = false,
            ItemKind::Agent { final_answer, .. } if !answered => { *final_answer = true; answered = true }
            _ => {}
        }
    }
    items
}

fn item(uuid: &str, n: usize, kind: ItemKind) -> Item {
    Item { id: format!("claude-{uuid}-{n}"), turn: None, kind, status: ItemStatus::Done }
}

/// What a tool was pointed at: its file, pattern, address or description, else its input in brief.
fn detail(input: &Value) -> String {
    ["file_path", "path", "pattern", "url", "query", "description", "prompt"].iter().find_map(|k| input[*k].as_str()).map(String::from)
        .unwrap_or_else(|| { let text = input.to_string(); text.chars().take(120).collect() })
}

struct Chain<'a> {
    session: &'a str,
    cwd: &'a str,
    parent: Option<String>,
    lines: Vec<Value>,
    calls: usize,
}

impl Chain<'_> {
    fn text(&mut self, text: &str) {
        self.add("assistant", json!([{"type": "text", "text": text}]));
    }

    fn add(&mut self, role: &str, content: Value) {
        let uuid = crate::claude::new_session_id();
        let mut message = json!({"role": role, "content": content});
        if role == "assistant" {
            message["type"] = json!("message");
            message["id"] = json!(format!("msg_zero_{}", self.lines.len()));
            message["model"] = json!("zero-handoff");
            message["stop_reason"] = json!("end_turn");
            message["usage"] = json!({"input_tokens": 0, "output_tokens": 0});
        }
        self.lines.push(json!({
            "type": role, "uuid": uuid, "parentUuid": self.parent, "sessionId": self.session, "cwd": self.cwd,
            "isSidechain": false, "userType": "external", "timestamp": crate::ask::Time::now().iso(), "message": message,
        }));
        self.parent = Some(uuid);
    }
}
