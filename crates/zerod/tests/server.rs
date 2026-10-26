//! The daemon over its socket, as Zero's apps use it: requests answered by id, and a subscription that sends
//! each session's snapshot and then every change after it.

mod common;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use common::{Seen, fixture, play, temp_dir};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use zerod::daemon::{Daemon, Runtime};
use zerod::model::{Conversation, Provider, Status};

/// A daemon whose runtimes are recorded sessions: a Codex start plays the Codex command fixture and a Claude start
/// the Claude one; later Codex runtimes (resumes) answer initialize and thread/resume. What each one saw is kept,
/// newest last, with the command line it was started with.
struct Harness {
    home: PathBuf,
    socket: PathBuf,
    project: PathBuf,
    seen: Arc<Mutex<Vec<Seen>>>,
    commands: Arc<Mutex<Vec<Vec<String>>>>,
}

fn runtime(seen: Arc<Mutex<Vec<Seen>>>, commands: Arc<Mutex<Vec<Vec<String>>>>) -> Runtime {
    Arc::new(move |conversation: &Conversation, _dir: &std::path::Path, argv: &[String]| {
        let codex_before = commands.lock().unwrap().iter().any(|a| a.iter().any(|w| w == "codex"));
        commands.lock().unwrap().push(argv.to_vec());
        let mut all = seen.lock().unwrap();
        let script = match conversation.provider {
            Provider::Claude => fixture("claude-command"),
            _ if !codex_before => fixture("codex-command"),
            _ => {
                let thread = "01a177f4-5525-7141-bfb3-f350d91476d6";
                vec![
                    json!({"out": {"id": "a", "method": "initialize"}}), json!({"in": {"id": "a", "result": {}}}),
                    json!({"out": {"id": "b", "method": "thread/resume"}}), json!({"in": {"id": "b", "result": {"thread": {"id": thread}, "model": "gpt-6-sol"}}}),
                ]
            }
        };
        let (transport, recorder) = play(script);
        all.push(recorder);
        Ok(transport)
    })
}

async fn harness(name: &str) -> Harness {
    let home = temp_dir(name);
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let socket = home.join("zerod.sock");
    let (seen, commands) = (Arc::new(Mutex::new(vec![])), Arc::new(Mutex::new(vec![])));
    let daemon = Daemon::open(&home, runtime(seen.clone(), commands.clone())).unwrap();
    tokio::spawn(zerod::server::serve(daemon, socket.clone()));
    for _ in 0..100 {
        if UnixStream::connect(&socket).await.is_ok() { break }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    Harness { home, socket, project, seen, commands }
}

struct Client {
    lines: tokio::io::Lines<BufReader<OwnedReadHalf>>,
    write: OwnedWriteHalf,
    next: u64,
    /// Events that arrived while waiting for an answer.
    events: Vec<Value>,
}

impl Client {
    async fn connect(socket: &PathBuf) -> Client {
        let (read, write) = UnixStream::connect(socket).await.unwrap().into_split();
        Client { lines: BufReader::new(read).lines(), write, next: 0, events: vec![] }
    }

    async fn raw(&mut self, line: &str) {
        self.write.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    }

    async fn next_line(&mut self) -> Value {
        let line = tokio::time::timeout(std::time::Duration::from_secs(5), self.lines.next_line()).await.expect("the daemon answered").unwrap().unwrap();
        serde_json::from_str(&line).unwrap()
    }

    /// Sends a request and returns its answer, keeping any events that come first.
    async fn call(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        self.raw(&request.to_string()).await;
        loop {
            let message = self.next_line().await;
            if message.get("event").is_some() { self.events.push(message); continue }
            assert_eq!(message["id"], json!(self.next));
            return message;
        }
    }

    async fn event(&mut self) -> Value {
        if !self.events.is_empty() { return self.events.remove(0) }
        loop {
            let message = self.next_line().await;
            if message.get("event").is_some() { return message }
        }
    }

    /// Applies events to local copies until `test` holds for the session.
    async fn follow(&mut self, mirror: &mut Vec<Conversation>, session: &str, test: impl Fn(&Conversation) -> bool) -> Conversation {
        loop {
            if let Some(found) = mirror.iter().find(|c| c.id == session) && test(found) { return found.clone() }
            let event = self.event().await;
            match event["event"].as_str().unwrap() {
                "session" => {
                    let conversation: Conversation = serde_json::from_value(event["conversation"].clone()).unwrap();
                    mirror.retain(|c| c.id != conversation.id);
                    mirror.push(conversation);
                }
                "change" => {
                    let target = mirror.iter_mut().find(|c| c.id == event["session"]).expect("a snapshot came first");
                    assert_eq!(event["seq"], json!(target.seq + 1), "no gaps, no repeats");
                    target.apply(serde_json::from_value(event["change"].clone()).unwrap());
                }
                other => panic!("unknown event {other}"),
            }
        }
    }
}

#[tokio::test]
async fn requests_are_answered_by_id_and_a_bad_one_does_not_end_the_connection() {
    let h = harness("server-hello").await;
    let mut client = Client::connect(&h.socket).await;
    let hello = client.call(json!({"op": "hello"})).await;
    assert_eq!(hello["ok"], true);
    assert_eq!(hello["result"]["version"], 1);
    let unknown = client.call(json!({"op": "fly"})).await;
    assert_eq!(unknown["ok"], false);
    assert!(unknown["error"].as_str().unwrap().contains("fly"));
    client.raw("not json").await;
    let garbled = client.next_line().await;
    assert_eq!(garbled["ok"], false);
    assert_eq!(client.call(json!({"op": "list"})).await["result"], json!([]));
}

#[tokio::test]
async fn a_session_starts_streams_to_subscribers_and_takes_decisions_over_the_socket() {
    let h = harness("server-flow").await;
    let mut watcher = Client::connect(&h.socket).await;
    assert_eq!(watcher.call(json!({"op": "subscribe"})).await["ok"], true);
    let mut control = Client::connect(&h.socket).await;
    let started = control.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls", "model": "gpt-6-sol"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();

    let mut mirror = vec![];
    let waiting = watcher.follow(&mut mirror, &session, |c| !c.approvals.is_empty()).await;
    let approval = &waiting.approvals[0];
    let decided = control.call(json!({"op": "decide", "session": session, "approval": approval.id, "choice": approval.choices[0].id})).await;
    assert_eq!(decided["ok"], true, "{decided}");
    let done = watcher.follow(&mut mirror, &session, |c| c.status == Status::Idle && c.turn.is_none() && c.approvals.is_empty()).await;

    let fetched = control.call(json!({"op": "get", "session": session})).await;
    let daemon_side: Conversation = serde_json::from_value(fetched["result"].clone()).unwrap();
    assert_eq!(done, daemon_side, "the subscriber's copy is the daemon's");
    assert_eq!(h.seen.lock().unwrap()[0].reply_to(&json!(0)).unwrap()["result"]["decision"], "accept");

    // A subscriber arriving later starts from a snapshot of the same conversation.
    let mut late = Client::connect(&h.socket).await;
    late.call(json!({"op": "subscribe"})).await;
    let mut late_mirror = vec![];
    assert_eq!(late.follow(&mut late_mirror, &session, |_| true).await, daemon_side);
}

#[tokio::test]
async fn a_session_only_starts_in_a_folder_that_exists() {
    let h = harness("server-cwd").await;
    let mut client = Client::connect(&h.socket).await;
    for cwd in ["relative/path", "/no/such/folder"] {
        let refused = client.call(json!({"op": "start", "provider": "codex", "cwd": cwd, "prompt": "hi"})).await;
        assert_eq!(refused["ok"], false, "{cwd}");
    }
    let unknown = client.call(json!({"op": "start", "provider": "gemini", "cwd": h.project, "prompt": "hi"})).await;
    assert_eq!(unknown["ok"], false, "only the providers zerod has adapters for");
    let refused = client.call(json!({"op": "decide", "session": "nope", "approval": "0", "choice": "0"})).await;
    assert!(refused["error"].as_str().unwrap().contains("nope"));
    let unanswerable = client.call(json!({"op": "answer", "session": "nope", "question": "q1", "answers": {"0": ["Redis"]}})).await;
    assert!(unanswerable["error"].as_str().unwrap().contains("nope"), "{unanswerable}");
}

#[tokio::test]
async fn sessions_survive_a_daemon_restart_and_a_message_resumes_one() {
    let h = harness("server-restart").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "subscribe"})).await;
    let session = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await["result"]["session"].as_str().unwrap().to_string();
    let mut mirror = vec![];
    let waiting = client.follow(&mut mirror, &session, |c| !c.approvals.is_empty()).await;
    client.call(json!({"op": "decide", "session": session, "approval": waiting.approvals[0].id, "choice": waiting.approvals[0].choices[0].id})).await;
    let before = client.follow(&mut mirror, &session, |c| c.status == Status::Idle && c.turn.is_none()).await;

    // Another daemon on the same home: the session is there, offline, with its history.
    let socket = h.home.join("again.sock");
    let daemon = Daemon::open(&h.home, runtime(h.seen.clone(), h.commands.clone())).unwrap();
    tokio::spawn(zerod::server::serve(daemon, socket.clone()));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let mut again = Client::connect(&socket).await;
    let listed = again.call(json!({"op": "list"})).await;
    assert_eq!(listed["result"][0]["id"], session);
    assert_eq!(listed["result"][0]["status"], "offline");
    let reloaded: Conversation = serde_json::from_value(again.call(json!({"op": "get", "session": session})).await["result"].clone()).unwrap();
    assert_eq!(reloaded.items, before.items);

    let sent = again.call(json!({"op": "send", "session": session, "text": "and again"})).await;
    assert_eq!(sent["ok"], true, "{sent}");
    let resumed = h.seen.lock().unwrap().last().unwrap().clone();
    assert_eq!(resumed.methods()[..4], ["initialize", "initialized", "thread/resume", "turn/start"]);
}

#[tokio::test]
async fn a_claude_session_starts_on_a_session_id_of_zeros_and_answers_through_the_socket() {
    let h = harness("server-claude").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "subscribe"})).await;
    let started = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "uname", "model": "haiku"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let mut mirror = vec![];
    let done = client.follow(&mut mirror, &session, |c| c.status == Status::Idle && c.items.len() >= 3).await;
    assert_eq!(done.provider, Provider::Claude);
    let command = h.commands.lock().unwrap()[0].join(" ");
    assert!(command.contains("claude -p") && command.contains("--session-id") && command.contains("--model haiku"), "{command}");
    assert!(command.contains("--permission-mode auto"), "auto unless asked otherwise");
}

#[tokio::test]
async fn a_session_can_start_unrestricted_and_keeps_it_across_a_restart() {
    let h = harness("server-unrestricted").await;
    let mut client = Client::connect(&h.socket).await;
    let started = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "uname", "permissions": "unrestricted"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    assert!(h.commands.lock().unwrap()[0].join(" ").contains("--permission-mode bypassPermissions"));
    let refused = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "uname", "permissions": "yolo"})).await;
    assert_eq!(refused["ok"], false);

    let daemon = Daemon::open(&h.home, runtime(h.seen.clone(), h.commands.clone())).unwrap();
    assert_eq!(daemon.get(&session).unwrap().permissions, zerod::model::Permissions::Unrestricted);
}

#[tokio::test]
async fn a_lead_spawns_names_waits_on_and_reads_a_worker_over_the_socket() {
    let h = harness("server-leads").await;
    let mut client = Client::connect(&h.socket).await;
    let lead = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "lead", "permissions": "unrestricted"})).await;
    let lead = lead["result"]["session"].as_str().unwrap().to_string();
    let spawned = client.call(json!({"op": "spawn", "session": lead, "provider": "codex", "prompt": "ls", "label": "Listing", "ticket": "WEB-7"})).await;
    assert_eq!(spawned["ok"], true, "{spawned}");
    let worker = spawned["result"]["session"].as_str().unwrap().to_string();
    let workers = client.call(json!({"op": "workers", "session": lead})).await;
    assert_eq!(workers["result"][0]["id"], worker.as_str());
    assert!(workers["result"][0]["attention"].is_string(), "lists leave the items out, so zerod says how each one is doing");
    assert_eq!(workers["result"][0]["permissions"], "unrestricted", "the lead's mode");
    assert_eq!(workers["result"][0]["ticket"], "WEB-7");

    // The recording asks for an approval; an unrestricted worker has zerod allow it, so nobody has to.
    let waited = client.call(json!({"op": "wait", "sessions": [worker], "timeout": 5})).await;
    assert_eq!(waited["result"][0]["attention"], "done", "{waited}");
    assert!(waited["result"][0]["answer"].as_str().unwrap().contains("The directory is empty"));
    let result = client.call(json!({"op": "result", "session": worker})).await;
    assert!(result["result"]["answer"].as_str().unwrap().contains("The directory is empty"));

    let named = client.call(json!({"op": "label", "session": worker, "label": "Files", "ticket": null})).await;
    assert_eq!(named["ok"], true);
    let listed = client.call(json!({"op": "workers", "session": lead})).await;
    assert_eq!((&listed["result"][0]["label"], &listed["result"][0]["ticket"]), (&json!("Files"), &json!(null)));
    assert_eq!(listed["result"][0]["attention"], "done", "finished, though its items aren't in the list");
    let all = client.call(json!({"op": "list"})).await;
    assert!(all["result"].as_array().unwrap().iter().any(|c| c["attention"] == "done"));
    let impatient = client.call(json!({"op": "wait", "sessions": [lead], "timeout": 0})).await;
    assert_eq!(impatient["ok"], false, "the lead is still working: {impatient}");
}
