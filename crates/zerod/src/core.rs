//! A conversation and the adapter for its provider: every line each way goes through here and comes out as
//! applied `Change`s, the same live and on replay.

use serde_json::Value;

use crate::adapter::{Adapter, Effects};
use crate::model::{Change, Conversation, Status};

pub struct Core {
    conversation: Conversation,
    adapter: Box<dyn Adapter>,
}

impl Core {
    pub fn new(conversation: Conversation) -> Self {
        let adapter = conversation.provider.adapter();
        Core { conversation, adapter }
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
    pub fn answer(&self, approval: &str, choice: &str) -> Result<Value, String> {
        let open = self.conversation.approvals.iter().find(|a| a.id == approval).ok_or_else(|| format!("No open approval {approval}"))?;
        if !open.choices.iter().any(|c| c.id == choice) {
            return Err(format!("{} doesn't offer {choice} for \"{}\"", self.conversation.provider.title(), open.title));
        }
        self.adapter.answer(open, choice)
    }

    /// Applies a change Zero makes itself and returns it for the clients.
    pub fn change(&mut self, change: Change) -> Change {
        self.conversation.apply(change.clone());
        change
    }

    /// The runtime's process is gone: no turn, and nothing left to approve.
    pub fn offline(&mut self) -> Vec<Change> {
        self.adapter.ended();
        let mut changes: Vec<Change> = self.conversation.approvals.iter().map(|a| Change::Resolved { approval: a.id.clone() }).collect();
        changes.push(Change::Status { status: Status::Offline, turn: None, error: self.conversation.error.clone() });
        self.apply(changes)
    }

    /// Something went wrong that the runtime didn't report itself (it didn't answer, say).
    pub fn report(&mut self, text: &str) -> Vec<Change> {
        let mut effects = Effects::default();
        effects.fail(&self.conversation, text);
        self.apply(effects.changes)
    }

    fn apply(&mut self, changes: Vec<Change>) -> Vec<Change> {
        for change in &changes {
            self.conversation.apply(change.clone());
        }
        changes
    }
}
