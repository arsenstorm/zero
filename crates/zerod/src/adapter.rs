//! What differs between providers: each one's protocol, turned into `Change`s to Zero's model with no I/O (so a
//! live session and a replay of its transcript run the same code), and the command line that starts it.

use std::collections::HashMap;

use serde_json::Value;

use crate::model::{Approval, Change, Conversation, Item, ItemKind, ItemStatus, Provider, Question, Status};

/// Answers to a question, by field id: the options picked, or Arsen's own words.
pub type Answers = HashMap<String, Vec<String>>;
use crate::{acp, claude, codex};

pub trait Adapter: Send {
    /// A line Zero wrote to the runtime. Providers that don't echo the user's words, or that start a turn only by
    /// being sent one, change the conversation here.
    fn sent(&mut self, conversation: &Conversation, message: &Value) -> Vec<Change>;
    /// A line the runtime wrote.
    fn receive(&mut self, conversation: &Conversation, message: &Value) -> Effects;
    /// Which of Zero's requests this line answers, and with what.
    fn answers(&self, message: &Value) -> Option<(String, Result<Value, String>)>;
    /// The line that answers `approval` with its choice `choice`.
    fn answer(&self, approval: &Approval, choice: &str) -> Result<Value, String>;
    /// The line that answers `question`, every field of it.
    fn reply(&self, question: &Question, answers: &Answers) -> Result<Value, String>;
    /// The runtime's process ended: whatever it was waiting on is gone.
    fn ended(&mut self);
}

/// What one line from the runtime leads to: changes to the conversation, and lines to send back at once.
#[derive(Default, Debug)]
pub struct Effects {
    pub changes: Vec<Change>,
    pub replies: Vec<Value>,
}

impl Effects {
    /// A notice, with an id nothing else in the conversation has: the sequence number it will be applied at.
    pub fn notice(&mut self, conversation: &Conversation, text: &str, error: bool) {
        let id = format!("notice-{}", conversation.seq + 1 + self.changes.len() as u64);
        let item = Item { at: None, id, turn: conversation.turn.clone(), kind: ItemKind::Notice { text: text.into(), error }, status: ItemStatus::Done };
        self.changes.push(Change::Item { item });
    }

    /// Something failed: a notice, and the error on the session until its next turn.
    pub fn fail(&mut self, conversation: &Conversation, text: &str) {
        self.notice(conversation, text, true);
        let status = if conversation.status == Status::Starting { Status::Idle } else { conversation.status };
        self.changes.push(Change::Status { status, turn: conversation.turn.clone(), error: Some(text.into()) });
    }
}

/// A JSON-RPC id as text: numbers and strings both, so it can key maps and name approvals.
pub fn key(id: &Value) -> String {
    match id {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// A JSON-RPC answer: whose request it answers, and its result or why it failed.
pub fn json_rpc_answer(message: &Value) -> Option<(String, Result<Value, String>)> {
    if message.get("method").is_some() { return None }
    let id = message.get("id")?;
    let outcome = match message.get("error") {
        Some(error) => Err(error["message"].as_str().unwrap_or("refused").to_string()),
        None => Ok(message["result"].clone()),
    };
    Some((key(id), outcome))
}

/// The status a session returns to once an approval or question is settled: still waiting if others are open.
pub fn after_approval(conversation: &Conversation, settled: &str) -> Change {
    let others = conversation.approvals.iter().any(|a| a.id != settled) || conversation.questions.iter().any(|q| q.id != settled);
    let status = if others { Status::Waiting } else if conversation.turn.is_some() { Status::Working } else { conversation.status };
    Change::Status { status, turn: conversation.turn.clone(), error: conversation.error.clone() }
}

/// What every agent zerod runs is told about working in Zero, where the provider takes extra instructions (Claude's
/// appended system prompt, Codex's developer instructions; OpenCode has no way over ACP). The user reads the
/// conversation in Zero, so it isn't the inbox rules for unattended terminals: just where commands only they can run
/// go, and that what other people will see stays the user's call.
pub const INSTRUCTIONS: &str = "You are working in Zero, a workspace for coding agents: the user reads this conversation there. \
Anything you need from them goes through Zero, never only your words: a question with your own question tool or with \
`zero ask \"…\" --option … --async`, a command they must run (their machine, credentials or production access) with \
`zero run 'command' --why 'what you need the output for' --async`, an approval with `zero approve`; never print a \
command for them to paste. End every turn with exactly one of these as its last line: [zero: done] (the work is \
finished, something still follows), [zero: completed] (done-done, nothing left for anyone), [zero: blocked] (stopped on \
something that isn't the user), [zero: working] (pausing between steps), or [zero: asked <id>] (waiting on what you \
asked). Don't take actions other people will see, such as merging, marking a pull request ready, requesting reviews or \
posting messages, unless the user asked you to. For anything in a web browser, use Zero's browser_ tools (the user's \
Chrome, through Zero for Chrome): your own browser tools are off in Zero.";

/// Codex's own browser, its bundled chrome and browser plugins, off for this run only: the user's config is left as is.
const CODEX_NO_BROWSER: &[&str] = &["-c", "plugins.chrome@openai-bundled.enabled=false", "-c", "plugins.browser@openai-bundled.enabled=false"];

/// `args` run through Arsen's login shell, so his PATH (nvm, ~/.local/bin, Homebrew) finds the provider's CLI.
pub fn login_shell(args: &[&str]) -> Vec<String> {
    ["/bin/zsh", "-lic", "exec \"$@\"", "zsh"].iter().chain(args).map(|s| s.to_string()).collect()
}

impl Provider {
    pub fn adapter(self) -> Box<dyn Adapter> {
        match self {
            Provider::Codex => Box::new(codex::Codex::default()),
            Provider::Claude => Box::new(claude::Claude::default()),
            Provider::Opencode => Box::new(acp::Acp::default()),
        }
    }

    /// The command line that starts the provider's runtime for `conversation`; `resume` for one that ran before. The
    /// providers' own browsers are off (Claude Code's `--no-chrome`, Codex's chrome and browser plugins): agents in Zero
    /// use Zero for Chrome, and two drivers in one Chrome would fight over its tabs.
    pub fn command(self, conversation: &Conversation, resume: bool, model: Option<&str>, effort: Option<&str>) -> Vec<String> {
        match self {
            Provider::Codex => login_shell(&[&["codex", "app-server"][..], CODEX_NO_BROWSER].concat()),
            Provider::Claude => claude::command(conversation, resume, model, effort),
            Provider::Opencode => login_shell(&["opencode", "acp"]),
        }
    }

    /// The provider's own terminal UI on the task's thread, with the task's permissions and model.
    pub fn terminal(self, conversation: &Conversation) -> Result<Vec<String>, String> {
        let thread = conversation.thread.as_deref().ok_or_else(|| format!("{} hasn't started this task's thread yet", self.title()))?;
        let unrestricted = conversation.permissions == crate::model::Permissions::Unrestricted;
        let mut args: Vec<&str> = match self {
            Provider::Claude => vec!["claude", "--resume", thread, "--permission-mode", if unrestricted { "bypassPermissions" } else { "auto" }, "--no-chrome"],
            // Its own app-server, as Zero runs Codex headless: the shared one may run with other settings, and Codex asks
            // before using it.
            Provider::Codex => [&["codex", "resume", thread, "--no-daemon", if unrestricted { "--dangerously-bypass-approvals-and-sandbox" } else { "--sandbox=workspace-write" }][..], CODEX_NO_BROWSER].concat(),
            Provider::Opencode => vec!["opencode", "--session", thread],
        };
        if self != Provider::Opencode && let Some(model) = conversation.model.as_deref() { args.extend(["--model", model]) }
        Ok(login_shell(&args))
    }

    /// How the provider is named to Arsen.
    pub fn title(self) -> &'static str {
        match self {
            Provider::Codex => "Codex",
            Provider::Claude => "Claude Code",
            Provider::Opencode => "OpenCode",
        }
    }
}
