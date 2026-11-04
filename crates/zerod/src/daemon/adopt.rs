//! Taking sessions in: one started elsewhere (Claude Code's, Codex's, OpenCode's) as a task, a task as a lead's
//! worker, a worker let go as a task of its own.

use super::*;

impl Daemon {
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
        self.take_in(conversation, crate::handoff::from_claude_session(&records), options)
    }

    /// A session started outside Zero, by its id alone (Claude Code's, Codex's or OpenCode's), taken in as a task
    /// where it ran, with its history: offline, not opened, until a message resumes it on its own thread.
    pub fn migrate(&self, thread: &str, options: Options) -> Result<String, String> {
        if let Some(known) = self.sessions().iter().map(|s| s.summary()).find(|c| c.thread.as_deref() == Some(thread)) { return Ok(known.id) }
        let user = self.user_home();
        let claude = std::fs::read_dir(user.join(".claude/projects")).into_iter().flatten().flatten()
            .map(|e| e.path().join(format!("{thread}.jsonl"))).find(|f| f.is_file());
        if let Some(file) = claude {
            let cwd = claude_cwd(&file).ok_or_else(|| format!("Claude Code session {thread} doesn't say its folder"))?;
            return self.adopt(Provider::Claude, thread, &cwd, options);
        }
        let (provider, (cwd, items)) = if let Some(file) = rollout(&user.join(".codex/sessions"), thread) {
            let text = std::fs::read_to_string(&file).map_err(|e| e.to_string())?;
            let records: Vec<serde_json::Value> = text.lines().filter_map(|line| serde_json::from_str(line).ok()).collect();
            (Provider::Codex, crate::handoff::from_codex_rollout(&records).ok_or_else(|| format!("Codex session {thread} doesn't say its folder"))?)
        } else if thread.starts_with("ses_") {
            // ponytail: waits on OpenCode's export (a second or two) in the caller's thread; spawn it if that matters.
            let argv = crate::adapter::login_shell(&["opencode", "session", "export", thread]);
            let printed = std::process::Command::new(&argv[0]).args(&argv[1..]).current_dir(&user).output().map_err(|e| format!("OpenCode didn't run: {e}"))?;
            let text = String::from_utf8_lossy(&printed.stdout);
            let export: serde_json::Value = text.find('{').and_then(|at| serde_json::from_str(&text[at..]).ok())
                .ok_or_else(|| format!("No Claude Code, Codex or OpenCode session {thread}"))?;
            (Provider::Opencode, crate::handoff::from_opencode_export(&export).ok_or_else(|| format!("OpenCode session {thread} doesn't say its folder"))?)
        } else {
            return Err(format!("No Claude Code, Codex or OpenCode session {thread}"));
        };
        if !Path::new(&cwd).is_dir() { return Err(format!("{cwd} isn't a folder any more")) }
        let mut conversation = Conversation::new(&new_id(), provider, &cwd);
        conversation.thread = Some(thread.into());
        conversation.permissions = options.permissions.unwrap_or_default();
        conversation.branch = branch(Path::new(&cwd));
        self.take_in(conversation, items, options)
    }

    /// A conversation from elsewhere, with its history, kept as a task: offline until a message resumes it.
    fn take_in(&self, conversation: Conversation, items: Vec<crate::model::Item>, options: Options) -> Result<String, String> {
        let id = conversation.id.clone();
        let session = Session::new(conversation, Some(self.home.join("sessions").join(&id)), self.events.clone()).map_err(|e| e.to_string())?;
        session.change(Change::Status { status: Status::Offline, turn: None, error: None });
        for item in items { session.change(Change::Item { item }) }
        if options.label.is_some() || options.ticket.is_some() { session.change(Change::Named { label: options.label, ticket: options.ticket }) }
        self.attention.lock().unwrap().insert(id.clone(), Attention::Offline);
        self.sessions.lock().unwrap().push(session.clone());
        session.announce();
        if let Some(workspace) = options.workspace.as_deref() { self.place_in_workspace(&id, Some(workspace))? }
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

    /// A worker let go of its lead: a task of its own (a lead itself), by its id or its session's. Its lead isn't told
    /// of it any more.
    pub fn detach(&self, target: &str) -> Result<(), String> {
        let id = self.sessions().iter().map(|s| s.summary()).find(|c| c.id == target || c.thread.as_deref() == Some(target)).map(|c| c.id)
            .ok_or_else(|| format!("No task {target}"))?;
        let session = self.session(&id)?;
        if session.summary().parent.is_some() { session.change(Change::Parent { parent: None }) }
        Ok(())
    }

    pub(super) fn claude_file(&self, conversation: &Conversation) -> PathBuf {
        crate::handoff::claude_folder(&self.user_home(), &conversation.cwd).join(format!("{}.jsonl", conversation.thread.as_deref().unwrap_or("")))
    }
}

/// The folder a Claude Code session ran in, from the first of its records that says.
/// Codex's rollout file for a thread, under its sessions' year/month/day folders: `rollout-<time>-<thread>.jsonl`.
fn rollout(folder: &Path, thread: &str) -> Option<PathBuf> {
    let suffix = format!("-{thread}.jsonl");
    for entry in std::fs::read_dir(folder).ok()?.flatten() {
        let path = entry.path();
        if path.is_dir() { if let Some(found) = rollout(&path, thread) { return Some(found) } }
        else if path.file_name().is_some_and(|n| n.to_string_lossy().ends_with(&suffix)) { return Some(path) }
    }
    None
}

fn claude_cwd(file: &Path) -> Option<String> {
    use std::io::BufRead;
    std::io::BufReader::new(std::fs::File::open(file).ok()?).lines().map_while(Result::ok)
        .find_map(|line| serde_json::from_str::<serde_json::Value>(&line).ok()?["cwd"].as_str().map(String::from))
}
