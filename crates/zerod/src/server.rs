//! The daemon's socket: one JSON object per line each way. A request `{"id", "op", …}` gets `{"id", "ok",
//! "result"}` or `{"id", "ok": false, "error"}`; requests run concurrently, so answers can come out of order.
//! After `subscribe`, the connection also gets `{"event": "session", "conversation"}` (a snapshot) and
//! `{"event": "change", "session", "seq", "change"}`; a client applies a change only if its `seq` follows its copy.
//! After `inbox`, it gets `{"event": "asks", "asks", "offline", "reachable"}` (a snapshot), then `{"event": "ask", "ask"}`,
//! `{"event": "output", "ask", "chunk"}`, `{"event": "removed", "ask"}` and `{"event": "agents", "offline", "reachable"}`.

use std::collections::HashMap;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc};

use crate::daemon::Daemon;
use crate::drops::Drops;
use crate::inbox::{Inbox, InboxEvent};
use crate::model::{Permissions, Provider};

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
}

impl Settings {
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
        crate::board::mark_paused(&mut rows, &|id| daemon.is_paused(id));
        for row in rows.iter_mut() { row.wakes = daemon.next_wake(&row.session) }
        rows
    }
}

/// Serves until the listener fails. The socket is the owner's only: whoever can write to it runs agents.
pub async fn serve(zerod: Zerod, socket: PathBuf) -> std::io::Result<()> {
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    loop {
        let (stream, _) = listener.accept().await?;
        tokio::spawn(connection(zerod.clone(), stream));
    }
}

async fn connection(zerod: Zerod, stream: UnixStream) {
    let (read, mut write) = stream.into_split();
    let (out, mut lines_out) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        while let Some(message) = lines_out.recv().await {
            let mut line = serde_json::to_vec(&message).unwrap_or_default();
            line.push(b'\n');
            if write.write_all(&line).await.is_err() { break }
        }
    });
    let (mut subscription, mut inbox, mut feed) = (None, None, None);
    let mut browser: Option<String> = None;
    let mut lines = BufReader::new(read).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        // An unknown provider is refused here, as a bad request: zerod only starts what it has an adapter for. The
        // refusal keeps the request's id when there is one, so the client knows which request it was.
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(error) => {
                let id = serde_json::from_str::<Value>(&line).ok().and_then(|v| v.get("id").cloned()).unwrap_or(Value::Null);
                let _ = out.send(json!({"id": id, "ok": false, "error": format!("Not a request: {error}")}));
                continue;
            }
        };
        if request.op == "subscribe" {
            if subscription.is_none() { subscription = Some(tokio::spawn(subscribe(zerod.daemon.clone(), out.clone(), request.lazy.unwrap_or(false)))) }
            if feed.is_none() { feed = Some(tokio::spawn(self::feed(zerod.clone(), out.clone()))) }
            let _ = out.send(json!({"id": request.id, "ok": true, "result": null}));
            continue;
        }
        // The native host of a Chrome with Zero for Chrome: calls for it go down this connection, its answers come up it.
        if request.op == "browserAttach" {
            browser = Some(zerod.browsers.attach(request.browser.as_ref().unwrap_or(&Value::Null), out.clone()));
            // Tasks whose browser call found Chrome gone are told it's back, as Zero's word between their turns.
            for session in zerod.browsers.take_waiting() {
                zerod.daemon.tell_from_zero(&session, "Zero for Chrome is connected again: carry on with the browser work.");
            }
            continue;
        }
        if request.op == "browserAnswer" {
            if let Some(answer) = &request.browser { zerod.browsers.answer(answer) }
            continue;
        }
        if request.op == "inbox" {
            if inbox.is_none() { inbox = Some(tokio::spawn(follow_inbox(zerod.inbox.clone(), out.clone()))) }
            let _ = out.send(json!({"id": request.id, "ok": true, "result": null}));
            continue;
        }
        let (zerod, out) = (zerod.clone(), out.clone());
        tokio::spawn(async move {
            let id = request.id.clone();
            let answer = match handle(&zerod, request).await {
                Ok(result) => json!({"id": id, "ok": true, "result": result}),
                Err(error) => json!({"id": id, "ok": false, "error": error}),
            };
            let _ = out.send(answer);
        });
    }
    for task in [subscription, inbox, feed].into_iter().flatten() { task.abort() }
    if let Some(browser) = browser { zerod.browsers.detach(&browser) }
    drop(out);
    let _ = writer.await;
}

async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let (daemon, inbox) = (&zerod.daemon, &zerod.inbox);
    let ask = || request.ask.as_ref().and_then(|a| a.as_str()).map(String::from).ok_or("Which ask?");
    let agent = || request.agent.clone().ok_or("Which agent?");
    let option = || request.option.ok_or("Which option?");
    let session = || request.session.clone().ok_or("Which session?");
    let model = request.model.as_deref();
    let effort = request.effort.as_deref();
    let integrations = &zerod.integrations;
    let integration = || request.integration.clone().ok_or("Which integration: github or linear?");
    let view = || request.view.as_ref().and_then(|v| v.as_str()).map(String::from).ok_or("Which view?");
    let state = |settings: crate::integrations::Settings| json!({"settings": settings, "linear": integrations.linear_workspace(), "github": integrations.github_known(), "slack": integrations.slack_state()});
    let workspace_id = || request.workspace.as_ref().and_then(|w| w.as_str()).filter(|w| !w.is_empty()).map(String::from);
    match request.op.as_str() {
        // Integrations: their settings and views, what a view shows now, and connecting Linear.
        "integrations" => { integrations.github_account().await; Ok(state(integrations.settings())) }
        "setIntegration" => integrations.set_enabled(&integration()?, request.enabled.ok_or("On or off?")?).map(state),
        "saveView" => integrations.save_view(&integration()?, request.view.clone().ok_or("Which view?")?).map(state),
        "deleteView" => integrations.delete_view(&integration()?, &view()?).map(state),
        "orderViews" => integrations.order_views(&integration()?, request.ids.as_deref().ok_or("Which views, in what order?")?).map(state),
        "viewItems" if request.cached == Some(true) => match integrations.cached(&format!("{}/{}", integration()?, view()?)) {
            Some(kept) => Ok(json!(crate::integrations::with_tasks(serde_json::from_value(kept).unwrap_or_default(), &tasks(daemon)))),
            None => Ok(Value::Null),
        },
        "viewItems" => integrations.items(&integration()?, &view()?).await.map(|items| json!(crate::integrations::with_tasks(items, &tasks(daemon)))),
        "startTask" => start_task(zerod, &integration()?, &view()?, request.item.clone().ok_or("Which item?")?),
        "linearTeams" if request.cached == Some(true) => Ok(integrations.cached("linear/teams").unwrap_or_default()),
        "linearTeams" => integrations.linear_teams().await,
        "connectLinear" => integrations.connect_linear().await.map(|url| json!({"url": url})),
        "disconnectLinear" => integrations.disconnect_linear().map(|_| state(integrations.settings())),
        "connectSlack" => { integrations.connect_slack(request.token.as_deref().ok_or("Slack's user token (xoxp-…)")?).await?; Ok(state(integrations.settings())) }
        "disconnectSlack" => integrations.disconnect_slack().map(|_| state(integrations.settings())),
        "refreshSlack" => { integrations.refresh_slack().await?; Ok(state(integrations.settings())) }
        "pad" => {
            let tool = request.tool.as_deref().ok_or("Which scratchpad tool?")?;
            let result = crate::pads::call(&zerod.pads, tool, request.args.as_ref().unwrap_or(&Value::Null));
            if result.is_ok() && !matches!(tool, "list" | "read" | "find") { let _ = zerod.notices.send("pads"); }
            result
        }
        // Later: things to come back to. Saved from a task, it knows which, and the task's name and workspace then.
        "later" => {
            let tool = request.tool.as_deref().ok_or("Which later tool?")?;
            let mut args = request.args.clone().unwrap_or(json!({}));
            if let (Some(id), Some(fields)) = (request.session.as_deref(), args.as_object_mut())
                && let Some(task) = daemon.get(id) {
                if tool == "save" {
                    fields.insert("from".into(), json!(id));
                    fields.insert("task".into(), json!(crate::bridge::label(&task)));
                    fields.insert("workspace".into(), json!(daemon.workspace_of(&task)));
                } else if tool == "edit" {
                    fields.insert("by".into(), json!(id));
                }
            }
            let result = crate::later::call(&zerod.later, tool, &args);
            if result.is_ok() && !matches!(tool, "list" | "view") { let _ = zerod.notices.send("later"); }
            result
        }
        // Loops: named instructions, by name.
        "loops" => Ok(json!(zerod.loops.list())),
        "loop" => zerod.loops.read(request.name.as_deref().ok_or("Which loop?")?).map(|l| json!(l)),
        "saveLoop" => {
            let saved = zerod.loops.save(request.name.as_deref().ok_or("A loop needs a name")?, request.description.as_deref().unwrap_or(""), request.body.as_deref().unwrap_or(""))?;
            let _ = zerod.notices.send("loops");
            Ok(json!(saved))
        }
        "deleteLoop" => {
            zerod.loops.delete(request.name.as_deref().ok_or("Which loop?")?)?;
            let _ = zerod.notices.send("loops");
            Ok(Value::Null)
        }
        "follow" => {
            let followed = zerod.following.follow(&session()?, request.topic.as_deref().ok_or("Follow what? A topic or a URL")?, request.mine.unwrap_or(false), request.about.clone().unwrap_or_default()).await?;
            let _ = zerod.notices.send("following");
            Ok(json!(followed))
        }
        "unfollow" => {
            let removed = zerod.following.unfollow(&session()?, if request.all == Some(true) { None } else { Some(request.topics.as_deref().ok_or("Unfollow which topics? Or all")?) });
            let _ = zerod.notices.send("following");
            Ok(json!({"removed": removed}))
        }
        "following" => Ok(json!(zerod.following.list(request.session.as_deref()))),
        "hello" => Ok(json!({"version": VERSION, "pid": std::process::id()})),
        "list" => Ok(json!(daemon.sessions().iter().map(|s| summary(&s.summary())).collect::<Vec<_>>())),
        "get" => daemon.get(&session()?).map(|c| json!(c)).ok_or_else(|| format!("No session {}", request.session.unwrap_or_default())),
        "start" => {
            let provider = request.provider.ok_or("Start needs a provider: codex, claude or opencode")?;
            let cwd = request.cwd.as_deref().ok_or("Start needs a folder")?;
            let options = crate::daemon::Options {
                cwd: Some(cwd.into()), workspace: workspace_id(), model: request.model.clone(), effort: request.effort.clone(), permissions: Some(request.permissions.unwrap_or_default()),
                label: request.label.clone(), ticket: request.ticket.clone(), force: request.force.unwrap_or(false),
                images: request.images.clone().unwrap_or_default(), signin: request.signin.as_ref().and_then(Value::as_str).map(String::from),
            };
            // A loop named in the prompt (@name) is given as its words, and its use recorded once the session exists.
            let (prompt, loops) = zerod.loops.expand(request.prompt.as_deref().unwrap_or(""));
            let id = daemon.start_with(provider, &prompt, options)?;
            for name in &loops { zerod.loops.record(name, &id, "lead") }
            Ok(json!({"session": id}))
        }
        "send" => {
            let images = request.images.clone().unwrap_or_default();
            let text = request.text.as_deref().filter(|t| !t.trim().is_empty() || !images.is_empty()).ok_or("Send needs text")?;
            let (text, loops) = zerod.loops.expand(text);
            let id = session()?;
            let role = if daemon.get(&id).is_some_and(|c| c.parent.is_some()) { "worker" } else { "lead" };
            for name in &loops { zerod.loops.record(name, &id, role) }
            daemon.send_with_images(&id, &text, &images, model, effort).await.map(|_| Value::Null)
        }
        // For after the current turn: queued, one turn each; between turns it goes now.
        "queue" => {
            let images = request.images.clone().unwrap_or_default();
            let text = request.text.as_deref().filter(|t| !t.trim().is_empty() || !images.is_empty()).ok_or("Queue needs text")?;
            let (text, loops) = zerod.loops.expand(text);
            let id = session()?;
            let role = if daemon.get(&id).is_some_and(|c| c.parent.is_some()) { "worker" } else { "lead" };
            for name in &loops { zerod.loops.record(name, &id, role) }
            daemon.queue(&id, &text, &images).map(|queued| json!(queued))
        }
        "unqueue" => daemon.unqueue(&session()?, request.item.as_ref().and_then(Value::as_str).ok_or("Which queued message?")?).map(|queued| json!(queued)),
        "release" => daemon.release(&session()?).map(|_| Value::Null),
        "resume" => daemon.resume(&session()?).await.map(|_| Value::Null),
        "openTerminal" => daemon.open_terminal(&session()?).await.map(|terminal| json!({"terminal": terminal})),
        // From a session: the task or Claude Code session becomes its worker.
        "adopt" if request.session.is_some() => daemon.adopt_into(&session()?, request.thread.as_deref().ok_or("Which task or session?")?).map(|id| json!({"session": id})),
        "adopt" => {
            let options = crate::daemon::Options { workspace: None, label: request.label.clone(), ticket: request.ticket.clone(), permissions: request.permissions, ..Default::default() };
            daemon.adopt(request.provider.unwrap_or(Provider::Claude), request.thread.as_deref().ok_or("Which session?")?,
                         request.cwd.as_deref().ok_or("Which folder?")?, options).map(|id| json!({"session": id}))
        }
        "archive" => daemon.archive(&session()?).await.map(|_| Value::Null),
        "unarchive" => daemon.unarchive(&session()?).map(|back| json!(back)),
        "archived" => Ok(json!(daemon.archived(request.limit.unwrap_or(1000)))),
        // A new build is on disk: turns under way pause between steps, then zerod becomes the new one, which carries
        // them on. Answered at once; the restart happens when the last turn has paused.
        // While a restart waits for turns to pause: what it's waiting for.
        "restartStatus" => Ok(daemon.restart_status()),
        "restart" => {
            let daemon = daemon.clone();
            // The app hears a restart is under way, and asks what it waits for.
            let _ = zerod.notices.send("restarting");
            tokio::spawn(async move {
                let paused = daemon.pause_for_restart().await;
                eprintln!("zerod: restarting as the new build; {} turn(s) paused to carry on", paused.len());
                crate::process::replace_self();
            });
            Ok(json!({"restarting": true}))
        }
        "rewindPreview" => daemon.rewind_preview(&session()?, request.message.as_deref().ok_or("Back to which message?")?),
        "rewind" => daemon.rewind(&session()?, request.message.as_deref().ok_or("Back to which message?")?, request.conversation.unwrap_or(true),
                                  request.code.unwrap_or(false)).await,
        "branch" => daemon.branch(&session()?, request.message.as_deref().ok_or("Branch from which message?")?),
        "closeTerminal" => daemon.close_terminal(&session()?).await.map(|_| Value::Null),
        "switch" => {
            let provider = request.provider.ok_or("Switch to which provider: codex, claude or opencode?")?;
            daemon.switch(&session()?, provider, request.model.as_deref(), request.effort.as_deref()).await.map(|_| Value::Null)
        }
        "interrupt" => daemon.interrupt(&session()?).await.map(|_| Value::Null),
        "stop" => daemon.stop(&session()?).map(|_| Value::Null),
        // The tasks named (every task, none named) and their workers: on hold, and off it. A working one is given five
        // minutes to wrap up.
        "pause" => Ok(json!(daemon.pause(&request.sessions.clone().unwrap_or_default(), std::time::Duration::from_secs(5 * 60)).await)),
        "unpause" => Ok(json!(daemon.unpause(&request.sessions.clone().unwrap_or_default()).await)),
        "decide" => {
            let approval = request.approval.as_deref().ok_or("Which approval?")?;
            let choice = request.choice.as_deref().ok_or("Which choice?")?;
            daemon.decide(&session()?, approval, choice).await.map(|_| Value::Null)
        }
        "answer" => {
            let question = request.question.as_deref().ok_or("Which question?")?;
            let answers = request.answers.as_ref().ok_or("Answer with answers")?;
            daemon.answer(&session()?, question, answers).await.map(|_| Value::Null)
        }
        "spawn" => {
            let lead = session()?;
            let provider = match request.provider { Some(provider) => provider, None => daemon.get(&lead).ok_or_else(|| format!("No session {lead}"))?.provider };
            let options = crate::daemon::Options {
                cwd: request.cwd.clone(), workspace: workspace_id(), model: request.model.clone(), effort: request.effort.clone(), permissions: request.permissions,
                label: request.label.clone(), ticket: request.ticket.clone(), force: request.force.unwrap_or(false),
                images: request.images.clone().unwrap_or_default(), signin: request.signin.as_ref().and_then(Value::as_str).map(String::from),
            };
            let (prompt, loops) = zerod.loops.expand(request.prompt.as_deref().unwrap_or(""));
            let id = daemon.spawn(&lead, provider, &prompt, options)?;
            for name in &loops { zerod.loops.record(name, &id, "worker") }
            Ok(json!({"session": id}))
        }
        // From another task when `from` says which: marked as its words.
        "notify" => daemon.notify_from(&session()?, request.from.as_deref().unwrap_or("zero"), request.text.as_deref().ok_or("Notify with text")?).map(|_| Value::Null),
        "watch" => daemon.watch(&session()?, request.command.as_deref().ok_or("Watch which command?")?).map(|_| Value::Null),
        // A file watched for the session: {file, alerts, done, quiet}.
        "watchFile" => {
            let watch = request.watch.as_ref().ok_or("Watch what?")?;
            let file = watch["file"].as_str().ok_or("Watch which file?")?;
            let alerts = watch["alerts"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
            daemon.watch_file(&session()?, std::path::Path::new(file), alerts, watch["done"].as_str().map(String::from), watch["quiet"].as_u64())
                .map(|id| json!({"watch": id}))
        }
        "watches" => Ok(json!(daemon.watches(request.session.as_deref()))),
        "unwatch" => daemon.unwatch(request.watch.as_ref().and_then(Value::as_str).ok_or("Which watch?")?).map(|_| Value::Null),
        "remind" => {
            let after = std::time::Duration::from_secs(request.minutes.ok_or("Remind in how many minutes?")? * 60);
            daemon.remind(&session()?, after, request.text.as_deref().ok_or("Remind with text")?).map(|_| Value::Null)
        }
        // A task waking itself at a time: `at` (seconds since 1970) or in `minutes`.
        "schedule" => {
            let at = match (request.at, request.minutes) {
                (Some(at), _) => at,
                (None, Some(minutes)) => std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0) + minutes as i64 * 60,
                _ => return Err("When? at (seconds since 1970) or minutes".into()),
            };
            daemon.schedule(&session()?, at, request.text.as_deref().ok_or("Schedule it with what for?")?).map(|s| json!(s))
        }
        "schedules" => Ok(json!(daemon.schedules(request.session.as_deref()))),
        "unschedule" => daemon.unschedule(request.item.as_ref().and_then(Value::as_str).ok_or("Which schedule?")?).map(|_| Value::Null),
        "usage" => Ok(json!(daemon.usage().into_iter().map(|(provider, usage)| json!({"provider": provider, "usage": usage})).collect::<Vec<_>>())),
        // The user saw a task's reply, on whichever client: Replied settles to Idle five minutes on, everywhere.
        "seen" => daemon.mark_seen(&session()?, request.answer.as_deref(), request.at).map(|_| Value::Null),
        "label" => daemon.label(&session()?, request.label.as_deref(), request.ticket.as_deref()).map(|_| Value::Null),
        "workspaces" => Ok(json!(daemon.workspaces.list())),
        "browserCall" => {
            let session = request.session.as_deref();
            let conversation = session.and_then(|s| daemon.get(s));
            // A task's group is its own; its window is its team's (its lead's, through every level).
            let mut lead = conversation.clone();
            while let Some(parent) = lead.as_ref().and_then(|c| c.parent.clone()).and_then(|p| daemon.get(&p)) { lead = Some(parent) }
            let task = json!({
                "session": session, "group": session.unwrap_or("zero"), "window": lead.as_ref().map(|l| l.id.as_str()).unwrap_or("zero"),
                "name": conversation.as_ref().map(crate::bridge::label).unwrap_or_else(|| "Zero".into()),
                "state": "working",
                // What the group is called: Zero, and the work's reference when it has one (its own, else its lead's).
                "ticket": conversation.as_ref().and_then(|c| c.ticket.clone()).or_else(|| lead.as_ref().and_then(|l| l.ticket.clone())),
            });
            let tool = request.tool.as_deref().ok_or("Which tool?")?;
            let args = request.args.clone().unwrap_or(json!({}));
            if let Some(conversation) = &conversation { review(zerod, conversation, tool, &args).await? }
            zerod.browsers.call(session, task, tool, args).await
        }
        "browsers" => Ok(zerod.browsers.list(request.session.as_deref())),
        "browserState" => {
            zerod.browsers.tell_state(&session()?, request.browser.as_ref().and_then(|b| b["state"].as_str()).ok_or("Which state?")?);
            Ok(Value::Null)
        }
        // Firefox opened under remote control (Settings › Browsers), its extension installed.
        "openFirefox" => { zerod.browsers.firefox().ok_or("Firefox isn't set up in Zero")?.ensure().await?; Ok(Value::Null) }
        // A Chrome debugger command from Zero's extension in Firefox, done through Firefox's remote control.
        "firefox" => {
            let args = request.args.as_ref().ok_or("Which command?")?;
            let firefox = zerod.browsers.firefox().ok_or("Firefox isn't set up in Zero")?;
            firefox.command(args["tab"].as_i64().ok_or("Which tab?")?, args["nonce"].as_str(), args["method"].as_str().ok_or("Which method?")?,
                            &args["params"]).await
        }
        "browserSettings" => Ok(zerod.browsers.settings()),
        "saveBrowserSettings" => zerod.browsers.save_settings(request.browser.as_ref().ok_or("Which settings?")?),
        "browserSetup" => {
            let zerod_exe = std::env::current_exe().map_err(|e| e.to_string())?;
            let manifest = crate::browser::install(&zerod_exe)?;
            let extension = zerod_exe.parent().and_then(|macos| macos.parent()).map(|contents| contents.join("Resources/chrome")).unwrap_or_default();
            Ok(json!({"manifest": manifest, "extension": extension, "id": crate::browser::EXTENSION}))
        }
        // MCP servers set up in Zero: each task's CLI gets its workspace's as it starts.
        // The CLIs' sign-ins: what each is (never its value, which the app keeps in the Keychain) and each CLI's default.
        "signIns" => {
            let list = daemon.signins.list();
            let defaults: serde_json::Map<String, Value> = [Provider::Claude, Provider::Codex, Provider::Opencode].into_iter()
                .filter_map(|cli| daemon.signins.default_for(cli).map(|s| (format!("{cli:?}").to_lowercase(), json!(s.id)))).collect();
            let usage: serde_json::Map<String, Value> = list.iter().filter_map(|s| daemon.signins.usage(&s.id).map(|u| (s.id.clone(), json!(u)))).collect();
            Ok(json!({"signins": list, "defaults": defaults, "usage": usage}))
        }
        "saveSignIn" => {
            let signin = serde_json::from_value(request.signin.clone().ok_or("Which sign-in?")?).map_err(|e| format!("Not a sign-in: {e}"))?;
            let saved = daemon.signins.save(signin)?;
            let _ = zerod.notices.send("signins");
            Ok(json!(saved))
        }
        // A Codex account signed in by Codex itself, in a home of its own: its page back now, the rest in the background.
        "codexSignIn" => codex_sign_in(zerod, request.signin.as_ref()).await,
        // A Claude account signed in by Claude Code itself, in a folder of its own: the same, through `claude auth login`.
        "claudeSignIn" => claude_sign_in(zerod).await,
        "deleteSignIn" => {
            daemon.signins.delete(request.signin.as_ref().and_then(|s| s.as_str()).ok_or("Which sign-in?")?)?;
            let _ = zerod.notices.send("signins");
            Ok(Value::Null)
        }
        "defaultSignIn" => {
            let chosen = request.signin.as_ref().ok_or("Which sign-in?")?;
            let cli: Provider = serde_json::from_value(chosen["cli"].clone()).map_err(|_| "Which CLI?")?;
            daemon.signins.set_default(cli, chosen["id"].as_str().ok_or("Which sign-in?")?)?;
            let _ = zerod.notices.send("signins");
            Ok(Value::Null)
        }
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
            daemon.workspaces.delete(&workspace_id().ok_or("Which workspace?")?)?;
            let _ = zerod.notices.send("workspaces");
            Ok(Value::Null)
        }
        "setPermissions" => daemon.set_permissions(&session()?, request.permissions.ok_or("Which permissions: auto or unrestricted?")?).await.map(|_| Value::Null),
        "placeInWorkspace" => daemon.place_in_workspace(&session()?, workspace_id().as_deref()).map(|_| Value::Null),
        "attr" => daemon.set_attribute(&session()?, request.name.as_deref().ok_or("Which attribute?")?, request.value.as_deref()).map(|_| Value::Null),
        "table" => daemon.table(&session()?, request.title.as_deref().unwrap_or(""), request.columns.clone().unwrap_or_default(), request.rows.clone().unwrap_or_default()).map(|_| Value::Null),
        "workers" => {
            let lead = session()?;
            Ok(json!(daemon.sessions().iter().map(|s| s.summary()).filter(|c| c.parent.as_deref() == Some(lead.as_str())).map(|c| summary(&c)).collect::<Vec<_>>()))
        }
        "result" => Ok(json!({"answer": daemon.last_answer(&session()?)})),
        "wait" => {
            let ids = request.sessions.clone().ok_or("Wait on which sessions?")?;
            let timeout = std::time::Duration::from_secs(request.timeout.unwrap_or(30 * 60));
            let settled = daemon.wait(&ids, request.any.unwrap_or(false), timeout).await?;
            Ok(json!(settled.iter().map(|c| json!({
                "id": c.id, "label": c.label, "ticket": c.ticket, "attention": c.attention(), "answer": c.answer(),
                "error": c.failure.as_ref().map(|f| &f.message), "stalled": c.stalled,
            })).collect::<Vec<_>>()))
        }
        // The inbox.
        "create" => {
            let incoming: crate::ask::Ask = serde_json::from_value(request.ask.clone().ok_or("Create which ask?")?).map_err(|e| format!("Not an ask: {e}"))?;
            Ok(json!(inbox.create(incoming, request.keep.unwrap_or(false))))
        }
        "asks" => Ok(json!(inbox.asks())),
        // Whole sessions, not the list's: a row falls back on its lead's last answer.
        // Each session as a summary: its latest answer for Now, not its whole conversation.
        "board" => Ok(json!(zerod.board())),
        // A session's latest items and how many came before: what a lazy subscriber shows when it opens one.
        "recent" => {
            let (conversation, earlier) = daemon.session(&session()?)?.recent(RECENT);
            Ok(json!({"conversation": conversation, "earlier": earlier}))
        }
        "items" => Ok(json!(daemon.session(&session()?)?.items(request.before.as_deref(), request.from.as_deref(), request.limit.unwrap_or(60)))),
        "window" => {
            let (items, earlier, later) = daemon.session(&session()?)?.window(request.from.as_deref(), request.after.as_deref(), request.limit.unwrap_or(60));
            Ok(json!({"items": items, "earlier": earlier, "later": later}))
        }
        "outline" => Ok(daemon.session(&session()?)?.outline()),
        "place" => daemon.set_place(&session()?, request.place.as_deref()).map(|_| Value::Null),
        "settings" => Ok(json!(Settings::load(daemon.home()))),
        "choose" => { inbox.choose(&ask()?, option()?); Ok(Value::Null) }
        "answerAsk" => { inbox.answer(&ask()?, option()?, request.text.as_deref().unwrap_or("")); Ok(Value::Null) }
        "reply" => { inbox.reply(&ask()?, request.text.as_deref().ok_or("Reply with text")?); Ok(Value::Null) }
        "takeBack" => Ok(json!(inbox.take_back(&ask()?))),
        "withdraw" => { inbox.withdraw(&ask()?, request.text.as_deref()); Ok(Value::Null) }
        "dismiss" => { inbox.dismiss(&ask()?); Ok(Value::Null) }
        "cancelRun" => { inbox.cancel_run(&ask()?); Ok(Value::Null) }
        "deliver" => { inbox.deliver_answer(&ask()?); Ok(Value::Null) }
        "message" => inbox.message(request.text.as_deref().ok_or("Message with text")?, &agent()?).await.map(|_| Value::Null),
        "close" => { inbox.close_agent(&agent()?, request.stop.unwrap_or(true)); Ok(Value::Null) }
        "screen" => Ok(json!(inbox.screen(&agent()?).await)),
        "press" => inbox.press(&agent()?, request.keys.as_deref().unwrap_or_default()).await.map(|screen| json!(screen)),
        "switchModel" => inbox.switch_model(&agent()?, model, effort).await.map(|_| Value::Null),
        "configure" => {
            let mut settings = Settings::load(daemon.home());
            let given = request.settings.clone();
            settings.take_back = given.take_back.or(settings.take_back);
            settings.ttl = given.ttl.or(settings.ttl);
            settings.patterns = given.patterns.or(settings.patterns);
            settings.places = given.places.or(settings.places);
            settings.apply(inbox, zerod.drops.as_deref());
            let _ = std::fs::write(daemon.home().join("settings.json"), serde_json::to_vec_pretty(&settings).unwrap_or_default());
            Ok(Value::Null)
        }
        other => Err(format!("Unknown op {other}")),
    }
}

/// A session for a list: everything but its items, and how it's doing, which can't be told without them.
/// Each session filed under a ticket: (ticket, session).
fn tasks(daemon: &Daemon) -> Vec<(String, String)> {
    daemon.sessions().iter().map(|s| s.summary()).filter_map(|c| Some((c.ticket?, c.id))).collect()
}

/// One task per item: its existing one, or a new one from the view's template with a state pad of its own in
/// Tasks/<ticket>.
fn start_task(zerod: &Zerod, integration: &str, view: &str, item: Value) -> Result<Value, String> {
    let item: crate::integrations::Item = serde_json::from_value(item).map_err(|e| format!("Not an item: {e}"))?;
    let ticket = item.ticket();
    let folder = format!("{}/{ticket}", crate::pads::TASKS);
    let pad = |pads: &crate::pads::Pads| pads.list_in(None, Some(&folder)).into_iter().find(|p| p.title == "State" && p.folder == folder).map(|p| p.link);
    if let Some((_, session)) = tasks(&zerod.daemon).into_iter().find(|(t, _)| *t == ticket) {
        return Ok(json!({"session": session, "existing": true, "pad": pad(&zerod.pads)}));
    }
    let (name, start) = zerod.integrations.start_of(integration, view)?;
    let start = start.ok_or_else(|| format!("{name} doesn't start tasks yet: give it a folder and a prompt in Integrations"))?;
    let pad = match pad(&zerod.pads) {
        Some(link) => link,
        None => zerod.pads.create("State", &folder, &format!("# {ticket} {}

{}

## State

## Next
", item.title, item.url))?.link,
    };
    let provider: Provider = serde_json::from_value(json!(start.provider.as_deref().unwrap_or("claude"))).map_err(|_| "The provider is codex, claude or opencode")?;
    let permissions: Option<Permissions> = start.permissions.as_ref().map(|p| serde_json::from_value(json!(p))).transpose().map_err(|_| "Permissions are auto or unrestricted")?;
    let options = crate::daemon::Options {
        cwd: Some(match start.cwd.strip_prefix("~/") { Some(rest) => format!("{}/{rest}", std::env::var("HOME").unwrap_or_default()), None => start.cwd.clone() }),
        workspace: None, model: start.model.clone(), effort: start.effort.clone(), permissions: Some(permissions.unwrap_or_default()),
        label: Some(format!("{ticket} {}", item.title)), ticket: Some(ticket), force: false, images: vec![], signin: None,
    };
    let session = zerod.daemon.start_with(provider, &crate::integrations::task_prompt(&start.prompt, &item, &pad), options)?;
    Ok(json!({"session": session, "existing": false, "pad": pad}))
}

/// In auto mode, a site new to the task gets a second opinion before the task may open it: a one-shot run of the task's
/// own CLI. A refusal stands unless the user approved the site through an ask (`zero approve`, whose id the agent passes
/// as `approval`). ponytail: only browser_navigate is reviewed; a click that leaves for another site isn't.
async fn review(zerod: &Zerod, conversation: &crate::model::Conversation, tool: &str, args: &Value) -> Result<(), String> {
    if tool != "browser_navigate" || conversation.permissions != crate::model::Permissions::Auto { return Ok(()) }
    let Some(site) = args["url"].as_str().and_then(crate::browser::site) else { return Ok(()) };
    if zerod.browsers.allowed(&conversation.id, &site) { return Ok(()) }
    if let Some(approval) = args["approval"].as_str() {
        let approved = zerod.inbox.asks().iter().any(|ask| ask.id == approval && ask.kind == crate::ask::AskKind::Approve && ask.state == crate::ask::AskState::Answered
            && format!("{} {}", ask.title, ask.body).to_lowercase().contains(&site));
        if !approved { return Err(format!("Ask {approval} isn't the user's approval of {site}: it must be an approve they said yes to, naming {site}")) }
        zerod.browsers.allow(&conversation.id, &site);
        return Ok(());
    }
    // What the user asked first, and what they asked last: a long task's current work is in the latter.
    let full = zerod.daemon.session(&conversation.id).map(|s| s.snapshot()).unwrap_or_else(|_| conversation.clone());
    let yours: Vec<String> = full.items.iter().filter_map(|item| match &item.kind {
        crate::model::ItemKind::User { text, .. } if crate::model::from(text).is_none() => Some(text.chars().take(600).collect::<String>()),
        _ => None,
    }).collect();
    let asked = match (yours.first(), yours.last()) {
        (Some(first), Some(last)) if first != last => format!("{first}\" and most recently: \"{last}"),
        (Some(first), _) => first.clone(),
        _ => String::new(),
    };
    let prompt = crate::browser::review_prompt(&crate::bridge::label(conversation), &asked, args["url"].as_str().unwrap_or_default());
    let (_, printed) = crate::process::run(&crate::browser::review_command(conversation.provider, &prompt), std::path::Path::new(&conversation.cwd), &conversation.id).await;
    match crate::browser::verdict(&printed) {
        Ok(_) => { zerod.browsers.allow(&conversation.id, &site); Ok(()) }
        Err(why) => Err(format!("Zero's reviewer advised against opening {site}: {}. If the task needs it, ask the user with zero approve \"Open {site} in Chrome\" and pass the ask's id as approval", why.trim_end_matches('.'))),
    }
}

fn summary(conversation: &crate::model::Conversation) -> Value {
    let mut summary = json!(crate::model::Conversation { items: vec![], ..conversation.clone() });
    summary["attention"] = json!(conversation.attention());
    summary
}

/// What isn't a session's change, pushed rather than polled for: the board whenever it changes (worked out at most
/// four times a second while sessions change, and every half minute for what changes on its own, places and clocks),
/// and each notice ("pads").
async fn feed(zerod: Zerod, out: mpsc::UnboundedSender<Value>) {
    let (mut sessions, mut asks, mut notices, mut queues) = (zerod.daemon.subscribe(), zerod.inbox.subscribe(), zerod.notices.subscribe(), zerod.daemon.subscribe_queues());
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
    let mut last: Option<Value> = None;
    loop {
        let rows = json!(zerod.board());
        if last.as_ref() != Some(&rows) {
            if out.send(json!({"event": "board", "rows": rows})).is_err() { return }
            last = Some(rows);
        }
        tokio::select! {
            heard = sessions.recv() => if matches!(heard, Err(broadcast::error::RecvError::Closed)) { return },
            heard = asks.recv() => if matches!(heard, Err(broadcast::error::RecvError::Closed)) { return },
            // A queue changed by the user's hand (queued, taken out, sent): shown at once, not after the settle.
            heard = queues.recv() => match heard { Err(broadcast::error::RecvError::Closed) => return, _ => continue },
            notice = notices.recv() => match notice {
                Ok(notice) => { if out.send(json!({"event": notice})).is_err() { return } continue }
                Err(broadcast::error::RecvError::Closed) => return,
                Err(broadcast::error::RecvError::Lagged(_)) => { let _ = out.send(json!({"event": "pads"})); continue }
            },
            _ = tick.tick() => {}
        }
        // A burst (a turn streaming) settles before the board is worked out again.
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        while sessions.try_recv().is_ok() {}
        while asks.try_recv().is_ok() {}
        while queues.try_recv().is_ok() {}
    }
}

/// How many of a session's latest items a snapshot carries.
pub const RECENT: usize = 40;

/// Every session's snapshot, then each change after it; a session seen for the first time, or one whose changes
/// skipped ahead (the subscriber fell behind), gets a fresh snapshot instead.
async fn subscribe(daemon: Arc<Daemon>, out: mpsc::UnboundedSender<Value>, lazy: bool) {
    // Listening starts before the snapshots, so no change falls between the two; ones already in a snapshot are skipped.
    let mut events = daemon.subscribe();
    let mut known: HashMap<String, u64> = HashMap::new();
    // A snapshot carries a session's latest items and how many came before: the app asks for older pages as it needs them.
    let snapshot = |known: &mut HashMap<String, u64>, session: &crate::session::Session| {
        let (conversation, earlier) = session.recent(RECENT);
        known.insert(conversation.id.clone(), conversation.seq);
        out.send(json!({"event": "session", "conversation": conversation, "earlier": earlier})).is_ok()
    };
    for session in daemon.sessions() {
        if !lazy && !snapshot(&mut known, &session) { return }
    }
    loop {
        let sent = match events.recv().await {
            Ok(event) => match known.get(&event.session).copied() {
                Some(seq) if event.seq <= seq => true,
                Some(seq) if event.seq == seq + 1 => {
                    known.insert(event.session.clone(), event.seq);
                    out.send(json!({"event": "change", "session": event.session, "seq": event.seq, "change": event.change})).is_ok()
                }
                _ => match daemon.session(&event.session) {
                    Ok(session) => snapshot(&mut known, &session),
                    Err(_) => true,
                },
            },
            // Behind: fresh snapshots of what it has (a lazy subscriber has only some).
            Err(broadcast::error::RecvError::Lagged(_)) => {
                let behind: Vec<_> = daemon.sessions().into_iter().filter(|s| !lazy || known.contains_key(&s.id())).collect();
                behind.iter().all(|s| snapshot(&mut known, s))
            }
            Err(broadcast::error::RecvError::Closed) => return,
        };
        if !sent { return }
    }
}

/// The inbox's asks, then each change; one that falls behind gets a fresh snapshot.
async fn follow_inbox(inbox: Arc<Inbox>, out: mpsc::UnboundedSender<Value>) {
    let mut events = inbox.subscribe();
    let snapshot = |inbox: &Inbox| {
        let (offline, reachable) = inbox.agents();
        out.send(json!({"event": "asks", "asks": inbox.asks(), "offline": offline, "reachable": reachable})).is_ok()
    };
    if !snapshot(&inbox) { return }
    loop {
        let sent = match events.recv().await {
            Ok(InboxEvent::Ask(ask)) => out.send(json!({"event": "ask", "ask": ask})).is_ok(),
            Ok(InboxEvent::Output { id, chunk }) => out.send(json!({"event": "output", "ask": id, "chunk": chunk})).is_ok(),
            Ok(InboxEvent::Removed(id)) => out.send(json!({"event": "removed", "ask": id})).is_ok(),
            Ok(InboxEvent::Agents { offline, reachable }) => out.send(json!({"event": "agents", "offline": offline, "reachable": reachable})).is_ok(),
            Err(broadcast::error::RecvError::Lagged(_)) => snapshot(&inbox),
            Err(broadcast::error::RecvError::Closed) => return,
        };
        if !sent { return }
    }
}

/// Starts a Codex sign-in: a pending sign-in and its home, Codex's app-server run there, and its ChatGPT page given
/// back for the app to open (none for an API key). Once Codex says who signed in, the sign-in takes their email and
/// plan; turned down or left for a quarter of an hour, it goes. The key, if one is given, goes only to Codex.
async fn codex_sign_in(zerod: &Zerod, asked: Option<&Value>) -> Result<Value, String> {
    use crate::signins::{Kind, SignIn};
    let key = asked.and_then(|a| a["apiKey"].as_str()).filter(|k| !k.trim().is_empty()).map(|k| k.trim().to_string());
    let label = asked.and_then(|a| a["label"].as_str()).filter(|l| !l.trim().is_empty()).unwrap_or(if key.is_some() { "OpenAI API key" } else { "Codex" }).to_string();
    let signins = &zerod.daemon.signins;
    let signin = signins.save(SignIn { id: String::new(), cli: Provider::Codex, kind: Kind::CodexHome, label: label.clone(), plan: None, variable: None, pending: true })?;
    let home = signins.folder(Provider::Codex, &signin.id)?;
    let (child, input, output) = codex_in(&home).inspect_err(|_| { let _ = signins.delete(&signin.id); })?;
    let (page, opened) = tokio::sync::oneshot::channel();
    let method = key.map(crate::codex_login::Method::ApiKey).unwrap_or(crate::codex_login::Method::ChatGpt);
    let (daemon, notices, id) = (zerod.daemon.clone(), zerod.notices.clone(), signin.id.clone());
    tokio::spawn(async move {
        let outcome = tokio::time::timeout(SIGN_IN_TIME, crate::codex_login::sign_in(output, input, method, page)).await
            .unwrap_or_else(|_| Err("the sign-in wasn't finished".into()));
        signed_in(&daemon, &notices, &id, label, outcome);
        drop(child);
        name_codex_accounts(&daemon, &notices).await;
    });
    let _ = zerod.notices.send("signins");
    let page = tokio::time::timeout(std::time::Duration::from_secs(30), opened).await.ok().and_then(Result::ok).flatten();
    Ok(json!({"id": signin.id, "page": page}))
}

/// Codex's app-server, run in a sign-in's home.
fn codex_in(home: &std::path::Path) -> Result<(tokio::process::Child, tokio::process::ChildStdin, tokio::process::ChildStdout), String> {
    let argv = Provider::Codex.command(&crate::model::Conversation::new("", Provider::Codex, ""), false, None, None);
    let mut child = tokio::process::Command::new(&argv[0]).args(&argv[1..]).env("CODEX_HOME", home).current_dir(home)
        .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null())
        .kill_on_drop(true).spawn().map_err(|e| format!("Couldn't start Codex: {e}"))?;
    let (Some(input), Some(output)) = (child.stdin.take(), child.stdout.take()) else { return Err("Codex has no stdio".into()) };
    Ok((child, input, output))
}

/// Codex accounts that don't say whose they are (signed in before Zero asked, or Codex hadn't said yet) are asked
/// of Codex, in their homes: the email becomes the name unless the user gave it one, and the plan is kept.
pub async fn name_codex_accounts(daemon: &Daemon, notices: &broadcast::Sender<&'static str>) {
    use crate::signins::Kind;
    for mut signin in daemon.signins.list() {
        if signin.kind != Kind::CodexHome || signin.pending || signin.plan.is_some() { continue }
        let Ok(home) = daemon.signins.folder(Provider::Codex, &signin.id) else { continue };
        let Ok((child, input, output)) = codex_in(&home) else { continue };
        let account = tokio::time::timeout(std::time::Duration::from_secs(30), crate::codex_login::account(output, input)).await;
        drop(child);
        let Ok(Ok(account)) = account else { continue };
        let before = signin.clone();
        if signin.label == "Codex" && let Some(email) = account.email { signin.label = email }
        signin.plan = account.plan;
        if signin != before && daemon.signins.save(signin).is_ok() { let _ = notices.send("signins"); }
    }
}

/// How long a sign-in is waited for in the browser before it's let go.
const SIGN_IN_TIME: std::time::Duration = std::time::Duration::from_secs(15 * 60);

/// A sign-in's end: who signed in, on the pending sign-in; else it goes.
fn signed_in(daemon: &Daemon, notices: &broadcast::Sender<&'static str>, id: &str, label: String, outcome: Result<crate::codex_login::Account, String>) {
    match (outcome, daemon.signins.get(id)) {
        (Ok(account), Some(mut signin)) => {
            signin.label = account.email.unwrap_or(label);
            signin.plan = account.plan;
            signin.pending = false;
            let _ = daemon.signins.save(signin);
        }
        (Err(error), _) => { eprintln!("zerod: sign-in: {error}"); let _ = daemon.signins.delete(id); }
        (Ok(_), None) => {}
    }
    let _ = notices.send("signins");
}

/// Starts a Claude sign-in: a pending sign-in and its own Claude Code folder, `claude auth login` run there (Claude
/// Code opens its page in the browser), and that page given back in case it didn't open. Once Claude Code is signed
/// in, the sign-in takes the account's email and plan from `claude auth status`.
async fn claude_sign_in(zerod: &Zerod) -> Result<Value, String> {
    use crate::signins::{Kind, SignIn};
    let signins = &zerod.daemon.signins;
    let signin = signins.save(SignIn { id: String::new(), cli: Provider::Claude, kind: Kind::ClaudeHome, label: "Claude".into(), plan: None, variable: None, pending: true })?;
    let env = signins.environment(&SignIn { pending: false, ..signin.clone() })?;
    let (page, opened) = tokio::sync::oneshot::channel();
    let (daemon, notices, id) = (zerod.daemon.clone(), zerod.notices.clone(), signin.id.clone());
    tokio::spawn(async move {
        let outcome = tokio::time::timeout(SIGN_IN_TIME, crate::claude_login::sign_in(&crate::claude_login::Commands::claude(), &env, page)).await
            .unwrap_or_else(|_| Err("the sign-in wasn't finished".into()));
        signed_in(&daemon, &notices, &id, "Claude".into(), outcome);
    });
    let _ = zerod.notices.send("signins");
    let page = tokio::time::timeout(std::time::Duration::from_secs(3), opened).await.ok().and_then(Result::ok).flatten();
    Ok(json!({"id": signin.id, "page": page}))
}
