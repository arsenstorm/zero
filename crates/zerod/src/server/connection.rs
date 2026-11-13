//! The socket's connections: requests read and answered, and what a connection follows (sessions, the inbox, the
//! board and notices) pushed to it.

use std::collections::HashMap;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc};

use super::{RECENT, Request, Zerod, handle};
use crate::daemon::Daemon;
use crate::inbox::{Inbox, InboxEvent};

/// Serves until the listener fails. The socket is the owner's only: whoever can write to it runs agents.
pub async fn serve(zerod: Zerod, socket: PathBuf) -> std::io::Result<()> {
    let inbox = Arc::downgrade(&zerod.inbox);
    zerod.daemon.note_with(Box::new(move |id, text| match inbox.upgrade() {
        Some(inbox) => inbox.with_open_asks(id, text),
        None => text,
    }));
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    loop {
        let stream = next_connection(&listener).await;
        tokio::spawn(connection(zerod.clone(), stream));
    }
}

/// The next connection, however long that takes. A failed accept (out of descriptors, a client gone before it was
/// taken) passes: a listener that gave up on one left its socket on disk with nothing answering, until a restart.
pub(crate) async fn next_connection(listener: &UnixListener) -> UnixStream {
    loop {
        match listener.accept().await {
            Ok((stream, _)) => return stream,
            Err(error) => {
                eprintln!("zerod: couldn't accept a connection: {error}");
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
}

async fn connection(zerod: Zerod, stream: UnixStream) {
    let token = crate::peer::audit_token(std::os::fd::AsRawFd::as_raw_fd(&stream));
    // Whether the peer may make the app's own ops: asked once, the first time it makes one.
    let mut app: Option<bool> = None;
    let (read, mut write) = stream.into_split();
    let (out, mut lines_out) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        while let Some(message) = lines_out.recv().await {
            let mut line = serde_json::to_vec(&message).unwrap_or_default();
            line.push(b'\n');
            if write.write_all(&line).await.is_err() {
                break;
            }
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
        if super::APP_ONLY.contains(&request.op.as_str()) && !*app.get_or_insert_with(|| (zerod.peers)(token)) {
            let error = format!("{} is the user's to do, and only Zero.app does it: ask the user instead (zero ask)", request.op);
            let _ = out.send(json!({"id": request.id, "ok": false, "error": error}));
            continue;
        }
        if request.op == "subscribe" {
            if subscription.is_none() {
                subscription = Some(tokio::spawn(subscribe(zerod.daemon.clone(), out.clone(), request.lazy.unwrap_or(false))))
            }
            if feed.is_none() {
                feed = Some(tokio::spawn(self::feed(zerod.clone(), out.clone())))
            }
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
            if let Some(answer) = &request.browser {
                zerod.browsers.answer(answer)
            }
            continue;
        }
        if request.op == "inbox" {
            if inbox.is_none() {
                inbox = Some(tokio::spawn(follow_inbox(zerod.inbox.clone(), out.clone())))
            }
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
    for task in [subscription, inbox, feed].into_iter().flatten() {
        task.abort()
    }
    if let Some(browser) = browser {
        zerod.browsers.detach(&browser)
    }
    drop(out);
    let _ = writer.await;
}

/// What isn't a session's change, pushed rather than polled for: the board whenever it changes (worked out at most
/// four times a second while sessions change, and every half minute for what changes on its own, places and clocks),
/// each notice ("pads"), and what tasks' processes use and what they left running, at once and whenever it changes
/// enough to show (uses.rs, left.rs).
async fn feed(zerod: Zerod, out: mpsc::UnboundedSender<Value>) {
    let (mut sessions, mut asks, mut notices, mut queues) =
        (zerod.daemon.subscribe(), zerod.inbox.subscribe(), zerod.notices.subscribe(), zerod.daemon.subscribe_queues());
    let (mut uses, mut left) = (zerod.daemon.uses(), zerod.daemon.left());
    if out.send(json!({"event": "uses", "tasks": *uses.borrow_and_update()})).is_err()
        || out.send(json!({"event": "left", "tasks": *left.borrow_and_update()})).is_err()
    {
        return;
    }
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
    let mut last: Option<Value> = None;
    loop {
        let rows = json!(zerod.shared_board());
        if last.as_ref() != Some(&rows) {
            if out.send(json!({"event": "board", "rows": rows})).is_err() {
                return;
            }
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
            changed = uses.changed() => {
                if changed.is_err() || out.send(json!({"event": "uses", "tasks": *uses.borrow_and_update()})).is_err() { return }
                continue
            }
            changed = left.changed() => {
                if changed.is_err() || out.send(json!({"event": "left", "tasks": *left.borrow_and_update()})).is_err() { return }
                continue
            }
            _ = tick.tick() => {}
        }
        // A burst (a turn streaming) settles before the board is worked out again.
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        while sessions.try_recv().is_ok() {}
        while asks.try_recv().is_ok() {}
        while queues.try_recv().is_ok() {}
    }
}

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
        if !lazy && !snapshot(&mut known, &session) {
            return;
        }
    }
    loop {
        let sent = match events.recv().await {
            Ok(event) => match known.get(&event.session).copied() {
                Some(seq) if event.seq <= seq => true,
                // An undone rewind brings back what clients let go of: they're sent the session afresh instead.
                Some(seq) if event.seq == seq + 1 && event.change != crate::model::Change::Unrewound => {
                    known.insert(event.session.clone(), event.seq);
                    out.send(json!({"event": "change", "session": event.session, "seq": event.seq, "change": event.change})).is_ok()
                }
                _ => match daemon.session(&event.session) {
                    Ok(session) => snapshot(&mut known, &session),
                    Err(_) => true,
                },
            },
            // Behind: what's left of the backlog skipped (the snapshots have it), and fresh snapshots of only what
            // changed since it was sent (a lazy subscriber has only some). Every session again, each with its whole
            // latest turn, took long enough during a burst to fall behind again, over and over.
            Err(broadcast::error::RecvError::Lagged(_)) => {
                events = events.resubscribe();
                let behind: Vec<_> = daemon
                    .sessions()
                    .into_iter()
                    .filter(|s| match known.get(&s.id()) {
                        Some(&seq) => s.seq() != seq,
                        None => !lazy,
                    })
                    .collect();
                behind.iter().all(|s| snapshot(&mut known, s))
            }
            Err(broadcast::error::RecvError::Closed) => return,
        };
        if !sent {
            return;
        }
    }
}

/// The inbox's asks, then each change; one that falls behind gets a fresh snapshot.
async fn follow_inbox(inbox: Arc<Inbox>, out: mpsc::UnboundedSender<Value>) {
    let mut events = inbox.subscribe();
    let snapshot = |inbox: &Inbox| {
        let (offline, reachable) = inbox.agents();
        out.send(json!({"event": "asks", "asks": inbox.asks(), "offline": offline, "reachable": reachable})).is_ok()
    };
    if !snapshot(&inbox) {
        return;
    }
    loop {
        let sent = match events.recv().await {
            Ok(InboxEvent::Ask(ask)) => out.send(json!({"event": "ask", "ask": ask})).is_ok(),
            Ok(InboxEvent::Output { id, chunk }) => out.send(json!({"event": "output", "ask": id, "chunk": chunk})).is_ok(),
            Ok(InboxEvent::Removed(id)) => out.send(json!({"event": "removed", "ask": id})).is_ok(),
            Ok(InboxEvent::Trimmed) => snapshot(&inbox),
            Ok(InboxEvent::Agents { offline, reachable }) => {
                out.send(json!({"event": "agents", "offline": offline, "reachable": reachable})).is_ok()
            }
            Err(broadcast::error::RecvError::Lagged(_)) => snapshot(&inbox),
            Err(broadcast::error::RecvError::Closed) => return,
        };
        if !sent {
            return;
        }
    }
}
