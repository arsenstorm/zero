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
    /// `pad`: a scratchpad tool (list, read, write…) and its arguments, as the MCP server's.
    tool: Option<String>,
    args: Option<Value>,
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
    /// items: the page of a session's items before this one, or all of them from `from`.
    before: Option<String>,
    from: Option<String>,
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
    pub places: Arc<crate::board::Places>,
    /// Changes that aren't a session's, for subscribers: "pads" when a scratchpad changes.
    pub notices: broadcast::Sender<&'static str>,
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
            if subscription.is_none() { subscription = Some(tokio::spawn(subscribe(zerod.daemon.clone(), out.clone()))) }
            if feed.is_none() { feed = Some(tokio::spawn(self::feed(zerod.clone(), out.clone()))) }
            let _ = out.send(json!({"id": request.id, "ok": true, "result": null}));
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
    let state = |settings: crate::integrations::Settings| json!({"settings": settings, "linear": integrations.linear_workspace(), "github": integrations.github_known()});
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
        "pad" => {
            let tool = request.tool.as_deref().ok_or("Which scratchpad tool?")?;
            let result = crate::pads::call(&zerod.pads, tool, request.args.as_ref().unwrap_or(&Value::Null));
            if result.is_ok() && !matches!(tool, "list" | "read" | "find") { let _ = zerod.notices.send("pads"); }
            result
        }
        "hello" => Ok(json!({"version": VERSION, "pid": std::process::id()})),
        "list" => Ok(json!(daemon.sessions().iter().map(|s| summary(&s.summary())).collect::<Vec<_>>())),
        "get" => daemon.get(&session()?).map(|c| json!(c)).ok_or_else(|| format!("No session {}", request.session.unwrap_or_default())),
        "start" => {
            let provider = request.provider.ok_or("Start needs a provider: codex, claude or opencode")?;
            let cwd = request.cwd.as_deref().ok_or("Start needs a folder")?;
            let options = crate::daemon::Options {
                cwd: Some(cwd.into()), model: request.model.clone(), effort: request.effort.clone(), permissions: Some(request.permissions.unwrap_or_default()),
                label: request.label.clone(), ticket: request.ticket.clone(), force: request.force.unwrap_or(false),
                images: request.images.clone().unwrap_or_default(),
            };
            let id = daemon.start_with(provider, request.prompt.as_deref().unwrap_or(""), options)?;
            Ok(json!({"session": id}))
        }
        "send" => {
            let images = request.images.clone().unwrap_or_default();
            let text = request.text.as_deref().filter(|t| !t.trim().is_empty() || !images.is_empty()).ok_or("Send needs text")?;
            daemon.send_with_images(&session()?, text, &images, model, effort).await.map(|_| Value::Null)
        }
        "resume" => daemon.resume(&session()?).await.map(|_| Value::Null),
        "openTerminal" => daemon.open_terminal(&session()?).await.map(|terminal| json!({"terminal": terminal})),
        // From a session: the task or Claude Code session becomes its worker.
        "adopt" if request.session.is_some() => daemon.adopt_into(&session()?, request.thread.as_deref().ok_or("Which task or session?")?).map(|id| json!({"session": id})),
        "adopt" => {
            let options = crate::daemon::Options { label: request.label.clone(), ticket: request.ticket.clone(), permissions: request.permissions, ..Default::default() };
            daemon.adopt(request.provider.unwrap_or(Provider::Claude), request.thread.as_deref().ok_or("Which session?")?,
                         request.cwd.as_deref().ok_or("Which folder?")?, options).map(|id| json!({"session": id}))
        }
        "archive" => daemon.archive(&session()?).await.map(|_| Value::Null),
        // A new build is on disk: turns under way pause between steps, then zerod becomes the new one, which carries
        // them on. Answered at once; the restart happens when the last turn has paused.
        "restart" => {
            let daemon = daemon.clone();
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
                cwd: request.cwd.clone(), model: request.model.clone(), effort: request.effort.clone(), permissions: request.permissions,
                label: request.label.clone(), ticket: request.ticket.clone(), force: request.force.unwrap_or(false),
                images: request.images.clone().unwrap_or_default(),
            };
            let id = daemon.spawn(&lead, provider, request.prompt.as_deref().unwrap_or(""), options)?;
            Ok(json!({"session": id}))
        }
        "notify" => daemon.notify(&session()?, request.text.as_deref().ok_or("Notify with text")?).map(|_| Value::Null),
        "watch" => daemon.watch(&session()?, request.command.as_deref().ok_or("Watch which command?")?).map(|_| Value::Null),
        "remind" => {
            let after = std::time::Duration::from_secs(request.minutes.ok_or("Remind in how many minutes?")? * 60);
            daemon.remind(&session()?, after, request.text.as_deref().ok_or("Remind with text")?).map(|_| Value::Null)
        }
        "usage" => Ok(json!(daemon.usage().into_iter().map(|(provider, usage)| json!({"provider": provider, "usage": usage})).collect::<Vec<_>>())),
        "label" => daemon.label(&session()?, request.label.as_deref(), request.ticket.as_deref()).map(|_| Value::Null),
        "attr" => daemon.set_attribute(&session()?, request.name.as_deref().ok_or("Which attribute?")?, request.value.as_deref()).map(|_| Value::Null),
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
        "board" => Ok(json!(crate::board::board_with(&daemon.sessions().iter().map(|s| s.summary()).collect::<Vec<_>>(), &inbox.asks(), &zerod.places.get()))),
        "items" => Ok(json!(daemon.session(&session()?)?.items(request.before.as_deref(), request.from.as_deref(), request.limit.unwrap_or(60)))),
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
        model: start.model.clone(), effort: start.effort.clone(), permissions: Some(permissions.unwrap_or_default()),
        label: Some(format!("{ticket} {}", item.title)), ticket: Some(ticket), force: false, images: vec![],
    };
    let session = zerod.daemon.start_with(provider, &crate::integrations::task_prompt(&start.prompt, &item, &pad), options)?;
    Ok(json!({"session": session, "existing": false, "pad": pad}))
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
    let (mut sessions, mut asks, mut notices) = (zerod.daemon.subscribe(), zerod.inbox.subscribe(), zerod.notices.subscribe());
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
    let mut last: Option<Value> = None;
    loop {
        let rows = json!(crate::board::board_with(&zerod.daemon.sessions().iter().map(|s| s.summary()).collect::<Vec<_>>(), &zerod.inbox.asks(), &zerod.places.get()));
        if last.as_ref() != Some(&rows) {
            if out.send(json!({"event": "board", "rows": rows})).is_err() { return }
            last = Some(rows);
        }
        tokio::select! {
            heard = sessions.recv() => if matches!(heard, Err(broadcast::error::RecvError::Closed)) { return },
            heard = asks.recv() => if matches!(heard, Err(broadcast::error::RecvError::Closed)) { return },
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
    }
}

/// How many of a session's latest items a snapshot carries.
pub const RECENT: usize = 40;

/// Every session's snapshot, then each change after it; a session seen for the first time, or one whose changes
/// skipped ahead (the subscriber fell behind), gets a fresh snapshot instead.
async fn subscribe(daemon: Arc<Daemon>, out: mpsc::UnboundedSender<Value>) {
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
        if !snapshot(&mut known, &session) { return }
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
            Err(broadcast::error::RecvError::Lagged(_)) => daemon.sessions().iter().all(|s| snapshot(&mut known, s)),
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
