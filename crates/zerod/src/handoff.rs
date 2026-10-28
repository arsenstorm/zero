//! Handing a task from one provider to another. Zero's record of the conversation is the task's history; each provider
//! gets it the way it reads a conversation natively: as a Claude Code session file, which Claude Code resumes and Codex
//! imports (`externalAgentConfig/import`). Messages and commands come along as they happened; reasoning stays with the
//! provider that had it, and notices are Zero's own.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::model::{Conversation, ItemKind};

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
