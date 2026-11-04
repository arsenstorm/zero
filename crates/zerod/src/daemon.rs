//! The daemon's sessions: started in a folder, kept under `<home>/sessions/<id>/`, loaded again at start-up,
//! and resumed with a new runtime process whenever one is wanted. A session can start others (a lead and its
//! workers): each worker's outcome is put to its lead as a message once the lead is between turns.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::sync::broadcast;

use crate::claude;
use crate::model::{Attention, Change, Conversation, Event, ItemKind, Opened, Permissions, Provider, Queued, Status};
use crate::process;
use crate::session::{Session, Transport};

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

/// What a turn paused for a restart is told once the new zerod is up. Zero's own words, not yours: never shown as a
/// message (core.rs leaves its item out).
/// What a turn paused for an update says, as it's paused, and once it's carried on.
pub const PAUSED_FOR_UPDATE: &str = "Paused for Zero's update: it carries on once Zero has restarted";
pub const CARRIED: &str = "Zero updated: carrying on where it left off";
pub const CARRY_ON: &str = "Zero restarted while you were working: your turn was paused between steps. Please carry on where you left off.";
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
            resets: Mutex::new(HashMap::new()), me: me.clone(), user: Mutex::new(user_places()), restarting: Default::default(), held_up: Mutex::default(),
            workspaces: crate::workspaces::Workspaces::open(home),
            mcp_servers: crate::mcp_servers::McpServers::open(home),
            signins: crate::signins::SignIns::open(home),
            resuming: Mutex::new(HashMap::new()),
            watches: Mutex::new(crate::watches::load(home).into_iter().map(|w| (w.id.clone(), w)).collect()),
            schedules: Mutex::new(crate::schedules::load(home)),
            paused: Mutex::new(std::fs::read(home.join(PAUSED)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()),
            seen: Mutex::new(std::fs::read(home.join(SEEN)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()),
        });
        let parker = Arc::downgrade(&daemon);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(60)).await;
                match parker.upgrade() { Some(daemon) => daemon.park(), None => return }
            }
        });
        let mut heard = daemon.events.subscribe();
        let weak: Weak<Daemon> = Arc::downgrade(&daemon);
        tokio::spawn(async move {
            loop {
                match heard.recv().await {
                    Ok(event) => match weak.upgrade() { Some(daemon) => daemon.heard(&event.session), None => return },
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return,
                }
            }
        });
        // Watches kept from before a restart carry on from where they'd read to.
        let kept: Vec<String> = daemon.watches.lock().unwrap().keys().cloned().collect();
        for id in kept { daemon.follow_file(id) }
        // Wakes kept from before a restart: armed again, any already due told now.
        let due: Vec<crate::schedules::Schedule> = daemon.schedules.lock().unwrap().clone();
        for schedule in due { daemon.arm(schedule) }
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

    /// A message of the user's for after the current turn: queued behind what's already waiting, one turn each.
    /// Between turns already, it goes now. Queueing releases a held queue: the user is back with it.
    pub fn queue(&self, id: &str, text: &str, images: &[String]) -> Result<Queued, String> {
        let session = self.session(id)?;
        if text.trim().is_empty() && images.is_empty() { return Err("A message needs words or an image".into()) }
        let queued = Queued { id: new_id(), text: text.into(), images: images.to_vec(), report: false };
        self.pending.lock().unwrap().entry(id.into()).or_default().push(queued.clone());
        self.hold(id, false);
        self.keep_pending(id);
        if between_turns(&session.summary()) { self.deliver(id) }
        Ok(queued)
    }

    /// Takes a queued message back.
    pub fn unqueue(&self, id: &str, item: &str) -> Result<Queued, String> {
        let taken = {
            let mut pending = self.pending.lock().unwrap();
            let list = pending.get_mut(id).ok_or("Nothing is queued")?;
            let index = list.iter().position(|q| q.id == item).ok_or("That message isn't queued any more")?;
            list.remove(index)
        };
        self.keep_pending(id);
        Ok(taken)
    }

    /// Lets a held queue go on.
    pub fn release(&self, id: &str) -> Result<(), String> {
        self.session(id)?;
        self.hold(id, false);
        let _ = self.queues.send(());
        self.deliver(id);
        Ok(())
    }

    /// The user's messages waiting for `id`, in order (reports aren't theirs to see), and whether they're held.
    pub fn queued(&self, id: &str) -> (Vec<Queued>, bool) {
        let list = self.pending.lock().unwrap().get(id).map(|l| l.iter().filter(|q| !q.report).cloned().collect()).unwrap_or_default();
        (list, self.held.lock().unwrap().contains(id))
    }

    /// Every session's queue, for the board.
    pub fn queues(&self) -> HashMap<String, (Vec<Queued>, bool)> {
        let held = self.held.lock().unwrap();
        self.pending.lock().unwrap().iter()
            .map(|(id, list)| (id.clone(), (list.iter().filter(|q| !q.report).cloned().collect::<Vec<_>>(), held.contains(id))))
            .filter(|(_, (list, _))| !list.is_empty())
            .collect()
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

    /// Starts a session in `cwd` with `prompt` as its first turn; returns its id at once, while the runtime starts.
    pub fn start(&self, provider: Provider, cwd: &str, prompt: &str, model: Option<&str>, effort: Option<&str>, permissions: Permissions) -> Result<String, String> {
        let options = Options { cwd: Some(cwd.into()), workspace: None, model: model.map(Into::into), effort: effort.map(Into::into), permissions: Some(permissions), ..Default::default() };
        self.create(provider, prompt, options, None)
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

    /// A session of its own (no lead), with every option.
    pub fn start_with(&self, provider: Provider, prompt: &str, options: Options) -> Result<String, String> {
        self.create(provider, prompt, options, None)
    }

    /// A worker of `lead`: in the lead's folder, with the lead's permissions, unless told otherwise.
    pub fn spawn(&self, lead: &str, provider: Provider, prompt: &str, mut options: Options) -> Result<String, String> {
        let parent = self.get(lead).ok_or_else(|| format!("No session {lead} to lead it"))?;
        options.cwd = options.cwd.or(Some(parent.cwd.clone()));
        options.permissions = options.permissions.or(Some(parent.permissions));
        // On its lead's model unless told otherwise: left to itself, the provider would start it on its own default.
        if provider == parent.provider {
            options.model = options.model.or(parent.model.clone());
            options.effort = options.effort.or(parent.effort.clone());
        }
        // The lead decides: its worker is in its workspace wherever the worker's folder is.
        options.workspace = options.workspace.or_else(|| Some(self.workspace_of(&parent)));
        self.create(provider, prompt, options, Some(lead.to_string()))
    }

    fn create(&self, provider: Provider, prompt: &str, options: Options, parent: Option<String>) -> Result<String, String> {
        let cwd = options.cwd.as_deref().unwrap_or("");
        let (model, effort) = (options.model.as_deref(), options.effort.as_deref());
        let folder = Path::new(cwd);
        if !folder.is_absolute() || !folder.is_dir() { return Err(format!("{cwd} isn't a folder")) }
        if !options.force && let Some((_, usage)) = self.usage().into_iter().find(|(p, u)| *p == provider && u.limited && u.resets_at.is_none_or(|at| at > now()))
        {
            let until = usage.resets_at.map(|at| format!(" until {}", at)).unwrap_or_default();
            return Err(format!("{} is at its usage limit{until}; start it anyway with force", provider.title()));
        }
        if prompt.trim().is_empty() && options.images.is_empty() { return Err("A session starts with something to do".into()) }
        let id = new_id();
        let dir = self.home.join("sessions").join(&id);
        let mut conversation = Conversation::new(&id, provider, cwd);
        conversation.permissions = options.permissions.unwrap_or_default();
        conversation.parent = parent;
        if let Some(workspace) = &options.workspace && !self.workspaces.exists(workspace) { return Err(format!("No workspace {workspace}")) }
        conversation.workspace = options.workspace.clone();
        if let Some(signin) = &options.signin && self.signins.get(signin).is_none_or(|s| s.cli != provider) { return Err(format!("No {} sign-in {signin}", provider.title())) }
        // Chosen, else its lead's (a worker of the same CLI runs as its lead does), else the CLI's default.
        let lead = conversation.parent.as_deref().and_then(|lead| self.get(lead)).filter(|lead| lead.provider == provider).and_then(|lead| lead.signin);
        conversation.signin = options.signin.clone().or(lead)
            .or_else(|| self.signins.choose(provider, now(), None).or_else(|| self.signins.default_for(provider)).map(|s| s.id));
        conversation.branch = branch(folder);
        // Claude takes its conversation's id from Zero, so the session can be resumed even if it never answered.
        if provider == Provider::Claude { conversation.thread = Some(claude::new_session_id()) }
        conversation.mcp = self.mcp_for(&conversation)?;
        let session = Session::new(conversation.clone(), Some(dir.clone()), self.events.clone()).map_err(|e| e.to_string())?;
        session.set_mcp(conversation.mcp.clone());
        // The workspace it starts in, kept in its history as a move into it is: restarted, it's still there (only
        // memory had it, and a restart put it back in its folder's, or Zero).
        if conversation.workspace.is_some() { session.change(Change::Placed { workspace: conversation.workspace.clone() }) }
        // The model it starts on, kept with it (Claude's thread is known already): resumed later, it starts on it again.
        if let (Some(thread), true) = (&conversation.thread, model.is_some() || effort.is_some()) {
            session.change(Change::Thread { thread: thread.clone(), model: model.map(Into::into), effort: effort.map(Into::into) });
        }
        let argv = provider.command(&conversation, false, model, effort);
        let transport = match (self.runtime)(&conversation, &dir, &argv) {
            Ok(transport) => transport,
            Err(error) => {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(format!("{} didn't start: {error}", provider.title()));
            }
        };
        self.sessions.lock().unwrap().push(session.clone());
        self.attention.lock().unwrap().insert(id.clone(), Attention::Starting);
        session.announce();
        if options.label.is_some() || options.ticket.is_some() { session.change(Change::Named { label: options.label.clone(), ticket: options.ticket.clone() }) }
        let (prompt, model, effort, images) = (prompt.to_string(), model.map(String::from), effort.map(String::from), options.images.clone());
        let (cwd, name) = (conversation.cwd.clone(), format!("{id}/{}", millis()));
        tokio::spawn(async move {
            let kept = tokio::task::spawn_blocking(move || crate::snapshots::take(Path::new(&cwd), &name)).await.ok().flatten();
            match session.start_with_images(transport, &prompt, &images, model.as_deref(), effort.as_deref()).await {
                Ok(()) => if let Some(commit) = kept { attach_snapshot(&session, commit) },
                Err(error) => session.report(&error),
            }
        });
        Ok(id)
    }

    /// A session started elsewhere (Claude Code's, by its id) taken in as a task in `cwd`: its history read from the
    /// session file, offline until a message resumes it on the same thread. The same session twice is the one task.
    pub fn adopt(&self, provider: Provider, thread: &str, cwd: &str, options: Options) -> Result<String, String> {
        if provider != Provider::Claude { return Err(format!("{} sessions can't be taken in yet", provider.title())) }
        if !Path::new(cwd).is_dir() { return Err(format!("{cwd} isn't a folder")) }
        if let Some(known) = self.sessions().iter().map(|s| s.summary()).find(|c| c.thread.as_deref() == Some(thread)) { return Ok(known.id) }
        let id = new_id();
        let mut conversation = Conversation::new(&id, provider, cwd);
        conversation.thread = Some(thread.into());
        conversation.permissions = options.permissions.unwrap_or_default();
        conversation.branch = branch(Path::new(cwd));
        let text = std::fs::read_to_string(self.claude_file(&conversation)).map_err(|_| format!("No Claude Code session {thread} in {cwd}"))?;
        let records: Vec<serde_json::Value> = text.lines().filter_map(|line| serde_json::from_str(line).ok()).collect();
        let session = Session::new(conversation, Some(self.home.join("sessions").join(&id)), self.events.clone()).map_err(|e| e.to_string())?;
        session.change(Change::Status { status: Status::Offline, turn: None, error: None });
        for item in crate::handoff::from_claude_session(&records) { session.change(Change::Item { item }) }
        if options.label.is_some() || options.ticket.is_some() { session.change(Change::Named { label: options.label, ticket: options.ticket }) }
        self.attention.lock().unwrap().insert(id.clone(), Attention::Offline);
        self.sessions.lock().unwrap().push(session.clone());
        session.announce();
        Ok(id)
    }

    /// `target` made a worker of `lead`: a task Zero has (by its id, or its Claude Code session's), else a Claude Code
    /// session taken in first, found by its id in any folder. Not the lead itself, nor anything above it.
    pub fn adopt_into(&self, lead: &str, target: &str) -> Result<String, String> {
        let mut above = Some(self.session(lead)?.summary());
        let known = self.sessions().iter().map(|s| s.summary()).find(|c| c.id == target || c.thread.as_deref() == Some(target)).map(|c| c.id);
        let id = match known {
            Some(id) => id,
            None => {
                let file = std::fs::read_dir(self.user_home().join(".claude/projects")).map_err(|e| e.to_string())?
                    .filter_map(|e| e.ok().map(|e| e.path().join(format!("{target}.jsonl")))).find(|f| f.is_file())
                    .ok_or_else(|| format!("No task or Claude Code session {target}"))?;
                let cwd = claude_cwd(&file).ok_or_else(|| format!("Claude Code session {target} doesn't say its folder"))?;
                self.adopt(Provider::Claude, target, &cwd, Options::default())?
            }
        };
        while let Some(conversation) = above {
            if conversation.id == id { return Err(format!("{id} leads {lead}; it can't be its worker")) }
            above = conversation.parent.and_then(|parent| self.session(&parent).ok()).map(|s| s.summary());
        }
        self.session(&id)?.change(Change::Parent { parent: Some(lead.into()) });
        Ok(id)
    }

    /// Puts a task away with the workers it still has: stopped, out of the list, their files moved to archive/. Each
    /// worker is marked as gone with it, so unarchiving the task brings back those and no others (one put away on its
    /// own before stays put away).
    pub async fn archive(&self, id: &str) -> Result<(), String> {
        let root = self.session(id)?.summary();
        let mut team = vec![];
        let mut i = 0;
        let mut leads = vec![id.to_string()];
        while i < leads.len() {
            let lead = leads[i].clone();
            for member in self.list().into_iter().filter(|c| c.parent.as_deref() == Some(lead.as_str())) {
                leads.push(member.id.clone());
                team.push(member.id);
            }
            i += 1;
        }
        for member in team.iter().rev() { self.archive_one(member, Some(id)).await? }
        let workspace = self.workspace_of(&root);
        self.archive_one(id, None).await?;
        let _ = std::fs::write(self.home.join("archive").join(id).join(ARCHIVED), serde_json::to_vec(&serde_json::json!({
            "with": null, "at": archived_at(), "task": crate::bridge::label(&root), "workspace": workspace, "workers": team.len(),
        })).unwrap_or_default());
        Ok(())
    }

    async fn archive_one(&self, id: &str, with: Option<&str>) -> Result<(), String> {
        let session = self.session(id)?;
        if session.summary().terminal.is_some() { self.close_terminal(id).await? }
        self.take_offline(&session).await;
        let seq = session.summary().seq;
        self.sessions.lock().unwrap().retain(|s| s.id() != id);
        self.attention.lock().unwrap().remove(id);
        self.pending.lock().unwrap().remove(id);
        self.held.lock().unwrap().remove(id);
        drop(session);
        let archive = self.home.join("archive");
        std::fs::create_dir_all(&archive).map_err(|e| e.to_string())?;
        std::fs::rename(self.home.join("sessions").join(id), archive.join(id)).map_err(|e| e.to_string())?;
        if let Some(with) = with {
            let _ = std::fs::write(archive.join(id).join(ARCHIVED), serde_json::to_vec(&serde_json::json!({"with": with, "at": archived_at()})).unwrap_or_default());
        }
        let _ = self.events.send(Event { session: id.into(), seq: seq + 1, change: Change::Archived });
        Ok(())
    }

    /// Brings a task back from the archive, and the workers that went with it: offline, as they were, under it.
    pub fn unarchive(&self, id: &str) -> Result<Vec<String>, String> {
        let archive = self.home.join("archive");
        if !archive.join(id).join("meta.json").exists() { return Err(format!("Nothing archived as {id}")) }
        if self.session(id).is_ok() { return Err(format!("{id} isn't archived")) }
        let with: Vec<String> = std::fs::read_dir(&archive).into_iter().flatten().flatten()
            .filter(|entry| archived_with(&entry.path()).as_deref() == Some(id))
            .map(|entry| entry.file_name().to_string_lossy().to_string()).collect();
        let mut back = vec![];
        for member in std::iter::once(id.to_string()).chain(with) {
            let (from, to) = (archive.join(&member), self.home.join("sessions").join(&member));
            std::fs::rename(&from, &to).map_err(|e| e.to_string())?;
            let _ = std::fs::remove_file(to.join(ARCHIVED));
            let _ = std::fs::remove_file(to.join(HELD)); // held again below if it still has words waiting
            let session = Session::load(&to, self.events.clone()).map_err(|e| e.to_string())?;
            self.sessions.lock().unwrap().push(session);
            // What it was waiting to say comes back held: put away a while, it goes on only when the user says so.
            let words = kept_pending(&to);
            if !words.is_empty() {
                self.pending.lock().unwrap().insert(member.clone(), words);
                self.hold(&member, true);
            }
            back.push(member);
        }
        let _ = self.queues.send(());
        // The board and the apps hear of it: the task's back, its workers under it.
        if let Ok(session) = self.session(id) { session.announce() }
        Ok(back)
    }

    /// What's archived that was put away itself (not with its lead), newest first: its name, when, its workspace and
    /// how many workers went with it.
    pub fn archived(&self, limit: usize) -> Vec<serde_json::Value> {
        let archive = self.home.join("archive");
        let mut entries: Vec<(std::path::PathBuf, i64)> = std::fs::read_dir(&archive).into_iter().flatten().flatten()
            .map(|e| e.path()).filter(|p| p.join("meta.json").exists() && archived_with(p).is_none())
            .map(|p| { let at = marker(&p).and_then(|m| m["at"].as_i64()).unwrap_or_else(|| modified_ms(&p)); (p, at) }).collect();
        entries.sort_by_key(|(_, at)| std::cmp::Reverse(*at));
        let counts = archived_counts(&archive);
        entries.into_iter().take(limit).map(|(path, at)| {
            let id = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            let kept = marker(&path);
            let task = kept.as_ref().and_then(|m| m["task"].as_str().map(String::from)).or_else(|| parked_label(&path)).unwrap_or_else(|| id.clone());
            serde_json::json!({"id": id, "task": task, "at": at, "workspace": kept.as_ref().and_then(|m| m["workspace"].as_str().map(String::from)),
                               "workers": counts.get(&id).copied().unwrap_or(0),
                               "parent": std::fs::read(path.join("meta.json")).ok().and_then(|d| serde_json::from_slice::<serde_json::Value>(&d).ok()).and_then(|m| m["parent"].as_str().map(String::from))})
        }).collect()
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

    /// Hands the task to its provider's own terminal, on its own thread: Zero's headless process stops first, so only
    /// one of them ever writes to the thread. Watched until its program ends, which brings the task back.
    pub async fn open_terminal(&self, id: &str) -> Result<String, String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        if let Some(open) = &conversation.terminal { return Ok(open.id.clone()) }
        if matches!(conversation.status, Status::Working | Status::Waiting) {
            return Err(format!("{} is working; stop its turn first", conversation.provider.title()));
        }
        let argv = conversation.provider.terminal(&conversation)?;
        self.take_offline(&session).await;
        let mark = match conversation.provider {
            Provider::Claude => std::fs::read_to_string(self.claude_file(&conversation)).map(|text| text.lines().count()).unwrap_or(0),
            _ => 0,
        };
        let terminal = self.host().open(&conversation.cwd, &argv, &crate::bridge::label(&conversation)).await?;
        session.change(Change::Terminal { terminal: Some(Opened { id: terminal.clone(), mark }) });
        let (weak, task, watched) = (self.me.clone(), id.to_string(), terminal.clone());
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(2)).await;
                let Some(daemon) = weak.upgrade() else { return };
                if daemon.get(&task).and_then(|c| c.terminal).map(|t| t.id) != Some(watched.clone()) { return }
                if matches!(crate::terminal::Terminal::state(&daemon.host(), &watched).await, crate::terminal::State::Exited | crate::terminal::State::Missing) {
                    if let Err(error) = daemon.close_terminal(&task).await { eprintln!("zerod: {task} came back from its terminal badly: {error}") }
                    return;
                }
            }
        });
        Ok(terminal)
    }

    /// Back from the provider's terminal: it closes, what happened there joins the task's record, and Zero's UI has the
    /// task again (the next message resumes the provider headless on the same thread).
    pub async fn close_terminal(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        let Some(open) = conversation.terminal.clone() else { return Ok(()) };
        self.host().shut(&open.id).await;
        session.change(Change::Terminal { terminal: None });
        match conversation.provider {
            Provider::Claude => {
                let text = std::fs::read_to_string(self.claude_file(&conversation)).unwrap_or_default();
                let records: Vec<serde_json::Value> = text.lines().skip(open.mark).filter_map(|line| serde_json::from_str(line).ok()).collect();
                for item in crate::handoff::from_claude_session(&records) { session.change(Change::Item { item }) }
            }
            Provider::Codex => {
                // Codex lets go of the thread once its terminal's program has exited, a moment after it's told to.
                // ponytail: two more tries over about 4 s; zero-host saying when the program is gone would make it exact.
                tokio::time::sleep(Duration::from_secs(1)).await;
                let mut tries = 0;
                loop {
                    match self.resume(id).await {
                        Err(error) if error.contains("active writer") && tries < 2 => { tries += 1; tokio::time::sleep(Duration::from_secs(2)).await }
                        resumed => break resumed?,
                    }
                }
                crate::codex::catch_up(&session).await?;
            }
            // ponytail: OpenCode's terminal turns stay in OpenCode until its session export is read back.
            Provider::Opencode => {}
        }
        Ok(())
    }

    fn claude_file(&self, conversation: &Conversation) -> PathBuf {
        crate::handoff::claude_folder(&self.user_home(), &conversation.cwd).join(format!("{}.jsonl", conversation.thread.as_deref().unwrap_or("")))
    }

    /// Stops the session's process, if it has one, and waits for it to be gone.
    async fn take_offline(&self, session: &Session) {
        if !session.is_attached() { return }
        session.stop();
        for _ in 0..100 {
            if session.summary().status == Status::Offline { break }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// Arsen's words to a session, resuming it first if it is offline.
    pub async fn send(&self, id: &str, text: &str, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        self.send_with_images(id, text, &[], model, effort).await
    }

    /// Words with images (their files).
    pub async fn send_with_images(&self, id: &str, text: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        let session = self.session(id)?;
        if let Some(conversation) = self.get(id) && conversation.terminal.is_some() {
            return Err(format!("{} is open in its terminal; type there, or go back to Zero", conversation.provider.title()));
        }
        // Writing to a paused task resumes it.
        if self.is_paused(id) { self.unpause(&[id.to_string()]).await; }
        // OpenCode takes one message at a time: one sent mid-turn waits for the turn's end, as Return does while it
        // works, rather than being refused (and lost from the box it was written in).
        if session.is_attached() && let Some(now) = self.get(id) && now.provider == Provider::Opencode && now.turn.is_some() {
            return self.queue(id, text, images).map(|_| ());
        }
        // The folder as it is before the agent reads the message: what rewinding to it brings back.
        let kept = self.keep_folder(&session).await;
        let conversation = session.snapshot();
        if !session.is_attached() && conversation.thread.is_none() && (conversation.items.is_empty() || conversation.provider == Provider::Opencode) {
            self.restart(&session, text, images, model, effort).await?;
        } else {
            if !session.is_attached() { self.resume(id).await? }
            session.send_with_images(text, images, model, effort).await?;
        }
        if let Some(commit) = kept { attach_snapshot(&session, commit) }
        Ok(())
    }

    /// The task's folder kept as it is now (snapshots.rs), off the async threads: git reads the whole folder.
    async fn keep_folder(&self, session: &Session) -> Option<String> {
        let (cwd, name) = (session.summary().cwd, format!("{}/{}", session.id(), millis()));
        tokio::task::spawn_blocking(move || crate::snapshots::take(Path::new(&cwd), &name)).await.ok().flatten()
    }

    /// A new thread for a conversation that has none: rewound to its first message, or (OpenCode, which can't be
    /// handed a conversation) rewound anywhere, the earlier conversation then going with the message as context.
    async fn restart(&self, session: &Session, text: &str, images: &[String], model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        let mut conversation = session.snapshot();
        let context = (conversation.provider == Provider::Opencode && !conversation.items.is_empty()).then(|| crate::handoff::context(&conversation));
        if conversation.provider == Provider::Claude {
            let thread = claude::new_session_id();
            session.change(Change::Thread { thread: thread.clone(), model: None, effort: None });
            conversation.thread = Some(thread);
        }
        let (model, effort) = (model.or(conversation.model.as_deref()).map(String::from), effort.or(conversation.effort.as_deref()).map(String::from));
        conversation.mcp = self.mcp_for(&conversation)?;
        session.set_mcp(conversation.mcp.clone());
        let argv = conversation.provider.command(&conversation, false, model.as_deref(), effort.as_deref());
        let transport = (self.runtime)(&conversation, &self.home.join("sessions").join(&conversation.id), &argv)
            .map_err(|e| format!("{} didn't start: {e}", conversation.provider.title()))?;
        session.restart(transport, context.as_deref(), text, images, model.as_deref(), effort.as_deref()).await
    }

    /// One at a time per session: a second resume (the app warming it as the user types, their message arriving)
    /// waits for the first and finds its agent running, rather than starting another.
    pub async fn resume(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        let lock = self.resuming.lock().unwrap().entry(id.to_string()).or_default().clone();
        let _one = lock.lock().await;
        if session.is_attached() { return Ok(()) }
        let mut conversation = session.snapshot();
        // Its workspace's servers as they are now: one moved since, or a server added, applies from this start.
        conversation.mcp = self.mcp_for(&conversation)?;
        session.set_mcp(conversation.mcp.clone());
        let argv = conversation.provider.command(&conversation, true, conversation.model.as_deref(), conversation.effort.as_deref());
        let transport = (self.runtime)(&conversation, &self.home.join("sessions").join(id), &argv)
            .map_err(|e| format!("{} didn't start: {e}", conversation.provider.title()))?;
        let resumed = session.resume(transport).await;
        // A process that didn't get the thread lets go of it; it would otherwise hold it from whoever does.
        if resumed.is_err() { self.take_offline(&session).await }
        resumed
    }

    /// Moves a task to another provider between turns. Its conversation stays Zero's; the next message starts the new
    /// provider on it (handoff.rs): Claude Code resumes it as one of its own session files, Codex imports that file.
    pub async fn switch(&self, id: &str, provider: Provider, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        if provider == conversation.provider { return session.set_model(model, effort).await }
        if provider == Provider::Opencode { return Err(format!("Zero can't hand a task to {} yet", provider.title())) }
        if matches!(conversation.status, Status::Working | Status::Waiting) {
            return Err(format!("{} is working; stop its turn first", conversation.provider.title()));
        }
        if conversation.terminal.is_some() { return Err(format!("{} is open in its terminal; go back to Zero first", conversation.provider.title())) }
        self.take_offline(&session).await;
        session.change(Change::Switched { provider, model: model.map(Into::into), effort: effort.map(Into::into) });
        self.rethread(&session)
    }

    /// Changes what the task's agent may do without asking, between turns: its process is stopped, and the next message
    /// resumes its thread started with the new permissions.
    pub async fn set_permissions(&self, id: &str, permissions: crate::model::Permissions) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        if conversation.permissions == permissions { return Ok(()) }
        if matches!(conversation.status, Status::Working | Status::Waiting | Status::Starting) {
            return Err(format!("{} is working; change its permissions once its turn ends", conversation.provider.title()));
        }
        if conversation.terminal.is_some() { return Err(format!("{} is open in its terminal; go back to Zero first", conversation.provider.title())) }
        self.take_offline(&session).await;
        session.change(Change::Permitted { permissions });
        Ok(())
    }

    /// The provider given a thread made from Zero's record (handoff.rs): Claude Code a session file of its own; Codex,
    /// with no thread, imports the record when it next resumes; OpenCode, with none, starts afresh with it as context.
    fn rethread(&self, session: &Session) -> Result<(), String> {
        let conversation = session.snapshot();
        if conversation.provider != Provider::Claude || conversation.items.is_empty() { return Ok(()) }
        let thread = claude::new_session_id();
        let folder = crate::handoff::claude_folder(&self.user_home(), &conversation.cwd);
        std::fs::create_dir_all(&folder).and_then(|_| std::fs::write(folder.join(format!("{thread}.jsonl")), crate::handoff::claude_session(&conversation, &thread)))
            .map_err(|e| format!("Couldn't write the conversation for Claude Code: {e}"))?;
        session.change(Change::Thread { thread, model: None, effort: None });
        Ok(())
    }

    // Going back to a message of yours.

    /// The folder kept now and noted as how it was when `item` went (what sending does before each message).
    pub fn snapshot_for(&self, id: &str, item: &str) -> Option<String> {
        let session = self.session(id).ok()?;
        let commit = crate::snapshots::take(Path::new(&session.summary().cwd), &format!("{id}/{}", millis()))?;
        session.change(Change::Snapshot { item: item.into(), commit: commit.clone() });
        Some(commit)
    }

    /// What going back to `item` would do to the folder: whether it was kept then, and what changed in it since.
    pub fn rewind_preview(&self, id: &str, item: &str) -> Result<serde_json::Value, String> {
        let conversation = self.session(id)?.snapshot();
        yours(&conversation, item)?;
        let since = conversation.snapshots.get(item).and_then(|commit| crate::snapshots::preview(Path::new(&conversation.cwd), commit));
        Ok(match since {
            Some(diff) => serde_json::json!({"snapshot": true, "files": diff.files, "insertions": diff.insertions, "deletions": diff.deletions}),
            None => serde_json::json!({"snapshot": false}),
        })
    }

    /// Back to just before `item`, a message of yours: the conversation (its provider going on from Zero's record up to
    /// there), the folder as it was when the message went, or both. Gives the message back, to send again or change.
    pub async fn rewind(&self, id: &str, item: &str, conversation: bool, code: bool) -> Result<serde_json::Value, String> {
        let session = self.session(id)?;
        let current = session.snapshot();
        let (_, text, images) = yours(&current, item)?;
        if current.terminal.is_some() { return Err(format!("{} is open in its terminal; go back to Zero first", current.provider.title())) }
        if matches!(current.status, Status::Working | Status::Waiting) { return Err(format!("{} is working; stop its turn first", current.provider.title())) }
        let mut restored = serde_json::Value::Null;
        if code {
            let commit = current.snapshots.get(item).cloned().ok_or("Zero didn't keep the folder for that message, so its code can't be brought back")?;
            let (cwd, point) = (current.cwd.clone(), format!("{id}/restore-{}", millis()));
            let diff = tokio::task::spawn_blocking(move || crate::snapshots::restore(Path::new(&cwd), &commit, &point)).await.map_err(|e| e.to_string())??;
            restored = serde_json::json!(diff);
        }
        if conversation {
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
        let session = Session::new(conversation, Some(self.home.join("sessions").join(&branch)), self.events.clone()).map_err(|e| e.to_string())?;
        session.change(Change::Status { status: Status::Offline, turn: None, error: None });
        for kept in &original.items[..at] { session.change(Change::Item { item: kept.clone() }) }
        for kept in &original.items[..at] {
            if let Some(commit) = original.snapshots.get(&kept.id) { session.change(Change::Snapshot { item: kept.id.clone(), commit: commit.clone() }) }
        }
        session.change(Change::Named { label: Some(format!("{} (branch)", crate::bridge::label(&original))), ticket: original.ticket.clone() });
        self.rethread(&session)?;
        self.attention.lock().unwrap().insert(branch.clone(), Attention::Offline);
        self.sessions.lock().unwrap().push(session.clone());
        session.announce();
        Ok(serde_json::json!({"session": branch, "text": text, "images": images}))
    }

    /// Stops the turn. What's queued for the session is held: the user stopped it, so nothing of theirs goes on
    /// until they say (queueing again, or releasing).
    pub async fn interrupt(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        if !self.queued(id).0.is_empty() { self.hold(id, true); let _ = self.queues.send(()); }
        session.interrupt().await
    }

    pub async fn decide(&self, id: &str, approval: &str, choice: &str) -> Result<(), String> {
        self.session(id)?.decide(approval, choice).await
    }

    pub async fn answer(&self, id: &str, question: &str, answers: &crate::adapter::Answers) -> Result<(), String> {
        self.session(id)?.answer(question, answers).await
    }

    /// Something its agent says about the task, by name (`zero attr PR <link>`); no value takes it back.
    pub fn set_attribute(&self, id: &str, name: &str, value: Option<&str>) -> Result<(), String> {
        let name = name.trim();
        if name.is_empty() { return Err("An attribute needs a name".into()) }
        let value = value.map(str::trim).filter(|v| !v.is_empty()).map(String::from);
        self.session(id)?.change(Change::Attribute { name: name.into(), value });
        Ok(())
    }

    /// Names a session and says what it's for.
    /// What a session's CLI starts with: its sign-in (signins.rs) and its workspace's MCP servers, their values read
    /// (the Keychain's now). Both go in its process's environment alone: the sign-in as its CLI reads one, Claude's
    /// MCP values for its `--mcp-config` to refer to. A sign-in gone from the Keychain stops the start, said.
    fn mcp_for(&self, conversation: &Conversation) -> Result<Vec<crate::mcp_servers::Resolved>, String> {
        let workspace = self.workspace_of(conversation);
        let mut servers: Vec<_> = self.mcp_servers.for_workspace(&workspace).iter().map(|s| s.resolve(&crate::mcp_servers::keychain)).collect();
        // Zero's own tools (scratchpads, the browser: `zerod mcp`), for the CLIs that don't have them from Zero's plugin
        // as Claude Code does. Told which task it serves; Codex gives a server only the variables it's given.
        if conversation.provider != Provider::Claude && let Ok(zerod) = std::env::current_exe() {
            servers.insert(0, crate::mcp_servers::Resolved { id: "zero".into(), name: "Zero".into(), command: Some(zerod.to_string_lossy().into()),
                args: vec!["mcp".into()], url: None, env: vec![("ZERO_SESSION".into(), conversation.id.clone())], headers: vec![] });
        }
        let mut env = match conversation.signin.as_deref().and_then(|id| self.signins.get(id)) {
            Some(signin) => self.signins.environment(&signin)?,
            None => vec![],
        };
        if conversation.provider == Provider::Claude { env.extend(claude::mcp_config(&servers).map(|(_, env)| env).unwrap_or_default()) }
        let mut all = crate::process::SESSION_ENV.lock().unwrap();
        if env.is_empty() { all.remove(&conversation.id); } else { all.insert(conversation.id.clone(), env); }
        Ok(servers)
    }

    /// Which workspace a conversation is in: the one it was put in, else its folder's, else Zero.
    pub fn workspace_of(&self, conversation: &Conversation) -> String { self.workspaces.of(conversation.workspace.as_deref(), &conversation.cwd) }

    /// Puts a session in a workspace (none: back to its folder's).
    pub fn place_in_workspace(&self, id: &str, workspace: Option<&str>) -> Result<(), String> {
        if let Some(workspace) = workspace && !self.workspaces.exists(workspace) { return Err(format!("No workspace {workspace}")) }
        self.session(id)?.change(Change::Placed { workspace: workspace.map(Into::into) });
        Ok(())
    }

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

    /// Words for a session from anywhere (an event source, a script, the user): given when it is between turns, kept
    /// on disk while it is offline.
    pub fn notify(&self, id: &str, text: &str) -> Result<(), String> { self.notify_from(id, "zero", text) }

    /// Words from another task (`zero send` inside one), marked as its, as a worker's report is.
    pub fn notify_from(&self, id: &str, from: &str, text: &str) -> Result<(), String> {
        self.session(id)?;
        self.tell(id, crate::model::from_line(from, text));
        Ok(())
    }

    /// Runs `command` in the session's folder and, when it ends, tells the session how: "wake me when CI finishes"
    /// without a polling loop.
    pub fn watch(&self, id: &str, command: &str) -> Result<(), String> {
        let cwd = PathBuf::from(self.get(id).ok_or_else(|| format!("No session {id}"))?.cwd);
        let (me, id, command) = (self.me.clone(), id.to_string(), command.to_string());
        tokio::spawn(async move {
            let (code, printed) = process::run(&command, &cwd, &id).await;
            let how = code.map(|c| format!("with exit {c}")).unwrap_or_else(|| "when it was stopped".into());
            let words = if printed.is_empty() { format!("`{command}` finished {how} and printed nothing.") } else { format!("`{command}` finished {how}:\n{printed}") };
            if let Some(daemon) = me.upgrade() { daemon.tell(&id, crate::model::from_line("zero", &words)) }
        });
        Ok(())
    }

    /// Zero's word for a session, between its turns (a parked one resumed for it), shown as Zero's, not the user's.
    pub fn tell_from_zero(&self, id: &str, words: &str) {
        if self.session(id).is_ok() { self.tell(id, crate::model::from_line("zero", words)) }
    }

    /// Watches `file` for `session` from now on (watches.rs): lines with any of `alerts` told with what led up to them,
    /// at most one alert a minute; the file not growing for `quiet` minutes told once; a line with `done` told, and
    /// the watch ended. Its id.
    pub fn watch_file(&self, session: &str, file: &Path, alerts: Vec<String>, done: Option<String>, quiet: Option<u64>) -> Result<String, String> {
        self.session(session)?;
        let offset = std::fs::metadata(file).map_err(|e| format!("Can't watch {}: {e}", file.display()))?.len();
        let alerts: Vec<String> = alerts.into_iter().filter(|a| !a.is_empty()).collect();
        if alerts.is_empty() && done.is_none() && quiet.is_none() { return Err("Watch it for what? --alert TEXT, --until TEXT or --quiet MINUTES".into()) }
        if let Some(short) = alerts.iter().chain(done.iter()).find(|text| text.trim().chars().count() < 3) {
            return Err(format!("`{short}` is in almost every line: watch for text only that line has"));
        }
        let watch = crate::watches::Watch { id: crate::ask::new_id(), session: session.into(), file: file.into(), alerts, done, quiet, offset };
        crate::watches::Reading::new(&watch)?;
        let id = watch.id.clone();
        self.watches.lock().unwrap().insert(id.clone(), watch);
        self.keep_watches();
        self.follow_file(id.clone());
        Ok(id)
    }

    /// The watches, of `session` or everyone's.
    pub fn watches(&self, session: Option<&str>) -> Vec<crate::watches::Watch> {
        let mut all: Vec<_> = self.watches.lock().unwrap().values().filter(|w| session.is_none_or(|s| w.session == s)).cloned().collect();
        all.sort_by(|a, b| a.id.cmp(&b.id));
        all
    }

    pub fn unwatch(&self, id: &str) -> Result<(), String> {
        self.watches.lock().unwrap().remove(id).ok_or_else(|| format!("No watch {id}"))?;
        self.keep_watches();
        Ok(())
    }

    fn keep_watches(&self) {
        let all: Vec<_> = self.watches.lock().unwrap().values().cloned().collect();
        crate::watches::keep(&self.home, &all);
    }

    /// Reads a watch's file as it grows, until the watch is stopped or its file says it's done.
    fn follow_file(&self, id: String) {
        let me = self.me.clone();
        tokio::spawn(async move {
            use std::io::{Read, Seek};
            let Some(first) = me.upgrade().and_then(|daemon| daemon.watches.lock().unwrap().get(&id).cloned()) else { return };
            let Ok(mut reading) = crate::watches::Reading::new(&first) else { return };
            let mut alerted = std::time::Instant::now().checked_sub(crate::watches::COOL_DOWN).unwrap_or_else(std::time::Instant::now);
            let (mut grew, mut said_quiet, mut kept) = (std::time::Instant::now(), false, std::time::Instant::now());
            loop {
                tokio::time::sleep(crate::watches::poll()).await;
                let Some(daemon) = me.upgrade() else { return };
                let Some(mut watch) = daemon.watches.lock().unwrap().get(&id).cloned() else { return };
                // Its task archived: nobody to tell.
                if daemon.session(&watch.session).is_err() { let _ = daemon.unwatch(&id); return }
                let length = std::fs::metadata(&watch.file).map(|m| m.len()).unwrap_or(watch.offset);
                // Started again (truncated or replaced): from its top.
                if length < watch.offset { watch.offset = 0 }
                if length > watch.offset {
                    let mut bytes = vec![];
                    if let Ok(mut file) = std::fs::File::open(&watch.file) && file.seek(std::io::SeekFrom::Start(watch.offset)).is_ok() {
                        let _ = file.take(crate::watches::CHUNK).read_to_end(&mut bytes);
                    }
                    watch.offset += bytes.len() as u64;
                    reading.read(&watch, &String::from_utf8_lossy(&bytes));
                    (grew, said_quiet) = (std::time::Instant::now(), false);
                    if let Some(kept_watch) = daemon.watches.lock().unwrap().get_mut(&id) { kept_watch.offset = watch.offset }
                    if kept.elapsed() > Duration::from_secs(30) { daemon.keep_watches(); kept = std::time::Instant::now() }
                }
                if !reading.hits.is_empty() && alerted.elapsed() >= crate::watches::COOL_DOWN {
                    let hits = std::mem::take(&mut reading.hits);
                    daemon.tell(&watch.session, crate::model::from_line("zero", &watch.alert(&hits, reading.latest.as_deref())));
                    alerted = std::time::Instant::now();
                }
                if let Some(line) = reading.done.take() {
                    daemon.tell(&watch.session, crate::model::from_line("zero", &watch.finished(&line)));
                    let _ = daemon.unwatch(&id);
                    return;
                }
                if let Some(minutes) = watch.quiet && !said_quiet && grew.elapsed() >= Duration::from_secs(minutes * 60) {
                    daemon.tell(&watch.session, crate::model::from_line("zero", &watch.quieted(reading.latest.as_deref())));
                    said_quiet = true;
                }
            }
        });
    }

    /// Tells the session `text` after `after`. ponytail: held in memory, so a daemon restart forgets it; keep it on disk
    /// beside pending.json if reminders start spanning restarts.
    pub fn remind(&self, id: &str, after: Duration, text: &str) -> Result<(), String> {
        self.schedule(id, now() + after.as_secs() as i64, text).map(|_| ())
    }

    /// Wakes `id` at `at` (seconds since 1970) with `text`: kept on disk, told as Zero's word when due.
    pub fn schedule(&self, id: &str, at: i64, text: &str) -> Result<crate::schedules::Schedule, String> {
        self.session(id)?;
        let text = text.trim();
        if text.is_empty() { return Err("Schedule it with what for: the words to hear then".into()) }
        let schedule = crate::schedules::Schedule { id: new_id(), session: id.into(), at, text: text.into() };
        self.schedules.lock().unwrap().push(schedule.clone());
        self.keep_schedules();
        self.arm(schedule.clone());
        Ok(schedule)
    }

    /// The wakes scheduled, soonest first: `session`'s, or everyone's.
    pub fn schedules(&self, session: Option<&str>) -> Vec<crate::schedules::Schedule> {
        let mut list: Vec<_> = self.schedules.lock().unwrap().iter().filter(|s| session.is_none_or(|id| s.session == id)).cloned().collect();
        list.sort_by_key(|s| s.at);
        list
    }

    pub fn unschedule(&self, schedule: &str) -> Result<(), String> {
        let mut list = self.schedules.lock().unwrap();
        let before = list.len();
        list.retain(|s| s.id != schedule);
        if list.len() == before { return Err(format!("Nothing is scheduled as {schedule}")) }
        drop(list);
        self.keep_schedules();
        Ok(())
    }

    /// When `id` next wakes, for its board row.
    pub fn next_wake(&self, id: &str) -> Option<i64> { self.schedules.lock().unwrap().iter().filter(|s| s.session == id).map(|s| s.at).min() }

    fn keep_schedules(&self) { crate::schedules::keep(&self.home, &self.schedules.lock().unwrap()) }

    /// Told when due, if it's still scheduled then (not taken back); once.
    fn arm(&self, schedule: crate::schedules::Schedule) {
        let me = self.me.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs((schedule.at - now()).max(0) as u64)).await;
            let Some(daemon) = me.upgrade() else { return };
            let still = { let mut list = daemon.schedules.lock().unwrap(); let before = list.len(); list.retain(|s| s.id != schedule.id); list.len() < before };
            if !still { return }
            daemon.keep_schedules();
            daemon.tell_from_zero(&schedule.session, &schedule.told(now()));
        });
    }

    /// Each provider's limits as its CLI last reported them, from the session that heard last.
    pub fn usage(&self) -> Vec<(Provider, crate::model::Usage)> {
        let mut latest: Vec<(Provider, crate::model::Usage)> = vec![];
        for conversation in self.sessions().iter().map(|s| s.summary()) {
            let Some(usage) = conversation.usage else { continue };
            latest.retain(|(p, _)| *p != conversation.provider);
            latest.push((conversation.provider, usage));
        }
        latest
    }

    /// A session stopped by a usage limit is told to go on once the limit has reset.
    /// At its account's usage limit: carried on as another of its CLI's accounts, the one the policy picks
    /// (signins.rs choose), its agent started again on the same conversation. False when there's none to go to.
    fn switch_account(&self, conversation: &Conversation) -> bool {
        if conversation.usage.as_ref().is_none_or(|u| !u.limited) { return false }
        let Some(next) = self.signins.choose(conversation.provider, now(), conversation.signin.as_deref()) else { return false };
        let Ok(session) = self.session(&conversation.id) else { return false };
        session.change(Change::SignedIn { signin: Some(next.id.clone()) });
        // The limit was the last account's: this one starts clear.
        session.change(Change::Usage { usage: crate::model::Usage { limited: false, resets_at: None, windows: vec![] } });
        // As is the error that said so (the failure is worked out from it).
        session.change(Change::Status { status: conversation.status, turn: conversation.turn.clone(), error: None });
        session.change(Change::Failed { failure: None });
        let (me, id) = (self.me.clone(), conversation.id.clone());
        tokio::spawn(async move {
            let Some(daemon) = me.upgrade() else { return };
            if let Ok(session) = daemon.session(&id) { daemon.take_offline(&session).await }
            daemon.tell(&id, crate::model::from_line("zero", "Your account reached its usage limit, so Zero carries this task on as another account: carry on with what you were doing."));
        });
        true
    }

    fn after_reset(&self, conversation: &Conversation) {
        let Some(usage) = conversation.usage.clone().filter(|u| u.limited) else { return };
        let Some(at) = usage.resets_at else { return };
        if self.resets.lock().unwrap().insert(conversation.id.clone(), at) == Some(at) { return }
        let (me, id) = (self.me.clone(), conversation.id.clone());
        let wait = Duration::from_secs((at - now()).max(0) as u64 + 60);
        tokio::spawn(async move {
            tokio::time::sleep(wait).await;
            let Some(daemon) = me.upgrade() else { return };
            let Ok(session) = daemon.session(&id) else { return };
            // The provider says nothing when a limit resets; the clock does.
            session.change(Change::Usage { usage: crate::model::Usage { limited: false, resets_at: None, ..usage } });
            daemon.tell(&id, crate::model::from_line("zero", "The usage limit has reset: carry on with what you were doing."));
        });
    }

    /// Something changed in `id`: a worker that has come to an end (or just got stuck) tells its lead, and a session
    /// between turns gets the word waiting for it. The session is read as it is now, which may be several events on
    /// from the one heard, so a worker can seem to go straight from waiting on the user to done: anything still under
    /// way counts as before, anything ended as now.
    fn heard(&self, id: &str) {
        let Some(conversation) = self.get(id) else { return };
        let now = conversation.attention();
        let before = self.attention.lock().unwrap().insert(id.into(), now);
        let under_way = |a: Attention| matches!(a, Attention::Starting | Attention::Working | Attention::NeedsYou | Attention::Stuck);
        let ended = matches!(now, Attention::Done | Attention::Answered | Attention::Blocked | Attention::Failed | Attention::Limited | Attention::Offline | Attention::Idle);
        let came_to_an_end = before.is_some_and(under_way) && ended;
        if came_to_an_end { self.carry_read(&conversation) }
        let got_stuck = now == Attention::Stuck && before != Some(Attention::Stuck);
        // While zerod restarts, a turn ending is the pause for it: the new zerod carries it on, so its lead hears nothing.
        let restarting = self.restarting.load(Ordering::Relaxed);
        // Nor while it's paused by the user: its turn ending is the pause.
        if let Some(lead) = &conversation.parent && (came_to_an_end || got_stuck) && !restarting && !self.is_paused(id) {
            self.tell(lead, crate::model::from_line(&conversation.id, &report(&conversation, now)));
        }
        // What its CLI says of its account's usage is the account's, for choosing accounts by.
        if let (Some(signin), Some(usage)) = (&conversation.signin, &conversation.usage) { self.signins.record_usage(signin, usage) }
        if now == Attention::Limited && !self.switch_account(&conversation) { self.after_reset(&conversation) }
        if between_turns(&conversation) { self.deliver(id) }
    }

    /// Keeps `words` for `id` until it can take them; a parked (offline) session is resumed for them, and they go
    /// once it's between turns.
    fn tell(&self, id: &str, words: String) {
        self.pending.lock().unwrap().entry(id.into()).or_default().push(Queued { id: new_id(), text: words, images: vec![], report: true });
        self.keep_pending(id);
        if self.is_paused(id) { return }
        let Ok(session) = self.session(id) else { return };
        if !session.is_attached() && session.summary().terminal.is_none() {
            let (Some(daemon), id) = (self.me.upgrade(), id.to_string()) else { return };
            tokio::spawn(async move { if let Err(error) = daemon.resume(&id).await { eprintln!("zerod: couldn't resume {id} for its words: {error}") } });
        } else if between_turns(&session.summary()) {
            self.deliver(id)
        }
    }

    /// Before zerod becomes a new build: every turn under way is paused between steps (a command running is left to
    /// finish, up to COMMAND_WAIT), its session told to carry on once the new zerod is up. All at once, so one long
    /// command holds up only its own turn. Gives the sessions paused.
    pub async fn pause_for_restart(&self) -> Vec<String> {
        self.restarting.store(true, Ordering::Relaxed);
        let mut pausing = tokio::task::JoinSet::new();
        for session in self.sessions() {
            let conversation = session.summary();
            // Only a turn with a process behind it: an offline session's last status may still say it was working.
            if !session.is_attached() || !matches!(conversation.status, Status::Working | Status::Waiting | Status::Starting) { continue }
            let me = self.me.clone();
            pausing.spawn(async move {
                let deadline = tokio::time::Instant::now() + COMMAND_WAIT;
                // What it's waiting for, for the app to show while it waits.
                let (recent, _) = session.recent(50);
                let running = recent.items.iter().rev().find_map(|i| match (&i.kind, i.status) {
                    (ItemKind::Command { command, .. }, crate::model::ItemStatus::Running) => Some(command.clone()), _ => None });
                if let (Some(command), Some(daemon)) = (running, me.upgrade()) { daemon.held_up.lock().unwrap().insert(conversation.id.clone(), command); }
                // A session closed or gone offline meanwhile has no command to wait for, whatever its last item says.
                while session.is_attached() && (session.running_command() || session.summary().status == Status::Starting) && tokio::time::Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
                session.pause_for_update();
                if session.is_attached() { let _ = tokio::time::timeout(Duration::from_secs(5), session.interrupt()).await; }
                // The agent's own note of the stop says it's paused for the update; a moment for it, else Zero's.
                let noted = || session.recent(5).0.items.iter().any(|i| matches!(&i.kind, ItemKind::Notice { text, .. } if text == PAUSED_FOR_UPDATE));
                for _ in 0..10 { if noted() { break } tokio::time::sleep(Duration::from_millis(100)).await }
                if !noted() { note_pause(&session, PAUSED_FOR_UPDATE) }
                if let Some(daemon) = me.upgrade() { daemon.held_up.lock().unwrap().remove(&conversation.id); }
                conversation.id
            });
        }
        let mut paused = vec![];
        while let Some(done) = pausing.join_next().await { if let Ok(id) = done { paused.push(id) } }
        for id in &paused {
            // Once, however many restarts paused it before it carried on.
            let mut pending = self.pending.lock().unwrap();
            let list = pending.entry(id.clone()).or_default();
            if list.iter().any(|q| q.text == CARRY_ON) { continue }
            list.push(Queued { id: new_id(), text: CARRY_ON.into(), images: vec![], report: true });
            drop(pending);
            self.keep_pending(id);
        }
        // Which turns to carry on: these, and only these (words waiting for a parked task wait for you to resume it).
        let _ = std::fs::write(self.home.join("paused.json"), serde_json::to_vec(&paused).unwrap_or_default());
        paused
    }

    /// Once zerod is up after a restart: the turns it paused resume, and are told to carry on as soon as they're between
    /// turns. Nothing else is resumed. Gives the sessions resumed.
    pub fn carry_on(&self) -> Vec<String> {
        let file = self.home.join("paused.json");
        let paused: Vec<String> = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        let _ = std::fs::remove_file(&file);
        let mut resumed = vec![];
        for id in paused {
            let Ok(session) = self.session(&id) else { continue };
            if session.is_attached() || session.summary().terminal.is_some() || self.is_paused(&id) { continue }
            // The turn was paused for the update and carried on, not stopped: said in the conversation, in place of the
            // pause's "Interrupted" when that was noted, on a line of its own when it wasn't (the old zerod may have
            // gone before the interrupt's result was recorded).
            note_pause(&session, CARRIED);
            let Some(daemon) = self.me.upgrade() else { break };
            resumed.push(id.clone());
            tokio::spawn(async move { if let Err(error) = daemon.resume(&id).await { eprintln!("zerod: couldn't resume {id} to carry on: {error}") } });
        }
        resumed
    }

    /// Whether a restart is under way, and the turns it's waiting on: each one's task and the command it lets finish
    /// (at most COMMAND_WAIT), for the app to say what Zero is waiting for.
    pub fn restart_status(&self) -> serde_json::Value {
        let waiting: Vec<serde_json::Value> = self.held_up.lock().unwrap().iter().map(|(id, command)| {
            let task = self.session(id).map(|s| { let c = s.summary(); c.label.or(c.title).unwrap_or_default() }).unwrap_or_default();
            serde_json::json!({"session": id, "task": task, "command": command})
        }).collect();
        serde_json::json!({"restarting": self.restarting.load(Ordering::Relaxed), "waiting": waiting, "most": COMMAND_WAIT.as_secs()})
    }

    pub fn is_paused(&self, id: &str) -> bool { self.paused.lock().unwrap().contains(id) }

    /// Puts `ids` and their workers (every lead's, `ids` empty) on hold: each working one is asked to wrap up, given
    /// `wait` to end its turn, then stopped (a running command left to finish first, as for a restart); then parked.
    /// Words for them wait until they're resumed. Gives the sessions paused.
    pub async fn pause(&self, ids: &[String], wait: Duration) -> Vec<String> {
        let targets = if ids.is_empty() { self.list().into_iter().filter(|c| c.parent.is_none()).map(|c| c.id).collect() } else { ids.to_vec() };
        let targets = self.with_workers(targets);
        // Marked first: the turns ending now are the pause, not word for a lead or a reason to deliver.
        self.paused.lock().unwrap().extend(targets.iter().cloned());
        self.keep_paused();
        let mut pausing = tokio::task::JoinSet::new();
        for id in &targets {
            let Ok(session) = self.session(id) else { continue };
            let Some(daemon) = self.me.upgrade() else { break };
            let id = id.clone();
            pausing.spawn(async move {
                if session.is_attached() && busy(session.summary().attention()) {
                    // Told to carry on when resumed, since its turn is cut short.
                    daemon.pending.lock().unwrap().entry(id.clone()).or_default()
                        .push(Queued { id: new_id(), text: crate::model::from_line("zero", RESUMED), images: vec![], report: true });
                    daemon.keep_pending(&id);
                    // Steered where the provider allows it; where it doesn't (OpenCode), the wait runs out and it's stopped.
                    let _ = session.send_with_images(&crate::model::from_line("zero", WRAP_UP), &[], None, None).await;
                    let deadline = tokio::time::Instant::now() + wait;
                    while session.is_attached() && busy(session.summary().attention()) && tokio::time::Instant::now() < deadline {
                        tokio::time::sleep(Duration::from_millis(250)).await;
                    }
                    let deadline = tokio::time::Instant::now() + COMMAND_WAIT;
                    while session.is_attached() && session.running_command() && tokio::time::Instant::now() < deadline {
                        tokio::time::sleep(Duration::from_millis(250)).await;
                    }
                    if session.is_attached() && busy(session.summary().attention()) {
                        let _ = tokio::time::timeout(Duration::from_secs(5), session.interrupt()).await;
                    }
                }
                daemon.take_offline(&session).await;
            });
        }
        while pausing.join_next().await.is_some() {}
        let _ = self.queues.send(()); // the board shows it paused, though nothing of the session's changed
        targets
    }

    /// Takes `ids` (every paused session, `ids` empty) off hold. Those with words waiting are resumed for them; the
    /// rest stay parked until they're written to, as any finished task. Gives the sessions taken off hold.
    pub async fn unpause(&self, ids: &[String]) -> Vec<String> {
        let ids = if ids.is_empty() { self.paused.lock().unwrap().iter().cloned().collect() } else { self.with_workers(ids.to_vec()) };
        let resumed: Vec<String> = {
            let mut paused = self.paused.lock().unwrap();
            ids.into_iter().filter(|id| paused.remove(id)).collect()
        };
        self.keep_paused();
        let waiting = self.pending.lock().unwrap().clone();
        for id in &resumed {
            if !waiting.get(id).is_some_and(|words| !words.is_empty()) { continue }
            if let Err(error) = self.resume(id).await { eprintln!("zerod: couldn't resume {id} after its pause: {error}") }
        }
        let _ = self.queues.send(());
        resumed
    }

    /// `ids` and their workers, theirs too, through every level.
    fn with_workers(&self, mut ids: Vec<String>) -> Vec<String> {
        let all = self.list();
        let mut i = 0;
        while i < ids.len() {
            let id = ids[i].clone();
            let more: Vec<String> = all.iter().filter(|c| c.parent.as_deref() == Some(&id) && !ids.contains(&c.id)).map(|c| c.id.clone()).collect();
            ids.extend(more);
            i += 1;
        }
        ids.retain(|id| self.session(id).is_ok());
        ids
    }

    /// The user saw a task's reply: its latest answer unless one is named, now unless a time is given (a client
    /// passing on what it recorded before zerod kept this).
    pub fn mark_seen(&self, id: &str, answer: Option<&str>, at: Option<i64>) -> Result<(), String> {
        self.session(id)?;
        let Some(answer) = answer.map(String::from).or_else(|| self.latest_answer(id)) else { return Ok(()) };
        let mut seen = self.seen.lock().unwrap();
        if seen.get(id).is_some_and(|(kept, _)| *kept == answer) && at.is_none() { return Ok(()) }
        seen.insert(id.to_string(), (answer, at.unwrap_or_else(now)));
        let _ = std::fs::write(self.home.join(SEEN), serde_json::to_vec(&*seen).unwrap_or_default());
        Ok(())
    }

    /// A turn Zero started (an event it follows, a worker's report, a wake-up) has come to an end: its reply is nothing
    /// new for the user if they had read the one before it, so it's read too. One to their own message stays new.
    fn carry_read(&self, conversation: &Conversation) {
        let items = &conversation.items;
        let Some(asked) = items.iter().rposition(|i| matches!(i.kind, ItemKind::User { .. })) else { return };
        let ItemKind::User { text, .. } = &items[asked].kind else { return };
        if !text.starts_with(crate::model::FROM) { return }
        let answer = |range: &[crate::model::Item]| range.iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. })).map(|i| i.id.clone());
        let (Some(before), Some(latest)) = (answer(&items[..asked]), answer(&items[asked..])) else { return };
        let read_before = self.seen.lock().unwrap().get(&conversation.id).is_some_and(|(seen, _)| *seen == before);
        if read_before { let _ = self.mark_seen(&conversation.id, Some(&latest), None); }
    }

    /// Whether the user has read the task's reply (board::read).
    pub fn has_read(&self, id: &str) -> bool {
        let seen = self.seen.lock().unwrap().get(id).cloned();
        seen.is_some() && crate::board::read(seen.as_ref().map(|(a, at)| (a.as_str(), *at)), self.latest_answer(id).as_deref(), now())
    }

    fn latest_answer(&self, id: &str) -> Option<String> {
        self.get(id)?.items.iter().rev().find(|i| matches!(i.kind, ItemKind::Agent { final_answer: true, .. })).map(|i| i.id.clone())
    }

    fn keep_paused(&self) {
        let paused: Vec<String> = self.paused.lock().unwrap().iter().cloned().collect();
        let _ = std::fs::write(self.home.join(PAUSED), serde_json::to_vec(&paused).unwrap_or_default());
    }

    /// Stops the process of every session idle for PARK_AFTER with nothing waiting for it.
    fn park(&self) {
        let pending = self.pending.lock().unwrap().clone();
        for session in self.sessions() {
            if session.unwanted_for().is_some_and(|unwanted| unwanted >= UNLOAD_AFTER) { session.unload(); }
            if !session.is_loaded() { continue }
            let conversation = session.summary();
            if let Some(open) = conversation.terminal {
                let (Some(daemon), id) = (self.me.upgrade(), conversation.id.clone()) else { continue };
                tokio::spawn(async move {
                    if daemon.host().idle(&open.id).await.is_some_and(|idle| idle >= TERMINAL_PARK_AFTER)
                        && let Err(error) = daemon.close_terminal(&id).await { eprintln!("zerod: couldn't close {id}'s idle terminal: {error}") }
                });
                continue;
            }
            if pending.get(&conversation.id).is_some_and(|words| !words.is_empty()) { continue }
            if session.idle_for().is_some_and(|idle| idle >= PARK_AFTER) { session.stop() }
        }
    }

    /// The next of what waits: a message of the user's on its own (one turn each, never joined to anything), or the
    /// reports at the head of the queue together. The rest goes when that turn ends. A held queue waits.
    fn deliver(&self, id: &str) {
        if self.restarting.load(Ordering::Relaxed) || self.is_paused(id) { return }
        if self.held.lock().unwrap().contains(id) { return }
        let Ok(session) = self.session(id) else { return };
        if !session.is_attached() { return }
        if !self.delivering.lock().unwrap().insert(id.into()) { return }
        let (text, images) = {
            let mut pending = self.pending.lock().unwrap();
            let Some(list) = pending.get_mut(id).filter(|l| !l.is_empty()) else { self.delivering.lock().unwrap().remove(id); return };
            if list[0].report {
                let reports = list.iter().take_while(|q| q.report).count();
                (list.drain(..reports).map(|q| q.text).collect::<Vec<_>>().join("\n\n"), vec![])
            } else {
                let next = list.remove(0);
                (next.text, next.images)
            }
        };
        self.keep_pending(id);
        let (me, id) = (self.me.clone(), id.to_string());
        tokio::spawn(async move {
            // ponytail: word that fails to go through is dropped with a notice; keep it if sends start failing in practice.
            if let Err(error) = session.send_with_images(&text, &images, None, None).await { session.report(&format!("Couldn't pass on: {error}")) }
            if let Some(daemon) = me.upgrade() { daemon.delivering.lock().unwrap().remove(&id); }
        });
    }

    /// Holds a session's queue for the user, or lets it go; kept in its folder, so zerod started again still holds it.
    fn hold(&self, id: &str, on: bool) {
        let marker = self.home.join("sessions").join(id).join(HELD);
        if on { self.held.lock().unwrap().insert(id.into()); let _ = std::fs::write(marker, b""); }
        else if self.held.lock().unwrap().remove(id) { let _ = std::fs::remove_file(marker); }
    }

    fn keep_pending(&self, id: &str) {
        let words = self.pending.lock().unwrap().get(id).cloned().unwrap_or_default();
        let file = self.home.join("sessions").join(id).join("pending.json");
        let _ = if words.is_empty() { std::fs::remove_file(file) } else { std::fs::write(file, serde_json::to_vec(&words).unwrap_or_default()) };
        let _ = self.queues.send(());
    }

    pub fn stop(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        if session.summary().status == Status::Offline { return Err(format!("{id} isn't running")) }
        session.stop();
        Ok(())
    }
}

/// The user's home, and zero-host's socket in Zero's folder there.
fn user_places() -> (PathBuf, PathBuf) {
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let host = home.join(".zero/host.sock");
    (home, host)
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// zerod's own sessions as a runtime for the inbox: an agent in one that asks with `zero ask --async` gets its answer
/// between turns, the way a worker's report reaches its lead.
pub struct Sessions(Weak<Daemon>);

impl Sessions {
    pub fn of(daemon: &Arc<Daemon>) -> Sessions {
        Sessions(Arc::downgrade(daemon))
    }

    fn session(agent: &crate::ask::AgentIdentity) -> Option<&str> {
        (agent.runtime.as_deref() == Some("zerod")).then_some(agent.reference.as_deref()).flatten()
    }
}

impl crate::inbox::Runtime for Sessions {
    fn name(&self) -> &str { "Zero" }
    fn can_reach(&self, agent: &crate::ask::AgentIdentity) -> bool { Sessions::session(agent).is_some() && self.0.upgrade().is_some() }
    fn send<'a>(&'a self, text: &'a str, agent: &'a crate::ask::AgentIdentity) -> crate::inbox::Fut<'a, Result<(), String>> {
        Box::pin(async move {
            let (daemon, id) = (self.0.upgrade().ok_or("zerod is stopping")?, Sessions::session(agent).ok_or("not a zerod session")?);
            daemon.notify(id, text)
        })
    }
    fn display_name<'a>(&'a self, agent: &'a crate::ask::AgentIdentity) -> crate::inbox::Fut<'a, Option<String>> {
        Box::pin(async move {
            let conversation = self.0.upgrade()?.get(Sessions::session(agent)?)?;
            conversation.label.or(conversation.title)
        })
    }
    fn offline<'a>(&'a self, agents: &'a [crate::ask::AgentIdentity]) -> crate::inbox::Fut<'a, std::collections::HashSet<String>> {
        Box::pin(async move {
            let Some(daemon) = self.0.upgrade() else { return Default::default() };
            agents.iter().filter(|a| Sessions::session(a).and_then(|id| daemon.get(id)).is_some_and(|c| c.status == Status::Offline)).map(|a| a.name.clone()).collect()
        })
    }
    fn gone<'a>(&'a self, agents: &'a [crate::ask::AgentIdentity]) -> crate::inbox::Fut<'a, std::collections::HashSet<String>> {
        Box::pin(async move {
            let Some(daemon) = self.0.upgrade() else { return Default::default() };
            agents.iter().filter(|a| Sessions::session(a).is_some_and(|id| daemon.get(id).is_none())).map(|a| a.name.clone()).collect()
        })
    }
    fn stop<'a>(&'a self, agent: &'a crate::ask::AgentIdentity) -> crate::inbox::Fut<'a, ()> {
        Box::pin(async move { if let (Some(daemon), Some(id)) = (self.0.upgrade(), Sessions::session(agent)) { let _ = daemon.stop(id); } })
    }
}

/// What a lead is told when a worker stops working, and how to answer it.
pub fn report(worker: &Conversation, attention: Attention) -> String {
    let mut name = worker.label.clone().unwrap_or_else(|| worker.id.clone());
    if let Some(ticket) = &worker.ticket { name = format!("{name} ({ticket})") }
    let what = match attention {
        Attention::Done => {
            let full = worker.answer().unwrap_or("");
            let answer = crate::board::without_ending(full);
            let answer = if answer.chars().count() > 4000 { answer.chars().take(4000).collect::<String>() + "…" } else { answer.to_string() };
            // How it ended its turn says what its answer is: a worker waiting on the user, or blocked, isn't finished.
            match crate::board::ending(full) {
                Some("asked") => {
                    let id = full.trim_end().lines().last().and_then(|l| l.trim().trim_end_matches(']').split_whitespace().nth(2)).unwrap_or("");
                    format!("is waiting on the user's answer (ask {id}): {answer}")
                }
                Some("blocked") => format!("is blocked: {answer}"),
                _ => format!("finished: {answer}"),
            }
        }
        Attention::Failed => format!("failed: {}", worker.failure.as_ref().map(|f| f.message.as_str()).unwrap_or("no reason given")),
        Attention::Stuck => format!("looks stuck: {}", worker.stalled.as_deref().unwrap_or("no progress")),
        Attention::Limited => "hit a usage limit".into(),
        Attention::Blocked => format!("is blocked: {}", worker.answer().map(crate::board::without_ending).unwrap_or("no reason given")),
        Attention::Offline => "stopped: its process ended".into(),
        _ => "stopped without an answer".into(),
    };
    format!("Worker {name} {what}\n\n(It is session {}: `zero send {} \"…\"` to reply to it, `zero wait {}` to wait on it.)", worker.id, worker.id, worker.id)
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
    let millis = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
    format!("{millis:012x}{:04x}", COUNTER.fetch_add(1, Ordering::Relaxed) & 0xffff)
}

/// A message of yours in the conversation: where it is, its words and its images.
fn yours(conversation: &Conversation, item: &str) -> Result<(usize, String, Vec<String>), String> {
    let at = conversation.items.iter().position(|i| i.id == item).ok_or("That message isn't in the conversation")?;
    match &conversation.items[at].kind {
        ItemKind::User { text, images } => Ok((at, text.clone(), images.clone())),
        _ => Err("Only a message of yours can be gone back to".into()),
    }
}

/// A snapshot taken as a message went, noted against that message: the latest of yours without one.
fn attach_snapshot(session: &Session, commit: String) {
    let conversation = session.snapshot();
    let Some(item) = conversation.items.iter().rev().find(|i| matches!(i.kind, ItemKind::User { .. })) else { return };
    if conversation.snapshots.contains_key(&item.id) { return }
    session.change(Change::Snapshot { item: item.id.clone(), commit });
}

fn millis() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

/// The folder a Claude Code session ran in, from the first of its records that says.
fn claude_cwd(file: &Path) -> Option<String> {
    use std::io::BufRead;
    std::io::BufReader::new(std::fs::File::open(file).ok()?).lines().map_while(Result::ok)
        .find_map(|line| serde_json::from_str::<serde_json::Value>(&line).ok()?["cwd"].as_str().map(String::from))
}

/// When something's archived, in milliseconds, never the same twice: two put away in one millisecond still list in
/// the order they went.
fn archived_at() -> i64 {
    static LAST: AtomicI64 = AtomicI64::new(0);
    let now = millis() as i64;
    let mut last = LAST.load(Ordering::Relaxed);
    loop {
        let next = now.max(last + 1);
        match LAST.compare_exchange(last, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return next,
            Err(seen) => last = seen,
        }
    }
}

/// A session's queue as kept in its folder. Before queues, pending.json held plain words: reports.
fn kept_pending(dir: &Path) -> Vec<Queued> {
    let Ok(data) = std::fs::read(dir.join("pending.json")) else { return vec![] };
    serde_json::from_slice(&data).unwrap_or_else(|_| serde_json::from_slice::<Vec<String>>(&data).unwrap_or_default()
        .into_iter().map(|text| Queued { id: new_id(), text, images: vec![], report: true }).collect())
}

fn marker(dir: &Path) -> Option<serde_json::Value> {
    std::fs::read(dir.join(ARCHIVED)).ok().and_then(|data| serde_json::from_slice(&data).ok())
}

/// The lead an archived task went with, if it went with one.
fn archived_with(dir: &Path) -> Option<String> { marker(dir).and_then(|m| m["with"].as_str().map(String::from)) }

/// How many archived tasks went with each lead.
fn archived_counts(archive: &Path) -> HashMap<String, usize> {
    let mut counts = HashMap::new();
    for entry in std::fs::read_dir(archive).into_iter().flatten().flatten() {
        if let Some(with) = archived_with(&entry.path()) { *counts.entry(with).or_insert(0) += 1 }
    }
    counts
}

fn modified_ms(path: &Path) -> i64 {
    std::fs::metadata(path).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// An archived task's name from its parked summary (archived before archive markers were kept).
fn parked_label(dir: &Path) -> Option<String> {
    let parked: serde_json::Value = serde_json::from_slice(&std::fs::read(dir.join("parked.json")).ok()?).ok()?;
    let summary: Conversation = serde_json::from_value(parked["summary"].clone()).ok()?;
    Some(crate::bridge::label(&summary))
}

/// A turn paused for an update says so: in place of the pause's "Interrupted" (or the line saying it's paused, once
/// it's carried on), else on a line of its own (the old zerod may have gone before the interrupt was recorded).
fn note_pause(session: &Session, words: &str) {
    let conversation = session.snapshot();
    let item = match conversation.items.last().cloned() {
        Some(mut last) if matches!(&last.kind, ItemKind::Notice { text, error: false } if text == "Interrupted" || text == PAUSED_FOR_UPDATE) => {
            last.kind = ItemKind::Notice { text: words.into(), error: false };
            last
        }
        _ => crate::model::Item { at: None, id: format!("paused-{}", conversation.seq + 1), turn: None,
                                  kind: ItemKind::Notice { text: words.into(), error: false }, status: crate::model::ItemStatus::Done },
    };
    session.change(Change::Item { item });
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

