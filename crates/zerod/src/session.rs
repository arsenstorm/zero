//! One agent session: a runtime process speaking JSON lines, the conversation its provider's adapter makes of what
//! it says, and a transcript on disk of every line each way. A session outlives its process: when the process
//! ends the session goes offline, keeps its conversation, and `resume` gives it a new process on the same
//! conversation. After a restart of the daemon, `load` rebuilds it from the transcript.

use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use tokio::time::Instant;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::process::Child;
use tokio::sync::{broadcast, mpsc, oneshot};

use crate::core::Core;
use crate::model::{Change, ChoiceKind, Conversation, Event, Item, ItemKind, ItemStatus, Permissions, Provider};
use crate::{acp, claude, codex};

/// How long a request waits for its answer. Turns run long, but the requests that wait answer at once.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(60);

/// When a working session counts as stuck: no word from its agent, one command running, or the same command in a row.
/// ponytail: fixed; a setting per project if a suite legitimately runs longer.
const SILENT: Duration = Duration::from_secs(10 * 60);
const LONG_COMMAND: Duration = Duration::from_secs(30 * 60);
const REPEATS: usize = 5;
const WATCH_EVERY: Duration = Duration::from_secs(15);

/// The two ends of a runtime's stdio, and its process when there is one.
pub struct Transport {
    reader: Box<dyn AsyncRead + Send + Unpin>,
    writer: Box<dyn AsyncWrite + Send + Unpin>,
    child: Option<Child>,
}

impl Transport {
    pub fn new(reader: impl AsyncRead + Send + Unpin + 'static, writer: impl AsyncWrite + Send + Unpin + 'static) -> Self {
        Transport { reader: Box::new(reader), writer: Box::new(writer), child: None }
    }

    pub fn with_child(mut self, child: Child) -> Self {
        self.child = Some(child);
        self
    }
}

#[derive(Clone)]
pub struct Session(Arc<Mutex<Inner>>);

struct Inner {
    core: Core,
    events: broadcast::Sender<Event>,
    transcript: Option<File>,
    /// Lines to the runtime; None while offline.
    out: Option<mpsc::UnboundedSender<Value>>,
    child: Option<Child>,
    /// Zero's requests waiting for an answer, by id.
    waiting: HashMap<String, oneshot::Sender<Result<Value, String>>>,
    /// Approvals already answered, so a second answer (from another client, say) is refused.
    answered: HashSet<String>,
    next: u64,
    /// Bumped by each attach, so the end of an old process doesn't take a resumed session offline.
    generation: u64,
    /// When the runtime last said anything, and when each command still running started.
    heard: Instant,
    running: HashMap<String, Instant>,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Meta {
    id: String,
    provider: Provider,
    cwd: String,
    #[serde(default)]
    permissions: Permissions,
    #[serde(default)]
    parent: Option<String>,
    #[serde(default)]
    branch: Option<String>,
    /// The provider's conversation id when Zero chose it (Claude's `--session-id`), before the runtime said anything.
    thread: Option<String>,
}

impl Session {
    /// A new session; with `dir`, its metadata and transcript are kept there.
    pub fn new(conversation: Conversation, dir: Option<PathBuf>, events: broadcast::Sender<Event>) -> io::Result<Session> {
        let transcript = match dir {
            Some(dir) => {
                std::fs::create_dir_all(&dir)?;
                let meta = Meta { id: conversation.id.clone(), provider: conversation.provider, cwd: conversation.cwd.clone(),
                                  permissions: conversation.permissions, parent: conversation.parent.clone(), branch: conversation.branch.clone(),
                                  thread: conversation.thread.clone() };
                std::fs::write(dir.join("meta.json"), serde_json::to_vec(&meta)?)?;
                Some(append(&dir)?)
            }
            None => None,
        };
        Ok(Session::with(Core::new(conversation), transcript, events, 1))
    }

    /// The session kept in `dir`, its conversation replayed from the transcript, offline.
    pub fn load(dir: &Path, events: broadcast::Sender<Event>) -> io::Result<Session> {
        let meta: Meta = serde_json::from_slice(&std::fs::read(dir.join("meta.json"))?)?;
        let mut conversation = Conversation::new(&meta.id, meta.provider, &meta.cwd);
        conversation.thread = meta.thread;
        conversation.permissions = meta.permissions;
        conversation.parent = meta.parent;
        conversation.branch = meta.branch;
        let mut core = Core::new(conversation);
        let mut lines = 0;
        if let Ok(file) = File::open(dir.join("transcript.jsonl")) {
            for line in io::BufReader::new(file).lines() {
                lines += 1;
                // A line cut short by a crash is the last one; everything before it still counts.
                let Ok(entry) = serde_json::from_str::<Value>(&line?) else { continue };
                if let Some(message) = entry.get("out") { core.sent(message); }
                if let Some(message) = entry.get("in") { core.receive(message); }
                if entry.get("offline").is_some() { core.offline(); }
                if let Some(change) = entry.get("change").and_then(|c| serde_json::from_value(c.clone()).ok()) { core.change(change); }
            }
        }
        core.offline();
        Ok(Session::with(core, Some(append(dir)?), events, lines + 1))
    }

    fn with(core: Core, transcript: Option<File>, events: broadcast::Sender<Event>, next: u64) -> Session {
        Session(Arc::new(Mutex::new(Inner {
            core, events, transcript, out: None, child: None, waiting: HashMap::new(), answered: HashSet::new(), next, generation: 0,
            heard: Instant::now(), running: HashMap::new(),
        })))
    }

    pub fn snapshot(&self) -> Conversation {
        self.lock().core.conversation().clone()
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // A panic while holding the lock leaves the conversation as it was after the last full change.
        self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn provider(&self) -> Provider {
        self.lock().core.conversation().provider
    }

    /// True while a runtime process is connected.
    pub fn is_attached(&self) -> bool {
        self.lock().out.is_some()
    }

    /// Starts the runtime's side of the session, with `prompt` as its first turn.
    pub async fn start(&self, transport: Transport, prompt: &str, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        match self.provider() {
            Provider::Codex => codex::start(self, transport, prompt, model, effort).await,
            Provider::Claude => claude::start(self, transport, prompt).await,
            Provider::Opencode => acp::start(self, transport, prompt, model, effort).await,
        }
    }

    /// Gives an offline session a new process on its conversation.
    pub async fn resume(&self, transport: Transport) -> Result<(), String> {
        match self.provider() {
            Provider::Codex => codex::resume(self, transport).await,
            Provider::Claude => claude::resume(self, transport).await,
            Provider::Opencode => acp::resume(self, transport).await,
        }
    }

    /// Arsen's words: steering or queued behind the turn in progress where the provider allows it, else a new turn.
    pub async fn send(&self, text: &str, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        let conversation = self.snapshot();
        if !self.is_attached() { return Err(format!("{} is offline; resume it first", conversation.id)) }
        match conversation.provider {
            Provider::Codex => codex::send(self, text, model, effort).await,
            Provider::Claude => claude::send(self, text, model).await,
            Provider::Opencode => acp::send(self, text, model, effort).await,
        }
    }

    pub async fn interrupt(&self) -> Result<(), String> {
        match self.provider() {
            Provider::Codex => codex::interrupt(self).await,
            Provider::Claude => claude::interrupt(self).await,
            Provider::Opencode => acp::interrupt(self).await,
        }
    }

    /// Answers an open approval with one of the choices it offers, once.
    pub async fn decide(&self, approval: &str, choice: &str) -> Result<(), String> {
        let mut inner = self.lock();
        if inner.answered.contains(approval) { return Err(format!("{approval} was already answered")) }
        let line = inner.core.answer(approval, choice)?;
        inner.send(line)?;
        inner.answered.insert(approval.into());
        Ok(())
    }

    /// Answers an open question, every field of it, once.
    pub async fn answer(&self, question: &str, answers: &crate::adapter::Answers) -> Result<(), String> {
        let mut inner = self.lock();
        if inner.answered.contains(question) { return Err(format!("{question} was already answered")) }
        let line = inner.core.reply(question, answers)?;
        inner.send(line)?;
        inner.answered.insert(question.into());
        Ok(())
    }

    /// Ends the runtime's process; the session stays, offline, to be resumed.
    pub fn stop(&self) {
        let generation = {
            let mut inner = self.lock();
            match inner.child.as_mut() {
                // Its output ends when it does, and that takes the session offline.
                Some(child) => { let _ = child.start_kill(); return }
                None => inner.generation,
            }
        };
        // Without a process of its own there is nothing to wait for.
        self.ended(generation);
    }

    /// Tells subscribers the session exists, before its runtime has said anything.
    pub fn announce(&self) {
        let conversation = self.snapshot();
        self.change(Change::Status { status: conversation.status, turn: None, error: None });
    }

    /// Shows an error the runtime didn't report itself, such as a start that never finished.
    pub fn report(&self, text: &str) {
        let mut inner = self.lock();
        let changes = inner.core.report(text);
        for change in &changes { inner.record(json!({"change": change})); }
        inner.broadcast(changes);
    }

    /// Connects a runtime's stdio to the session and starts reading it.
    pub fn attach(&self, transport: Transport) {
        let Transport { reader, mut writer, child } = transport;
        let (out, mut lines_out) = mpsc::unbounded_channel::<Value>();
        let generation = {
            let mut inner = self.lock();
            inner.generation += 1;
            inner.out = Some(out);
            inner.child = child;
            inner.answered.clear();
            inner.heard = Instant::now();
            inner.generation
        };
        let watched = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(WATCH_EVERY).await;
                if !watched.watch(generation) { break }
            }
        });
        tokio::spawn(async move {
            while let Some(message) = lines_out.recv().await {
                let mut line = serde_json::to_vec(&message).unwrap_or_default();
                line.push(b'\n');
                if writer.write_all(&line).await.is_err() || writer.flush().await.is_err() { break }
            }
        });
        let session = self.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                // Anything that isn't JSON (a shell's greeting before the runtime starts) is not the runtime speaking.
                if let Ok(message) = serde_json::from_str::<Value>(&line) { session.receive(message) }
            }
            session.ended(generation);
        });
    }

    fn receive(&self, message: Value) {
        let mut inner = self.lock();
        inner.record(json!({"in": message}));
        inner.heard = Instant::now();
        let effects = inner.core.receive(&message);
        for change in &effects.changes {
            if let Change::Item { item } = change {
                if item.status == ItemStatus::Running && matches!(item.kind, ItemKind::Command { .. }) { inner.running.entry(item.id.clone()).or_insert_with(Instant::now); }
                else { inner.running.remove(&item.id); }
            }
        }
        for change in &effects.changes {
            if let Change::Resolved { approval: id } | Change::Answered { question: id } = change { inner.answered.remove(id); }
        }
        let asked: Vec<_> = effects.changes.iter().filter_map(|c| match c { Change::Approval { approval } => Some(approval.clone()), _ => None }).collect();
        inner.broadcast(effects.changes);
        if inner.core.conversation().permissions == Permissions::Unrestricted {
            for approval in asked { inner.allow(&approval); }
        }
        if let Some((id, outcome)) = inner.core.answers(&message) && let Some(waiter) = inner.waiting.remove(&id) {
            let _ = waiter.send(outcome);
        }
        for reply in effects.replies { let _ = inner.send(reply); }
    }

    /// The runtime's output ended: its process is gone, and so is everything waiting on it.
    fn ended(&self, generation: u64) {
        let mut inner = self.lock();
        if inner.generation != generation { return }
        inner.out = None;
        inner.child = None;
        let provider = inner.core.conversation().provider.title();
        for (_, waiter) in inner.waiting.drain() { let _ = waiter.send(Err(format!("{provider} stopped"))); }
        inner.record(json!({"offline": true}));
        let changes = inner.core.offline();
        inner.broadcast(changes);
    }

    /// Looks for a working session that has stopped making progress, and marks or clears it. False once the
    /// process it watched is gone.
    fn watch(&self, generation: u64) -> bool {
        let mut inner = self.lock();
        if inner.generation != generation || inner.out.is_none() { return false }
        let conversation = inner.core.conversation();
        let reason = if conversation.status != crate::model::Status::Working { None } else {
            let longest = inner.running.iter().filter_map(|(id, started)| {
                let elapsed = started.elapsed();
                let command = match conversation.item(id).map(|i| &i.kind) { Some(ItemKind::Command { command, .. }) => command.clone(), _ => return None };
                (elapsed >= LONG_COMMAND).then(|| format!("{command} has been running for {} minutes", elapsed.as_secs() / 60))
            }).next();
            let commands: Vec<&str> = conversation.items.iter().rev().take_while(|i| i.turn == conversation.turn || conversation.turn.is_none())
                .filter_map(|i| match &i.kind { ItemKind::Command { command, .. } => Some(command.as_str()), _ => None }).take(REPEATS).collect();
            let repeated = (commands.len() == REPEATS && commands.iter().all(|c| *c == commands[0])).then(|| format!("Ran {} {REPEATS} times in a row", commands[0]));
            let silent = (inner.heard.elapsed() >= SILENT).then(|| format!("No word from {} for {} minutes", conversation.provider.title(), SILENT.as_secs() / 60));
            longest.or(repeated).or(silent)
        };
        if reason != conversation.stalled {
            let change = inner.core.change(Change::Stalled { reason });
            inner.broadcast(vec![change]);
        }
        true
    }

    // What the providers' flows use to talk to their runtime.

    /// A change Zero makes itself (a model switched, a label given), kept in the transcript so a restart replays it.
    pub fn change(&self, change: Change) {
        let mut inner = self.lock();
        inner.record(json!({"change": change}));
        let change = inner.core.change(change);
        inner.broadcast(vec![change]);
    }

    /// Writes a line that nothing waits on an answer to.
    pub(crate) fn write(&self, message: Value) -> Result<(), String> {
        self.lock().send(message)
    }

    /// Sends a request with a fresh id, and waits for its answer.
    pub(crate) async fn request(&self, build: impl FnOnce(&str) -> Value) -> Result<Value, String> {
        let (answer, provider) = {
            let mut inner = self.lock();
            let id = inner.fresh_id();
            let (tell, answer) = oneshot::channel();
            inner.waiting.insert(id.clone(), tell);
            if let Err(error) = inner.send(build(&id)) {
                inner.waiting.remove(&id);
                return Err(error);
            }
            (answer, inner.core.conversation().provider.title())
        };
        match tokio::time::timeout(ANSWER_TIMEOUT, answer).await {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(_)) => Err(format!("{provider} stopped")),
            Err(_) => Err(format!("{provider} didn't answer")),
        }
    }

    /// Sends a request with a fresh id whose answer the adapter handles when it comes (an ACP prompt, which answers
    /// only when its turn ends).
    pub(crate) fn request_later(&self, build: impl FnOnce(&str) -> Value) -> Result<(), String> {
        let mut inner = self.lock();
        let id = inner.fresh_id();
        inner.send(build(&id))
    }
}

impl Inner {
    /// An unrestricted session's agent asked anyway (OpenCode can't be told per session): allowed once, never
    /// "always", so no rule outlives the session, and noted in the conversation.
    fn allow(&mut self, approval: &crate::model::Approval) {
        let Some(choice) = [ChoiceKind::Allow, ChoiceKind::AllowSession].iter().find_map(|kind| approval.choices.iter().find(|c| c.kind == *kind)) else { return };
        let Ok(line) = self.core.answer(&approval.id, &choice.id) else { return };
        if self.send(line).is_err() { return }
        self.answered.insert(approval.id.clone());
        let conversation = self.core.conversation();
        let item = Item { id: format!("notice-{}", conversation.seq + 1), turn: conversation.turn.clone(),
                          kind: ItemKind::Notice { text: format!("Allowed without asking: {}", approval.title), error: false }, status: ItemStatus::Done };
        let change = Change::Item { item };
        self.record(json!({"change": change}));
        let change = self.core.change(change);
        self.broadcast(vec![change]);
    }

    fn fresh_id(&mut self) -> String {
        let id = format!("z{}", self.next);
        self.next += 1;
        id
    }

    /// Every line to the runtime goes through the adapter first, which may change the conversation (Claude's and
    /// ACP's prompts start turns; their answers settle approvals).
    fn send(&mut self, message: Value) -> Result<(), String> {
        let out = self.out.clone().ok_or_else(|| format!("{} isn't running", self.core.conversation().provider.title()))?;
        self.record(json!({"out": message}));
        let changes = self.core.sent(&message);
        self.broadcast(changes);
        out.send(message).map_err(|_| "The runtime isn't running".to_string())
    }

    /// ponytail: written under the session's lock, a line at a time; buffer if transcripts get hot.
    fn record(&mut self, entry: Value) {
        if let Some(file) = self.transcript.as_mut() {
            let mut line = serde_json::to_vec(&entry).unwrap_or_default();
            line.push(b'\n');
            let _ = file.write_all(&line);
        }
    }

    /// Sends changes the core has already applied, numbered after the ones before them.
    fn broadcast(&self, changes: Vec<Change>) {
        let conversation = self.core.conversation();
        let first = conversation.seq + 1 - changes.len() as u64;
        for (offset, change) in changes.into_iter().enumerate() {
            // Nobody listening is fine: the conversation has the change either way.
            let _ = self.events.send(Event { session: conversation.id.clone(), seq: first + offset as u64, change });
        }
    }
}

fn append(dir: &Path) -> io::Result<File> {
    OpenOptions::new().create(true).append(true).open(dir.join("transcript.jsonl"))
}
