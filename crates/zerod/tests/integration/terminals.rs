//! A task opened in the user's own terminal app, on its CLI's own resume: Zero's UI is the way to work with an agent, and
//! the CLI's terminal UI a door to what only it has. The terminal takes over the task's own thread (Zero stops its
//! headless process first); back in Zero, what happened there joins the task's record, so nothing is lost.

use std::collections::HashSet;
use std::path::Path;
use std::sync::{Arc, Mutex};

use crate::common::{temp_dir, until};
use serde_json::{Value, json};
use std::os::unix::process::ExitStatusExt;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

#[test]
fn each_provider_opens_its_own_terminal_on_the_tasks_thread() {
    let mut claude = Conversation::new("s", Provider::Claude, "/w");
    claude.thread = Some("3f1c".into());
    claude.model = Some("opus".into());
    // The providers' own browsers are off in Zero, whatever the user's own settings: agents use Zero for Chrome.
    // Their own subagents too, unless the user allows them: work for another agent goes to a Zero worker.
    assert_eq!(
        Provider::Claude.terminal(&claude).unwrap()[4..],
        [
            "claude",
            "--resume",
            "3f1c",
            "--permission-mode",
            "auto",
            "--no-chrome",
            "--settings",
            r#"{"idleCompaction":false}"#,
            "--disallowed-tools=Agent",
            "--model",
            "opus"
        ]
    );
    let mut codex = Conversation::new("s", Provider::Codex, "/w");
    codex.thread = Some("01a1".into());
    codex.permissions = Permissions::Unrestricted;
    assert_eq!(
        Provider::Codex.terminal(&codex).unwrap()[4..],
        [
            "codex",
            "resume",
            "01a1",
            "--no-daemon",
            "--dangerously-bypass-approvals-and-sandbox",
            "-c",
            "plugins.chrome@openai-bundled.enabled=false",
            "-c",
            "plugins.browser@openai-bundled.enabled=false",
            "-c",
            "features.multi_agent=false"
        ]
    );
    assert_eq!(
        Provider::Codex.command(&codex, true, None, None)[4..],
        [
            "codex",
            "app-server",
            "-c",
            "plugins.chrome@openai-bundled.enabled=false",
            "-c",
            "plugins.browser@openai-bundled.enabled=false",
            "-c",
            "features.multi_agent=false"
        ]
    );
    let mut opencode = Conversation::new("s", Provider::Opencode, "/w");
    opencode.thread = Some("ses_9".into());
    assert_eq!(Provider::Opencode.terminal(&opencode).unwrap()[4..], ["opencode", "--session", "ses_9"]);
    assert_eq!(
        Provider::Codex.terminal(&Conversation::new("s", Provider::Codex, "/w")).unwrap_err(),
        "Codex hasn't started this task's thread yet"
    );
}

/// What Claude Code writes to its session file as you work in its terminal.
fn claude_turn() -> Vec<Value> {
    vec![
        json!({"type": "user", "uuid": "u1", "isMeta": true, "message": {"role": "user", "content": "<local-command-caveat>Caveat</local-command-caveat>"}}),
        json!({"type": "user", "uuid": "u2", "message": {"role": "user", "content": "List the files"}}),
        json!({"type": "assistant", "uuid": "a1", "message": {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hmm"}, {"type": "text", "text": "Listing them."},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]}}),
        json!({"type": "user", "uuid": "u3", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "a.txt", "is_error": false}]}}),
        json!({"type": "assistant", "uuid": "a2", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t2", "name": "Read", "input": {"file_path": "/w/a.txt"}}]}}),
        json!({"type": "user", "uuid": "u4", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t2", "content": "hi"}]}}),
        json!({"type": "assistant", "uuid": "a3", "message": {"role": "assistant", "content": [{"type": "text", "text": "There is one file, a.txt."}]}}),
        json!({"type": "system", "uuid": "s1", "subtype": "turn_duration"}),
    ]
}

#[test]
fn claude_codes_session_file_comes_back_as_the_tasks_items() {
    let kinds: Vec<ItemKind> = zerod::handoff::from_claude_session(&claude_turn()).into_iter().map(|i| i.kind).collect();
    assert_eq!(
        kinds,
        [
            ItemKind::User { text: "List the files".into(), images: vec![], sent: None },
            ItemKind::Agent { text: "Listing them.".into(), final_answer: false },
            ItemKind::Command {
                command: "ls".into(),
                cwd: String::new(),
                output: "a.txt".into(),
                exit_code: Some(0),
                duration_ms: None,
                description: String::new()
            },
            ItemKind::Tool { name: "Read".into(), detail: "/w/a.txt".into(), output: String::new() },
            ItemKind::Agent { text: "There is one file, a.txt.".into(), final_answer: true },
        ],
        "what was said and done, in order; Claude's own bookkeeping and thinking left out, the turn's last words its answer"
    );
}

#[test]
fn only_codex_turns_zero_doesnt_have_yet_come_back() {
    let turns = json!([
        {"id": "turn-1", "items": [{"type": "agentMessage", "id": "m1", "text": "old", "phase": "final_answer"}]},
        {"id": "turn-2", "items": [{"type": "userMessage", "id": "u2", "content": [{"type": "text", "text": "In the terminal"}]},
                                   {"type": "agentMessage", "id": "m2", "text": "Typed there", "phase": "final_answer"}]},
    ]);
    let items = zerod::codex::new_turn_items(&turns, &HashSet::from(["turn-1".to_string()]));
    let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids, ["u2", "m2"]);
    assert!(matches!(&items[1].kind, ItemKind::Agent { text, final_answer: true } if text == "Typed there"));
}

/// The terminal app as a test has it: records the script it's given and starts a stand-in for the CLI in its place,
/// whose process id goes where the script would write its own.
/// Each terminal opened, as its app and its script.
type Scripts = Arc<Mutex<Vec<(String, String)>>>;

fn fake_terminal(daemon: &Daemon) -> (Scripts, Arc<Mutex<Option<std::process::Child>>>) {
    let (seen, child) = (Arc::new(Mutex::new(vec![])), Arc::new(Mutex::new(None)));
    let (record, keep) = (seen.clone(), child.clone());
    daemon.open_terminals_with(Arc::new(move |app: &str, script: &Path| {
        record.lock().unwrap().push((app.to_string(), std::fs::read_to_string(script).unwrap()));
        let cli = std::process::Command::new("/bin/sleep").arg("30").spawn().unwrap();
        std::fs::write(script.with_extension("pid"), cli.id().to_string()).unwrap();
        *keep.lock().unwrap() = Some(cli);
        Ok(())
    }));
    (seen, child)
}

#[tokio::test]
async fn a_task_opens_in_the_users_terminal_and_comes_back_with_what_happened_there() {
    let home = temp_dir("terminal-flow");
    let user = home.join("user");
    let runtime: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home.join("zerod"), runtime).unwrap();
    daemon.place(&user);
    std::fs::write(home.join("zerod/settings.json"), r#"{"terminal": "iTerm"}"#).unwrap();
    let (seen, cli) = fake_terminal(&daemon);
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    let session = daemon.session(&id).unwrap();
    until(&session, |c| c.status == Status::Offline).await;
    let thread = session.snapshot().thread.unwrap();
    let file = zerod::handoff::claude_folder(&user, home.to_str().unwrap()).join(format!("{thread}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, json!({"type": "user", "uuid": "u0", "message": {"role": "user", "content": "hi"}}).to_string() + "\n").unwrap();

    let pid = daemon.open_terminal(&id).await.unwrap();
    let (app, script) = seen.lock().unwrap()[0].clone();
    assert_eq!(app, "iTerm", "the terminal app Settings names");
    assert!(script.contains(&format!("cd {}", zerod::daemon::quoted(home.to_str().unwrap()))), "{script}");
    assert!(script.contains(&format!("'--resume' '{thread}'")), "the CLI's own resume, on the task's thread: {script}");
    assert!(script.contains(&format!("export ZERO_SESSION='{id}'")), "its zero calls still reach the task: {script}");
    assert!(script.contains("export ZERO_MANAGED='0'"), "the user is at the keyboard: its prompts stay in the terminal");
    assert!(!script.contains("TERM="), "the terminal's own TERM and PATH, not the headless ones: {script}");
    assert_eq!(pid, cli.lock().unwrap().as_ref().unwrap().id().to_string());
    assert_eq!(session.snapshot().terminal, Some(Opened { id: pid.clone(), mark: 1 }), "what the file held before is in the record");
    assert_eq!(
        daemon.send(&id, zerod::session::Message::text("from Zero"), Default::default()).await.unwrap_err(),
        "Claude Code is open in Terminal; type there, or bring it back to Zero"
    );
    assert_eq!(daemon.open_terminal(&id).await.unwrap(), pid, "open already: the same one");
    assert_eq!(seen.lock().unwrap().len(), 1);

    let mut written = std::fs::read_to_string(&file).unwrap();
    for record in claude_turn() {
        written += &(record.to_string() + "\n")
    }
    std::fs::write(&file, written).unwrap();
    // The CLI exits in the terminal: the task comes back on its own.
    let mut exited = cli.lock().unwrap().take().unwrap();
    exited.kill().unwrap();
    exited.wait().unwrap();
    for _ in 0..50 {
        if session.snapshot().terminal.is_none() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    let conversation = session.snapshot();
    assert_eq!(conversation.terminal, None);
    let texts: Vec<String> = conversation
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::User { text, .. } | ItemKind::Agent { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        texts,
        ["hi", "List the files", "Listing them.", "There is one file, a.txt."],
        "the terminal's turn joins the record, the earlier one isn't repeated"
    );
    // Kept across a restart: the record took it in as changes in the transcript.
    drop(daemon);
    let runtime: Runtime = Arc::new(|_, _, _| Err(std::io::Error::other("not started")));
    let again = Daemon::open(&home.join("zerod"), runtime).unwrap();
    assert_eq!(again.get(&id).unwrap().items.len(), conversation.items.len());
}

#[test]
fn ghostty_is_given_the_script_as_its_command_as_it_asks_before_running_one_opened() {
    let script = Path::new("/z/t.command");
    assert_eq!(zerod::daemon::open_args("Terminal", script), ["-a", "Terminal", "/z/t.command"]);
    for ghostty in ["Ghostty", "/Applications/Ghostty.app"] {
        assert_eq!(
            zerod::daemon::open_args(ghostty, script),
            ["-na", ghostty, "--args", "--quit-after-last-window-closed=true", "-e", "/z/t.command"]
        );
    }
}

#[test]
fn unset_the_terminal_is_ghostty_where_installed_else_terminal() {
    assert_eq!(zerod::daemon::default_terminal(|app| app == "Ghostty"), "Ghostty");
    assert_eq!(zerod::daemon::default_terminal(|_| false), "Terminal");
}

#[tokio::test]
async fn back_to_zero_ends_the_cli_still_running_in_the_terminal() {
    let home = temp_dir("terminal-back");
    let runtime: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home.join("zerod"), runtime).unwrap();
    daemon.place(&home.join("user"));
    let (_, cli) = fake_terminal(&daemon);
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    let session = daemon.session(&id).unwrap();
    until(&session, |c| c.status == Status::Offline).await;
    daemon.open_terminal(&id).await.unwrap();
    daemon.close_terminal(&id).await.unwrap();
    assert_eq!(session.snapshot().terminal, None);
    let mut child = cli.lock().unwrap().take().unwrap();
    assert!(child.wait().unwrap().signal().is_some(), "two writers on one thread never: the terminal's CLI is ended");
}

#[tokio::test]
async fn a_terminal_that_never_starts_the_cli_leaves_the_task_in_zero() {
    let home = temp_dir("terminal-never");
    let runtime: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home.join("zerod"), runtime).unwrap();
    daemon.place(&home.join("user"));
    daemon.open_terminals_with(Arc::new(|_: &str, _: &Path| Ok(())));
    zerod::daemon::set_terminal_wait(std::time::Duration::from_millis(300));
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    let session = daemon.session(&id).unwrap();
    until(&session, |c| c.status == Status::Offline).await;
    let error = daemon.open_terminal(&id).await.unwrap_err();
    assert!(error.contains("didn't start"), "{error}");
    assert_eq!(session.snapshot().terminal, None);
}

#[tokio::test]
async fn a_resume_that_fails_lets_go_of_the_process_it_started() {
    // Codex refusing the thread (still held by its terminal, say): the headless Codex started for it mustn't stay
    // around holding the thread too.
    let home = temp_dir("terminal-resume-fails");
    let dir = home.join("sessions/01a100000000000a");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("meta.json"), r#"{"id":"01a100000000000a","provider":"codex","cwd":"/work","thread":"t1"}"#).unwrap();
    let script = vec![
        json!({"out": {"id": "z1", "method": "initialize"}}),
        json!({"in": {"id": "z1", "result": {}}}),
        json!({"out": {"method": "initialized"}}),
        json!({"out": {"id": "z2", "method": "thread/resume"}}),
        json!({"in": {"id": "z2", "error": {"code": -1, "message": "thread t1 already has an active writer"}}}),
    ];
    let script = Mutex::new(Some(script));
    let runtime: Runtime = Arc::new(move |_, _, _| Ok(crate::common::play(script.lock().unwrap().take().unwrap()).0));
    let daemon = Daemon::open(&home, runtime).unwrap();
    let error = daemon.resume("01a100000000000a").await.unwrap_err();
    assert!(error.contains("active writer"), "{error}");
    let session = daemon.session("01a100000000000a").unwrap();
    assert!(!session.is_attached());
    until(&session, |c| c.status == Status::Offline).await;
}

#[tokio::test]
async fn claudes_session_file_is_found_by_the_folders_real_path_too() {
    // Claude Code names its folder by the real path: a task in /tmp is in /private/tmp to it.
    let home = temp_dir("terminal-real-path");
    let real = home.join("project");
    std::fs::create_dir_all(&real).unwrap();
    let link = home.join("linked");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let runtime: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home.join("zerod"), runtime).unwrap();
    let user = home.join("user");
    daemon.place(&user);
    let (_, cli) = fake_terminal(&daemon);
    let id = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(link.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    let session = daemon.session(&id).unwrap();
    until(&session, |c| c.status == Status::Offline).await;
    let thread = session.snapshot().thread.unwrap();
    let canonical = std::fs::canonicalize(&link).unwrap();
    let file = zerod::handoff::claude_folder(&user, canonical.to_str().unwrap()).join(format!("{thread}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, json!({"type": "user", "uuid": "u0", "message": {"role": "user", "content": "hi"}}).to_string() + "\n").unwrap();
    daemon.open_terminal(&id).await.unwrap();
    assert_eq!(session.snapshot().terminal.map(|t| t.mark), Some(1));
    let mut written = std::fs::read_to_string(&file).unwrap();
    for record in claude_turn() {
        written += &(record.to_string() + "\n")
    }
    std::fs::write(&file, written).unwrap();
    let mut exited = cli.lock().unwrap().take().unwrap();
    exited.kill().unwrap();
    exited.wait().unwrap();
    until(&session, |c| {
        c.terminal.is_none()
            && c.items.iter().any(|i| matches!(&i.kind, ItemKind::Agent { text, .. } if text == "There is one file, a.txt."))
    })
    .await;
}
