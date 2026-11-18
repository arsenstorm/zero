//! Zero Browser: Chromium in its own app, inside Zero.app, started by zerod when Zero.app first needs it. zerod keeps
//! one end of a socket pair and hands the app the other on its stdin; that end is one more connection to zerod, which
//! the app's tools page uses as Zero for Chrome uses its native host. Here a script stands in for the app.

use std::sync::Arc;
use std::time::Duration;

use crate::common::temp_dir;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

struct Client {
    lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    write: tokio::net::unix::OwnedWriteHalf,
}

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
            if reply["id"] == request["id"] {
                return reply;
            }
        }
    }
}

/// A stand-in for Zero Browser.app: says hello on its socket as the tools page does, answers every call it's sent with
/// "zero browser here", and stays until zerod goes.
fn stand_in(home: &std::path::Path) -> std::path::PathBuf {
    let app = home.join("Zero Browser.app");
    let exe = app.join("Contents/MacOS");
    std::fs::create_dir_all(&exe).unwrap();
    let hello = json!({"id": "a", "op": "browserAttach", "browser": {"type": "hello", "id": "zero-browser", "name": "Zero Browser", "version": "1"}});
    let answer = r#"{"id":"x","op":"browserAnswer","browser":{"type":"answer","call":$1,"result":{"content":[{"type":"text","text":"zero browser here"}]}}}"#;
    let script = format!(
        "#!/bin/sh\necho '{hello}' >&0\nexec perl -e 'open(my $o, \">&=\", 0) or die; $o->autoflush(1); while (<STDIN>) {{ print $o \"{}\\n\" if /browserCall/ && /\"call\":(\\d+)/ }}'\n",
        answer.replace('"', "\\\"")
    );
    std::fs::write(exe.join("Zero Browser"), script).unwrap();
    std::process::Command::new("chmod").args(["+x", &exe.join("Zero Browser").to_string_lossy()]).status().unwrap();
    app
}

async fn zerod(name: &str, peers: zerod::server::Peers) -> (std::path::PathBuf, std::path::PathBuf) {
    let home = temp_dir(name);
    let socket = home.join("zerod.sock");
    let runtime: zerod::daemon::Runtime = Arc::new(|_, _, _| Err(std::io::Error::other("no runtime here")));
    let daemon = zerod::daemon::Daemon::open(&home, runtime).unwrap();
    let integrations = zerod::integrations::Integrations::open(&home, Arc::new(zerod::integrations::Commands::default()));
    let browsers = zerod::browser::Browsers::open(&home);
    browsers.set_zero_browser(zerod::zero_browser::ZeroBrowser::new(stand_in(&home), home.join("zero-browser.log"), false));
    tokio::spawn(zerod::server::serve(
        zerod::server::Zerod {
            daemon,
            inbox: zerod::inbox::Inbox::open(None, vec![]),
            integrations: integrations.clone(),
            following: zerod::following::Following::open(&home, Arc::new(zerod::integrations::Commands::default()), integrations),
            pads: Arc::new(zerod::pads::Pads::open(&home.join("scratchpads"))),
            later: Arc::new(zerod::later::Later::open(&home.join("later"))),
            loops: Arc::new(zerod::loops::Loops::open(&home.join("loops"))),
            browsers,
            desktop: Default::default(),
            places: Default::default(),
            notices: tokio::sync::broadcast::channel(64).0,
            peers,
        },
        socket.clone(),
    ));
    for _ in 0..50 {
        if socket.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await
    }
    (home, socket)
}

async fn listed(client: &mut Client) -> Vec<String> {
    let mut names = vec![];
    for _ in 0..100 {
        let reply = client.call(json!({"id": "l", "op": "browsers"})).await;
        names = reply["result"].as_array().into_iter().flatten().filter_map(|b| b["name"].as_str().map(String::from)).collect();
        if !names.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    names
}

#[tokio::test]
async fn zerod_starts_zero_browser_once_and_its_socket_is_a_browser_connection() {
    let (_home, socket) = zerod("zero-browser", Arc::new(|_| true)).await;
    let mut client = Client::connect(&socket).await;

    let started = client.call(json!({"id": 1, "op": "zeroBrowser"})).await;
    let pid = started["result"]["pid"].as_i64().expect("its pid");
    assert!(pid > 0, "{started}");
    let again = client.call(json!({"id": 2, "op": "zeroBrowser"})).await;
    assert_eq!(again["result"]["pid"].as_i64(), Some(pid), "one Zero Browser, however often it's asked for");
    assert_eq!(listed(&mut client).await, vec!["Zero Browser"], "its tools page is one more connected browser");

    // Gone (crashed, killed): the next ask starts it again, and it's listed again once it says hello.
    std::process::Command::new("kill").args(["-9", &pid.to_string()]).status().unwrap();
    let mut restarted = None;
    for _ in 0..100 {
        let reply = client.call(json!({"id": 3, "op": "zeroBrowser"})).await;
        if let Some(new) = reply["result"]["pid"].as_i64().filter(|&p| p != pid) {
            restarted = Some(new);
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(restarted.is_some(), "started again after it died");
    assert_eq!(listed(&mut client).await, vec!["Zero Browser"]);
}

#[tokio::test]
async fn only_zero_app_starts_zero_browser() {
    let (_home, socket) = zerod("zero-browser-peers", Arc::new(|_| false)).await;
    let mut client = Client::connect(&socket).await;
    let refused = client.call(json!({"id": 1, "op": "zeroBrowser"})).await;
    assert_eq!(refused["ok"], false, "{refused}");
}

#[tokio::test]
async fn agents_use_zero_browser_when_they_pick_it_and_chrome_otherwise() {
    let (_home, socket) = zerod("zero-browser-select", Arc::new(|_| true)).await;
    let mut client = Client::connect(&socket).await;

    // Not started yet: picking it starts it.
    let picked =
        client.call(json!({"id": 1, "op": "browserCall", "session": "s1", "tool": "browser_select", "args": {"browser": "zero"}})).await;
    assert_eq!(picked["ok"], true, "{picked}");
    let answered = client.call(json!({"id": 2, "op": "browserCall", "session": "s1", "tool": "browser_tabs", "args": {}})).await;
    assert_eq!(answered["result"]["content"][0]["text"], "zero browser here", "{answered}");

    // Another task, which picked nothing, doesn't get it: Chrome is the default, and none is connected here.
    let other = client.call(json!({"id": 3, "op": "browserCall", "session": "s2", "tool": "browser_tabs", "args": {}})).await;
    assert_eq!(other["ok"], false, "{other}");
}
