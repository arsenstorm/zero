//! The daemon's sessions: started in a folder, kept under `<home>/sessions/<id>/`, loaded again at start-up,
//! and resumed with a new runtime process whenever one is wanted. A session can start others (a lead and its
//! workers): each worker's outcome is put to its lead as a message once the lead is between turns.

mod adopt;
mod archive;
mod heard;
mod inbox;
mod pause;
mod rewind;
mod send;
mod start;
mod terminals;
mod watches;

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, UNIX_EPOCH};

use tokio::sync::broadcast;

use crate::{claude, now, now_ms};
use crate::model::{Attention, Change, Conversation, Event, ItemKind, Opened, Permissions, Provider, Queued, Status};
use crate::process;
use crate::session::{Message, ModelChoice, Session, Transport};

pub use heard::report;
pub use inbox::Sessions;
pub use rewind::Rewind;
use archive::archived_with;
use send::kept_pending;

/// Starts a session's runtime process: its conversation, its folder in the daemon's home, and the command line
/// its provider starts with.
pub type Runtime = Arc<dyn Fn(&Conversation, &Path, &[String]) -> io::Result<Transport> + Send + Sync>;

/// The real one: the provider's CLI in the session's folder, its errors in the session's stderr.log.
pub fn real_runtime() -> Runtime {
    Arc::new(|conversation, dir, argv| process::spawn(argv, Path::new(&conversation.cwd), &conversation.id, Some(&dir.join("stderr.log"))))
}

const PAUSED: &str = "paused-by-user.json";
/// Each task's reply the user has seen (its answer's item, and when), on any client: seen.json.
const SEEN: &str = "seen.json";
/// In an archived task's folder: when it went, and with whom (the lead it went with; none, it went on its own).
const ARCHIVED: &str = "archived.json";
/// In a session's folder: its queue waits for the user.
const HELD: &str = "held";

pub struct Daemon {
    home: PathBuf,
    sessions: Mutex<Vec<Session>>,
    events: broadcast::Sender<Event>,
    runtime: Runtime,
    /// Each session's attention as last seen, to tell when a worker stops working.
    attention: Mutex<HashMap<String, Attention>>,
    /// Word for a session that it hasn't been given yet (it was busy or offline), kept in its folder as pending.json:
    /// the user's queued messages and reports for it, in order.
    pending: Mutex<HashMap<String, Vec<Queued>>>,
    /// Sessions whose queue waits for the user's say (they stopped the agent): nothing goes until released.
    held: Mutex<HashSet<String>>,
    /// Sessions with a queued message on its way to the agent: a turn's end is heard as several events, and each
    /// would otherwise take the next message before the first had made the session busy.
    delivering: Mutex<HashSet<String>>,
    /// Pinged whenever a queue changes, for the board.
    queues: broadcast::Sender<()>,
    /// The limit resets already waited for, by session, so each is waited for once.
    resets: Mutex<HashMap<String, i64>>,
    /// The user's home (where Claude Code keeps its sessions) and zero-host's socket.
    user: Mutex<(PathBuf, PathBuf)>,
    /// zerod is about to become a new build: words wait for it, rather than starting turns the restart would cut.
    restarting: std::sync::atomic::AtomicBool,
    /// While a restart waits: each turn it waits on, and the command it's letting finish.
    held_up: Mutex<HashMap<String, String>>,
    /// Tasks sent back to end their turn properly: their next ending is taken as it is, so it can't go round.
    sent_back: Mutex<std::collections::HashSet<String>>,
    /// Whether turns must end on Zero's ending (zerod turns it on; tests of other things run agents without one).
    endings: std::sync::atomic::AtomicBool,
    /// The turns a restart has paused, shown as paused until the new zerod carries them on.
    updating: Mutex<std::collections::HashSet<String>>,
    /// Sessions the user put on hold: parked, and kept parked whatever arrives for them, until resumed. Kept in
    /// paused-by-user.json (the restart's paused.json is its own, and short-lived).
    paused: Mutex<HashSet<String>>,
    seen: Mutex<HashMap<String, (String, i64)>>,
    pub workspaces: crate::workspaces::Workspaces,
    /// The MCP servers set up in Zero, each task's CLI given its workspace's as it starts.
    pub mcp_servers: crate::mcp_servers::McpServers,
    /// The CLIs' sign-ins, handed to each as a task starts.
    pub signins: crate::signins::SignIns,
    /// A lock per session held while its agent starts (resume).
    resuming: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    /// Files watched for tasks (watches.rs), by id.
    watches: Mutex<HashMap<String, crate::watches::Watch>>,
    /// Each task's scheduled wakes (schedules.rs).
    schedules: Mutex<Vec<crate::schedules::Schedule>>,
    me: Weak<Daemon>,
}

/// What a turn paused for an update says, as it's paused, and once it's carried on.
pub const PAUSED_FOR_UPDATE: &str = "Paused for Zero's update: it carries on once Zero has restarted";
pub const CARRIED: &str = "Zero updated: carrying on where it left off";
/// What a task is told when its turn ends without saying where it left the task (no Zero ending), or on a question to
/// the user it never asked: sent once, unseen in the conversation. Every agent gets it, whichever runs the task.
pub const END_YOUR_TURN_MARK: &str = "Zero can't tell where your turn left the task";
pub const END_YOUR_TURN: &str = "Zero can't tell where your turn left the task. End it with exactly one of these as its last line: \
[zero: done] (nothing is left that you can do, even if others still have steps), [zero: waiting] (the next move is \
someone else's, not the user's), [zero: working] (pausing between steps), or [zero: asked <id>]. Anything you need from the user (a decision, a command for them to run, steps for them to take) \
goes through zero ask, zero run or zero approve with --async (or Zero's zero_ask and zero_run tools), and the turn ends [zero: asked <id>]: a question left in \
your words reaches no one. Don't repeat your answer; do what's missing and end.";
/// What a turn paused for a restart is told once the new zerod is up. Zero's own words, not the user's: never shown as
/// a message (core.rs leaves its item out).
/// Under the user's words when writing to a task withdrew its open asks: for the agent, never shown as the user's.
pub const WITHDRAWN_MARK: &str = "(Zero withdrew your open asks";
pub const CARRY_ON: &str = "Zero restarted while you were working: your turn was paused between steps, and what you had running in the background was stopped. Please carry on where you left off, starting again what you still need.";
/// What a task waiting on the user's answer (the provider's own question or approval) is told: that went with the restart.
pub const CARRY_ON_WAITING: &str = "Zero restarted while you were waiting on the user: your question to them (or the approval you wanted) went with it, unanswered. Please ask again if you still need it, and carry on.";
/// What a task between turns with a run in the background is told: the run went with the restart.
pub const CARRY_ON_BACKGROUND: &str = "Zero restarted between your turns, which stopped what you had running in the background. Please start again what you still need, and carry on.";
/// Every carry-on: Zero's words, never the user's.
pub const CARRIES: [&str; 3] = [CARRY_ON, CARRY_ON_WAITING, CARRY_ON_BACKGROUND];
/// What a working session is told when the user pauses it, steering its turn to an end it can be picked up from.
pub const WRAP_UP: &str = "The user is pausing you (for the night, or while they're away): finish the step you're on, leave the work so it can \
be picked up again, say where you are and what comes next, and end your turn. Don't start anything new.";
/// What a session paused mid-work is told when it's resumed.
pub const RESUMED: &str = "The user paused you and has now resumed you: carry on from where you left off.";
/// How long a restart waits for a running command before pausing its turn anyway: long enough for a test run, not
/// so long that everything already paused sits idle with no sign of why (a deploy isn't an agent's to run unattended).
const COMMAND_WAIT: Duration = Duration::from_secs(2 * 60);

/// How long an agent waits between turns, with nothing open, before its process is stopped (parked): finished work
/// shouldn't hold memory, and resuming takes seconds. Words for it resume it.
pub const PARK_AFTER: Duration = Duration::from_secs(3 * 60);
/// How long a task's provider terminal sits with nothing written or typed before it closes and the task comes back to
/// Zero: longer, since someone may be reading it.
/// An offline task whose conversation nobody has wanted for this long leaves memory, kept as a summary.
pub const UNLOAD_AFTER: Duration = Duration::from_secs(10 * 60);
pub const TERMINAL_PARK_AFTER: Duration = Duration::from_secs(15 * 60);

/// How a lead starts a worker; anything left out comes from the lead.
#[derive(Default, Clone, Debug)]
pub struct Options {
    pub cwd: Option<String>,
    /// The workspace to put it in; none, and its folder decides (a worker goes with its lead).
    pub workspace: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub permissions: Option<Permissions>,
    pub label: Option<String>,
    pub ticket: Option<String>,
    /// Start even though the provider is at its usage limit.
    pub force: bool,
    /// Images with the first message, by their files.
    pub images: Vec<String>,
    /// The sign-in its CLI runs as; none, and the CLI's default.
    pub signin: Option<String>,
    /// Its lead, for a worker.
    pub parent: Option<String>,
}

/// Parks what's been idle long enough, looked at every minute while the daemon lives.
fn park_every_minute(daemon: &Arc<Daemon>) {
    let parker = Arc::downgrade(daemon);
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            match parker.upgrade() { Some(daemon) => daemon.park(), None => return }
        }
    });
}

/// Each session's changes heard by the daemon as they happen, while it lives.
fn hear_sessions(daemon: &Arc<Daemon>) {
    let mut heard = daemon.events.subscribe();
    let weak: Weak<Daemon> = Arc::downgrade(daemon);
    tokio::spawn(async move {
        loop {
            match heard.recv().await {
                Ok(event) => match weak.upgrade() { Some(daemon) => daemon.heard(&event.session), None => return },
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    });
}

/// Its turn over and nothing of the provider's waiting on the user (an approval, a question): what's queued can go,
/// however the turn ended, a question to the user in prose included (the user's queued words answer it). Out of usage,
/// it waits for the reset, which tells it to go on.
fn between_turns(conversation: &Conversation) -> bool {
    conversation.status == Status::Idle && conversation.approvals.is_empty() && conversation.questions.is_empty()
        && conversation.attention() != Attention::Limited
}

fn busy(attention: Attention) -> bool {
    matches!(attention, Attention::Working | Attention::Starting)
}

impl Daemon {
    pub fn open(home: &Path, runtime: Runtime) -> io::Result<Arc<Daemon>> {
        let root = home.join("sessions");
        std::fs::create_dir_all(&root)?;
        // ponytail: 4096 changes of slack per subscriber; one that falls further behind gets fresh snapshots.
        let (events, _) = broadcast::channel(4096);
        let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)?.filter_map(|entry| entry.ok().map(|e| e.path())).filter(|p| p.is_dir()).collect();
        dirs.sort(); // ids sort by when they were made
        let (mut sessions, mut attention, mut pending, mut held) = (vec![], HashMap::new(), HashMap::new(), HashSet::new());
        for dir in dirs {
            match Session::load(&dir, events.clone()) {
                Ok(session) => {
                    let conversation = session.summary();
                    attention.insert(conversation.id.clone(), conversation.attention());
                    let words = kept_pending(&dir);
                    if !words.is_empty() { pending.insert(conversation.id.clone(), words); }
                    if dir.join(HELD).exists() { held.insert(conversation.id.clone()); }
                    sessions.push(session);
                }
                Err(error) => eprintln!("zerod: skipped {}: {error}", dir.display()),
            }
        }
        let daemon = Arc::new_cyclic(|me| Daemon {
            home: home.into(), sessions: Mutex::new(sessions), events, runtime, attention: Mutex::new(attention), pending: Mutex::new(pending),
            held: Mutex::new(held), delivering: Mutex::new(HashSet::new()), queues: broadcast::channel(64).0,
            resets: Mutex::new(HashMap::new()), me: me.clone(), user: Mutex::new(user_places()), restarting: Default::default(), held_up: Mutex::default(), updating: Mutex::default(), sent_back: Mutex::default(), endings: Default::default(),
            workspaces: crate::workspaces::Workspaces::open(home),
            mcp_servers: crate::mcp_servers::McpServers::open(home),
            signins: crate::signins::SignIns::open(home),
            resuming: Mutex::new(HashMap::new()),
            watches: Mutex::new(crate::watches::load(home).into_iter().map(|w| (w.id.clone(), w)).collect()),
            schedules: Mutex::new(crate::schedules::load(home)),
            paused: Mutex::new(std::fs::read(home.join(PAUSED)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()),
            seen: Mutex::new(std::fs::read(home.join(SEEN)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()),
        });
        park_every_minute(&daemon);
        hear_sessions(&daemon);
        daemon.carry_on_watches_and_wakes();
        Ok(daemon)
    }

    /// Where sessions and the daemon's own files are kept.
    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    /// Pinged whenever a session's queue changes.
    pub fn subscribe_queues(&self) -> broadcast::Receiver<()> {
        self.queues.subscribe()
    }

    pub fn sessions(&self) -> Vec<Session> {
        self.sessions.lock().unwrap().clone()
    }

    pub fn session(&self, id: &str) -> Result<Session, String> {
        self.sessions().into_iter().find(|s| s.id() == id).ok_or_else(|| format!("No session {id}"))
    }

    pub fn get(&self, id: &str) -> Option<Conversation> {
        self.session(id).ok().map(|s| s.snapshot())
    }

    /// Every session without its items: enough for a list.
    pub fn list(&self) -> Vec<Conversation> {
        self.sessions().iter().map(|s| s.summary().with_items(vec![])).collect()
    }

    /// A table the agent hands to Zero to draw, as an item of its conversation where it stands in the turn.
    pub fn table(&self, id: &str, title: &str, columns: Vec<String>, rows: Vec<Vec<String>>) -> Result<(), String> {
        if columns.is_empty() { return Err("A table needs columns".into()) }
        let session = self.session(id)?;
        let conversation = session.snapshot();
        let rows = rows.into_iter().map(|mut row| { row.resize(columns.len(), String::new()); row }).collect();
        session.change(Change::Item { item: crate::model::Item { at: None, id: format!("table-{}", conversation.seq + 1), turn: conversation.turn.clone(),
                                                                  kind: ItemKind::Table { title: title.into(), columns, rows }, status: crate::model::ItemStatus::Done } });
        Ok(())
    }

    /// Where the user's home and zero-host are, for a test's own.
    pub fn place(&self, home: &Path, host: &Path) {
        *self.user.lock().unwrap() = (home.into(), host.into());
    }

    fn host(&self) -> crate::host::Host {
        crate::host::Host { socket: self.user.lock().unwrap().1.clone(), sessions: Default::default(), poll: Duration::from_secs(2) }
    }

    fn user_home(&self) -> PathBuf {
        self.user.lock().unwrap().0.clone()
    }

    /// Something its agent says about the task, by name (`zero attr PR <link>`); no value takes it back.
    pub fn set_attribute(&self, id: &str, name: &str, value: Option<&str>) -> Result<(), String> {
        let name = name.trim();
        if name.is_empty() { return Err("An attribute needs a name".into()) }
        let value = value.map(str::trim).filter(|v| !v.is_empty()).map(String::from);
        self.session(id)?.change(Change::Attribute { name: name.into(), value });
        Ok(())
    }

    /// Which workspace a conversation is in: the one it was put in, else its folder's, else Zero.
    pub fn workspace_of(&self, conversation: &Conversation) -> String { self.workspaces.of(conversation.workspace.as_deref(), &conversation.cwd) }

    /// Puts a session in a workspace (none: back to its folder's).
    pub fn place_in_workspace(&self, id: &str, workspace: Option<&str>) -> Result<(), String> {
        if let Some(workspace) = workspace && !self.workspaces.exists(workspace) { return Err(format!("No workspace {workspace}")) }
        self.session(id)?.change(Change::Placed { workspace: workspace.map(Into::into) });
        Ok(())
    }

    /// Names a session and says what it's for.
    pub fn label(&self, id: &str, label: Option<&str>, ticket: Option<&str>) -> Result<(), String> {
        self.session(id)?.change(Change::Named { label: label.map(Into::into), ticket: ticket.map(Into::into) });
        Ok(())
    }

    /// Where the task runs, by name; none goes back to its folder.
    pub fn set_place(&self, id: &str, place: Option<&str>) -> Result<(), String> {
        self.session(id)?.change(Change::Place { place: place.map(Into::into).filter(|p: &String| !p.trim().is_empty()) });
        Ok(())
    }

    /// The sessions `lead` started.
    pub fn workers(&self, lead: &str) -> Vec<Conversation> {
        self.list().into_iter().filter(|c| c.parent.as_deref() == Some(lead)).collect()
    }

    pub fn last_answer(&self, id: &str) -> Option<String> {
        self.get(id)?.answer().map(String::from)
    }

    /// Waits until every one of `ids` (or, with `any`, one of them) has stopped working, whether finished, failed,
    /// stuck or waiting on the user, up to `timeout`; returns them as they are then.
    pub async fn wait(&self, ids: &[String], any: bool, timeout: Duration) -> Result<Vec<Conversation>, String> {
        let mut events = self.events.subscribe();
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let now: Vec<Conversation> = ids.iter().map(|id| self.get(id).ok_or_else(|| format!("No session {id}"))).collect::<Result<_, _>>()?;
            let settled = |c: &Conversation| !busy(c.attention());
            if if any { now.iter().any(settled) } else { now.iter().all(settled) } { return Ok(now) }
            if tokio::time::timeout_at(deadline, events.recv()).await.is_err() {
                return Err(format!("Still working after {} minutes", timeout.as_secs() / 60));
            }
        }
    }

    /// A task there, live or archived: done and put away, it still follows things, and hears of them (`notify`).
    pub fn exists(&self, id: &str) -> bool { self.session(id).is_ok() || self.home.join("archive").join(id).join("meta.json").exists() }

}

/// The user's home, and zero-host's socket in Zero's folder there.
fn user_places() -> (PathBuf, PathBuf) {
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let host = home.join(".zero/host.sock");
    (home, host)
}

/// The branch a folder's repository has checked out; none outside a repository.
fn branch(folder: &Path) -> Option<String> {
    let output = std::process::Command::new("git").args(["symbolic-ref", "--short", "HEAD"]).current_dir(folder)
        .stderr(std::process::Stdio::null()).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_string()).filter(|b| !b.is_empty())
}

/// Sortable by creation: milliseconds since 1970, then a counter, in hex.
fn new_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    format!("{:012x}{:04x}", now_ms(), COUNTER.fetch_add(1, Ordering::Relaxed) & 0xffff)
}

/// A snapshot taken as a message went, noted against that message: the latest of yours without one.
fn attach_snapshot(session: &Session, commit: String) {
    let conversation = session.snapshot();
    let Some(item) = conversation.items.iter().rev().find(|i| matches!(i.kind, ItemKind::User { .. })) else { return };
    if conversation.snapshots.contains_key(&item.id) { return }
    session.change(Change::Snapshot { item: item.id.clone(), commit });
}

#[cfg(test)]
mod tests {
    #[test]
    fn ids_sort_in_the_order_they_were_made() {
        let ids: Vec<String> = (0..100).map(|_| super::new_id()).collect();
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(ids, sorted);
        assert_eq!(ids[0].len(), 16);
    }
}
