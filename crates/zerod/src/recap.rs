//! After an agent's CLI compacts its conversation, Zero gives the agent its own record of what matters, word for word,
//! into the turn: a summary written by the model can miss the user's last words or what's still open, and the agent
//! would carry on from that.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast::error::RecvError;

use crate::adapter::COMPACTED;
use crate::ask::Ask;
use crate::daemon::Daemon;
use crate::inbox::Inbox;
use crate::model::{Change, Conversation, ItemKind, ItemStatus};
use crate::session::{Message, ModelChoice};

/// The user's latest messages the recap repeats, each up to this many characters.
const MESSAGES: usize = 8;
const LONGEST: usize = 2000;
/// How the recap starts: how it's known in the conversation.
const HEAD: &str = "Your conversation was just compacted.";

/// Hears each compaction end and gives that session its recap.
pub fn start(daemon: Arc<Daemon>, inbox: Arc<Inbox>) {
    let mut events = daemon.subscribe();
    let weak = Arc::downgrade(&daemon);
    let given = Mutex::new(HashSet::new());
    tokio::spawn(async move {
        loop {
            let event = match events.recv().await {
                Ok(event) => event,
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => return,
            };
            let Change::Item { item } = &event.change else { continue };
            if !item.id.starts_with(COMPACTED) || item.status != ItemStatus::Done {
                continue;
            }
            if !given.lock().unwrap().insert((event.session.clone(), item.id.clone())) {
                continue;
            }
            let Some(daemon) = weak.upgrade() else { return };
            let (Ok(session), Some(conversation)) = (daemon.session(&event.session), daemon.get(&event.session)) else { continue };
            if unread(&conversation) {
                continue;
            }
            let asks: Vec<Ask> = inbox.open_asks().into_iter().filter(|a| a.agent.name == format!("zerod-{}", conversation.id)).collect();
            let changed = git_status(&conversation.cwd).await;
            let words = crate::model::from_line("zero", &text(&conversation, &daemon.workers(&conversation.id), &asks, &changed));
            if let Err(error) = session.send(Message::text(&words), ModelChoice::default()).await {
                session.report(&format!("Couldn't give the agent Zero's record after compacting: {error}"));
            }
        }
    });
}

/// The last recap is still waiting for the agent: since it, only compactions (Claude Code compacting again and again
/// while the context is too big). Another would wait with it, all of them in the next request.
fn unread(conversation: &Conversation) -> bool {
    for item in conversation.items.iter().rev() {
        match &item.kind {
            ItemKind::Notice { .. } if item.id.starts_with(COMPACTED) => continue,
            ItemKind::User { text, .. } => return crate::model::from(text) == Some("zero") && text.contains(HEAD),
            _ => return false,
        }
    }
    false
}

/// What Zero knows for certain about the task, as the agent reads it after compacting.
pub fn text(conversation: &Conversation, workers: &[Conversation], asks: &[Ask], changed: &str) -> String {
    let mut parts = vec![format!(
        "{HEAD} This is Zero's own record, not a summary: where your summary says otherwise, this is right. Carry on \
with what you were doing."
    )];
    let said: Vec<String> = conversation
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::User { text, images, .. } if crate::model::from(text).is_none() => Some(named(text, images)),
            _ => None,
        })
        .collect();
    if !said.is_empty() {
        let latest = said[said.len().saturating_sub(MESSAGES)..].iter().map(|t| format!("> {}", clip(t).replace('\n', "\n> ")));
        parts.push(format!("The user's latest messages, oldest first, word for word:\n\n{}", latest.collect::<Vec<_>>().join("\n\n")));
    }
    if !asks.is_empty() {
        let open = asks.iter().map(|a| format!("- {}: {}", a.id, a.title));
        parts.push(format!("Your asks the user hasn't answered yet:\n{}", open.collect::<Vec<_>>().join("\n")));
    }
    if !conversation.issues.is_empty() {
        let rows = conversation.issues.iter().map(|i| format!("- {} ({}): {}", i.ticket, format!("{:?}", i.state).to_lowercase(), i.text));
        parts.push(format!("Your issue rows:\n{}", rows.collect::<Vec<_>>().join("\n")));
    }
    if !workers.is_empty() {
        let rows = workers.iter().map(|w| {
            let name = w.label.as_deref().or(w.title.as_deref()).unwrap_or("unnamed");
            format!("- {} ({name}): {:?}", w.id, w.attention())
        });
        parts.push(format!("Your workers:\n{}", rows.collect::<Vec<_>>().join("\n")));
    }
    if !changed.is_empty() {
        parts.push(format!("`git status` in {} now:\n{changed}", conversation.cwd))
    }
    parts.join("\n\n")
}

/// The message with each image named by its file, not attached: a few big images can push a fresh context over its
/// limit.
fn named(text: &str, images: &[String]) -> String {
    let mut words = text.to_string();
    for (n, path) in images.iter().enumerate() {
        let token = format!("[Image #{}]", n + 1);
        let name = format!("[image: {path}]");
        if words.contains(&token) { words = words.replacen(&token, &name, 1) } else { words.push_str(&format!(" {name}")) }
    }
    words
}

fn clip(text: &str) -> String {
    if text.chars().count() <= LONGEST {
        return text.to_string();
    }
    format!("{}…", text.chars().take(LONGEST).collect::<String>())
}

/// The folder's `git status`, up to 40 lines; nothing outside a repository.
async fn git_status(cwd: &str) -> String {
    let output = tokio::process::Command::new("git").args(["status", "--short", "--branch"]).current_dir(cwd).output().await;
    let Some(output) = output.ok().filter(|o| o.status.success()) else { return String::new() };
    let text = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<&str> = text.lines().collect();
    let mut shown = lines.iter().take(40).copied().collect::<Vec<_>>().join("\n");
    if lines.len() > 40 {
        shown.push_str(&format!("\n… and {} more", lines.len() - 40))
    }
    shown
}
