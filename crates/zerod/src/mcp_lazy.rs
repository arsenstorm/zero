//! `zerod mcp lazy <command> <args…>`: stands in for a local MCP server that starts when first used (McpServer::lazy).
//! A CLI starts every server in its config with every task, and most servers are never called in most tasks (a Node one
//! is ≈140 MB each time): the stand-in answers the handshake and the lists (tools, prompts, resources) from what the
//! server said the last time it ran, starts it on the first call, and passes everything through both ways from then on.
//! What it says is kept again each time it starts, and a server changed since tells the CLI its tools changed. Kept in
//! ~/.zero/mcp-cache, by its command, its arguments and when the files they name last changed (an update is a new
//! server); nothing kept, or kept for another version, and it starts at once.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, UNIX_EPOCH};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin};
use tokio::sync::{mpsc, oneshot};

/// What a server's answers are kept for: the handshake and the lists a CLI asks for as it starts.
/// `server/discover` is the probe a newer CLI makes before its handshake (Claude Code's): an older server refuses it.
const KEPT: &[&str] = &["server/discover", "initialize", "tools/list", "prompts/list", "resources/list", "resources/templates/list"];
/// The stand-in's own requests to the server: its handshake, and the lists asked again once it runs.
const OWN: &str = "zero-lazy:";

/// What was kept of a server: the version it was kept for, and its answers by method.
#[derive(Default)]
struct Kept {
    file: PathBuf,
    key: String,
    /// The protocol version the handshake asked for: a CLI asking for another is answered by the server itself.
    asked: Option<String>,
    answers: serde_json::Map<String, Value>,
}

impl Kept {
    fn read(command: &str, args: &[String]) -> Kept {
        let key = key(command, args);
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let file = home.join(".zero/mcp-cache").join(format!("{:016x}.json", hash(&key)));
        let mut kept = Kept { file, key, ..Default::default() };
        let read: Option<Value> = std::fs::read(&kept.file).ok().and_then(|data| serde_json::from_slice(&data).ok());
        if let Some(read) = read.filter(|r| r["key"] == kept.key.as_str()) {
            kept.asked = read["asked"].as_str().map(String::from);
            kept.answers = read["answers"].as_object().cloned().unwrap_or_default();
        }
        kept
    }

    fn answer(&self, method: &str) -> Option<&Value> {
        self.answers.get(method)
    }

    /// The server's answer to `method`, kept (its result or its error).
    fn keep(&mut self, method: &str, answer: &Value) {
        let mut kept = serde_json::Map::new();
        for field in ["result", "error"] {
            if let Some(value) = answer.get(field) {
                kept.insert(field.into(), value.clone());
            }
        }
        // Only a whole list: one in pages is the server's to give.
        if kept.get("result").is_some_and(|r| r.get("nextCursor").is_some_and(|c| !c.is_null())) {
            return;
        }
        self.answers.insert(method.into(), Value::Object(kept));
        let data = json!({"key": self.key, "asked": self.asked, "answers": self.answers}).to_string();
        let partial = self.file.with_extension("partial");
        if let Some(dir) = self.file.parent()
            && std::fs::create_dir_all(dir).is_ok()
            && std::fs::write(&partial, data).is_ok()
        {
            let _ = std::fs::rename(&partial, &self.file);
        }
    }
}

/// The server's identity: its command and arguments, and when the files they name last changed.
fn key(command: &str, args: &[String]) -> String {
    let program = if command.contains('/') {
        Some(PathBuf::from(command))
    } else {
        std::env::var("PATH").ok().and_then(|path| path.split(':').map(|dir| Path::new(dir).join(command)).find(|p| p.is_file()))
    };
    let stamp = |path: &Path| {
        let meta = std::fs::metadata(path).ok().filter(|m| m.is_file())?;
        let at = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?.as_nanos();
        Some(format!("{}@{at}:{}", path.display(), meta.len()))
    };
    let stamps: Vec<String> =
        program.iter().chain(args.iter().map(PathBuf::from).collect::<Vec<_>>().iter()).filter_map(|p| stamp(p)).collect();
    [command.to_string()].into_iter().chain(args.iter().cloned()).chain(stamps).collect::<Vec<_>>().join("\u{0}")
}

fn hash(text: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::hash::DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

/// The server, once started, and whether the stand-in made its handshake (else the CLI makes its own through it).
struct Real {
    input: ChildStdin,
    child: Child,
    handshake: bool,
}

/// What the stand-in and the reader of the server's output share.
struct Shared {
    kept: Mutex<Kept>,
    /// Requests whose answers are kept, by their id, with their method.
    keeping: Mutex<HashMap<String, String>>,
    /// The tools the CLI was given from what was kept.
    given: Mutex<Option<Value>>,
    /// Waiting for the server's answer to the handshake.
    handshake: Mutex<Option<oneshot::Sender<Value>>>,
}

pub async fn serve(command: String, args: Vec<String>) {
    let shared = Arc::new(Shared {
        kept: Mutex::new(Kept::read(&command, &args)),
        keeping: Mutex::new(HashMap::new()),
        given: Mutex::new(None),
        handshake: Mutex::new(None),
    });
    let (out, mut lines_out) = mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(mut line) = lines_out.recv().await {
            line.push('\n');
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.flush().await.is_err() {
                std::process::exit(0)
            }
        }
    });
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let (mut real, mut hello): (Option<Real>, Option<Value>) = (None, None);
    loop {
        let line = tokio::select! {
            line = lines.next_line() => match line { Ok(Some(line)) => line, _ => break },
            _ = async { match terminate.as_mut() { Some(t) => { t.recv().await; } None => std::future::pending().await } } => break,
        };
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let method = message["method"].as_str().unwrap_or_default().to_string();
        let id = message.get("id").cloned();
        if let Some(server) = real.as_mut() {
            // Running: everything goes through, but a handshake the stand-in already made.
            if method == "notifications/initialized" && server.handshake {
                continue;
            }
            if method == "initialize" {
                shared.kept.lock().unwrap().asked = message["params"]["protocolVersion"].as_str().map(String::from);
            }
            if let Some(id) = &id
                && KEPT.contains(&method.as_str())
                && message["params"].get("cursor").is_none()
            {
                shared.keeping.lock().unwrap().insert(id.to_string(), method.clone());
            }
            if server.input.write_all(format!("{line}\n").as_bytes()).await.is_err() {
                break;
            }
            continue;
        }
        if method == "initialize" {
            hello = Some(message["params"].clone());
        }
        let Some(id) = id else { continue };
        if method == "ping" {
            let _ = out.send(json!({"jsonrpc": "2.0", "id": id, "result": {}}).to_string());
            continue;
        }
        let answer = {
            let kept = shared.kept.lock().unwrap();
            // Before the handshake (a probe), any; after it, only what was said for the same protocol version.
            let same_version = hello.as_ref().is_none_or(|h| kept.asked.as_deref() == h["protocolVersion"].as_str());
            kept.answer(&method).filter(|_| same_version && message["params"].get("cursor").is_none()).cloned()
        };
        if let Some(mut answer) = answer {
            if method == "tools/list" {
                *shared.given.lock().unwrap() = answer["result"]["tools"].as_array().cloned().map(Value::Array);
            }
            answer["jsonrpc"] = json!("2.0");
            answer["id"] = id;
            let _ = out.send(answer.to_string());
            continue;
        }
        // Not kept (never seen, or a call): the server, from now on.
        let started = match start(&command, &args, hello.clone(), &shared, out.clone()).await {
            Ok(started) => started,
            Err(why) => {
                eprintln!("zerod mcp lazy: {why}");
                let _ = out.send(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": why}}).to_string());
                break;
            }
        };
        let server = real.insert(started);
        if method == "initialize" && server.handshake {
            // Its handshake is the stand-in's: its answer goes to the CLI as the answer to the CLI's.
            if let Some(mut answer) = shared.kept.lock().unwrap().answer("initialize").cloned() {
                answer["jsonrpc"] = json!("2.0");
                answer["id"] = id;
                let _ = out.send(answer.to_string());
            }
            continue;
        }
        if KEPT.contains(&method.as_str()) {
            shared.keeping.lock().unwrap().insert(id.to_string(), method.clone());
        }
        if server.input.write_all(format!("{line}\n").as_bytes()).await.is_err() {
            break;
        }
    }
    if let Some(mut server) = real {
        let _ = server.child.start_kill();
    }
    std::process::exit(0)
}

/// Starts the server. After the CLI's handshake, makes it (as the CLI asked) and asks it again for what's kept of it,
/// so what's kept is how it is now; before it (a probe), leaves the handshake to the CLI.
async fn start(
    command: &str, args: &[String], hello: Option<Value>, shared: &Arc<Shared>, out: mpsc::UnboundedSender<String>,
) -> Result<Real, String> {
    let mut child = tokio::process::Command::new(command)
        .args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("{command} didn't start: {e}"))?;
    let (Some(mut input), Some(output)) = (child.stdin.take(), child.stdout.take()) else { return Err(format!("{command} has no stdio")) };
    let (said, heard) = oneshot::channel();
    *shared.handshake.lock().unwrap() = Some(said);
    let reader = shared.clone();
    tokio::spawn(async move {
        let mut lines = BufReader::new(output).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Some(line) = heard_from_server(&reader, line) {
                let _ = out.send(line);
            }
        }
        // The server ended: so does its stand-in, so the CLI sees it gone.
        std::process::exit(0)
    });
    let Some(hello) = hello else { return Ok(Real { input, child, handshake: false }) };
    shared.kept.lock().unwrap().asked = hello["protocolVersion"].as_str().map(String::from);
    let send = |message: Value| format!("{message}\n");
    input
        .write_all(send(json!({"jsonrpc": "2.0", "id": format!("{OWN}initialize"), "method": "initialize", "params": hello})).as_bytes())
        .await
        .map_err(|e| format!("{command} closed: {e}"))?;
    let answer = tokio::time::timeout(Duration::from_secs(120), heard)
        .await
        .map_err(|_| format!("{command} didn't answer its handshake"))?
        .map_err(|_| format!("{command} ended"))?;
    let capabilities = &answer["result"]["capabilities"];
    let mut again = vec![send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))];
    let lists =
        [("tools", "tools/list"), ("prompts", "prompts/list"), ("resources", "resources/list"), ("resources", "resources/templates/list")];
    for (capability, method) in lists {
        if capabilities.get(capability).is_some() {
            again.push(send(json!({"jsonrpc": "2.0", "id": format!("{OWN}{method}"), "method": method})));
        }
    }
    for line in again {
        input.write_all(line.as_bytes()).await.map_err(|e| format!("{command} closed: {e}"))?;
    }
    Ok(Real { input, child, handshake: true })
}

/// A line from the server: kept if it answers what's kept, and what goes on to the CLI (not the stand-in's own).
fn heard_from_server(shared: &Shared, line: String) -> Option<String> {
    let Ok(message) = serde_json::from_str::<Value>(&line) else { return Some(line) };
    let id = message.get("id").filter(|_| message.get("method").is_none());
    let Some(id) = id else { return Some(line) };
    let own = id.as_str().and_then(|id| id.strip_prefix(OWN)).map(String::from);
    let method = own.clone().or_else(|| shared.keeping.lock().unwrap().remove(&id.to_string()));
    if let Some(method) = &method {
        shared.kept.lock().unwrap().keep(method, &message);
    }
    match own.as_deref() {
        None => Some(line),
        Some("initialize") => {
            if let Some(said) = shared.handshake.lock().unwrap().take() {
                let _ = said.send(message);
            }
            None
        }
        // The tools as they are now, against what the CLI was given: changed, it's told to ask again.
        Some("tools/list") => {
            let given = shared.given.lock().unwrap().take();
            let changed = given.is_some_and(|given| Some(&given) != message["result"].get("tools"));
            changed.then(|| json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}).to_string())
        }
        Some(_) => None,
    }
}
