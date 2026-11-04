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

unsafe extern "C" {
    safe fn kill(pid: i32, signal: i32) -> i32;
}
const SIGKILL: i32 = 9;

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
    /// The MCP servers its CLI is started with (Conversation::mcp), set by zerod before each start.
    mcp: Vec<crate::mcp_servers::Resolved>,
    /// The conversation, replayed; None while parked.
    core: Option<Core>,
    /// What's kept of a parked session: its summary and latest items, until something needs the rest.
    parked: Option<Parked>,
    /// The loaded conversation's summary as of its sequence number: the board asks for every session's several
    /// times a second while a turn streams.
    summary: Option<(u64, Conversation)>,
    /// Where it's kept, to load from and park to.
    dir: Option<PathBuf>,
    /// Lines in its transcript, so a park file can tell whether it's caught up.
    lines: u64,
    /// When its conversation was last wanted: one left offline and unwanted is parked again.
    touched: Instant,
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

/// A session not in memory, as parked.json keeps it: enough for the board, a list and a snapshot's latest items.
#[derive(serde::Serialize, serde::Deserialize, Clone)]
struct Parked {
    /// Its transcript's lines when parked: a transcript with more is replayed instead.
    lines: u64,
    summary: Conversation,
    tail: Vec<Item>,
    total: usize,
}

/// How many of the latest items a parked session keeps: a snapshot's worth.
const TAIL: usize = 40;

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
        let transcript = match &dir {
            Some(dir) => {
                std::fs::create_dir_all(dir)?;
                let meta = Meta { id: conversation.id.clone(), provider: conversation.provider, cwd: conversation.cwd.clone(),
                                  permissions: conversation.permissions, parent: conversation.parent.clone(), branch: conversation.branch.clone(),
                                  thread: conversation.thread.clone() };
                std::fs::write(dir.join("meta.json"), serde_json::to_vec(&meta)?)?;
                Some(append(dir)?)
            }
            None => None,
        };
        let session = Session::with(Core::new(conversation), transcript, events, 1);
        session.lock().dir = dir;
        Ok(session)
    }

    /// The session kept in `dir`, offline and parked: from parked.json when it's caught up with the transcript, else
    /// replayed once and parked.
    pub fn load(dir: &Path, events: broadcast::Sender<Event>) -> io::Result<Session> {
        let lines = count_lines(&dir.join("transcript.jsonl"));
        let parked: Option<Parked> = std::fs::read(dir.join("parked.json")).ok().and_then(|data| serde_json::from_slice(&data).ok());
        if let Some(parked) = parked.filter(|p| p.lines == lines) {
            let session = Session(Arc::new(Mutex::new(Inner {
                mcp: vec![], core: None, parked: Some(parked), summary: None, dir: Some(dir.into()), lines, touched: Instant::now(), events, transcript: Some(append(dir)?),
                out: None, child: None, waiting: HashMap::new(), answered: HashSet::new(), next: lines + 1, generation: 0,
                heard: Instant::now(), running: HashMap::new(),
            })));
            return Ok(session);
        }
        let (core, lines) = replay(dir)?;
        let session = Session::with(core, Some(append(dir)?), events, lines + 1);
        {
            let mut inner = session.lock();
            inner.dir = Some(dir.into());
            inner.lines = lines;
        }
        session.unload();
        Ok(session)
    }

    /// Whether its conversation is in memory.
    pub fn is_loaded(&self) -> bool { self.lock().core.is_some() }

    /// Parks it: its summary and latest items to parked.json, its conversation out of memory. Not while it runs.
    pub fn unload(&self) -> bool {
        let mut inner = self.lock();
        let Some(core) = inner.core.as_ref() else { return true };
        if inner.out.is_some() || core.conversation().terminal.is_some() { return false }
        let Some(dir) = inner.dir.clone() else { return false };
        let conversation = core.conversation();
        let start = turn_start(&conversation.items, conversation.items.len().saturating_sub(TAIL));
        let parked = Parked { lines: inner.lines, summary: summarize(conversation), tail: conversation.items[start..].to_vec(),
                              total: conversation.items.len() };
        if std::fs::write(dir.join("parked.json"), serde_json::to_vec(&parked).unwrap_or_default()).is_err() { return false }
        inner.core = None;
        inner.parked = Some(parked);
        true
    }

    /// Offline, how long since its conversation was last wanted.
    pub fn unwanted_for(&self) -> Option<Duration> {
        let inner = self.lock();
        (inner.out.is_none() && inner.core.is_some()).then(|| inner.touched.elapsed())
    }

    fn with(core: Core, transcript: Option<File>, events: broadcast::Sender<Event>, next: u64) -> Session {
        Session(Arc::new(Mutex::new(Inner {
            mcp: vec![], core: Some(core), parked: None, summary: None, dir: None, lines: 0, touched: Instant::now(), events, transcript, out: None, child: None, waiting: HashMap::new(), answered: HashSet::new(), next, generation: 0,
            heard: Instant::now(), running: HashMap::new(),
        })))
    }

    pub fn snapshot(&self) -> Conversation {
        let mut inner = self.lock();
        let mut conversation = inner.core().conversation().clone();
        conversation.mcp = inner.mcp.clone();
        conversation
    }

    /// The MCP servers its CLI is to be started with, from now on.
    pub fn set_mcp(&self, servers: Vec<crate::mcp_servers::Resolved>) {
        let mut inner = self.lock();
        inner.mcp = servers.clone();
        if let Some(core) = inner.core.as_mut() { core.set_mcp(servers) }
    }

    /// The conversation with its latest `count` items (more, back to the start of their turn), and how many came before.
    pub fn recent(&self, count: usize) -> (Conversation, usize) {
        let mut inner = self.lock();
        if let Some(parked) = inner.parked.as_ref().filter(|p| count <= p.tail.len() || p.tail.len() == p.total) {
            let start = turn_start(&parked.tail, parked.tail.len().saturating_sub(count));
            return (parked.summary.with_items(parked.tail[start..].to_vec()), parked.total - (parked.tail.len() - start));
        }
        let conversation = inner.core().conversation();
        let start = turn_start(&conversation.items, conversation.items.len().saturating_sub(count));
        (conversation.with_items(conversation.items[start..].to_vec()), start)
    }

    /// Items before `before` (all of them with none): from `from` if given, else the last `limit` of them.
    pub fn items(&self, before: Option<&str>, from: Option<&str>, limit: usize) -> Vec<Item> {
        let mut inner = self.lock();
        let items = &inner.core().conversation().items;
        let end = before.and_then(|id| items.iter().position(|i| i.id == id)).unwrap_or(items.len());
        let start = match from.and_then(|id| items[..end].iter().position(|i| i.id == id)) {
            Some(start) => start,
            None => turn_start(items, end.saturating_sub(limit)),
        };
        items[start..end].to_vec()
    }

    /// A page of the conversation anywhere in it, and how many items lie before and after it: from a message (the
    /// rail's jump), after one (scrolled to the page's foot), or the latest page. ponytail: positions by scanning
    /// for the id; index them if conversations reach the hundreds of thousands of items.
    pub fn window(&self, from: Option<&str>, after: Option<&str>, limit: usize) -> (Vec<Item>, usize, usize) {
        let mut inner = self.lock();
        let items = &inner.core().conversation().items;
        let find = |id: &str| items.iter().position(|i| i.id == id);
        let start = match (from, after) {
            (Some(id), _) => match find(id) { Some(at) => at, None => return (vec![], 0, 0) },
            (None, Some(id)) => match find(id) { Some(at) => at + 1, None => return (vec![], 0, 0) },
            (None, None) => turn_start(items, items.len().saturating_sub(limit)),
        };
        let end = if from.is_none() && after.is_none() { items.len() } else { (start + limit).min(items.len()) };
        (items[start..end].to_vec(), start, items.len() - end)
    }

    /// Each message of yours with the start of its answer: the app's rail, whole however little of the conversation
    /// is loaded.
    pub fn outline(&self) -> Value {
        let mut inner = self.lock();
        let items = &inner.core().conversation().items;
        let mut marks: Vec<Value> = vec![];
        for (index, item) in items.iter().enumerate() {
            // Yours only: what Zero gave the session (a worker's report) isn't a mark of yours.
            let ItemKind::User { text, .. } = &item.kind else { continue };
            if crate::model::from(text).is_some() { continue }
            let answer = items[index + 1..].iter().take_while(|i| !matches!(i.kind, ItemKind::User { .. }))
                .find_map(|i| match &i.kind { ItemKind::Agent { text, final_answer: true } => Some(text.chars().take(400).collect::<String>()), _ => None });
            marks.push(json!({"id": item.id, "text": text.chars().take(300).collect::<String>(), "answer": answer}));
        }
        Value::Array(marks)
    }

    /// The conversation without its items but its latest answer and last item: what a list and the board need.
    pub fn summary(&self) -> Conversation {
        // Read without touching it: the board reading every task mustn't keep them all in memory.
        let mut inner = self.lock();
        if let Some(core) = &inner.core {
            let conversation = core.conversation();
            if let Some((seq, kept)) = &inner.summary && *seq == conversation.seq { return kept.clone() }
            let made = summarize(conversation);
            inner.summary = Some((conversation.seq, made.clone()));
            return made;
        }
        match &inner.parked {
            Some(parked) => parked.summary.clone(),
            None => Conversation::new("", Provider::Claude, ""),
        }
    }

    /// Its id, without loading it.
    pub fn id(&self) -> String {
        let inner = self.lock();
        match (&inner.core, &inner.parked) {
            (Some(core), _) => core.conversation().id.clone(),
            (None, Some(parked)) => parked.summary.id.clone(),
            (None, None) => String::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // A panic while holding the lock leaves the conversation as it was after the last full change.
        self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn provider(&self) -> Provider {
        self.summary().provider
    }

    /// A command of its turn still running: what pausing for a restart waits for.
    pub fn running_command(&self) -> bool {
        let inner = self.lock();
        !inner.running.is_empty() || inner.core.as_ref().is_some_and(|core| core.conversation().items.iter().rev().take(50)
            .any(|i| matches!(i.kind, ItemKind::Command { .. }) && i.status == ItemStatus::Running))
    }

    /// True while a runtime process is connected.
    pub fn is_attached(&self) -> bool {
        self.lock().out.is_some()
    }

    /// While its process runs between turns with nothing open (no approval, question or command), how long since the
    /// runtime last said anything.
    pub fn idle_for(&self) -> Option<Duration> {
        let inner = self.lock();
        // Parked, it has no process.
        let conversation = inner.core.as_ref()?.conversation();
        // Idle or done, not limited: a limited one is waiting to carry on its turn once the limit resets.
        let idle = inner.out.is_some() && matches!(conversation.attention(), crate::model::Attention::Idle | crate::model::Attention::Answered | crate::model::Attention::Done)
            && conversation.turn.is_none() && inner.running.is_empty();
        idle.then(|| inner.heard.elapsed())
    }

    /// Starts the runtime's side of the session, with `prompt` as its first turn.
    pub async fn start(&self, transport: Transport, prompt: &str, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        self.start_with_images(transport, prompt, &[], model, effort).await
    }

    /// The first turn with images (their files), kept as any message's are.
    pub async fn start_with_images(&self, transport: Transport, prompt: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        self.keep_images(images);
        match self.provider() {
            Provider::Codex => codex::start(self, transport, prompt, images, model, effort).await,
            Provider::Claude => claude::start(self, transport, prompt, images).await,
            Provider::Opencode => acp::start(self, transport, prompt, images, model, effort).await,
        }
    }

    /// A new thread for a conversation without one: for OpenCode, which can't be handed a conversation, the earlier one
    /// goes with the message as context (handoff.rs), not as words of yours.
    pub async fn restart(&self, transport: Transport, context: Option<&str>, prompt: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        match (self.provider(), context) {
            (Provider::Opencode, Some(context)) => {
                self.keep_images(images);
                acp::start_with_context(self, transport, Some(context), prompt, images, model, effort).await
            }
            _ => self.start_with_images(transport, prompt, images, model, effort).await,
        }
    }

    /// The images go on the next message of yours, now and on replay.
    fn keep_images(&self, images: &[String]) {
        if images.is_empty() { return }
        let mut inner = self.lock();
        inner.record(json!({"attach": images}));
        inner.core().attach(images.to_vec());
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
        self.send_with_images(text, &[], model, effort).await
    }

    /// A model (and effort) picked without a message, for the turns from here: told to the agent now where it takes
    /// that (Claude Code, OpenCode), and kept so the next turn carries it (Codex) and a restart starts with it.
    pub async fn set_model(&self, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        if model.is_none() && effort.is_none() { return Ok(()) }
        let conversation = self.snapshot();
        let thread = conversation.thread.clone()
            .ok_or_else(|| format!("{} hasn't started yet: pick the model with your next message", conversation.provider.title()))?;
        if self.is_attached() {
            match conversation.provider {
                Provider::Claude => if let Some(model) = model { claude::set_model(self, model).await? },
                Provider::Opencode => acp::configure(self, model, effort).await?,
                Provider::Codex => {}
            }
        }
        self.change(Change::Thread { thread, model: model.map(Into::into), effort: effort.map(Into::into) });
        Ok(())
    }

    /// Words with images (their files): kept in the transcript first, so the message keeps them on replay.
    pub async fn send_with_images(&self, text: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        let conversation = self.snapshot();
        if !self.is_attached() { return Err(format!("{} is offline; resume it first", conversation.id)) }
        self.keep_images(images);
        match conversation.provider {
            Provider::Codex => codex::send(self, text, images, model, effort).await,
            Provider::Claude => claude::send(self, text, images, model).await,
            Provider::Opencode => acp::send(self, text, images, model, effort).await,
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
        let line = inner.core().answer(approval, choice)?;
        inner.send(line)?;
        inner.answered.insert(approval.into());
        Ok(())
    }

    /// Answers an open question, every field of it, once.
    pub async fn answer(&self, question: &str, answers: &crate::adapter::Answers) -> Result<(), String> {
        let mut inner = self.lock();
        if inner.answered.contains(question) { return Err(format!("{question} was already answered")) }
        let line = inner.core().reply(question, answers)?;
        inner.send(line)?;
        inner.answered.insert(question.into());
        Ok(())
    }

    /// Ends the runtime's process; the session stays, offline, to be resumed.
    pub fn stop(&self) {
        let generation = {
            let mut inner = self.lock();
            match inner.child.as_mut() {
                // Its output ends when it and everything it started (its process group) are gone, and that takes the
                // session offline.
                Some(child) => {
                    if let Some(pid) = child.id().and_then(|pid| i32::try_from(pid).ok()) { kill(-pid, SIGKILL); }
                    let _ = child.start_kill();
                    return;
                }
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
        let changes = inner.core().report(text);
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
        let at = now_ms();
        inner.record(json!({"in": message, "at": at}));
        inner.core().at(at);
        inner.heard = Instant::now();
        let effects = inner.core().receive(&message);
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
        if inner.core().conversation().permissions == Permissions::Unrestricted {
            for approval in asked { inner.allow(&approval); }
        }
        if let Some((id, outcome)) = inner.core().answers(&message) && let Some(waiter) = inner.waiting.remove(&id) {
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
        let provider = inner.core().conversation().provider.title();
        for (_, waiter) in inner.waiting.drain() { let _ = waiter.send(Err(format!("{provider} stopped"))); }
        inner.record(json!({"offline": true}));
        let changes = inner.core().offline();
        inner.broadcast(changes);
    }

    /// Looks for a working session that has stopped making progress, and marks or clears it. False once the
    /// process it watched is gone.
    fn watch(&self, generation: u64) -> bool {
        let mut inner = self.lock();
        if inner.generation != generation || inner.out.is_none() { return false }
        let Some(core) = inner.core.as_ref() else { return true };
        let conversation = core.conversation();
        let reason = if conversation.status != crate::model::Status::Working { None } else {
            let longest = inner.running.iter().filter_map(|(id, started)| {
                let elapsed = started.elapsed();
                let command = match conversation.item(id).map(|i| &i.kind) { Some(ItemKind::Command { command, .. }) => command.clone(), _ => return None };
                (elapsed >= LONG_COMMAND).then(|| format!("{command} has been running for {} minutes", elapsed.as_secs() / 60))
            }).next();
            // The same command again and again with nothing else between: counted in full, so the number grows as it goes
            // on. Another step between (a different tool, a file changed) is work, not a loop.
            let steps = conversation.items.iter().rev().take_while(|i| i.turn == conversation.turn || conversation.turn.is_none())
                .filter(|i| !matches!(i.kind, ItemKind::Reasoning { .. } | ItemKind::Agent { .. }));
            let mut run: Option<(&str, usize)> = None;
            for step in steps {
                match (&step.kind, run) {
                    (ItemKind::Command { command, .. }, None) => run = Some((command, 1)),
                    (ItemKind::Command { command, .. }, Some((same, n))) if command == same => run = Some((same, n + 1)),
                    _ => break,
                }
            }
            let repeated = run.filter(|(_, n)| *n >= REPEATS).map(|(command, n)| format!("Ran {command} {n} times in a row"));
            let silent = (inner.heard.elapsed() >= SILENT).then(|| format!("No word from {} for {} minutes", conversation.provider.title(), SILENT.as_secs() / 60));
            longest.or(repeated).or(silent)
        };
        if reason != conversation.stalled {
            let change = inner.core().change(Change::Stalled { reason });
            inner.broadcast(vec![change]);
        }
        true
    }

    // What the providers' flows use to talk to their runtime.

    /// A change Zero makes itself (a model switched, a label given), kept in the transcript so a restart replays it.
    /// Its turn is being paused for Zero's update: the agent's note of the stop says so.
    pub fn pause_for_update(&self) { self.lock().core().pausing(true) }

    pub fn change(&self, change: Change) {
        let mut inner = self.lock();
        inner.core().at(now_ms());
        // Kept as applied, so an item's time comes back with it.
        let change = inner.core().change(change);
        inner.record(json!({"change": change}));
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
            (answer, inner.core().conversation().provider.title())
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
        let Ok(line) = self.core().answer(&approval.id, &choice.id) else { return };
        if self.send(line).is_err() { return }
        self.answered.insert(approval.id.clone());
        // Settled now, not when the runtime says so: until then it would read as waiting on the user, and nobody is.
        let resolved = Change::Resolved { approval: approval.id.clone() };
        self.record(json!({"change": resolved}));
        let resolved = self.core().change(resolved);
        self.broadcast(vec![resolved]);
        let conversation = self.core().conversation();
        let item = Item { at: None, id: format!("notice-{}", conversation.seq + 1), turn: conversation.turn.clone(),
                          kind: ItemKind::Notice { text: format!("Allowed without asking: {}", approval.title), error: false }, status: ItemStatus::Done };
        let change = Change::Item { item };
        self.record(json!({"change": change}));
        let change = self.core().change(change);
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
        let out = self.out.clone().ok_or_else(|| format!("{} isn't running", self.core().conversation().provider.title()))?;
        let at = now_ms();
        self.record(json!({"out": message, "at": at}));
        self.core().at(at);
        let changes = self.core().sent(&message);
        self.broadcast(changes);
        out.send(message).map_err(|_| "The runtime isn't running".to_string())
    }

    /// ponytail: written under the session's lock, a line at a time; buffer if transcripts get hot.
    /// The conversation, replayed from the transcript first if the session is parked.
    fn core(&mut self) -> &mut Core {
        self.touched = Instant::now();
        if self.core.is_none() {
            let loaded = self.dir.as_deref().and_then(|dir| replay(dir).ok()).map(|(core, _)| core);
            let mut core = loaded.unwrap_or_else(|| Core::new(self.parked.as_ref().map(|p| p.summary.clone()).unwrap_or_else(|| Conversation::new("", Provider::Claude, ""))));
            core.set_mcp(self.mcp.clone());
            self.core = Some(core);
            self.parked = None;
        }
        self.core.as_mut().unwrap()
    }

    fn record(&mut self, entry: Value) {
        self.lines += 1;
        if let Some(file) = self.transcript.as_mut() {
            let mut line = serde_json::to_vec(&entry).unwrap_or_default();
            line.push(b'\n');
            let _ = file.write_all(&line);
        }
    }

    /// Sends changes the core has already applied, numbered after the ones before them.
    fn broadcast(&self, changes: Vec<Change>) {
        // Changes come from a loaded conversation.
        let Some(core) = self.core.as_ref() else { return };
        let conversation = core.conversation();
        let first = conversation.seq + 1 - changes.len() as u64;
        for (offset, change) in changes.into_iter().enumerate() {
            // Nobody listening is fine: the conversation has the change either way.
            let _ = self.events.send(Event { session: conversation.id.clone(), seq: first + offset as u64, change });
        }
    }
}

/// Where the turn holding `items[start]` begins (the message of yours it answers), so a page never splits a turn: the
/// app folds a turn into one row, and half of one shows the wrong time.
fn turn_start(items: &[Item], start: usize) -> usize {
    if start >= items.len() { return start }
    items[..=start].iter().rposition(|i| matches!(i.kind, ItemKind::User { .. })).unwrap_or(0)
}

/// Without its items but its latest answer (the board's) and its last item (how it's doing).
fn summarize(conversation: &Conversation) -> Conversation {
    // The first message too: it names the task on the board when nothing else does.
    let asked = conversation.items.iter().find(|i| matches!(i.kind, ItemKind::User { .. }));
    let answer = conversation.items.iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. }));
    let mut items: Vec<Item> = Vec::new();
    for item in asked.into_iter().chain(answer).chain(conversation.items.last()) {
        if !items.iter().any(|kept| kept.id == item.id) { items.push(item.clone()) }
    }
    conversation.with_items(items)
}

/// Newlines in a file, read a piece at a time: transcripts run to tens of megabytes.
fn count_lines(path: &Path) -> u64 {
    let Ok(mut file) = File::open(path) else { return 0 };
    let (mut buffer, mut lines) = (vec![0u8; 64 * 1024], 0);
    while let Ok(read) = io::Read::read(&mut file, &mut buffer) && read > 0 { lines += buffer[..read].iter().filter(|b| **b == b'\n').count() as u64 }
    lines
}

fn append(dir: &Path) -> io::Result<File> {
    OpenOptions::new().create(true).append(true).open(dir.join("transcript.jsonl"))
}

/// Now, in milliseconds since 1970: when a line arrived or a change was made.
fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// The session in `dir` replayed from its transcript, offline, with how many lines it read.
fn replay(dir: &Path) -> io::Result<(Core, u64)> {
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
            if let Some(at) = entry["at"].as_i64() { core.at(at) }
            if let Some(images) = entry["attach"].as_array() { core.attach(images.iter().filter_map(|i| i.as_str().map(String::from)).collect()) }
            if let Some(message) = entry.get("out") { core.sent(message); }
            if let Some(message) = entry.get("in") { core.receive(message); }
            if entry.get("offline").is_some() { core.offline(); }
            if let Some(change) = entry.get("change").and_then(|c| serde_json::from_value(c.clone()).ok()) { core.change(change); }
        }
    }
    core.offline();
    Ok((core, lines))
}
