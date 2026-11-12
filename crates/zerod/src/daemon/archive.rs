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
        for member in team.iter().rev() {
            self.archive_one(member, Some(id)).await?
        }
        let workspace = self.workspace_of(&root);
        self.archive_one(id, None).await?;
        let _ = std::fs::write(
            self.home.join("archive").join(id).join(ARCHIVED),
            serde_json::to_vec(&serde_json::json!({
                "with": null, "at": archived_at(), "task": crate::bridge::label(&root), "workspace": workspace, "workers": team.len(),
            }))
            .unwrap_or_default(),
        );
        self.reindex(id);
        Ok(())
    }

    async fn archive_one(&self, id: &str, with: Option<&str>) -> Result<(), String> {
        let session = self.session(id)?;
        if session.summary().terminal.is_some() {
            self.close_terminal(id).await?
        }
        // A worker's pull requests passed to its lead with its report: the lead carries on with them.
        if let (Some(following), Some(lead)) = (self.following.get(), session.summary().parent) {
            following.drop_shared(id, &lead)
        }
        self.archiving.lock().unwrap().insert(id.into());
        self.take_offline(&session).await;
        self.archiving.lock().unwrap().remove(id);
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
            let _ = std::fs::write(
                archive.join(id).join(ARCHIVED),
                serde_json::to_vec(&serde_json::json!({"with": with, "at": archived_at()})).unwrap_or_default(),
            );
        }
        self.reindex(id);
        let _ = self.events.send(Event { session: id.into(), seq: seq + 1, change: Change::Archived });
        Ok(())
    }

    /// Brings a task back from the archive, and the workers that went with it: offline, as they were, under it.
    pub fn unarchive(&self, id: &str) -> Result<Vec<String>, String> {
        let archive = self.home.join("archive");
        if !archive.join(id).join("meta.json").exists() {
            return Err(format!("Nothing archived as {id}"));
        }
        if self.session(id).is_ok() {
            return Err(format!("{id} isn't archived"));
        }
        let with: Vec<String> =
            self.archive_index(|index| index.iter().filter(|a| a.with.as_deref() == Some(id)).map(|a| a.id.clone()).collect());
        let mut back = vec![];
        for member in std::iter::once(id.to_string()).chain(with) {
            let (from, to) = (archive.join(&member), self.home.join("sessions").join(&member));
            std::fs::rename(&from, &to).map_err(|e| e.to_string())?;
            self.reindex(&member);
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
        if let Ok(session) = self.session(id) {
            session.announce()
        }
        Ok(back)
    }

    /// What's archived that was put away itself (not with its lead), newest first: its name, when, its workspace and
    /// how many workers went with it.
    pub fn archived(&self, limit: usize) -> Vec<serde_json::Value> {
        self.archive_index(|index| {
            let mut counts: HashMap<&str, usize> = HashMap::new();
            for with in index.iter().filter_map(|a| a.with.as_deref()) {
                *counts.entry(with).or_insert(0) += 1
            }
            let mut roots: Vec<&Archived> = index.iter().filter(|a| a.with.is_none()).collect();
            roots.sort_by_key(|a| std::cmp::Reverse(a.at));
            roots
                .into_iter()
                .take(limit)
                .map(|a| {
                    serde_json::json!({"id": a.id, "task": a.task, "at": a.at, "workspace": a.workspace,
                "workers": counts.get(a.id.as_str()).copied().unwrap_or(0), "parent": a.parent})
                })
                .collect()
        })
    }

    /// Every archived task, workers put away with their lead too: its id and name.
    pub(crate) fn archived_tasks(&self) -> Vec<(String, String)> {
        self.archive_index(|index| index.iter().map(|a| (a.id.clone(), a.task.clone())).collect())
    }

    /// The archived tasks called `name` (whatever the case).
    pub(super) fn archived_named(&self, name: &str) -> Vec<String> {
        self.archive_index(|index| index.iter().filter(|a| a.task.eq_ignore_ascii_case(name)).map(|a| a.id.clone()).collect())
    }

    /// An archived task as it was put away, read from its folder: what `zero wait` finds of it.
    pub(super) fn archived_summary(&self, id: &str) -> Option<Conversation> {
        let dir = self.home.join("archive").join(id);
        dir.join("meta.json").exists().then(|| Session::load(&dir, self.events.clone()).ok().map(|s| s.summary()))?
    }

    /// The archive's index, read from archive.json the first time, or rebuilt from the folders when that's missing or
    /// older than the archive (a zerod that kept none put something away).
    fn archive_index<T>(&self, then: impl FnOnce(&mut Vec<Archived>) -> T) -> T {
        then(self.archive_index.lock().unwrap().get_or_insert_with(|| {
            let (file, archive) = (self.home.join(INDEX), self.home.join("archive"));
            let modified = |path: &Path| std::fs::metadata(path).and_then(|m| m.modified()).ok();
            let fresh = modified(&file).is_some_and(|kept| modified(&archive).is_none_or(|changed| kept >= changed));
            if fresh && let Some(index) = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()) {
                return index;
            }
            let index: Vec<Archived> =
                std::fs::read_dir(&archive).into_iter().flatten().flatten().filter_map(|e| Archived::of(&e.path())).collect();
            write_index(&self.home, &index);
            index
        }))
    }

    /// Reads one archived folder into the index again (gone, it leaves it), and keeps the index.
    fn reindex(&self, id: &str) {
        self.archive_index(|index| {
            index.retain(|a| a.id != id);
            index.extend(Archived::of(&self.home.join("archive").join(id)));
            write_index(&self.home, index);
        })
    }

    /// Stops the process of every session idle for PARK_AFTER with nothing waiting for it.
    pub(super) fn park(&self) {
        let pending = self.pending.lock().unwrap().clone();
        for session in self.sessions() {
            if session.unwanted_for().is_some_and(|unwanted| unwanted >= UNLOAD_AFTER) {
                session.unload();
            }
            if !session.is_loaded() {
                continue;
            }
            let conversation = session.summary();
            if let Some(open) = conversation.terminal {
                let (Some(daemon), id) = (self.me.upgrade(), conversation.id.clone()) else { continue };
                tokio::spawn(async move {
                    if daemon.host().idle(&open.id).await.is_some_and(|idle| idle >= TERMINAL_PARK_AFTER)
                        && let Err(error) = daemon.close_terminal(&id).await
                    {
                        eprintln!("zerod: couldn't close {id}'s idle terminal: {error}")
                    }
                });
                continue;
            }
            if pending.get(&conversation.id).is_some_and(|words| !words.is_empty()) {
                continue;
            }
            if session.idle_for().is_some_and(|idle| idle >= PARK_AFTER) {
                session.stop()
            }
        }
    }
}

/// When something's archived, in milliseconds, never the same twice: two put away in one millisecond still list in
/// the order they went.
fn archived_at() -> i64 {
    static LAST: AtomicI64 = AtomicI64::new(0);
    let now = now_ms();
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
pub(super) fn archived_with(dir: &Path) -> Option<String> {
    marker(dir).and_then(|m| m["with"].as_str().map(String::from))
}

const INDEX: &str = "archive.json";

/// An archived task as the index keeps it.
#[derive(serde::Serialize, serde::Deserialize)]
pub(super) struct Archived {
    id: String,
    task: String,
    at: i64,
    workspace: Option<String>,
    parent: Option<String>,
    /// The lead it went with; none, it was put away itself.
    with: Option<String>,
}

impl Archived {
    fn of(dir: &Path) -> Option<Archived> {
        let meta: serde_json::Value = serde_json::from_slice(&std::fs::read(dir.join("meta.json")).ok()?).ok()?;
        let id = dir.file_name()?.to_string_lossy().to_string();
        let kept = marker(dir);
        let field = |key: &str| kept.as_ref().and_then(|m| m[key].as_str().map(String::from));
        Some(Archived {
            task: field("task").or_else(|| parked_label(dir)).unwrap_or_else(|| id.clone()),
            at: kept.as_ref().and_then(|m| m["at"].as_i64()).unwrap_or_else(|| modified_ms(dir)),
            workspace: field("workspace"),
            with: field("with"),
            parent: meta["parent"].as_str().map(String::from),
            id,
        })
    }
}

/// Written whole, through a file beside it: read half-written, it would be rebuilt rather than trusted.
fn write_index(home: &Path, index: &[Archived]) {
    let (file, partial) = (home.join(INDEX), home.join("archive.json.partial"));
    if std::fs::write(&partial, serde_json::to_vec(index).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&partial, &file);
    }
}

fn modified_ms(path: &Path) -> i64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// An archived task's name from its parked summary (archived before archive markers were kept).
fn parked_label(dir: &Path) -> Option<String> {
    let parked: serde_json::Value = serde_json::from_slice(&std::fs::read(dir.join("parked.json")).ok()?).ok()?;
    let summary: Conversation = serde_json::from_value(parked["summary"].clone()).ok()?;
    Some(crate::bridge::label(&summary))
}
