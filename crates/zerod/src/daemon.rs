//! The daemon's sessions: started in a folder, kept under `<home>/sessions/<id>/`, loaded again at start-up,
//! and resumed with a new runtime process whenever one is wanted.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::broadcast;

use crate::claude;
use crate::model::{Conversation, Event, Permissions, Provider, Status};
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
}

impl Daemon {
    pub fn open(home: &Path, runtime: Runtime) -> io::Result<Arc<Daemon>> {
        let root = home.join("sessions");
        std::fs::create_dir_all(&root)?;
        // ponytail: 4096 changes of slack per subscriber; one that falls further behind gets fresh snapshots.
        let (events, _) = broadcast::channel(4096);
        let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)?.filter_map(|entry| entry.ok().map(|e| e.path())).filter(|p| p.is_dir()).collect();
        dirs.sort(); // ids sort by when they were made
        let mut sessions = vec![];
        for dir in dirs {
            match Session::load(&dir, events.clone()) {
                Ok(session) => sessions.push(session),
                Err(error) => eprintln!("zerod: skipped {}: {error}", dir.display()),
            }
        }
        Ok(Arc::new(Daemon { home: home.into(), sessions: Mutex::new(sessions), events, runtime }))
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
        let folder = Path::new(cwd);
        if !folder.is_absolute() || !folder.is_dir() { return Err(format!("{cwd} isn't a folder")) }
        if prompt.trim().is_empty() { return Err("A session starts with something to do".into()) }
        let id = new_id();
        let dir = self.home.join("sessions").join(&id);
        let mut conversation = Conversation::new(&id, provider, cwd);
        conversation.permissions = permissions;
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
        session.announce();
        let (prompt, model, effort) = (prompt.to_string(), model.map(String::from), effort.map(String::from));
        tokio::spawn(async move {
            if let Err(error) = session.start(transport, &prompt, model.as_deref(), effort.as_deref()).await {
                session.report(&error);
            }
        });
        Ok(id)
    }

    /// Arsen's words to a session, resuming it first if it is offline.
    pub async fn send(&self, id: &str, text: &str, model: Option<&str>, effort: Option<&str>) -> Result<(), String> {
        let session = self.session(id)?;
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
        session.resume(transport).await
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

    pub fn stop(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        if session.snapshot().status == Status::Offline { return Err(format!("{id} isn't running")) }
        session.stop();
        Ok(())
    }
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
