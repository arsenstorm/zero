//! The daemon's socket: one JSON object per line each way. A request `{"id", "op", …}` gets `{"id", "ok",
//! "result"}` or `{"id", "ok": false, "error"}`; requests run concurrently, so answers can come out of order.
//! After `subscribe`, the connection also gets `{"event": "session", "conversation"}` (a snapshot) and
//! `{"event": "change", "session", "seq", "change"}`; a client applies a change only if its `seq` follows its copy.
//! After `inbox`, it gets `{"event": "asks", "asks", "offline", "reachable"}` (a snapshot), then `{"event": "ask", "ask"}`,
//! `{"event": "output", "ask", "chunk"}`, `{"event": "removed", "ask"}` and `{"event": "agents", "offline", "reachable"}`.

mod browser;
mod connection;
mod inbox;
mod integrations;
mod notes;
mod sessions;
mod signins;
mod watches;

use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::broadcast;

use crate::daemon::Daemon;
use crate::drops::Drops;
use crate::inbox::Inbox;
use crate::model::{Permissions, Provider};

pub use connection::serve;
pub use signins::name_codex_accounts;

pub const VERSION: u64 = 1;

#[derive(Deserialize)]
struct Request {
    id: Option<Value>,
    op: String,
    provider: Option<Provider>,
    permissions: Option<Permissions>,
    session: Option<String>,
    cwd: Option<String>,
    prompt: Option<String>,
    text: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    approval: Option<String>,
    choice: Option<String>,
    question: Option<String>,
    answers: Option<crate::adapter::Answers>,
    /// "seen": the answer's item the user saw, and when (seconds since 1970).
    answer: Option<String>,
    at: Option<i64>,
    label: Option<String>,
    ticket: Option<String>,
    sessions: Option<Vec<String>>,
    any: Option<bool>,
    /// Seconds.
    timeout: Option<u64>,
    command: Option<String>,
    minutes: Option<u64>,
    force: Option<bool>,
    /// An ask's id; for `create`, the ask itself.
    ask: Option<Value>,
    keep: Option<bool>,
    option: Option<usize>,
    /// An agent's name in the inbox.
    agent: Option<String>,
    stop: Option<bool>,
    keys: Option<Vec<u8>>,
    /// "github" or "linear", with whether it's on, and one of its views (its id, or for saveView the view itself).
    integration: Option<String>,
    enabled: Option<bool>,
    view: Option<Value>,
    /// Views' ids, in the order they go.
    ids: Option<Vec<String>>,
    /// viewItems and linearTeams: what was last fetched (null for nothing yet) rather than fetching.
    cached: Option<bool>,
    /// A loop's description and body (loops.rs); its name is `name`.
    description: Option<String>,
    body: Option<String>,
    /// `table`: its title, columns and rows.
    title: Option<String>,
    columns: Option<Vec<String>>,
    rows: Option<Vec<Vec<String>>>,
    /// `pad`: a scratchpad tool (list, read, write…) and its arguments, as the MCP server's.
    tool: Option<String>,
    args: Option<Value>,
    /// An MCP server to save, or the id of one to delete.
    server: Option<Value>,
    /// startTask: the view's item (an issue or a pull request) to start a task from.
    item: Option<Value>,
    /// Rewinding: the message of yours to go back to, and what to bring back (the conversation, the folder's code).
    message: Option<String>,
    /// `attr`: an attribute's name and value (none takes it back).
    name: Option<String>,
    value: Option<String>,
    /// issue: who has it now (you, working, waiting, parked, done).
    state: Option<String>,
    conversation: Option<bool>,
    code: Option<bool>,
    /// adopt: the provider's own session id, to take in as a task.
    thread: Option<String>,
    /// send: images with the words, by their files.
    images: Option<Vec<String>>,
    /// place: where the session runs, by name.
    place: Option<String>,
    /// connectSlack: the user token.
    token: Option<String>,
    /// A Slack workspace's team id: the one to disconnect.
    team: Option<String>,
    /// browserAttach: what the extension says of itself; browserAnswer: its answer to a call; saveBrowserSettings: them.
    browser: Option<Value>,
    /// subscribe: no snapshots up front (a phone, on a slow link): each session's comes once it changes, or `recent`.
    lazy: Option<bool>,
    /// start, spawn, placeInWorkspace: a workspace's id; saveWorkspace: the workspace itself.
    workspace: Option<Value>,
    /// follow: a topic or URL, what to hear of it (mine: the pull requests followed; about: words); unfollow: topics, or all.
    topic: Option<String>,
    topics: Option<Vec<String>>,
    mine: Option<bool>,
    about: Option<Vec<String>>,
    all: Option<bool>,
    /// items: the page of a session's items before this one, or all of them from `from`.
    before: Option<String>,
    from: Option<String>,
    /// window: the page after this item.
    after: Option<String>,
    /// watchFile: {file, alerts, done, quiet}; unwatch: its id.
    watch: Option<Value>,
    /// start, spawn: the sign-in its CLI runs as, by id; saveSignIn: the sign-in; deleteSignIn: its id;
    /// defaultSignIn: {cli, id}.
    signin: Option<Value>,
    limit: Option<usize>,
    #[serde(flatten)]
    settings: Settings,
}

/// What an op needs from the request, refused with what's missing.
impl Request {
    fn ask(&self) -> Result<String, &'static str> { self.ask.as_ref().and_then(|a| a.as_str()).map(String::from).ok_or("Which ask?") }
    fn agent(&self) -> Result<String, &'static str> { self.agent.clone().ok_or("Which agent?") }
    fn option(&self) -> Result<usize, &'static str> { self.option.ok_or("Which option?") }
    fn session(&self) -> Result<String, &'static str> { self.session.clone().ok_or("Which session?") }
    fn integration(&self) -> Result<String, &'static str> { self.integration.clone().ok_or("Which integration: github or linear?") }
    fn view(&self) -> Result<String, &'static str> { self.view.as_ref().and_then(|v| v.as_str()).map(String::from).ok_or("Which view?") }
    /// The model and effort asked for; none, the session's own.
    fn choice(&self) -> crate::session::ModelChoice<'_> { crate::session::ModelChoice { model: self.model.as_deref(), effort: self.effort.as_deref() } }
    fn workspace_id(&self) -> Option<String> { self.workspace.as_ref().and_then(|w| w.as_str()).filter(|w| !w.is_empty()).map(String::from) }
}

/// What the app's settings say about the inbox; kept in zerod's home, so they hold before the app has connected.
#[derive(serde::Serialize, Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// Seconds an answer can be taken back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub take_back: Option<f64>,
    /// Seconds an ask without its own expiry waits.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ttl: Option<i64>,
    /// The folders that are drops.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patterns: Option<Vec<String>>,
    /// A command printing where tasks run by ticket, `[{"ticket", "place"}]`, rerun every minute (board.rs); empty for none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub places: Option<String>,
    /// Seconds a done task stays before it's archived; 0 never, -1 once the user has read it. Unset, a day.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archive_completed: Option<i64>,
    /// The identity agents' Git commits and signs as (git.rs); unset, the user's own.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git: Option<crate::git::AgentGit>,
    /// Agents may use their CLI's own subagents; unset, they can't (adapter::subagents).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subagents: Option<bool>,
    /// Models the user added for a CLI, Zero-wide: the pickers list them with the CLI's own.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub models: Option<Vec<CustomModel>>,
}

/// A model the user added: for which CLI, the id it's started with (`--model`), and the name the picker shows.
#[derive(serde::Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct CustomModel {
    pub cli: crate::model::Provider,
    pub id: String,
    pub name: String,
}

impl Settings {
    /// How long a done task stays before it's archived; none, never. Once read, at once (archive_once_read).
    pub fn archive_after(&self) -> Option<i64> {
        match self.archive_completed { None => Some(24 * 3600), Some(0) => None, Some(-1) => Some(0), Some(seconds) => Some(seconds.max(60)) }
    }

    pub fn allows_subagents(&self) -> bool { self.subagents.unwrap_or(false) }

    /// A done task leaves once the user has read its last answer, as a done worker does once its lead has its report.
    pub fn archive_once_read(&self) -> bool { self.archive_completed == Some(-1) }

    pub fn load(home: &std::path::Path) -> Settings {
        std::fs::read(home.join("settings.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    /// Agents' processes started from here on commit and sign as the settings say.
    pub fn apply_git(&self, home: &std::path::Path) { crate::git::set(self.git.clone(), crate::git::key_path(home)) }

    pub fn apply(&self, inbox: &Inbox, drops: Option<&Drops>) {
        inbox.configure(std::time::Duration::from_secs_f64(self.take_back.unwrap_or(2.0).max(0.0)), self.ttl.unwrap_or(3600));
        crate::adapter::allow_subagents(self.allows_subagents());
        if let (Some(drops), Some(patterns)) = (drops, &self.patterns) { drops.set_patterns(patterns.clone()) }
    }
}

/// What a connection reaches: the sessions, the inbox, and the drops feeding it.
#[derive(Clone)]
pub struct Zerod {
    pub daemon: Arc<Daemon>,
    pub inbox: Arc<Inbox>,
    pub drops: Option<Arc<Drops>>,
    pub integrations: Arc<crate::integrations::Integrations>,
    pub pads: Arc<crate::pads::Pads>,
    pub later: Arc<crate::later::Later>,
    pub loops: Arc<crate::loops::Loops>,
    pub following: Arc<crate::following::Following>,
    pub browsers: Arc<crate::browser::Browsers>,
    pub places: Arc<crate::board::Places>,
    /// Changes that aren't a session's, for subscribers: "pads" when a scratchpad changes.
    pub notices: broadcast::Sender<&'static str>,
}

impl Zerod {
    /// The board as every client sees it: each session as a summary (its latest answer for Now, not its whole
    /// conversation), paused tasks shown so.
    pub(crate) fn shared_board(&self) -> Vec<crate::board::Row> {
        // Worked out once for every client: each connection's feed asked for it after the same settle (6 ms each, up
        // to four times a second while a session streams). Kept 200 ms, under the feed's 250 ms settle, so a feed
        // that heard a change never gets a board from before it. By daemon: tests run several in one process. Asked for directly (`zero board`), it's worked out fresh.
        static KEPT: std::sync::Mutex<Option<(usize, std::time::Instant, Vec<crate::board::Row>)>> = std::sync::Mutex::new(None);
        let key = Arc::as_ptr(&self.daemon) as usize;
        if let Some((kept, at, rows)) = KEPT.lock().unwrap().as_ref() && *kept == key && at.elapsed() < std::time::Duration::from_millis(200) {
            return rows.clone();
        }
        let rows = self.board();
        *KEPT.lock().unwrap() = Some((key, std::time::Instant::now(), rows.clone()));
        rows
    }

    fn board(&self) -> Vec<crate::board::Row> {
        let daemon = &self.daemon;
        let mut rows = crate::board::board_in(&daemon.sessions().iter().map(|s| s.summary()).collect::<Vec<_>>(), &self.inbox.asks(), &self.places.get(), &daemon.queues(), &|c| daemon.workspace_of(c));
        crate::board::mark_read(&mut rows, &|id| daemon.has_read(id));
        crate::board::mark_paused(&mut rows, &|id| daemon.is_paused(id) || daemon.is_paused_for_update(id));
        // Saved for later: in Later until it's resumed from there.
        rows.retain(|r| !daemon.is_saved(&r.session));
        for row in rows.iter_mut() { row.wakes = daemon.next_wake(&row.session); row.next = daemon.next(&row.session) }
        rows
    }
}

/// A task with a blocking ask open (`zero ask --block`) hears nothing else until it's answered: the inbox tells the
/// daemon which tasks those are.
pub fn hold_while_blocked(daemon: &Arc<Daemon>, inbox: &Arc<Inbox>) {
    let inbox = Arc::downgrade(inbox);
    daemon.hold_while(Box::new(move |session| inbox.upgrade().is_some_and(|inbox| inbox.open_asks().iter()
        .any(|a| a.blocks && (a.agent.reference.as_deref() == Some(session) || a.agent.name == format!("zerod-{session}"))))));
}

/// Archives each task done for as long as the settings say (a day, unless the user changed it), or once the user has
/// read it, looked at every minute. Counted from when it said it was done, so a restart doesn't start it again.
pub async fn archive_completed(zerod: Zerod) {
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        let settings = Settings::load(zerod.daemon.home());
        let asks = zerod.inbox.asks();
        // Its last answer, or its last note (`zero note --done`), whichever came later: when it said it was done.
        let said = |id: &str| -> Option<i64> {
            let answered = zerod.daemon.get(id).and_then(|c| c.items.iter().rev().find(|i| matches!(i.kind, crate::model::ItemKind::Agent { final_answer: true, .. })).and_then(|i| i.at));
            let noted = asks.iter().filter(|a| a.kind == crate::ask::AskKind::Note && a.agent.reference.as_deref() == Some(id)).map(|a| a.created_at.0).max();
            // Items are stamped in milliseconds, asks in seconds.
            answered.map(|ms| ms / 1000).max(noted)
        };
        let due = crate::board::due_to_archive(&zerod.board(), now, settings.archive_after(), &said);
        for id in due.into_iter().filter(|id| !settings.archive_once_read() || zerod.daemon.has_read(id)) {
            if let Err(error) = zerod.daemon.archive(&id).await { eprintln!("zerod: couldn't archive completed {id}: {error}") }
        }
    }
}

/// Each op to its topic's handler.
async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    match request.op.as_str() {
        "integrations" | "setIntegration" | "saveView" | "deleteView" | "orderViews" | "viewItems" | "startTask" | "linearTeams"
        | "connectLinear" | "disconnectLinear" | "connectSlack" | "disconnectSlack" | "refreshSlack" => integrations::handle(zerod, request).await,
        "pad" | "later" | "loops" | "loop" | "saveLoop" | "deleteLoop" => notes::handle(zerod, request),
        "watch" | "watchFile" | "watches" | "unwatch" | "remind" | "schedule" | "schedules" | "unschedule" | "follow" | "unfollow"
        | "following" => watches::handle(zerod, request).await,
        "start" | "spawn" | "adopt" | "detach" | "migrate" | "archive" | "unarchive" | "archived" | "saveForLater" | "resumeLater" | "restartStatus" | "restart" => {
            sessions::lifecycle(zerod, request).await
        }
        "release" | "resume" | "openTerminal" | "closeTerminal" | "rewindPreview" | "rewind" | "branch" | "switch" | "interrupt" | "stop"
        | "pause" | "unpause" => sessions::control(zerod, request).await,
        "send" | "queue" | "unqueue" | "notify" | "decide" | "answer" | "seen" | "introduce" => sessions::messages(zerod, request).await,
        "label" | "setPermissions" | "placeInWorkspace" | "attr" | "issue" | "table" | "place" => sessions::properties(zerod, request).await,
        "hello" | "list" | "get" | "workers" | "result" | "wait" | "usage" | "board" | "recent" | "items" | "window" | "outline" => {
            sessions::reads(zerod, request).await
        }
        "browserCall" | "browsers" | "browserState" | "checkSafari" | "openFirefox" | "firefox" | "browserSettings" | "saveBrowserSettings"
        | "browserSetup" => browser::handle(zerod, request).await,
        "signIns" | "saveSignIn" | "codexSignIn" | "claudeSignIn" | "deleteSignIn" | "defaultSignIn" | "readUsage" => signins::handle(zerod, request).await,
        "agentAsk" | "create" | "asks" | "choose" | "answerAsk" | "reply" | "takeBack" | "withdraw" | "dismiss" | "cancelRun" | "deliver"
        | "message" | "close" | "screen" | "press" | "switchModel" => inbox::handle(zerod, request).await,
        "gitAccount" | "gitCheck" => git(zerod, request).await,
        "mcpServers" | "saveMcpServer" | "deleteMcpServer" | "workspaces" | "saveWorkspace" | "deleteWorkspace" | "settings" | "configure" | "gitKey" => {
            setup(zerod, request)
        }
        other => unknown(other),
    }
}

/// Settings › Git's lookups on GitHub, with the user's GitHub CLI: an account's committer, and whether the agents' key is
/// one of its signing keys.
async fn git(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let login = request.args.as_ref().and_then(|a| a["login"].as_str()).unwrap_or("").to_string();
    match request.op.as_str() {
        "gitAccount" => crate::git::account(&login).await.map(|(name, email)| json!({"login": login.trim().trim_start_matches('@'), "name": name, "email": email})),
        "gitCheck" => Ok(json!({"title": crate::git::on_github(&login, zerod.daemon.home()).await})),
        other => unknown(other),
    }
}

fn unknown(op: &str) -> Result<Value, String> {
    Err(format!("Unknown op {op}"))
}

/// Zero's own setup: MCP servers, workspaces, and the inbox's settings.
fn setup(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    match request.op.as_str() {
        // MCP servers set up in Zero: each task's CLI gets its workspace's as it starts.
        "mcpServers" => Ok(json!(daemon.mcp_servers.list())),
        "saveMcpServer" => {
            let server = serde_json::from_value(request.server.clone().ok_or("Which server?")?).map_err(|e| format!("Not a server: {e}"))?;
            let saved = daemon.mcp_servers.save(server)?;
            let _ = zerod.notices.send("mcp");
            Ok(json!(saved))
        }
        "deleteMcpServer" => {
            daemon.mcp_servers.delete(request.server.as_ref().and_then(|s| s.as_str()).ok_or("Which server?")?)?;
            let _ = zerod.notices.send("mcp");
            Ok(Value::Null)
        }
        "saveWorkspace" => {
            let workspace = serde_json::from_value(request.workspace.clone().ok_or("Which workspace?")?).map_err(|e| format!("Not a workspace: {e}"))?;
            let saved = daemon.workspaces.save(workspace)?;
            let _ = zerod.notices.send("workspaces");
            Ok(json!(saved))
        }
        "deleteWorkspace" => {
            daemon.workspaces.delete(&request.workspace_id().ok_or("Which workspace?")?)?;
            let _ = zerod.notices.send("workspaces");
            Ok(Value::Null)
        }
        "workspaces" => Ok(json!(daemon.workspaces.list())),
        "settings" => {
            let mut settings = json!(Settings::load(daemon.home()));
            if let Some(key) = crate::git::public_key(daemon.home()) { settings["gitPublicKey"] = json!(key) }
            Ok(settings)
        }
        // The agents' signing key, taken from a file the user chose: its public half back, for GitHub.
        "gitKey" => {
            let from = request.args.as_ref().and_then(|a| a["path"].as_str()).ok_or("Which key file?")?;
            crate::git::take_key(std::path::Path::new(from), daemon.home()).map(|key| json!({"publicKey": key}))
        }
        "configure" => configure(zerod, request.settings),
        other => unknown(other),
    }
}

/// The settings given over the ones kept, applied and kept.
fn configure(zerod: &Zerod, given: Settings) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    let mut settings = Settings::load(daemon.home());
        settings.take_back = given.take_back.or(settings.take_back);
        settings.ttl = given.ttl.or(settings.ttl);
        settings.patterns = given.patterns.or(settings.patterns);
        settings.places = given.places.or(settings.places);
        settings.archive_completed = given.archive_completed.or(settings.archive_completed);
        settings.git = given.git.or(settings.git);
        settings.subagents = given.subagents.or(settings.subagents);
        settings.models = given.models.or(settings.models);
        settings.apply_git(daemon.home());
        settings.apply(&zerod.inbox, zerod.drops.as_deref());
        let _ = std::fs::write(daemon.home().join("settings.json"), serde_json::to_vec_pretty(&settings).unwrap_or_default());
        Ok(Value::Null)
}

/// How many of a session's latest items a snapshot carries.
pub const RECENT: usize = 40;
