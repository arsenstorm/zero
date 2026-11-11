//! Going back to a message of yours: the conversation, the folder as it was then, or a branch from there.

use super::*;

impl Daemon {
    /// The folder kept now and noted as how it was when `item` went (what sending does before each message).
    pub fn snapshot_for(&self, id: &str, item: &str) -> Option<String> {
        let session = self.session(id).ok()?;
        let commit = crate::snapshots::take(Path::new(&session.summary().cwd), &format!("{id}/{}", now_ms()))?;
        session.change(Change::Snapshot { item: item.into(), commit: commit.clone() });
        Some(commit)
    }

    /// What going back to `item` would do to the folder: whether it was kept then, and what changed in it since.
    pub fn rewind_preview(&self, id: &str, item: &str) -> Result<serde_json::Value, String> {
        let conversation = self.session(id)?.snapshot();
        yours(&conversation, item)?;
        let since = conversation.snapshots.get(item).and_then(|commit| crate::snapshots::preview(Path::new(&conversation.cwd), commit));
        Ok(match since {
            Some(diff) => {
                serde_json::json!({"snapshot": true, "files": diff.files, "insertions": diff.insertions, "deletions": diff.deletions})
            }
            None => serde_json::json!({"snapshot": false}),
        })
    }

    /// Back to just before `item`, a message of yours: the conversation (its provider going on from Zero's record up to
    /// there), the folder as it was when the message went, or both. Gives the message back, to send again or change.
    pub async fn rewind(&self, id: &str, item: &str, what: Rewind) -> Result<serde_json::Value, String> {
        let session = self.session(id)?;
        let current = session.snapshot();
        let (_, text, images) = yours(&current, item)?;
        if current.terminal.is_some() {
            return Err(format!("{} is open in its terminal; go back to Zero first", current.provider.title()));
        }
        if matches!(current.status, Status::Working | Status::Waiting) {
            return Err(format!("{} is working; stop its turn first", current.provider.title()));
        }
        let mut restored = serde_json::Value::Null;
        if matches!(what, Rewind::Code | Rewind::Both) {
            let commit = current
                .snapshots
                .get(item)
                .cloned()
                .ok_or("Zero didn't keep the folder for that message, so its code can't be brought back")?;
            let (cwd, point) = (current.cwd.clone(), format!("{id}/restore-{}", now_ms()));
            let diff = tokio::task::spawn_blocking(move || crate::snapshots::restore(Path::new(&cwd), &commit, &point))
                .await
                .map_err(|e| e.to_string())??;
            restored = serde_json::json!(diff);
        }
        if matches!(what, Rewind::Conversation | Rewind::Both) {
            self.take_offline(&session).await;
            session.change(Change::Rewound { before: item.into() });
            self.rethread(&session)?;
        }
        Ok(serde_json::json!({"text": text, "images": images, "code": restored}))
    }

    /// A new task beside this one, its conversation as it was just before `item`; this one stays as it is. Gives the
    /// message back, to send there.
    pub fn branch(&self, id: &str, item: &str) -> Result<serde_json::Value, String> {
        let original = self.session(id)?.snapshot();
        let (at, text, images) = yours(&original, item)?;
        let branch = new_id();
        let mut conversation = Conversation::new(&branch, original.provider, &original.cwd);
        conversation.permissions = original.permissions;
        conversation.parent = original.parent.clone();
        conversation.branch = original.branch.clone();
        let session =
            Session::new(conversation, Some(self.home.join("sessions").join(&branch)), self.events.clone()).map_err(|e| e.to_string())?;
        session.change(Change::Status { status: Status::Offline, turn: None, error: None });
        for kept in &original.items[..at] {
            session.change(Change::Item { item: kept.clone() })
        }
        for kept in &original.items[..at] {
            if let Some(commit) = original.snapshots.get(&kept.id) {
                session.change(Change::Snapshot { item: kept.id.clone(), commit: commit.clone() })
            }
        }
        session.change(Change::Named {
            label: Some(format!("{} (branch)", crate::bridge::label(&original))),
            ticket: original.ticket.clone(),
        });
        self.rethread(&session)?;
        self.attention.lock().unwrap().insert(branch.clone(), Attention::Offline);
        self.sessions.lock().unwrap().push(session.clone());
        session.announce();
        Ok(serde_json::json!({"session": branch, "text": text, "images": images}))
    }
}

/// What rewinding brings back: the conversation, the folder's code, or both.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rewind {
    Conversation,
    Code,
    Both,
}

/// A message of yours in the conversation: where it is, its words and its images.
fn yours(conversation: &Conversation, item: &str) -> Result<(usize, String, Vec<String>), String> {
    let at = conversation.items.iter().position(|i| i.id == item).ok_or("That message isn't in the conversation")?;
    match &conversation.items[at].kind {
        ItemKind::User { text, images, .. } => Ok((at, text.clone(), images.clone())),
        _ => Err("Only a message of yours can be gone back to".into()),
    }
}
