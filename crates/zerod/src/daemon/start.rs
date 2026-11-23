//! Starting tasks: one of its own, or a lead's worker, checked, given its conversation, and its first turn begun.

use super::*;
use serde_json::{Value, json};

impl Daemon {
    /// A session of its own (no lead) with `prompt` as its first turn; returns its id at once, while the runtime starts.
    pub fn start(&self, provider: Provider, prompt: &str, options: Options) -> Result<String, String> {
        self.create(provider, prompt, Options { parent: None, ..options })
    }

    /// A worker of `lead`: in the lead's folder, with the lead's permissions, unless told otherwise.
    pub fn spawn(&self, lead: &str, provider: Provider, prompt: &str, options: Options) -> Result<String, String> {
        self.spawn_as(lead, provider, prompt, options, false)
    }

    /// A worker of `lead`, on its folder, mode, model and workspace unless told otherwise; `own`, the same but a task of
    /// its own beside it (a lead for each of a list of issues), whose end the session isn't told of.
    pub fn spawn_as(&self, lead: &str, provider: Provider, prompt: &str, mut options: Options, own: bool) -> Result<String, String> {
        let parent = self.get(lead).ok_or_else(|| format!("No session {lead} to lead it"))?;
        options.cwd = options.cwd.or(Some(parent.cwd.clone()));
        options.permissions = options.permissions.or(Some(parent.permissions));
        // On its lead's model unless told otherwise: left to itself, the provider would start it on its own default.
        if provider == parent.provider {
            options.model = options.model.or(parent.model.clone());
            options.effort = options.effort.or(parent.effort.clone());
            options.advisor = options.advisor.or(parent.advisor.clone());
        }
        // The lead decides: its worker is in its workspace wherever the worker's folder is.
        options.workspace = options.workspace.or_else(|| Some(self.workspace_of(&parent)));
        options.parent = (!own).then(|| lead.to_string());
        self.create(provider, prompt, options)
    }

    fn create(&self, provider: Provider, prompt: &str, mut options: Options) -> Result<String, String> {
        // No folder given: a new one of its own, made only once nothing else refuses it.
        let made = options.cwd.is_none();
        if made {
            options.cwd = Some(self.user_home().join("Zero").to_string_lossy().into_owned());
        }
        self.check_start(provider, prompt, &options, made)?;
        if made {
            let folder = new_folder(&self.user_home().join("Zero"), prompt).map_err(|e| format!("No folder for it in ~/Zero: {e}"))?;
            options.cwd = Some(folder.to_string_lossy().into_owned());
        }
        let (model, effort) = (options.model.as_deref(), options.effort.as_deref());
        let id = new_id();
        let dir = self.home.join("sessions").join(&id);
        let conversation = self.new_conversation(&id, provider, &options)?;
        let session = Session::new(conversation.clone(), Some(dir.clone()), self.events.clone()).map_err(|e| e.to_string())?;
        session.prepare(&conversation);
        // The workspace it starts in, kept in its history as a move into it is: restarted, it's still there (only
        // memory had it, and a restart put it back in Zero).
        if conversation.workspace.is_some() {
            session.change(Change::Placed { workspace: conversation.workspace.clone() })
        }
        if conversation.advisor.is_some() {
            session.change(Change::Advised { advisor: conversation.advisor.clone() })
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
                // Its own new folder held nothing but an empty repo.
                if made {
                    let _ = std::fs::remove_dir_all(&conversation.cwd);
                }
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
                // A busy Mac (a Gatekeeper scan once held every process start) can keep the small model past its
                // minute, and the task kept its first five words for a name: asked again, three times in all.
                for attempt in 0..3 {
                    if attempt > 0 {
                        tokio::time::sleep(std::time::Duration::from_secs(30)).await
                    }
                    if session.summary().title.is_some() {
                        return;
                    }
                    if let Some(name) = crate::naming::name(&prompt, &cwd, &id).await {
                        if session.summary().title.is_none() {
                            session.change(Change::Title { title: Some(name) });
                        }
                        return;
                    }
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
    fn check_start(&self, provider: Provider, prompt: &str, options: &Options, new_folder: bool) -> Result<(), String> {
        let cwd = options.cwd.as_deref().unwrap_or("");
        let folder = Path::new(cwd);
        if !new_folder && (!folder.is_absolute() || !folder.is_dir()) {
            return Err(format!("{cwd} isn't a folder"));
        }
        // The limit a task last reported is its own account's: with another account free (or one asked for), the
        // new task starts as that one (new_conversation), so only a CLI with none free is refused.
        let free = options.signin.is_some() || self.signins.choose_for(provider, now(), None, options.model.as_deref()).is_some();
        if !options.force
            && !free
            && let Some((_, usage)) =
                self.usage().into_iter().find(|(p, u)| *p == provider && u.limited && u.resets_at.is_none_or(|at| at > now()))
        {
            let left = usage.resets_at.map(|at| format!(" for {}", span(at - now()))).unwrap_or_default();
            return Err(format!("{} is at its usage limit{left}", provider.title()));
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
        conversation.advisor = options.advisor.clone();
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
        conversation.plain_answers = self.plain_answers(&conversation);
        Ok(conversation)
    }

    /// Whether a task's CLI is told the answer rules: unless the user turned them off, for all tasks or its workspace.
    pub(super) fn plain_answers(&self, conversation: &Conversation) -> bool {
        let workspace = self.workspace_of(conversation);
        crate::server::Settings::load(&self.home).plain_answers()
            && self.workspaces.list().iter().find(|w| w.id == workspace).is_none_or(|w| w.plain_answers != Some(false))
    }

    /// Every running task given its workspace's MCP servers as they are now (a server saved, changed or deleted): see
    /// `push_mcp`. Each on its own, so a Codex waiting out its turn holds up no one.
    pub fn push_mcp_everywhere(self: &Arc<Self>) {
        for session in self.sessions().into_iter().filter(Session::is_attached) {
            let (me, id) = (self.clone(), session.id().to_string());
            tokio::spawn(async move {
                if let Err(error) = me.push_mcp(&id).await {
                    eprintln!("zerod: couldn't give {id} its MCP servers: {error}")
                }
            });
        }
    }

    /// An MCP server the user approved on an agent's ask (`zero mcp add`): kept, given to the asking task (`asker`)
    /// and every other running task it's for, and what the asker is told of it.
    pub async fn apply_mcp(self: &Arc<Self>, server: crate::mcp_servers::McpServer, asker: Option<&str>) -> Result<String, String> {
        let saved = self.mcp_servers.save(server)?;
        self.mcp_changed(&saved.id);
        let kept = format!("Zero keeps the MCP server {} ({}).", saved.id, saved.describe());
        let waits = self.mcp_waits(&saved).await;
        let told = match (asker, self.session(asker.unwrap_or_default())) {
            (Some(_), Ok(session)) if waits => {
                session.change(Change::McpSignIn { server: saved.id.clone(), connector: false });
                "It needs signing in: Zero asks the user to, and it's in this task's tools once they have.".into()
            }
            (Some(id), _) => self.given(id, &saved.id).await,
            (None, _) => String::new(),
        };
        self.push_mcp_everywhere();
        Ok(format!("{kept} {told}").trim_end().to_string())
    }

    /// A server a Claude task says needs signing in that is its CLI's own: kept as Zero's when Zero can sign in to it
    /// itself (`mcp_servers::adoptable`, and `mcp_zero_signs_in`), so one sign-in serves every task and account. Zero's
    /// copy takes the place of the CLI's in every task once signed in. One Zero keeps at that URL for other workspaces
    /// is widened to this task's.
    pub async fn adopt_mcp(self: &Arc<Self>, id: &str, server: &str) {
        let (Ok(session), Some(tokens)) = (self.session(id), self.integrations.get()) else { return };
        let conversation = session.summary();
        let workspace = self.workspace_of(&conversation);
        let kept = self.mcp_servers.list().into_iter().find(|s| s.id == server);
        let covered = kept.as_ref().is_some_and(|s| !s.enabled || s.workspaces.is_empty() || s.workspaces.contains(&workspace));
        if conversation.provider != Provider::Claude
            || !session.is_attached()
            || covered
            || (kept.is_none() && self.mcp_auth.under_way(server))
        {
            return;
        }
        let listed = tokio::time::timeout(std::time::Duration::from_secs(10), claude_status(&session)).await.unwrap_or_default();
        let Some(adopted) = listed.iter().find(|s| s["name"] == server).and_then(|s| crate::mcp_servers::adoptable(s, &workspace)) else {
            return;
        };
        let url = adopted.url.clone().unwrap_or_default();
        if let Some(mut kept) = kept {
            // ponytail: one of this name at another URL stays the CLI's own here; a server per URL if that's ever seen.
            if kept.url.as_deref() == Some(&url) {
                kept.workspaces = if adopted.workspaces.is_empty() { vec![] } else { [kept.workspaces, adopted.workspaces].concat() };
                if self.mcp_servers.save(kept).is_ok() {
                    self.push_mcp_everywhere()
                }
            }
            return;
        }
        if self.mcp_auth.declined(&url) {
            return;
        }
        if !tokens.mcp_zero_signs_in(&url).await {
            return self.mcp_auth.decline(&url);
        }
        let Ok(saved) = self.mcp_servers.save(adopted) else { return };
        tokens.mcp_waiting(&saved.id, &url);
        self.mcp_changed(&saved.id);
    }

    /// Whether Zero has a token for a server it keeps, for its URL.
    pub fn mcp_signed_in(&self, id: &str) -> bool {
        let (Some(tokens), Some(url)) =
            (self.integrations.get(), self.mcp_servers.list().into_iter().find(|s| s.id == id).and_then(|s| s.url))
        else {
            return false;
        };
        tokens.mcp_access(id, &url).is_some_and(|access| access.is_some())
    }

    /// A server's config changed: no stale "needs signing in" (Claude's cache in every home, this zerod's ended
    /// sign-ins) hides the new one.
    pub fn mcp_changed(&self, id: &str) {
        crate::mcp_servers::clear_needs_auth(&self.home().join("claude-homes"), id);
        self.mcp_auth.forget(id);
    }

    /// Whether a server waits for the user to sign in to it with Zero (asked of it once per URL): until then tasks
    /// aren't given it.
    pub async fn mcp_waits(&self, server: &crate::mcp_servers::McpServer) -> bool {
        let (Some(url), Some(tokens)) = (&server.url, self.integrations.get()) else { return false };
        if server.headers.iter().any(|h| h.name.eq_ignore_ascii_case("authorization")) {
            return false;
        }
        match tokens.mcp_access(&server.id, url) {
            Some(access) => access.is_none(),
            None if tokens.mcp_needs_sign_in(url).await => {
                tokens.mcp_waiting(&server.id, url);
                true
            }
            None => false,
        }
    }

    /// Whether a running task has a local server that changed since it was given (a new build, or the user's Reload):
    /// read from the files alone, so it's cheap before every message.
    pub fn mcp_stale(&self, session: &Session) -> bool {
        session.mcp().iter().any(|server| {
            let given = server.env.iter().find(|(name, _)| name == crate::mcp_servers::STAMP).map(|(_, stamp)| stamp.clone());
            given.is_some() && given != self.mcp_servers.stamp(server)
        })
    }

    /// What a task is told of a server it was just given: its tools, or why it has none yet.
    async fn given(&self, id: &str, server: &str) -> String {
        let Ok(session) = self.session(id) else { return String::new() };
        let conversation = session.summary();
        if let Err(error) = self.push_mcp(id).await {
            return format!("It didn't reach this task: {error}.");
        }
        if !self.mcp_for(&conversation).is_ok_and(|s| s.iter().any(|s| s.id == server)) {
            return "It isn't for this task's workspace, so this task doesn't have it.".into();
        }
        match conversation.provider {
            Provider::Codex => "Codex takes MCP servers only as it starts: Zero starts this task again with it at its next turn, \
                                so its tools are yours from the message that brings you this."
                .into(),
            Provider::Opencode => format!("It's in this task's tools now, as {server}_<tool>."),
            Provider::Claude if !session.is_attached() => "This task has it when it next starts.".into(),
            Provider::Claude => {
                let listed = claude_status(&session).await.into_iter().find(|s| s["name"] == server);
                let Some(listed) = listed else { return "It's in this task's MCP servers now.".into() };
                match listed["status"].as_str().unwrap_or_default() {
                    "connected" => {
                        let tools: Vec<String> = listed["tools"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|t| t["name"].as_str())
                            .map(|t| format!("mcp__{server}__{t}"))
                            .collect();
                        if tools.is_empty() {
                            "It's connected, and lists no tools.".into()
                        } else {
                            format!("Its tools are yours now: {}.", tools.join(", "))
                        }
                    }
                    "needs-auth" => "It needs signing in: Zero asks the user to, and it connects once they have.".into(),
                    other => {
                        format!("It didn't connect ({other}){}.", listed["error"].as_str().map(|e| format!(": {e}")).unwrap_or_default())
                    }
                }
            }
        }
    }

    /// A running task's CLI given its workspace's MCP servers as they are now, if they changed: Claude Code and
    /// OpenCode take the whole list mid-session (a server given as before keeps running); Codex can't, so its process
    /// stops once its turn is over, and its next message starts it again with them. True if they changed.
    pub async fn push_mcp(&self, id: &str) -> Result<bool, String> {
        let session = self.session(id)?;
        let conversation = session.summary();
        if !session.is_attached() {
            return Ok(false);
        }
        let servers = self.mcp_for(&conversation)?;
        if servers == session.mcp() {
            return Ok(false);
        }
        match conversation.provider {
            Provider::Claude => {
                let list = claude::mcp_servers(&servers);
                let answer = session
                    .request(|id| json!({"type": "control_request", "request_id": id, "request": {"subtype": "mcp_set_servers", "servers": list}}))
                    .await?;
                if let Some(errors) = answer["errors"].as_object().filter(|e| !e.is_empty()) {
                    eprintln!("zerod: {id}'s Claude Code couldn't take some MCP servers: {}", Value::Object(errors.clone()))
                }
                // A server given mid-session that needs signing in says so only here, never on its own.
                for listed in claude_status(&session).await {
                    if listed["status"] == "needs-auth"
                        && let Some(name) = listed["name"].as_str().filter(|n| servers.iter().any(|s| s.id == *n))
                    {
                        session.change(Change::McpSignIn { server: name.into(), connector: false });
                    }
                }
            }
            Provider::Opencode => {
                let thread = conversation.thread.clone().ok_or("OpenCode has no session yet")?;
                let params = json!({"sessionId": thread, "cwd": conversation.cwd, "mcpServers": crate::acp::mcp_servers(&servers)});
                session.request(|id| json!({"jsonrpc": "2.0", "id": id, "method": "session/resume", "params": params})).await?;
            }
            Provider::Codex => {
                let mut events = self.subscribe();
                while self.summary(id).is_some_and(|c| c.turn.is_some()) {
                    if let Err(broadcast::error::RecvError::Closed) = events.recv().await {
                        return Ok(false);
                    }
                }
                // Its turn may have ended in a stop, or a newer push already taken it offline with the same list.
                if !session.is_attached() || self.mcp_for(&self.summary(id).unwrap_or(conversation))? == session.mcp() {
                    return Ok(false);
                }
                // ponytail: a message that starts a turn between this check and the stop is cut short; a lock on the
                // session's sends would close it if that's ever seen.
                self.take_offline(&session).await;
                return Ok(true);
            }
        }
        session.set_mcp(servers);
        Ok(true)
    }

    /// What a session's CLI starts with: its sign-in (signins.rs) and its workspace's MCP servers, their values read
    /// (the Keychain's now). Both go in its process's environment alone: the sign-in as its CLI reads one, Claude's
    /// MCP values for its `--mcp-config` to refer to. A sign-in gone from the Keychain stops the start, said.
    pub(super) fn mcp_for(&self, conversation: &Conversation) -> Result<Vec<crate::mcp_servers::Resolved>, String> {
        let workspace = self.workspace_of(conversation);
        let mut servers: Vec<_> =
            self.mcp_servers.for_workspace(&workspace).iter().map(|s| s.resolve(&crate::mcp_servers::keychain)).collect();
        for server in &mut servers {
            if let Some(stamp) = self.mcp_servers.stamp(server) {
                server.env.push((crate::mcp_servers::STAMP.into(), stamp))
            }
        }
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
        // Zero's sign-ins: a server's token as its header, for the URL it was made for; one waiting for the user left
        // out until it's made.
        if let Some(tokens) = self.integrations.get() {
            servers.retain_mut(|server| {
                let Some(url) = server.url.clone().filter(|_| !server.headers.iter().any(|(n, _)| n.eq_ignore_ascii_case("authorization")))
                else {
                    return true;
                };
                match tokens.mcp_access(&server.id, &url) {
                    Some(Some(token)) => server.headers.push(("Authorization".into(), format!("Bearer {token}"))),
                    Some(None) => return false,
                    None => {}
                }
                true
            });
        }
        let mut env = match conversation.signin.as_deref().and_then(|id| self.signins.get(id)) {
            Some(signin) => self.signins.task_environment(&signin, &servers.iter().map(|s| s.id.as_str()).collect::<Vec<_>>())?,
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
                Message { text: &prompt, images: &images, ..Default::default() },
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

/// A wait as people say it: "3 h 20 min", "12 min", "under a minute".
fn span(seconds: i64) -> String {
    let total = (seconds.max(0) + 59) / 60;
    let (hours, minutes) = (total / 60, total % 60);
    match (hours, minutes) {
        (0, 0) => "under a minute".into(),
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m} min"),
    }
}

impl Daemon {
    /// The task's work into `folder` (a project), out of the new folder zerod made it: between turns only, its files
    /// moved there (none over one already there), its Claude Code thread copied for the folder, the emptied folder
    /// removed, and its agent told. Its agent starts in `folder` from its next message.
    pub async fn move_to(&self, id: &str, folder: &str) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        let (old, new) = (Path::new(&conversation.cwd), Path::new(folder));
        if old.parent() != Some(&self.user_home().join("Zero")) {
            return Err("Only a task in a folder of its own in ~/Zero moves to a project".into());
        }
        if !new.is_absolute() || !new.is_dir() || new == old {
            return Err(format!("{folder} isn't a folder to move it to"));
        }
        if matches!(conversation.status, Status::Working | Status::Waiting | Status::Starting) {
            return Err("It's in a turn: move it once the turn ends".into());
        }
        let entries: Vec<std::ffi::OsString> = std::fs::read_dir(old)
            .map_err(|e| e.to_string())?
            .filter_map(|e| e.ok().map(|e| e.file_name()))
            .filter(|name| name != ".git")
            .collect();
        if let Some(taken) = entries.iter().find(|name| new.join(name).symlink_metadata().is_ok()) {
            return Err(format!("{} is in {folder} already: nothing moved", taken.to_string_lossy()));
        }
        // Before the old folder goes: its Claude Code folder is named from its real path.
        let thread = conversation.thread.as_ref().filter(|_| conversation.provider == Provider::Claude).map(|thread| {
            let file = format!("{thread}.jsonl");
            (crate::handoff::claude_folder(&self.user_home(), &conversation.cwd).join(&file), file)
        });
        self.take_offline(&session).await;
        for name in &entries {
            std::fs::rename(old.join(name), new.join(name)).map_err(|e| format!("{} didn't move: {e}", name.to_string_lossy()))?;
        }
        if let Some((from, file)) = thread.filter(|(from, _)| from.exists()) {
            let to = crate::handoff::claude_folder(&self.user_home(), folder);
            std::fs::create_dir_all(&to).and_then(|_| std::fs::copy(&from, to.join(file))).map_err(|e| e.to_string())?;
        }
        // All that's left is the empty repo zerod made, and the rewind points kept in it.
        let _ = std::fs::remove_dir_all(old);
        session.change(Change::Moved { cwd: folder.into() });
        let moved =
            if entries.is_empty() { String::new() } else { format!(", with the {} files from {}", entries.len(), conversation.cwd) };
        self.notify(id, &format!("Your folder is now {folder}{moved}. Work there from now on."))
    }
}

/// A task's own new folder in `base`: named from the first line's first five words (lower case, hyphens between),
/// "task" when they give nothing to name it by, "-2" and on when taken; a git repo, so rewind works.
fn new_folder(base: &Path, prompt: &str) -> std::io::Result<std::path::PathBuf> {
    std::fs::create_dir_all(base)?;
    let line = prompt.lines().next().unwrap_or("").to_lowercase();
    let words: Vec<&str> = line.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).take(5).collect();
    let name: String = words.join("-").chars().take(40).collect();
    let name = if name.is_empty() { "task".to_string() } else { name.trim_end_matches('-').to_string() };
    for n in 1.. {
        let folder = base.join(if n == 1 { name.clone() } else { format!("{name}-{n}") });
        // Not create_dir_all: an existing folder must fail here, so two tasks never share one.
        match std::fs::create_dir(&folder) {
            Ok(()) => {
                let _ = std::process::Command::new("git")
                    .args(["init", "-q"])
                    .current_dir(&folder)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
                return Ok(folder);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    unreachable!()
}

/// Claude Code's MCP servers as it has them now (`mcp_status`): settled, as `mcp_set_servers` waits for them.
async fn claude_status(session: &Session) -> Vec<Value> {
    let status = session.request(|id| json!({"type": "control_request", "request_id": id, "request": {"subtype": "mcp_status"}})).await;
    status.ok().and_then(|s| s["mcpServers"].as_array().cloned()).unwrap_or_default()
}
