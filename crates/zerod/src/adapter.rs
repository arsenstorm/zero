//! What differs between providers: each one's protocol, turned into `Change`s to Zero's model with no I/O (so a
//! live session and a replay of its transcript run the same code), and the command line that starts it.

use std::collections::HashMap;

use serde_json::Value;

use crate::model::{Approval, Change, Conversation, Item, ItemKind, ItemStatus, Provider, Question, Status};

/// Answers to a question, by field id: the options picked, or the user's own words.
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

    /// Lines that stop what runs in the background (a subagent, a long command) apart from the turn: what Stop sends
    /// besides interrupting the turn. None where the provider has no such thing.
    fn stops(&self) -> Vec<Value> {
        vec![]
    }
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
        let item = Item {
            at: None,
            id,
            turn: conversation.turn.clone(),
            kind: ItemKind::Notice { text: text.into(), error },
            status: ItemStatus::Done,
        };
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
    if message.get("method").is_some() {
        return None;
    }
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
    // No turn under way (a background subagent's request, between turns): no turn to go back to, so not left waiting.
    let status = if others {
        Status::Waiting
    } else if conversation.turn.is_some() {
        Status::Working
    } else if conversation.status == Status::Waiting {
        Status::Idle
    } else {
        conversation.status
    };
    Change::Status { status, turn: conversation.turn.clone(), error: conversation.error.clone() }
}

/// What every agent zerod runs is told about working in Zero, where the provider takes extra instructions (Claude's
/// appended system prompt, Codex's developer instructions; OpenCode has no way over ACP). The user reads the
/// conversation in Zero, so it isn't the inbox rules for unattended terminals: just where commands only they can run
/// go, and that what other people will see stays the user's call.
pub const INSTRUCTIONS: &str = "You are working in Zero, a workspace for coding agents: the user reads this conversation there. \
When the user's own message started your turn, they're in the conversation: answer them in your reply and ask what you \
need to know there, in plain words, as in any chat. Put what they should read in your last message: what you write \
before a tool call is folded away. Zero's asks are for actions, and for when they aren't here: a command only they can \
run (their machine, credentials or production access) with `zero run 'command' --why 'what you need the output for' \
--async`, an approval with `zero approve`, and any question in a turn Zero started (an event you follow, a worker's \
report, a wake-up) with `zero ask \"…\" --option … --async` (with `--block` when you can't go on without the answer: Zero then \
holds your other events until it's answered); where the `zero` command can't reach Zero (a sandbox), \
Zero's zero_ask, zero_run, zero_note and zero_issue tools do the same. Never print a command for them to paste. \
An MCP server that needs signing in (its tools fail asking for authentication): Zero has already asked the user to sign \
in to it, so don't ask them again; go on without it, and its tools work once they have. \
Leading several issues at once (a worker each), keep a row per issue, which the user reads coming back instead of \
asking you where everything is: `zero issue TICKET you|over|working|waiting|parked|done \"…\"` whenever one's state \
changes (you: what you need them to decide or give; over: done on your side, their step to take, such as a review or \
merge; waiting: on whom; parked: why). Other tasks in Zero may \
work on what yours touches (`zero tasks` lists them, with their folders): coordinate with one directly by \
`zero send <its id or name> \"…\"`, its replies coming to you as messages from it, and keep the user out of what you \
can settle between you. Work for another agent goes to a Zero worker: \
`zero spawn \"task\" --label NAME` starts one under you, which the user sees in Zero and can watch, steer or stop, and \
which reports back to you when it finishes, fails or gets stuck (a turn it ended with a command of its own still \
running in the background, it's waiting on that, not stopped). A finished worker is put away an hour after you have its \
report; `zero send` to it brings it back. Your CLI's own subagents are off in Zero unless the \
user has turned them on, and even then workers come first: the user can't see a subagent. Hand a worker reading that \
would fill your context (long logs, many files, a whole transcript, a review) and the parts of a job that can run side \
by side, and take back its conclusion, so your conversation stays short of compacting; leading, your issue rows and \
workers keep the state, not your memory. A turn the user's own message started is a conversation: end it with your answer, no ending line \
(it shows as Replied), unless the work has come to [zero: done], [zero: waiting] or [zero: asked <id>] below. End \
every other turn (one Zero started: an event, a worker's report, a reminder) with exactly one of these as its last \
line: [zero: done] (the work is finished end to end, with good reason to say so: merged and deployed, verified, its \
ticket closed, or the user said it's done; Zero then puts it away, and what you follow brings it back if something \
comes up. Committed, pushed or in review is not done. It counts only once `zero done \"what's done\"` (or zero_done) \
has confirmed it: that's refused at first with what done means and a token, then `--confirm <token>` within 5 \
minutes marks it; unsure, `--ask` asks the user. A worker's done is its lead's to judge, never the user's: for a \
worker, `zero done` marks it at once and asks no one. Unconfirmed, [zero: done] shows as Replied), [zero: waiting] (the next move is someone else's, not the user's: a review, CI, a deploy, QA), \
[zero: blocked] (rare, shown red: it can't go on at all until something outside you and the user changes, such as an \
outage or another team's access, or for a worker, a decision only its lead or the user can make; only once `zero blocked \"what blocks it\"` (or zero_blocked) has confirmed it, in two \
steps as done; unconfirmed, it shows as Waiting), [zero: working] (pausing between steps), or [zero: asked <id>] (waiting on the user's answer to what you asked, only \
while it's unanswered). Don't take actions other people will see, such as merging, marking a pull request ready, requesting reviews or \
posting messages, unless the user asked you to. For anything in a web browser, use Zero's browser_ tools (the user's \
Chrome, through Zero for Chrome): your own browser tools are off in Zero. To show the user an image (a screenshot, a \
render), save it as a file and put `![what it shows](/its/absolute/path.png)` on a line of its own in your message: \
Zero shows it there, on their Mac and their phone.";

/// The start of a compaction row's id, whichever CLI compacted: once it's done, Zero gives the agent its record (recap.rs).
pub const COMPACTED: &str = "compaction-";

/// Whether agents may use their CLI's own subagents (Settings › subagents): off unless the user turns them on, so work
/// handed to another agent goes to a Zero worker, which the user sees, steers and stops in Zero. Read as each process
/// starts.
static SUBAGENTS: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub fn allow_subagents(on: bool) {
    SUBAGENTS.store(on, std::sync::atomic::Ordering::Relaxed)
}
pub fn subagents() -> bool {
    SUBAGENTS.load(std::sync::atomic::Ordering::Relaxed)
}

/// The context size agents compact at (Settings › Compact context at), in tokens; 0, the CLIs' own. Read as each
/// process starts: Claude Code from its environment (process::environment), Codex from `compact_config`.
static COMPACT_WINDOW: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub fn set_compact_window(tokens: Option<u64>) {
    COMPACT_WINDOW.store(tokens.unwrap_or(0), std::sync::atomic::Ordering::Relaxed)
}
pub fn compact_window() -> Option<u64> {
    Some(COMPACT_WINDOW.load(std::sync::atomic::Ordering::Relaxed)).filter(|&tokens| tokens > 0)
}

/// Claude Code's window at the user's size, as the variable it reads over its own settings (none set, its own).
pub fn claude_compact() -> Option<(String, String)> {
    compact_window().map(|tokens| ("CLAUDE_CODE_AUTO_COMPACT_WINDOW".to_string(), tokens.to_string()))
}

/// Codex's compaction threshold at the user's size, for this run only (none set, Codex's own).
fn codex_compact() -> Vec<String> {
    compact_window().map(|tokens| vec!["-c".into(), format!("model_auto_compact_token_limit={tokens}")]).unwrap_or_default()
}

/// Codex's own subagents (its multi-agent tools), off for this run only.
const CODEX_NO_SUBAGENTS: &[&str] = &["-c", "features.multi_agent=false"];

/// Codex's own browser, its bundled chrome and browser plugins, off for this run only: the user's config is left as is.
const CODEX_NO_BROWSER: &[&str] =
    &["-c", "plugins.chrome@openai-bundled.enabled=false", "-c", "plugins.browser@openai-bundled.enabled=false"];

/// `args` run through the user's login shell, so their PATH (nvm, ~/.local/bin, Homebrew) finds the provider's CLI.
pub fn login_shell(args: &[&str]) -> Vec<String> {
    ["/bin/zsh", "-lic", "exec \"$@\"", "zsh"].iter().chain(args).map(|s| s.to_string()).collect()
}

/// `args` run directly, with the PATH the user's login shell gives (read once): for what zerod runs over and over
/// (gh for every pull request followed, every minute), where a login shell each time cost ~94 ms of CPU and half a
/// second. Agents' CLIs still start through `login_shell`, for the rest of the user's environment.
pub fn on_login_path(args: &[&str]) -> Vec<String> {
    static PATH: std::sync::LazyLock<String> = std::sync::LazyLock::new(|| {
        std::process::Command::new("/bin/zsh")
            .args(["-lic", "printf %s \"$PATH\""])
            .output()
            .ok()
            .and_then(|out| String::from_utf8(out.stdout).ok())
            .filter(|p| !p.trim().is_empty())
            .unwrap_or_else(|| std::env::var("PATH").unwrap_or_default())
    });
    ["/usr/bin/env".to_string(), format!("PATH={}", *PATH)].into_iter().chain(args.iter().map(|s| s.to_string())).collect()
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
        self.command_with(conversation, resume, model, effort, subagents())
    }

    /// As `command`, with the CLI's own subagents on or off (`subagents`): off, Claude's Agent tool and Codex's
    /// multi-agent tools are left out. OpenCode's can't be, for a run alone: its background service reads the user's
    /// own config.
    pub fn command_with(
        self, conversation: &Conversation, resume: bool, model: Option<&str>, effort: Option<&str>, subagents: bool,
    ) -> Vec<String> {
        match self {
            Provider::Codex => {
                let compact = codex_compact();
                let compact: Vec<&str> = compact.iter().map(String::as_str).collect();
                login_shell(
                    &[&["codex", "app-server"][..], CODEX_NO_BROWSER, if subagents { &[] } else { CODEX_NO_SUBAGENTS }, &compact].concat(),
                )
            }
            Provider::Claude => claude::command(conversation, resume, model, effort, subagents),
            Provider::Opencode => login_shell(&["opencode", "acp"]),
        }
    }

    /// The provider's own terminal UI on the task's thread, with the task's permissions and model.
    pub fn terminal(self, conversation: &Conversation) -> Result<Vec<String>, String> {
        let thread = conversation.thread.as_deref().ok_or_else(|| format!("{} hasn't started this task's thread yet", self.title()))?;
        let unrestricted = conversation.permissions == crate::model::Permissions::Unrestricted;
        let compact = codex_compact();
        let mut args: Vec<&str> = match self {
            Provider::Claude => [
                &[
                    "claude",
                    "--resume",
                    thread,
                    "--permission-mode",
                    if unrestricted { "bypassPermissions" } else { "auto" },
                    "--no-chrome",
                    "--settings",
                    claude::NO_IDLE_COMPACTION,
                ][..],
                if subagents() { &[] } else { claude::NO_SUBAGENTS },
            ]
            .concat(),
            // Its own app-server, as Zero runs Codex headless: the shared one may run with other settings, and Codex asks
            // before using it.
            Provider::Codex => [
                &[
                    "codex",
                    "resume",
                    thread,
                    "--no-daemon",
                    if unrestricted { "--dangerously-bypass-approvals-and-sandbox" } else { "--sandbox=workspace-write" },
                ][..],
                CODEX_NO_BROWSER,
                if subagents() { &[] } else { CODEX_NO_SUBAGENTS },
                &compact.iter().map(String::as_str).collect::<Vec<_>>(),
            ]
            .concat(),
            Provider::Opencode => vec!["opencode", "--session", thread],
        };
        if self != Provider::Opencode
            && let Some(model) = conversation.model.as_deref()
        {
            args.extend(["--model", model])
        }
        Ok(login_shell(&args))
    }

    /// How the provider is named to the user.
    pub fn title(self) -> &'static str {
        match self {
            Provider::Codex => "Codex",
            Provider::Claude => "Claude Code",
            Provider::Opencode => "OpenCode",
        }
    }
}
