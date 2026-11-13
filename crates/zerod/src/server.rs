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
use crate::inbox::Inbox;
use crate::model::{Permissions, Provider};

pub(crate) use connection::next_connection;
pub use connection::serve;
pub use signins::{follow_usage, name_accounts};

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
    /// A queued message, a command, or a schedule: its id.
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
    /// unrewind: the folder as it was before the rewind (its `undo`).
    undo: Option<String>,
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
    /// configure: the write switches, kept with the integrations' tokens rather than in settings.json.
    #[serde(rename = "slackPosts")]
    slack_posts: Option<bool>,
    #[serde(rename = "linearChanges")]
    linear_changes: Option<bool>,
    #[serde(flatten)]
    settings: Settings,
}

/// What an op needs from the request, refused with what's missing.
impl Request {
    fn ask(&self) -> Result<String, &'static str> {
        self.ask.as_ref().and_then(|a| a.as_str()).map(String::from).ok_or("Which ask?")
    }
    fn agent(&self) -> Result<String, &'static str> {
        self.agent.clone().ok_or("Which agent?")
    }
    fn option(&self) -> Result<usize, &'static str> {
        self.option.ok_or("Which option?")
    }
    fn session(&self) -> Result<String, &'static str> {
        self.session.clone().ok_or("Which session?")
    }
    /// The model and effort asked for; none, the session's own.
    fn choice(&self) -> crate::session::ModelChoice<'_> {
        crate::session::ModelChoice { model: self.model.as_deref(), effort: self.effort.as_deref() }
    }
    fn workspace_id(&self) -> Option<String> {
        self.workspace.as_ref().and_then(|w| w.as_str()).filter(|w| !w.is_empty()).map(String::from)
    }
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
    /// The context size, in tokens, agents compact at; 0 or unset, the CLIs' own (adapter::compact_window).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compact_window: Option<u64>,
    /// Agents' builds share a compile cache (build_cache.rs); unset, they don't.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub build_cache: Option<bool>,
    /// What Zero does about commands that look stuck (stuck.rs); unset, it tells the user.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stuck: Option<crate::stuck::Settings>,
    /// The terminal app a task opens in (its name, or an .app's path); unset, Ghostty where installed, else Terminal.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal: Option<String>,
    /// What this zerod doesn't read (an older one's settings, such as drop folders' patterns), kept as it was.
    #[serde(flatten)]
    pub rest: serde_json::Map<String, Value>,
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
        match self.archive_completed {
            None => Some(24 * 3600),
            Some(0) => None,
            Some(-1) => Some(0),
            Some(seconds) => Some(seconds.max(60)),
        }
    }

    /// Within what Claude Code takes (100k to 1M tokens), so Claude and Codex compact at the same size.
    pub fn compact_window(&self) -> Option<u64> {
        self.compact_window.filter(|&tokens| tokens > 0).map(|tokens| tokens.clamp(100_000, 1_000_000))
    }

    pub fn shares_build_cache(&self) -> bool {
        self.build_cache.unwrap_or(false)
    }

    pub fn allows_subagents(&self) -> bool {
        self.subagents.unwrap_or(false)
    }

    /// A done task leaves once the user has read its last answer, as a done worker does once its lead has its report.
    pub fn archive_once_read(&self) -> bool {
        self.archive_completed == Some(-1)
    }

    pub fn load(home: &std::path::Path) -> Settings {
        let mut settings: Settings =
            std::fs::read(home.join("settings.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        settings.git = settings.git.map(crate::git::AgentGit::upgraded);
        // Where an older zerod kept the write switches: anyone's to edit, so not read (vault.rs keeps them now).
        for key in ["slackPosts", "linearChanges"] {
            settings.rest.remove(key);
        }
        settings
    }

    /// Agents' processes started from here on commit and sign as the settings say.
    pub fn apply_git(&self, home: &std::path::Path) {
        crate::git::set(self.git.clone(), crate::git::key_path(home))
    }

    pub fn apply(&self, inbox: &Inbox) {
        inbox.configure(std::time::Duration::from_secs_f64(self.take_back.unwrap_or(2.0).max(0.0)), self.ttl.unwrap_or(3600));
        crate::adapter::allow_subagents(self.allows_subagents());
        crate::adapter::set_compact_window(self.compact_window());
        crate::build_cache::set(self.shares_build_cache());
        crate::stuck::set(self.stuck.clone().unwrap_or_default());
    }
}

/// What a connection reaches: the sessions, the inbox, and the rest zerod keeps.
#[derive(Clone)]
pub struct Zerod {
    pub daemon: Arc<Daemon>,
    pub inbox: Arc<Inbox>,
    pub integrations: Arc<crate::integrations::Integrations>,
    pub pads: Arc<crate::pads::Pads>,
    pub later: Arc<crate::later::Later>,
    pub loops: Arc<crate::loops::Loops>,
    pub following: Arc<crate::following::Following>,
    pub browsers: Arc<crate::browser::Browsers>,
    pub places: Arc<crate::board::Places>,
    /// Changes that aren't a session's, for subscribers: "pads" when a scratchpad changes.
    pub notices: broadcast::Sender<&'static str>,
    /// Whether a connection's peer, by its audit token, may make the app's own ops (APP_ONLY): Zero.app's signature
    /// for the user's zerod (peer.rs).
    pub peers: Peers,
}

/// Who may make the app's own ops, by the peer's audit token (none when the kernel didn't say).
pub type Peers = Arc<dyn Fn(Option<[u32; 8]>) -> bool + Send + Sync>;

/// What only the user does, through Zero.app: answer asks and tasks' approvals and questions, speak to an agent as
/// them, change settings, permissions, sign-ins and connections. Agents' own commands never send these; from any
/// other process they're refused, so an agent can't approve itself or let itself write.
pub(crate) const APP_ONLY: &[&str] = &[
    "choose",
    "answerAsk",
    "reply",
    "takeBack",
    "dismiss",
    "cancelRun",
    "deliver",
    "message",
    "decide",
    "answer",
    "configure",
    "setPermissions",
    "saveMcpServer",
    "deleteMcpServer",
    "saveWorkspace",
    "deleteWorkspace",
    "gitKey",
    "saveBrowserSettings",
    "saveSignIn",
    "codexSignIn",
    "claudeSignIn",
    "deleteSignIn",
    "defaultSignIn",
    "connectSlack",
    "disconnectSlack",
    "connectLinear",
    "disconnectLinear",
];

impl Zerod {
    /// The board as every client sees it: each session as a summary (its latest answer for Now, not its whole
    /// conversation), paused tasks shown so.
    pub(crate) fn shared_board(&self) -> Vec<crate::board::Row> {
        // Worked out once for every client: each connection's feed asked for it after the same settle (6 ms each, up
        // to four times a second while a session streams). Kept 200 ms, under the feed's 250 ms settle, so a feed
        // that heard a change never gets a board from before it. By daemon: tests run several in one process. Asked for directly (`zero board`), it's worked out fresh.
        static KEPT: std::sync::Mutex<Option<(usize, std::time::Instant, Vec<crate::board::Row>)>> = std::sync::Mutex::new(None);
        let key = Arc::as_ptr(&self.daemon) as usize;
        if let Some((kept, at, rows)) = KEPT.lock().unwrap().as_ref()
            && *kept == key
            && at.elapsed() < std::time::Duration::from_millis(200)
        {
            return rows.clone();
        }
        let rows = self.board();
        *KEPT.lock().unwrap() = Some((key, std::time::Instant::now(), rows.clone()));
        rows
    }

    /// Whether a task (a lead, or a worker on one) is done, confirmed: the board's word.
    pub fn done(&self, id: &str) -> bool {
        self.board().iter().any(|r| {
            (r.session == id && r.own == crate::board::State::Done)
                || r.team.iter().any(|m| m.session == id && m.state == crate::board::State::Done)
        })
    }

    fn board(&self) -> Vec<crate::board::Row> {
        let daemon = &self.daemon;
        let mut rows = crate::board::board_in(
            &daemon.sessions().iter().map(|s| s.summary()).collect::<Vec<_>>(),
            &self.inbox.asks(),
            &self.places.get(),
            &daemon.queues(),
            &|c| daemon.workspace_of(c),
        );
        crate::board::mark_read(&mut rows, &|id| daemon.has_read(id));
        crate::board::mark_background(&mut rows, &|id| daemon.background(id).is_some());
        crate::board::mark_paused(&mut rows, &|id| daemon.is_paused(id));
        // Saved for later: in Later until it's resumed from there.
        rows.retain(|r| !daemon.is_saved(&r.session));
        for row in rows.iter_mut() {
            row.wakes = daemon.next_wake(&row.session);
            row.paused_held = daemon.held_while_paused(&row.session);
            for member in row.team.iter_mut() {
                member.paused_held = daemon.held_while_paused(&member.session)
            }
            row.next = daemon.next(&row.session)
        }
        rows
    }
}

/// The inbox tells a worker (a task under a lead) by the daemon's sessions: its done is its lead's to judge.
pub fn know_workers(daemon: &Arc<Daemon>, inbox: &Arc<Inbox>) {
    let daemon = Arc::downgrade(daemon);
    inbox.know_workers(Box::new(move |agent| {
        let session = agent.reference.as_deref().or_else(|| agent.name.strip_prefix("zerod-"));
        daemon.upgrade().zip(session).and_then(|(daemon, id)| daemon.get(id)).is_some_and(|c| c.parent.is_some())
    }));
}

/// Asks linked to their task's conversation (about.rs): what each is about read from it, moved to the answer its turn
/// ends on, and the agent's answer to the user's words on one kept with it as its turn ends.
pub fn link_asks(daemon: &Arc<Daemon>, inbox: &Arc<Inbox>) {
    let weak = Arc::downgrade(daemon);
    inbox.know_conversations(Box::new(move |session, all| {
        let session = weak.upgrade()?.session(session).ok()?;
        // ponytail: an anchor copies the whole conversation to search it; index headings if that shows.
        Some(if all { session.items(None, None, usize::MAX) } else { session.recent(1).0.items })
    }));
    let inbox = Arc::downgrade(inbox);
    daemon.when_ended(Box::new(move |conversation| {
        if let Some(inbox) = inbox.upgrade() {
            inbox.answered(&conversation.id, &conversation.items);
            inbox.keep_reply(&conversation.items)
        }
    }));
}

/// A task with a blocking ask open (`zero ask --block`) hears nothing else until it's answered: the inbox tells the
/// daemon which tasks those are.
pub fn hold_while_blocked(daemon: &Arc<Daemon>, inbox: &Arc<Inbox>) {
    let inbox = Arc::downgrade(inbox);
    daemon.hold_while(Box::new(move |session| {
        inbox.upgrade().is_some_and(|inbox| {
            inbox
                .open_asks()
                .iter()
                .any(|a| a.blocks && (a.agent.reference.as_deref() == Some(session) || a.agent.name == format!("zerod-{session}")))
        })
    }));
}

/// What in the inbox wakes a task ending its turn waiting, so it isn't told nothing does: a note saying on whom
/// (`zero note --waiting`, `--needs`), and its workers' asks open to the user (the answer wakes the worker, whose
/// report wakes it).
pub fn know_what_wakes(daemon: &Arc<Daemon>, inbox: &Arc<Inbox>) {
    let (notes, asks) = (Arc::downgrade(inbox), Arc::downgrade(inbox));
    daemon.know_who(
        Box::new(move |conversation| notes.upgrade().is_some_and(|inbox| crate::board::says_who(conversation, &inbox.asks()))),
        Box::new(move |session| {
            asks.upgrade().is_some_and(|inbox| {
                inbox.open_asks().iter().any(|a| {
                    !matches!(a.kind, crate::ask::AskKind::Note | crate::ask::AskKind::Message)
                        && (a.agent.reference.as_deref() == Some(session) || a.agent.name == format!("zerod-{session}"))
                })
            })
        }),
    );
}

/// How long a finished worker stays after its answer before it's put away, in seconds.
const FINISHED_WORKER_AFTER: i64 = 3600;

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
            // The summary keeps the latest answer: the whole conversation needn't be copied, or a parked one loaded.
            let answered = zerod.daemon.summary(id).and_then(|c| {
                c.items.iter().rev().find(|i| matches!(i.kind, crate::model::ItemKind::Agent { final_answer: true, .. })).and_then(|i| i.at)
            });
            let noted = asks
                .iter()
                .filter(|a| a.kind == crate::ask::AskKind::Note && a.agent.reference.as_deref() == Some(id))
                .map(|a| a.created_at.0)
                .max();
            // Items are stamped in milliseconds, asks in seconds.
            answered.map(|ms| ms / 1000).max(noted)
        };
        let board = zerod.board();
        let due = crate::board::due_to_archive(&board, now, settings.archive_after(), &said);
        for id in due.into_iter().filter(|id| !settings.archive_once_read() || zerod.daemon.has_read(id)) {
            if let Err(error) = zerod.daemon.archive(&id).await {
                eprintln!("zerod: couldn't archive completed {id}: {error}")
            }
        }
        // A worker that finished, its lead has its report and nothing of its own is open (no follow, watch or wake-up
        // either): put away a while after, a message to it brings it back (Daemon::resolve). Off with the setting off.
        if settings.archive_after().is_none() {
            continue;
        }
        let daemon = &zerod.daemon;
        for id in crate::board::finished_workers(&board, now, FINISHED_WORKER_AFTER, &said) {
            // Follows its lead shares (its pull requests, passed with its report) are the lead's to carry on with.
            let lead = daemon.get(&id).and_then(|w| w.parent).unwrap_or_default();
            let open = zerod.following.unshared(&id, &lead) > 0 || !daemon.watches(Some(&id)).is_empty() || daemon.next_wake(&id).is_some();
            if !open
                && daemon.finished(&id)
                && let Err(error) = daemon.archive(&id).await
            {
                eprintln!("zerod: couldn't put away finished worker {id}: {error}")
            }
        }
    }
}

/// Each op to its topic's handler.
async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    match request.op.as_str() {
        "integrations" | "linearTeams" | "connectLinear" | "disconnectLinear" | "connectSlack" | "disconnectSlack" | "refreshSlack"
        | "slack" | "linear" => integrations::handle(zerod, request).await,
        "pad" | "later" | "loops" | "loop" | "saveLoop" | "deleteLoop" => notes::handle(zerod, request),
        "watch" | "watchFile" | "watches" | "unwatch" | "remind" | "schedule" | "schedules" | "unschedule" | "follow" | "unfollow"
        | "following" => watches::handle(zerod, request).await,
        "start" | "spawn" | "adopt" | "detach" | "migrate" | "archive" | "unarchive" | "archived" | "saveForLater" | "resumeLater"
        | "restartStatus" | "restart" | "stopLeft" => sessions::lifecycle(zerod, request).await,
        "release" | "resume" | "openTerminal" | "closeTerminal" | "rewindPreview" | "rewind" | "unrewind" | "branch" | "switch"
        | "interrupt" | "stop" | "restartAgent" | "pause" | "unpause" => sessions::control(zerod, request).await,
        "send" | "queue" | "unqueue" | "notify" | "decide" | "answer" | "seen" | "introduce" => sessions::messages(zerod, request).await,
        "label" | "setPermissions" | "placeInWorkspace" | "setStatus" | "attr" | "issue" | "table" | "place" | "expect" | "stopCommand" => {
            sessions::properties(zerod, request).await
        }
        "hello" | "selfCheck" | "list" | "get" | "workers" | "result" | "wait" | "usage" | "board" | "recent" | "items" | "window"
        | "outline" | "anchor" => sessions::reads(zerod, request).await,
        "browserCall"
        | "browsers"
        | "browserState"
        | "checkSafari"
        | "openFirefox"
        | "firefox"
        | "browserSettings"
        | "saveBrowserSettings"
        | "browserSetup" => browser::handle(zerod, request).await,
        "signIns" | "saveSignIn" | "codexSignIn" | "claudeSignIn" | "deleteSignIn" | "defaultSignIn" | "readUsage" | "accountActivity" => {
            signins::handle(zerod, request).await
        }
        "agentAsk" | "create" | "asks" | "choose" | "answerAsk" | "reply" | "takeBack" | "withdraw" | "dismiss" | "cancelRun"
        | "deliver" | "message" | "close" | "switchModel" => inbox::handle(zerod, request).await,
        "gitAccount" | "gitCheck" | "gitTokenStatus" => git(zerod, request).await,
        "mcpSignIn" => mcp_sign_in(zerod, request).await,
        "mcpServers" | "saveMcpServer" | "deleteMcpServer" | "workspaces" | "saveWorkspace" | "deleteWorkspace" | "settings"
        | "configure" | "gitKey" => setup(zerod, request),
        other => unknown(other),
    }
}

/// Settings › Git's lookups on GitHub, with the user's GitHub CLI: an account's committer, and whether the agents' key is
/// one of its signing keys.
async fn git(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let login = request.args.as_ref().and_then(|a| a["login"].as_str()).unwrap_or("").to_string();
    match request.op.as_str() {
        "gitAccount" => crate::git::account(&login)
            .await
            .map(|(name, email)| json!({"login": login.trim().trim_start_matches('@'), "name": name, "email": email})),
        "gitCheck" => Ok(json!({"title": crate::git::on_github(&login, zerod.daemon.home()).await})),
        "gitTokenStatus" => Ok(crate::git::token_status().await),
        other => unknown(other),
    }
}

/// Settings › MCP servers' Sign in, for a server of Claude Code's own: Claude's sign-in link (mcp_auth.rs), run as the
/// user's default Claude account, in the server's project for one of a project's.
async fn mcp_sign_in(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let args = request.args.unwrap_or_default();
    let server = args["server"].as_str().filter(|s| !s.is_empty()).ok_or("Which server?")?.to_string();
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    let cwd = args["cwd"].as_str().filter(|c| !c.is_empty()).unwrap_or(&home).to_string();
    let signins = &zerod.daemon.signins;
    let env = match signins.default_for(Provider::Claude) {
        Some(signin) => signins.environment(&signin)?,
        None => vec![],
    };
    let job = crate::mcp_auth::Job { server, provider: Provider::Claude, cwd, env, mcp: vec![] };
    Ok(json!({"page": zerod.daemon.mcp_auth.sign_in(job).await?}))
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
            let server =
                serde_json::from_value(request.server.clone().ok_or("Which server?")?).map_err(|e| format!("Not a server: {e}"))?;
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
            let workspace = serde_json::from_value(request.workspace.clone().ok_or("Which workspace?")?)
                .map_err(|e| format!("Not a workspace: {e}"))?;
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
            if let Some(key) = crate::git::public_key(daemon.home()) {
                settings["gitPublicKey"] = json!(key)
            }
            settings["buildCacheTools"] = crate::build_cache::tools(crate::build_cache::installed);
            settings["terminalApp"] = json!(crate::daemon::terminal_app(daemon.home()));
            let writes = zerod.integrations.writes();
            settings["slackPosts"] = json!(writes.slack_posts);
            settings["linearChanges"] = json!(writes.linear_changes);
            Ok(settings)
        }
        // The agents' signing key, taken from a file the user chose: its public half back, for GitHub.
        "gitKey" => {
            let from = request.args.as_ref().and_then(|a| a["path"].as_str()).ok_or("Which key file?")?;
            crate::git::take_key(std::path::Path::new(from), daemon.home()).map(|key| json!({"publicKey": key}))
        }
        "configure" => {
            zerod.integrations.set_writes(request.slack_posts, request.linear_changes)?;
            configure(zerod, request.settings)
        }
        other => unknown(other),
    }
}

/// The settings given over the ones kept, applied and kept.
fn configure(zerod: &Zerod, given: Settings) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    let mut settings = Settings::load(daemon.home());
    settings.take_back = given.take_back.or(settings.take_back);
    settings.ttl = given.ttl.or(settings.ttl);
    settings.places = given.places.or(settings.places);
    settings.archive_completed = given.archive_completed.or(settings.archive_completed);
    settings.git = given.git.map(crate::git::AgentGit::upgraded).or(settings.git);
    settings.subagents = given.subagents.or(settings.subagents);
    settings.models = given.models.or(settings.models);
    settings.compact_window = given.compact_window.or(settings.compact_window);
    settings.build_cache = given.build_cache.or(settings.build_cache);
    settings.stuck = given.stuck.or(settings.stuck);
    settings.terminal = given.terminal.or(settings.terminal);
    settings.apply_git(daemon.home());
    settings.apply(&zerod.inbox);
    let _ = std::fs::write(daemon.home().join("settings.json"), serde_json::to_vec_pretty(&settings).unwrap_or_default());
    Ok(Value::Null)
}

/// How many of a session's latest items a snapshot carries.
pub const RECENT: usize = 40;
