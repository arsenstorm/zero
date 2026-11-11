//! Zero's model of an agent session, the same for every provider: a conversation of items, its status and the
//! approvals it waits on. Clients never see a provider's protocol, only `Change`s to this model, so the Swift
//! apps keep a copy by applying them in order (`Conversation::apply`, mirrored in Swift).

use serde::{Deserialize, Serialize};

/// Who has an issue now: the user (what it needs from them), its agents, someone else, nobody for now, or no one ever.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub enum IssueState {
    You,
    Working,
    Waiting,
    Parked,
    Done,
}

impl IssueState {
    pub fn named(word: &str) -> Option<IssueState> {
        Some(match word {
            "you" | "user" | "needs-you" => IssueState::You,
            "working" => IssueState::Working,
            "waiting" | "blocked" => IssueState::Waiting,
            "parked" | "later" => IssueState::Parked,
            "done" | "completed" | "merged" => IssueState::Done,
            _ => return None,
        })
    }
}

/// One issue a lead drives, by its ticket, as the lead keeps it: who has it, and in words what it needs from the user
/// (on them), where it stands, or why it's parked. Zero keeps when it came to that state and its time on the user.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Issue {
    pub ticket: String,
    pub state: IssueState,
    pub text: String,
    /// When it came to its state, in milliseconds since 1970: on the user since then, say.
    pub since: i64,
    /// Its time on the user before now (the stretch it's in, if it is on them, aside), in milliseconds.
    #[serde(default)]
    pub on_you_ms: i64,
    /// When its agent last set it, whatever changed (ms): a turn that heard of the issue and left its row alone shows.
    #[serde(default)]
    pub updated: i64,
}

impl Issue {
    /// The row set at `now` (ms), after `previous`: its time in a state carries on while the state doesn't change.
    pub fn set(previous: Option<&Issue>, ticket: &str, state: IssueState, text: &str, now: i64) -> Issue {
        let same = previous.is_some_and(|p| p.state == state);
        let left_you = previous.filter(|p| p.state == IssueState::You && state != IssueState::You).map_or(0, |p| now - p.since);
        Issue {
            ticket: ticket.into(),
            state,
            text: text.into(),
            since: if same { previous.map_or(now, |p| p.since) } else { now },
            on_you_ms: previous.map_or(0, |p| p.on_you_ms) + left_you,
            updated: now,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    /// Zero's id for the session.
    pub id: String,
    pub provider: Provider,
    pub cwd: String,
    /// How freely the agent may act; set at start.
    #[serde(default)]
    pub permissions: Permissions,
    /// A name given by the user or the lead that started it, and a reference for the work (an issue, a ticket).
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub ticket: Option<String>,
    /// Where it runs, by name, when its folder doesn't say (`zero label --where`).
    #[serde(default)]
    pub place: Option<String>,
    /// The git branch its folder was on when it started.
    #[serde(default)]
    pub branch: Option<String>,
    /// The session that started it, for a worker.
    #[serde(default)]
    pub parent: Option<String>,
    /// The workspace it was put in (workspaces.rs); none, and its folder decides.
    #[serde(default)]
    pub workspace: Option<String>,
    /// The sign-in its CLI runs as (signins.rs), by id; none, and the CLI's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signin: Option<String>,
    /// The MCP servers its CLI is given when it starts (its workspace's, from Zero's list): in memory only, never sent
    /// to clients or kept (their values may be secrets).
    #[serde(skip)]
    pub mcp: Vec<crate::mcp_servers::Resolved>,
    /// The provider's own id for the conversation (a Codex thread), once it exists; what resuming needs.
    pub thread: Option<String>,
    pub title: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub status: Status,
    /// The turn in progress, which interrupting and steering name.
    pub turn: Option<String>,
    /// Why the last turn or request failed, until the next turn starts.
    pub error: Option<String>,
    pub items: Vec<Item>,
    /// The folder as it was when each message of yours went, by the message's id: a git commit (snapshots.rs).
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub snapshots: std::collections::BTreeMap<String, String>,
    /// The issues it drives, a row each, as its agent keeps them (`zero issue`): a lead running several at once.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub issues: Vec<Issue>,
    /// What its agent says about it beyond its name and ticket, by name ("PR": a link): `zero attr`.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub attributes: std::collections::BTreeMap<String, String>,
    pub approvals: Vec<Approval>,
    /// What the agent asked the user, waiting for their answer.
    #[serde(default)]
    pub questions: Vec<Question>,
    /// The usage limits the provider's CLI last reported for the account the session runs on.
    #[serde(default)]
    pub usage: Option<Usage>,
    /// The current error, by kind, so Zero can say what to do about it.
    #[serde(default)]
    pub failure: Option<Failure>,
    /// Why the session looks stuck, while it does: no word from the agent, a command that won't end, or the
    /// same command over and over.
    #[serde(default)]
    pub stalled: Option<String>,
    /// The unified diff of everything the latest turn changed.
    pub diff: Option<String>,
    /// While the task is in its provider's own terminal (zero-host's): which one, and where Zero's record of the
    /// provider's history stood when it opened.
    #[serde(default)]
    pub terminal: Option<Opened>,
    /// How many changes have been applied: a client that took a snapshot at `seq` applies only later changes.
    pub seq: u64,
}

/// A task's provider terminal: zero-host's id for it, and `mark`, how much of the provider's own history (lines of
/// Claude Code's session file) was already in Zero's record when it opened.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Opened {
    pub id: String,
    pub mark: usize,
}

/// Which agent runtime a session runs on.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Codex,
    Claude,
    Opencode,
}

/// How freely an agent acts. `Auto` is how the user works: the provider's own judgement decides what is safe (Claude's
/// auto-mode classifier; Codex's on-request approvals in a workspace-write sandbox; OpenCode's own rules), and Zero
/// hears what it won't allow alone. `Unrestricted` lets the agent do anything without asking, sandbox off.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum Permissions {
    #[default]
    Auto,
    Unrestricted,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    /// The runtime is starting and has no conversation yet.
    Starting,
    Idle,
    Working,
    /// Working, but stopped on an approval.
    Waiting,
    /// No runtime process: the conversation can be resumed.
    Offline,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub turn: Option<String>,
    pub kind: ItemKind,
    pub status: ItemStatus,
    /// When zerod first saw it (or its provider's record says it happened), in milliseconds since 1970.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<i64>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ItemKind {
    /// Your words, and the images sent with them (their files).
    User {
        text: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<String>,
    },
    /// `final_answer`: the turn's answer, as opposed to commentary while working.
    Agent {
        text: String,
        final_answer: bool,
    },
    /// A summary of the model's reasoning, where the provider gives one.
    Reasoning {
        text: String,
    },
    Plan {
        text: String,
    },
    Command {
        command: String,
        cwd: String,
        output: String,
        exit_code: Option<i64>,
        duration_ms: Option<i64>,
    },
    FileChange {
        changes: Vec<FileChange>,
    },
    /// Any other tool: MCP, web search, the provider's own.
    Tool {
        name: String,
        detail: String,
    },
    /// Something to read that isn't the agent speaking: an error, an interruption, or a provider item Zero
    /// doesn't show yet (named by its provider type, so nothing silently disappears).
    Notice {
        text: String,
        error: bool,
    },
    /// A table the agent handed to Zero to draw (`zero table`): a title, columns, and rows of cells.
    Table {
        title: String,
        columns: Vec<String>,
        rows: Vec<Vec<String>>,
    },
}

/// Words given to a session by Zero rather than typed by the user (a worker's report to its lead, a watched command's
/// end, a script's notice) start with this: `<!-- from: <session id or zero> -->` on a line of its own. The agent
/// reads past it; the app shows such a message as what it is, not as the user's, and the rail leaves it out.
pub const FROM: &str = "<!-- from: ";

/// Who a message is from, when it isn't the user: the session id, or "zero".
pub fn from(text: &str) -> Option<&str> {
    let rest = text.strip_prefix(FROM)?;
    let end = rest.find(" -->")?;
    Some(&rest[..end])
}

pub fn from_line(who: &str, text: &str) -> String {
    format!("{FROM}{who} -->\n{text}")
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ItemStatus {
    Running,
    Done,
    Failed,
    Declined,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileChange {
    pub path: String,
    /// "add", "delete" or "update".
    pub kind: String,
    /// Where an update moved the file, if it did.
    pub move_path: Option<String>,
    pub diff: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Approval {
    /// The provider's id for the request, as text.
    pub id: String,
    /// The item the approval is about, when the provider names one.
    pub item: Option<String>,
    pub kind: ApprovalKind,
    pub title: String,
    pub command: Option<String>,
    pub cwd: Option<String>,
    pub reason: Option<String>,
    /// For a file approval, what will change.
    pub changes: Vec<FileChange>,
    /// The answers the provider takes for this request, in its order.
    pub choices: Vec<Choice>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ApprovalKind {
    Command,
    FileChange,
    /// Any other tool: a web fetch, an MCP tool.
    Tool,
}

/// The agent asking the user something (Claude's AskUserQuestion, Codex's request for input): one or more fields answered
/// together.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Question {
    /// The provider's id for the request.
    pub id: String,
    pub item: Option<String>,
    pub fields: Vec<Field>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Field {
    /// What the answer is keyed by.
    pub id: String,
    /// A word or two naming the question ("Cache").
    pub header: Option<String>,
    pub question: String,
    pub options: Vec<QuestionOption>,
    /// More than one option may be picked.
    pub multiple: bool,
    /// An answer in the user's own words is taken too.
    pub other: bool,
    /// The answer is a secret: shown as dots, never logged by Zero.
    pub secret: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct QuestionOption {
    pub label: String,
    pub description: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    /// A limit is reached: the provider won't take more until `resets_at`.
    pub limited: bool,
    /// Unix seconds.
    pub resets_at: Option<i64>,
    pub windows: Vec<UsageWindow>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    /// "5 hours", "7 days".
    pub name: String,
    /// The share of the window used, 0 to 1.
    pub used: f64,
    pub resets_at: Option<i64>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Failure {
    pub kind: FailureKind,
    pub message: String,
}

/// What went wrong, as far as what the user can do about it: wait for a reset, sign in with the CLI, check the
/// network, pick another model, or read the message.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum FailureKind {
    Limit,
    SignIn,
    Network,
    Model,
    Other,
}

impl FailureKind {
    /// From an error's text: the CLIs report failures as messages, not codes.
    pub fn of(message: &str) -> FailureKind {
        let text = message.to_lowercase();
        let any = |words: &[&str]| words.iter().any(|w| text.contains(w));
        if any(&["usage limit", "rate limit", "limit reached", "hit your limit", "quota", "credit balance"]) {
            return FailureKind::Limit;
        }
        if any(&["not logged in", "/login", "unauthorized", "oauth", "401", "403", "sign in", "authentication"]) {
            return FailureKind::SignIn;
        }
        if any(&["overloaded", "529"]) || (text.contains("model") && any(&["not available", "unavailable", "not found", "does not exist"]))
        {
            return FailureKind::Model;
        }
        if any(&[
            "enotfound",
            "network",
            "dns",
            "econnreset",
            "econnrefused",
            "timed out",
            "connection",
            "stream disconnected",
            "server error",
            "api error: 5",
        ]) {
            return FailureKind::Network;
        }
        FailureKind::Other
    }
}

/// What a session needs from the user, most urgent first: the bar's dot.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Attention {
    /// A question or an approval waits for them.
    NeedsYou,
    /// A usage limit stopped it until it resets.
    Limited,
    /// It has stopped making progress (`stalled` says how).
    Stuck,
    /// The last turn or request failed.
    Failed,
    /// It ended its turn blocked on something that isn't the user (CI, another team, an outage): they'd have been asked.
    Blocked,
    Working,
    /// Its answer is there to read.
    Done,
    /// It answered the user and waits on nothing: the answer is there to read, and that is all (the app shows it as
    /// Replied until the user has seen it).
    Answered,
    Idle,
    Offline,
    Starting,
}

/// One answer to an approval, as the provider offers it: `id` is the adapter's, `label` what Zero shows.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Choice {
    pub id: String,
    pub label: String,
    pub kind: ChoiceKind,
}

/// What a choice does, the same for every provider, so the inbox can put Allow under 1 and Deny last.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ChoiceKind {
    Allow,
    /// Allow this and anything like it until the session ends.
    AllowSession,
    /// Allow this and anything like it from now on: the provider keeps a rule.
    AllowAlways,
    Deny,
    /// Deny, and end the turn.
    Stop,
}

/// Words waiting for a session until it is between turns: a message of the user's, queued to go after the current
/// turn, one turn each; or a report (a worker's, Zero's own), which go together.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Queued {
    pub id: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub report: bool,
}

/// One step of a conversation's history, as sent to clients.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Change {
    Thread {
        thread: String,
        model: Option<String>,
        effort: Option<String>,
    },
    Title {
        title: Option<String>,
    },
    Named {
        label: Option<String>,
        ticket: Option<String>,
    },
    /// Put in a workspace (none: back to Zero).
    Placed {
        workspace: Option<String>,
    },
    /// Runs as another sign-in from its next start (signins.rs): one of its CLI's accounts at its limit, say.
    SignedIn {
        signin: Option<String>,
    },
    /// What the agent may do without asking, from its next start (set between turns).
    Permitted {
        permissions: Permissions,
    },
    Status {
        status: Status,
        turn: Option<String>,
        error: Option<String>,
    },
    /// Adds the item, or replaces the one with its id.
    Item {
        item: Item,
    },
    /// Appends to an item's text (a command's output).
    Delta {
        item: String,
        text: String,
    },
    Approval {
        approval: Approval,
    },
    Resolved {
        approval: String,
    },
    Question {
        question: Question,
    },
    Answered {
        question: String,
    },
    Usage {
        usage: Usage,
    },
    Failed {
        failure: Option<Failure>,
    },
    Stalled {
        reason: Option<String>,
    },
    Diff {
        diff: Option<String>,
    },
    /// The task moves to another provider: it starts a thread of its own there, from Zero's record (handoff.rs).
    Switched {
        provider: Provider,
        model: Option<String>,
        effort: Option<String>,
    },
    /// The task went to its provider's terminal, or came back from it.
    Terminal {
        terminal: Option<Opened>,
    },
    /// The task was put away (zerod's archive/): clients drop it. Never kept in a transcript.
    Archived,
    /// Where the task runs, by name (a worktree, a machine), when its folder doesn't say.
    Place {
        place: Option<String>,
    },
    /// The task became a worker of another (a lead adopting it), or a lead of its own again.
    Parent {
        parent: Option<String>,
    },
    /// Its agent said something about the task (`zero attr`); no value takes it back.
    Attribute {
        name: String,
        value: Option<String>,
    },
    /// An issue's row set (`zero issue`): replaces the row for its ticket.
    Issue {
        issue: Issue,
    },
    /// The folder was kept (snapshots.rs) as it was when this message of yours went.
    Snapshot {
        item: String,
        commit: String,
    },
    /// Back to just before this message of yours: it and everything after it go, and so does the provider's thread,
    /// which goes on from Zero's record up to here.
    Rewound {
        before: String,
    },
}

/// A change as clients receive it: which session, and its place in that session's sequence.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Event {
    pub session: String,
    pub seq: u64,
    pub change: Change,
}

impl Conversation {
    pub fn new(id: &str, provider: Provider, cwd: &str) -> Self {
        Conversation {
            id: id.into(),
            provider,
            cwd: cwd.into(),
            permissions: Permissions::Auto,
            label: None,
            ticket: None,
            place: None,
            branch: None,
            parent: None,
            workspace: None,
            signin: None,
            thread: None,
            title: None,
            model: None,
            effort: None,
            status: Status::Starting,
            turn: None,
            error: None,
            items: vec![],
            snapshots: Default::default(),
            issues: vec![],
            attributes: Default::default(),
            approvals: vec![],
            questions: vec![],
            usage: None,
            failure: None,
            stalled: None,
            diff: None,
            terminal: None,
            seq: 0,
            mcp: vec![],
        }
    }

    pub fn item(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|item| item.id == id)
    }

    /// The last thing the agent gave as an answer.
    /// Everything but its items, without copying them: for lists, the board, and snapshots that send items in pages.
    pub fn with_items(&self, items: Vec<Item>) -> Conversation {
        Conversation {
            id: self.id.clone(),
            provider: self.provider,
            cwd: self.cwd.clone(),
            permissions: self.permissions,
            label: self.label.clone(),
            ticket: self.ticket.clone(),
            place: self.place.clone(),
            branch: self.branch.clone(),
            parent: self.parent.clone(),
            workspace: self.workspace.clone(),
            signin: self.signin.clone(),
            thread: self.thread.clone(),
            title: self.title.clone(),
            model: self.model.clone(),
            effort: self.effort.clone(),
            status: self.status,
            turn: self.turn.clone(),
            error: self.error.clone(),
            items,
            snapshots: self.snapshots.clone(),
            issues: self.issues.clone(),
            attributes: self.attributes.clone(),
            approvals: self.approvals.clone(),
            questions: self.questions.clone(),
            usage: self.usage.clone(),
            failure: self.failure.clone(),
            stalled: self.stalled.clone(),
            diff: self.diff.clone(),
            terminal: self.terminal.clone(),
            seq: self.seq,
            mcp: self.mcp.clone(),
        }
    }

    pub fn answer(&self) -> Option<&str> {
        self.items.iter().rev().find_map(|item| match &item.kind {
            ItemKind::Agent { text, final_answer: true } => Some(text.as_str()),
            _ => None,
        })
    }

    /// Its last word was a plain answer to the user: no ending, no question; a lead's, since a worker's answer is its
    /// report. The app shows it as Replied until the user has seen it, parked or not.
    pub fn replied(&self) -> bool {
        self.parent.is_none()
            && matches!(self.items.last().map(|i| &i.kind),
            Some(ItemKind::Agent { text, final_answer: true }) if crate::board::ending(text).is_none() && !text.lines().any(|l| l.trim_end().ends_with('?')))
    }

    pub fn attention(&self) -> Attention {
        if !self.approvals.is_empty() || !self.questions.is_empty() {
            return Attention::NeedsYou;
        }
        if self.usage.as_ref().is_some_and(|u| u.limited) || self.failure.as_ref().is_some_and(|f| f.kind == FailureKind::Limit) {
            return Attention::Limited;
        }
        if self.stalled.is_some() {
            return Attention::Stuck;
        }
        if self.failure.is_some() {
            return Attention::Failed;
        }
        match self.status {
            Status::Working | Status::Waiting => Attention::Working,
            Status::Starting => Attention::Starting,
            Status::Offline => Attention::Offline,
            Status::Idle => self.ended(),
        }
    }

    /// How its last turn left it, between turns (or parked since, its process stopped while it waited). A worker's
    /// answer is its report to its lead: done, unless its ending says it waits on someone, asked the user, or is only
    /// between steps. A lead's answer says whether the task is done or waits on the user:
    /// Zero's ending, or a question put to them in prose (any line ending in one: "Could you reopen OrbStack?" comes
    /// mid-answer as often as last). An answer with neither is a turn finished, not a task.
    pub fn ended(&self) -> Attention {
        // Zero's own lines after it (paused for an update, carried on) are Zero's, not the agent's: looked past.
        match self.items.iter().rev().find(|i| !matches!(i.kind, ItemKind::Notice { .. })).map(|i| &i.kind) {
            Some(ItemKind::Agent { text, final_answer: true }) if self.parent.is_some() => match crate::board::ending(text) {
                Some("waiting") => Attention::Blocked,
                Some("asked") => Attention::NeedsYou,
                Some("working") => Attention::Idle,
                _ => Attention::Done,
            },
            // A question in its reply waits on the user, whatever its ending says (a conversation's turn ends so).
            Some(ItemKind::Agent { text, final_answer: true })
                if crate::board::ending(text) != Some("asked") && crate::board::asks_in_prose(text) =>
            {
                Attention::NeedsYou
            }
            Some(ItemKind::Agent { text, final_answer: true }) => match crate::board::ending(text) {
                Some("done") => Attention::Done,
                Some("asked") => Attention::NeedsYou,
                Some("waiting") => Attention::Blocked,
                Some(_) => Attention::Idle,
                None if text.lines().any(|l| l.trim_end().ends_with('?')) => Attention::NeedsYou,
                None => Attention::Answered,
            },
            _ => Attention::Idle,
        }
    }

    pub fn apply(&mut self, change: Change) {
        self.seq += 1;
        match change {
            Change::Thread { thread, model, effort } => self.set_thread(thread, model, effort),
            Change::Title { title } => self.title = title,
            Change::Named { label, ticket } => (self.label, self.ticket) = (label, ticket),
            Change::Placed { workspace } => self.workspace = workspace,
            Change::SignedIn { signin } => self.signin = signin,
            Change::Permitted { permissions } => self.permit(permissions),
            Change::Status { status, turn, error } => (self.status, self.turn, self.error) = (status, turn, error),
            Change::Item { item } => self.put_item(item),
            Change::Delta { item, text } => self.append_to(&item, &text),
            Change::Approval { approval } => put_last(&mut self.approvals, approval, |a| &a.id),
            Change::Resolved { approval } => self.approvals.retain(|existing| existing.id != approval),
            Change::Question { question } => put_last(&mut self.questions, question, |q| &q.id),
            Change::Answered { question } => self.questions.retain(|existing| existing.id != question),
            Change::Usage { usage } => self.usage = Some(usage),
            Change::Failed { failure } => self.failure = failure,
            Change::Stalled { reason } => self.stalled = reason,
            Change::Diff { diff } => self.diff = diff,
            Change::Terminal { terminal } => self.terminal = terminal,
            Change::Archived => {}
            Change::Place { place } => self.place = place,
            Change::Parent { parent } => self.parent = parent,
            Change::Snapshot { item, commit } => {
                self.snapshots.insert(item, commit);
            }
            Change::Attribute { name, value } => self.set_attribute(name, value),
            Change::Issue { issue } => match self.issues.iter_mut().find(|i| i.ticket == issue.ticket) {
                Some(row) => *row = issue,
                None => self.issues.push(issue),
            },
            Change::Rewound { before } => self.rewind_to(&before),
            Change::Switched { provider, model, effort } => self.switch_to(provider, model, effort),
        }
    }

    /// On its thread; the model and effort only when it says which.
    fn set_thread(&mut self, thread: String, model: Option<String>, effort: Option<String>) {
        self.thread = Some(thread);
        if model.is_some() {
            self.model = model
        }
        if effort.is_some() {
            self.effort = effort
        }
    }

    /// New permissions, and a notice in the conversation of what they let the agent do.
    fn permit(&mut self, permissions: Permissions) {
        self.permissions = permissions;
        let text = match permissions {
            Permissions::Auto => "Auto from here: it asks before what isn't safe",
            Permissions::Unrestricted => "Unrestricted from here: it acts without asking",
        };
        self.items.push(Item {
            at: None,
            id: format!("permitted-{}", self.items.len()),
            turn: None,
            kind: ItemKind::Notice { text: text.into(), error: false },
            status: ItemStatus::Done,
        });
    }

    /// The item in place of the one with its id, where that one was; else last.
    fn put_item(&mut self, item: Item) {
        match self.items.iter_mut().find(|existing| existing.id == item.id) {
            Some(existing) => *existing = item,
            None => self.items.push(item),
        }
    }

    /// Streamed text added to the item's: its words, or a command's output.
    fn append_to(&mut self, id: &str, text: &str) {
        let Some(item) = self.items.iter_mut().find(|existing| existing.id == id) else { return };
        match &mut item.kind {
            ItemKind::User { text: body, .. }
            | ItemKind::Agent { text: body, .. }
            | ItemKind::Reasoning { text: body }
            | ItemKind::Plan { text: body }
            | ItemKind::Notice { text: body, .. } => body.push_str(text),
            ItemKind::Command { output, .. } => output.push_str(text),
            ItemKind::FileChange { .. } | ItemKind::Tool { .. } | ItemKind::Table { .. } => {}
        }
    }

    /// An attribute set, or with no value taken back.
    fn set_attribute(&mut self, name: String, value: Option<String>) {
        match value {
            Some(value) => {
                self.attributes.insert(name, value);
            }
            None => {
                self.attributes.remove(&name);
            }
        }
    }

    /// Back to just before the item `before`: what came from it on, and the thread, turn and what was pending, gone.
    fn rewind_to(&mut self, before: &str) {
        if let Some(at) = self.items.iter().position(|i| i.id == before) {
            self.items.truncate(at)
        }
        let kept: std::collections::HashSet<&str> = self.items.iter().map(|i| i.id.as_str()).collect();
        self.snapshots.retain(|item, _| kept.contains(item.as_str()));
        self.thread = None;
        self.turn = None;
        self.approvals.clear();
        self.questions.clear();
        self.diff = None;
        self.error = None;
        self.failure = None;
        self.stalled = None;
    }

    /// On another provider, with no thread of its own yet.
    fn switch_to(&mut self, provider: Provider, model: Option<String>, effort: Option<String>) {
        self.provider = provider;
        self.thread = None;
        self.model = model;
        self.effort = effort;
        // Where each provider took over, in the conversation itself (handoff.rs leaves notices out). Stopped
        // for the handover, the two are one line.
        if let Some(last) = self.items.last_mut()
            && let ItemKind::Notice { text, error: false } = &mut last.kind
            && text == "Interrupted"
        {
            *text = format!("Interrupted and continued in {}", provider.title());
        } else {
            let id = format!("switched-{}", self.seq);
            self.items.push(Item {
                at: None,
                id,
                turn: None,
                kind: ItemKind::Notice { text: format!("Continued in {}", provider.title()), error: false },
                status: ItemStatus::Done,
            });
        }
    }
}

/// `new` in place of the one with its id, which goes; `new` last.
fn put_last<T>(list: &mut Vec<T>, new: T, id: impl Fn(&T) -> &str) {
    let key = id(&new);
    list.retain(|existing| id(existing) != key);
    list.push(new);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(id: &str, text: &str) -> Item {
        Item {
            at: None,
            id: id.into(),
            turn: None,
            kind: ItemKind::Agent { text: text.into(), final_answer: false },
            status: ItemStatus::Running,
        }
    }

    #[test]
    fn an_item_with_a_known_id_is_replaced_not_added() {
        let mut conversation = Conversation::new("s", Provider::Codex, "/");
        conversation.apply(Change::Item { item: agent("a", "draft") });
        conversation.apply(Change::Item { item: agent("a", "final") });
        assert_eq!(conversation.items, vec![agent("a", "final")]);
        assert_eq!(conversation.seq, 2);
    }

    #[test]
    fn a_delta_appends_to_text_or_to_a_commands_output() {
        let mut conversation = Conversation::new("s", Provider::Codex, "/");
        conversation.apply(Change::Item { item: agent("a", "Hel") });
        let command =
            ItemKind::Command { command: "ls".into(), cwd: "/".into(), output: String::new(), exit_code: None, duration_ms: None };
        conversation
            .apply(Change::Item { item: Item { at: None, id: "c".into(), turn: None, kind: command, status: ItemStatus::Running } });
        conversation.apply(Change::Delta { item: "a".into(), text: "lo".into() });
        conversation.apply(Change::Delta { item: "c".into(), text: "total 0\n".into() });
        conversation.apply(Change::Delta { item: "missing".into(), text: "ignored".into() });
        assert!(matches!(&conversation.items[0].kind, ItemKind::Agent { text, .. } if text == "Hello"));
        assert!(matches!(&conversation.items[1].kind, ItemKind::Command { output, .. } if output == "total 0\n"));
        assert_eq!(conversation.seq, 5, "every change counts, even one that finds nothing");
    }

    #[test]
    fn changes_are_tagged_with_their_type_in_camel_case() {
        let change = Change::Status { status: Status::Waiting, turn: Some("u".into()), error: None };
        assert_eq!(
            serde_json::to_value(change).unwrap(),
            serde_json::json!({"type": "status", "status": "waiting", "turn": "u", "error": null})
        );
        let item = Item {
            at: None,
            id: "c".into(),
            turn: None,
            kind: ItemKind::Command { command: "ls".into(), cwd: "/".into(), output: "".into(), exit_code: Some(0), duration_ms: None },
            status: ItemStatus::Done,
        };
        let json = serde_json::to_value(item).unwrap();
        assert_eq!(json["kind"]["type"], "command");
        assert_eq!(json["kind"]["exitCode"], 0);
    }
}

/// A change picked while a turn runs, for the turns after it: another provider, model or effort, other permissions.
/// Kept with the task (next.json) and applied as the turn ends, before what's queued goes.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Next {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<Provider>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permissions: Option<Permissions>,
}

impl Next {
    pub fn is_empty(&self) -> bool {
        *self == Next::default()
    }
}
