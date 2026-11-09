//! The daemon over its socket, as Zero's apps use it: requests answered by id, and a subscription that sends
//! each session's snapshot and then every change after it.


use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::common::{Seen, fixture, play, temp_dir};
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
    tokio::spawn(zerod::server::serve(zerod::server::Zerod { daemon, inbox: zerod::inbox::Inbox::open(None, vec![]), drops: None,
        integrations: zerod::integrations::Integrations::open(&home, Arc::new(zerod::integrations::Commands::default())),
        following: zerod::following::Following::open(&home, Arc::new(zerod::integrations::Commands::default()), zerod::integrations::Integrations::open(&home, Arc::new(zerod::integrations::Commands::default()))),
        browsers: zerod::browser::Browsers::open(&home),
        pads: Arc::new(zerod::pads::Pads::open(&home.join("scratchpads"))), later: Arc::new(zerod::later::Later::open(&home.join("later"))), loops: Arc::new(zerod::loops::Loops::open(&home.join("loops"))),
        places: Default::default(), notices: tokio::sync::broadcast::channel(64).0 }, socket.clone()));
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
                // The board and pad notices come on the same subscription.
                "board" | "pads" => {}
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
    // Every account's usage is read in the background: asked, it says so at once.
    assert_eq!(client.call(json!({"op": "readUsage"})).await["ok"], true);
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
async fn a_lazy_subscriber_gets_no_snapshots_until_a_session_changes_and_asks_for_one_it_opens() {
    // A phone, over a slow link: the board up front, a conversation when it's opened or once it moves.
    let h = harness("server-lazy").await;
    let mut control = Client::connect(&h.socket).await;
    let started = control.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let mut mirror = vec![];
    let mut early = Client::connect(&h.socket).await;
    early.call(json!({"op": "subscribe"})).await;
    early.follow(&mut mirror, &session, |c| !c.approvals.is_empty()).await;

    let mut phone = Client::connect(&h.socket).await;
    assert_eq!(phone.call(json!({"op": "subscribe", "lazy": true})).await["ok"], true);
    let board = phone.call(json!({"op": "board"})).await;
    assert!(phone.events.iter().all(|e| e["event"] != "session"), "no snapshots up front: {:?}", phone.events);
    assert_eq!(board["result"][0]["session"], session.as_str());
    let recent = phone.call(json!({"op": "recent", "session": session})).await;
    let opened: Conversation = serde_json::from_value(recent["result"]["conversation"].clone()).unwrap();
    assert!(!opened.approvals.is_empty() && !opened.items.is_empty(), "the conversation, when it's opened");
    assert_eq!(recent["result"]["earlier"], 0);

    // It moves: its snapshot comes, then its changes.
    let approval = opened.approvals[0].clone();
    control.call(json!({"op": "decide", "session": session, "approval": approval.id, "choice": approval.choices[0].id})).await;
    let mut phone_mirror = vec![];
    let done = phone.follow(&mut phone_mirror, &session, |c| c.approvals.is_empty() && c.status == Status::Idle).await;
    assert!(done.approvals.is_empty());
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
    tokio::spawn(zerod::server::serve(zerod::server::Zerod { daemon, inbox: zerod::inbox::Inbox::open(None, vec![]), drops: None,
        integrations: zerod::integrations::Integrations::open(&h.home, Arc::new(zerod::integrations::Commands::default())),
        following: zerod::following::Following::open(&h.home, Arc::new(zerod::integrations::Commands::default()), zerod::integrations::Integrations::open(&h.home, Arc::new(zerod::integrations::Commands::default()))),
        browsers: zerod::browser::Browsers::open(&h.home),
        pads: Arc::new(zerod::pads::Pads::open(&h.home.join("scratchpads"))), later: Arc::new(zerod::later::Later::open(&h.home.join("later"))), loops: Arc::new(zerod::loops::Loops::open(&h.home.join("loops"))),
        places: Default::default(), notices: tokio::sync::broadcast::channel(64).0 }, socket.clone()));
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

#[tokio::test]
async fn the_inbox_is_followed_and_answered_over_the_socket() {
    let h = harness("server-inbox").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "configure", "takeBack": 0.02, "ttl": 600, "patterns": ["~/drops/*"]})).await;
    let kept: Value = serde_json::from_slice(&std::fs::read(h.home.join("settings.json")).unwrap()).unwrap();
    assert_eq!(kept, json!({"takeBack": 0.02, "ttl": 600, "patterns": ["~/drops/*"]}), "kept for the next start");
    client.call(json!({"op": "inbox"})).await;
    let snapshot = client.event().await;
    assert_eq!((snapshot["event"].as_str(), &snapshot["asks"]), (Some("asks"), &json!([])));
    let ask = json!({"id": "", "kind": "choice", "title": "Ship it?", "options": ["Yes", "No"], "agent": {"name": "codex-1", "host": "mac"},
                     "createdAt": "2026-01-01T00:00:00Z", "expiresAt": "2026-01-01T00:00:00Z", "state": "waiting", "output": ""});
    let created = client.call(json!({"op": "create", "ask": ask})).await["result"].clone();
    let id = created["id"].as_str().unwrap().to_string();
    assert_eq!(client.event().await["ask"]["id"], id.as_str());
    client.call(json!({"op": "choose", "ask": id, "option": 0})).await;
    loop {
        let event = client.event().await;
        if event["ask"]["state"] == "answered" { assert_eq!(event["ask"]["answer"], "Yes"); break }
    }
    assert_eq!(client.call(json!({"op": "choose", "ask": id})).await["error"], "Which option?");
    assert_eq!(client.call(json!({"op": "board"})).await["result"], json!([]), "no sessions, no rows");
    let integrations = client.call(json!({"op": "setIntegration", "integration": "github", "enabled": true})).await["result"].clone();
    assert_eq!((integrations["settings"]["github"]["enabled"].clone(), integrations["linear"].clone()), (json!(true), Value::Null));
    let saved = client.call(json!({"op": "saveView", "integration": "github", "view": {"name": "Ours", "query": "is:pr org:acme"}})).await["result"].clone();
    assert_eq!(saved["settings"]["github"]["views"][2]["name"], "Ours");
    assert_eq!(client.call(json!({"op": "viewItems", "integration": "github", "view": "nope"})).await["error"], "No view nope");
}

#[tokio::test]
async fn scratchpads_are_reached_through_the_pad_op() {
    let h = harness("server-pads").await;
    let mut client = Client::connect(&h.socket).await;
    let created = client.call(json!({"op": "pad", "tool": "create", "args": {"title": "Plan", "content": "## Steps\n\nShip."}})).await;
    let link = format!("{}#steps", created["result"]["link"].as_str().unwrap());
    let read = client.call(json!({"op": "pad", "tool": "read", "args": {"pad": link}})).await;
    assert_eq!(read["result"]["content"], "## Steps\n\nShip.\n");
    assert!(h.home.join("scratchpads/Plan.md").exists());
    assert_eq!(client.call(json!({"op": "pad", "tool": "nope"})).await["error"], "No scratchpad tool nope");
}

#[tokio::test]
async fn an_issue_starts_one_task_with_a_state_pad_of_its_own() {
    let h = harness("server-start-task").await;
    let mut client = Client::connect(&h.socket).await;
    let saved = client.call(json!({"op": "saveView", "integration": "linear", "view": {"id": "mine", "name": "My issues", "assignee": "me",
        "start": {"cwd": h.project, "prompt": "Supervise {key}: {title}", "provider": "codex"}}})).await;
    assert_eq!(saved["ok"], true, "{saved}");
    let item = json!({"id": "i1", "key": "ENG-1", "title": "Fix it", "url": "u", "place": "ENG", "state": "Plan", "updated": "t"});
    let started = client.call(json!({"op": "startTask", "integration": "linear", "view": "mine", "item": item})).await;
    assert_eq!(started["ok"], true, "{started}");
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let task: Conversation = serde_json::from_value(client.call(json!({"op": "get", "session": session})).await["result"].clone()).unwrap();
    assert_eq!((task.ticket.as_deref(), task.label.as_deref()), (Some("ENG-1"), Some("ENG-1 Fix it")));
    let pad = client.call(json!({"op": "pad", "tool": "read", "args": {"pad": started["result"]["pad"]}})).await;
    assert_eq!((pad["result"]["title"].as_str(), pad["result"]["folder"].as_str()), (Some("State"), Some("Tasks/ENG-1")));
    let again = client.call(json!({"op": "startTask", "integration": "linear", "view": "mine", "item": item})).await;
    assert_eq!((again["result"]["session"].as_str(), again["result"]["existing"].as_bool()), (Some(session.as_str()), Some(true)), "one task per issue");
    let pr = json!({"id": "PR_5", "key": "#5", "title": "Docs", "url": "u", "place": "o/r", "state": "Open", "updated": "t"});
    let unset = client.call(json!({"op": "startTask", "integration": "github", "view": "mine", "item": pr})).await;
    assert_eq!(unset["error"], "My pull requests doesn't start tasks yet: give it a folder and a prompt in Integrations");
}

#[tokio::test]
async fn a_subscriber_is_sent_the_board_and_told_when_pads_change() {
    let h = harness("server-feed").await;
    let mut watcher = Client::connect(&h.socket).await;
    assert_eq!(watcher.call(json!({"op": "subscribe"})).await["ok"], true);
    let board = loop { let event = watcher.event().await; if event["event"] == "board" { break event } };
    assert_eq!(board["rows"], json!([]), "pushed at once, no polling");
    let mut writer = Client::connect(&h.socket).await;
    writer.call(json!({"op": "pad", "tool": "create", "args": {"title": "Notes"}})).await;
    loop { if watcher.event().await["event"] == "pads" { break } }
    writer.call(json!({"op": "pad", "tool": "list"})).await;
    // Reading isn't a change.
    let quiet = tokio::time::timeout(std::time::Duration::from_millis(300), watcher.event()).await;
    assert!(quiet.map(|e| e["event"] != "pads").unwrap_or(true));
}

#[tokio::test]
async fn later_is_reached_through_its_op_and_knows_the_task_it_came_from() {
    let h = harness("server-later").await;
    let mut watcher = Client::connect(&h.socket).await;
    watcher.call(json!({"op": "subscribe"})).await;
    let mut client = Client::connect(&h.socket).await;
    let started = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    client.call(json!({"op": "label", "session": session, "label": "Login bug"})).await;
    let saved = client.call(json!({"op": "later", "tool": "save", "session": session, "args": {"note": "Fix the race", "artifact": "In full"}})).await;
    assert_eq!(saved["ok"], true, "{saved}");
    assert_eq!((saved["result"]["from"].as_str(), saved["result"]["task"].as_str(), saved["result"]["workspace"].as_str()),
               (Some(session.as_str()), Some("Login bug"), Some("zero")));
    assert!(h.home.join("later").join(saved["result"]["id"].as_str().unwrap()).join("artifact.md").exists());
    loop { if watcher.event().await["event"] == "later" { break } }
    assert_eq!(client.call(json!({"op": "later", "tool": "list"})).await["result"][0]["note"], "Fix the race");
}

#[tokio::test]
async fn seeing_a_task_is_kept_by_zerod_for_every_client() {
    let h = harness("server-seen").await;
    let mut client = Client::connect(&h.socket).await;
    let started = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let seen = client.call(json!({"op": "seen", "session": session, "answer": "item-9", "at": 1000})).await;
    assert_eq!(seen["ok"], true, "{seen}");
    let kept: Value = serde_json::from_slice(&std::fs::read(h.home.join("seen.json")).unwrap()).unwrap();
    assert_eq!(kept[&session], json!(["item-9", 1000]), "kept across restarts, beside paused-by-user.json");
    assert_eq!(client.call(json!({"op": "seen", "session": "nope"})).await["ok"], false);
}

#[tokio::test]
async fn a_task_started_in_a_workspace_is_still_there_after_a_restart() {
    let h = harness("server-workspace-restart").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Personal", "glyph": "", "folders": []}})).await;
    let started = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls", "workspace": "personal"})).await;
    let session = started["result"]["session"].as_str().unwrap_or_else(|| panic!("{started}")).to_string();
    let row = |board: &Value| board["result"].as_array().unwrap().iter().find(|r| r["session"] == session.as_str()).map(|r| r["workspace"].clone());
    assert_eq!(row(&client.call(json!({"op": "board"})).await), Some(json!("personal")));

    // Another daemon on the same home, as after a restart: the task is where it was started, not back in Zero.
    let socket = h.home.join("again.sock");
    let daemon = Daemon::open(&h.home, runtime(h.seen.clone(), h.commands.clone())).unwrap();
    tokio::spawn(zerod::server::serve(zerod::server::Zerod { daemon, inbox: zerod::inbox::Inbox::open(None, vec![]), drops: None,
        integrations: zerod::integrations::Integrations::open(&h.home, Arc::new(zerod::integrations::Commands::default())),
        following: zerod::following::Following::open(&h.home, Arc::new(zerod::integrations::Commands::default()), zerod::integrations::Integrations::open(&h.home, Arc::new(zerod::integrations::Commands::default()))),
        browsers: zerod::browser::Browsers::open(&h.home),
        pads: Arc::new(zerod::pads::Pads::open(&h.home.join("scratchpads"))), later: Arc::new(zerod::later::Later::open(&h.home.join("later"))), loops: Arc::new(zerod::loops::Loops::open(&h.home.join("loops"))),
        places: Default::default(), notices: tokio::sync::broadcast::channel(64).0 }, socket.clone()));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let mut again = Client::connect(&socket).await;
    assert_eq!(row(&again.call(json!({"op": "board"})).await), Some(json!("personal")));
}

#[tokio::test]
async fn a_lead_unarchived_brings_back_the_workers_archived_with_it_and_no_others() {
    let h = harness("server-unarchive").await;
    let mut client = Client::connect(&h.socket).await;
    let lead = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "lead", "permissions": "unrestricted"})).await;
    let lead = lead["result"]["session"].as_str().unwrap().to_string();
    let worker = |label: &'static str| json!({"op": "spawn", "session": lead, "provider": "codex", "prompt": "ls", "label": label});
    let one = client.call(worker("One")).await["result"]["session"].as_str().unwrap().to_string();
    let two = client.call(worker("Two")).await["result"]["session"].as_str().unwrap().to_string();
    let ids = |listed: &Value| listed["result"].as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();

    // Child one put away on its own; then the lead, which takes child two with it.
    assert_eq!(client.call(json!({"op": "archive", "session": one})).await["ok"], true);
    assert_eq!(client.call(json!({"op": "archive", "session": lead})).await["ok"], true);
    assert!(ids(&client.call(json!({"op": "list"})).await).is_empty(), "the lead and child two went together");
    let archived = client.call(json!({"op": "archived"})).await;
    let roots: Vec<(String, u64)> = archived["result"].as_array().unwrap().iter().map(|a| (a["id"].as_str().unwrap().into(), a["workers"].as_u64().unwrap())).collect();
    assert_eq!(roots, [(lead.clone(), 1), (one.clone(), 0)], "newest first: the lead with the one worker it took, child one on its own");
    assert_eq!(archived["result"][1]["parent"], lead.as_str(), "child one says whose it is, to be shown under its lead");
    assert_eq!(archived["result"][0]["parent"], Value::Null);

    let back = client.call(json!({"op": "unarchive", "session": lead})).await;
    assert_eq!(back["ok"], true, "{back}");
    let mut now = ids(&client.call(json!({"op": "list"})).await);
    now.sort();
    let mut expected = vec![lead.clone(), two.clone()];
    expected.sort();
    assert_eq!(now, expected, "child two came back with its lead; child one, archived on its own, didn't");
    assert_eq!(client.call(json!({"op": "get", "session": two})).await["result"]["parent"], lead.as_str(), "still its lead's");
    client.call(json!({"op": "unarchive", "session": one})).await;
    assert_eq!(ids(&client.call(json!({"op": "list"})).await).len(), 3);
    assert_eq!(client.call(json!({"op": "unarchive", "session": "nope"})).await["ok"], false);
}

#[tokio::test]
async fn a_task_gets_its_workspaces_mcp_servers_when_it_starts() {
    let h = harness("server-mcp").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Cybersecurity", "glyph": "", "folders": []}})).await;
    let saved = client.call(json!({"op": "saveMcpServer", "server": {"name": "CVE lookup", "command": "cve-mcp", "workspaces": ["cybersecurity"],
        "env": [{"name": "REGION", "value": "eu", "from": "file"}]}})).await;
    assert_eq!(saved["result"]["id"], "cve-lookup", "{saved}");
    assert_eq!(client.call(json!({"op": "mcpServers"})).await["result"][0]["name"], "CVE lookup");
    let start = |workspace: Option<&str>| json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls", "workspace": workspace});
    client.call(start(Some("cybersecurity"))).await;
    client.call(start(None)).await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let configs: Vec<serde_json::Value> = h.seen.lock().unwrap().iter()
        .filter_map(|seen| seen.first("thread/start").map(|m| m["params"]["config"].clone())).collect();
    assert_eq!(configs.len(), 2, "{configs:?}");
    assert_eq!(configs[0]["mcp_servers.cve-lookup"]["env"]["REGION"], "eu", "the Cybersecurity task has its server");
    assert!(configs[1].get("mcp_servers.cve-lookup").is_none(), "Zero's doesn't: {}", configs[1]);
}

#[tokio::test]
async fn the_app_keeps_sign_ins_through_zerod_and_never_sees_their_values() {
    let h = harness("server-signins").await;
    let mut client = Client::connect(&h.socket).await;
    let saved = client.call(json!({"op": "saveSignIn", "signin": {"cli": "claude", "kind": "token", "label": "a@example.com"}})).await;
    let a = saved["result"]["id"].as_str().unwrap_or_else(|| panic!("{saved}")).to_string();
    let b = client.call(json!({"op": "saveSignIn", "signin": {"cli": "claude", "kind": "token", "label": "b@example.com"}})).await["result"]["id"].as_str().unwrap().to_string();
    client.call(json!({"op": "defaultSignIn", "signin": {"cli": "claude", "id": b}})).await;
    let listed = client.call(json!({"op": "signIns"})).await;
    let rows = listed["result"]["signins"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(listed["result"]["defaults"]["claude"], b.as_str());
    client.call(json!({"op": "deleteSignIn", "signin": a})).await;
    assert_eq!(client.call(json!({"op": "signIns"})).await["result"]["signins"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn a_task_asks_runs_and_notes_through_zeros_tools_whatever_sandbox_its_agent_is_in() {
    // Codex runs commands in a sandbox that can't reach Zero's socket: Zero's MCP server (outside it) asks for it.
    let h = harness("server-agent-ask").await;
    let mut control = Client::connect(&h.socket).await;
    let started = control.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let asked = control.call(json!({"op": "agentAsk", "session": session, "args": {"tool": "ask", "question": "Start the check, or wait for Dana?",
                                                                                     "options": ["Start it", "Wait for Dana"]}})).await;
    assert_eq!(asked["ok"], true, "{asked}");
    let id = asked["result"]["id"].as_str().unwrap().to_string();
    let ran = control.call(json!({"op": "agentAsk", "session": session, "args": {"tool": "run", "command": "bin/prod-check", "why": "the counts"}})).await;
    assert_eq!(ran["ok"], true, "{ran}");
    control.call(json!({"op": "agentAsk", "session": session, "args": {"tool": "note", "text": "Waiting on QA", "state": "waiting"}})).await;
    assert!(control.call(json!({"op": "agentAsk", "session": session, "args": {"tool": "run", "command": "x"}})).await["ok"] == false, "a run says why");
    let asks = control.call(json!({"op": "asks"})).await["result"].as_array().unwrap().clone();
    let question = asks.iter().find(|a| a["id"] == id.as_str()).unwrap();
    assert_eq!((question["kind"].as_str(), question["title"].as_str()), (Some("choice"), Some("Start the check, or wait for Dana?")));
    assert_eq!(question["agent"]["runtime"], "zerod", "the task's own ask, joining its approvals in the inbox");
    assert!(asks.iter().any(|a| a["kind"] == "run" && a["command"] == "bin/prod-check" && a["body"] == "the counts"));
    // A tool call never waits for its answer: the answer goes to the task as a message, as for `zero ask --async`.
    assert!(asks.iter().filter(|a| a["kind"] == "choice" || a["kind"] == "run").all(|a| a["waits"] == false), "{asks:?}");
    assert!(asks.iter().any(|a| a["kind"] == "note" && a["status"] == "waiting"));
}

/// Every op reaches its handler: asked without what it needs, each says what's missing rather than "Unknown op".
/// Left out: ops that act with nothing given (restart, sign-ins, connecting services, setting browsers up, pausing).
#[tokio::test]
async fn every_op_is_routed_to_its_handler() {
    let h = harness("server-routes").await;
    let mut client = Client::connect(&h.socket).await;
    let ops = "adopt agentAsk answer answerAsk archive archived asks attr board branch browserCall browserSettings browserState browsers \
        cancelRun choose close closeTerminal configure connectSlack create decide defaultSignIn deleteLoop deleteMcpServer deleteSignIn \
        deleteView deleteWorkspace deliver detach dismiss firefox follow following get hello interrupt items label later list loop loops \
        mcpServers message migrate notify openTerminal orderViews outline pad place placeInWorkspace press queue recent release remind \
        reply restartStatus result resume rewind rewindPreview saveBrowserSettings saveLoop saveMcpServer saveSignIn saveView saveWorkspace \
        schedule schedules screen seen send setIntegration setPermissions settings signIns spawn start startTask stop switch switchModel \
        table takeBack unarchive unfollow unqueue unschedule unwatch viewItems wait watch watchFile watches window withdraw workers workspaces";
    for op in ops.split_whitespace() {
        let answer = client.call(json!({"op": op})).await;
        let error = answer["error"].as_str().unwrap_or_default();
        assert!(!error.starts_with("Unknown op"), "{op} isn't routed: {answer}");
    }
}

#[tokio::test]
async fn writing_in_the_chat_tells_the_agent_which_of_its_asks_are_still_open() {
    // The user may answer one in the chat, or write about something else and leave it open on purpose (a step they're
    // still running): Zero can't tell which, so none is withdrawn, and the agent is told what's open to withdraw what
    // the words answered.
    let h = harness("server-chat-withdraws").await;
    let mut control = Client::connect(&h.socket).await;
    let started = control.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let asked = control.call(json!({"op": "agentAsk", "session": session, "args": {"tool": "ask", "question": "Which piece first?", "options": ["Formatters", "Docs"]}})).await;
    let question = asked["result"]["id"].as_str().unwrap().to_string();
    let ran = control.call(json!({"op": "agentAsk", "session": session, "args": {"tool": "run", "command": "bin/prod-check", "why": "the counts"}})).await;
    let run = ran["result"]["id"].as_str().unwrap().to_string();
    // Sent once the agent is up (still starting, a send is turned away).
    for _ in 0..60 {
        if control.call(json!({"op": "send", "session": session, "text": "let's talk about the formatters"})).await["error"].is_null() { break }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    let asks = control.call(json!({"op": "asks"})).await["result"].as_array().unwrap().clone();
    let state = |id: &str| asks.iter().find(|a| a["id"] == id).map(|a| (a["status"].clone(), a["state"].clone())).unwrap();
    assert!(state(&question).0 != "withdrawn" && state(&run).0 != "withdrawn", "left for the user");
    // Given to the agent, the words carry the note (queued, they carry it as they're given: the queue keeps them as
    // written, a_queued_message_is_kept_in_the_users_own_words).
    let mut given = String::new();
    for _ in 0..60 {
        given = h.seen.lock().unwrap().iter().flat_map(|s| s.all()).map(|m| m.to_string()).collect::<String>();
        if given.contains(zerod::daemon::OPEN_ASKS_MARK) { break }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(given.contains("let's talk about the formatters") && given.contains(zerod::daemon::OPEN_ASKS_MARK), "{given}");
    assert!(given.contains(&question) && given.contains(&run) && given.contains("zero withdraw"), "the agent is told which: {given}");
}

#[tokio::test]
async fn a_queued_message_is_kept_in_the_users_own_words() {
    // The note on open asks goes with the words as they're given to the agent, not into the queue: the queue shows
    // what the user wrote (the app matches its own copy of a message just queued to zerod's by its words, and Edit puts
    // them back in the composer), and the note names what's open when it goes, not when it was queued.
    let h = harness("server-queue-own-words").await;
    let mut control = Client::connect(&h.socket).await;
    let started = control.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    control.call(json!({"op": "agentAsk", "session": session, "args": {"tool": "ask", "question": "Which piece first?", "options": ["Formatters", "Docs"]}})).await;
    let queued = control.call(json!({"op": "queue", "session": session, "text": "let's talk about the formatters"})).await;
    assert_eq!(queued["result"]["text"], "let's talk about the formatters", "{queued}");
}

#[tokio::test]
async fn a_lead_sets_its_issues_rows_and_the_board_shows_them() {
    let h = harness("server-issues").await;
    let mut control = Client::connect(&h.socket).await;
    let started = control.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "lead these"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let set = |ticket: &str, state: &str, text: &str| json!({"op": "issue", "session": session, "ticket": ticket, "state": state, "text": text});
    assert_eq!(control.call(set("ENG-1", "you", "merge decision")).await["ok"], true);
    assert_eq!(control.call(set("ENG-2", "waiting", "CI on app#12")).await["ok"], true);
    let refused = control.call(set("ENG-3", "dancing", "")).await;
    assert!(refused["error"].as_str().unwrap().contains("you, working, waiting, parked or done"), "{refused}");
    let board = control.call(json!({"op": "board"})).await;
    let row = board["result"]["rows"].as_array().or(board["result"].as_array()).unwrap().iter().find(|r| r["session"] == session.as_str()).unwrap().clone();
    let issues: Vec<(String, String)> = row["issues"].as_array().unwrap().iter().map(|i| (i["ticket"].as_str().unwrap().into(), i["state"].as_str().unwrap().into())).collect();
    assert_eq!(issues, [("ENG-1".to_string(), "you".to_string()), ("ENG-2".into(), "waiting".into())]);
    assert_eq!(row["state"], "needsYou");
    // Kept: another zerod, rebuilt from the transcript, has the rows.
    assert!(std::fs::read_to_string(h.home.join("sessions").join(&session).join("transcript.jsonl")).unwrap().contains("merge decision"));
}
