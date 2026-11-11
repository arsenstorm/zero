//! MCP servers that start when first used: `zerod mcp lazy <command> <args…>` stands in for the server in a CLI's
//! config, answering the handshake and the lists from what the server said the last time it ran, and starts it on the
//! first call, passing everything through from then on. A server running in every task (≈140 MB of Node each) that
//! most tasks never call costs a 2 MB stand-in instead.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use crate::common::temp_dir;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout};

/// A server that notes each start (its pid, a line in `starts`) and lists the tools named in `tools`, one per line.
const SERVER: &str = r#"
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, "starts"), "a").write(f"{os.getpid()}\n")
tools = [t for t in open(os.path.join(here, "tools")).read().split() if t]
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    method, result = m.get("method"), None
    if method == "initialize":
        result = {"protocolVersion": m["params"]["protocolVersion"], "capabilities": {"tools": {"listChanged": True}},
                  "serverInfo": {"name": "fake", "version": "1.0"}}
    elif method == "tools/list":
        result = {"tools": [{"name": t, "inputSchema": {"type": "object"}} for t in tools]}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": "called " + m["params"]["name"]}]}
    if result is None:
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "no " + str(method)}}), flush=True)
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": result}), flush=True)
"#;

fn server(name: &str, tools: &str) -> PathBuf {
    let dir = temp_dir(name);
    std::fs::write(dir.join("server.py"), SERVER).unwrap();
    std::fs::write(dir.join("tools"), tools).unwrap();
    dir
}

fn starts(dir: &Path) -> Vec<i32> {
    std::fs::read_to_string(dir.join("starts")).unwrap_or_default().lines().filter_map(|l| l.parse().ok()).collect()
}

/// The CLI's side: the stand-in started as the CLI starts a server from its config.
struct Client {
    child: Child,
    input: ChildStdin,
    output: Lines<BufReader<ChildStdout>>,
    next: u64,
    /// Notifications that came while waiting for an answer.
    told: Vec<Value>,
}

impl Client {
    fn start(dir: &Path) -> Client {
        let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_zerod"))
            .args(["mcp", "lazy", "/usr/bin/python3", dir.join("server.py").to_str().unwrap()])
            .env("HOME", dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let (input, output) = (child.stdin.take().unwrap(), child.stdout.take().unwrap());
        Client { child, input, output: BufReader::new(output).lines(), next: 0, told: vec![] }
    }

    async fn send(&mut self, message: Value) {
        self.input.write_all(format!("{message}\n").as_bytes()).await.unwrap();
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})).await;
        loop {
            let line = tokio::time::timeout(Duration::from_secs(10), self.output.next_line()).await.expect("an answer").unwrap().unwrap();
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == json!(id) {
                return message;
            }
            assert!(message.get("id").is_none(), "only its own answer, or notifications: {message}");
            self.told.push(message);
        }
    }

    /// What Claude does as it starts: the handshake, then the tools.
    async fn handshake(&mut self) -> Vec<String> {
        let init = self.call("initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}})).await;
        assert_eq!(init["result"]["serverInfo"]["name"], "fake", "{init}");
        self.send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await;
        names(&self.call("tools/list", json!({})).await)
    }

    async fn close(mut self) {
        drop(self.input);
        tokio::time::timeout(Duration::from_secs(10), self.child.wait()).await.expect("it ends with its input").unwrap();
    }
}

fn names(list: &Value) -> Vec<String> {
    list["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap().to_string()).collect()
}

fn alive(pid: i32) -> bool {
    unsafe extern "C" {
        safe fn kill(pid: i32, signal: i32) -> i32;
    }
    kill(pid, 0) == 0
}

#[tokio::test]
async fn a_lazy_server_runs_once_to_be_learnt_then_is_stood_in_for_until_its_first_call() {
    let dir = server("mcp-lazy", "search\nget");
    // Never seen: it runs, and what it says is kept.
    let mut first = Client::start(&dir);
    assert_eq!(first.handshake().await, ["search", "get"]);
    assert_eq!(starts(&dir).len(), 1);
    first.close().await;

    // Seen: the handshake and its tools from what was kept, nothing started.
    let mut second = Client::start(&dir);
    assert_eq!(second.handshake().await, ["search", "get"]);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(starts(&dir).len(), 1, "not started for the handshake");
    // Its first call starts it, and the answer is the server's.
    let called = second.call("tools/call", json!({"name": "search", "arguments": {}})).await;
    assert_eq!(called["result"]["content"][0]["text"], "called search", "{called}");
    assert_eq!(starts(&dir).len(), 2);
    let again = second.call("tools/call", json!({"name": "get", "arguments": {}})).await;
    assert_eq!(again["result"]["content"][0]["text"], "called get");
    assert_eq!(starts(&dir).len(), 2, "started once");
    let pid = *starts(&dir).last().unwrap();
    second.close().await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!alive(pid), "the server goes with its stand-in");
}

#[tokio::test]
async fn a_server_whose_tools_changed_since_says_so_when_it_starts_and_is_remembered_so() {
    let dir = server("mcp-lazy-changed", "search");
    Client::start(&dir).handshake().await;
    std::fs::write(dir.join("tools"), "search\nexport").unwrap();
    let mut client = Client::start(&dir);
    assert_eq!(client.handshake().await, ["search"], "what was kept, until it runs");
    client.call("tools/call", json!({"name": "search", "arguments": {}})).await;
    // Started, it's asked its tools again: different, the CLI is told to list them again, and gets the server's.
    for _ in 0..50 {
        if client.told.iter().any(|m| m["method"] == "notifications/tools/list_changed") {
            break;
        }
        client.call("ping", json!({})).await;
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(client.told.iter().any(|m| m["method"] == "notifications/tools/list_changed"), "{:?}", client.told);
    assert_eq!(names(&client.call("tools/list", json!({})).await), ["search", "export"]);
    client.close().await;
    let starts_before = starts(&dir).len();
    assert_eq!(Client::start(&dir).handshake().await, ["search", "export"], "kept as it now is");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(starts(&dir).len(), starts_before);
}

#[tokio::test]
async fn a_server_changed_on_disk_is_learnt_again_rather_than_stood_in_for() {
    // Updated (its script or program changed): what was kept may be out of date, so it runs as it starts.
    let dir = server("mcp-lazy-updated", "search");
    Client::start(&dir).handshake().await;
    std::thread::sleep(Duration::from_millis(1100));
    std::fs::write(dir.join("server.py"), format!("{SERVER}\n# updated\n")).unwrap();
    Client::start(&dir).handshake().await;
    assert_eq!(starts(&dir).len(), 2);
}

#[tokio::test]
async fn a_cli_that_probes_before_its_handshake_is_answered_from_what_was_kept_too() {
    // Claude Code asks `server/discover` first (a newer protocol), and makes the handshake when the server refuses.
    let dir = server("mcp-lazy-probe", "search");
    for run in 0..2 {
        let mut client = Client::start(&dir);
        let probe = client.call("server/discover", json!({})).await;
        assert_eq!(probe["error"]["code"], -32601, "the server's own refusal: {probe}");
        let init =
            client.call("initialize", json!({"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "t"}})).await;
        assert_eq!(init["result"]["protocolVersion"], "2025-11-25", "the handshake the CLI asked for");
        client.send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await;
        assert_eq!(names(&client.call("tools/list", json!({})).await), ["search"]);
        if run == 1 {
            tokio::time::sleep(Duration::from_millis(300)).await;
            assert_eq!(starts(&dir).len(), 1, "the second time, nothing started");
            let called = client.call("tools/call", json!({"name": "search", "arguments": {}})).await;
            assert_eq!(called["result"]["content"][0]["text"], "called search");
        }
        client.close().await;
    }
}
