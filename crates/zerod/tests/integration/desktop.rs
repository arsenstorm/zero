//! The desktop tools: an agent's desktop_ call goes through zerod to Zero.app, which holds the Mac's Accessibility and
//! Screen Recording permissions and does it. zerod decides first whether the task may: each app needs the user's yes on
//! a card (for the task, or once), and some apps only ever allow so much (their tier). Here a stand-in client plays
//! Zero.app: it attaches as the desktop, finds the app a call names (`resolve`), and answers the call.

use std::sync::Arc;
use std::time::Duration;

use crate::common::{Seen, fixture, play, temp_dir};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use zerod::daemon::Daemon;

struct Client {
    lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    write: tokio::net::unix::OwnedWriteHalf,
}

impl Client {
    async fn connect(socket: &std::path::Path) -> Client {
        let (read, write) = tokio::net::UnixStream::connect(socket).await.unwrap().into_split();
        Client { lines: BufReader::new(read).lines(), write }
    }
    async fn send(&mut self, request: Value) {
        self.write.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    }
    async fn next(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(5), self.lines.next_line()).await.expect("a message").unwrap().unwrap();
        serde_json::from_str(&line).unwrap()
    }
    async fn call(&mut self, request: Value) -> Value {
        self.send(request.clone()).await;
        loop {
            let reply = self.next().await;
            if reply["id"] == request["id"] {
                return reply;
            }
        }
    }
    /// The next desktop call zerod pushes to the app.
    async fn pushed(&mut self) -> Value {
        loop {
            let message = self.next().await;
            if !message["desktop"].is_null() {
                return message["desktop"].clone();
            }
        }
    }
    async fn answer(&mut self, call: &Value, result: Value) {
        self.send(json!({"op": "desktopAnswer", "args": {"call": call["call"], "result": result}})).await
    }
    /// Answers a `resolve` with the app it found.
    async fn resolves(&mut self, bundle: &str, name: &str) {
        self.resolves_as(bundle, name, 42).await
    }

    /// The app found as process `pid`: a relaunch is the same app under a new one.
    async fn resolves_as(&mut self, bundle: &str, name: &str, pid: u32) {
        let call = self.pushed().await;
        assert_eq!(call["tool"], "resolve", "{call}");
        self.answer(&call, json!({"bundle": bundle, "name": name, "pid": pid})).await
    }
}

struct Zerod {
    socket: std::path::PathBuf,
    session: String,
    /// What the task's runtimes were sent.
    seen: Arc<std::sync::Mutex<Vec<Seen>>>,
}

async fn zerod(name: &str, app: bool) -> Zerod {
    let home = temp_dir(name);
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let socket = home.join("zerod.sock");
    let seen = Arc::new(std::sync::Mutex::new(vec![]));
    let recorded = seen.clone();
    let runtime: zerod::daemon::Runtime = Arc::new(move |_, _, _| {
        let (transport, seen) = play(fixture("claude-command"));
        recorded.lock().unwrap().push(seen);
        Ok(transport)
    });
    let daemon = Daemon::open(&home, runtime).unwrap();
    let inbox = zerod::inbox::Inbox::open(None, vec![]);
    // Answers commit at once: the take-back window is the app's to show, not these tests' to wait out.
    inbox.configure(Duration::ZERO, 3600);
    let integrations = zerod::integrations::Integrations::open(&home, Arc::new(zerod::integrations::Commands::default()));
    // A call waits a second on its card here (45 in zerod): long enough for these tests to answer, short to time out.
    let desktop = Arc::new(zerod::desktop::Desktop::default());
    desktop.set_card_wait(Duration::from_secs(1));
    tokio::spawn(zerod::server::serve(
        zerod::server::Zerod {
            daemon,
            inbox,
            integrations: integrations.clone(),
            following: zerod::following::Following::open(&home, Arc::new(zerod::integrations::Commands::default()), integrations),
            pads: Arc::new(zerod::pads::Pads::open(&home.join("scratchpads"))),
            later: Arc::new(zerod::later::Later::open(&home.join("later"))),
            loops: Arc::new(zerod::loops::Loops::open(&home.join("loops"))),
            browsers: zerod::browser::Browsers::open(&home),
            desktop,
            places: Default::default(),
            notices: tokio::sync::broadcast::channel(64).0,
            peers: Arc::new(move |_| app),
        },
        socket.clone(),
    ));
    for _ in 0..100 {
        if tokio::net::UnixStream::connect(&socket).await.is_ok() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await
    }
    let mut control = Client::connect(&socket).await;
    let started = control.call(json!({"id": "s", "op": "start", "provider": "claude", "cwd": project, "prompt": "ls"})).await;
    let session = started["result"]["session"].as_str().unwrap().to_string();
    // Its first turn over: idle, so what Zero tells it goes at once.
    for _ in 0..500 {
        let first = seen.lock().unwrap().first().cloned();
        if let Some(first) = first {
            first.said("user", 1).await;
            first.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"}));
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    for _ in 0..500 {
        if control.call(json!({"id": "g", "op": "get", "session": session})).await["result"]["status"] == "idle" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    Zerod { socket, session, seen }
}

/// The agent's call, made on a connection of its own, its reply awaited later.
fn desktop(z: &Zerod, tool: &str, args: Value) -> tokio::task::JoinHandle<Value> {
    let (socket, session, tool) = (z.socket.clone(), z.session.clone(), tool.to_string());
    tokio::spawn(async move {
        let mut agent = Client::connect(&socket).await;
        agent.call(json!({"id": 1, "op": "desktopCall", "session": session, "tool": tool, "args": args})).await
    })
}

async fn reply(call: tokio::task::JoinHandle<Value>) -> Value {
    tokio::time::timeout(Duration::from_secs(5), call).await.expect("a reply").unwrap()
}

/// The open ask, once there is one: waited for, as zerod makes it while the call waits.
async fn card(control: &mut Client) -> Value {
    for _ in 0..100 {
        let asks = control.call(json!({"id": "a", "op": "asks"})).await["result"].as_array().cloned().unwrap_or_default();
        if let Some(open) = asks.into_iter().find(|a| a["state"] == "waiting") {
            return open;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("no card")
}

async fn open_asks(control: &mut Client) -> usize {
    let asks = control.call(json!({"id": "a", "op": "asks"})).await["result"].as_array().cloned().unwrap_or_default();
    asks.iter().filter(|a| a["state"] == "waiting").count()
}

async fn choose(control: &mut Client, card: &Value, option: &str) {
    let index = card["options"].as_array().unwrap().iter().position(|o| o == option).unwrap_or_else(|| panic!("no {option} in {card}"));
    control.call(json!({"id": "c", "op": "choose", "ask": card["id"], "option": index})).await;
}

/// The open card answered with `option`.
async fn pick(control: &mut Client, option: &str) {
    let open = card(control).await;
    choose(control, &open, option).await
}

async fn attached(socket: &std::path::Path) -> Client {
    let mut app = Client::connect(socket).await;
    assert_eq!(app.call(json!({"id": "att", "op": "desktopAttach"})).await["ok"], true);
    app
}

#[tokio::test]
async fn a_call_reaches_zero_app_once_the_user_allows_the_app_for_the_task() {
    let z = zerod("desktop-allow", true).await;
    let mut control = Client::connect(&z.socket).await;

    let none = reply(desktop(&z, "desktop_apps", json!({}))).await;
    assert!(none["error"].as_str().unwrap().contains("Zero.app isn't open"), "{none}");

    let mut app = attached(&z.socket).await;
    let call = desktop(&z, "desktop_click", json!({"app": "Notes", "ref": "e3"}));
    app.resolves("com.apple.Notes", "Notes").await;
    let asked = card(&mut control).await;
    assert_eq!(asked["kind"], "permission");
    assert!(asked["title"].as_str().unwrap().ends_with("use Notes?"), "{asked}");
    assert_eq!(asked["options"], json!(["Allow for this task", "Allow once", "Deny"]));
    choose(&mut control, &asked, "Allow for this task").await;
    let pushed = app.pushed().await;
    assert_eq!((pushed["tool"].as_str(), pushed["args"]["ref"].as_str()), (Some("desktop_click"), Some("e3")));
    assert_eq!((pushed["args"]["bundle"].as_str(), pushed["args"]["pid"].as_i64()), (Some("com.apple.Notes"), Some(42)));
    assert_eq!(pushed["task"]["session"], z.session.as_str(), "the app shows which task drives");
    app.answer(&pushed, json!({"content": [{"type": "text", "text": "Pressed"}]})).await;
    assert_eq!(reply(call).await["result"]["content"][0]["text"], "Pressed");

    // Allowed for the task: the next call goes straight through.
    let call = desktop(&z, "desktop_type", json!({"app": "Notes", "text": "hi"}));
    app.resolves("com.apple.Notes", "Notes").await;
    let pushed = app.pushed().await;
    assert_eq!(pushed["tool"], "desktop_type");
    assert_eq!(open_asks(&mut control).await, 0);
    app.send(json!({"op": "desktopAnswer", "args": {"call": pushed["call"], "error": "No text field focused"}})).await;
    assert_eq!(reply(call).await["error"], "No text field focused", "the app's refusal comes back as an error");

    // Listing apps asks nothing; the app is told which are allowed, to show their windows' titles only.
    let call = desktop(&z, "desktop_apps", json!({}));
    let pushed = app.pushed().await;
    assert_eq!((pushed["tool"].as_str(), pushed["args"]["approved"].clone()), (Some("desktop_apps"), json!(["com.apple.Notes"])));
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);

    // Zero.app gone mid-call: the call is told.
    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves("com.apple.Notes", "Notes").await;
    let _ = app.pushed().await;
    drop(app);
    assert!(reply(call).await["error"].as_str().unwrap().contains("Zero.app closed"));
}

#[tokio::test]
async fn once_allows_one_call_and_deny_refuses() {
    let z = zerod("desktop-once", true).await;
    let mut control = Client::connect(&z.socket).await;
    let mut app = attached(&z.socket).await;

    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves("com.apple.Notes", "Notes").await;
    pick(&mut control, "Allow once").await;
    let pushed = app.pushed().await;
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);

    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves("com.apple.Notes", "Notes").await;
    pick(&mut control, "Deny").await;
    let denied = reply(call).await;
    assert!(denied["error"].as_str().unwrap().contains("denied"), "{denied}");
}

#[tokio::test]
async fn each_app_allows_what_its_tier_does() {
    let z = zerod("desktop-tiers", true).await;
    let mut control = Client::connect(&z.socket).await;
    let mut app = attached(&z.socket).await;

    // Off limits: refused, no card.
    let call = desktop(&z, "desktop_read", json!({"app": "Keychain Access"}));
    app.resolves("com.apple.keychainaccess", "Keychain Access").await;
    assert!(reply(call).await["error"].as_str().unwrap().contains("off limits"));
    assert_eq!(open_asks(&mut control).await, 0);

    // A browser acts through the browser_ tools: clicking it is refused, with no card.
    let call = desktop(&z, "desktop_click", json!({"app": "Chrome", "x": 1, "y": 1}));
    app.resolves("com.google.Chrome", "Google Chrome").await;
    assert!(reply(call).await["error"].as_str().unwrap().contains("browser_"));

    // The user's Zero is used in the background only, so the user isn't disturbed: after the card, clicks go as
    // accessibility actions and events to Zero alone (Zero.app keeps them off its cards); the real pointer never.
    let call = desktop(&z, "desktop_click", json!({"app": "Zero", "ref": "e1"}));
    app.resolves("com.arsen.zero", "Zero").await;
    let asked = card(&mut control).await;
    assert!(asked["body"].as_str().unwrap().contains("in the background"), "{asked}");
    choose(&mut control, &asked, "Allow for this task").await;
    let pushed = app.pushed().await;
    assert_eq!(pushed["args"]["background"], true, "Zero.app never falls back to the real pointer");
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);
    let call = desktop(&z, "desktop_drag", json!({"app": "Zero", "from": {"ref": "e1"}, "to": {"ref": "e2"}, "pointer": true}));
    app.resolves("com.arsen.zero", "Zero").await;
    assert!(reply(call).await["error"].as_str().unwrap().contains("real pointer"));

    // A terminal: allowed for the task, it still asks before each typing, showing what.
    let call = desktop(&z, "desktop_read", json!({"app": "Terminal"}));
    app.resolves("com.apple.Terminal", "Terminal").await;
    pick(&mut control, "Allow for this task").await;
    let pushed = app.pushed().await;
    app.answer(&pushed, json!({"content": []})).await;
    reply(call).await;
    for _ in 0..2 {
        let call = desktop(&z, "desktop_type", json!({"app": "Terminal", "text": "make test"}));
        app.resolves("com.apple.Terminal", "Terminal").await;
        let asked = card(&mut control).await;
        assert_eq!((asked["command"].as_str(), asked["options"].clone()), (Some("make test"), json!(["Allow once", "Deny"])));
        choose(&mut control, &asked, "Allow once").await;
        let pushed = app.pushed().await;
        app.answer(&pushed, json!({"content": []})).await;
        assert_eq!(reply(call).await["ok"], true);
    }

    // The whole screen is its own approval, found without asking the app.
    let call = desktop(&z, "desktop_screenshot", json!({"screen": true}));
    let asked = card(&mut control).await;
    assert!(asked["title"].as_str().unwrap().contains("the whole screen"), "{asked}");
    choose(&mut control, &asked, "Allow once").await;
    let pushed = app.pushed().await;
    assert_eq!((pushed["tool"].as_str(), pushed["args"]["bundle"].as_str()), (Some("desktop_screenshot"), Some("screen")));
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);

    // A window named without its app isn't the whole screen: the call says which app, and asks the user nothing.
    let call = desktop(&z, "desktop_screenshot", json!({"window": 7}));
    let refused = reply(call).await;
    assert!(refused["error"].as_str().unwrap().contains("Which app?"), "{refused}");
    assert_eq!(open_asks(&mut control).await, 0);
}

#[tokio::test]
async fn stop_takes_the_desktop_back_from_the_task() {
    let z = zerod("desktop-stop", true).await;
    let mut control = Client::connect(&z.socket).await;
    let mut app = attached(&z.socket).await;
    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves("com.apple.Notes", "Notes").await;
    pick(&mut control, "Allow for this task").await;
    let pushed = app.pushed().await;
    app.answer(&pushed, json!({"content": []})).await;
    reply(call).await;

    assert_eq!(control.call(json!({"id": "x", "op": "desktopStop", "session": z.session})).await["ok"], true);
    assert_eq!(app.pushed().await["stop"], z.session.as_str(), "the app ends what the task has going (a recording)");
    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    assert!(reply(call).await["error"].as_str().unwrap().contains("stopped"));
    // Told once; after that it's a new start, with a card again.
    let _call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves("com.apple.Notes", "Notes").await;
    assert!(card(&mut control).await["title"].as_str().unwrap().contains("Notes"));
}

#[tokio::test]
async fn only_zero_app_is_the_desktop() {
    let z = zerod("desktop-peer", false).await;
    let mut other = Client::connect(&z.socket).await;
    assert_eq!(other.call(json!({"id": 1, "op": "desktopAttach"})).await["ok"], false);
    assert_eq!(other.call(json!({"id": 2, "op": "desktopStop", "session": z.session})).await["ok"], false);
    // Outside a task there's no one to approve for.
    let mut agent = Client::connect(&z.socket).await;
    let outside = agent.call(json!({"id": 3, "op": "desktopCall", "tool": "desktop_apps", "args": {}})).await;
    assert!(outside["error"].as_str().unwrap().contains("Zero's tasks"), "{outside}");
}

#[tokio::test]
async fn agents_get_the_desktop_tools_from_zeros_mcp_server() {
    let list =
        zerod::mcp::respond(&json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}), |_, _| async { Ok(json!({})) }).await.unwrap();
    let names: Vec<&str> = list["result"]["tools"].as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    for tool in ["apps", "read", "click", "type", "key", "scroll"] {
        assert!(names.contains(&format!("desktop_{tool}").as_str()), "no desktop_{tool}");
    }
    let called = zerod::mcp::respond(
        &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "desktop_apps", "arguments": {}}}),
        |tool, _| async move { Ok(json!({"content": [{"type": "text", "text": tool}]})) },
    )
    .await
    .unwrap();
    assert_eq!(called["result"]["content"][0]["text"], "desktop_apps", "a desktop tool's answer is already MCP content");
}

#[tokio::test]
async fn an_agent_cant_widen_what_its_allowed() {
    let z = zerod("desktop-widen", true).await;
    let mut control = Client::connect(&z.socket).await;
    let mut app = attached(&z.socket).await;

    // "The whole screen" is for a picture or a film, never a way past an app's tier.
    let call = desktop(&z, "desktop_click", json!({"app": "Keychain Access", "screen": true, "x": 1, "y": 1}));
    app.resolves("com.apple.keychainaccess", "Keychain Access").await;
    assert!(reply(call).await["error"].as_str().unwrap().contains("off limits"));

    // What zerod sets, the agent can't: which apps are approved, which app and process a call goes to.
    let call = desktop(&z, "desktop_apps", json!({"approved": ["com.apple.keychainaccess"]}));
    let pushed = app.pushed().await;
    assert_eq!(pushed["args"]["approved"], json!([]));
    app.answer(&pushed, json!({"content": []})).await;
    reply(call).await;
    let call = desktop(&z, "desktop_read", json!({"app": "Notes", "pid": 1, "bundle": "com.apple.Notes"}));
    app.resolves("com.apple.Notes", "Notes").await;
    pick(&mut control, "Allow once").await;
    let pushed = app.pushed().await;
    assert_eq!(pushed["args"]["pid"], 42);
    app.answer(&pushed, json!({"content": []})).await;
    reply(call).await;

    // Stopping its own recording asks nothing: Zero.app stops the task's.
    let call = desktop(&z, "desktop_record", json!({"action": "stop"}));
    let pushed = app.pushed().await;
    assert_eq!((pushed["tool"].as_str(), pushed["task"]["session"].as_str()), (Some("desktop_record"), Some(z.session.as_str())));
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);
    assert_eq!(open_asks(&mut control).await, 0);
}

#[tokio::test]
async fn an_allow_given_after_the_call_returned_holds_past_the_turn() {
    let z = zerod("desktop-allow-later", true).await;
    let mut control = Client::connect(&z.socket).await;
    let mut app = attached(&z.socket).await;
    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves("com.apple.Notes", "Notes").await;
    assert!(reply(call).await["error"].as_str().unwrap().contains("Waiting for the user"));
    pick(&mut control, "Allow for this task").await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    control.call(json!({"id": "s", "op": "stop", "session": z.session})).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves("com.apple.Notes", "Notes").await;
    let pushed = app.pushed().await;
    assert_eq!(pushed["tool"], "desktop_read", "allowed for the task when the user said so, whatever the turn did since");
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);
    assert_eq!(open_asks(&mut control).await, 0);
}

#[tokio::test]
async fn a_card_outlives_the_call_and_the_turn() {
    // An agent's tool call can time out (Codex's after 60 s) before the user gets to the card: the call returns, the card
    // stays, and the next call takes its answer.
    let z = zerod("desktop-later", true).await;
    let mut control = Client::connect(&z.socket).await;
    let mut app = attached(&z.socket).await;
    let call = desktop(&z, "desktop_click", json!({"app": "Notes", "ref": "e1"}));
    app.resolves("com.apple.Notes", "Notes").await;
    let waited = reply(call).await;
    assert!(waited["error"].as_str().unwrap().contains("Waiting for the user to allow Notes"), "{waited}");
    pick(&mut control, "Allow once").await;
    let call = desktop(&z, "desktop_click", json!({"app": "Notes", "ref": "e1"}));
    app.resolves("com.apple.Notes", "Notes").await;
    let pushed = app.pushed().await;
    assert_eq!(pushed["tool"], "desktop_click", "the answer given since lets it through");
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);
    assert_eq!(open_asks(&mut control).await, 0);

    // Once is once: the next call asks again. The task's turn ends with it open: it stays, for the user to answer, and
    // the answer wakes the task.
    let call = desktop(&z, "desktop_click", json!({"app": "Notes", "ref": "e1"}));
    app.resolves("com.apple.Notes", "Notes").await;
    card(&mut control).await;
    reply(call).await;
    let ended = control.call(json!({"id": "g", "op": "get", "session": z.session})).await;
    assert_eq!(ended["result"]["status"], "idle", "the fixture's turn is over");
    assert_eq!(open_asks(&mut control).await, 1, "the card outlives the turn");
    pick(&mut control, "Allow once").await;
    for _ in 0..150 {
        let said: Vec<Value> = z.seen.lock().unwrap().iter().flat_map(|s| s.all()).collect();
        if said.iter().any(|m| m.to_string().contains("The user answered the card for Notes")) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the task wasn't told the card was answered");
}

#[tokio::test]
async fn an_app_that_quits_and_opens_again_keeps_its_card_and_its_answer() {
    let z = zerod("desktop-relaunch", true).await;
    let mut control = Client::connect(&z.socket).await;
    let mut app = attached(&z.socket).await;

    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves_as("com.apple.Notes", "Notes", 42).await;
    assert!(reply(call).await["error"].as_str().unwrap().contains("Waiting"));

    // macOS quits Notes (no window, in the background) and it opens again: a new process, the same app and card.
    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves_as("com.apple.Notes", "Notes", 43).await;
    assert_eq!(open_asks(&mut control).await, 1, "one card per app per task");
    pick(&mut control, "Allow for this task").await;
    let pushed = app.pushed().await;
    assert_eq!(pushed["args"]["pid"], 43, "the call goes to the process running now");
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);

    // And again: the answer was for Notes, whatever its process.
    let call = desktop(&z, "desktop_read", json!({"app": "Notes"}));
    app.resolves_as("com.apple.Notes", "Notes", 44).await;
    let pushed = app.pushed().await;
    assert_eq!((pushed["tool"].as_str(), pushed["args"]["pid"].as_u64()), (Some("desktop_read"), Some(44)));
    app.answer(&pushed, json!({"content": []})).await;
    assert_eq!(reply(call).await["ok"], true);
    assert_eq!(open_asks(&mut control).await, 0);
}
