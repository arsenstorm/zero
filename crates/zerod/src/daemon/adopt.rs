//! Taking sessions in: one started elsewhere (Claude Code's, Codex's, OpenCode's) as a task, a task as a lead's
//! worker, a worker let go as a task of its own.

use super::*;

impl Daemon {
    /// A session started elsewhere (Claude Code's, by its id) taken in as a task in `cwd`: its history read from the
    /// session file, offline until a message resumes it on the same thread. The same session twice is the one task.
    pub fn adopt(&self, provider: Provider, thread: &str, cwd: &str, options: Options) -> Result<String, String> {
        if provider != Provider::Claude {
            return Err(format!("{} sessions can't be taken in yet", provider.title()));
        }
        if !Path::new(cwd).is_dir() {
            return Err(format!("{cwd} isn't a folder"));
        }
        if let Some(known) = self.sessions().iter().map(|s| s.summary()).find(|c| c.thread.as_deref() == Some(thread)) {
            return Ok(known.id);
        }
        let id = new_id();
        let mut conversation = Conversation::new(&id, provider, cwd);
        conversation.thread = Some(thread.into());
        conversation.permissions = options.permissions.unwrap_or_default();
        conversation.branch = branch(Path::new(cwd));
        let text =
            std::fs::read_to_string(self.claude_file(&conversation)).map_err(|_| format!("No Claude Code session {thread} in {cwd}"))?;
        let records: Vec<serde_json::Value> = text.lines().filter_map(|line| serde_json::from_str(line).ok()).collect();
        self.take_in(conversation, crate::handoff::from_claude_session(&records), options)
    }

    /// A session started outside Zero, by its id alone (Claude Code's, Codex's or OpenCode's), taken in as a task
    /// where it ran, with its history: offline, not opened, until a message resumes it on its own thread.
    pub fn migrate(&self, thread: &str, options: Options) -> Result<String, String> {
        if let Some(known) = self.sessions().iter().map(|s| s.summary()).find(|c| c.thread.as_deref() == Some(thread)) {
            return Ok(known.id);
        }
        let user = self.user_home();
        let claude = std::fs::read_dir(user.join(".claude/projects"))
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path().join(format!("{thread}.jsonl")))
            .find(|f| f.is_file());
        if let Some(file) = claude {
            let cwd = claude_cwd(&file).ok_or_else(|| format!("Claude Code session {thread} doesn't say its folder"))?;
            return self.adopt(Provider::Claude, thread, &cwd, options);
        }
        let (provider, (cwd, items)) = if let Some(file) = rollout(&user.join(".codex/sessions"), thread) {
            let text = std::fs::read_to_string(&file).map_err(|e| e.to_string())?;
            let records: Vec<serde_json::Value> = text.lines().filter_map(|line| serde_json::from_str(line).ok()).collect();
            (
                Provider::Codex,
                crate::handoff::from_codex_rollout(&records).ok_or_else(|| format!("Codex session {thread} doesn't say its folder"))?,
            )
        } else if thread.starts_with("ses_") {
            // ponytail: waits on OpenCode's export (a second or two) in the caller's thread; spawn it if that matters.
            let argv = crate::adapter::login_shell(&["opencode", "session", "export", thread]);
            let printed = std::process::Command::new(&argv[0])
                .args(&argv[1..])
                .current_dir(&user)
                .output()
                .map_err(|e| format!("OpenCode didn't run: {e}"))?;
            let text = String::from_utf8_lossy(&printed.stdout);
            let export: serde_json::Value = text
                .find('{')
                .and_then(|at| serde_json::from_str(&text[at..]).ok())
                .ok_or_else(|| format!("No Claude Code, Codex or OpenCode session {thread}"))?;
            (
                Provider::Opencode,
                crate::handoff::from_opencode_export(&export).ok_or_else(|| format!("OpenCode session {thread} doesn't say its folder"))?,
            )
        } else {
            return Err(format!("No Claude Code, Codex or OpenCode session {thread}"));
        };
        if !Path::new(&cwd).is_dir() {
            return Err(format!("{cwd} isn't a folder any more"));
        }
        let mut conversation = Conversation::new(&new_id(), provider, &cwd);
        conversation.thread = Some(thread.into());
        conversation.permissions = options.permissions.unwrap_or_default();
        conversation.branch = branch(Path::new(&cwd));
        self.take_in(conversation, items, options)
    }

    /// A conversation from elsewhere, with its history, kept as a task: offline until a message resumes it.
    fn take_in(&self, conversation: Conversation, items: Vec<crate::model::Item>, options: Options) -> Result<String, String> {
        let id = conversation.id.clone();
        let session =
            Session::new(conversation, Some(self.home.join("sessions").join(&id)), self.events.clone()).map_err(|e| e.to_string())?;
        session.change(Change::Status { status: Status::Offline, turn: None, error: None });
        for item in items {
            session.change(Change::Item { item })
        }
        if options.label.is_some() || options.ticket.is_some() {
            session.change(Change::Named { label: options.label, ticket: options.ticket })
        }
        self.attention.lock().unwrap().insert(id.clone(), Attention::Offline);
        self.sessions.lock().unwrap().push(session.clone());
        session.announce();
        if let Some(workspace) = options.workspace.as_deref() {
            self.place_in_workspace(&id, Some(workspace))?
        }
        Ok(id)
    }

    /// `target` made a worker of `lead` (`zero adopt`, by the lead): a task Zero has (by its id, or its Claude Code
    /// session's), else a Claude Code session taken in first, found by its id in any folder. Not the lead itself, nor
    /// anything above it. `by`, the task running it: the lead itself, or one above it. Told as the user's move is
    /// (set_parent).
    pub fn adopt_into(&self, lead: &str, target: &str, by: &str) -> Result<String, String> {
        self.session(lead)?;
        // Before a session from outside is taken in for it.
        self.in_own_tree(by, lead)?;
        let id = match self.find(target) {
            Ok(id) => id,
            Err(_) => {
                let file = std::fs::read_dir(self.user_home().join(".claude/projects"))
                    .map_err(|e| e.to_string())?
                    .filter_map(|e| e.ok().map(|e| e.path().join(format!("{target}.jsonl"))))
                    .find(|f| f.is_file())
                    .ok_or_else(|| format!("No task or Claude Code session {target}"))?;
                let cwd = claude_cwd(&file).ok_or_else(|| format!("Claude Code session {target} doesn't say its folder"))?;
                self.adopt(Provider::Claude, target, &cwd, Options::default())?
            }
        };
        self.set_parent(&id, Some(lead), Some(by))?;
        Ok(id)
    }

    /// A worker let go of its lead (`zero detach`, by `by`): a task of its own (a lead itself), by its id or its
    /// session's. Told as the user's move is (set_parent).
    pub fn detach(&self, target: &str, by: Option<&str>) -> Result<(), String> {
        self.set_parent(&self.find(target)?, None, by)
    }

    /// A task by its id or its session's.
    fn find(&self, target: &str) -> Result<String, String> {
        self.sessions()
            .iter()
            .map(|s| s.summary())
            .find(|c| c.id == target || c.thread.as_deref() == Some(target))
            .map(|c| c.id)
            .ok_or_else(|| format!("No task {target}"))
    }

    /// Whether `actor` may put a task under `lead`: the lead is it, or one of its workers (any way down).
    fn in_own_tree(&self, actor: &str, lead: &str) -> Result<(), String> {
        let mut above = self.get(lead);
        while let Some(conversation) = above {
            if conversation.id == actor {
                return Ok(());
            }
            above = conversation.parent.and_then(|parent| self.get(&parent));
        }
        let name = self.get(lead).map_or_else(|| lead.to_string(), |c| crate::bridge::label(&c));
        Err(format!(
            "{name} isn't you or one of your workers: a task adopts only into its own tree; the user can move any task from its menu"
        ))
    }

    /// Whether `id` may be `lead`'s worker: not the lead itself, nor anything above it.
    fn no_loop(&self, id: &str, lead: &str) -> Result<(), String> {
        let mut above = Some(self.session(lead)?.summary());
        while let Some(conversation) = above {
            if conversation.id == id {
                return Err(format!("{id} leads {lead}; it can't be its worker"));
            }
            above = conversation.parent.and_then(|parent| self.session(&parent).ok()).map(|s| s.summary());
        }
        Ok(())
    }

    /// `id` put under `lead` as its worker, in the lead's workspace with its own workers, or with none a task of its
    /// own: the user's move (the task menu, `by` none) or a task's (`zero adopt`, `zero detach`). Its reports follow
    /// its lead (heard). The new lead is told it has a worker and where it stands; the worker who it answers to now. A
    /// lead it leaves gets a quiet line, or is told if it was waiting on it, so it isn't left waiting on a report that
    /// won't come. The task that made the move isn't told what it did.
    pub fn set_parent(&self, id: &str, lead: Option<&str>, by: Option<&str>) -> Result<(), String> {
        let task = self.session(id)?.summary();
        if task.parent.as_deref() == lead {
            return Ok(());
        }
        // A task's own move stays in its tree: its own workers let go; a task of its own (no lead) taken in.
        if let Some(actor) = by {
            let name = crate::bridge::label(&task);
            match lead {
                None if task.parent.as_deref() != Some(actor) => {
                    return Err(format!(
                        "{name} isn't your worker: a task detaches only its own workers; the user can move any task from its menu"
                    ));
                }
                None => {}
                Some(lead) => {
                    self.in_own_tree(actor, lead)?;
                    if task.parent.is_some() {
                        return Err(format!(
                            "{name} has a lead already: a task adopts only a task of its own (no lead) or a session from outside Zero"
                        ));
                    }
                }
            }
        }
        let new_lead = lead.map(|lead| self.no_loop(id, lead).and_then(|_| self.session(lead)).map(|s| s.summary())).transpose()?;
        let name = crate::bridge::label(&task);
        let (who, who_said) = match by.and_then(|by| self.get(by)) {
            Some(actor) => (crate::bridge::label(&actor), crate::bridge::label(&actor)),
            None => ("the user".to_string(), "The user".to_string()),
        };
        let did = |session: &str| by == Some(session);
        let old_lead = task.parent.as_deref().and_then(|old| self.get(old));
        let old_name = old_lead.as_ref().map_or_else(|| "its lead".into(), crate::bridge::label);
        let waited_on = old_lead.as_ref().is_some_and(|old| {
            !did(&old.id) && matches!(old.attention(), Attention::Working | Attention::Starting | Attention::Blocked) && !self.finished(id)
        });
        // The workspace its lead's tree shows in (its top lead's, as the board has it), its own workers with it,
        // before anything is told.
        if let Some(new_lead) = &new_lead {
            let mut top = new_lead.clone();
            while let Some(up) = top.parent.as_deref().and_then(|p| self.session(p).ok()).map(|s| s.summary()) {
                top = up
            }
            let shown = self.workspace_of(&top);
            let placed = (shown != crate::workspaces::DEFAULT).then_some(shown.as_str());
            let mut tree = vec![id.to_string()];
            while let Some(next) = tree.pop() {
                if self.get(&next).is_some_and(|c| self.workspace_of(&c) != shown) {
                    self.place_in_workspace(&next, placed)?;
                }
                tree.extend(self.workers(&next).into_iter().map(|w| w.id));
            }
        }
        self.session(id)?.change(Change::Parent { parent: lead.map(Into::into) });
        self.leaving.lock().unwrap().remove(id);
        self.kept_reports.lock().unwrap().remove(id);
        if let Some(old) = &old_lead {
            let words = format!("{name} was detached by {who}; it no longer reports to you.");
            if waited_on { self.tell_from_zero(&old.id, &words) } else { self.say_quietly(&old.id, &words) }
        }
        let Some(new_lead) = new_lead else {
            let gone = match &old_lead {
                Some(old) if did(&old.id) => format!("{old_name} let this task go"),
                _ => format!("{who_said} detached this task from {old_name}"),
            };
            if !did(id) {
                self.tell_from_zero(id, &format!("{gone}: it no longer reports there. {ON_YOUR_OWN}"));
            }
            return Ok(());
        };
        let stands =
            task.answer().and_then(|a| a.lines().find(|l| !l.trim().is_empty())).map(str::trim).unwrap_or("it hasn't answered yet");
        if !did(&new_lead.id) {
            self.tell_from_zero(
                &new_lead.id,
                &format!(
                    "{who_said} gave you a worker: {name} ({id}). Its reports come to you from now on. Where it stands, its last answer: {stands}"
                ),
            );
        }
        let lead_name = format!("{} ({})", crate::bridge::label(&new_lead), new_lead.id);
        let moved = if did(&new_lead.id) {
            format!("{lead_name} took this task on")
        } else {
            format!("{who_said} moved this task under {lead_name}")
        };
        if !did(id) {
            self.tell_from_zero(id, &format!("{moved}: you're its worker now, and you report to it. {WORKER_NOW}"));
        }
        Ok(())
    }

    pub(super) fn claude_file(&self, conversation: &Conversation) -> PathBuf {
        crate::handoff::claude_folder(&self.user_home(), &conversation.cwd)
            .join(format!("{}.jsonl", conversation.thread.as_deref().unwrap_or("")))
    }
}

/// The folder a Claude Code session ran in, from the first of its records that says.
/// Codex's rollout file for a thread, under its sessions' year/month/day folders: `rollout-<time>-<thread>.jsonl`.
fn rollout(folder: &Path, thread: &str) -> Option<PathBuf> {
    let suffix = format!("-{thread}.jsonl");
    for entry in std::fs::read_dir(folder).ok()?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if let Some(found) = rollout(&path, thread) {
                return Some(found);
            }
        } else if path.file_name().is_some_and(|n| n.to_string_lossy().ends_with(&suffix)) {
            return Some(path);
        }
    }
    None
}

fn claude_cwd(file: &Path) -> Option<String> {
    use std::io::BufRead;
    std::io::BufReader::new(std::fs::File::open(file).ok()?)
        .lines()
        .map_while(Result::ok)
        .find_map(|line| serde_json::from_str::<serde_json::Value>(&line).ok()?["cwd"].as_str().map(String::from))
}
