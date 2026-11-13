//! Claude Code through its own headless mode: the installed `claude`, unmodified, with stream-json both ways and
//! its permission prompts on stdio (`--permission-prompt-tool stdio`, as Anthropic's Agent SDK starts it). It
//! signs in as it always does; Zero never reads or holds its credentials. The message shapes are those of the
//! SDK's control protocol (`@anthropic-ai/claude-agent-sdk`'s sdk.d.ts), checked against recordings.

use std::collections::HashMap;

use serde_json::{Value, json};

use crate::adapter::INSTRUCTIONS;
use crate::adapter::{Adapter, Answers, Effects, after_approval, login_shell};
use crate::codex::file_title;
use crate::model::{
    Approval, ApprovalKind, Change, Choice, ChoiceKind, Conversation, Field, FileChange, Item, ItemKind, ItemStatus, Permissions, Question,
    QuestionOption, Status,
};
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
    /// Tools running on in the background (a subagent, a long command): their immediate result only says they
    /// started, so each stays running until its task notification.
    background: std::collections::HashSet<String>,
    /// Zero asked Claude to stop the turn: the error result that follows is the stop, not a failure.
    interrupting: bool,
    /// Claude's background tasks still running (a subagent, a shell), by task id: what Stop stops besides the turn.
    tasks: std::collections::HashSet<String>,
    /// Servers this process said need signing in, so a later turn's init doesn't say it again.
    signing_in: std::collections::HashSet<String>,
    /// The row saying Claude is compacting the conversation, while it does: a turn can go quiet for minutes then.
    compacting: Option<String>,
}

/// Claude compacts an idle conversation before its prompt cache expires: a cache write saved, the conversation lost to a
/// summary. Off for Zero's runs only, on top of the user's own settings.
pub const NO_IDLE_COMPACTION: &str = r#"{"idleCompaction":false}"#;

/// Claude's own subagents (its Agent tool), off for this run only.
pub const NO_SUBAGENTS: &[&str] = &["--disallowed-tools=Agent"];

pub fn command(conversation: &Conversation, resume: bool, model: Option<&str>, effort: Option<&str>, subagents: bool) -> Vec<String> {
    let mut args = vec![
        "claude",
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        // Claude in Chrome's tools: in print mode they come only with the flag (the user's own default
        // applies to terminal sessions alone); Claude connects to the extension if Chrome has it.
        "--include-partial-messages",
        "--no-chrome",
        "--permission-prompt-tool",
        "stdio",
        "--permission-mode",
        match conversation.permissions {
            Permissions::Auto => "auto",
            Permissions::Unrestricted => "bypassPermissions",
        },
        "--append-system-prompt",
        INSTRUCTIONS,
        "--settings",
        NO_IDLE_COMPACTION,
    ];
    if !subagents {
        args.extend(NO_SUBAGENTS)
    }
    if let Some(thread) = conversation.thread.as_deref() {
        args.extend([if resume { "--resume" } else { "--session-id" }, thread])
    }
    if let Some(model) = model {
        args.extend(["--model", model])
    }
    if let Some(effort) = effort {
        args.extend(["--effort", effort])
    }
    let config = mcp_config(&conversation.mcp).map(|(config, _)| config);
    if let Some(config) = &config {
        args.extend(["--mcp-config", config])
    }
    login_shell(&args)
}

/// Zero's MCP servers as `--mcp-config` takes them, on top of the user's own; each value a `${…}` that Claude expands
/// from its environment, where zerod puts the value (the pairs given back), so no secret is on the command line.
pub fn mcp_config(servers: &[crate::mcp_servers::Resolved]) -> Option<(String, Vec<(String, String)>)> {
    if servers.is_empty() {
        return None;
    }
    let mut env = vec![];
    let mut config = serde_json::Map::new();
    for server in servers {
        let mut refer = |values: &[(String, String)]| -> serde_json::Map<String, Value> {
            values
                .iter()
                .map(|(name, value)| {
                    let var = format!("ZERO_MCP_{}_{}", variable(&server.id), variable(name));
                    env.push((var.clone(), value.clone()));
                    (name.clone(), json!(format!("${{{var}}}")))
                })
                .collect()
        };
        let entry = match (&server.command, &server.url) {
            (Some(command), _) => json!({"command": command, "args": server.args, "env": refer(&server.env)}),
            (None, Some(url)) => json!({"type": "http", "url": url, "headers": refer(&server.headers)}),
            (None, None) => continue,
        };
        config.insert(server.id.clone(), entry);
    }
    Some((json!({"mcpServers": config}).to_string(), env))
}

fn variable(name: &str) -> String {
    name.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_uppercase() } else { '_' }).collect()
}

/// A fresh conversation id for a new Claude session, a UUID as `--session-id` wants.
pub fn new_session_id() -> String {
    let mut bytes = [0u8; 16];
    if let Ok(mut random) = std::fs::File::open("/dev/urandom") {
        let _ = std::io::Read::read_exact(&mut random, &mut bytes);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// Your words as Claude Code's stream takes them, each image as data where its token stands (images.rs).
pub fn user_message(text: &str, images: &[String]) -> Value {
    if images.is_empty() {
        return json!({"type": "user", "message": {"role": "user", "content": text}});
    }
    let content: Vec<Value> = crate::images::parts(text, images)
        .into_iter()
        .filter_map(|part| match part {
            crate::images::Part::Text(text) => Some(json!({"type": "text", "text": text})),
            crate::images::Part::Image(path) => crate::images::data(&path)
                .map(|(mime, data)| json!({"type": "image", "source": {"type": "base64", "media_type": mime, "data": data}})),
        })
        .collect();
    json!({"type": "user", "message": {"role": "user", "content": content}})
}

impl Adapter for Claude {
    fn sent(&mut self, conversation: &Conversation, message: &Value) -> Vec<Change> {
        match message["type"].as_str() {
            Some("user") => {
                // Words alone, or words and images as blocks: the words, with their image tokens, as one.
                let text = match &message["message"]["content"] {
                    Value::Array(blocks) => blocks.iter().filter_map(|b| b["text"].as_str()).collect(),
                    content => content.as_str().unwrap_or("").to_string(),
                };
                let mut changes = vec![Change::Item {
                    item: Item {
                        at: None,
                        id: format!("user-{}", conversation.seq + 1),
                        turn: conversation.turn.clone(),
                        kind: ItemKind::User { text, images: vec![], sent: None },
                        status: ItemStatus::Done,
                    },
                }];
                if self.queued == 0 {
                    self.turns += 1;
                    changes.push(Change::Status { status: Status::Working, turn: Some(format!("turn-{}", self.turns)), error: None });
                }
                self.queued += 1;
                changes
            }
            Some("control_request") if message["request"]["subtype"] == "interrupt" => {
                self.interrupting = true;
                vec![]
            }
            Some("control_response") => {
                let id = message["response"]["request_id"].as_str().unwrap_or("");
                if self.requests.remove(id).is_none() {
                    return vec![];
                }
                let settled = if conversation.questions.iter().any(|q| q.id == id) {
                    Change::Answered { question: id.into() }
                } else {
                    Change::Resolved { approval: id.into() }
                };
                vec![settled, after_approval(conversation, id)]
            }
            _ => vec![],
        }
    }

    fn receive(&mut self, conversation: &Conversation, message: &Value) -> Effects {
        let mut effects = Effects::default();
        // A subagent left running in the background, speaking after the lead's turn has ended: its words are its own,
        // and no turn of the lead's (which nothing would ever end). The lead hears from it, and says so, in its next turn.
        // Its results still end the steps they answer (calls it made while the turn ran, shown then): a result starts
        // no turn.
        let between_turns = matches!(conversation.status, Status::Idle | Status::Offline);
        if between_turns
            && message["parent_tool_use_id"].is_string()
            && matches!(message["type"].as_str(), Some("assistant" | "stream_event"))
        {
            return effects;
        }
        match message["type"].as_str() {
            // Auto mode's classifier refused a tool call: what the user would have to allow or do themselves.
            Some("system") if message["subtype"] == "permission_denied" => {
                if let Some(mut item) = message["tool_use_id"].as_str().and_then(|id| conversation.item(id)).cloned() {
                    item.status = ItemStatus::Declined;
                    effects.changes.push(Change::Item { item });
                }
                let reason = message["message"].as_str().unwrap_or("Claude's permission check refused it");
                effects.notice(conversation, &format!("Blocked: {reason}"), true);
            }
            Some("system") if message["subtype"] == "init" => {
                if let Some(thread) = message["session_id"].as_str() {
                    effects.changes.push(Change::Thread {
                        thread: thread.into(),
                        model: message["model"].as_str().map(Into::into),
                        effort: None,
                    });
                }
                // A server that wants signing in, Zero's or the user's own: Zero signs in to it (mcp_auth.rs), once.
                for server in message["mcp_servers"].as_array().into_iter().flatten().filter(|s| s["status"] == "needs-auth") {
                    if let Some(name) = server["name"].as_str()
                        && self.signing_in.insert(name.into())
                    {
                        effects.changes.push(Change::McpSignIn { server: name.into() });
                    }
                }
            }
            Some("system") if message["subtype"] == "status" && message["status"] == "compacting" => {
                if self.compacting.is_none() {
                    let id = format!("{}{}", crate::adapter::COMPACTED, conversation.seq + 1 + effects.changes.len() as u64);
                    self.compacting = Some(id.clone());
                    let item = Item {
                        at: None,
                        id,
                        turn: conversation.turn.clone(),
                        kind: ItemKind::Notice { text: "Compacting the conversation…".into(), error: false },
                        status: ItemStatus::Running,
                    };
                    effects.changes.push(Change::Item { item });
                }
            }
            Some("system")
                if message["subtype"] == "status"
                    && let Some(id) = self.compacting.take() =>
            {
                let failed = message["compact_result"] == "failed";
                let text = if failed { "Couldn't compact the conversation" } else { "Conversation compacted" };
                let item = Item {
                    at: None,
                    id,
                    turn: conversation.turn.clone(),
                    kind: ItemKind::Notice { text: text.into(), error: false },
                    status: if failed { ItemStatus::Failed } else { ItemStatus::Done },
                };
                effects.changes.push(Change::Item { item });
            }
            Some("system") if message["subtype"] == "task_started" && message["is_backgrounded"] == true => {
                if let Some(id) = message["tool_use_id"].as_str() {
                    self.background.insert(id.into());
                }
                if let Some(task) = message["task_id"].as_str() {
                    self.tasks.insert(task.into());
                }
            }
            // A task at work, backgrounded or not: running until its notification.
            Some("system") if message["subtype"] == "task_progress" => {
                if let Some(task) = message["task_id"].as_str() {
                    self.tasks.insert(task.into());
                }
            }
            // A background task's end: its tool's step ends now, as the task did (not when it was started).
            Some("system") if message["subtype"] == "task_notification" => {
                if let Some(task) = message["task_id"].as_str() {
                    self.tasks.remove(task);
                }
                if let Some(id) = message["tool_use_id"].as_str()
                    && self.background.remove(id)
                    && let Some(mut item) = conversation.item(id).cloned()
                {
                    item.status = if message["status"] == "completed" { ItemStatus::Done } else { ItemStatus::Failed };
                    effects.changes.push(Change::Item { item });
                }
            }
            Some("stream_event") => self.stream(conversation, message, &mut effects),
            // Claude Code's own word of an API error, made up as the agent's: one it retries is nothing to show, one
            // that ends the turn its result reports.
            Some("assistant") if message["is_api_error_message"] == true => {}
            Some("assistant") => self.assistant(conversation, message, &mut effects),
            Some("user") => results(conversation, message, &mut effects, &self.background),
            Some("control_request") => self.request(conversation, message, &mut effects),
            Some("control_cancel_request") => {
                let id = message["request_id"].as_str().unwrap_or("");
                if self.requests.remove(id).is_some() {
                    let settled = if conversation.questions.iter().any(|q| q.id == id) {
                        Change::Answered { question: id.into() }
                    } else {
                        Change::Resolved { approval: id.into() }
                    };
                    effects.changes.push(settled);
                    effects.changes.push(after_approval(conversation, id));
                }
            }
            Some("result") => self.result(conversation, message, &mut effects),
            Some("rate_limit_event") => effects.changes.push(Change::Usage { usage: usage(&message["rate_limit_info"]) }),
            // Status lines, thinking-token counts, rate limits: kept in the transcript, not shown.
            _ => {}
        }
        effects
    }

    fn answers(&self, message: &Value) -> Option<(String, Result<Value, String>)> {
        if message["type"] != "control_response" {
            return None;
        }
        let response = &message["response"];
        let outcome = match response["subtype"].as_str() {
            Some("success") => Ok(response["response"].clone()),
            _ => Err(response["error"].as_str().unwrap_or("Claude refused the request").to_string()),
        };
        Some((response["request_id"].as_str()?.to_string(), outcome))
    }

    fn answer(&self, approval: &Approval, choice: &str) -> Result<Value, String> {
        let (input, suggestions) =
            self.requests.get(&approval.id).ok_or_else(|| format!("Claude isn't waiting on \"{}\" any more", approval.title))?;
        let response = match choice {
            "allow" => json!({"behavior": "allow", "updatedInput": input}),
            "always" | "session" => json!({"behavior": "allow", "updatedInput": input, "updatedPermissions": suggestions}),
            "deny" => json!({"behavior": "deny", "message": "Denied in Zero"}),
            "stop" => json!({"behavior": "deny", "message": "Denied in Zero", "interrupt": true}),
            other => return Err(format!("No choice {other}")),
        };
        Ok(json!({"type": "control_response", "response": {"subtype": "success", "request_id": approval.id, "response": response}}))
    }

    fn reply(&self, question: &Question, answers: &Answers) -> Result<Value, String> {
        let (input, _) = self.requests.get(&question.id).ok_or("Claude isn't waiting on that question any more")?;
        // AskUserQuestion's answers ride back in its input, keyed by each question's text; several picks, comma-joined.
        let mut input = input.clone();
        input["answers"] = question
            .fields
            .iter()
            .map(|field| (field.question.clone(), Value::String(answers[&field.id].join(", "))))
            .collect::<serde_json::Map<_, _>>()
            .into();
        Ok(
            json!({"type": "control_response", "response": {"subtype": "success", "request_id": question.id, "response": {"behavior": "allow", "updatedInput": input}}}),
        )
    }

    fn stops(&self) -> Vec<Value> {
        let mut tasks: Vec<&String> = self.tasks.iter().collect();
        tasks.sort();
        tasks.into_iter().map(|task| json!({"type": "control_request", "request_id": format!("stop-{task}"), "request": {"subtype": "stop_task", "task_id": task}})).collect()
    }

    fn ended(&mut self) {
        self.requests.clear();
        self.queued = 0;
        self.said = None;
        self.background.clear();
        self.tasks.clear();
        self.signing_in.clear();
    }
}

impl Claude {
    /// The turn Claude is speaking in. Idle, its words are a turn of their own (a message that reached it as the last
    /// turn ended), so the session reads as working until that turn's result.
    fn speaking(&mut self, conversation: &Conversation, effects: &mut Effects) -> Option<String> {
        if conversation.status != Status::Idle && conversation.status != Status::Offline {
            return conversation.turn.clone();
        }
        self.turns += 1;
        let turn = format!("turn-{}", self.turns);
        effects.changes.push(Change::Status { status: Status::Working, turn: Some(turn.clone()), error: None });
        Some(turn)
    }

    /// Text as it streams in: a block starts an item, its deltas grow it, and the finished message replaces it.
    fn stream(&mut self, conversation: &Conversation, message: &Value, effects: &mut Effects) {
        let event = &message["event"];
        let Some(msg) = message["api_message_id"].as_str() else { return };
        let index = event["index"].as_u64().unwrap_or(0);
        match event["type"].as_str() {
            Some("content_block_start") if event["content_block"]["type"] == "text" => {
                let turn = self.speaking(conversation, effects);
                let count = self.streamed.entry(msg.into()).or_insert(0);
                let id = format!("{msg}:{count}");
                *count += 1;
                self.blocks.insert((msg.into(), index), id.clone());
                let kind = ItemKind::Agent { text: String::new(), final_answer: false };
                effects.changes.push(Change::Item { item: Item { at: None, id: id.clone(), turn, kind, status: ItemStatus::Running } });
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
        let turn = self.speaking(conversation, effects);
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
                Some("tool_use") => (
                    block["id"].as_str().unwrap_or("tool").into(),
                    tool(conversation, &block["name"], &block["input"]),
                    ItemStatus::Running,
                ),
                _ => continue,
            };
            effects.changes.push(Change::Item { item: Item { at: None, id, turn: turn.clone(), kind, status } });
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
        if name == "AskUserQuestion" {
            let fields = input["questions"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .iter()
                .enumerate()
                .map(|(i, q)| Field {
                    id: i.to_string(),
                    header: q["header"].as_str().map(String::from),
                    question: q["question"].as_str().unwrap_or("").into(),
                    options: q["options"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default()
                        .iter()
                        .map(|o| QuestionOption {
                            label: o["label"].as_str().unwrap_or("").into(),
                            description: o["description"].as_str().filter(|d| !d.is_empty()).map(String::from),
                        })
                        .collect(),
                    multiple: q["multiSelect"] == true,
                    other: true,
                    secret: false,
                })
                .collect();
            self.requests.insert(id.clone(), (input.clone(), Value::Null));
            effects
                .changes
                .push(Change::Question { question: Question { id, item: request["tool_use_id"].as_str().map(Into::into), fields } });
            effects.changes.push(Change::Status {
                status: Status::Waiting,
                turn: conversation.turn.clone(),
                error: conversation.error.clone(),
            });
            return;
        }
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
        if let Some(choice) = remember(&suggestions) {
            choices.push(choice)
        }
        choices.push(Choice { id: "deny".into(), label: "Deny".into(), kind: ChoiceKind::Deny });
        choices.push(Choice { id: "stop".into(), label: "Deny and stop".into(), kind: ChoiceKind::Stop });
        self.requests.insert(id.clone(), (input.clone(), suggestions));
        let approval =
            Approval { id, item: request["tool_use_id"].as_str().map(Into::into), kind, title, command, cwd, reason, changes, choices };
        effects.changes.push(Change::Approval { approval });
        // Within a turn, the turn waits on it. Between turns (a background subagent asking), no turn of the lead's
        // starts: the approval alone makes it need the user, and the subagent's words stay its own.
        if conversation.turn.is_some() {
            effects.changes.push(Change::Status {
                status: Status::Waiting,
                turn: conversation.turn.clone(),
                error: conversation.error.clone(),
            });
        }
    }

    /// The end of a turn: its last words become its answer, and the session is idle. Messages sent during the turn
    /// went into it (Claude Code hands them to the running turn), so none is still to come.
    fn result(&mut self, conversation: &Conversation, message: &Value, effects: &mut Effects) {
        // No turn run, only a background task's end noted (a resumed session's command its pause or restart stopped):
        // the turn sent to it, if any, hasn't started yet.
        if message["origin"]["kind"] == "task-notification" && message["num_turns"] == 0 && message["subtype"] == "success" {
            return;
        }
        self.queued = 0;
        let mut error = None;
        if std::mem::take(&mut self.interrupting) && message["subtype"] == "error_during_execution" {
            effects.notice(conversation, "Interrupted", false);
        } else if message["is_error"] == true || message["subtype"] != "success" {
            let text = message["result"].as_str().or(message["subtype"].as_str()).unwrap_or("The turn failed").to_string();
            effects.notice(conversation, &text, true);
            error = Some(text);
        }
        if let Some(id) = self.said.take()
            && let Some(mut item) = conversation.item(&id).cloned()
        {
            if let ItemKind::Agent { final_answer, .. } = &mut item.kind {
                *final_answer = true
            }
            item.status = ItemStatus::Done;
            effects.changes.push(Change::Item { item });
        }
        effects.changes.push(Change::Status { status: Status::Idle, turn: None, error });
    }
}

/// Tool results, which Claude sends back as a user message: each fills in the item of the tool it answers.
fn results(conversation: &Conversation, message: &Value, effects: &mut Effects, background: &std::collections::HashSet<String>) {
    let outcome = &message["tool_use_result"];
    for block in message["message"]["content"].as_array().cloned().unwrap_or_default() {
        if block["type"] != "tool_result" {
            continue;
        }
        // Started in the background: this result only says so; the step runs on until its task notification.
        if block["tool_use_id"].as_str().is_some_and(|id| background.contains(id)) {
            continue;
        }
        let Some(mut item) = block["tool_use_id"].as_str().and_then(|id| conversation.item(id)).cloned() else { continue };
        item.status = if block["is_error"] == true { ItemStatus::Failed } else { ItemStatus::Done };
        match &mut item.kind {
            ItemKind::Command { output, .. } => {
                *output = match outcome["stdout"].as_str() {
                    // Claude's "(Bash completed with no output)" is its note to itself, not output.
                    Some(stdout) => [stdout, outcome["stderr"].as_str().unwrap_or("")]
                        .iter()
                        .filter(|s| !s.is_empty())
                        .cloned()
                        .collect::<Vec<_>>()
                        .join("\n"),
                    None => text(&block["content"]),
                };
            }
            ItemKind::Tool { output, .. } => *output = crate::model::tool_output(&text(&block["content"])),
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
        "Bash" => ItemKind::Command {
            command: field("command"),
            cwd: conversation.cwd.clone(),
            output: String::new(),
            exit_code: None,
            duration_ms: None,
            description: field("description"),
        },
        "Write" => ItemKind::FileChange {
            changes: vec![FileChange { path: field("file_path"), kind: "add".into(), move_path: None, diff: field("content") }],
        },
        "Edit" => ItemKind::FileChange {
            changes: vec![FileChange {
                path: field("file_path"),
                kind: "update".into(),
                move_path: None,
                diff: replaced(&field("old_string"), &field("new_string")),
            }],
        },
        "MultiEdit" => {
            let diff = input["edits"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .iter()
                .map(|edit| replaced(edit["old_string"].as_str().unwrap_or(""), edit["new_string"].as_str().unwrap_or("")))
                .collect();
            ItemKind::FileChange { changes: vec![FileChange { path: field("file_path"), kind: "update".into(), move_path: None, diff }] }
        }
        other => {
            let detail = ["file_path", "pattern", "url", "query", "description", "notebook_path"]
                .iter()
                .find_map(|key| input[key].as_str())
                .map(String::from)
                .unwrap_or_else(|| input.to_string());
            ItemKind::Tool { name: other.into(), detail, output: String::new() }
        }
    }
}

/// `old` replaced by `new`, as diff lines.
fn replaced(old: &str, new: &str) -> String {
    let mut diff = String::new();
    for line in old.lines() {
        diff += &format!("-{line}\n")
    }
    for line in new.lines() {
        diff += &format!("+{line}\n")
    }
    diff
}

/// The choice that keeps Claude's suggested rule: rules to allow from now on, or a mode for this session.
fn remember(suggestions: &Value) -> Option<Choice> {
    let suggestions = suggestions.as_array().filter(|s| !s.is_empty())?;
    let rules: Vec<String> = suggestions
        .iter()
        .filter(|s| s["type"] == "addRules" && s["behavior"] == "allow")
        .flat_map(|s| s["rules"].as_array().cloned().unwrap_or_default())
        .map(|rule| match rule["ruleContent"].as_str() {
            Some(content) => format!("{}({content})", rule["toolName"].as_str().unwrap_or("")),
            None => rule["toolName"].as_str().unwrap_or("").to_string(),
        })
        .collect();
    if !rules.is_empty() {
        return Some(Choice { id: "always".into(), label: format!("Always allow {}", rules.join(", ")), kind: ChoiceKind::AllowAlways });
    }
    if suggestions.iter().any(|s| s["type"] == "setMode" && s["mode"] == "acceptEdits") {
        return Some(Choice { id: "session".into(), label: "Allow all edits this session".into(), kind: ChoiceKind::AllowSession });
    }
    Some(Choice { id: "always".into(), label: "Always allow".into(), kind: ChoiceKind::AllowAlways })
}

/// Claude's own report of the account's limits: a status, and the use of each window.
fn usage(info: &Value) -> crate::model::Usage {
    let limited = info["status"] == "rejected";
    let windows = info["unifiedWindows"]
        .as_object()
        .map(|windows| {
            windows
                .iter()
                .map(|(key, window)| crate::model::UsageWindow {
                    name: match key.as_str() {
                        "five_hour" => "5 hours".into(),
                        "seven_day" => "7 days".into(),
                        other => other.replace('_', " "),
                    },
                    used: window["utilization"].as_f64().unwrap_or(0.0),
                    resets_at: window["resetsAt"].as_i64(),
                })
                .collect()
        })
        .unwrap_or_default();
    crate::model::Usage { limited, resets_at: if limited { info["resetsAt"].as_i64() } else { None }, windows }
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
pub async fn start(session: &Session, transport: Transport, prompt: &str, images: &[String]) -> Result<(), String> {
    session.attach(transport);
    session.write(user_message(prompt, images))
}

/// Started again with `--resume`, it is the same conversation, waiting for the next message.
pub async fn resume(session: &Session, transport: Transport) -> Result<(), String> {
    session.attach(transport);
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    Ok(())
}

/// A message: Claude takes it now or queues it behind the turn in progress. A new model switches first; effort
/// is set at start (`--effort`) and stays.
pub async fn send(session: &Session, text: &str, images: &[String], model: Option<&str>) -> Result<(), String> {
    if let Some(model) = model {
        set_model(session, model).await?
    }
    // Claude reads nothing more until its own question is answered: the user writing in the chat instead answers it.
    for question in session.snapshot().questions {
        session.write(json!({"type": "control_response", "response": {"subtype": "success", "request_id": question.id,
            "response": {"behavior": "deny", "message": "The user wrote in the chat instead of picking an answer: their message follows."}}}))?;
    }
    session.write(user_message(text, images))
}

/// The model from here on: Claude Code switches at once.
pub async fn set_model(session: &Session, model: &str) -> Result<(), String> {
    if session.snapshot().model.as_deref() == Some(model) {
        return Ok(());
    }
    session.request(|id| json!({"type": "control_request", "request_id": id, "request": {"subtype": "set_model", "model": model}})).await?;
    let thread = session.snapshot().thread.unwrap_or_default();
    session.change(Change::Thread { thread, model: Some(model.into()), effort: None });
    Ok(())
}

/// Stops what runs: the turn, and every task in the background (a subagent left running, a long command), which an
/// interrupt of the turn alone leaves going.
pub async fn interrupt(session: &Session) -> Result<(), String> {
    for stop in session.stops() {
        let _ = session.write(stop);
    }
    if session.snapshot().turn.is_none() {
        return Ok(());
    }
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
