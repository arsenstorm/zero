//! One agent session: a runtime process speaking JSON lines, the conversation its provider's adapter makes of what
//! it says, and a transcript on disk of every line each way. A session outlives its process: when the process
//! ends the session goes offline, keeps its conversation, and `resume` gives it a new process on the same
//! conversation. After a restart of the daemon, `load` rebuilds it from the transcript.

mod pages;
mod process;
mod turns;

use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use tokio::time::Instant;

use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::process::Child;
use tokio::sync::{broadcast, mpsc, oneshot};

use crate::core::Core;
use crate::model::{Change, ChoiceKind, Conversation, Event, Item, ItemKind, ItemStatus, Permissions, Provider};
use crate::{acp, claude, codex, now_ms};

use pages::turn_start;
pub use process::{Handoff, Transport};
pub use turns::{Message, ModelChoice};

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
    /// Its transcript's last write failed (a full disk): said once, until a write works again.
    unwritten: bool,
    /// Lines to the runtime; None while offline.
    out: Option<mpsc::UnboundedSender<Value>>,
    child: Option<Child>,
    /// Its process's pid and pipes (stdin, stdout), which a restart hands to the next zerod; how to stop its reading for
    /// that, and its writer, to let finish first.
    pid: Option<i32>,
    fds: Option<(i32, i32)>,
    stop_reading: Option<oneshot::Sender<oneshot::Sender<Vec<u8>>>>,
    writing: Option<tokio::task::JoinHandle<()>>,
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
    /// Claude's last init recorded (its hash), without what changes every time: the same again isn't recorded.
    init: Option<u64>,
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
                let meta = Meta {
                    id: conversation.id.clone(),
                    provider: conversation.provider,
                    cwd: conversation.cwd.clone(),
                    permissions: conversation.permissions,
                    parent: conversation.parent.clone(),
                    branch: conversation.branch.clone(),
                    thread: conversation.thread.clone(),
                };
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
                mcp: vec![],
                core: None,
                parked: Some(parked),
                summary: None,
                dir: Some(dir.into()),
                lines,
                touched: Instant::now(),
                events,
                transcript: Some(append(dir)?),
                unwritten: false,
                out: None,
                child: None,
                pid: None,
                fds: None,
                stop_reading: None,
                writing: None,
                waiting: HashMap::new(),
                answered: HashSet::new(),
                next: lines + 1,
                generation: 0,
                heard: Instant::now(),
                running: HashMap::new(),
                init: None,
            })));
            return Ok(session);
        }
        let (core, lines) = replay(dir, false)?;
        let session = Session::with(core, Some(append(dir)?), events, lines + 1);
        {
            let mut inner = session.lock();
            inner.dir = Some(dir.into());
            inner.lines = lines;
        }
        session.unload();
        Ok(session)
    }

    /// Takes over the process the zerod before handed over (Daemon::hand_off): the conversation replayed as it stood,
    /// mid-turn and all (not offline, as a load leaves it), and the process attached where the other zerod left off.
    pub fn adopt(&self, handoff: Handoff) -> io::Result<()> {
        let dir = self.lock().dir.clone().ok_or_else(|| io::Error::other("a session kept nowhere has nothing to take over"))?;
        let (core, lines) = replay(&dir, true)?;
        let transport = Transport::adopt(handoff)?;
        {
            let mut inner = self.lock();
            inner.core = Some(core);
            inner.parked = None;
            inner.summary = None;
            inner.lines = lines;
            inner.next = inner.next.max(lines + 1);
        }
        self.attach(transport);
        Ok(())
    }

    /// Whether its conversation is in memory.
    pub fn is_loaded(&self) -> bool {
        self.lock().core.is_some()
    }

    /// Parks it: its summary and latest items to parked.json, its conversation out of memory. Not while it runs.
    pub fn unload(&self) -> bool {
        let mut inner = self.lock();
        let Some(core) = inner.core.as_ref() else { return true };
        if inner.out.is_some() || core.conversation().terminal.is_some() {
            return false;
        }
        let Some(dir) = inner.dir.clone() else { return false };
        let conversation = core.conversation();
        let start = turn_start(&conversation.items, conversation.items.len().saturating_sub(TAIL));
        let parked = Parked {
            lines: inner.lines,
            summary: summarize(conversation),
            tail: conversation.items[start..].to_vec(),
            total: conversation.items.len(),
        };
        if std::fs::write(dir.join("parked.json"), serde_json::to_vec(&parked).unwrap_or_default()).is_err() {
            return false;
        }
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
            mcp: vec![],
            core: Some(core),
            parked: None,
            summary: None,
            dir: None,
            lines: 0,
            touched: Instant::now(),
            events,
            transcript,
            unwritten: false,
            out: None,
            child: None,
            pid: None,
            fds: None,
            stop_reading: None,
            writing: None,
            waiting: HashMap::new(),
            answered: HashSet::new(),
            next,
            generation: 0,
            heard: Instant::now(),
            running: HashMap::new(),
            init: None,
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
        if let Some(core) = inner.core.as_mut() {
            core.set_mcp(servers)
        }
    }

    /// The conversation without its items but its latest answer and last item: what a list and the board need.
    pub fn summary(&self) -> Conversation {
        // Read without touching it: the board reading every task mustn't keep them all in memory.
        let mut inner = self.lock();
        if let Some(core) = &inner.core {
            let conversation = core.conversation();
            if let Some((seq, kept)) = &inner.summary
                && *seq == conversation.seq
            {
                return kept.clone();
            }
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
        !inner.running.is_empty()
            || inner.core.as_ref().is_some_and(|core| {
                core.conversation()
                    .items
                    .iter()
                    .rev()
                    .take(50)
                    .any(|i| matches!(i.kind, ItemKind::Command { .. }) && i.status == ItemStatus::Running)
            })
    }

    /// What Stop sends to stop the provider's background work.
    pub fn stops(&self) -> Vec<Value> {
        self.lock().core.as_ref().map(|c| c.stops()).unwrap_or_default()
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
        // Idle, done, or waiting on someone (what it follows wakes it), not limited: a limited one is waiting to carry on
        // its turn once the limit resets. Nothing of its own running in the background either, which stopping it ends.
        let idle = inner.out.is_some()
            && matches!(
                conversation.attention(),
                crate::model::Attention::Idle
                    | crate::model::Attention::Answered
                    | crate::model::Attention::Done
                    | crate::model::Attention::Blocked
            )
            && conversation.turn.is_none()
            && inner.running.is_empty()
            && inner.core.as_ref().is_some_and(|core| core.stops().is_empty());
        idle.then(|| inner.heard.elapsed())
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
        for change in &changes {
            inner.record(json!({"change": change}));
        }
        inner.broadcast(changes);
    }

    /// A change Zero makes itself (a model switched, a label given), kept in the transcript so a restart replays it.
    /// Its turn is being paused for Zero's update: the agent's note of the stop says so.
    pub fn pause_for_update(&self) {
        self.lock().core().pausing(true)
    }

    pub fn change(&self, change: Change) {
        let mut inner = self.lock();
        inner.core().at(now_ms());
        // Kept as applied, so an item's time comes back with it.
        let change = inner.core().change(change);
        inner.record(json!({"change": change}));
        inner.broadcast(vec![change]);
    }
}

impl Inner {
    /// An unrestricted session's agent asked anyway (OpenCode can't be told per session): allowed once, never
    /// "always", so no rule outlives the session, and noted in the conversation.
    fn allow(&mut self, approval: &crate::model::Approval) {
        let Some(choice) =
            [ChoiceKind::Allow, ChoiceKind::AllowSession].iter().find_map(|kind| approval.choices.iter().find(|c| c.kind == *kind))
        else {
            return;
        };
        let Ok(line) = self.core().answer(&approval.id, &choice.id) else { return };
        if self.send(line).is_err() {
            return;
        }
        self.answered.insert(approval.id.clone());
        // Settled now, not when the runtime says so: until then it would read as waiting on the user, and nobody is.
        let resolved = Change::Resolved { approval: approval.id.clone() };
        self.record(json!({"change": resolved}));
        let resolved = self.core().change(resolved);
        self.broadcast(vec![resolved]);
        let conversation = self.core().conversation();
        let item = Item {
            at: None,
            id: format!("notice-{}", conversation.seq + 1),
            turn: conversation.turn.clone(),
            kind: ItemKind::Notice { text: format!("Allowed without asking: {}", approval.title), error: false },
            status: ItemStatus::Done,
        };
        let change = Change::Item { item };
        self.record(json!({"change": change}));
        let change = self.core().change(change);
        self.broadcast(vec![change]);
    }

    /// ponytail: written under the session's lock, a line at a time; buffer if transcripts get hot.
    /// The conversation, replayed from the transcript first if the session is parked.
    fn core(&mut self) -> &mut Core {
        self.touched = Instant::now();
        if self.core.is_none() {
            let loaded = self.dir.as_deref().and_then(|dir| replay(dir, false).ok()).map(|(core, _)| core);
            let mut core = loaded.unwrap_or_else(|| {
                Core::new(self.parked.as_ref().map(|p| p.summary.clone()).unwrap_or_else(|| Conversation::new("", Provider::Claude, "")))
            });
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
            let id = self
                .core
                .as_ref()
                .map(|c| c.conversation().id.clone())
                .or_else(|| self.parked.as_ref().map(|p| p.summary.id.clone()))
                .unwrap_or_default();
            if let Some(said) = unwritten(&mut self.unwritten, file.write_all(&line), &id) {
                eprintln!("{said}")
            }
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

/// Without its items but its latest answer (the board's) and its last item (how it's doing).
fn summarize(conversation: &Conversation) -> Conversation {
    // The first message too: it names the task on the board when nothing else does.
    let asked = conversation.items.iter().find(|i| matches!(i.kind, ItemKind::User { .. }));
    let answer = conversation.items.iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. }));
    // The user's latest word of their own: until they speak again, done or merged stands (board.rs).
    let spoke =
        conversation.items.iter().rev().find(|i| matches!(&i.kind, ItemKind::User { text, .. } if !text.starts_with(crate::model::FROM)));
    let mut items: Vec<Item> = Vec::new();
    // And its latest message of any kind: whether its last turn was the user's or Zero's (board.rs `quiet`).
    let latest = conversation.items.iter().rev().find(|i| matches!(i.kind, ItemKind::User { .. }));
    for item in asked.into_iter().chain(spoke).chain(latest).chain(answer).chain(conversation.items.last()) {
        if !items.iter().any(|kept| kept.id == item.id) {
            items.push(item.clone())
        }
    }
    conversation.with_items(items)
}

/// What to log of a transcript write, if anything: its failure, once, until a write works again. A session rebuilds
/// from its transcript, so a line lost is lost on the next start.
pub fn unwritten(failing: &mut bool, written: std::io::Result<()>, id: &str) -> Option<String> {
    let said = match &written {
        Err(error) if !*failing => Some(format!("zerod: {id}'s transcript: {error}; lines are being lost")),
        _ => None,
    };
    *failing = written.is_err();
    said
}

/// Newlines in a file, read a piece at a time: transcripts run to tens of megabytes.
fn count_lines(path: &Path) -> u64 {
    let Ok(mut file) = File::open(path) else { return 0 };
    let (mut buffer, mut lines) = (vec![0u8; 64 * 1024], 0);
    while let Ok(read) = io::Read::read(&mut file, &mut buffer)
        && read > 0
    {
        lines += buffer[..read].iter().filter(|b| **b == b'\n').count() as u64
    }
    lines
}

fn append(dir: &Path) -> io::Result<File> {
    OpenOptions::new().create(true).append(true).open(dir.join("transcript.jsonl"))
}

/// The session in `dir` replayed from its transcript, with how many lines it read: offline, unless its process is
/// still `running` (taken over across a restart).
fn replay(dir: &Path, running: bool) -> io::Result<(Core, u64)> {
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
            replay_entry(&mut core, &entry);
        }
    }
    if !running {
        core.offline();
    }
    Ok((core, lines))
}

/// One record of a transcript, read back into its session.
pub fn replay_entry(core: &mut Core, entry: &Value) {
    if let Some(at) = entry["at"].as_i64() {
        core.at(at)
    }
    if let Some(images) = entry["attach"].as_array() {
        core.attach(images.iter().filter_map(|i| i.as_str().map(String::from)).collect())
    }
    if let Some(message) = entry.get("out") {
        core.sent(message);
    }
    if let Some(message) = entry.get("in") {
        core.receive(message);
    }
    if entry.get("offline").is_some() {
        core.offline();
    }
    if let Some(change) = entry.get("change").and_then(|c| serde_json::from_value(c.clone()).ok()) {
        core.change(change);
    }
}
