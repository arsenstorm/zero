//! The `zero` CLI's socket, served by zerod as the Swift app served it (apps/macos/Sources/ZeroApp/Server.swift, which
//! this replaces): one JSON line per request, and a connection that waits on an ask stays open until the ask is final,
//! streaming a run's output as it comes.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use zerod::ask::AskState;
use zerod::inbox::Inbox;

async fn serve(name: &str) -> (Arc<Inbox>, PathBuf) {
    let dir = std::env::temp_dir().join(format!("zerod-cli-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("zero.sock");
    let inbox = Inbox::open(None, vec![]);
    inbox.configure(Duration::from_millis(50), 3600);
    tokio::spawn(zerod::cli::serve(inbox.clone(), socket.clone()));
    for _ in 0..100 {
        if UnixStream::connect(&socket).await.is_ok() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    (inbox, socket)
}

/// A CLI connection. Its writing half stays open while it lives: closing it is how a waiting CLI hangs up.
struct Line {
    lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    _open: tokio::net::unix::OwnedWriteHalf,
}

impl Line {
    async fn open(socket: &PathBuf, request: Value) -> Line {
        let (read, mut write) = UnixStream::connect(socket).await.unwrap().into_split();
        write.write_all(format!("{request}\n").as_bytes()).await.unwrap();
        Line { lines: BufReader::new(read).lines(), _open: write }
    }

    async fn next(&mut self) -> Option<Value> {
        let line = tokio::time::timeout(Duration::from_secs(5), self.lines.next_line()).await.expect("an answer in time").unwrap()?;
        Some(serde_json::from_str(&line).unwrap())
    }
}

fn agent() -> Value {
    json!({"name": "cli-agent", "host": "mac", "cwd": "/tmp"})
}

/// An ask as the CLI sends it: createdAt and expiresAt equal, so the inbox's own default expiry applies.
fn ask(kind: &str, title: &str, options: &[&str]) -> Value {
    json!({"id": "", "kind": kind, "title": title, "body": "", "options": options, "agent": agent(),
           "createdAt": "2026-10-26T12:00:00Z", "expiresAt": "2026-10-26T12:00:00Z", "state": "waiting", "output": ""})
}

#[tokio::test]
async fn a_waiting_ask_is_answered_on_its_connection() {
    let (inbox, socket) = serve("wait").await;
    let mut cli = Line::open(&socket, json!({"op": "create", "ask": ask("choice", "Merge?", &["Yes", "No"])})).await;
    let created = cli.next().await.unwrap();
    assert_eq!(created["op"], "created");
    let id = created["id"].as_str().unwrap().to_string();
    inbox.choose(&id, 1);
    let done = cli.next().await.unwrap();
    assert_eq!(done["op"], "done");
    assert_eq!((&done["ask"]["state"], &done["ask"]["answer"]), (&json!("answered"), &json!("No")));
    assert!(cli.next().await.is_none(), "then the connection ends");
}

#[tokio::test]
async fn an_async_ask_returns_at_once_and_is_marked_unwaited() {
    let (inbox, socket) = serve("async").await;
    let mut cli = Line::open(&socket, json!({"op": "create", "ask": ask("question", "Which?", &[]), "wait": false})).await;
    let id = cli.next().await.unwrap()["id"].as_str().unwrap().to_string();
    assert!(cli.next().await.is_none());
    assert_eq!(inbox.ask(&id).unwrap().waits, Some(false));
}

#[tokio::test]
async fn a_run_streams_its_output_to_the_waiting_agent() {
    let (inbox, socket) = serve("run").await;
    let mut run = ask("run", "Count", &["Run", "Reject"]);
    run["command"] = json!("echo one; echo two; exit 4");
    run["cwd"] = json!("/tmp");
    let mut cli = Line::open(&socket, json!({"op": "create", "ask": run})).await;
    let id = cli.next().await.unwrap()["id"].as_str().unwrap().to_string();
    inbox.choose(&id, 0);
    let mut streamed = String::new();
    loop {
        let message = cli.next().await.unwrap();
        match message["op"].as_str().unwrap() {
            "output" => streamed += message["chunk"].as_str().unwrap(),
            "done" => {
                assert_eq!(message["ask"]["exitCode"], 4);
                break;
            }
            other => panic!("{other}"),
        }
    }
    assert!(streamed.contains("one") && streamed.contains("two"), "{streamed}");
}

#[tokio::test]
async fn waiting_again_reconnects_to_the_same_ask() {
    let (inbox, socket) = serve("rewait").await;
    let mut first = Line::open(&socket, json!({"op": "create", "ask": ask("question", "Later?", &[]), "wait": false})).await;
    let id = first.next().await.unwrap()["id"].as_str().unwrap().to_string();
    let mut again = Line::open(&socket, json!({"op": "wait", "id": id})).await;
    inbox.reply(&id, "now");
    assert_eq!(again.next().await.unwrap()["ask"]["answer"], "now");
    let mut late = Line::open(&socket, json!({"op": "wait", "id": id})).await;
    assert_eq!(late.next().await.unwrap()["op"], "done", "a final ask answers at once");
    let mut unknown = Line::open(&socket, json!({"op": "wait", "id": "nope00"})).await;
    let refused = unknown.next().await.unwrap();
    assert_eq!(refused["op"], "error");
    assert!(refused["message"].as_str().unwrap().contains("nope00"));
}

#[tokio::test]
async fn status_list_withdraw_and_prompt_answer_as_the_app_did() {
    let (inbox, socket) = serve("ops").await;
    let mut create = Line::open(&socket, json!({"op": "create", "ask": ask("choice", "Merge?", &["Yes", "No"]), "wait": false})).await;
    let id = create.next().await.unwrap()["id"].as_str().unwrap().to_string();
    let status = Line::open(&socket, json!({"op": "status", "id": id})).await.next().await.unwrap();
    assert_eq!((&status["op"], &status["ask"]["state"]), (&json!("ask"), &json!("waiting")));
    let list = Line::open(&socket, json!({"op": "list"})).await.next().await.unwrap();
    assert_eq!(list["asks"][0]["id"], id.as_str());
    // Open ones only, when asked: `zero list` sent every ask ever made (hundreds of kilobytes) to show a few.
    Line::open(&socket, json!({"op": "create", "ask": ask("note", "Done a thing", &[]), "wait": false})).await.next().await.unwrap();
    let open = Line::open(&socket, json!({"op": "list", "open": true})).await.next().await.unwrap();
    assert!(
        open["asks"].as_array().unwrap().iter().all(|a| a["state"] == "waiting" || a["state"] == "pending" || a["state"] == "running"),
        "{open}"
    );
    assert_eq!(open["asks"][0]["id"], id.as_str());
    let prompt = json!({"op": "prompt", "ask": {"id": "", "kind": "message", "title": "Prompt", "body": "just merge it", "options": [],
        "agent": agent(), "createdAt": "2026-10-26T12:00:00Z", "expiresAt": "2026-10-26T12:00:00Z", "state": "waiting", "output": ""}});
    assert_eq!(Line::open(&socket, prompt).await.next().await.unwrap()["message"], "human");
    assert_eq!(inbox.ask(&id).unwrap().status.as_deref(), Some("withdrawn"), "typed in the terminal, so answered there");
    let mut other = Line::open(&socket, json!({"op": "create", "ask": ask("question", "Name?", &[]), "wait": false})).await;
    let other = other.next().await.unwrap()["id"].as_str().unwrap().to_string();
    let withdrawn = Line::open(&socket, json!({"op": "withdraw", "id": other, "text": "not needed"})).await.next().await.unwrap();
    assert_eq!(withdrawn["op"], "withdrawn");
    let gone = inbox.ask(&other).unwrap();
    assert_eq!((gone.state, gone.answer.as_deref()), (AskState::Expired, Some("not needed")));
    let unknown = Line::open(&socket, json!({"op": "fly"})).await.next().await.unwrap();
    assert_eq!(unknown["op"], "error");
}

#[tokio::test]
async fn blocked_is_refused_then_marked_with_its_token() {
    let (inbox, socket) = serve("blocked").await;
    let said = json!({"id": "", "kind": "note", "title": "Update", "body": "The API is down", "options": [], "agent": agent(),
        "createdAt": "2026-10-26T12:00:00Z", "expiresAt": "2026-10-26T12:00:00Z", "state": "waiting", "output": ""});
    let refused = Line::open(&socket, json!({"op": "blocked", "ask": said})).await.next().await.unwrap();
    assert_eq!(refused["op"], "notBlocked");
    let message = refused["message"].as_str().unwrap();
    let token = message.split("--confirm ").nth(1).unwrap().split_whitespace().next().unwrap();
    let marked = Line::open(&socket, json!({"op": "blocked", "ask": said, "id": token})).await.next().await.unwrap();
    assert_eq!(marked["op"], "marked");
    assert!(inbox.asks().iter().any(|a| a.confirmed && a.status.as_deref() == Some("blocked")));
}
