//! Zero for Chrome: the extension reaches zerod through its native host (`zerod chrome-extension://…`, browser::host),
//! which relays Chrome's framing (a 4-byte length, then JSON) to zerod's socket. A task's browser tools go to the
//! extension as calls, with the task they're for; the extension answers each by its id.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::temp_dir;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, DuplexStream};
use zerod::daemon::Daemon;

async fn frame(to: &mut DuplexStream, message: Value) {
    let data = message.to_string().into_bytes();
    to.write_all(&(data.len() as u32).to_le_bytes()).await.unwrap();
    to.write_all(&data).await.unwrap();
}

async fn unframe(from: &mut DuplexStream) -> Value {
    let mut length = [0u8; 4];
    tokio::time::timeout(Duration::from_secs(5), from.read_exact(&mut length)).await.expect("a message from the host").unwrap();
    let mut data = vec![0u8; u32::from_le_bytes(length) as usize];
    from.read_exact(&mut data).await.unwrap();
    serde_json::from_slice(&data).unwrap()
}

struct Client { lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>, write: tokio::net::unix::OwnedWriteHalf }

impl Client {
    async fn connect(socket: &std::path::Path) -> Client {
        let (read, write) = tokio::net::UnixStream::connect(socket).await.unwrap().into_split();
        Client { lines: BufReader::new(read).lines(), write }
    }
    async fn call(&mut self, request: Value) -> Value {
        self.write.write_all(format!("{request}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(5), self.lines.next_line()).await.expect("an answer").unwrap().unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == request["id"] { return reply }
        }
    }
}

async fn zerod(name: &str) -> (std::path::PathBuf, std::path::PathBuf) {
    let home = temp_dir(name);
    let socket = home.join("zerod.sock");
    let runtime: zerod::daemon::Runtime = Arc::new(|_, _, _| Err(std::io::Error::other("no runtime here")));
    let daemon = Daemon::open(&home, runtime).unwrap();
    let integrations = zerod::integrations::Integrations::open(&home, Arc::new(zerod::integrations::Commands::default()));
    tokio::spawn(zerod::server::serve(zerod::server::Zerod {
        daemon, inbox: zerod::inbox::Inbox::open(None, vec![]), drops: None, integrations: integrations.clone(),
        following: zerod::following::Following::open(&home, Arc::new(zerod::integrations::Commands::default()), integrations),
        pads: Arc::new(zerod::pads::Pads::open(&home.join("scratchpads"))), loops: Arc::new(zerod::loops::Loops::open(&home.join("loops"))),
        browsers: zerod::browser::Browsers::open(&home), places: Default::default(), notices: tokio::sync::broadcast::channel(64).0,
    }, socket.clone()));
    for _ in 0..50 { if socket.exists() { break } tokio::time::sleep(Duration::from_millis(10)).await }
    (home, socket)
}

#[tokio::test]
async fn a_tasks_call_reaches_the_extension_and_its_answer_comes_back() {
    let (home, socket) = zerod("browser-calls").await;
    std::fs::write(home.join("browser.json"), json!({"blocked": ["*.bank.example"]}).to_string()).unwrap();
    let (mut extension, host_side) = tokio::io::duplex(1 << 20);
    let (host_in, host_out) = tokio::io::split(host_side);
    let host = tokio::spawn(zerod::browser::host(host_in, host_out, socket.clone()));
    frame(&mut extension, json!({"type": "hello", "name": "Chrome", "version": "0.1"})).await;

    let mut client = Client::connect(&socket).await;
    // Connected, the browser is listed.
    for _ in 0..50 {
        let listed = client.call(json!({"id": "l", "op": "browsers"})).await;
        if listed["result"].as_array().is_some_and(|b| !b.is_empty()) { assert_eq!(listed["result"][0]["name"], "Chrome"); break }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let asked = tokio::spawn(async move {
        let reply = client.call(json!({"id": 1, "op": "browserCall", "tool": "browser_navigate", "args": {"url": "example.com"}})).await;
        (client, reply)
    });
    let call = unframe(&mut extension).await;
    assert_eq!((call["type"].as_str(), call["tool"].as_str(), call["args"]["url"].as_str()), (Some("call"), Some("browser_navigate"), Some("example.com")));
    assert_eq!(call["task"]["blocked"], json!(["*.bank.example"]), "the user's blocked sites go with every call");
    assert_eq!(call["task"]["group"], "zero", "outside a task, Zero's own group");
    frame(&mut extension, json!({"type": "answer", "call": call["call"], "result": {"content": [{"type": "text", "text": "Navigated"}]}})).await;
    let (mut client, reply) = asked.await.unwrap();
    assert_eq!(reply["result"]["content"][0]["text"], "Navigated");

    // A refusal comes back as an error.
    let asked = tokio::spawn(async move { let r = client.call(json!({"id": 2, "op": "browserCall", "tool": "browser_read", "args": {"tabId": 9}})).await; (client, r) });
    let call = unframe(&mut extension).await;
    frame(&mut extension, json!({"type": "answer", "call": call["call"], "error": "Tab 9 isn't this task's"})).await;
    let (mut client, reply) = asked.await.unwrap();
    assert_eq!((reply["ok"].as_bool(), reply["error"].as_str()), (Some(false), Some("Tab 9 isn't this task's")));

    // The extension asks zerod things too (the board, to give a tab to a task): answered by its id.
    frame(&mut extension, json!({"type": "request", "id": 7, "request": {"op": "hello"}})).await;
    let reply = unframe(&mut extension).await;
    assert_eq!((reply["type"].as_str(), reply["id"].as_i64(), reply["ok"].as_bool()), (Some("reply"), Some(7), Some(true)));

    // Chrome gone: a call waiting is told so, and so is the next.
    let asked = tokio::spawn(async move { let r = client.call(json!({"id": 3, "op": "browserCall", "tool": "browser_tabs", "args": {}})).await; (client, r) });
    let _ = unframe(&mut extension).await;
    drop(extension);
    let _ = tokio::time::timeout(Duration::from_secs(5), host).await;
    let (mut client, reply) = asked.await.unwrap();
    assert_eq!(reply["error"], "Chrome disconnected before answering");
    let reply = client.call(json!({"id": 4, "op": "browserCall", "tool": "browser_tabs", "args": {}})).await;
    assert!(reply["error"].as_str().unwrap().starts_with("Zero for Chrome isn't connected"), "{reply}");
}

#[test]
fn every_tool_is_offered_to_agents_with_claude_in_chromes_inputs() {
    let tools = zerod::browser::tools();
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    for name in ["browser_tabs", "browser_tab_new", "browser_tab_close", "browser_navigate", "browser_computer", "browser_read", "browser_find", "browser_text",
                 "browser_form", "browser_js", "browser_console", "browser_network", "browser_resize", "browser_upload", "browser_record", "browser_dialog", "browser_batch", "browser_list", "browser_select"] {
        assert!(names.contains(&name), "{name} is missing");
    }
    let computer = tools.iter().find(|t| t["name"] == "browser_computer").unwrap();
    assert_eq!(computer["inputSchema"]["required"], json!(["action", "tabId"]));
    assert_eq!(computer["inputSchema"]["properties"]["action"]["enum"].as_array().unwrap().len(), 13);
}

#[test]
fn the_host_manifest_names_zerod_and_only_zeros_extension() {
    let manifest = zerod::browser::host_manifest(std::path::Path::new("/Applications/Zero.app/Contents/MacOS/zerod"));
    assert_eq!(manifest["name"], zerod::browser::HOST);
    assert_eq!(manifest["path"], "/Applications/Zero.app/Contents/MacOS/zerod");
    assert_eq!(manifest["type"], "stdio");
    assert_eq!(manifest["allowed_origins"], json!([format!("chrome-extension://{}/", zerod::browser::EXTENSION)]));
}

#[test]
fn in_auto_mode_a_new_site_gets_a_reviewers_opinion_first() {
    use zerod::browser::{review_command, verdict, site};
    use zerod::model::Provider;
    // The task's own CLI, run once, on a small model where there's one to pick.
    let claude = review_command(Provider::Claude, "Is it fine?");
    assert!(claude.starts_with("claude -p --model haiku ") && claude.ends_with("'Is it fine?'"), "{claude}");
    assert!(review_command(Provider::Codex, "it's").starts_with("codex exec --skip-git-repo-check "));
    assert!(review_command(Provider::Codex, "it's").ends_with("'it'\\''s'"), "quoted for the shell");
    assert!(review_command(Provider::Opencode, "x").starts_with("opencode run "));
    // Its verdict is its last ALLOW or DENY line.
    assert_eq!(verdict("Thinking…\nALLOW: the task's own docs"), Ok("the task's own docs".to_string()));
    assert_eq!(verdict("DENY: a bank, nothing to do with the task\n"), Err("a bank, nothing to do with the task".to_string()));
    assert_eq!(verdict("I can't tell"), Err("the reviewer gave no verdict".to_string()));
    assert_eq!(site("https://docs.Example.com/a?b"), Some("docs.example.com".to_string()));
    assert_eq!(site("example.com/path"), Some("example.com".to_string()));
    assert_eq!(site("back"), None);
    // Once allowed, a site is the task's for good; other tasks are asked afresh.
    let browsers = zerod::browser::Browsers::open(&temp_dir("browser-review"));
    assert!(!browsers.allowed("s1", "example.com"));
    browsers.allow("s1", "example.com");
    assert!(browsers.allowed("s1", "example.com") && !browsers.allowed("s2", "example.com"));
}

#[test]
fn screenshots_and_recordings_to_keep_are_saved_as_files_and_their_paths_given() {
    let home = temp_dir("browser-media");
    let browsers = zerod::browser::Browsers::open(&home);
    let jpeg = zerod::images::base64(b"\xff\xd8\xff jpeg");
    // A screenshot asked to be kept: the image stays for the agent, its file's path is added.
    let answer = json!({"content": [{"type": "text", "text": "Screenshot"}, {"type": "image", "data": jpeg, "mimeType": "image/jpeg"}], "keep": [{"data": jpeg, "extension": "jpg"}]});
    let kept = browsers.keep_media(answer, "s1");
    assert_eq!(kept["content"].as_array().unwrap().len(), 3);
    assert!(kept.get("keep").is_none());
    let path = kept["content"][2]["text"].as_str().unwrap().strip_prefix("Saved to ").unwrap().to_string();
    assert!(path.starts_with(home.join("media").to_str().unwrap()) && path.ends_with(".jpg"), "{path}");
    assert_eq!(std::fs::read(&path).unwrap(), b"\xff\xd8\xff jpeg");
    // A recording: only the file, never its bytes, goes to the agent.
    let video = json!({"content": [{"type": "text", "text": "Recorded 12 s"}], "keep": [{"data": zerod::images::base64(b"mp4"), "extension": "mp4"}]});
    let kept = browsers.keep_media(video, "s1");
    assert!(kept["content"][1]["text"].as_str().unwrap().ends_with(".mp4"));
}

#[test]
fn a_tasks_state_is_a_light_for_its_tab_group() {
    use zerod::browser::light;
    use zerod::model::Attention::*;
    for (attention, expected) in [(Starting, "working"), (Working, "working"), (NeedsYou, "blocked"), (Stuck, "blocked"), (Failed, "blocked"), (Limited, "blocked"),
                                  (Done, "done"), (Answered, "done"), (Idle, "done"), (Offline, "done")] {
        assert_eq!(light(attention), expected, "{attention:?}");
    }
}

#[tokio::test]
async fn chrome_hears_when_a_tasks_state_changes() {
    let (_, socket) = zerod("browser-states").await;
    let (mut extension, host_side) = tokio::io::duplex(1 << 20);
    let (host_in, host_out) = tokio::io::split(host_side);
    tokio::spawn(zerod::browser::host(host_in, host_out, socket.clone()));
    frame(&mut extension, json!({"type": "hello", "name": "Chrome"})).await;
    let mut client = Client::connect(&socket).await;
    for _ in 0..50 {
        if client.call(json!({"id": "l", "op": "browsers"})).await["result"].as_array().is_some_and(|b| !b.is_empty()) { break }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // What zerod's follower says when a session's light changes, as it would.
    let reply = client.call(json!({"id": 1, "op": "browserState", "session": "s1", "browser": {"state": "blocked"}})).await;
    assert_eq!(reply["ok"], true, "{reply}");
    let told = unframe(&mut extension).await;
    assert_eq!((told["type"].as_str(), told["session"].as_str(), told["state"].as_str()), (Some("state"), Some("s1"), Some("blocked")));
}
