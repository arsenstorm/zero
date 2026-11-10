//! Recorded runtimes for tests. A fixture is a transcript of a real session in zerod's own format: `{"in": …}`
//! for what the runtime said, `{"out": …}` for what was said to it. `play` stands in for the runtime: it says
//! the `in` lines in order and, at each `out` line, waits for Zero to say the same thing (the same method, or the
//! same Claude message type), so the session under test has to speak the protocol in the recorded order.
#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines, ReadHalf, WriteHalf};
use zerod::core::Core;
use zerod::model::{Change, Conversation, Provider};
use zerod::session::{Session, Transport};

pub fn fixture(name: &str) -> Vec<Value> {
    let path = format!("{}/tests/fixtures/{name}.jsonl", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(path).unwrap().lines().map(|line| serde_json::from_str(line).unwrap()).collect()
}

/// A fixture through a fresh core, as a replay would: the conversation it ends with and every change on the way.
pub fn replay(provider: Provider, name: &str) -> (Core, Vec<Change>) {
    let mut core = Core::new(Conversation::new("s1", provider, "/work/project"));
    let mut changes = vec![];
    for entry in fixture(name) {
        if let Some(message) = entry.get("out") {
            changes.extend(core.sent(message))
        }
        if let Some(message) = entry.get("in") {
            changes.extend(core.receive(message).changes)
        }
    }
    (core, changes)
}

/// Everything Zero wrote to the runtime, in order; and, once the script has run out, a way to say more.
#[derive(Clone, Default)]
pub struct Seen(Arc<Mutex<Vec<Value>>>, Arc<Mutex<Option<tokio::sync::mpsc::UnboundedSender<Value>>>>);

impl Seen {
    /// Has the runtime say `message` (after its script has played).
    pub fn say(&self, message: Value) {
        if let Some(say) = self.1.lock().unwrap().as_ref() {
            let _ = say.send(message);
        }
    }

    pub fn all(&self) -> Vec<Value> {
        self.0.lock().unwrap().clone()
    }

    /// The JSON-RPC methods, or the Claude message types (`control_request:interrupt` for a control request).
    pub fn methods(&self) -> Vec<String> {
        self.all().iter().filter_map(name).collect()
    }

    pub fn first(&self, method: &str) -> Option<Value> {
        self.all().into_iter().find(|m| name(m).as_deref() == Some(method))
    }

    /// What Zero said with this name, once it has: lines nothing answers (a Claude message, an ACP cancel) are
    /// sent before the fake has read them.
    pub async fn said(&self, method: &str, count: usize) -> Vec<Value> {
        for _ in 0..500 {
            let found: Vec<Value> = self.all().into_iter().filter(|m| name(m).as_deref() == Some(method)).collect();
            if found.len() >= count {
                return found;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("Zero never said {method} {count} times; it said {:?}", self.methods());
    }

    pub fn reply_to(&self, id: &Value) -> Option<Value> {
        self.all().into_iter().find(|m| m.get("method").is_none() && &m["id"] == id)
    }
}

fn name(message: &Value) -> Option<String> {
    if let Some(method) = message["method"].as_str() {
        return Some(method.into());
    }
    match message["type"].as_str()? {
        "control_request" => Some(format!("control_request:{}", message["request"]["subtype"].as_str().unwrap_or(""))),
        other => Some(other.into()),
    }
}

/// Whether what Zero said is the recorded `out` line: the same request or notification, or the answer to the same
/// request of the runtime's.
fn same(recorded: &Value, said: &Value) -> bool {
    match (recorded.get("method"), recorded["type"].as_str()) {
        (Some(method), _) => said.get("method") == Some(method),
        (None, Some("control_response")) => {
            said["type"] == "control_response" && said["response"]["request_id"] == recorded["response"]["request_id"]
        }
        (None, Some(kind)) => name(said) == name(recorded) && said["type"] == kind,
        (None, None) => said.get("method").is_none() && said["id"] == recorded["id"],
    }
}

type In = Lines<BufReader<ReadHalf<DuplexStream>>>;
type Out = WriteHalf<DuplexStream>;

/// A transport whose far end plays `script`, a transcript fixture. Requests Zero makes that the script doesn't
/// expect get an empty success, so a test can go on talking after the script ends; `{"hangup": true}` hangs up.
pub fn play(script: Vec<Value>) -> (Transport, Seen) {
    let (zero_side, runtime_side) = tokio::io::duplex(1 << 20);
    let (zero_read, zero_write) = tokio::io::split(zero_side);
    let (runtime_read, mut runtime_write) = tokio::io::split(runtime_side);
    let seen = Seen::default();
    let recorder = seen.clone();
    let (say, mut said) = tokio::sync::mpsc::unbounded_channel::<Value>();
    *seen.1.lock().unwrap() = Some(say);
    tokio::spawn(async move {
        let mut lines = BufReader::new(runtime_read).lines();
        // Recorded ids of Zero's requests → the ids Zero used this time.
        let mut ids: HashMap<String, Value> = HashMap::new();
        for entry in script {
            if entry.get("hangup").is_some() {
                return;
            }
            if let Some(message) = entry.get("in") {
                let mut message = message.clone();
                if message.get("method").is_none()
                    && let Some(actual) = message.get("id").and_then(|id| ids.get(&key(id)))
                {
                    message["id"] = actual.clone()
                }
                if message["type"] == "control_response"
                    && let Some(actual) = ids.get(&key(&message["response"]["request_id"]))
                {
                    message["response"]["request_id"] = actual.clone();
                }
                write(&mut runtime_write, &message).await;
            }
            if let Some(recorded) = entry.get("out") {
                let Some(said) = wait(&mut lines, &mut runtime_write, &recorder, &|m| same(recorded, m)).await else { return };
                if recorded.get("method").is_some()
                    && let (Some(from), Some(to)) = (recorded.get("id"), said.get("id"))
                {
                    ids.insert(key(from), to.clone());
                }
                if recorded["type"] == "control_request" {
                    ids.insert(key(&recorded["request_id"]), said["request_id"].clone());
                }
            }
        }
        // The script is over: keep answering what Zero says, and say what the test asks for.
        loop {
            tokio::select! {
                line = lines.next_line() => {
                    let Ok(Some(line)) = line else { return };
                    let message: Value = serde_json::from_str(&line).unwrap();
                    recorder.0.lock().unwrap().push(message.clone());
                    if message.get("method").is_some() && message.get("id").is_some() {
                        write(&mut runtime_write, &json!({"jsonrpc": "2.0", "id": message["id"], "result": {}})).await;
                    }
                    if message["type"] == "control_request" {
                        write(&mut runtime_write, &json!({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"], "response": {}}})).await;
                    }
                }
                Some(message) = said.recv() => write(&mut runtime_write, &message).await,
            }
        }
    });
    (Transport::new(zero_read, zero_write), seen)
}

/// Reads what Zero says until `wanted` matches, answering any other request on the way.
async fn wait(lines: &mut In, out: &mut Out, seen: &Seen, wanted: &(dyn Fn(&Value) -> bool + Sync)) -> Option<Value> {
    while let Ok(Some(line)) = lines.next_line().await {
        let message: Value = serde_json::from_str(&line).unwrap();
        seen.0.lock().unwrap().push(message.clone());
        if wanted(&message) {
            return Some(message);
        }
        if message.get("method").is_some() && message.get("id").is_some() {
            write(out, &json!({"jsonrpc": "2.0", "id": message["id"], "result": {}})).await;
        }
        if message["type"] == "control_request" {
            write(out, &json!({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"], "response": {}}})).await;
        }
    }
    None
}

fn key(id: &Value) -> String {
    id.as_str().map(String::from).unwrap_or_else(|| id.to_string())
}

async fn write(out: &mut Out, message: &Value) {
    let mut line = serde_json::to_vec(message).unwrap();
    line.push(b'\n');
    let _ = out.write_all(&line).await;
}

/// Waits up to five seconds for the session's conversation to satisfy `test`.
pub async fn until(session: &Session, test: impl Fn(&Conversation) -> bool) -> Conversation {
    for _ in 0..500 {
        let now = session.snapshot();
        if test(&now) {
            return now;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out; the conversation is {:#?}", session.snapshot());
}

/// A folder of its own under the system's temporary folder, empty.
pub fn temp_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("zerod-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
