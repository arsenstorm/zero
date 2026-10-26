//! The daemon's socket: one JSON object per line each way. A request `{"id", "op", …}` gets `{"id", "ok",
//! "result"}` or `{"id", "ok": false, "error"}`; requests run concurrently, so answers can come out of order.
//! After `subscribe`, the connection also gets `{"event": "session", "conversation"}` (a snapshot) and
//! `{"event": "change", "session", "seq", "change"}`; a client applies a change only if its `seq` follows its copy.

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
}

/// Serves until the listener fails. The socket is the owner's only: whoever can write to it runs agents.
pub async fn serve(daemon: Arc<Daemon>, socket: PathBuf) -> std::io::Result<()> {
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    loop {
        let (stream, _) = listener.accept().await?;
        tokio::spawn(connection(daemon.clone(), stream));
    }
}

async fn connection(daemon: Arc<Daemon>, stream: UnixStream) {
    let (read, mut write) = stream.into_split();
    let (out, mut lines_out) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        while let Some(message) = lines_out.recv().await {
            let mut line = serde_json::to_vec(&message).unwrap_or_default();
            line.push(b'\n');
            if write.write_all(&line).await.is_err() { break }
        }
    });
    let mut subscription = None;
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
            if subscription.is_none() { subscription = Some(tokio::spawn(subscribe(daemon.clone(), out.clone()))) }
            let _ = out.send(json!({"id": request.id, "ok": true, "result": null}));
            continue;
        }
        let (daemon, out) = (daemon.clone(), out.clone());
        tokio::spawn(async move {
            let id = request.id.clone();
            let answer = match handle(&daemon, request).await {
                Ok(result) => json!({"id": id, "ok": true, "result": result}),
                Err(error) => json!({"id": id, "ok": false, "error": error}),
            };
            let _ = out.send(answer);
        });
    }
    if let Some(subscription) = subscription { subscription.abort() }
    drop(out);
    let _ = writer.await;
}

async fn handle(daemon: &Daemon, request: Request) -> Result<Value, String> {
    let session = || request.session.clone().ok_or("Which session?");
    let model = request.model.as_deref();
    let effort = request.effort.as_deref();
    match request.op.as_str() {
        "hello" => Ok(json!({"version": VERSION, "pid": std::process::id()})),
        "list" => Ok(json!(daemon.sessions().iter().map(|s| summary(&s.snapshot())).collect::<Vec<_>>())),
        "get" => daemon.get(&session()?).map(|c| json!(c)).ok_or_else(|| format!("No session {}", request.session.unwrap_or_default())),
        "start" => {
            let provider = request.provider.ok_or("Start needs a provider: codex, claude or opencode")?;
            let cwd = request.cwd.as_deref().ok_or("Start needs a folder")?;
            let options = crate::daemon::Options {
                cwd: Some(cwd.into()), model: request.model.clone(), effort: request.effort.clone(), permissions: Some(request.permissions.unwrap_or_default()),
                label: request.label.clone(), ticket: request.ticket.clone(), force: request.force.unwrap_or(false),
            };
            let id = daemon.start_with(provider, request.prompt.as_deref().unwrap_or(""), options)?;
            Ok(json!({"session": id}))
        }
        "send" => daemon.send(&session()?, request.text.as_deref().ok_or("Send needs text")?, model, effort).await.map(|_| Value::Null),
        "resume" => daemon.resume(&session()?).await.map(|_| Value::Null),
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
        "workers" => {
            let lead = session()?;
            Ok(json!(daemon.sessions().iter().map(|s| s.snapshot()).filter(|c| c.parent.as_deref() == Some(lead.as_str())).map(|c| summary(&c)).collect::<Vec<_>>()))
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
        other => Err(format!("Unknown op {other}")),
    }
}

/// A session for a list: everything but its items, and how it's doing, which can't be told without them.
fn summary(conversation: &crate::model::Conversation) -> Value {
    let mut summary = json!(crate::model::Conversation { items: vec![], ..conversation.clone() });
    summary["attention"] = json!(conversation.attention());
    summary
}

/// Every session's snapshot, then each change after it; a session seen for the first time, or one whose changes
/// skipped ahead (the subscriber fell behind), gets a fresh snapshot instead.
async fn subscribe(daemon: Arc<Daemon>, out: mpsc::UnboundedSender<Value>) {
    // Listening starts before the snapshots, so no change falls between the two; ones already in a snapshot are skipped.
    let mut events = daemon.subscribe();
    let mut known: HashMap<String, u64> = HashMap::new();
    let snapshot = |known: &mut HashMap<String, u64>, conversation: crate::model::Conversation| {
        known.insert(conversation.id.clone(), conversation.seq);
        out.send(json!({"event": "session", "conversation": conversation})).is_ok()
    };
    for session in daemon.sessions() {
        if !snapshot(&mut known, session.snapshot()) { return }
    }
    loop {
        let sent = match events.recv().await {
            Ok(event) => match known.get(&event.session).copied() {
                Some(seq) if event.seq <= seq => true,
                Some(seq) if event.seq == seq + 1 => {
                    known.insert(event.session.clone(), event.seq);
                    out.send(json!({"event": "change", "session": event.session, "seq": event.seq, "change": event.change})).is_ok()
                }
                _ => match daemon.get(&event.session) {
                    Some(conversation) => snapshot(&mut known, conversation),
                    None => true,
                },
            },
            Err(broadcast::error::RecvError::Lagged(_)) => daemon.sessions().into_iter().all(|s| snapshot(&mut known, s.snapshot())),
            Err(broadcast::error::RecvError::Closed) => return,
        };
        if !sent { return }
    }
}
