//! The runtime the inbox reaches agents through when zerod doesn't run them itself: Zero's own terminals (zero-host's
//! socket), tested against a stand-in speaking its interface, plus the screen reading it takes.

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
    std::fs::write(
        folder.join("bbbb.jsonl"),
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"other\"}}\n{\"aiTitle\":\"Other task\"}",
    )
    .unwrap();
    assert_eq!(sessions.find("say \"hi\" please", cwd).as_deref(), Some("aaaa"));
    assert_eq!(sessions.find("other", cwd).as_deref(), Some("bbbb"));
    assert_eq!(sessions.find("missing", cwd), None);
    assert_eq!(sessions.title("bbbb", cwd).as_deref(), Some("Other task"));
    assert_eq!(sessions.title("aaaa", cwd), None);
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
    let agent = AgentIdentity {
        name: "claude-term01".into(),
        host: "mac".into(),
        runtime: Some("zero".into()),
        reference: Some("term-1".into()),
        ..Default::default()
    };
    assert!(host.can_reach(&agent));
    host.send("hello", &agent).await.unwrap();
    let writes: Vec<Value> = seen.lock().unwrap().iter().filter(|r| r["op"] == "write").cloned().collect();
    assert_eq!(writes[0]["text"], "hello");
    assert_eq!(writes[1]["bytes"], json!([13]), "then Enter");
    assert!(host.offline(std::slice::from_ref(&agent)).await.contains("claude-term01"), "its program exited");
    assert_eq!(host.screen(&agent).await.unwrap().lines().next(), Some("⏺ hi"));
}

#[test]
fn a_claude_title_is_read_from_what_was_added_since_the_last_look() {
    let dir = temp("claude-title");
    let sessions = ClaudeSessions { root: dir.clone() };
    let folder = sessions.folder("/w");
    std::fs::create_dir_all(&folder).unwrap();
    let file = folder.join("s.jsonl");
    std::fs::write(&file, "{\"aiTitle\":\"First\"}\n").unwrap();
    assert_eq!(sessions.title("s", "/w").as_deref(), Some("First"));
    let mut append = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
    std::io::Write::write_all(&mut append, b"{\"type\":\"user\"}\n").unwrap();
    assert_eq!(sessions.title("s", "/w").as_deref(), Some("First"), "kept while nothing new names it");
    std::io::Write::write_all(&mut append, b"{\"aiTitle\":\"Sec").unwrap();
    assert_eq!(sessions.title("s", "/w").as_deref(), Some("First"), "half a line isn't a title");
    std::io::Write::write_all(&mut append, b"ond\"}\n").unwrap();
    assert_eq!(sessions.title("s", "/w").as_deref(), Some("Second"));
}
