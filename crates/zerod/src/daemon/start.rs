//! Starting tasks: one of its own, or a lead's worker, checked, given its conversation, and its first turn begun.

use super::*;

impl Daemon {
    /// A session of its own (no lead) with `prompt` as its first turn; returns its id at once, while the runtime starts.
    pub fn start(&self, provider: Provider, prompt: &str, options: Options) -> Result<String, String> {
        self.create(provider, prompt, Options { parent: None, ..options })
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
        options.parent = Some(lead.to_string());
        self.create(provider, prompt, options)
    }

    fn create(&self, provider: Provider, prompt: &str, options: Options) -> Result<String, String> {
        self.check_start(provider, prompt, &options)?;
        let (model, effort) = (options.model.as_deref(), options.effort.as_deref());
        let id = new_id();
        let dir = self.home.join("sessions").join(&id);
        let conversation = self.new_conversation(&id, provider, &options)?;
        let session = Session::new(conversation.clone(), Some(dir.clone()), self.events.clone()).map_err(|e| e.to_string())?;
        session.set_mcp(conversation.mcp.clone());
        // The workspace it starts in, kept in its history as a move into it is: restarted, it's still there (only
        // memory had it, and a restart put it back in Zero).
        if conversation.workspace.is_some() {
            session.change(Change::Placed { workspace: conversation.workspace.clone() })
        }
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
        if options.label.is_some() || options.ticket.is_some() {
            session.change(Change::Named { label: options.label.clone(), ticket: options.ticket.clone() })
        }
        start_first_turn(session.clone(), transport, prompt, &options);
        // A task started without a name gets a short one from its first message: its title, which a name given to it
        // (by the user or its lead) goes before.
        if self.naming.load(Ordering::Relaxed) && provider == Provider::Claude && options.label.is_none() && options.parent.is_none() {
            let (prompt, cwd, id) = (prompt.to_string(), conversation.cwd.clone(), id.clone());
            tokio::spawn(async move {
                if let Some(name) = crate::naming::name(&prompt, &cwd, &id).await
                    && session.summary().title.is_none()
                {
                    session.change(Change::Title { title: Some(name) });
                }
            });
        }
        Ok(id)
    }

    /// New tasks get names from a small model from here on (zerod's own start; tests don't, so spend nothing).
    pub fn name_tasks(&self) {
        self.naming.store(true, Ordering::Relaxed)
    }

    /// Why a task can't start as asked: not in a folder, its provider at its usage limit (unless forced), nothing to
    /// do, or a workspace or sign-in that isn't there.
    fn check_start(&self, provider: Provider, prompt: &str, options: &Options) -> Result<(), String> {
        let cwd = options.cwd.as_deref().unwrap_or("");
        let folder = Path::new(cwd);
        if !folder.is_absolute() || !folder.is_dir() {
            return Err(format!("{cwd} isn't a folder"));
        }
        if !options.force
            && let Some((_, usage)) =
                self.usage().into_iter().find(|(p, u)| *p == provider && u.limited && u.resets_at.is_none_or(|at| at > now()))
        {
            let until = usage.resets_at.map(|at| format!(" until {}", at)).unwrap_or_default();
            return Err(format!("{} is at its usage limit{until}; start it anyway with force", provider.title()));
        }
        if prompt.trim().is_empty() && options.images.is_empty() {
            return Err("A session starts with something to do".into());
        }
        if let Some(workspace) = &options.workspace
            && !self.workspaces.exists(workspace)
        {
            return Err(format!("No workspace {workspace}"));
        }
        if let Some(signin) = &options.signin
            && self.signins.get(signin).is_none_or(|s| s.cli != provider)
        {
            return Err(format!("No {} sign-in {signin}", provider.title()));
        }
        Ok(())
    }

    /// A new task's conversation as its options say: where, with what permissions, under which lead and sign-in.
    fn new_conversation(&self, id: &str, provider: Provider, options: &Options) -> Result<Conversation, String> {
        let cwd = options.cwd.as_deref().unwrap_or("");
        let mut conversation = Conversation::new(id, provider, cwd);
        conversation.permissions = options.permissions.unwrap_or_default();
        conversation.parent = options.parent.clone();
        conversation.workspace = options.workspace.clone();
        // Chosen, else its lead's (a worker of the same CLI runs as its lead does), else the CLI's default.
        let lead = conversation
            .parent
            .as_deref()
            .and_then(|lead| self.get(lead))
            .filter(|lead| lead.provider == provider)
            .and_then(|lead| lead.signin);
        conversation.signin = options.signin.clone().or(lead).or_else(|| {
            self.signins
                .choose_for(provider, now(), None, options.model.as_deref())
                .or_else(|| self.signins.default_for(provider))
                .map(|s| s.id)
        });
        conversation.branch = branch(Path::new(cwd));
        // Claude takes its conversation's id from Zero, so the session can be resumed even if it never answered.
        if provider == Provider::Claude {
            conversation.thread = Some(claude::new_session_id())
        }
        conversation.mcp = self.mcp_for(&conversation)?;
        Ok(conversation)
    }

    /// What a session's CLI starts with: its sign-in (signins.rs) and its workspace's MCP servers, their values read
    /// (the Keychain's now). Both go in its process's environment alone: the sign-in as its CLI reads one, Claude's
    /// MCP values for its `--mcp-config` to refer to. A sign-in gone from the Keychain stops the start, said.
    pub(super) fn mcp_for(&self, conversation: &Conversation) -> Result<Vec<crate::mcp_servers::Resolved>, String> {
        let workspace = self.workspace_of(conversation);
        let mut servers: Vec<_> =
            self.mcp_servers.for_workspace(&workspace).iter().map(|s| s.resolve(&crate::mcp_servers::keychain)).collect();
        // Zero's own tools (scratchpads, the browser: `zerod mcp`), for the CLIs that don't have them from Zero's plugin
        // as Claude Code does. Told which task it serves; Codex gives a server only the variables it's given.
        if conversation.provider != Provider::Claude
            && let Ok(zerod) = std::env::current_exe()
        {
            servers.insert(
                0,
                crate::mcp_servers::Resolved {
                    id: "zero".into(),
                    name: "Zero".into(),
                    command: Some(zerod.to_string_lossy().into()),
                    args: vec!["mcp".into()],
                    url: None,
                    env: vec![("ZERO_SESSION".into(), conversation.id.clone())],
                    headers: vec![],
                },
            );
        }
        let mut env = match conversation.signin.as_deref().and_then(|id| self.signins.get(id)) {
            Some(signin) => self.signins.environment(&signin)?,
            None => vec![],
        };
        if conversation.provider == Provider::Claude {
            env.extend(claude::mcp_config(&servers).map(|(_, env)| env).unwrap_or_default())
        }
        let mut all = crate::process::SESSION_ENV.lock().unwrap();
        if env.is_empty() {
            all.remove(&conversation.id);
        } else {
            all.insert(conversation.id.clone(), env);
        }
        Ok(servers)
    }
}

/// A new task's first turn, once its folder is kept as it was before it (what rewinding to the first message brings
/// back); a turn that couldn't start is reported on the task.
fn start_first_turn(session: Session, transport: Transport, prompt: &str, options: &Options) {
    let (prompt, model, effort, images) = (prompt.to_string(), options.model.clone(), options.effort.clone(), options.images.clone());
    let (cwd, name) = (session.summary().cwd, format!("{}/{}", session.id(), now_ms()));
    tokio::spawn(async move {
        let kept = tokio::task::spawn_blocking(move || crate::snapshots::take(Path::new(&cwd), &name)).await.ok().flatten();
        match session
            .start(
                transport,
                Message { text: &prompt, images: &images, context: None },
                ModelChoice { model: model.as_deref(), effort: effort.as_deref() },
            )
            .await
        {
            Ok(()) => {
                if let Some(commit) = kept {
                    attach_snapshot(&session, commit)
                }
            }
            Err(error) => session.report(&error),
        }
    });
}
