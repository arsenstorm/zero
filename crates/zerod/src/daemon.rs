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
use crate::model::{Attention, Change, Conversation, Event, Opened, Permissions, Provider, Status};
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
    me: Weak<Daemon>,
}

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
                    let conversation = session.snapshot();
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
            resets: Mutex::new(HashMap::new()), me: me.clone(), user: Mutex::new(user_places()),
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
        self.sessions().into_iter().find(|s| s.snapshot().id == id).ok_or_else(|| format!("No session {id}"))
    }

    pub fn get(&self, id: &str) -> Option<Conversation> {
        self.session(id).ok().map(|s| s.snapshot())
    }

    /// Every session without its items: enough for a list.
    pub fn list(&self) -> Vec<Conversation> {
        self.sessions().iter().map(|s| Conversation { items: vec![], ..s.snapshot() }).collect()
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
        if prompt.trim().is_empty() { return Err("A session starts with something to do".into()) }
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
        let (prompt, model, effort) = (prompt.to_string(), model.map(String::from), effort.map(String::from));
        tokio::spawn(async move {
            if let Err(error) = session.start(transport, &prompt, model.as_deref(), effort.as_deref()).await {
                session.report(&error);
            }
        });
        Ok(id)
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
            if session.snapshot().status == Status::Offline { break }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// Arsen's words to a session, resuming it first if it is offline.
    pub async fn send(&self, id: &str, text: &str, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        let session = self.session(id)?;
        if let Some(conversation) = self.get(id) && conversation.terminal.is_some() {
            return Err(format!("{} is open in its terminal; type there, or go back to Zero", conversation.provider.title()));
        }
        if !session.is_attached() { self.resume(id).await? }
        session.send(text, model, effort).await
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
        if provider == Provider::Claude {
            let thread = claude::new_session_id();
            let folder = crate::handoff::claude_folder(&self.user_home(), &conversation.cwd);
            std::fs::create_dir_all(&folder).and_then(|_| std::fs::write(folder.join(format!("{thread}.jsonl")), crate::handoff::claude_session(&session.snapshot(), &thread)))
                .map_err(|e| format!("Couldn't write the conversation for Claude Code: {e}"))?;
            session.change(Change::Thread { thread, model: None, effort: None });
        }
        Ok(())
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
        for conversation in self.sessions().iter().map(|s| s.snapshot()) {
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

    /// Keeps `words` for `id` until it can take them.
    fn tell(&self, id: &str, words: String) {
        self.pending.lock().unwrap().entry(id.into()).or_default().push(words);
        self.keep_pending(id);
        if self.get(id).is_some_and(|c| matches!(c.attention(), Attention::Done | Attention::Idle)) { self.deliver(id) }
    }

    fn deliver(&self, id: &str) {
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
        if session.snapshot().status == Status::Offline { return Err(format!("{id} isn't running")) }
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
