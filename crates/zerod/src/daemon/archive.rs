//! Archiving tasks and parking idle ones: an archived task's folder moves to the archive, with the lead it went
//! with; a parked one's process stops until it's written to.

use super::*;

impl Daemon {
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

    /// Stops the process of every session idle for PARK_AFTER with nothing waiting for it.
    pub(super) fn park(&self) {
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

fn marker(dir: &Path) -> Option<serde_json::Value> {
    std::fs::read(dir.join(ARCHIVED)).ok().and_then(|data| serde_json::from_slice(&data).ok())
}

/// The lead an archived task went with, if it went with one.
pub(super) fn archived_with(dir: &Path) -> Option<String> { marker(dir).and_then(|m| m["with"].as_str().map(String::from)) }

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
