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
            ItemKind::User { text, .. } => chain.add("user", json!(text)),
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
            // As a call, never as words: an agent reading "Used zero_ask: {…}" in its own past replies writes its
            // next calls that way too, and nothing runs. Zero keeps a call's input, not its result.
            ItemKind::Tool { name, detail } => {
                chain.calls += 1;
                let call = format!("toolu_zero_{}", chain.calls);
                let input = serde_json::from_str::<Value>(detail).ok().filter(Value::is_object).unwrap_or_else(|| json!({"detail": detail}));
                chain.add("assistant", json!([{"type": "tool_use", "id": call, "name": name, "input": input}]));
                chain.add("user", json!([{"type": "tool_result", "tool_use_id": call, "content": "Its result isn't in Zero's record.", "is_error": false}]));
            }
            ItemKind::Agent { .. } | ItemKind::Reasoning { .. } | ItemKind::Notice { .. } | ItemKind::Table { .. } => {}
        }
    }
    chain.lines.iter().map(|line| line.to_string() + "\n").collect()
}

/// The conversation as plain text, for a provider that can't be handed one (OpenCode): what each said, and the
/// commands run, in order.
pub fn context(conversation: &Conversation) -> String {
    let lines: Vec<String> = conversation.items.iter().filter_map(|item| match &item.kind {
        ItemKind::User { text, .. } => Some(format!("User: {text}")),
        ItemKind::Agent { text, .. } if !text.trim().is_empty() => Some(format!("You: {text}")),
        ItemKind::Command { command, .. } => Some(format!("You ran: {command}")),
        _ => None,
    }).collect();
    format!("This conversation goes on from an earlier session; here is what was said before, for context. Carry on from it.\n\n{}", lines.join("\n\n"))
}

/// What a stretch of Claude Code's session file says, as the task's items: what was typed, said and run. Its own
/// bookkeeping (meta messages, slash-command echoes, system records) and its thinking stay out; each turn's last words
/// are its answer.
pub fn from_claude_session(records: &[Value]) -> Vec<Item> {
    let mut items: Vec<Item> = vec![];
    for record in records {
        let uuid = record["uuid"].as_str().unwrap_or("");
        if record["isMeta"] == true { continue }
        let before = items.len();
        let content = &record["message"]["content"];
        match (record["type"].as_str(), content) {
            (Some("user"), Value::String(text)) if !text.starts_with('<') => items.push(item(uuid, 0, ItemKind::User { text: text.clone(), images: vec![] })),
            (Some("user"), Value::Array(blocks)) => {
                for (n, block) in blocks.iter().enumerate() {
                    match block["type"].as_str() {
                        Some("text") if !block["text"].as_str().unwrap_or("").starts_with('<') =>
                            items.push(item(uuid, n, ItemKind::User { text: block["text"].as_str().unwrap_or("").into(), images: vec![] })),
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
        stamp_from(record, &mut items, before);
    }
    answers(&mut items);
    items
}

/// The last thing the agent said before you spoke again (or at the end) was its answer.
fn answers(items: &mut [Item]) {
    let mut answered = false;
    for item in items.iter_mut().rev() {
        match &mut item.kind {
            ItemKind::User { .. } => answered = false,
            ItemKind::Agent { final_answer, .. } if !answered => { *final_answer = true; answered = true }
            _ => {}
        }
    }
}

/// A Codex session's rollout file (`~/.codex/sessions/…/rollout-…-<id>.jsonl`) as the task's folder and items: its
/// completed items, what was typed, said and run. Its reasoning and bookkeeping stay out.
pub fn from_codex_rollout(records: &[Value]) -> Option<(String, Vec<Item>)> {
    let cwd = records.iter().find(|r| r["type"] == "session_meta")?["payload"]["cwd"].as_str()?.to_string();
    let mut items = vec![];
    for record in records.iter().filter(|r| r["type"] == "event_msg" && r["payload"]["type"] == "item_completed") {
        let it = &record["payload"]["item"];
        let text = || it["content"].as_array().into_iter().flatten().filter_map(|c| c["text"].as_str()).collect::<Vec<_>>().join("\n");
        let kind = match it["type"].as_str() {
            Some("UserMessage") => ItemKind::User { text: text(), images: vec![] },
            Some("AgentMessage") if !text().trim().is_empty() => ItemKind::Agent { text: text(), final_answer: false },
            Some("CommandExecution") => {
                // The shell's own wrapper (zsh -lc 'the command') left off: the command as it was given.
                let argv: Vec<&str> = it["command"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
                let command = match argv.as_slice() { [_, "-lc" | "-c", command] => command.to_string(), _ => argv.join(" ") };
                let exit_code = it["exit_code"].as_i64().or_else(|| it["exit_code"].as_str()?.parse().ok());
                let duration_ms = it["duration"]["secs"].as_i64().map(|s| s * 1000 + it["duration"]["nanos"].as_i64().unwrap_or(0) / 1_000_000);
                ItemKind::Command { command, cwd: it["cwd"].as_str().unwrap_or("").trim_start_matches("file://").into(),
                                    output: it["aggregated_output"].as_str().unwrap_or("").into(), exit_code, duration_ms }
            }
            Some("McpToolCall") => ItemKind::Tool { name: format!("{}.{}", it["server"].as_str().unwrap_or("mcp"), it["tool"].as_str().unwrap_or("tool")), detail: detail(&it["arguments"]) },
            _ => continue,
        };
        let mut taken = Item { id: format!("codex-{}", it["id"].as_str().unwrap_or("")), turn: None, kind, status: ItemStatus::Done, at: None };
        taken.at = record["timestamp"].as_str().and_then(millis);
        items.push(taken);
    }
    answers(&mut items);
    Some((cwd, items))
}

/// An OpenCode session as `opencode session export` prints it, as the task's folder and items: what was typed, said
/// and run. Its reasoning and OpenCode's own notices (system, idle, model switches) stay out.
pub fn from_opencode_export(export: &Value) -> Option<(String, Vec<Item>)> {
    let cwd = export["info"]["location"]["directory"].as_str().or(export["info"]["directory"].as_str())?.to_string();
    let mut items = vec![];
    for message in export["messages"].as_array().into_iter().flatten() {
        let (id, at) = (message["id"].as_str().unwrap_or(""), message["time"]["created"].as_i64());
        let mut push = |n: usize, kind: ItemKind| items.push(Item { id: format!("opencode-{id}-{n}"), turn: None, kind, status: ItemStatus::Done, at });
        match message["type"].as_str() {
            Some("user") => push(0, ItemKind::User { text: message["text"].as_str().unwrap_or("").into(), images: vec![] }),
            Some("assistant") => for (n, part) in message["content"].as_array().into_iter().flatten().enumerate() {
                let state = &part["state"];
                match (part["type"].as_str(), part["name"].as_str()) {
                    (Some("text"), _) if !part["text"].as_str().unwrap_or("").trim().is_empty() => push(n, ItemKind::Agent { text: part["text"].as_str().unwrap_or("").into(), final_answer: false }),
                    (Some("tool"), Some("bash")) => push(n, ItemKind::Command {
                        command: state["input"]["command"].as_str().unwrap_or("").into(), cwd: String::new(),
                        output: state["content"].as_array().into_iter().flatten().filter_map(|c| c["text"].as_str()).collect::<Vec<_>>().join("\n"),
                        exit_code: None, duration_ms: None }),
                    (Some("tool"), name) => push(n, ItemKind::Tool { name: name.unwrap_or("tool").into(), detail: detail(&state["input"]) }),
                    _ => {}
                }
            },
            _ => {}
        }
    }
    answers(&mut items);
    Some((cwd, items))
}

fn item(uuid: &str, n: usize, kind: ItemKind) -> Item {
    Item { id: format!("claude-{uuid}-{n}"), turn: None, kind, status: ItemStatus::Done, at: None }
}

/// The record's own time ("2026-10-27T12:23:52.151Z") on the items made from it, those from `from` on.
fn stamp_from(record: &Value, items: &mut [Item], from: usize) {
    let Some(at) = record["timestamp"].as_str().and_then(millis) else { return };
    for item in &mut items[from..] { item.at = Some(at) }
}

/// An RFC 3339 UTC time in milliseconds since 1970.
fn millis(text: &str) -> Option<i64> {
    let (date, time) = text.trim_end_matches('Z').split_once('T')?;
    let mut d = date.split('-').map(|p| p.parse::<i64>());
    let (year, month, day) = (d.next()?.ok()?, d.next()?.ok()?, d.next()?.ok()?);
    let (clock, fraction) = time.split_once('.').unwrap_or((time, "0"));
    let mut t = clock.split(':').map(|p| p.parse::<i64>());
    let (hour, minute, second) = (t.next()?.ok()?, t.next()?.ok()?, t.next()?.ok()?);
    let ms: i64 = format!("{fraction:0<3}")[..3].parse().ok()?;
    // Days since 1970 from the civil date (Howard Hinnant's algorithm).
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + ms)
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
