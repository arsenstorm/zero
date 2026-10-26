//! Zero's model of an agent session, the same for every provider: a conversation of items, its status and the
//! approvals it waits on. Clients never see a provider's protocol, only `Change`s to this model, so the Swift
//! apps keep a copy by applying them in order (`Conversation::apply`, mirrored in Swift).

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    /// Zero's id for the session.
    pub id: String,
    pub provider: Provider,
    pub cwd: String,
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
    pub approvals: Vec<Approval>,
    /// The unified diff of everything the latest turn changed.
    pub diff: Option<String>,
    /// How many changes have been applied: a client that took a snapshot at `seq` applies only later changes.
    pub seq: u64,
}

/// Which agent runtime a session runs on.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Codex,
    Claude,
    Opencode,
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
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ItemKind {
    User { text: String },
    /// `final_answer`: the turn's answer, as opposed to commentary while working.
    Agent { text: String, final_answer: bool },
    /// A summary of the model's reasoning, where the provider gives one.
    Reasoning { text: String },
    Plan { text: String },
    Command { command: String, cwd: String, output: String, exit_code: Option<i64>, duration_ms: Option<i64> },
    FileChange { changes: Vec<FileChange> },
    /// Any other tool: MCP, web search, the provider's own.
    Tool { name: String, detail: String },
    /// Something to read that isn't the agent speaking: an error, an interruption, or a provider item Zero
    /// doesn't show yet (named by its provider type, so nothing silently disappears).
    Notice { text: String, error: bool },
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

/// One step of a conversation's history, as sent to clients.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Change {
    Thread { thread: String, model: Option<String>, effort: Option<String> },
    Title { title: Option<String> },
    Status { status: Status, turn: Option<String>, error: Option<String> },
    /// Adds the item, or replaces the one with its id.
    Item { item: Item },
    /// Appends to an item's text (a command's output).
    Delta { item: String, text: String },
    Approval { approval: Approval },
    Resolved { approval: String },
    Diff { diff: Option<String> },
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
            id: id.into(), provider, cwd: cwd.into(), thread: None, title: None, model: None, effort: None,
            status: Status::Starting, turn: None, error: None, items: vec![], approvals: vec![], diff: None, seq: 0,
        }
    }

    pub fn item(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|item| item.id == id)
    }

    pub fn apply(&mut self, change: Change) {
        self.seq += 1;
        match change {
            Change::Thread { thread, model, effort } => {
                self.thread = Some(thread);
                if model.is_some() { self.model = model }
                if effort.is_some() { self.effort = effort }
            }
            Change::Title { title } => self.title = title,
            Change::Status { status, turn, error } => {
                self.status = status;
                self.turn = turn;
                self.error = error;
            }
            Change::Item { item } => match self.items.iter_mut().find(|existing| existing.id == item.id) {
                Some(existing) => *existing = item,
                None => self.items.push(item),
            },
            Change::Delta { item, text } => {
                if let Some(item) = self.items.iter_mut().find(|existing| existing.id == item) {
                    match &mut item.kind {
                        ItemKind::User { text: body } | ItemKind::Agent { text: body, .. } | ItemKind::Reasoning { text: body }
                        | ItemKind::Plan { text: body } | ItemKind::Notice { text: body, .. } => body.push_str(&text),
                        ItemKind::Command { output, .. } => output.push_str(&text),
                        ItemKind::FileChange { .. } | ItemKind::Tool { .. } => {}
                    }
                }
            }
            Change::Approval { approval } => {
                self.approvals.retain(|existing| existing.id != approval.id);
                self.approvals.push(approval);
            }
            Change::Resolved { approval } => self.approvals.retain(|existing| existing.id != approval),
            Change::Diff { diff } => self.diff = diff,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(id: &str, text: &str) -> Item {
        Item { id: id.into(), turn: None, kind: ItemKind::Agent { text: text.into(), final_answer: false }, status: ItemStatus::Running }
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
        let command = ItemKind::Command { command: "ls".into(), cwd: "/".into(), output: String::new(), exit_code: None, duration_ms: None };
        conversation.apply(Change::Item { item: Item { id: "c".into(), turn: None, kind: command, status: ItemStatus::Running } });
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
        assert_eq!(serde_json::to_value(change).unwrap(), serde_json::json!({"type": "status", "status": "waiting", "turn": "u", "error": null}));
        let item = Item { id: "c".into(), turn: None, kind: ItemKind::Command { command: "ls".into(), cwd: "/".into(), output: "".into(), exit_code: Some(0), duration_ms: None }, status: ItemStatus::Done };
        let json = serde_json::to_value(item).unwrap();
        assert_eq!(json["kind"]["type"], "command");
        assert_eq!(json["kind"]["exitCode"], 0);
    }
}
