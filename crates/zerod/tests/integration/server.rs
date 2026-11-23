//! The daemon over its socket, as Zero's apps use it: requests answered by id, and a subscription that sends
//! each session's snapshot and then every change after it.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::common::{Seen, fixture, play, temp_dir, until};
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
    daemon: Arc<Daemon>,
    inbox: Arc<zerod::inbox::Inbox>,
    /// What curl answers Zero's own requests (its MCP sign-ins), in turn; offline once they're spent.
    web: Arc<Web>,
}

#[derive(Default)]
struct Web {
    answers: Mutex<Vec<String>>,
    asked: Mutex<Vec<String>>,
}

impl zerod::integrations::Fetcher for Web {
    fn run(&self, _argv: Vec<String>, stdin: Option<String>) -> zerod::inbox::Fut<'_, Result<String, String>> {
        self.asked.lock().unwrap().push(stdin.unwrap_or_default());
        let mut answers = self.answers.lock().unwrap();
        let answer = if answers.is_empty() { Err("offline".to_string()) } else { Ok(answers.remove(0)) };
        Box::pin(async move { answer })
    }
}

fn runtime(seen: Arc<Mutex<Vec<Seen>>>, commands: Arc<Mutex<Vec<Vec<String>>>>) -> Runtime {
    Arc::new(move |conversation: &Conversation, _dir: &std::path::Path, argv: &[String]| {
        let codex_before = commands.lock().unwrap().iter().any(|a| a.iter().any(|w| w == "codex"));
        commands.lock().unwrap().push(argv.to_vec());
        let mut all = seen.lock().unwrap();
        let script = match conversation.provider {
            Provider::Claude => fixture("claude-command"),
            Provider::Opencode => fixture("opencode-command"),
            _ if !codex_before => fixture("codex-command"),
            _ => {
                let thread = "01a177f4-5525-7141-bfb3-f350d91476d6";
                vec![
                    json!({"out": {"id": "a", "method": "initialize"}}),
                    json!({"in": {"id": "a", "result": {}}}),
                    json!({"out": {"id": "b", "method": "thread/resume"}}),
                    json!({"in": {"id": "b", "result": {"thread": {"id": thread}, "model": "gpt-6-sol"}}}),
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
    let inbox = zerod::inbox::Inbox::open(None, vec![]);
    zerod::server::apply_mcp_asks(&daemon, &inbox);
    let web = Arc::new(Web::default());
    let integrations = zerod::integrations::Integrations::open(&home, web.clone());
    zerod::server::mcp_sign_ins(&daemon, &integrations);
    tokio::spawn(zerod::server::serve(
        zerod::server::Zerod {
            daemon: daemon.clone(),
            inbox: inbox.clone(),
            integrations,
            following: zerod::following::Following::open(
                &home,
                Arc::new(zerod::integrations::Commands::default()),
                zerod::integrations::Integrations::open(&home, Arc::new(zerod::integrations::Commands::default())),
            ),
            browsers: zerod::browser::Browsers::open(&home),
            desktop: Default::default(),
            pads: Arc::new(zerod::pads::Pads::open(&home.join("scratchpads"))),
            later: Arc::new(zerod::later::Later::open(&home.join("later"))),
            loops: Arc::new(zerod::loops::Loops::open(&home.join("loops"))),
            places: Default::default(),
            notices: tokio::sync::broadcast::channel(64).0,
            peers: std::sync::Arc::new(|_| true),
        },
        socket.clone(),
    ));
    for _ in 0..100 {
        if UnixStream::connect(&socket).await.is_ok() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    Harness { home, socket, project, seen, commands, daemon, inbox, web }
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
        let line = tokio::time::timeout(std::time::Duration::from_secs(5), self.lines.next_line())
            .await
            .expect("the daemon answered")
            .unwrap()
            .unwrap();
        serde_json::from_str(&line).unwrap()
    }

    /// Sends a request and returns its answer, keeping any events that come first.
    async fn call(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        self.raw(&request.to_string()).await;
        loop {
            let message = self.next_line().await;
            if message.get("event").is_some() {
                self.events.push(message);
                continue;
            }
            assert_eq!(message["id"], json!(self.next));
            return message;
        }
    }

    async fn event(&mut self) -> Value {
        if !self.events.is_empty() {
            return self.events.remove(0);
        }
        loop {
            let message = self.next_line().await;
            if message.get("event").is_some() {
                return message;
            }
        }
    }

    /// Applies events to local copies until `test` holds for the session.
    async fn follow(&mut self, mirror: &mut Vec<Conversation>, session: &str, test: impl Fn(&Conversation) -> bool) -> Conversation {
        loop {
            if let Some(found) = mirror.iter().find(|c| c.id == session)
                && test(found)
            {
                return found.clone();
            }
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
                // The board, pad notices, what tasks use and what they left running come on the same subscription.
                "board" | "pads" | "uses" | "left" => {}
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
    let decided =
        control.call(json!({"op": "decide", "session": session, "approval": approval.id, "choice": approval.choices[0].id})).await;
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
    let session = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await["result"]["session"]
        .as_str()
        .unwrap()
        .to_string();
    let mut mirror = vec![];
    let waiting = client.follow(&mut mirror, &session, |c| !c.approvals.is_empty()).await;
    client
        .call(
            json!({"op": "decide", "session": session, "approval": waiting.approvals[0].id, "choice": waiting.approvals[0].choices[0].id}),
        )
        .await;
    let before = client.follow(&mut mirror, &session, |c| c.status == Status::Idle && c.turn.is_none()).await;

    // Another daemon on the same home: the session is there, offline, with its history.
    let socket = h.home.join("again.sock");
    let daemon = Daemon::open(&h.home, runtime(h.seen.clone(), h.commands.clone())).unwrap();
    tokio::spawn(zerod::server::serve(
        zerod::server::Zerod {
            daemon,
            inbox: zerod::inbox::Inbox::open(None, vec![]),
            integrations: zerod::integrations::Integrations::open(&h.home, Arc::new(zerod::integrations::Commands::default())),
            following: zerod::following::Following::open(
                &h.home,
                Arc::new(zerod::integrations::Commands::default()),
                zerod::integrations::Integrations::open(&h.home, Arc::new(zerod::integrations::Commands::default())),
            ),
            browsers: zerod::browser::Browsers::open(&h.home),
            desktop: Default::default(),
            pads: Arc::new(zerod::pads::Pads::open(&h.home.join("scratchpads"))),
            later: Arc::new(zerod::later::Later::open(&h.home.join("later"))),
            loops: Arc::new(zerod::loops::Loops::open(&h.home.join("loops"))),
            places: Default::default(),
            notices: tokio::sync::broadcast::channel(64).0,
            peers: std::sync::Arc::new(|_| true),
        },
        socket.clone(),
    ));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let mut again = Client::connect(&socket).await;
    let listed = again.call(json!({"op": "list"})).await;
    assert_eq!(listed["result"][0]["id"], session);
    assert_eq!(listed["result"][0]["status"], "offline");
    let reloaded: Conversation =
        serde_json::from_value(again.call(json!({"op": "get", "session": session})).await["result"].clone()).unwrap();
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
    let started =
        client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "uname", "permissions": "unrestricted"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    assert!(h.commands.lock().unwrap()[0].join(" ").contains("--permission-mode bypassPermissions"));
    let refused =
        client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "uname", "permissions": "yolo"})).await;
    assert_eq!(refused["ok"], false);

    let daemon = Daemon::open(&h.home, runtime(h.seen.clone(), h.commands.clone())).unwrap();
    assert_eq!(daemon.get(&session).unwrap().permissions, zerod::model::Permissions::Unrestricted);
}

#[tokio::test]
async fn a_lead_spawns_names_waits_on_and_reads_a_worker_over_the_socket() {
    let h = harness("server-leads").await;
    let mut client = Client::connect(&h.socket).await;
    let lead =
        client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "lead", "permissions": "unrestricted"})).await;
    let lead = lead["result"]["session"].as_str().unwrap().to_string();
    let spawned = client
        .call(json!({"op": "spawn", "session": lead, "provider": "codex", "prompt": "ls", "label": "Listing", "ticket": "WEB-7"}))
        .await;
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
async fn a_task_starts_leads_of_their_own_beside_it_not_workers() {
    let h = harness("server-own-leads").await;
    let mut client = Client::connect(&h.socket).await;
    let first =
        client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "lead", "permissions": "unrestricted"})).await;
    let first = first["result"]["session"].as_str().unwrap().to_string();
    // A list of issues, a lead for each: on its folder, mode and model, in its workspace, but nobody's worker.
    let spawned = client.call(json!({"op": "spawn", "session": first, "prompt": "@issue WEB-7", "own": true})).await;
    assert_eq!(spawned["ok"], true, "{spawned}");
    let lead = spawned["result"]["session"].as_str().unwrap().to_string();
    let got = client.call(json!({"op": "get", "session": lead})).await["result"].clone();
    assert_eq!(got["parent"], Value::Null, "a task of its own: {got}");
    assert_eq!(got["permissions"], "unrestricted", "the starting task's mode");
    assert_eq!(got["cwd"], h.project.to_string_lossy().as_ref());
    let workers = client.call(json!({"op": "workers", "session": first})).await;
    assert_eq!(workers["result"], json!([]), "not a worker of the task that started it");
}

#[tokio::test]
async fn the_inbox_is_followed_and_answered_over_the_socket() {
    let h = harness("server-inbox").await;
    let mut client = Client::connect(&h.socket).await;
    // A setting this zerod no longer reads (drop folders' patterns) stays in the file as it was.
    std::fs::write(h.home.join("settings.json"), r#"{"patterns": ["~/drops/*"]}"#).unwrap();
    client.call(json!({"op": "configure", "takeBack": 0.02, "ttl": 600})).await;
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
        if event["ask"]["state"] == "answered" {
            assert_eq!(event["ask"]["answer"], "Yes");
            break;
        }
    }
    assert_eq!(client.call(json!({"op": "choose", "ask": id})).await["error"], "Which option?");
    assert_eq!(client.call(json!({"op": "board"})).await["result"], json!([]), "no sessions, no rows");
    let integrations = client.call(json!({"op": "disconnectLinear"})).await["result"].clone();
    assert_eq!((integrations["linear"].clone(), integrations["linearTeams"].clone()), (Value::Null, json!({})));
    assert_eq!(client.call(json!({"op": "saveView"})).await["error"], "Unknown op saveView", "no views");
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

/// Through `zerod mcp` as a task's agent runs it: its pads are made and listed in its task's workspace, another named
/// by its name, and the list says which workspaces there are.
#[tokio::test]
async fn an_agents_pads_are_its_tasks_workspaces_unless_it_names_another() {
    let h = harness("server-pad-agent").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Personal", "glyph": "", "folders": []}})).await;
    client.call(json!({"op": "pad", "tool": "create", "args": {"title": "App's"}})).await;
    let started = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls", "workspace": "personal"})).await;
    let session = started["result"]["session"].as_str().unwrap_or_else(|| panic!("{started}")).to_string();
    let mut agent = tokio::process::Command::new(env!("CARGO_BIN_EXE_zerod"))
        .args(["mcp", "--home", &h.home.to_string_lossy(), "--socket", &h.socket.to_string_lossy()])
        .env("HOME", &h.home)
        .env("ZERO_SESSION", &session)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut input = agent.stdin.take().unwrap();
    let mut lines = BufReader::new(agent.stdout.take().unwrap()).lines();
    let mut tool = async |name: &str, arguments: Value| -> Value {
        let call = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}});
        input.write_all(format!("{call}\n").as_bytes()).await.unwrap();
        let answer: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        let text = answer["result"]["content"][0]["text"].as_str().unwrap_or_default();
        serde_json::from_str(text).unwrap_or_else(|_| json!(text))
    };
    assert_eq!(tool("scratchpad_create", json!({"title": "Mine"})).await["workspace"], "personal", "made in its task's");
    let theirs = tool("scratchpad_create", json!({"title": "Zero's", "workspace": "Zero"})).await;
    assert_eq!(theirs["workspace"], "zero", "or the one it names: {theirs}");
    let listed = tool("scratchpad_list", json!({})).await;
    let titles =
        |listed: &Value| listed["pads"].as_array().unwrap().iter().map(|p| p["title"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    assert_eq!(titles(&listed), ["Mine"], "listed in its task's: {listed}");
    assert_eq!(listed["workspaces"], json!([{"id": "zero", "name": "Zero"}, {"id": "personal", "name": "Personal"}]));
    let mut zeros = titles(&tool("scratchpad_list", json!({"workspace": "Zero"})).await);
    zeros.sort();
    assert_eq!(zeros, ["App's", "Zero's"]);
    assert_eq!(tool("scratchpad_list", json!({"workspace": "Nope"})).await, json!("No workspace Nope: Zero, Personal"));
}

#[tokio::test]
async fn an_agent_moves_a_pad_to_a_workspace_by_its_name_and_not_to_one_that_isnt() {
    let h = harness("server-pad-place").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Personal", "glyph": "", "folders": []}})).await;
    let created = client.call(json!({"op": "pad", "tool": "create", "args": {"title": "Plan", "folder": "Work"}})).await;
    let link = created["result"]["link"].clone();
    let moved = client.call(json!({"op": "pad", "tool": "move", "args": {"pad": link, "workspace": "personal"}})).await;
    assert_eq!(moved["result"]["workspace"], "personal", "{moved}");
    assert_eq!(moved["result"]["folder"], "Work", "a workspace alone leaves its folder");
    let back = client.call(json!({"op": "pad", "tool": "move", "args": {"pad": link, "workspace": "Zero"}})).await;
    assert_eq!(back["result"]["workspace"], "zero", "by its name too: {back}");
    let typo = client.call(json!({"op": "pad", "tool": "move", "args": {"pad": link, "workspace": "Persnal"}})).await;
    assert_eq!(typo["error"], "No workspace Persnal: Zero, Personal");
}

#[tokio::test]
async fn a_subscriber_is_sent_the_board_and_told_when_pads_change() {
    let h = harness("server-feed").await;
    let mut watcher = Client::connect(&h.socket).await;
    assert_eq!(watcher.call(json!({"op": "subscribe"})).await["ok"], true);
    let board = loop {
        let event = watcher.event().await;
        if event["event"] == "board" {
            break event;
        }
    };
    assert_eq!(board["rows"], json!([]), "pushed at once, no polling");
    let mut writer = Client::connect(&h.socket).await;
    writer.call(json!({"op": "pad", "tool": "create", "args": {"title": "Notes"}})).await;
    loop {
        if watcher.event().await["event"] == "pads" {
            break;
        }
    }
    writer.call(json!({"op": "pad", "tool": "list"})).await;
    // Reading isn't a change.
    let quiet = tokio::time::timeout(std::time::Duration::from_millis(300), watcher.event()).await;
    assert!(quiet.map(|e| e["event"] != "pads").unwrap_or(true));
}

async fn uses(watcher: &mut Client) -> serde_json::Value {
    loop {
        let event = watcher.event().await;
        if event["event"] == "uses" {
            return event["tasks"].clone();
        }
    }
}

#[tokio::test]
async fn a_subscriber_is_sent_what_tasks_use_at_once_and_again_when_it_changes() {
    let h = harness("server-uses").await;
    let mut watcher = Client::connect(&h.socket).await;
    watcher.call(json!({"op": "subscribe"})).await;
    assert_eq!(uses(&mut watcher).await, json!({}), "pushed at once: nothing runs yet");
    let mut sampler = zerod::uses::Sampler::default();
    let tasks = sampler.sample(&[("s1".into(), std::process::id() as i32)]).unwrap();
    h.daemon.publish_uses(tasks);
    let tasks = uses(&mut watcher).await;
    assert!(tasks["s1"]["cli"]["memory"].as_u64().unwrap() > 0, "{tasks}");
    assert!(tasks["s1"]["commands"]["cpu"].is_number(), "{tasks}");
}

#[tokio::test]
async fn a_subscriber_is_sent_what_tasks_left_running_and_only_that_is_stopped() {
    let h = harness("server-left").await;
    let mut watcher = Client::connect(&h.socket).await;
    watcher.call(json!({"op": "subscribe"})).await;
    let left = loop {
        let event = watcher.event().await;
        if event["event"] == "left" {
            break event["tasks"].clone();
        }
    };
    assert_eq!(left, json!({}), "pushed at once: nothing's left running");
    let mut client = Client::connect(&h.socket).await;
    let refused = client.call(json!({"op": "stopLeft", "session": "s1", "args": {"things": ["p1-0"]}})).await;
    assert!(refused["error"].as_str().is_some_and(|e| e.contains("Nothing like that")), "nothing not recorded as the task's: {refused}");
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
    let saved = client
        .call(json!({"op": "later", "tool": "save", "session": session, "args": {"note": "Fix the race", "artifact": "In full"}}))
        .await;
    assert_eq!(saved["ok"], true, "{saved}");
    assert_eq!(
        (saved["result"]["from"].as_str(), saved["result"]["task"].as_str(), saved["result"]["workspace"].as_str()),
        (Some(session.as_str()), Some("Login bug"), Some("zero"))
    );
    assert!(h.home.join("later").join(saved["result"]["id"].as_str().unwrap()).join("artifact.md").exists());
    loop {
        if watcher.event().await["event"] == "later" {
            break;
        }
    }
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
    let row = |board: &Value| {
        board["result"].as_array().unwrap().iter().find(|r| r["session"] == session.as_str()).map(|r| r["workspace"].clone())
    };
    assert_eq!(row(&client.call(json!({"op": "board"})).await), Some(json!("personal")));

    // Another daemon on the same home, as after a restart: the task is where it was started, not back in Zero.
    let socket = h.home.join("again.sock");
    let daemon = Daemon::open(&h.home, runtime(h.seen.clone(), h.commands.clone())).unwrap();
    tokio::spawn(zerod::server::serve(
        zerod::server::Zerod {
            daemon,
            inbox: zerod::inbox::Inbox::open(None, vec![]),
            integrations: zerod::integrations::Integrations::open(&h.home, Arc::new(zerod::integrations::Commands::default())),
            following: zerod::following::Following::open(
                &h.home,
                Arc::new(zerod::integrations::Commands::default()),
                zerod::integrations::Integrations::open(&h.home, Arc::new(zerod::integrations::Commands::default())),
            ),
            browsers: zerod::browser::Browsers::open(&h.home),
            desktop: Default::default(),
            pads: Arc::new(zerod::pads::Pads::open(&h.home.join("scratchpads"))),
            later: Arc::new(zerod::later::Later::open(&h.home.join("later"))),
            loops: Arc::new(zerod::loops::Loops::open(&h.home.join("loops"))),
            places: Default::default(),
            notices: tokio::sync::broadcast::channel(64).0,
            peers: std::sync::Arc::new(|_| true),
        },
        socket.clone(),
    ));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let mut again = Client::connect(&socket).await;
    assert_eq!(row(&again.call(json!({"op": "board"})).await), Some(json!("personal")));
}

#[tokio::test]
async fn a_task_saved_for_later_leaves_the_board_paused_and_comes_back_from_later() {
    // Not archived: kept as it was, off the board and on hold, with an item in Later that brings it back.
    let h = harness("server-save-later").await;
    let mut client = Client::connect(&h.socket).await;
    let started = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    client.call(json!({"op": "label", "session": session, "label": "Login bug"})).await;
    let on_board = |board: &Value| board["result"].as_array().unwrap().iter().any(|r| r["session"] == session.as_str());
    assert!(on_board(&client.call(json!({"op": "board"})).await));

    let saved = client.call(json!({"op": "saveForLater", "session": session})).await;
    assert_eq!(saved["ok"], true, "{saved}");
    assert_eq!(
        (saved["result"]["resume"].as_str(), saved["result"]["note"].as_str(), saved["result"]["suggested"].as_bool()),
        (Some(session.as_str()), Some("Login bug"), Some(false))
    );
    assert!(!on_board(&client.call(json!({"op": "board"})).await), "off the board");
    assert_eq!(client.call(json!({"op": "get", "session": session})).await["ok"], true, "not archived");
    assert!(client.call(json!({"op": "archived"})).await["result"].as_array().unwrap().is_empty());
    let paused = || std::fs::read_to_string(h.home.join("paused-by-user.json")).unwrap_or_default().contains(session.as_str());
    assert!(paused(), "on hold");

    let item = saved["result"]["id"].as_str().unwrap();
    let back = client.call(json!({"op": "resumeLater", "args": {"item": item}})).await;
    assert_eq!(back["result"]["session"], session.as_str(), "{back}");
    assert!(on_board(&client.call(json!({"op": "board"})).await) && !paused());
    assert_eq!(client.call(json!({"op": "later", "tool": "view", "args": {"item": item}})).await["result"]["done"], true);
}

#[tokio::test]
async fn a_task_brought_back_from_the_archive_is_sent_afresh_to_a_subscribed_app() {
    // The app follows sessions over one subscription. A task archived and brought back starts again at the change
    // number it was archived at, which the subscription had sent already: skipped as old, the app never had it again,
    // and its page showed New task until Zero restarted.
    let h = harness("server-back").await;
    let mut app = Client::connect(&h.socket).await;
    let mut other = Client::connect(&h.socket).await;
    app.call(json!({"op": "subscribe"})).await;
    let task =
        other.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "lead", "permissions": "unrestricted"})).await;
    let task = task["result"]["session"].as_str().unwrap().to_string();
    other.call(json!({"op": "wait", "sessions": [task], "timeout": 5})).await;
    assert_eq!(other.call(json!({"op": "archive", "session": task})).await["ok"], true);
    loop {
        let event = app.event().await;
        if event["session"] == task.as_str() && event["change"]["type"] == "archived" {
            break;
        }
    }
    assert_eq!(other.call(json!({"op": "unarchive", "session": task})).await["ok"], true);
    loop {
        let event = app.event().await;
        if event["event"] == "session" && event["conversation"]["id"] == task.as_str() {
            break;
        }
    }
}

#[tokio::test]
async fn subscribing_again_sends_every_session_afresh() {
    // The app subscribes again when its copy has fallen behind or lacks a task: over the same connection, that has to
    // send the sessions again, not be taken as subscribed already.
    let h = harness("server-resub").await;
    let mut app = Client::connect(&h.socket).await;
    let task = app.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "lead"})).await;
    let task = task["result"]["session"].as_str().unwrap().to_string();
    for _ in 0..2 {
        app.events.clear();
        app.call(json!({"op": "subscribe"})).await;
        loop {
            let event = app.event().await;
            if event["event"] == "session" && event["conversation"]["id"] == task.as_str() {
                break;
            }
        }
    }
}

#[tokio::test]
async fn a_lead_unarchived_brings_back_the_workers_archived_with_it_and_no_others() {
    let h = harness("server-unarchive").await;
    let mut client = Client::connect(&h.socket).await;
    let lead =
        client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "lead", "permissions": "unrestricted"})).await;
    let lead = lead["result"]["session"].as_str().unwrap().to_string();
    let worker = |label: &'static str| json!({"op": "spawn", "session": lead, "provider": "codex", "prompt": "ls", "label": label});
    let one = client.call(worker("One")).await["result"]["session"].as_str().unwrap().to_string();
    let two = client.call(worker("Two")).await["result"]["session"].as_str().unwrap().to_string();
    let ids =
        |listed: &Value| listed["result"].as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();

    // Child one put away on its own; then the lead, which takes child two with it.
    assert_eq!(client.call(json!({"op": "archive", "session": one})).await["ok"], true);
    assert_eq!(client.call(json!({"op": "archive", "session": lead})).await["ok"], true);
    assert!(ids(&client.call(json!({"op": "list"})).await).is_empty(), "the lead and child two went together");
    let archived = client.call(json!({"op": "archived"})).await;
    let roots: Vec<(String, u64)> =
        archived["result"].as_array().unwrap().iter().map(|a| (a["id"].as_str().unwrap().into(), a["workers"].as_u64().unwrap())).collect();
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
    let saved = client
        .call(json!({"op": "saveMcpServer", "server": {"name": "CVE lookup", "command": "cve-mcp", "workspaces": ["cybersecurity"],
        "env": [{"name": "REGION", "value": "eu", "from": "file"}]}}))
        .await;
    assert_eq!(saved["result"]["id"], "cve-lookup", "{saved}");
    assert_eq!(client.call(json!({"op": "mcpServers"})).await["result"][0]["name"], "CVE lookup");
    let start =
        |workspace: Option<&str>| json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls", "workspace": workspace});
    client.call(start(Some("cybersecurity"))).await;
    client.call(start(None)).await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let configs: Vec<serde_json::Value> =
        h.seen.lock().unwrap().iter().filter_map(|seen| seen.first("thread/start").map(|m| m["params"]["config"].clone())).collect();
    assert_eq!(configs.len(), 2, "{configs:?}");
    assert_eq!(configs[0]["mcp_servers.cve-lookup"]["env"]["REGION"], "eu", "the Cybersecurity task has its server");
    assert!(configs[1].get("mcp_servers.cve-lookup").is_none(), "Zero's doesn't: {}", configs[1]);
}

#[tokio::test]
async fn a_tasks_transcript_keeps_its_mcp_servers_without_their_values() {
    let h = harness("server-mcp-redact").await;
    let mut client = Client::connect(&h.socket).await;
    client
        .call(json!({"op": "saveMcpServer", "server": {"name": "Docs", "url": "https://docs.example/mcp",
        "headers": [{"name": "Authorization", "value": "Bearer s3cr3t-41", "from": "file"}]}}))
        .await;
    let started = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let config = h.seen.lock().unwrap().iter().find_map(|seen| seen.first("thread/start").map(|m| m["params"]["config"].clone())).unwrap();
    assert_eq!(config["mcp_servers.docs"]["http_headers"]["Authorization"], "Bearer s3cr3t-41", "Codex is given it");
    let transcript = std::fs::read_to_string(h.home.join("sessions").join(&session).join("transcript.jsonl")).unwrap();
    assert!(transcript.contains("thread/start") && transcript.contains("mcp_servers.docs"), "the start is kept");
    assert!(!transcript.contains("s3cr3t-41"), "but not the value, on disk");
}

#[tokio::test]
async fn a_server_saved_reaches_the_running_tasks_without_a_restart_and_codex_at_its_next_turn() {
    let h = harness("server-mcp-live").await;
    let mut client = Client::connect(&h.socket).await;
    let mut ids = vec![];
    for provider in ["claude", "opencode", "codex"] {
        let started = client.call(json!({"op": "start", "provider": provider, "cwd": h.project, "prompt": "ls"})).await;
        let id = started["result"]["session"].as_str().unwrap_or_else(|| panic!("{started}")).to_string();
        // Codex's stops at its approval, mid-turn.
        until(&h.daemon.session(&id).unwrap(), |c| c.status == Status::Idle || !c.approvals.is_empty()).await;
        ids.push(id);
    }
    let seen = |n: usize| h.seen.lock().unwrap()[n].clone();
    let saved = client
        .call(json!({"op": "saveMcpServer", "server": {"name": "Docs", "url": "https://docs.example/mcp",
        "headers": [{"name": "Authorization", "value": "Bearer t-9", "from": "file"}]}}))
        .await;
    assert_eq!(saved["ok"], true, "{saved}");

    // Claude takes the whole list at once, its values as they are (it doesn't expand a ${…} there).
    let set = seen(0).said("control_request:mcp_set_servers", 1).await;
    assert_eq!(
        set[0]["request"]["servers"]["docs"],
        json!({"type": "http", "url": "https://docs.example/mcp", "headers": {"Authorization": "Bearer t-9"}})
    );
    // OpenCode the same, on the connection it has: Zero's own server still in it.
    let resumed = seen(1).said("session/resume", 1).await;
    let names: Vec<&str> = resumed[0]["params"]["mcpServers"].as_array().unwrap().iter().map(|s| s["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["zero", "docs"]);
    assert_eq!(resumed[0]["params"]["mcpServers"][1]["headers"][0]["value"], "Bearer t-9");
    // Codex can't: it stops once its turn is over, and its next message starts it again with them.
    let codex = h.daemon.session(&ids[2]).unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert!(codex.is_attached(), "not mid-turn");
    let approval = codex.snapshot().approvals[0].clone();
    client.call(json!({"op": "decide", "session": ids[2], "approval": approval.id, "choice": approval.choices[0].id})).await;
    until(&codex, |c| c.status == Status::Offline).await;
    assert_eq!(h.commands.lock().unwrap().len(), 3, "nothing started again yet");
    client.call(json!({"op": "send", "session": ids[2], "text": "and now?"})).await;
    let config = seen(3).said("thread/resume", 1).await[0]["params"]["config"].clone();
    assert_eq!(config["mcp_servers.docs"]["http_headers"]["Authorization"], "Bearer t-9");

    // Taken away: Claude's list no longer has it; nothing changed for a task, nothing is said.
    client.call(json!({"op": "deleteMcpServer", "server": "docs"})).await;
    let set = seen(0).said("control_request:mcp_set_servers", 2).await;
    assert_eq!(set[1]["request"]["servers"], json!({}));
    assert_eq!(seen(1).said("session/resume", 2).await[1]["params"]["mcpServers"].as_array().unwrap().len(), 1);
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Elsewhere", "glyph": "", "folders": []}})).await;
    client.call(json!({"op": "saveMcpServer", "server": {"name": "Other", "command": "other-mcp", "workspaces": ["elsewhere"]}})).await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(seen(0).methods().iter().filter(|m| *m == "control_request:mcp_set_servers").count(), 2, "not this workspace's");
}

async fn find_ask(client: &mut Client, id: &str) -> Value {
    client.call(json!({"op": "asks"})).await["result"].as_array().unwrap().iter().find(|a| a["id"] == id).unwrap().clone()
}

#[tokio::test]
async fn an_agent_proposes_an_mcp_server_and_once_the_user_approves_its_task_has_it_live() {
    let h = harness("server-mcp-ask").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "configure", "takeBack": 0.02, "ttl": 600})).await;
    client
        .call(json!({"op": "saveMcpServer", "server": {"name": "Paper", "url": "https://mcp.paper.design",
        "headers": [{"name": "X-Team", "value": "team-secret", "from": "file"}]}}))
        .await;
    let started = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    until(&h.daemon.session(&session).unwrap(), |c| c.status == Status::Idle).await;
    let agent = |args: Value| json!({"op": "agentAsk", "session": session, "args": args});

    // The agent reads what there is, values left out.
    let listed = client.call(agent(json!({"tool": "mcp_list"}))).await;
    assert_eq!(listed["result"][0]["id"], "paper", "{listed}");
    assert!(!listed.to_string().contains("team-secret"), "{listed}");
    let unsaid = client.call(agent(json!({"tool": "mcp", "name": "paper", "command": "paper"}))).await;
    assert!(unsaid["error"].as_str().unwrap().contains("why"), "{unsaid}");

    // Back to the local server: a change of the one there, shown as such, nothing changed before the user's word. Its
    // values stay where they're kept: the ask (in the log, to every client) has the names alone.
    let local = json!({"tool": "mcp", "name": "paper", "command": "/Users/me/.paper/bin/paper", "args": ["mcp"], "lazy": true,
                       "headers": ["X-Team"], "why": "Paper's design tools"});
    let asked = client.call(agent(local)).await;
    let id = asked["result"]["id"].as_str().unwrap_or_else(|| panic!("{asked}")).to_string();
    let card = find_ask(&mut client, &id).await;
    assert_eq!((card["kind"].as_str(), card["title"].as_str()), (Some("approve"), Some("Change the MCP server paper?")));
    assert_eq!(card["options"][0], "Change it");
    let body = card["body"].as_str().unwrap();
    assert!(
        body.contains("Paper's design tools")
            && body.contains("https://mcp.paper.design")
            && body.contains("/Users/me/.paper/bin/paper mcp"),
        "{body}"
    );
    assert_eq!(client.call(json!({"op": "mcpServers"})).await["result"][0]["url"], "https://mcp.paper.design");
    assert!(!client.call(json!({"op": "asks"})).await.to_string().contains("team-secret"), "no value in an ask");

    client.call(json!({"op": "choose", "ask": id, "option": 0})).await;
    let claude = h.seen.lock().unwrap()[0].clone();
    let set = claude.said("control_request:mcp_set_servers", 1).await;
    let given = &set[0]["request"]["servers"]["paper"];
    assert_eq!(given["args"].as_array().unwrap()[1..], [json!("lazy"), json!("/Users/me/.paper/bin/paper"), json!("mcp")], "{given}");
    let mut done = find_ask(&mut client, &id).await;
    for _ in 0..200 {
        if done["state"] == "answered" {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        done = find_ask(&mut client, &id).await;
    }
    assert_eq!(done["state"], "answered", "{done}");
    assert!(done["output"].as_str().unwrap().contains("paper"), "the answer says what came: {done}");
    let kept = client.call(json!({"op": "mcpServers"})).await["result"][0].clone();
    assert_eq!(
        (kept["id"].as_str(), kept["command"].as_str(), kept["url"].as_str()),
        (Some("paper"), Some("/Users/me/.paper/bin/paper"), None)
    );
    assert_eq!((kept["lazy"].as_bool(), kept["workspaces"].clone()), (Some(true), json!([])), "still every workspace's");
    assert_eq!(kept["headers"][0]["value"], "team-secret", "its value as it was kept");

    // An ask with a server that zerod didn't make (any client can make an ask, and say zerod made it) keeps
    // nothing, whatever the user answers it.
    let forged = json!({"id": "", "kind": "approve", "title": "Ship it?", "options": ["Yes", "No"], "agent": {"name": "codex-1", "host": "mac"},
        "createdAt": "2026-01-01T00:00:00Z", "expiresAt": "2030-01-01T00:00:00Z", "state": "waiting", "output": "",
        "mcp": {"name": "evil", "command": "/tmp/evil"}, "mcpMade": true});
    let forged = client.call(json!({"op": "create", "ask": forged})).await["result"]["id"].as_str().unwrap().to_string();
    client.call(json!({"op": "choose", "ask": forged, "option": 0})).await;

    // A new one is for the asking task's workspace; one the user rejects is never kept.
    let docs = client.call(agent(json!({"tool": "mcp", "name": "Docs", "url": "https://docs.example/mcp", "why": "the API docs"}))).await;
    let docs = docs["result"]["id"].as_str().unwrap().to_string();
    assert_eq!(find_ask(&mut client, &docs).await["title"], "Add the MCP server Docs?");
    client.call(json!({"op": "choose", "ask": docs, "option": 0})).await;
    let rejected = client.call(agent(json!({"tool": "mcp", "name": "Nope", "command": "nope", "why": "no"}))).await;
    client.call(json!({"op": "choose", "ask": rejected["result"]["id"], "option": 1})).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let servers = client.call(json!({"op": "mcpServers"})).await["result"].clone();
    let workspace = h.daemon.workspace_of(&h.daemon.get(&session).unwrap());
    assert_eq!(servers.as_array().unwrap().iter().map(|s| s["id"].as_str().unwrap()).collect::<Vec<_>>(), ["paper", "docs"], "no evil");
    assert_ne!(find_ask(&mut client, &forged).await["state"], "answered", "not kept as if it were");
    assert_eq!(servers[1]["workspaces"], json!([workspace]));
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
    let asked = control
        .call(json!({"op": "agentAsk", "session": session, "args": {"tool": "ask", "question": "Start the check, or wait for Dana?",
                                                                                     "options": ["Start it", "Wait for Dana"]}}))
        .await;
    assert_eq!(asked["ok"], true, "{asked}");
    let id = asked["result"]["id"].as_str().unwrap().to_string();
    let ran = control
        .call(json!({"op": "agentAsk", "session": session, "args": {"tool": "run", "command": "bin/prod-check", "why": "the counts"}}))
        .await;
    assert_eq!(ran["ok"], true, "{ran}");
    control
        .call(json!({"op": "agentAsk", "session": session, "args": {"tool": "note", "text": "Waiting on QA", "state": "waiting"}}))
        .await;
    assert!(
        control.call(json!({"op": "agentAsk", "session": session, "args": {"tool": "run", "command": "x"}})).await["ok"] == false,
        "a run says why"
    );
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
    let ops = "adopt agentAsk anchor answer answerAsk archive archived asks attr board branch browserCall browserSettings browserState browsers \
        cancelRun choose close closeTerminal configure connectSlack create decide defaultSignIn deleteLoop desktopCall deleteMcpServer deleteSignIn \
        deleteWorkspace deliver detach dismiss firefox follow following get hello interrupt items label later list loop loops \
        mcpServers message migrate notify openTerminal outline pad place placeInWorkspace queue recent release remind \
        reorderWorkspaces reply restartStatus result resume rewind rewindPreview saveBrowserSettings saveLoop saveMcpServer saveSignIn saveWorkspace \
        schedule schedules seen send setAdvisor setPermissions settings signIns spawn start stop switch switchModel \
        table takeBack unarchive unfollow unqueue unschedule unwatch wait watch watchFile watches window withdraw workers workspaces";
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
    let ran = control
        .call(json!({"op": "agentAsk", "session": session, "args": {"tool": "run", "command": "bin/prod-check", "why": "the counts"}}))
        .await;
    let run = ran["result"]["id"].as_str().unwrap().to_string();
    // Sent once the agent is up (still starting, a send is turned away).
    for _ in 0..60 {
        if control.call(json!({"op": "send", "session": session, "text": "let's talk about the formatters"})).await["error"].is_null() {
            break;
        }
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
        if given.contains(zerod::daemon::OPEN_ASKS_MARK) {
            break;
        }
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
    let set =
        |ticket: &str, state: &str, text: &str| json!({"op": "issue", "session": session, "ticket": ticket, "state": state, "text": text});
    assert_eq!(control.call(set("ENG-1", "you", "merge decision")).await["ok"], true);
    assert_eq!(control.call(set("ENG-2", "waiting", "CI on app#12")).await["ok"], true);
    let refused = control.call(set("ENG-3", "dancing", "")).await;
    assert!(refused["error"].as_str().unwrap().contains("you, over, working, waiting, parked or done"), "{refused}");
    let board = control.call(json!({"op": "board"})).await;
    let row = board["result"]["rows"]
        .as_array()
        .or(board["result"].as_array())
        .unwrap()
        .iter()
        .find(|r| r["session"] == session.as_str())
        .unwrap()
        .clone();
    let issues: Vec<(String, String)> = row["issues"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| (i["ticket"].as_str().unwrap().into(), i["state"].as_str().unwrap().into()))
        .collect();
    assert_eq!(issues, [("ENG-1".to_string(), "you".to_string()), ("ENG-2".into(), "waiting".into())]);
    assert_eq!(row["state"], "needsYou");
    // Kept: another zerod, rebuilt from the transcript, has the rows.
    assert!(std::fs::read_to_string(h.home.join("sessions").join(&session).join("transcript.jsonl")).unwrap().contains("merge decision"));
}

#[tokio::test]
async fn an_issue_carries_what_it_needs_its_pr_and_the_leads_own_columns() {
    // The board in the conversation shows what the lead's own tables did: what the issue needs from the user in the
    // lead's words, its pull request, and columns of the lead's (a merge risk, say). Left out, each keeps what it was;
    // given empty, it's taken back.
    let h = harness("server-issue-fields").await;
    let mut control = Client::connect(&h.socket).await;
    let started = control.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "lead these"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    async fn issue(control: &mut Client, session: &str, extra: Value) -> Value {
        let mut request = json!({"op": "issue", "session": session, "ticket": "ENG-1", "state": "over"});
        request.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        control.call(request).await
    }
    let row = |board: Value| {
        let rows = board["result"]["rows"].as_array().or(board["result"].as_array()).unwrap().clone();
        rows.into_iter().find(|r| r["session"] == session.as_str()).unwrap()["issues"][0].clone()
    };
    let set = json!({"text": "verified; CI green", "needs": "check the bench tabs", "pr": "https://github.com/acme/app/pull/12",
                     "fields": ["Merge risk=Medium", "Owner=app-12"]});
    assert_eq!(issue(&mut control, &session, set).await["ok"], true);
    assert_eq!(issue(&mut control, &session, json!({"text": "verified; CI green, 2 approvals"})).await["ok"], true);
    let kept = row(control.call(json!({"op": "board"})).await);
    assert_eq!(kept["text"], "verified; CI green, 2 approvals");
    assert_eq!((kept["needs"].as_str(), kept["pr"].as_str()), (Some("check the bench tabs"), Some("https://github.com/acme/app/pull/12")));
    assert_eq!(
        kept["fields"],
        json!([{"name": "Merge risk", "value": "Medium"}, {"name": "Owner", "value": "app-12"}]),
        "in the order given"
    );

    let cleared = json!({"state": "done", "text": "merged", "needs": "", "fields": ["Merge risk=Low", "Owner="]});
    assert_eq!(issue(&mut control, &session, cleared).await["ok"], true);
    let now = row(control.call(json!({"op": "board"})).await);
    assert!(now.get("needs").is_none(), "taken back: {now}");
    assert_eq!(now["pr"], "https://github.com/acme/app/pull/12", "left out, kept");
    assert_eq!(now["fields"], json!([{"name": "Merge risk", "value": "Low"}]), "changed in place, an empty one gone");

    let refused = issue(&mut control, &session, json!({"fields": ["Merge risk"]})).await;
    assert!(refused["error"].as_str().unwrap().contains("Name=value"), "{refused}");
}

/// Models the user adds to Zero for a CLI (one its own list doesn't have yet): kept Zero-wide, each with the id the CLI
/// is started with and the name the picker shows; a later list replaces the earlier one.
#[tokio::test]
async fn custom_models_are_kept_zero_wide() {
    let h = harness("server-models").await;
    let mut client = Client::connect(&h.socket).await;
    let models = json!([{"cli": "claude", "id": "claude-mythos-5-2", "name": "Mythos 5.2"}]);
    client.call(json!({"op": "configure", "models": models})).await;
    assert_eq!(client.call(json!({"op": "settings"})).await["result"]["models"], models);
    client.call(json!({"op": "configure", "ttl": 60})).await;
    assert_eq!(client.call(json!({"op": "settings"})).await["result"]["models"], models, "kept when other settings change");
    client.call(json!({"op": "configure", "models": []})).await;
    assert!(client.call(json!({"op": "settings"})).await["result"]["models"].as_array().is_none_or(|m| m.is_empty()));
}

#[tokio::test]
async fn the_user_sets_a_tasks_status_done_waiting_or_blocked_as_a_confirmed_note_would() {
    // Done without its agent knowing (the last of it was the user's own work): the user says so, and the row is Done as
    // the agent's confirmed `zero done` makes it. Waiting and blocked likewise; what an agent's activity says isn't theirs to set.
    let h = harness("server-set-status").await;
    let mut client = Client::connect(&h.socket).await;
    let started =
        client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls", "permissions": "unrestricted"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let state =
        |board: &Value| board["result"].as_array().unwrap().iter().find(|r| r["session"] == session.as_str()).map(|r| r["state"].clone());
    for (status, shown) in [("waiting", "waiting"), ("blocked", "blocked"), ("done", "done")] {
        let set = client.call(json!({"op": "setStatus", "session": session, "state": status})).await;
        assert_eq!(set["ok"], true, "{set}");
        let mut board = client.call(json!({"op": "board"})).await;
        for _ in 0..40 {
            if state(&board) == Some(json!(shown)) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            board = client.call(json!({"op": "board"})).await;
        }
        assert_eq!(state(&board), Some(json!(shown)), "{status}: {board}");
    }
    let refused = client.call(json!({"op": "setStatus", "session": session, "state": "working"})).await;
    assert_eq!(refused["ok"], false, "{refused}");
}

#[tokio::test]
async fn the_users_word_on_a_task_moves_its_issue_rows_that_say_otherwise() {
    // The agent set its issue done (or over to the user) and the user marked the task waiting: the row kept saying so
    // over a task that waits. A row the user's word contradicts takes it; one that doesn't (working) stays.
    let h = harness("server-mark-rows").await;
    let mut client = Client::connect(&h.socket).await;
    let started = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "lead these"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    let set = |ticket: &str, state: &str| json!({"op": "issue", "session": session, "ticket": ticket, "state": state, "text": "merged"});
    client.call(set("ENG-1", "done")).await;
    client.call(set("ENG-2", "working")).await;
    client.call(set("ENG-3", "over")).await;
    let rows = |board: Value| -> Vec<String> {
        let rows = board["result"]["rows"].as_array().or(board["result"].as_array()).unwrap().clone();
        let row = rows.into_iter().find(|r| r["session"] == session.as_str()).unwrap();
        let mut rows: Vec<(String, String)> = row["issues"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| (i["ticket"].as_str().unwrap().into(), i["state"].as_str().unwrap().into()))
            .collect();
        rows.sort();
        rows.into_iter().map(|(_, state)| state).collect()
    };
    client.call(json!({"op": "setStatus", "session": session, "state": "waiting"})).await;
    assert_eq!(rows(client.call(json!({"op": "board"})).await), ["waiting", "working", "waiting"], "on the user contradicts waiting too");
    let row =
        |board: Value| board["result"].as_array().unwrap().iter().find(|r| r["session"] == session.as_str()).unwrap()["state"].clone();
    assert_eq!(row(client.call(json!({"op": "board"})).await), "waiting", "not over to the user");
    client.call(set("ENG-3", "you")).await;
    client.call(json!({"op": "setStatus", "session": session, "state": "blocked"})).await;
    assert_eq!(rows(client.call(json!({"op": "board"})).await), ["waiting", "working", "parked"], "a working row isn't contradicted");
    client.call(json!({"op": "setStatus", "session": session, "state": "done"})).await;
    assert_eq!(rows(client.call(json!({"op": "board"})).await), ["done", "done", "done"]);
}

#[tokio::test]
async fn a_subscriber_that_falls_behind_gets_snapshots_of_what_changed_since_not_of_everything() {
    // A burst (thousands of changes at once) leaves a subscriber behind: every session sent again in full, each
    // carrying its whole latest turn, while the burst went on put it behind again, and gigabytes waited for the app.
    let h = harness("server-behind").await;
    let mut control = Client::connect(&h.socket).await;
    let mut ids = vec![];
    for _ in 0..2 {
        let started = control.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "uname"})).await;
        ids.push(started["result"]["session"].as_str().unwrap().to_string());
    }
    let mut watcher = Client::connect(&h.socket).await;
    watcher.call(json!({"op": "subscribe"})).await;
    let mut mirror = vec![];
    for id in &ids {
        watcher.follow(&mut mirror, id, |c| c.status == Status::Idle && c.turn.is_none()).await;
    }
    let (quiet, busy) = (&ids[0], &ids[1]);
    let session = h.daemon.session(busy).unwrap();
    for n in 0..5000 {
        session.change(zerod::model::Change::Title { title: Some(format!("t{n}")) });
    }
    let mut sent = std::collections::HashMap::<String, usize>::new();
    loop {
        if mirror.iter().any(|c| &c.id == busy && c.title.as_deref() == Some("t4999")) {
            break;
        }
        let event = watcher.event().await;
        match event["event"].as_str().unwrap() {
            "session" => {
                let conversation: Conversation = serde_json::from_value(event["conversation"].clone()).unwrap();
                *sent.entry(conversation.id.clone()).or_default() += 1;
                mirror.retain(|c| c.id != conversation.id);
                mirror.push(conversation);
            }
            "change" => {
                let target = mirror.iter_mut().find(|c| c.id == event["session"]).unwrap();
                assert_eq!(event["seq"], json!(target.seq + 1), "no gaps, no repeats");
                target.apply(serde_json::from_value(event["change"].clone()).unwrap());
            }
            _ => {}
        }
    }
    assert_eq!(sent.get(busy), Some(&1), "what changed, once");
    assert_eq!(sent.get(quiet), None, "not what didn't");
}

#[tokio::test]
async fn settings_say_which_terminal_app_tasks_open_in_resolved() {
    // The app names the action after it ("Open in Ghostty"): unset, it's what zerod would open, the default.
    let h = harness("server-terminal").await;
    let mut client = Client::connect(&h.socket).await;
    let unset = client.call(json!({"op": "settings"})).await["result"].clone();
    assert!(["Ghostty", "Terminal"].contains(&unset["terminalApp"].as_str().unwrap()), "{unset}");
    assert!(unset["terminal"].is_null(), "the setting itself stays unset");
    client.call(json!({"op": "configure", "terminal": "/Applications/iTerm.app"})).await;
    assert_eq!(client.call(json!({"op": "settings"})).await["result"]["terminalApp"], "/Applications/iTerm.app");
}

#[tokio::test]
async fn the_app_puts_the_workspaces_in_order() {
    let h = harness("server-order").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Personal", "glyph": ""}})).await;
    let answer = client.call(json!({"op": "reorderWorkspaces", "order": ["personal", "zero"]})).await;
    let ids =
        |listed: &Value| listed["result"].as_array().unwrap().iter().map(|w| w["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    assert_eq!(ids(&answer), ["personal", "zero"], "{answer}");
    assert_eq!(ids(&client.call(json!({"op": "workspaces"})).await), ["personal", "zero"]);
    assert!(client.call(json!({"op": "reorderWorkspaces"})).await["error"].is_string(), "an order is needed");
}

#[tokio::test]
async fn loops_and_pads_are_listed_by_workspace_and_an_agents_pad_is_made_in_its_tasks() {
    let h = harness("server-scoped").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Personal", "glyph": "", "color": "teal"}})).await;
    let listed = client.call(json!({"op": "workspaces"})).await;
    assert_eq!(listed["result"][1]["color"], "teal");

    client.call(json!({"op": "saveLoop", "name": "mine", "body": "Go."})).await;
    let saved = client.call(json!({"op": "saveLoop", "name": "home", "body": "Go.", "workspace": "personal"})).await;
    assert_eq!(saved["result"]["workspace"], "personal", "{saved}");
    client.call(json!({"op": "saveLoop", "name": "home", "body": "Go on."})).await;
    let names =
        |result: &Value| result["result"].as_array().unwrap().iter().map(|l| l["name"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    assert_eq!(names(&client.call(json!({"op": "loops", "workspace": "personal"})).await), ["home"], "kept its workspace");
    assert_eq!(names(&client.call(json!({"op": "loops", "workspace": "zero"})).await), ["mine"]);
    assert_eq!(names(&client.call(json!({"op": "loops"})).await), ["home", "mine"], "without one, all");

    let started = client.call(json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": "ls", "workspace": "personal"})).await;
    let session = started["result"]["session"].as_str().unwrap_or_else(|| panic!("{started}")).to_string();
    let made = client.call(json!({"op": "pad", "tool": "create", "session": session, "args": {"title": "Agent's"}})).await;
    assert_eq!(made["result"]["workspace"], "personal", "{made}");
    client.call(json!({"op": "pad", "tool": "create", "args": {"title": "App's"}})).await;
    let pads = |result: &Value| {
        result["result"]["pads"].as_array().unwrap().iter().map(|p| p["title"].as_str().unwrap().to_string()).collect::<Vec<_>>()
    };
    assert_eq!(pads(&client.call(json!({"op": "pad", "tool": "list", "args": {"workspace": "personal"}})).await), ["Agent's"]);

    // The workspace deleted: its loops and pads are Zero's.
    client.call(json!({"op": "deleteWorkspace", "workspace": "personal"})).await;
    assert_eq!(names(&client.call(json!({"op": "loops", "workspace": "zero"})).await), ["home", "mine"]);
    let mut zeros = pads(&client.call(json!({"op": "pad", "tool": "list", "args": {"workspace": "zero"}})).await);
    zeros.sort();
    assert_eq!(zeros, ["Agent's", "App's"]);
}

/// The user's move from the task menu, over the socket: under another task, then back to a task of its own.
#[tokio::test]
async fn the_app_moves_a_task_under_another_and_back() {
    let h = harness("server-set-parent").await;
    let mut client = Client::connect(&h.socket).await;
    let start = |prompt: &str| json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": prompt});
    let lead = client.call(start("lead")).await["result"]["session"].as_str().unwrap().to_string();
    let task = client.call(start("a part")).await["result"]["session"].as_str().unwrap().to_string();
    let moved = client.call(json!({"op": "setParent", "session": task, "args": {"parent": lead}})).await;
    assert_eq!(moved["ok"], true, "{moved}");
    assert_eq!(h.daemon.get(&task).unwrap().parent.as_deref(), Some(lead.as_str()));
    let looped = client.call(json!({"op": "setParent", "session": lead, "args": {"parent": task}})).await;
    assert_eq!(looped["ok"], false, "{looped}");
    assert_eq!(client.call(json!({"op": "setParent", "session": task, "args": {"parent": null}})).await["ok"], true);
    assert_eq!(h.daemon.get(&task).unwrap().parent, None);
}

/// An agent's `zero adopt` and `zero detach`, over the socket: its session is who did it.
#[tokio::test]
async fn an_agent_adopts_and_detaches_over_the_socket() {
    let h = harness("server-adopt-detach").await;
    let mut client = Client::connect(&h.socket).await;
    let start = |prompt: &str| json!({"op": "start", "provider": "codex", "cwd": h.project, "prompt": prompt});
    let lead = client.call(start("lead")).await["result"]["session"].as_str().unwrap().to_string();
    let task = client.call(start("a part")).await["result"]["session"].as_str().unwrap().to_string();
    let adopted = client.call(json!({"op": "adopt", "session": lead, "thread": task})).await;
    assert_eq!(adopted["result"]["session"], task.as_str(), "{adopted}");
    assert_eq!(h.daemon.get(&task).unwrap().parent.as_deref(), Some(lead.as_str()));
    let detached = client.call(json!({"op": "detach", "session": lead, "thread": task})).await;
    assert_eq!(detached["ok"], true, "{detached}");
    assert_eq!(h.daemon.get(&task).unwrap().parent, None);
    // Only inside a task, of its own workers; adopting into another's tree, by who runs it, is refused.
    let anonymous = client.call(json!({"op": "detach", "thread": task})).await;
    assert!(anonymous["error"].as_str().is_some_and(|e| e.contains("inside a task")), "{anonymous}");
    let other = client.call(start("another lead")).await["result"]["session"].as_str().unwrap().to_string();
    let theirs = client.call(json!({"op": "adopt", "session": other, "thread": task, "args": {"by": lead}})).await;
    assert!(theirs["error"].as_str().is_some_and(|e| e.contains("isn't you or one of your workers")), "{theirs}");
    assert_eq!(h.daemon.get(&task).unwrap().parent, None);
    // Its lead's quiet line names who let it go: the session that ran it, not the user.
    let line = h.daemon.session(&lead).unwrap().snapshot().items.iter().find_map(|i| match &i.kind {
        zerod::model::ItemKind::Notice { text, .. } if text.contains("was detached by") => Some(text.clone()),
        _ => None,
    });
    assert!(line.as_deref().is_some_and(|l| !l.contains("the user")), "{line:?}");
}

#[tokio::test]
async fn a_rewind_over_the_socket_is_refused_when_its_preview_counted_fewer_messages() {
    let h = harness("server-rewind-stale").await;
    let user = h.home.join("user");
    h.daemon.place(&user);
    let cwd = h.project.to_str().unwrap();
    let file = zerod::handoff::claude_folder(&user, cwd).join("t1.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let said = |uuid: &str, role: &str, text: &str| json!({"type": role, "uuid": uuid, "message": {"role": role, "content": [{"type": "text", "text": text}]}});
    let records = [said("u1", "user", "first"), said("a1", "assistant", "done one")];
    std::fs::write(&file, records.iter().map(|r| r.to_string() + "\n").collect::<String>()).unwrap();
    let id = h.daemon.adopt(Provider::Claude, "t1", cwd, Default::default()).unwrap();
    let first = h.daemon.get(&id).unwrap().items[0].id.clone();
    let mut client = Client::connect(&h.socket).await;

    let stale = client.call(json!({"op": "rewind", "session": id, "message": first, "conversation": true, "messages": 1})).await;
    assert_eq!(stale["ok"], false, "the preview's count reaches the guard: {stale}");
    assert_eq!(h.daemon.get(&id).unwrap().items.len(), 2);
    let rewound = client.call(json!({"op": "rewind", "session": id, "message": first, "conversation": true, "messages": 2})).await;
    assert_eq!(rewound["result"]["text"], "first", "{rewound}");
}

#[tokio::test]
async fn zero_signs_in_to_a_remote_server_an_agent_adds_and_its_task_gets_the_token() {
    let h = harness("server-mcp-oauth").await;
    zerod::mcp_auth::start(h.daemon.clone(), h.inbox.clone());
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "configure", "takeBack": 0.02, "ttl": 600})).await;
    let started = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    until(&h.daemon.session(&session).unwrap(), |c| c.status == Status::Idle).await;
    let challenge = "\n401|Bearer resource_metadata=\"https://docs.example/.well-known/oauth-protected-resource\"";
    *h.web.answers.lock().unwrap() = vec![
        challenge.into(),
        challenge.into(),
        "{\"authorization_servers\":[\"https://docs.example\"]}\n200|".into(),
        "{\"authorization_endpoint\":\"https://docs.example/authorize\",\"token_endpoint\":\"https://docs.example/token\",\"registration_endpoint\":\"https://docs.example/register\"}\n200|".into(),
        "{\"client_id\":\"zero-1\"}\n201|".into(),
        "{\"access_token\":\"tok-1\",\"refresh_token\":\"ref-1\",\"expires_in\":3600}\n200|".into(),
    ];

    let asked = client
        .call(json!({"op": "agentAsk", "session": session, "args": {"tool": "mcp", "name": "Docs", "url": "https://docs.example/mcp", "why": "the API docs"}}))
        .await;
    let id = asked["result"]["id"].as_str().unwrap_or_else(|| panic!("{asked}")).to_string();
    client.call(json!({"op": "choose", "ask": id, "option": 0})).await;
    let mut done = find_ask(&mut client, &id).await;
    for _ in 0..200 {
        if done["state"] == "answered" {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        done = find_ask(&mut client, &id).await;
    }
    assert!(done["output"].as_str().unwrap_or_default().contains("needs signing in"), "{done}");

    // Zero's own sign-in, asked of the user; until it's made the task isn't given the server.
    let mut link = None;
    for _ in 0..300 {
        let asks = client.call(json!({"op": "asks"})).await["result"].clone();
        link =
            asks.as_array().unwrap().iter().find(|a| a["title"] == "Sign in to docs?").and_then(|a| a["link"].as_str().map(String::from));
        if link.is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let link = link.expect("a sign-in ask with its link");
    assert!(link.starts_with("https://docs.example/authorize?") && link.contains("client_id=zero-1"), "{link}");
    let claude = h.seen.lock().unwrap()[0].clone();
    assert!(!claude.methods().iter().any(|m| m == "control_request:mcp_set_servers"), "not given before it's signed in to");

    let query = |key: &str| link.split(&format!("{key}=")).nth(1).unwrap().split('&').next().unwrap().to_string();
    let redirect = query("redirect_uri").replace("%3A", ":").replace("%2F", "/");
    let port: u16 = redirect.trim_start_matches("http://127.0.0.1:").trim_end_matches("/callback").parse().unwrap();
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    stream.write_all(format!("GET /callback?code=c0de&state={} HTTP/1.1\r\n\r\n", query("state")).as_bytes()).await.unwrap();
    let mut page = String::new();
    tokio::io::AsyncReadExt::read_to_string(&mut stream, &mut page).await.unwrap();
    assert!(page.contains("Zero signed in to docs"), "{page}");

    // Signed in: the task has it, its token the header.
    let set = claude.said("control_request:mcp_set_servers", 1).await;
    assert_eq!(set[0]["request"]["servers"]["docs"]["headers"]["Authorization"], "Bearer tok-1", "{}", set[0]);
    assert!(!claude.methods().iter().any(|m| m == "control_request:mcp_reconnect"), "changed, not reconnected without it");
    // One line in the task for the sign-in, its link replaced by the outcome.
    let notices = || -> Vec<String> {
        h.daemon
            .get(&session)
            .unwrap()
            .items
            .iter()
            .filter_map(|i| match &i.kind {
                zerod::model::ItemKind::Notice { text, .. } if text.contains("docs") => Some(text.clone()),
                _ => None,
            })
            .collect()
    };
    for _ in 0..200 {
        if notices().iter().any(|n| n.starts_with("Signed in")) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert_eq!(notices(), ["Signed in to docs"]);

    // Deleted, its sign-in goes with it.
    client.call(json!({"op": "deleteMcpServer", "server": "docs"})).await;
    let token = std::fs::read_to_string(h.home.join("secrets.json")).unwrap();
    assert!(!token.contains("tok-1"), "{token}");
}

#[tokio::test]
async fn a_remote_server_a_tasks_claude_has_of_its_own_and_needs_signing_in_to_becomes_zeros() {
    let h = harness("server-mcp-adopt").await;
    zerod::mcp_auth::start(h.daemon.clone(), h.inbox.clone());
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "configure", "takeBack": 0.02, "ttl": 600})).await;
    let started = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    until(&h.daemon.session(&session).unwrap(), |c| c.status == Status::Idle).await;
    let claude = h.seen.lock().unwrap()[0].clone();
    claude.answer(
        "mcp_status",
        json!({"mcpServers": [{"name": "amie", "status": "needs-auth", "scope": "user", "config": {"type": "http", "url": "https://amie.example/mcp"}}]}),
    );
    let challenge = "\n401|Bearer resource_metadata=\"https://amie.example/.well-known/oauth-protected-resource\"";
    let metadata = "{\"authorization_servers\":[\"https://amie.example\"]}\n200|";
    let server = "{\"authorization_endpoint\":\"https://amie.example/authorize\",\"token_endpoint\":\"https://amie.example/token\",\"registration_endpoint\":\"https://amie.example/register\"}\n200|";
    // Asked whether Zero can sign in to it (a challenge, a registration endpoint), then signed in to.
    *h.web.answers.lock().unwrap() = vec![
        challenge.into(),
        challenge.into(),
        metadata.into(),
        server.into(),
        challenge.into(),
        "{\"authorization_servers\":[\"https://amie.example\"]}\n200|".into(),
        "{\"authorization_endpoint\":\"https://amie.example/authorize\",\"token_endpoint\":\"https://amie.example/token\",\"registration_endpoint\":\"https://amie.example/register\"}\n200|".into(),
        "{\"client_id\":\"zero-1\"}\n201|".into(),
        "{\"access_token\":\"tok-1\",\"refresh_token\":\"ref-1\",\"expires_in\":3600}\n200|".into(),
    ];

    // The task's Claude says its own amie needs signing in: Zero keeps it and signs in to it itself, once for every task.
    claude.say(json!({"type": "system", "subtype": "init", "session_id": "de7c0e2b-badd-439a-a46b-9e187476cb40",
                      "mcp_servers": [{"name": "amie", "status": "needs-auth"}]}));
    let mut link = None;
    for _ in 0..300 {
        let asks = client.call(json!({"op": "asks"})).await["result"].clone();
        link =
            asks.as_array().unwrap().iter().find(|a| a["title"] == "Sign in to amie?").and_then(|a| a["link"].as_str().map(String::from));
        if link.is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let link = link.expect("a sign-in ask with its link");
    assert!(link.starts_with("https://amie.example/authorize?") && link.contains("client_id=zero-1"), "Zero's sign-in: {link}");
    let kept = h.daemon.mcp_servers.list();
    assert!(
        kept.iter().any(|s| s.id == "amie" && s.url.as_deref() == Some("https://amie.example/mcp") && s.workspaces.is_empty()),
        "{kept:?}"
    );
    assert!(!claude.methods().iter().any(|m| m == "control_request:mcp_set_servers"), "not given before it's signed in to");

    let query = |key: &str| link.split(&format!("{key}=")).nth(1).unwrap().split('&').next().unwrap().to_string();
    let redirect = query("redirect_uri").replace("%3A", ":").replace("%2F", "/");
    let port: u16 = redirect.trim_start_matches("http://127.0.0.1:").trim_end_matches("/callback").parse().unwrap();
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    stream.write_all(format!("GET /callback?code=c0de&state={} HTTP/1.1\r\n\r\n", query("state")).as_bytes()).await.unwrap();
    let mut page = String::new();
    tokio::io::AsyncReadExt::read_to_string(&mut stream, &mut page).await.unwrap();

    // Signed in: Zero's amie, its token the header, takes the place of the task's own.
    let set = claude.said("control_request:mcp_set_servers", 1).await;
    assert_eq!(set[0]["request"]["servers"]["amie"]["headers"]["Authorization"], "Bearer tok-1", "{}", set[0]);

    // A task that says it needs signing in again while Zero has its token (one started without it, as a zerod
    // starting does) is given it: Zero doesn't sign in again. (`mcp_changed` forgets the sign-in ended, as a restart.)
    h.daemon.mcp_changed("amie");
    let again = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "ls"})).await;
    let again = again["result"]["session"].as_str().unwrap().to_string();
    until(&h.daemon.session(&again).unwrap(), |c| c.status == Status::Idle).await;
    let asked = h.web.asked.lock().unwrap().len();
    let second = h.seen.lock().unwrap()[1].clone();
    second.say(json!({"type": "system", "subtype": "init", "session_id": "de7c0e2b-badd-439a-a46b-9e187476cb40",
                      "mcp_servers": [{"name": "amie", "status": "needs-auth"}]}));
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let asks = client.call(json!({"op": "asks"})).await["result"].clone();
    let open = asks.as_array().unwrap().iter().filter(|a| a["title"] == "Sign in to amie?" && a["state"] == "waiting").count();
    assert_eq!(open, 0, "no sign-in asked again: {asks}");
    assert_eq!(h.web.asked.lock().unwrap().len(), asked, "nothing asked of amie");
}

#[tokio::test]
async fn a_server_zero_keeps_for_one_workspace_is_widened_to_a_task_elsewhere_whose_claude_has_it_at_that_url() {
    let h = harness("server-mcp-widen").await;
    zerod::mcp_auth::start(h.daemon.clone(), h.inbox.clone());
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Personal", "glyph": "", "folders": []}})).await;
    let url = "https://mcp.linear.example/mcp";
    let header = json!([{"name": "Authorization", "value": "Bearer kept", "from": "file"}]);
    client
        .call(
            json!({"op": "saveMcpServer", "server": {"name": "linear-server", "url": url, "headers": header, "workspaces": ["personal"]}}),
        )
        .await;
    let started = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    until(&h.daemon.session(&session).unwrap(), |c| c.status == Status::Idle).await;
    let claude = h.seen.lock().unwrap()[0].clone();
    assert!(!claude.methods().iter().any(|m| m == "control_request:mcp_set_servers"), "not this workspace's yet");
    claude.answer("mcp_status", json!({"mcpServers": [{"name": "linear-server", "status": "needs-auth", "scope": "local", "config": {"type": "http", "url": url}}]}));

    claude.say(json!({"type": "system", "subtype": "init", "session_id": "de7c0e2b-badd-439a-a46b-9e187476cb40",
                      "mcp_servers": [{"name": "linear-server", "status": "needs-auth"}]}));
    let set = claude.said("control_request:mcp_set_servers", 1).await;
    assert_eq!(set[0]["request"]["servers"]["linear-server"]["url"], url, "{}", set[0]);
    let kept = h.daemon.mcp_servers.list();
    assert_eq!(kept.len(), 1, "{kept:?}");
    assert_eq!(kept[0].workspaces.len(), 2, "Personal and this task's: {kept:?}");
}

#[tokio::test]
async fn a_local_server_changed_on_disk_or_reloaded_starts_again_in_the_running_tasks() {
    let h = harness("server-mcp-reload").await;
    let mut client = Client::connect(&h.socket).await;
    let program = h.home.join("tool-mcp");
    std::fs::write(&program, "#!/bin/sh\n").unwrap();
    client.call(json!({"op": "saveMcpServer", "server": {"name": "Tool", "command": program, "args": ["serve"]}})).await;
    let started = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    until(&h.daemon.session(&session).unwrap(), |c| c.status == Status::Idle).await;
    let claude = h.seen.lock().unwrap()[0].clone();
    let stamp =
        |set: &Value| set["request"]["servers"]["tool"]["env"]["ZERO_MCP_STAMP"].as_str().unwrap_or_else(|| panic!("{set}")).to_string();

    // Nothing changed: a message goes as it is.
    client.call(json!({"op": "send", "session": session, "text": "again"})).await;
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert!(!claude.methods().iter().any(|m| m == "control_request:mcp_set_servers"));

    // A new build of it: the next message finds it, and the server starts again (its config changed) before it.
    std::fs::write(&program, "#!/bin/sh\n# a new build\n").unwrap();
    client.call(json!({"op": "send", "session": session, "text": "and now?"})).await;
    let first = stamp(&claude.said("control_request:mcp_set_servers", 1).await[0]);
    let methods = claude.methods();
    let set_at = methods.iter().position(|m| m == "control_request:mcp_set_servers").unwrap();
    assert!(methods[set_at..].iter().any(|m| m == "user"), "before the message: {methods:?}");

    // Reload in Settings: started again, whatever its files say.
    let reloaded = client.call(json!({"op": "reloadMcpServer", "server": "tool"})).await;
    assert_eq!(reloaded["ok"], true, "{reloaded}");
    let second = stamp(&claude.said("control_request:mcp_set_servers", 2).await[1]);
    assert_ne!(first, second);
}

#[tokio::test]
async fn an_agent_says_which_workspaces_a_server_is_for_and_an_edit_keeps_them_unless_it_says() {
    let h = harness("server-mcp-scope").await;
    let mut client = Client::connect(&h.socket).await;
    client.call(json!({"op": "configure", "takeBack": 0.02, "ttl": 600})).await;
    client.call(json!({"op": "saveWorkspace", "workspace": {"id": "", "name": "Elsewhere", "glyph": "", "folders": []}})).await;
    let started = client.call(json!({"op": "start", "provider": "claude", "cwd": h.project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    until(&h.daemon.session(&session).unwrap(), |c| c.status == Status::Idle).await;
    let approve = async |client: &mut Client, args: Value| {
        let asked = client.call(json!({"op": "agentAsk", "session": session, "args": args})).await;
        let id = asked["result"]["id"].as_str().unwrap_or_else(|| panic!("{asked}")).to_string();
        let card = find_ask(client, &id).await;
        client.call(json!({"op": "choose", "ask": id, "option": 0})).await;
        for _ in 0..200 {
            if find_ask(client, &id).await["state"] == "answered" {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        let kept = client.call(json!({"op": "mcpServers"})).await["result"][0]["workspaces"].clone();
        (card["body"].as_str().unwrap().to_string(), kept)
    };

    let unknown = client
        .call(json!({"op": "agentAsk", "session": session, "args": {"tool": "mcp", "name": "Docs", "command": "docs", "why": "docs", "workspaces": "nowhere"}}))
        .await;
    assert!(unknown["error"].as_str().unwrap_or_default().contains("elsewhere"), "says which there are: {unknown}");

    let (body, kept) =
        approve(&mut client, json!({"tool": "mcp", "name": "Docs", "command": "docs", "why": "docs", "workspaces": "all"})).await;
    assert!(body.contains("for every workspace"), "{body}");
    assert_eq!(kept, json!([]));

    let (body, kept) = approve(&mut client, json!({"tool": "mcp", "name": "docs", "command": "docs2", "why": "a fix"})).await;
    assert!(body.contains("Now: `docs2`, for every workspace"), "kept: {body}");
    assert_eq!(kept, json!([]));

    let (body, kept) =
        approve(&mut client, json!({"tool": "mcp", "name": "docs", "command": "docs2", "why": "only there", "workspaces": "Elsewhere"}))
            .await;
    assert!(body.contains("for Elsewhere") && body.contains("Was: `docs2`, for every workspace"), "{body}");
    assert_eq!(kept, json!(["elsewhere"]));
}
