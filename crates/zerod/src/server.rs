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
        "list" => Ok(json!(daemon.list())),
        "get" => daemon.get(&session()?).map(|c| json!(c)).ok_or_else(|| format!("No session {}", request.session.unwrap_or_default())),
        "start" => {
            let provider = request.provider.ok_or("Start needs a provider: codex, claude or opencode")?;
            let cwd = request.cwd.as_deref().ok_or("Start needs a folder")?;
            let id = daemon.start(provider, cwd, request.prompt.as_deref().unwrap_or(""), model, effort, request.permissions.unwrap_or_default())?;
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
        other => Err(format!("Unknown op {other}")),
    }
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
