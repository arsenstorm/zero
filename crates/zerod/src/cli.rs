//! The `zero` CLI's socket (~/.zero/zero.sock), as the Swift app served it: one JSON object per line. `create` and `wait`
//! keep the connection open until the ask is final, sending a run's output as `output` lines and one `done` at the end;
//! the CLI reconnects with `wait` if the connection drops, since open asks outlive it.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast;

use crate::ask::Ask;
use crate::inbox::{Inbox, InboxEvent};

#[derive(Deserialize)]
struct Request {
    op: String,
    ask: Option<Ask>,
    id: Option<String>,
    wait: Option<bool>,
    agent: Option<String>,
    text: Option<String>,
    /// For `list`: only the asks still open.
    open: Option<bool>,
}

#[derive(Serialize, Default)]
struct Response {
    op: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ask: Option<Ask>,
    #[serde(skip_serializing_if = "Option::is_none")]
    asks: Option<Vec<Ask>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chunk: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

pub async fn serve(inbox: Arc<Inbox>, socket: PathBuf) -> std::io::Result<()> {
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    loop {
        let stream = crate::server::next_connection(&listener).await;
        tokio::spawn(connection(inbox.clone(), stream));
    }
}

async fn send(out: &mut OwnedWriteHalf, response: Response) -> bool {
    let mut line = serde_json::to_vec(&response).unwrap_or_default();
    line.push(b'\n');
    out.write_all(&line).await.is_ok()
}

fn error(message: String) -> Response {
    Response { op: "error", message: Some(message), ..Default::default() }
}

async fn connection(inbox: Arc<Inbox>, stream: UnixStream) {
    let (read, mut out) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    let Ok(Some(line)) = lines.next_line().await else { return };
    let request: Request = match serde_json::from_str(&line) {
        Ok(request) => request,
        Err(e) => {
            send(&mut out, error(format!("not a request: {e}"))).await;
            return;
        }
    };
    match request.op.as_str() {
        "create" => {
            let Some(mut incoming) = request.ask else {
                send(&mut out, error("create needs an ask".into())).await;
                return;
            };
            // An anchor that isn't there (`--about "#plan"`) is the agent's to fix: told, and nothing asked.
            if let Err(message) = inbox.about(&mut incoming) {
                send(&mut out, error(message)).await;
                return;
            }
            let waits = request.wait.unwrap_or(true);
            if !waits {
                incoming.waits = Some(false)
            }
            // Listening starts before the ask exists, so not even an instant answer slips past.
            let events = inbox.subscribe();
            let ask = inbox.create(incoming, false);
            if !send(&mut out, Response { op: "created", id: Some(ask.id.clone()), ..Default::default() }).await || !waits {
                return;
            }
            park(&inbox, events, &ask.id, out, lines).await;
        }
        "wait" => {
            let Some(id) = request.id else {
                send(&mut out, error("wait needs an id".into())).await;
                return;
            };
            let events = inbox.subscribe();
            park(&inbox, events, &id, out, lines).await;
        }
        "status" => {
            let id = request.id.unwrap_or_default();
            let response = match inbox.ask(&id) {
                Some(ask) => Response { op: "ask", ask: Some(ask), ..Default::default() },
                None => error(format!("no such ask {id}")),
            };
            send(&mut out, response).await;
        }
        // `zero done`: said, refused with what done means and a token; with the token, done; --ask, the user's word.
        "done" => {
            let Some(said) = request.ask else {
                send(&mut out, error("done needs the agent and what's done".into())).await;
                return;
            };
            // A worker's `--ask` asks no one: its done is its lead's to judge (Inbox::done).
            let reply = if request.text.as_deref() == Some("ask") && !inbox.is_worker(&said.agent) {
                Response { op: "created", id: Some(inbox.ask_done(&said.agent, &said.body).id), ..Default::default() }
            } else {
                match inbox.done(&said.agent, &said.body, request.id.as_deref()) {
                    Ok(()) => Response { op: "marked", ..Default::default() },
                    Err(why) => Response { op: "notDone", message: Some(why), ..Default::default() },
                }
            };
            send(&mut out, reply).await;
        }
        // `zero blocked`: as done, refused with what blocked means and a token; with the token, blocked.
        "blocked" => {
            let Some(said) = request.ask else {
                send(&mut out, error("blocked needs the agent and what blocks it".into())).await;
                return;
            };
            let reply = match inbox.blocked(&said.agent, &said.body, request.id.as_deref()) {
                Ok(()) => Response { op: "marked", ..Default::default() },
                Err(why) => Response { op: "notBlocked", message: Some(why), ..Default::default() },
            };
            send(&mut out, reply).await;
        }
        "withdraw" => {
            let Some(id) = request.id else {
                send(&mut out, error("withdraw needs an id".into())).await;
                return;
            };
            inbox.withdraw(&id, request.text.as_deref());
            send(&mut out, Response { op: "withdrawn", id: Some(id), ..Default::default() }).await;
        }
        "prompt" => {
            // The plugin's prompt hook: who typed what just arrived in the agent's session.
            let Some(ask) = request.ask else {
                send(&mut out, error("prompt needs the agent and its text".into())).await;
                return;
            };
            let source = inbox.prompted(&ask.agent, &ask.body);
            send(&mut out, Response { op: "prompt", message: Some(source.into()), ..Default::default() }).await;
        }
        "list" => {
            let asks = if request.open == Some(true) { inbox.open_asks() } else { inbox.asks() };
            send(&mut out, Response { op: "asks", asks: Some(asks), ..Default::default() }).await;
        }
        "message" => {
            let (Some(agent), Some(text)) = (request.agent, request.text) else {
                send(&mut out, error("message needs an agent and text".into())).await;
                return;
            };
            tokio::spawn(async move {
                let _ = inbox.message(&text, &agent).await;
            });
            send(&mut out, Response { op: "created", ..Default::default() }).await;
        }
        other => {
            send(&mut out, error(format!("unknown op {other}"))).await;
        }
    }
}

/// Holds the connection until the ask is final, streaming a run's output; ends early if the client hangs up.
async fn park(
    inbox: &Inbox, mut events: broadcast::Receiver<InboxEvent>, id: &str, mut out: OwnedWriteHalf,
    mut lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
) {
    let Some(ask) = inbox.ask(id) else {
        send(&mut out, error(format!("no such ask {id}"))).await;
        return;
    };
    if ask.state.is_final() {
        send(&mut out, Response { op: "done", ask: Some(ask), ..Default::default() }).await;
        return;
    }
    if !ask.output.is_empty()
        && !send(&mut out, Response { op: "output", id: Some(id.into()), chunk: Some(ask.output), ..Default::default() }).await
    {
        return;
    }
    loop {
        tokio::select! {
            event = events.recv() => match event {
                Ok(InboxEvent::Output { id: of, chunk }) if of == id => {
                    if !send(&mut out, Response { op: "output", id: Some(of), chunk: Some(chunk), ..Default::default() }).await { return }
                }
                Ok(InboxEvent::Ask(ask)) if ask.id == id && ask.state.is_final() => {
                    send(&mut out, Response { op: "done", ask: Some(*ask), ..Default::default() }).await;
                    return;
                }
                Ok(_) => {}
                // Fell behind: the ask as it is now settles it.
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    if let Some(ask) = inbox.ask(id).filter(|a| a.state.is_final()) {
                        send(&mut out, Response { op: "done", ask: Some(ask), ..Default::default() }).await;
                        return;
                    }
                }
                Err(broadcast::error::RecvError::Closed) => return,
            },
            // The client hung up (or wrote something): either way it's no longer waiting here.
            _ = lines.next_line() => return,
        }
    }
}
