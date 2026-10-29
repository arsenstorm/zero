//! The daemon's sessions: started in a folder, kept under `<home>/sessions/<id>/`, loaded again at start-up,
//! and resumed with a new runtime process whenever one is wanted. A session can start others (a lead and its
//! workers): each worker's outcome is put to its lead as a message once the lead is between turns.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::sync::broadcast;

use crate::claude;
use crate::model::{Attention, Change, Conversation, Event, ItemKind, Opened, Permissions, Provider, Status};
use crate::process;
use crate::session::{Session, Transport};

/// Starts a session's runtime process: its conversation, its folder in the daemon's home, and the command line
/// its provider starts with.
pub type Runtime = Arc<dyn Fn(&Conversation, &Path, &[String]) -> io::Result<Transport> + Send + Sync>;

/// The real one: the provider's CLI in the session's folder, its errors in the session's stderr.log.
pub fn real_runtime() -> Runtime {
    Arc::new(|conversation, dir, argv| process::spawn(argv, Path::new(&conversation.cwd), &conversation.id, Some(&dir.join("stderr.log"))))
}

pub struct Daemon {
    home: PathBuf,
    sessions: Mutex<Vec<Session>>,
    events: broadcast::Sender<Event>,
    runtime: Runtime,
    /// Each session's attention as last seen, to tell when a worker stops working.
    attention: Mutex<HashMap<String, Attention>>,
    /// Word for a session that it hasn't been given yet (it was busy or offline), kept in its folder as pending.json.
    pending: Mutex<HashMap<String, Vec<String>>>,
    /// The limit resets already waited for, by session, so each is waited for once.
    resets: Mutex<HashMap<String, i64>>,
    /// The user's home (where Claude Code keeps its sessions) and zero-host's socket.
    user: Mutex<(PathBuf, PathBuf)>,
    /// zerod is about to become a new build: words wait for it, rather than starting turns the restart would cut.
    restarting: std::sync::atomic::AtomicBool,
    me: Weak<Daemon>,
}

/// What a turn paused for a restart is told once the new zerod is up.
const CARRY_ON: &str = "Zero restarted while you were working: your turn was paused between steps. Please carry on where you left off.";
/// How long a restart waits for a running command before pausing its turn anyway.
const COMMAND_WAIT: Duration = Duration::from_secs(30 * 60);

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
    pub model: Option<String>,
    pub effort: Option<String>,
    pub permissions: Option<Permissions>,
    pub label: Option<String>,
    pub ticket: Option<String>,
    /// Start even though the provider is at its usage limit.
    pub force: bool,
    /// Images with the first message, by their files.
    pub images: Vec<String>,
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
        let (mut sessions, mut attention, mut pending) = (vec![], HashMap::new(), HashMap::new());
        for dir in dirs {
            match Session::load(&dir, events.clone()) {
                Ok(session) => {
                    let conversation = session.summary();
                    attention.insert(conversation.id.clone(), conversation.attention());
                    if let Ok(words) = std::fs::read(dir.join("pending.json")).map(|data| serde_json::from_slice::<Vec<String>>(&data).unwrap_or_default())
                        && !words.is_empty() { pending.insert(conversation.id.clone(), words); }
                    sessions.push(session);
                }
                Err(error) => eprintln!("zerod: skipped {}: {error}", dir.display()),
            }
        }
        let daemon = Arc::new_cyclic(|me| Daemon {
            home: home.into(), sessions: Mutex::new(sessions), events, runtime, attention: Mutex::new(attention), pending: Mutex::new(pending),
            resets: Mutex::new(HashMap::new()), me: me.clone(), user: Mutex::new(user_places()), restarting: Default::default(),
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
        Ok(daemon)
    }

    /// Where sessions and the daemon's own files are kept.
    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
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
        let options = Options { cwd: Some(cwd.into()), model: model.map(Into::into), effort: effort.map(Into::into), permissions: Some(permissions), ..Default::default() };
        self.create(provider, prompt, options, None)
    }

    /// A session of its own (no lead), with every option.
    pub fn start_with(&self, provider: Provider, prompt: &str, options: Options) -> Result<String, String> {
        self.create(provider, prompt, options, None)
    }

    /// A worker of `lead`: in the lead's folder, with the lead's permissions, unless told otherwise.
    pub fn spawn(&self, lead: &str, provider: Provider, prompt: &str, mut options: Options) -> Result<String, String> {
        let parent = self.get(lead).ok_or_else(|| format!("No session {lead} to lead it"))?;
        options.cwd = options.cwd.or(Some(parent.cwd));
        options.permissions = options.permissions.or(Some(parent.permissions));
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
        conversation.branch = branch(folder);
        // Claude takes its conversation's id from Zero, so the session can be resumed even if it never answered.
        if provider == Provider::Claude { conversation.thread = Some(claude::new_session_id()) }
        let session = Session::new(conversation.clone(), Some(dir.clone()), self.events.clone()).map_err(|e| e.to_string())?;
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

    /// Puts a task away: stopped, out of the list, its files moved to archive/ (moved back, it returns).
    pub async fn archive(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        if session.summary().terminal.is_some() { self.close_terminal(id).await? }
        self.take_offline(&session).await;
        let seq = session.summary().seq;
        self.sessions.lock().unwrap().retain(|s| s.id() != id);
        self.attention.lock().unwrap().remove(id);
        self.pending.lock().unwrap().remove(id);
        drop(session);
        let archive = self.home.join("archive");
        std::fs::create_dir_all(&archive).map_err(|e| e.to_string())?;
        std::fs::rename(self.home.join("sessions").join(id), archive.join(id)).map_err(|e| e.to_string())?;
        let _ = self.events.send(Event { session: id.into(), seq: seq + 1, change: Change::Archived });
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
        let argv = conversation.provider.command(&conversation, false, model.as_deref(), effort.as_deref());
        let transport = (self.runtime)(&conversation, &self.home.join("sessions").join(&conversation.id), &argv)
            .map_err(|e| format!("{} didn't start: {e}", conversation.provider.title()))?;
        session.restart(transport, context.as_deref(), text, images, model.as_deref(), effort.as_deref()).await
    }

    /// ponytail: two resumes of one session at once each start a process, and the later one wins; a per-session
    /// lock if clients ever race.
    pub async fn resume(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        if session.is_attached() { return Ok(()) }
        let conversation = session.snapshot();
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
        if provider == conversation.provider { return Ok(()) }
        if provider == Provider::Opencode { return Err(format!("Zero can't hand a task to {} yet", provider.title())) }
        if matches!(conversation.status, Status::Working | Status::Waiting) {
            return Err(format!("{} is working; stop its turn first", conversation.provider.title()));
        }
        if conversation.terminal.is_some() { return Err(format!("{} is open in its terminal; go back to Zero first", conversation.provider.title())) }
        self.take_offline(&session).await;
        session.change(Change::Switched { provider, model: model.map(Into::into), effort: effort.map(Into::into) });
        self.rethread(&session)
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

    pub async fn interrupt(&self, id: &str) -> Result<(), String> {
        self.session(id)?.interrupt().await
    }

    pub async fn decide(&self, id: &str, approval: &str, choice: &str) -> Result<(), String> {
        self.session(id)?.decide(approval, choice).await
    }

    pub async fn answer(&self, id: &str, question: &str, answers: &crate::adapter::Answers) -> Result<(), String> {
        self.session(id)?.answer(question, answers).await
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

    /// Words for a session from anywhere (an event source, a script, the user): given when it is between turns, kept
    /// on disk while it is offline.
    pub fn notify(&self, id: &str, text: &str) -> Result<(), String> {
        self.session(id)?;
        self.tell(id, text.into());
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
            if let Some(daemon) = me.upgrade() { daemon.tell(&id, words) }
        });
        Ok(())
    }

    /// Tells the session `text` after `after`. ponytail: held in memory, so a daemon restart forgets it; keep it on disk
    /// beside pending.json if reminders start spanning restarts.
    pub fn remind(&self, id: &str, after: Duration, text: &str) -> Result<(), String> {
        self.session(id)?;
        let (me, id, text) = (self.me.clone(), id.to_string(), text.to_string());
        tokio::spawn(async move {
            tokio::time::sleep(after).await;
            if let Some(daemon) = me.upgrade() { daemon.tell(&id, text) }
        });
        Ok(())
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
            daemon.tell(&id, "The usage limit has reset: carry on with what you were doing.".into());
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
        let ended = matches!(now, Attention::Done | Attention::Failed | Attention::Limited | Attention::Offline | Attention::Idle);
        let came_to_an_end = before.is_some_and(under_way) && ended;
        let got_stuck = now == Attention::Stuck && before != Some(Attention::Stuck);
        if let Some(lead) = &conversation.parent && (came_to_an_end || got_stuck) {
            self.tell(lead, report(&conversation, now));
        }
        if now == Attention::Limited { self.after_reset(&conversation) }
        if matches!(now, Attention::Done | Attention::Idle) { self.deliver(id) }
    }

    /// Keeps `words` for `id` until it can take them; a parked (offline) session is resumed for them, and they go
    /// once it's between turns.
    fn tell(&self, id: &str, words: String) {
        self.pending.lock().unwrap().entry(id.into()).or_default().push(words);
        self.keep_pending(id);
        let Ok(session) = self.session(id) else { return };
        if !session.is_attached() && session.summary().terminal.is_none() {
            let (Some(daemon), id) = (self.me.upgrade(), id.to_string()) else { return };
            tokio::spawn(async move { if let Err(error) = daemon.resume(&id).await { eprintln!("zerod: couldn't resume {id} for its words: {error}") } });
        } else if matches!(session.summary().attention(), Attention::Done | Attention::Idle) {
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
            pausing.spawn(async move {
                let deadline = tokio::time::Instant::now() + COMMAND_WAIT;
                while (session.running_command() || session.summary().status == Status::Starting) && tokio::time::Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
                if session.is_attached() { let _ = tokio::time::timeout(Duration::from_secs(5), session.interrupt()).await; }
                conversation.id
            });
        }
        let mut paused = vec![];
        while let Some(done) = pausing.join_next().await { if let Ok(id) = done { paused.push(id) } }
        for id in &paused {
            self.pending.lock().unwrap().entry(id.clone()).or_default().push(CARRY_ON.into());
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
            if session.is_attached() || session.summary().terminal.is_some() { continue }
            let Some(daemon) = self.me.upgrade() else { break };
            resumed.push(id.clone());
            tokio::spawn(async move { if let Err(error) = daemon.resume(&id).await { eprintln!("zerod: couldn't resume {id} to carry on: {error}") } });
        }
        resumed
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

    fn deliver(&self, id: &str) {
        if self.restarting.load(Ordering::Relaxed) { return }
        let Ok(session) = self.session(id) else { return };
        if !session.is_attached() { return }
        let Some(words) = self.pending.lock().unwrap().remove(id) else { return };
        self.keep_pending(id);
        let text = words.join("\n\n");
        tokio::spawn(async move {
            // ponytail: word that fails to go through is dropped with a notice; keep it if sends start failing in practice.
            if let Err(error) = session.send(&text, None, None).await { session.report(&format!("Couldn't pass on: {error}")) }
        });
    }

    fn keep_pending(&self, id: &str) {
        let words = self.pending.lock().unwrap().get(id).cloned().unwrap_or_default();
        let file = self.home.join("sessions").join(id).join("pending.json");
        let _ = if words.is_empty() { std::fs::remove_file(file) } else { std::fs::write(file, serde_json::to_vec(&words).unwrap_or_default()) };
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
fn report(worker: &Conversation, attention: Attention) -> String {
    let mut name = worker.label.clone().unwrap_or_else(|| worker.id.clone());
    if let Some(ticket) = &worker.ticket { name = format!("{name} ({ticket})") }
    let what = match attention {
        Attention::Done => {
            let answer = worker.answer().unwrap_or("");
            let answer = if answer.chars().count() > 4000 { answer.chars().take(4000).collect::<String>() + "…" } else { answer.to_string() };
            format!("finished: {answer}")
        }
        Attention::Failed => format!("failed: {}", worker.failure.as_ref().map(|f| f.message.as_str()).unwrap_or("no reason given")),
        Attention::Stuck => format!("looks stuck: {}", worker.stalled.as_deref().unwrap_or("no progress")),
        Attention::Limited => "hit a usage limit".into(),
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
