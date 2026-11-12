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

use crate::model::{Attention, Change, Conversation, Event, ItemKind, Opened, Permissions, Provider, Queued, Status};
use crate::process;
use crate::session::{Message, ModelChoice, Session, Transport};
use crate::{claude, now, now_ms};

use archive::archived_with;
pub use heard::report;
pub use inbox::Sessions;
pub use rewind::Rewind;
use send::kept_pending;
pub use terminals::terminal_command;

/// Starts a session's runtime process: its conversation, its folder in the daemon's home, and the command line
/// its provider starts with.
pub type Runtime = Arc<dyn Fn(&Conversation, &Path, &[String]) -> io::Result<Transport> + Send + Sync>;

/// The real one: the provider's CLI in the session's folder, its errors in the session's stderr.log.
pub fn real_runtime() -> Runtime {
    Arc::new(|conversation, dir, argv| process::spawn(argv, Path::new(&conversation.cwd), &conversation.id, Some(&dir.join("stderr.log"))))
}

const PAUSED: &str = "paused-by-user.json";
const SAVED: &str = "saved-for-later.json";
/// Whether a task has a blocking ask open (the inbox knows).
pub type Blocked = Box<dyn Fn(&str) -> bool + Send + Sync>;
/// A user's queued words as they go to the agent: the note on its open asks added then (the inbox's to say).
/// Whether a task's own note says who it waits on (board::says_who), from the inbox.
pub type SaysWho = Box<dyn Fn(&Conversation) -> bool + Send + Sync>;
/// What else hears a task's turn end (the inbox, keeping the agent's answer with the ask it answers).
pub type Ended = Box<dyn Fn(&Conversation) + Send + Sync>;
pub type Noted = Box<dyn Fn(&str, String) -> String + Send + Sync>;

/// Messages two tasks may send each other without the user before Zero holds them for the user's word.
const BETWEEN_TASKS: u32 = 10;
/// The agents' processes one zerod hands the next across a restart (Daemon::hand_off, take_over).
const HANDOFF: &str = "handoff.json";
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
    /// Turns in a row each task's CLI ended on a server or network error, that Zero carried on.
    carried_on: Mutex<HashMap<String, u32>>,
    /// Each session's last answer counted for its account's activity (heard.rs): a turn counts once.
    counted: Mutex<HashMap<String, String>>,
    /// New Claude tasks without a name get one from a small model (naming.rs): zerod's, not the tests', which would spend.
    naming: std::sync::atomic::AtomicBool,
    /// Messages between two tasks (neither the other's lead) since the user last wrote to either, by the pair.
    crossed: Mutex<HashMap<(String, String), u32>>,
    /// Whether a task has a blocking ask open (Ask::blocks), as the inbox says: its events and reports wait then.
    blocked: std::sync::OnceLock<Blocked>,
    noted: std::sync::OnceLock<Noted>,
    /// What tasks follow (following.rs): the pull requests they open are followed, and a turn waiting on nothing told.
    following: std::sync::OnceLock<Arc<crate::following::Following>>,
    says_who: std::sync::OnceLock<SaysWho>,
    ended: std::sync::OnceLock<Ended>,
    /// Tasks told nothing wakes them: not again until something could (a follow, a background run, a note saying who).
    /// ponytail: in memory; a restart may tell one once more.
    told_nothing_wakes: Mutex<HashSet<String>>,
    /// Tasks whose messages from other tasks wait for the user: too many between them without the user.
    crossing: Mutex<HashSet<String>>,
    /// Workers that ended done: each leaves its lead's tree (archived) once its report has been handed to the lead.
    leaving: Mutex<HashSet<String>>,
    /// Sessions being archived now: their end is the archiving, not news for their lead.
    archiving: Mutex<HashSet<String>>,
    /// What's in archive/, kept in archive.json: listing it read every archived folder (hundreds) each time.
    archive_index: Mutex<Option<Vec<archive::Archived>>>,
    /// (lead, ticket) → when Zero last reminded the lead to set that row: once, until the row is set again.
    reminded_rows: Mutex<HashMap<(String, String), i64>>,
    /// Accounts a task's CLI found signed out (`account`): Zero's words to any task on one wait for a turn that works.
    signed_out: Mutex<HashSet<String>>,
    /// Whether turns must end on Zero's ending (zerod turns it on; tests of other things run agents without one).
    endings: std::sync::atomic::AtomicBool,
    /// The turns a restart has paused, shown as paused until the new zerod carries them on.
    updating: Mutex<std::collections::HashSet<String>>,
    /// Sessions the user put on hold: parked, and kept parked whatever arrives for them, until resumed. Kept in
    /// paused-by-user.json (the restart's paused.json is its own, and short-lived).
    paused: Mutex<HashSet<String>>,
    /// Tasks the user saved for later, whole: on hold and off the board, not archived, until resumed from Later. Kept
    /// in saved-for-later.json.
    saved: Mutex<HashSet<String>>,
    seen: Mutex<HashMap<String, (String, i64)>>,
    pub workspaces: crate::workspaces::Workspaces,
    /// The MCP servers set up in Zero, each task's CLI given its workspace's as it starts.
    pub mcp_servers: crate::mcp_servers::McpServers,
    /// Sign-ins to MCP servers tasks' CLIs say need one (mcp_auth.rs).
    pub mcp_auth: Arc<crate::mcp_auth::McpAuth>,
    /// The CLIs' sign-ins, handed to each as a task starts.
    pub signins: crate::signins::SignIns,
    /// A lock per session held while its agent starts (resume).
    resuming: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    /// Files watched for tasks (watches.rs), by id.
    watches: Mutex<HashMap<String, crate::watches::Watch>>,
    /// Each task's scheduled wakes (schedules.rs).
    schedules: Mutex<Vec<crate::schedules::Schedule>>,
    /// What each running task's processes use (uses.rs), as last sent to clients.
    uses: tokio::sync::watch::Sender<crate::uses::Tasks>,
    /// What tasks left running (left.rs), as last sent to clients.
    left: tokio::sync::watch::Sender<crate::left::Tasks>,
    me: Weak<Daemon>,
}

/// What a turn paused for an update says, as it's paused, and once it's carried on.
pub const PAUSED_FOR_UPDATE: &str = "Paused for Zero's update: it carries on once Zero has restarted";
pub const CARRIED: &str = "Zero updated: carrying on where it left off";
/// What a task is told when its turn ends without saying where it left the task (no Zero ending), or on a question to
/// the user it never asked: sent once, unseen in the conversation. Every agent gets it, whichever runs the task.
pub const END_YOUR_TURN_MARK: &str = "Zero can't tell where your turn left the task";
pub const END_YOUR_TURN: &str = "Zero can't tell where your turn left the task. End it with exactly one of these as its last line: \
[zero: done] (the work is finished end to end: merged and deployed, verified, or the user said so; and only after \
`zero done` confirmed it, its token, or zero done --ask), [zero: waiting] \
(the next move is someone else's, not the user's: a review, CI, a deploy, QA), [zero: working] (pausing between steps), or [zero: asked <id>]. Anything you need from the user (a decision, a command for them to run, steps for them to take) \
goes through zero ask, zero run or zero approve with --async (or Zero's zero_ask and zero_run tools), and the turn ends [zero: asked <id>]: a question left in \
your words reaches no one. Don't repeat your answer; do what's missing and end.";
/// What a worker is told when its turn ends without Zero's ending: as a task's, in a worker's terms. Its lead hears how
/// it ended, and a decision it can't make (its lead's or the user's) is blocked, red on its row, not a reply.
pub const END_A_WORKERS_TURN: &str = "Zero can't tell where your turn left the task. You're a worker: your lead hears how you end. End it with \
exactly one of these as its last line: [zero: done] (your part is finished: your lead takes it from here), [zero: waiting] \
(the next move is someone else's: CI, a review, another worker), [zero: blocked] (you can't go on without a decision or \
access you don't have, your lead's or the user's: mark it first with `zero blocked \"what you need\"`, confirmed with its \
token, and say exactly what would unblock you; your lead takes it to the user), or [zero: working] (pausing between steps). \
Don't repeat your answer; do what's missing and end.";
/// What a turn paused for a restart is told once the new zerod is up. Zero's own words, not the user's: never shown as
/// a message (core.rs leaves its item out).
/// What a task is told when its turn ends waiting with nothing to wake it: once, its reply taken as it is.
pub const NOTHING_WAKES_MARK: &str = "Nothing will wake you";
pub const NOTHING_WAKES: &str = "Nothing will wake you: you follow nothing and have nothing running. Follow what you wait on \
(`zero follow <url>`), or say who you're waiting on.";
/// What a lead is told when a worker's report reached it and the issue's row wasn't set in that turn (`zero issue`).
pub const ISSUE_ROW_MARK: &str = "The issue's row wasn't set";
/// Under the user's words when the task has asks open: for the agent, never shown as the user's.
pub const OPEN_ASKS_MARK: &str = "(Zero: your asks still open:";
pub const CARRY_ON: &str = "Zero restarted while you were working: your turn was paused between steps, and what you had running in the background was stopped. Please carry on where you left off, starting again what you still need.";
/// What a task waiting on the user's answer (the provider's own question or approval) is told: that went with the restart.
pub const CARRY_ON_WAITING: &str = "Zero restarted while you were waiting on the user: your question to them (or the approval you wanted) went with it, unanswered. Please ask again if you still need it, and carry on.";
/// What a task between turns with a run in the background is told: the run went with the restart.
pub const CARRY_ON_BACKGROUND: &str = "Zero restarted between your turns, which stopped what you had running in the background. Please start again what you still need, and carry on.";
/// Every carry-on: Zero's words, never the user's.
/// A turn its CLI gave up on, at a server or network error, past its own retries.
pub const CARRY_ON_AFTER_ERROR: &str = "Your last turn ended on a server error from your provider. Please carry on where you left off.";
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
            match parker.upgrade() {
                Some(daemon) => daemon.park(),
                None => return,
            }
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
                Ok(event) => match weak.upgrade() {
                    Some(daemon) => {
                        if let Change::Item { item } = &event.change
                            && item.status == crate::model::ItemStatus::Done
                            && let Some(url) = crate::following::opened(&item.kind)
                        {
                            daemon.follow_opened(&event.session, &url)
                        }
                        daemon.heard(&event.session)
                    }
                    None => return,
                },
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
    conversation.status == Status::Idle
        && conversation.approvals.is_empty()
        && conversation.questions.is_empty()
        && conversation.attention() != Attention::Limited
}

/// Its CLI says it isn't signed in.
fn signed_out(conversation: &Conversation) -> bool {
    conversation.failure.as_ref().is_some_and(|f| f.kind == crate::model::FailureKind::SignIn)
}

/// The account a task's CLI runs as: one of Zero's sign-ins, or the CLI's own (none).
fn account(conversation: &Conversation) -> String {
    format!("{:?}:{}", conversation.provider, conversation.signin.as_deref().unwrap_or(""))
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
        let mut dirs: Vec<PathBuf> =
            std::fs::read_dir(&root)?.filter_map(|entry| entry.ok().map(|e| e.path())).filter(|p| p.is_dir()).collect();
        dirs.sort(); // ids sort by when they were made
        let (mut sessions, mut attention, mut pending, mut held) = (vec![], HashMap::new(), HashMap::new(), HashSet::new());
        for dir in dirs {
            match Session::load(&dir, events.clone()) {
                Ok(session) => {
                    let conversation = session.summary();
                    attention.insert(conversation.id.clone(), conversation.attention());
                    let words = kept_pending(&dir);
                    if !words.is_empty() {
                        pending.insert(conversation.id.clone(), words);
                    }
                    if dir.join(HELD).exists() {
                        held.insert(conversation.id.clone());
                    }
                    sessions.push(session);
                }
                Err(error) => eprintln!("zerod: skipped {}: {error}", dir.display()),
            }
        }
        let daemon = Arc::new_cyclic(|me| Daemon {
            home: home.into(),
            sessions: Mutex::new(sessions),
            events,
            runtime,
            attention: Mutex::new(attention),
            pending: Mutex::new(pending),
            held: Mutex::new(held),
            delivering: Mutex::new(HashSet::new()),
            queues: broadcast::channel(64).0,
            resets: Mutex::new(HashMap::new()),
            me: me.clone(),
            user: Mutex::new(user_places()),
            restarting: Default::default(),
            held_up: Mutex::default(),
            updating: Mutex::default(),
            sent_back: Mutex::default(),
            carried_on: Mutex::default(),
            counted: Mutex::default(),
            reminded_rows: Mutex::default(),
            leaving: Mutex::default(),
            archiving: Mutex::default(),
            archive_index: Mutex::default(),
            blocked: Default::default(),
            noted: Default::default(),
            following: Default::default(),
            says_who: Default::default(),
            ended: Default::default(),
            told_nothing_wakes: Mutex::default(),
            crossed: Mutex::default(),
            crossing: Mutex::default(),
            naming: Default::default(),
            signed_out: Mutex::default(),
            endings: Default::default(),
            workspaces: crate::workspaces::Workspaces::open(home),
            mcp_servers: crate::mcp_servers::McpServers::open(home),
            mcp_auth: crate::mcp_auth::McpAuth::new(crate::mcp_auth::runner()),
            signins: crate::signins::SignIns::open(home),
            resuming: Mutex::new(HashMap::new()),
            watches: Mutex::new(crate::watches::load(home).into_iter().map(|w| (w.id.clone(), w)).collect()),
            schedules: Mutex::new(crate::schedules::load(home)),
            uses: tokio::sync::watch::channel(Default::default()).0,
            left: tokio::sync::watch::channel(Default::default()).0,
            paused: Mutex::new(
                std::fs::read(home.join(PAUSED)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default(),
            ),
            saved: Mutex::new(std::fs::read(home.join(SAVED)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()),
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

    /// What each running task's processes use, now and whenever it changes enough to show.
    pub fn uses(&self) -> tokio::sync::watch::Receiver<crate::uses::Tasks> {
        self.uses.subscribe()
    }

    pub fn publish_uses(&self, tasks: crate::uses::Tasks) {
        self.uses.send_replace(tasks);
    }

    /// What tasks left running, now and whenever it changes enough to show.
    pub fn left(&self) -> tokio::sync::watch::Receiver<crate::left::Tasks> {
        self.left.subscribe()
    }

    pub fn publish_left(&self, tasks: crate::left::Tasks) {
        self.left.send_replace(tasks);
    }

    /// Every task, archived ones too, as left.rs looks for what each left running.
    pub fn left_roots(&self) -> Vec<crate::left::Task> {
        let mut tasks: Vec<crate::left::Task> = self
            .sessions()
            .iter()
            .map(|session| {
                let summary = session.summary();
                crate::left::Task {
                    label: crate::bridge::label(&summary),
                    pid: session.pid(),
                    idle: !matches!(summary.status, Status::Working | Status::Waiting | Status::Starting),
                    done: session.attention() == crate::model::Attention::Done,
                    last: summary.items.iter().filter_map(|i| i.at).max(),
                    archived: false,
                    id: summary.id,
                }
            })
            .collect();
        tasks.extend(self.archived_tasks().into_iter().map(|(id, label)| crate::left::Task {
            id,
            label,
            pid: None,
            idle: true,
            done: false,
            archived: true,
            last: None,
        }));
        tasks
    }

    /// Stops what `session` left running: the things named (all of them, with none), as last found. Nothing else.
    pub async fn stop_left(&self, session: &str, things: Option<&[String]>) -> Result<usize, String> {
        let left = self.left.borrow().get(session).map(|l| l.things.clone()).unwrap_or_default();
        let chosen: Vec<_> = left.into_iter().filter(|t| things.is_none_or(|ids| ids.contains(&t.id))).collect();
        if chosen.is_empty() {
            return Err("Nothing like that is left running for this task".into());
        }
        let mut failed = vec![];
        for thing in &chosen {
            if let Err(error) = crate::left::stop(thing).await {
                failed.push(error)
            }
        }
        // Gone from the list at once, not at the next look: anything that survived is found again then.
        self.left.send_modify(|tasks| {
            if let Some(left) = tasks.get_mut(session) {
                left.things.retain(|t| !chosen.iter().any(|c| c.id == t.id));
                if left.things.is_empty() {
                    tasks.remove(session);
                }
            }
        });
        if failed.is_empty() { Ok(chosen.len()) } else { Err(failed.join("; ")) }
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

    /// A session without its conversation's items but its latest few (Session::summary): read without loading it.
    pub fn summary(&self, id: &str) -> Option<Conversation> {
        self.session(id).ok().map(|s| s.summary())
    }

    /// Every session without its items: enough for a list.
    pub fn list(&self) -> Vec<Conversation> {
        self.sessions().iter().map(|s| s.summary().with_items(vec![])).collect()
    }

    /// A table the agent hands to Zero to draw, as an item of its conversation where it stands in the turn.
    pub fn table(&self, id: &str, title: &str, columns: Vec<String>, rows: Vec<Vec<String>>) -> Result<(), String> {
        if columns.is_empty() {
            return Err("A table needs columns".into());
        }
        let session = self.session(id)?;
        let conversation = session.snapshot();
        let rows = rows
            .into_iter()
            .map(|mut row| {
                row.resize(columns.len(), String::new());
                row
            })
            .collect();
        session.change(Change::Item {
            item: crate::model::Item {
                at: None,
                id: format!("table-{}", conversation.seq + 1),
                turn: conversation.turn.clone(),
                kind: ItemKind::Table { title: title.into(), columns, rows },
                status: crate::model::ItemStatus::Done,
            },
        });
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
        if name.is_empty() {
            return Err("An attribute needs a name".into());
        }
        let value = value.map(str::trim).filter(|v| !v.is_empty()).map(String::from);
        self.session(id)?.change(Change::Attribute { name: name.into(), value: value.clone() });
        if name.eq_ignore_ascii_case("PR")
            && let Some(url) = value
            && let Some(topic) = self.following.get().and_then(|f| f.adopt(id, &url))
        {
            self.say_following(id, &topic)
        }
        Ok(())
    }

    /// One of the issues the task drives, its row set (`zero issue`): its time in a state carries on while the state
    /// doesn't change, and its time on the user is kept as it moves on.
    pub fn set_issue(&self, id: &str, ticket: &str, state: crate::model::IssueState, text: &str) -> Result<(), String> {
        let ticket = ticket.trim();
        if ticket.is_empty() {
            return Err("An issue needs its ticket".into());
        }
        let session = self.session(id)?;
        let previous = session.summary().issues.into_iter().find(|i| i.ticket == ticket);
        let issue = crate::model::Issue::set(previous.as_ref(), ticket, state, text.trim(), crate::now_ms());
        session.change(Change::Issue { issue });
        let _ = self.queues.send(()); // the board, at once
        Ok(())
    }

    /// Which workspace a conversation is in: the one it was put in, else Zero.
    pub fn workspace_of(&self, conversation: &Conversation) -> String {
        self.workspaces.of(conversation.workspace.as_deref())
    }

    /// Puts a session in a workspace (none: back to Zero).
    pub fn place_in_workspace(&self, id: &str, workspace: Option<&str>) -> Result<(), String> {
        if let Some(workspace) = workspace
            && !self.workspaces.exists(workspace)
        {
            return Err(format!("No workspace {workspace}"));
        }
        self.session(id)?.change(Change::Placed { workspace: workspace.map(Into::into) });
        Ok(())
    }

    /// How to tell a task has a blocking ask open: the inbox's, given once (server::hold_while_blocked).
    pub fn hold_while(&self, blocked: Blocked) {
        let _ = self.blocked.set(blocked);
    }

    /// What tasks follow, given once (main.rs).
    pub fn set_following(&self, following: Arc<crate::following::Following>) {
        let _ = self.following.set(following);
    }

    /// How to tell a task's note says who it waits on, given once (server::know_waiting_notes).
    pub fn know_who(&self, says_who: SaysWho) {
        let _ = self.says_who.set(says_who);
    }

    /// What else hears a turn end, given once (server::link_asks).
    pub fn when_ended(&self, ended: Ended) {
        let _ = self.ended.set(ended);
    }

    /// What's added to a user's queued words as they go to the agent.
    pub fn note_with(&self, noted: Noted) {
        let _ = self.noted.set(noted);
    }

    pub(crate) fn noted(&self, id: &str, text: String) -> String {
        match self.noted.get() {
            Some(noted) => noted(id, text),
            None => text,
        }
    }

    pub(crate) fn blocked_by_ask(&self, id: &str) -> bool {
        self.blocked.get().is_some_and(|blocked| blocked(id))
    }

    /// A task by its id, or by its name (as the sidebar shows it, whatever the case) when only one task has it. One
    /// archived (a finished worker put away, a task closed) comes back for what's sent to it, with its workers, as
    /// unarchiving brings them; a live task by that name comes first.
    pub fn resolve(&self, reference: &str) -> Result<String, String> {
        let reference = reference.trim();
        if self.session(reference).is_ok() {
            return Ok(reference.to_string());
        }
        let mut named: Vec<String> =
            self.list().into_iter().filter(|c| crate::bridge::label(c).eq_ignore_ascii_case(reference)).map(|c| c.id).collect();
        if named.is_empty() {
            named = if !reference.contains('/') && self.exists(reference) {
                vec![reference.to_string()]
            } else {
                self.archived_named(reference)
            };
            if let [one] = named.as_slice() {
                // Back with the lead it went with, if it went with one: its tree as it was.
                let root = archived_with(&self.home.join("archive").join(one)).unwrap_or_else(|| one.clone());
                self.unarchive(&root)?;
            }
        }
        match named.as_slice() {
            [one] => Ok(one.clone()),
            [] => Err(format!("No task {reference}")),
            several => Err(format!("{} tasks are called {reference}: say which by its id ({})", several.len(), several.join(", "))),
        }
    }

    /// The user asks two tasks to work together: each is told about the other (its name, folder and what it's on)
    /// and how to reach it.
    pub fn introduce(&self, a: &str, b: &str) -> Result<(), String> {
        if a == b {
            return Err("A task can't be introduced to itself".into());
        }
        let (first, second) = (self.get(a).ok_or_else(|| format!("No task {a}"))?, self.get(b).ok_or_else(|| format!("No task {b}"))?);
        self.tell(a, crate::model::from_line("zero", &introduction(&second)));
        self.tell(b, crate::model::from_line("zero", &introduction(&first)));
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
            // Archived, it's found there as it was put away.
            let now: Vec<Conversation> = ids
                .iter()
                .map(|id| self.get(id).or_else(|| self.archived_summary(id)).ok_or_else(|| format!("No session {id}")))
                .collect::<Result<_, _>>()?;
            // Between turns with a run of its own in the background, it's carried on when that finishes: not settled.
            let settled = |c: &Conversation| !busy(c.attention()) && self.background(&c.id).is_none();
            if if any { now.iter().any(settled) } else { now.iter().all(settled) } {
                return Ok(now);
            }
            if tokio::time::timeout_at(deadline, events.recv()).await.is_err() {
                return Err(format!("Still working after {} minutes", timeout.as_secs() / 60));
            }
        }
    }

    /// What a task left running in the background as its turn ended, which wakes it when it finishes (Session::background).
    pub fn background(&self, id: &str) -> Option<Vec<String>> {
        self.session(id).ok()?.background()
    }

    /// Whether a worker finished (its last turn ended on an answer, not waiting, asked or between steps) and its lead
    /// has had that report: a message from it in the lead's conversation since, not one still queued there.
    pub fn finished(&self, worker: &str) -> bool {
        let Some(conversation) = self.get(worker).filter(|c| c.ended() == Attention::Done) else { return false };
        let answered =
            conversation.items.iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. })).and_then(|i| i.at);
        let (Some(answered), Some(lead)) = (answered, conversation.parent.as_deref().and_then(|lead| self.get(lead))) else { return false };
        let marked = crate::model::from_line(worker, "");
        lead.items
            .iter()
            .rev()
            .take_while(|i| i.at.is_none_or(|at| at >= answered))
            .any(|i| matches!(&i.kind, ItemKind::User { text, .. } if text.contains(&marked)))
    }

    /// A task there, live or archived: done and put away, it still follows things, and hears of them (`notify`).
    pub fn exists(&self, id: &str) -> bool {
        self.session(id).is_ok() || self.home.join("archive").join(id).join("meta.json").exists()
    }
}

/// The user's home, and zero-host's socket in Zero's folder there.
fn user_places() -> (PathBuf, PathBuf) {
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let host = home.join(".zero/host.sock");
    (home, host)
}

/// The branch a folder's repository has checked out; none outside a repository.
fn branch(folder: &Path) -> Option<String> {
    let output = std::process::Command::new("git")
        .args(["symbolic-ref", "--short", "HEAD"])
        .current_dir(folder)
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
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
    if conversation.snapshots.contains_key(&item.id) {
        return;
    }
    session.change(Change::Snapshot { item: item.id.clone(), commit });
}

/// What a task is told of another it should work with: who it is, where, what it's on, and how to reach it.
fn introduction(other: &Conversation) -> String {
    let doing = other
        .answer()
        .or_else(|| {
            other.items.iter().find_map(|i| match &i.kind {
                ItemKind::User { text, .. } => Some(text.as_str()),
                _ => None,
            })
        })
        .and_then(|text| text.lines().map(str::trim).find(|l| !l.is_empty()))
        .map(|line| format!(" Its latest: \"{}\".", line.chars().take(200).collect::<String>()))
        .unwrap_or_default();
    format!(
        "The user wants you to work with another task: \"{}\" ({}), in {}.{doing} When your work touches its area, \
coordinate with it directly: `zero send {} \"…\"` (its name works too). Its replies come to you as messages from it. \
Keep the user out of what you two can settle; ask them only for what's theirs to decide.",
        crate::bridge::label(other),
        other.id,
        other.cwd,
        other.id
    )
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
