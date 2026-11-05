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

use std::collections::HashMap;
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
    /// Seconds a completed task stays before it's archived; 0 never. Unset, a day.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archive_completed: Option<i64>,
}

impl Settings {
    /// How long a completed task stays before it's archived; none, never.
    pub fn archive_after(&self) -> Option<i64> {
        match self.archive_completed { None => Some(24 * 3600), Some(0) => None, Some(seconds) => Some(seconds.max(60)) }
    }

    pub fn load(home: &std::path::Path) -> Settings {
        std::fs::read(home.join("settings.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    pub fn apply(&self, inbox: &Inbox, drops: Option<&Drops>) {
        inbox.configure(std::time::Duration::from_secs_f64(self.take_back.unwrap_or(2.0).max(0.0)), self.ttl.unwrap_or(3600));
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
    fn board(&self) -> Vec<crate::board::Row> {
        let daemon = &self.daemon;
        let mut rows = crate::board::board_in(&daemon.sessions().iter().map(|s| s.summary()).collect::<Vec<_>>(), &self.inbox.asks(), &self.places.get(), &daemon.queues(), &|c| daemon.workspace_of(c));
        crate::board::mark_read(&mut rows, &|id| daemon.has_read(id));
        crate::board::mark_paused(&mut rows, &|id| daemon.is_paused(id) || daemon.is_paused_for_update(id));
        for row in rows.iter_mut() { row.wakes = daemon.next_wake(&row.session) }
        rows
    }
}

/// Archives each task completed for as long as the settings say (a day, unless the user changed it), looked at every
/// few minutes. ponytail: when it was first seen completed is kept in memory, so a restart starts the clock again.
pub async fn archive_completed(zerod: Zerod) {
    let mut since = HashMap::new();
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(5 * 60)).await;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        let after = Settings::load(zerod.daemon.home()).archive_after();
        for id in crate::board::due_to_archive(&zerod.board(), &mut since, now, after) {
            match zerod.daemon.archive(&id).await {
                Ok(()) => { since.remove(&id); }
                Err(error) => eprintln!("zerod: couldn't archive completed {id}: {error}"),
            }
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
        "start" | "spawn" | "adopt" | "detach" | "migrate" | "archive" | "unarchive" | "archived" | "restartStatus" | "restart" => {
            sessions::lifecycle(zerod, request).await
        }
        "release" | "resume" | "openTerminal" | "closeTerminal" | "rewindPreview" | "rewind" | "branch" | "switch" | "interrupt" | "stop"
        | "pause" | "unpause" => sessions::control(zerod, request).await,
        "send" | "queue" | "unqueue" | "notify" | "decide" | "answer" | "seen" => sessions::messages(zerod, request).await,
        "label" | "setPermissions" | "placeInWorkspace" | "attr" | "issue" | "table" | "place" => sessions::properties(zerod, request).await,
        "hello" | "list" | "get" | "workers" | "result" | "wait" | "usage" | "board" | "recent" | "items" | "window" | "outline" => {
            sessions::reads(zerod, request).await
        }
        "browserCall" | "browsers" | "browserState" | "checkSafari" | "openFirefox" | "firefox" | "browserSettings" | "saveBrowserSettings"
        | "browserSetup" => browser::handle(zerod, request).await,
        "signIns" | "saveSignIn" | "codexSignIn" | "claudeSignIn" | "deleteSignIn" | "defaultSignIn" => signins::handle(zerod, request).await,
        "agentAsk" | "create" | "asks" | "choose" | "answerAsk" | "reply" | "takeBack" | "withdraw" | "dismiss" | "cancelRun" | "deliver"
        | "message" | "close" | "screen" | "press" | "switchModel" => inbox::handle(zerod, request).await,
        "mcpServers" | "saveMcpServer" | "deleteMcpServer" | "workspaces" | "saveWorkspace" | "deleteWorkspace" | "settings" | "configure" => {
            setup(zerod, request)
        }
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
        "settings" => Ok(json!(Settings::load(daemon.home()))),
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
        settings.apply(&zerod.inbox, zerod.drops.as_deref());
        let _ = std::fs::write(daemon.home().join("settings.json"), serde_json::to_vec_pretty(&settings).unwrap_or_default());
        Ok(Value::Null)
}

/// How many of a session's latest items a snapshot carries.
pub const RECENT: usize = 40;
