//! A conversation and the adapter for its provider: every line each way goes through here and comes out as
//! applied `Change`s, the same live and on replay.

use serde_json::Value;

use crate::adapter::{Adapter, Answers, Effects};
use crate::model::{Change, Conversation, Failure, FailureKind, ItemKind, Status};

pub struct Core {
    conversation: Conversation,
    adapter: Box<dyn Adapter>,
    /// The time the line being read arrived (ms since 1970): new items are stamped with it. None leaves them unstamped.
    clock: Option<i64>,
    /// Images sent with the message on its way: they go on the next message of yours seen, however its provider
    /// echoes it (at once, or when the turn starts).
    attach: Vec<String>,
    /// The app's id for the message on its way: it goes on the next message of yours seen, as its images do.
    sent: Option<String>,
    /// Being paused for Zero's update: the agent's own note of the stop says so.
    pausing: bool,
}

impl Core {
    pub fn new(conversation: Conversation) -> Self {
        let adapter = conversation.provider.adapter();
        Core { conversation, adapter, clock: None, attach: vec![], sent: None, pausing: false }
    }

    /// The images sent with the next message of yours.
    pub fn attach(&mut self, images: Vec<String>) {
        self.attach = images;
    }

    /// The app's id for the next message of yours; none clears it (a send that failed).
    pub fn mark(&mut self, sent: Option<String>) {
        self.sent = sent;
    }

    /// Sets the time of what's read next: now when live, the transcript's record on replay.
    pub fn at(&mut self, ms: i64) {
        self.clock = Some(ms);
    }

    /// An item keeps the time it was first seen; a new one takes the clock's, as does a usage figure (when it was read).
    fn stamp(&mut self, change: &mut Change) {
        if let Change::Usage { usage } = change {
            for window in usage.windows.iter_mut().filter(|w| w.read_at.is_none()) {
                window.read_at = self.clock.map(|ms| ms / 1000)
            }
        }
        let Change::Item { item } = change else { return };
        let known = self.conversation.item(&item.id);
        if item.at.is_none() {
            item.at = known.and_then(|known| known.at).or(self.clock)
        }
        if let ItemKind::User { images, sent, .. } = &mut item.kind {
            match known.map(|k| &k.kind) {
                Some(ItemKind::User { images: kept, sent: was, .. }) => {
                    if images.is_empty() {
                        images.clone_from(kept)
                    }
                    if sent.is_none() {
                        sent.clone_from(was)
                    }
                }
                None => {
                    if images.is_empty() && !self.attach.is_empty() {
                        *images = std::mem::take(&mut self.attach)
                    }
                    if sent.is_none() {
                        *sent = self.sent.take()
                    }
                }
                _ => {}
            }
        }
        // Sent again under its id (to a process started anew, the one before having ended before reading it): the same
        // message, not another.
        if let ItemKind::User { sent: Some(id), .. } = &item.kind
            && let Some(same) = self
                .conversation
                .items
                .iter()
                .rev()
                .find(|i| i.id != item.id && matches!(&i.kind, ItemKind::User { sent: Some(was), .. } if was == id))
        {
            item.id = same.id.clone();
            item.at = same.at;
        }
    }

    /// Numbered on from at least `seq`: a replay counts fewer changes than the live session made (streamed pieces aren't
    /// kept), and clients holding the higher number would drop what follows as already seen.
    pub fn number_from(&mut self, seq: u64) {
        self.conversation.seq = self.conversation.seq.max(seq);
    }

    /// The MCP servers its CLI was given: what the adapter may sign in to.
    pub fn set_mcp(&mut self, servers: Vec<crate::mcp_servers::Resolved>) {
        self.conversation.mcp = servers;
    }

    pub fn conversation(&self) -> &Conversation {
        &self.conversation
    }

    pub fn sent(&mut self, message: &Value) -> Vec<Change> {
        let changes = self.adapter.sent(&self.conversation, message);
        self.apply(changes)
    }

    pub fn receive(&mut self, message: &Value) -> Effects {
        let mut effects = self.adapter.receive(&self.conversation, message);
        effects.changes = self.apply(std::mem::take(&mut effects.changes));
        effects
    }

    pub fn answers(&self, message: &Value) -> Option<(String, Result<Value, String>)> {
        self.adapter.answers(message)
    }

    /// The line that answers an open approval with one of the choices it offers.
    /// What Stop sends to stop the provider's background work (Adapter::stops).
    pub fn stops(&self) -> Vec<Value> {
        self.adapter.stops()
    }

    pub fn answer(&self, approval: &str, choice: &str) -> Result<Value, String> {
        let open = self.conversation.approvals.iter().find(|a| a.id == approval).ok_or_else(|| format!("No open approval {approval}"))?;
        if !open.choices.iter().any(|c| c.id == choice) {
            return Err(format!("{} doesn't offer {choice} for \"{}\"", self.conversation.provider.title(), open.title));
        }
        self.adapter.answer(open, choice)
    }

    /// The line that answers an open question, once every field has an answer.
    pub fn reply(&self, question: &str, answers: &Answers) -> Result<Value, String> {
        let open = self.conversation.questions.iter().find(|q| q.id == question).ok_or_else(|| format!("No open question {question}"))?;
        if let Some(missing) = open.fields.iter().find(|f| answers.get(&f.id).is_none_or(|a| a.iter().all(|s| s.trim().is_empty()))) {
            return Err(format!("\"{}\" has no answer", missing.question));
        }
        self.adapter.reply(open, answers)
    }

    /// Applies a change Zero makes itself and returns it for the clients. A switch brings the new provider's adapter, so
    /// its lines are read its way from here on, live and on replay.
    /// The turn's being paused for Zero's update: its stop, as the agent notes it, says that.
    pub fn pausing(&mut self, on: bool) {
        self.pausing = on
    }

    fn paused_for_update(&self, change: &mut Change) {
        if self.pausing
            && let Change::Item { item } = change
            && let ItemKind::Notice { text, error: false } = &mut item.kind
            && text == "Interrupted"
        {
            *text = crate::daemon::PAUSED_FOR_UPDATE.into();
        }
    }

    pub fn change(&mut self, mut change: Change) -> Change {
        self.paused_for_update(&mut change);
        if let Change::Switched { provider, .. } = &change {
            self.adapter = provider.adapter()
        }
        self.stamp(&mut change);
        self.conversation.apply(change.clone());
        change
    }

    /// The runtime's process is gone: no turn, and nothing left to approve.
    pub fn offline(&mut self) -> Vec<Change> {
        self.adapter.ended();
        let mut changes: Vec<Change> = self.conversation.approvals.iter().map(|a| Change::Resolved { approval: a.id.clone() }).collect();
        changes.extend(self.conversation.questions.iter().map(|q| Change::Answered { question: q.id.clone() }));
        changes.push(Change::Status { status: Status::Offline, turn: None, error: self.conversation.error.clone() });
        if self.conversation.stalled.is_some() {
            changes.push(Change::Stalled { reason: None, command: None })
        }
        self.apply(changes)
    }

    /// Something went wrong that the runtime didn't report itself (it didn't answer, say).
    pub fn report(&mut self, text: &str) -> Vec<Change> {
        let mut effects = Effects::default();
        effects.fail(&self.conversation, text);
        self.apply(effects.changes)
    }

    /// Applies the changes, then classifies the session's error if it changed: the same for every provider.
    fn apply(&mut self, mut changes: Vec<Change>) -> Vec<Change> {
        // Zero's own words to the agent (the restart's carry-on) aren't a message of yours: no item for them.
        changes.retain_mut(|change| match change {
            Change::Item { item } => match &mut item.kind {
                ItemKind::User { text, .. } => match without_carry_on(text) {
                    Some(rest) => {
                        *text = rest;
                        true
                    }
                    None => false,
                },
                _ => true,
            },
            _ => true,
        });
        for change in &mut changes {
            self.paused_for_update(change)
        }
        // A loop named in a message of yours: the agent got its words, the record keeps the name (loops.rs).
        for change in &mut changes {
            if let Change::Item { item } = change
                && let ItemKind::User { text, .. } = &mut item.kind
                && text.contains("<!-- loop: ")
            {
                *text = crate::loops::collapse(text)
            }
        }
        for change in &mut changes {
            self.stamp(change);
            self.conversation.apply(change.clone());
        }
        let failure = self.conversation.error.as_ref().map(|message| Failure { kind: FailureKind::of(message), message: message.clone() });
        if failure != self.conversation.failure {
            let change = Change::Failed { failure };
            self.conversation.apply(change.clone());
            changes.push(change);
        }
        changes
    }
}

/// A message's text without Zero's carry-on (delivered with what else was waiting, or more than once, it's still not
/// the user's); none when nothing else is left.
pub fn without_carry_on(text: &str) -> Option<String> {
    let zeros = |part: &str| {
        crate::daemon::CARRIES.contains(&part)
            || part.starts_with(crate::daemon::END_YOUR_TURN_MARK)
            || part.starts_with(crate::daemon::OPEN_ASKS_MARK)
    };
    if !text.split("\n\n").any(|part| zeros(part.trim())) {
        return Some(text.to_string());
    }
    let rest = text.split("\n\n").filter(|part| !zeros(part.trim())).collect::<Vec<_>>().join("\n\n");
    let rest = rest.trim();
    (!rest.is_empty()).then(|| rest.to_string())
}
