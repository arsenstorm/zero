//! The runtimes the inbox reaches agents through when zerod doesn't run them itself: Solo (through its MCP helper),
//! Rex (its CLI), Zero's own terminals (zero-host's socket). Each tested against a stand-in speaking its interface, plus
//! the screen reading they share. Ported from the Swift adapters, which this replaces.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use zerod::ask::AgentIdentity;
use zerod::inbox::Runtime;
use zerod::terminal::{self, ClaudeSessions};

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("zerod-runtimes-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, body).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

const RULE: &str = "────────────────────────────────────────";

#[test]
fn a_draft_is_read_from_the_input_box_only() {
    let typing = format!("❯ old prompt in the scrollback\n⏺ reply\n{RULE}\n❯ let's leave this\n{RULE}\n  ⏵⏵ auto mode on");
    assert_eq!(terminal::draft(&typing).as_deref(), Some("let's leave this"));
    assert_eq!(terminal::draft(&format!("{RULE}\n❯ \n{RULE}")).as_deref(), Some(""));
    assert_eq!(terminal::draft(&format!("{RULE}\n❯ Try \"refactor x\"\n{RULE}")).as_deref(), Some(""), "the placeholder isn't a draft");
    assert_eq!(terminal::draft("no box here"), None);
}

#[test]
fn a_reply_is_the_last_thing_said_after_the_prompt() {
    let screen = "⏺ Earlier answer, before the message.\n\n✻ Worked for 3s · done 11:20 PM\n\n〉 hi\n\n● Hi. What are we working on?\n\n\
                  ✳ Worked for 1s · done 11:22 PM\n\n❯ next thing typed but not sent";
    assert_eq!(terminal::last_reply(screen, "hi").as_deref(), Some("Hi. What are we working on?"));
    let tools = "❯ fix the spinner\n\n⏺ Bash(make run)\n  ⎿  built\n\n⏺ Installed and pushed.\n\n  The spinner is now an arc.\n\n✻ Churned for 1m · done 11:23 PM";
    assert_eq!(terminal::last_reply(tools, "fix the spinner").as_deref(), Some("Installed and pushed.\n\nThe spinner is now an arc."));
    let ending = "❯ go\n\n⏺ Done, all green.\n\n⏺ [zero: done]\n";
    assert_eq!(terminal::last_reply(ending, "go").as_deref(), Some("Done, all green."), "Zero's turn ending is for the stop check");
    assert_eq!(terminal::last_reply("⏺ an answer to something else", "hi"), None, "nothing before the echo counts");
}

#[test]
fn claudes_sessions_are_found_by_first_prompt_and_titled() {
    let root = temp("sessions");
    let sessions = ClaudeSessions { root: root.clone() };
    let cwd = "/Users/x/proj.app";
    let folder = sessions.folder(cwd);
    assert_eq!(folder.file_name().unwrap(), "-Users-x-proj-app");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("aaaa.jsonl"), r#"{"type":"user","message":{"role":"user","content":"say \"hi\" please"}}"#).unwrap();
    std::fs::write(folder.join("bbbb.jsonl"), "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"other\"}}\n{\"aiTitle\":\"Other task\"}").unwrap();
    assert_eq!(sessions.find("say \"hi\" please", cwd).as_deref(), Some("aaaa"));
    assert_eq!(sessions.find("other", cwd).as_deref(), Some("bbbb"));
    assert_eq!(sessions.find("missing", cwd), None);
    assert_eq!(sessions.title("bbbb", cwd).as_deref(), Some("Other task"));
    assert_eq!(sessions.title("aaaa", cwd), None);
}

/// Solo's MCP helper as a script: answers each tool with the JSON text in `<dir>/<tool>.json` and logs the calls.
fn fake_solo(dir: &Path) -> zerod::solo::Solo {
    let helper = script(dir, "mcp", &format!(r#"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"tools/call"'*)
      printf '%s\n' "$line" >> "{dir}/calls.log"
      tool=$(printf '%s' "$line" | sed -n 's/.*"name":"\([a-z_]*\)".*/\1/p')
      printf '{{"jsonrpc":"2.0","id":2,"result":{{"content":[{{"type":"text","text":%s}}]}}}}\n' "$(cat "{dir}/$tool.json")"
      exit 0;;
  esac
done
"#, dir = dir.display()));
    zerod::solo::Solo { helper, sessions: ClaudeSessions { root: dir.join("claude") }, poll: Duration::from_millis(10) }
}

fn answer(dir: &Path, tool: &str, text: &str) {
    std::fs::write(dir.join(format!("{tool}.json")), serde_json::to_string(text).unwrap()).unwrap();
}

fn calls(dir: &Path) -> Vec<Value> {
    std::fs::read_to_string(dir.join("calls.log")).unwrap_or_default().lines().map(|l| serde_json::from_str::<Value>(l).unwrap()["params"].clone()).collect()
}

fn solo_agent() -> AgentIdentity {
    AgentIdentity { name: "solo-7".into(), host: "mac".into(), solo_process_id: Some(7), solo_project_id: Some(13), ..Default::default() }
}

#[tokio::test]
async fn solo_types_into_its_process_when_the_input_is_empty() {
    let dir = temp("solo-send");
    let solo = fake_solo(&dir);
    assert!(solo.can_reach(&solo_agent()));
    answer(&dir, "get_process_output", &format!("⏺ ready\n{RULE}\n❯ \n{RULE}"));
    answer(&dir, "send_input", "ok");
    solo.send("hello there", &solo_agent()).await.unwrap();
    let sent = calls(&dir).into_iter().find(|c| c["name"] == "send_input").unwrap();
    assert_eq!(sent["arguments"], json!({"process_id": 7, "project_id": 13, "input": "hello there", "submit": true}));
}

#[tokio::test]
async fn solo_says_which_agents_stopped_or_are_gone() {
    let dir = temp("solo-live");
    let solo = fake_solo(&dir);
    answer(&dir, "list_processes", &json!([{"id": 7, "status": "Running", "name": "Fix the bar"}, {"id": 8, "status": "Exited"}]).to_string());
    let (a, b, c) = (solo_agent(), AgentIdentity { name: "solo-8".into(), solo_process_id: Some(8), ..solo_agent() },
                     AgentIdentity { name: "solo-9".into(), solo_process_id: Some(9), ..solo_agent() });
    let agents = [a.clone(), b, c];
    let offline = solo.offline(&agents).await;
    assert!(!offline.contains("solo-7") && offline.contains("solo-8") && offline.contains("solo-9"));
    assert_eq!(solo.gone(&agents).await.into_iter().collect::<Vec<_>>(), ["solo-9"]);
    assert_eq!(solo.display_name(&a).await.as_deref(), Some("Fix the bar"), "Solo's name for the process, when it isn't just the tool's");
}

#[tokio::test]
async fn solo_reads_the_reply_off_the_screen_once_the_agent_is_idle() {
    let dir = temp("solo-reply");
    let solo = fake_solo(&dir);
    answer(&dir, "get_process_status", &json!({"status": "Running", "agent_state": {"idle": true, "idle_seconds": 2.0}}).to_string());
    answer(&dir, "get_process_output", "❯ how many?\n\n⏺ Forty two.\n\n✻ Worked for 1s · done");
    assert_eq!(solo.reply(&solo_agent(), "how many?").await.as_deref(), Some("Forty two."));
}

/// Rex's CLI as a script: `capture` prints `<dir>/screen.txt`, `block call` prints `<dir>/process.json` and exits with
/// `<dir>/process.code`, and every call is logged.
fn fake_rex(dir: &Path) -> zerod::rex::Rex {
    let rex = script(dir, "rex", &format!(r#"#!/bin/sh
printf '%s\n' "$*" >> "{dir}/calls.log"
case "$1" in
  capture) cat "{dir}/screen.txt";;
  block) cat "{dir}/process.json"; exit $(cat "{dir}/process.code");;
esac
"#, dir = dir.display()));
    zerod::rex::Rex { executable: Some(rex), sessions: ClaudeSessions { root: dir.join("claude") }, poll: Duration::from_millis(10) }
}

fn rex_agent() -> AgentIdentity {
    AgentIdentity { name: "claude-abc123".into(), host: "mac".into(), cwd: Some("/w".into()), runtime: Some("rex".into()),
                    reference: Some("block:1".into()), ..Default::default() }
}

#[tokio::test]
async fn rex_types_presses_enter_and_tells_running_from_gone() {
    let dir = temp("rex");
    let rex = fake_rex(&dir);
    std::fs::write(dir.join("screen.txt"), format!("{RULE}\n❯ \n{RULE}")).unwrap();
    std::fs::write(dir.join("process.json"), r#"{"child":{"pid":1}}"#).unwrap();
    std::fs::write(dir.join("process.code"), "0").unwrap();
    assert!(rex.can_reach(&rex_agent()));
    rex.send("hello", &rex_agent()).await.unwrap();
    let log = std::fs::read_to_string(dir.join("calls.log")).unwrap();
    assert!(log.contains("send -b block:1 hello") && log.contains("send-key -b block:1 enter"), "{log}");
    assert!(rex.offline(&[rex_agent()]).await.is_empty());
    std::fs::write(dir.join("process.json"), r#"{"child":null,"last_exit":0}"#).unwrap();
    assert!(rex.offline(&[rex_agent()]).await.contains("claude-abc123"), "exited, the terminal kept");
    std::fs::write(dir.join("process.code"), "3").unwrap();
    assert!(rex.gone(&[rex_agent()]).await.contains("claude-abc123"), "closed: no such block");
}

/// zero-host as a socket: answers each request from a table, and records them.
async fn fake_host(dir: &Path, answers: Value) -> (zerod::host::Host, std::sync::Arc<std::sync::Mutex<Vec<Value>>>) {
    let socket = dir.join("host.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let seen = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
    let record = seen.clone();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            if let Ok(Some(line)) = lines.next_line().await {
                let request: Value = serde_json::from_str(&line).unwrap();
                let reply = answers[request["op"].as_str().unwrap()].clone();
                record.lock().unwrap().push(request);
                let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
            }
        }
    });
    (zerod::host::Host { socket, sessions: ClaudeSessions { root: dir.join("claude") }, poll: Duration::from_millis(10) }, seen)
}

#[tokio::test]
async fn zeros_own_terminals_are_typed_into_and_read_through_zero_host() {
    let dir = temp("host");
    let answers = json!({
        "screen": {"ok": true, "screen": format!("⏺ hi\n{RULE}\n❯ \n{RULE}")},
        "write": {"ok": true},
        "state": {"ok": true, "terminal": {"id": "term-1", "label": "x", "cwd": "/w", "argv": ["claude"], "running": false, "exitCode": 0}},
    });
    let (host, seen) = fake_host(&dir, answers).await;
    let agent = AgentIdentity { name: "claude-term01".into(), host: "mac".into(), runtime: Some("zero".into()), reference: Some("term-1".into()), ..Default::default() };
    assert!(host.can_reach(&agent));
    host.send("hello", &agent).await.unwrap();
    let writes: Vec<Value> = seen.lock().unwrap().iter().filter(|r| r["op"] == "write").cloned().collect();
    assert_eq!(writes[0]["text"], "hello");
    assert_eq!(writes[1]["bytes"], json!([13]), "then Enter");
    assert!(host.offline(std::slice::from_ref(&agent)).await.contains("claude-term01"), "its program exited");
    assert_eq!(host.screen(&agent).await.unwrap().lines().next(), Some("⏺ hi"));
}

/// Read-only, against the running Solo app: its helper answers, and a process it doesn't have is offline and gone.
/// `cargo test -p zerod --test runtimes -- --ignored real_solo`.
#[tokio::test]
#[ignore = "talks to the running Solo app (reads only)"]
async fn real_solo_answers_through_its_helper() {
    let solo = zerod::solo::Solo::installed();
    let missing = AgentIdentity { name: "nobody".into(), host: "mac".into(), solo_process_id: Some(999_999), solo_project_id: Some(10), ..Default::default() };
    assert!(solo.can_reach(&missing));
    assert!(solo.offline(std::slice::from_ref(&missing)).await.contains("nobody"));
    assert!(solo.gone(std::slice::from_ref(&missing)).await.contains("nobody"));
}
