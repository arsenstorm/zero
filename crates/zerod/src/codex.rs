//! Codex through `codex app-server`: JSON-RPC 2.0, one object per line. The protocol's types come from `codex
//! app-server generate-ts`; docs/workspace.md says which version this was written against.

use std::collections::HashMap;

use serde_json::{Value, json};

use crate::adapter::{Adapter, Answers, Effects, INSTRUCTIONS, json_rpc_answer, key};
use crate::model::{Approval, ApprovalKind, Change, Choice, ChoiceKind, Conversation, Field, FileChange, Item, ItemKind, ItemStatus, Permissions, Question,
                   QuestionOption, Status};
use crate::session::{Session, Transport};

/// The approval policy and sandbox for a session's permissions. Auto is Codex's own "auto": edit and run in the
/// project, ask for anything beyond it; unrestricted is its "full access".
pub fn policy(permissions: Permissions) -> (&'static str, &'static str) {
    match permissions {
        Permissions::Auto => ("on-request", "workspace-write"),
        Permissions::Unrestricted => ("never", "danger-full-access"),
    }
}

#[derive(Default)]
pub struct Codex {
    /// Zero's requests waiting for an answer: id → method.
    pending: HashMap<String, String>,
    /// Codex's requests waiting for Zero: approval id → the JSON-RPC id to answer, and each choice's decision.
    requests: HashMap<String, (Value, Vec<Value>)>,
}

impl Adapter for Codex {
    fn sent(&mut self, _: &Conversation, message: &Value) -> Vec<Change> {
        if let (Some(id), Some(method)) = (message.get("id"), message["method"].as_str()) {
            self.pending.insert(key(id), method.into());
        }
        vec![]
    }

    fn receive(&mut self, conversation: &Conversation, message: &Value) -> Effects {
        let mut effects = Effects::default();
        match (message.get("id"), message["method"].as_str()) {
            (Some(id), Some(method)) => self.request(conversation, id, method, &message["params"], &mut effects),
            (Some(id), None) => self.response(conversation, id, message, &mut effects),
            (None, Some(method)) => notification(conversation, method, &message["params"], &mut effects),
            (None, None) => {}
        }
        effects
    }

    fn answers(&self, message: &Value) -> Option<(String, Result<Value, String>)> {
        json_rpc_answer(message)
    }

    fn answer(&self, approval: &Approval, choice: &str) -> Result<Value, String> {
        let (id, decisions) = self.requests.get(&approval.id).ok_or_else(|| format!("Codex isn't waiting on \"{}\" any more", approval.title))?;
        let decision = choice.parse::<usize>().ok().and_then(|i| decisions.get(i)).ok_or_else(|| format!("No choice {choice}"))?;
        Ok(json!({"id": id, "result": {"decision": decision}}))
    }

    fn reply(&self, question: &Question, answers: &Answers) -> Result<Value, String> {
        let (id, _) = self.requests.get(&question.id).ok_or("Codex isn't waiting on that question any more")?;
        let answers: serde_json::Map<String, Value> = question.fields.iter().map(|f| (f.id.clone(), json!({"answers": answers[&f.id]}))).collect();
        Ok(json!({"id": id, "result": {"answers": answers}}))
    }

    fn ended(&mut self) {
        self.pending.clear();
        self.requests.clear();
    }
}

impl Codex {
    fn response(&mut self, conversation: &Conversation, id: &Value, message: &Value, effects: &mut Effects) {
        let Some(method) = self.pending.remove(&key(id)) else { return };
        if let Some(error) = message.get("error") {
            effects.fail(conversation, &format!("{method} failed: {}", error["message"].as_str().unwrap_or("no reason given")));
            return;
        }
        let result = &message["result"];
        if (method == "thread/start" || method == "thread/resume") && let Some(thread) = result["thread"]["id"].as_str() {
            effects.changes.push(Change::Thread {
                thread: thread.into(),
                model: result["model"].as_str().map(Into::into),
                effort: result["reasoningEffort"].as_str().map(Into::into),
            });
            if let Some(name) = result["thread"]["name"].as_str() { effects.changes.push(Change::Title { title: Some(name.into()) }) }
            // A new thread is still starting until its first turn does; a resumed one is waiting for the next.
            if method == "thread/resume" && matches!(conversation.status, Status::Starting | Status::Offline) {
                effects.changes.push(Change::Status { status: Status::Idle, turn: None, error: None });
            }
        }
    }

    fn request(&mut self, conversation: &Conversation, id: &Value, method: &str, params: &Value, effects: &mut Effects) {
        let (kind, title, command, cwd, changes) = match method {
            "item/commandExecution/requestApproval" => {
                let command = actions(params).or_else(|| params["command"].as_str().map(unwrap_shell)).unwrap_or_default();
                (ApprovalKind::Command, format!("Run {command}"), Some(command), params["cwd"].as_str().map(Into::into), vec![])
            }
            "item/fileChange/requestApproval" => {
                let changes = match params["itemId"].as_str().and_then(|item| conversation.item(item)).map(|item| &item.kind) {
                    Some(ItemKind::FileChange { changes }) => changes.clone(),
                    _ => vec![],
                };
                (ApprovalKind::FileChange, file_title(&changes), None, None, changes)
            }
            "item/tool/requestUserInput" => {
                let fields = params["questions"].as_array().cloned().unwrap_or_default().iter().map(|q| Field {
                    id: q["id"].as_str().unwrap_or("").into(),
                    header: q["header"].as_str().filter(|h| !h.is_empty()).map(String::from),
                    question: q["question"].as_str().unwrap_or("").into(),
                    options: q["options"].as_array().cloned().unwrap_or_default().iter().map(|o| QuestionOption {
                        label: o["label"].as_str().unwrap_or("").into(),
                        description: o["description"].as_str().filter(|d| !d.is_empty()).map(String::from),
                    }).collect(),
                    multiple: false,
                    other: q["isOther"] == true,
                    secret: q["isSecret"] == true,
                }).collect();
                self.requests.insert(key(id), (id.clone(), vec![]));
                effects.changes.push(Change::Question { question: Question { id: key(id), item: params["itemId"].as_str().map(Into::into), fields } });
                effects.changes.push(Change::Status { status: Status::Waiting, turn: conversation.turn.clone(), error: conversation.error.clone() });
                return;
            }
            _ => {
                // ponytail: MCP elicitations and the rest are refused for now, so Codex
                // never waits on something no one is shown; they become Zero questions next (docs/workspace.md).
                effects.notice(conversation, &format!("Codex asked something Zero can't answer yet ({method}), so it was refused"), true);
                effects.replies.push(json!({"id": id, "error": {"code": -32601, "message": format!("Zero can't answer {method} yet")}}));
                return;
            }
        };
        let (choices, decisions): (Vec<Choice>, Vec<Value>) = offered(&params["availableDecisions"]).into_iter().unzip();
        let approval = Approval {
            id: key(id), item: params["itemId"].as_str().map(Into::into), kind, title, command, cwd,
            reason: params["reason"].as_str().map(Into::into), changes, choices,
        };
        self.requests.insert(approval.id.clone(), (id.clone(), decisions));
        effects.changes.push(Change::Approval { approval });
    }
}

fn notification(conversation: &Conversation, method: &str, params: &Value, effects: &mut Effects) {
    let turn = params["turnId"].as_str();
    match method {
        "thread/started" => {
            if let Some(name) = params["thread"]["name"].as_str() { effects.changes.push(Change::Title { title: Some(name.into()) }) }
        }
        "thread/name/updated" => effects.changes.push(Change::Title { title: params["threadName"].as_str().map(Into::into) }),
        "thread/status/changed" => {
            let flags = params["status"]["activeFlags"].as_array();
            let status = match params["status"]["type"].as_str() {
                Some("idle") | Some("systemError") => Status::Idle,
                Some("notLoaded") => Status::Offline,
                Some("active") if flags.is_some_and(|f| f.iter().any(|f| f == "waitingOnApproval")) => Status::Waiting,
                Some("active") => Status::Working,
                _ => return,
            };
            let error = if params["status"]["type"] == "systemError" { Some("Codex had a system error".into()) } else { conversation.error.clone() };
            effects.changes.push(Change::Status { status, turn: conversation.turn.clone(), error });
        }
        "turn/started" => effects.changes.push(Change::Status { status: Status::Working, turn: params["turn"]["id"].as_str().map(Into::into), error: None }),
        "turn/completed" => {
            let finished = &params["turn"];
            let mut error = None;
            match finished["status"].as_str() {
                Some("failed") => {
                    let text = finished["error"]["message"].as_str().unwrap_or("The turn failed").to_string();
                    effects.notice(conversation, &text, true);
                    error = Some(text);
                }
                Some("interrupted") => effects.notice(conversation, "Interrupted", false),
                _ => {}
            }
            effects.changes.push(Change::Status { status: Status::Idle, turn: None, error });
        }
        "item/started" | "item/completed" => {
            if let Some(item) = item(&params["item"], turn) { effects.changes.push(Change::Item { item }) }
        }
        "item/agentMessage/delta" | "item/plan/delta" | "item/commandExecution/outputDelta" | "item/reasoning/summaryTextDelta" => {
            let (Some(item), Some(text)) = (params["itemId"].as_str(), params["delta"].as_str()) else { return };
            // Reasoning only becomes an item once it says something.
            if method == "item/reasoning/summaryTextDelta" && conversation.item(item).is_none() {
                let kind = ItemKind::Reasoning { text: String::new() };
                effects.changes.push(Change::Item { item: Item { at: None, id: item.into(), turn: turn.map(Into::into), kind, status: ItemStatus::Running } });
            }
            effects.changes.push(Change::Delta { item: item.into(), text: text.into() });
        }
        "turn/diff/updated" => effects.changes.push(Change::Diff { diff: params["diff"].as_str().map(Into::into) }),
        "turn/plan/updated" => {
            let steps = params["plan"].as_array().cloned().unwrap_or_default();
            let text = steps.iter().map(|step| {
                let mark = if step["status"] == "completed" { "[x]" } else { "[ ]" };
                format!("- {mark} {}", step["step"].as_str().unwrap_or(""))
            }).collect::<Vec<_>>().join("\n");
            let id = format!("plan-{}", turn.unwrap_or("turn"));
            effects.changes.push(Change::Item { item: Item { at: None, id, turn: turn.map(Into::into), kind: ItemKind::Plan { text }, status: ItemStatus::Running } });
        }
        "error" => {
            let retrying = params["willRetry"].as_bool() == Some(true);
            let message = params["error"]["message"].as_str().unwrap_or("Codex reported an error");
            let text = if retrying { format!("{message} (retrying)") } else { message.to_string() };
            effects.notice(conversation, &text, !retrying);
        }
        "account/rateLimits/updated" => {
            let limits = &params["rateLimits"];
            let windows: Vec<crate::model::UsageWindow> = ["primary", "secondary"].iter().filter_map(|key| {
                let window = limits.get(*key).filter(|w| w.is_object())?;
                let minutes = window["windowDurationMins"].as_i64().unwrap_or(0);
                let name = match minutes { 300 => "5 hours".into(), 10080 => "7 days".into(), m if m % 1440 == 0 => format!("{} days", m / 1440), m => format!("{} hours", m / 60) };
                Some(crate::model::UsageWindow { name, used: window["usedPercent"].as_f64().unwrap_or(0.0) / 100.0, resets_at: window["resetsAt"].as_i64() })
            }).collect();
            let full = windows.iter().find(|w| w.used >= 1.0);
            let usage = crate::model::Usage { limited: full.is_some(), resets_at: full.and_then(|w| w.resets_at), windows };
            effects.changes.push(Change::Usage { usage });
        }
        "serverRequest/resolved" => {
            let settled = key(&params["requestId"]);
            if conversation.approvals.iter().any(|a| a.id == settled) { effects.changes.push(Change::Resolved { approval: settled }) }
            else if conversation.questions.iter().any(|q| q.id == settled) { effects.changes.push(Change::Answered { question: settled }) }
        }
        // Hooks, MCP start-up, token use, rate limits and the rest: kept in the transcript, not shown.
        _ => {}
    }
}

/// The items of the turns Zero doesn't know yet (those run in Codex's own terminal), from `thread/read`'s turns.
pub fn new_turn_items(turns: &Value, known: &std::collections::HashSet<String>) -> Vec<Item> {
    turns.as_array().into_iter().flatten()
        .filter(|turn| turn["id"].as_str().is_some_and(|id| !known.contains(id)))
        .flat_map(|turn| turn["items"].as_array().into_iter().flatten().filter_map(|value| item(value, turn["id"].as_str())).collect::<Vec<_>>())
        .collect()
}

/// After Codex's own terminal had the thread: its turns there join the task's record.
pub async fn catch_up(session: &Session) -> Result<(), String> {
    let conversation = session.snapshot();
    let thread = conversation.thread.clone().ok_or("Codex has no thread to read")?;
    let read = session.request(|id| json!({"id": id, "method": "thread/read", "params": {"threadId": thread, "includeTurns": true}})).await?;
    let known: std::collections::HashSet<String> = conversation.items.iter().filter_map(|i| i.turn.clone()).collect();
    for item in new_turn_items(&read["thread"]["turns"], &known) { session.change(Change::Item { item }) }
    Ok(())
}

fn item(value: &Value, turn: Option<&str>) -> Option<Item> {
    let id = value["id"].as_str()?.to_string();
    let text = |field: &str| value[field].as_str().unwrap_or("").to_string();
    let status = |field: &str| match value[field].as_str() {
        Some("inProgress") => ItemStatus::Running,
        Some("failed") => ItemStatus::Failed,
        Some("declined") => ItemStatus::Declined,
        _ => ItemStatus::Done,
    };
    let (kind, state) = match value["type"].as_str()? {
        "userMessage" => {
            let parts = value["content"].as_array().cloned().unwrap_or_default();
            let text = parts.iter().map(|part| match part["type"].as_str() {
                Some("text") => part["text"].as_str().unwrap_or("").to_string(),
                Some(other) => format!("[{other}]"),
                None => String::new(),
            }).collect::<Vec<_>>().join("\n");
            (ItemKind::User { text, images: vec![] }, ItemStatus::Done)
        }
        "agentMessage" => {
            // Started with no text yet, it is still being written.
            let state = if text("text").is_empty() { ItemStatus::Running } else { ItemStatus::Done };
            (ItemKind::Agent { text: text("text"), final_answer: value["phase"] == "final_answer" }, state)
        }
        "reasoning" => {
            let summary = value["summary"].as_array().map(|parts| parts.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("\n\n")).unwrap_or_default();
            if summary.is_empty() { return None }
            (ItemKind::Reasoning { text: summary }, ItemStatus::Done)
        }
        "plan" => (ItemKind::Plan { text: text("text") }, ItemStatus::Done),
        "commandExecution" => {
            let kind = ItemKind::Command {
                command: actions(value).unwrap_or_else(|| unwrap_shell(&text("command"))), cwd: text("cwd"),
                output: text("aggregatedOutput"), exit_code: value["exitCode"].as_i64(), duration_ms: value["durationMs"].as_i64(),
            };
            (kind, status("status"))
        }
        "fileChange" => {
            let changes = value["changes"].as_array().cloned().unwrap_or_default().iter().map(|change| FileChange {
                path: change["path"].as_str().unwrap_or("").into(),
                kind: change["kind"]["type"].as_str().unwrap_or("update").into(),
                move_path: change["kind"]["move_path"].as_str().map(Into::into),
                diff: change["diff"].as_str().unwrap_or("").into(),
            }).collect();
            (ItemKind::FileChange { changes }, status("status"))
        }
        "mcpToolCall" => (ItemKind::Tool { name: format!("{}.{}", text("server"), text("tool")), detail: value["arguments"].to_string() }, status("status")),
        "dynamicToolCall" => (ItemKind::Tool { name: text("tool"), detail: value["arguments"].to_string() }, status("status")),
        "webSearch" => (ItemKind::Tool { name: "Web search".into(), detail: text("query") }, ItemStatus::Done),
        "imageView" => (ItemKind::Tool { name: "View image".into(), detail: text("path") }, ItemStatus::Done),
        "contextCompaction" => (ItemKind::Notice { text: "Context compacted".into(), error: false }, ItemStatus::Done),
        // Codex's own bookkeeping: in the transcript, nothing to read.
        "hookPrompt" | "functionCallOutput" => return None,
        other => (ItemKind::Notice { text: format!("Codex {other} (not shown in Zero yet)"), error: false }, ItemStatus::Done),
    };
    Some(Item { at: None, id, turn: turn.map(Into::into), kind, status: state })
}

/// The commands Codex parsed out of a command line, which read better than the line it wraps them in.
fn actions(value: &Value) -> Option<String> {
    let actions = value["commandActions"].as_array().filter(|a| !a.is_empty())?;
    Some(actions.iter().filter_map(|a| a["command"].as_str()).collect::<Vec<_>>().join(" && "))
}

/// "Add hello.txt", "Edit main.rs", "Edit 3 files".
pub fn file_title(changes: &[FileChange]) -> String {
    match changes {
        [] => "Change files".into(),
        [one] => {
            let verb = match one.kind.as_str() { "add" => "Add", "delete" => "Delete", _ => "Edit" };
            format!("{verb} {}", one.path.rsplit('/').next().unwrap_or(&one.path))
        }
        many => format!("Edit {} files", many.len()),
    }
}

/// Codex's decisions for a request, each as a choice: what it offers, in its order. Without a list, everything a
/// file approval takes; network-policy amendments and decisions newer than this build are left out.
fn offered(available: &Value) -> Vec<(Choice, Value)> {
    let fallback = json!(["accept", "acceptForSession", "decline", "cancel"]);
    let list = available.as_array().unwrap_or_else(|| fallback.as_array().unwrap());
    list.iter().filter_map(|decision| {
        let (label, kind) = match decision {
            Value::String(name) => match name.as_str() {
                "accept" => ("Allow".to_string(), ChoiceKind::Allow),
                "acceptForSession" => ("Allow for this session".into(), ChoiceKind::AllowSession),
                "decline" => ("Deny".into(), ChoiceKind::Deny),
                "cancel" => ("Deny and stop".into(), ChoiceKind::Stop),
                _ => return None,
            },
            Value::Object(fields) => {
                let rule = fields.get("acceptWithExecpolicyAmendment")?["execpolicy_amendment"].as_array()?;
                let words: Vec<&str> = rule.iter().filter_map(Value::as_str).collect();
                (format!("Always allow {}", words.join(" ")), ChoiceKind::AllowAlways)
            }
            _ => return None,
        };
        Some((label, kind, decision.clone()))
    }).enumerate().map(|(i, (label, kind, decision))| (Choice { id: i.to_string(), label, kind }, decision)).collect()
}

/// `/bin/zsh -lc 'ls -la'` reads `ls -la`: the shell Codex wraps commands in isn't what the agent asked for.
fn unwrap_shell(command: &str) -> String {
    for shell in ["/bin/zsh -lc '", "/bin/bash -lc '", "/bin/sh -lc '", "bash -lc '", "zsh -lc '"] {
        if let Some(inner) = command.strip_prefix(shell).and_then(|rest| rest.strip_suffix('\'')) {
            return inner.into();
        }
    }
    command.into()
}

/// Your words as Codex's turn input, each image as its file where its token stands (images.rs).
pub fn input(text: &str, images: &[String]) -> Value {
    if images.is_empty() { return json!([{"type": "text", "text": text, "text_elements": []}]) }
    let parts: Vec<Value> = crate::images::parts(text, images).into_iter().map(|part| match part {
        crate::images::Part::Text(text) => json!({"type": "text", "text": text, "text_elements": []}),
        crate::images::Part::Image(path) => json!({"type": "localImage", "path": path}),
    }).collect();
    Value::Array(parts)
}

// The session's side: what Zero says to Codex, in order.

pub async fn start(session: &Session, transport: Transport, prompt: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
    handshake(session, transport).await?;
    let conversation = session.snapshot();
    let (approvals, sandbox) = policy(conversation.permissions);
    let mut params = json!({"cwd": conversation.cwd, "model": model, "approvalPolicy": approvals, "sandbox": sandbox, "developerInstructions": INSTRUCTIONS});
    if !conversation.mcp.is_empty() { params["config"] = mcp_config(&conversation.mcp) }
    session.request(|id| json!({"id": id, "method": "thread/start", "params": params})).await?;
    let thread = session.snapshot().thread.ok_or("Codex started no thread")?;
    turn(session, &thread, input(prompt, images), model, effort).await
}

/// ponytail: the turns aren't fetched, since the transcript already has them; a thread also used from another
/// Codex client since misses those turns until `thread/turns/list` hydration is added.
pub async fn resume(session: &Session, transport: Transport) -> Result<(), String> {
    let conversation = session.snapshot();
    if conversation.thread.is_none() && conversation.items.is_empty() {
        return Err("This session never got as far as a thread, so there is nothing to resume".into());
    }
    handshake(session, transport).await?;
    // Taken over from another provider: Codex imports the conversation as a thread of its own.
    let thread = match conversation.thread.clone() {
        Some(thread) => thread,
        None => take_over(session, &conversation).await?,
    };
    let (approvals, sandbox) = policy(conversation.permissions);
    let mut params = json!({"threadId": thread, "cwd": conversation.cwd, "approvalPolicy": approvals, "sandbox": sandbox,
                            "developerInstructions": INSTRUCTIONS, "excludeTurns": true});
    if let Some(model) = &conversation.model { params["model"] = json!(model) }
    if !conversation.mcp.is_empty() { params["config"] = mcp_config(&conversation.mcp) }
    session.request(|id| json!({"id": id, "method": "thread/resume", "params": params})).await.map(|_| ())
}

/// Zero's MCP servers as config overrides for a thread (`mcp_servers.<id>`), over stdin: on top of the user's own.
pub fn mcp_config(servers: &[crate::mcp_servers::Resolved]) -> Value {
    let pairs = |values: &[(String, String)]| -> serde_json::Map<String, Value> { values.iter().map(|(k, v)| (k.clone(), json!(v))).collect() };
    let config: serde_json::Map<String, Value> = servers.iter().filter_map(|server| {
        let entry = match (&server.command, &server.url) {
            (Some(command), _) => json!({"command": command, "args": server.args, "env": pairs(&server.env)}),
            (None, Some(url)) => json!({"url": url, "http_headers": pairs(&server.headers)}),
            (None, None) => return None,
        };
        Some((format!("mcp_servers.{}", server.id), entry))
    }).collect();
    Value::Object(config)
}

/// Codex imports Claude Code sessions it finds where Claude keeps them (not through a link), so the record goes there as a
/// Claude Code session file just for the import, and is gone again once Codex has made its thread of it.
async fn take_over(session: &Session, conversation: &Conversation) -> Result<String, String> {
    let home = std::path::PathBuf::from(std::env::var("HOME").map_err(|_| "No home folder to hand the task over in")?);
    let id = crate::claude::new_session_id();
    let folder = crate::handoff::claude_folder(&home, &conversation.cwd);
    let copy = folder.join(format!("{id}.jsonl"));
    std::fs::create_dir_all(&folder).and_then(|_| std::fs::write(&copy, crate::handoff::claude_session(conversation, &id)))
        .map_err(|e| format!("Couldn't write the conversation for Codex: {e}"))?;
    let imported = import(session, &copy.to_string_lossy()).await;
    let _ = std::fs::remove_file(&copy);
    imported
}

async fn import(session: &Session, path: &str) -> Result<String, String> {
    let detected = session.request(|id| json!({"id": id, "method": "externalAgentConfig/detect", "params": {"includeHome": true, "maxSessions": 20}})).await?;
    let mut item = detected["items"].as_array().into_iter().flatten().find(|i| i["itemType"] == "SESSIONS").cloned()
        .ok_or("Codex found no conversations to take over")?;
    let ours: Vec<Value> = item["details"]["sessions"].as_array().into_iter().flatten().filter(|s| s["path"] == path).cloned().collect();
    if ours.is_empty() { return Err("Codex didn't find the conversation Zero wrote for it".into()) }
    item["details"]["sessions"] = Value::Array(ours);
    let started = session.request(|id| json!({"id": id, "method": "externalAgentConfig/import", "params": {"migrationItems": [item]}})).await?;
    let import = started["importId"].as_str().ok_or("Codex didn't start the import")?.to_string();
    // ponytail: polls its import history; the completed notification when the adapter can hand notifications to a waiter.
    for _ in 0..240 {
        let read = session.request(|id| json!({"id": id, "method": "externalAgentConfig/import/readHistories"})).await?;
        if let Some(done) = read["data"].as_array().into_iter().flatten().find(|h| h["importId"] == import.as_str()) {
            if let Some(thread) = done["successes"].as_array().into_iter().flatten().find_map(|s| s["target"].as_str()) { return Ok(thread.into()) }
            let why = done["failures"][0]["message"].as_str().unwrap_or("no reason given");
            return Err(format!("Codex couldn't take over the conversation: {why}"));
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
    Err("Codex took too long to take over the conversation".into())
}

async fn handshake(session: &Session, transport: Transport) -> Result<(), String> {
    session.attach(transport);
    session.request(|id| json!({"id": id, "method": "initialize", "params": {
        "clientInfo": {"name": "zero", "title": "Zero", "version": env!("CARGO_PKG_VERSION")},
        "capabilities": {"experimentalApi": false, "requestAttestation": false},
    }})).await?;
    session.write(json!({"method": "initialized"}))
}

/// Steers the turn in progress, or starts a new one.
pub async fn send(session: &Session, text: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
    let conversation = session.snapshot();
    let thread = conversation.thread.ok_or("Codex hasn't started the thread yet")?;
    match conversation.turn {
        Some(turn) => session.request(|id| json!({"id": id, "method": "turn/steer", "params": {"threadId": thread, "expectedTurnId": turn, "input": input(text, images)}})).await.map(|_| ()),
        // The model and effort picked since the last turn (set_model) go with this one.
        None => self::turn(session, &thread, input(text, images), model.or(conversation.model.as_deref()), effort.or(conversation.effort.as_deref())).await,
    }
}

async fn turn(session: &Session, thread: &str, input: Value, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
    session.request(|id| json!({"id": id, "method": "turn/start", "params": {"threadId": thread, "input": input, "model": model, "effort": effort}})).await?;
    // A turn's model and effort stay for the turns after it.
    if model.is_some() || effort.is_some() {
        session.change(Change::Thread { thread: thread.into(), model: model.map(Into::into), effort: effort.map(Into::into) });
    }
    Ok(())
}

pub async fn interrupt(session: &Session) -> Result<(), String> {
    let conversation = session.snapshot();
    let (Some(thread), Some(turn)) = (conversation.thread, conversation.turn) else { return Err("Nothing is running to interrupt".into()) };
    session.request(|id| json!({"id": id, "method": "turn/interrupt", "params": {"threadId": thread, "turnId": turn}})).await.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shell_codex_wraps_commands_in_is_not_shown() {
        assert_eq!(unwrap_shell("/bin/zsh -lc 'ls -la'"), "ls -la");
        assert_eq!(unwrap_shell("cargo test"), "cargo test");
    }

    #[test]
    fn decisions_newer_than_zero_are_left_out() {
        let available = json!(["accept", {"applyNetworkPolicyAmendment": {"network_policy_amendment": {}}}, "somethingNew", "cancel"]);
        let kinds: Vec<_> = offered(&available).into_iter().map(|(c, _)| (c.id, c.kind)).collect();
        assert_eq!(kinds, [("0".to_string(), ChoiceKind::Allow), ("1".to_string(), ChoiceKind::Stop)]);
    }
}
