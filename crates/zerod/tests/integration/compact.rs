//! Settings › Compact context at reaches tasks already running, not only those started after the change: the CLIs read
//! it as their process starts, so a task between turns starts again with it, and one mid-turn as its turn ends.

use std::sync::{Arc, Mutex};

use crate::common::{temp_dir, until};
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

/// What each start was given: its session, and the window its CLI reads (Codex's on its command line, Claude Code's in
/// the environment its process gets).
type Starts = Arc<Mutex<Vec<(String, Option<String>)>>>;

/// An agent that stays connected, keeping each start's window; what it's sent goes to `sent`.
fn recording(starts: Starts, sent: Arc<Mutex<String>>) -> Runtime {
    let listening = crate::endings::listening(sent);
    Arc::new(move |conversation, dir, argv| {
        let line = argv.join(" ");
        let codex = line.split_whitespace().find_map(|a| a.strip_prefix("model_auto_compact_token_limit=")).map(String::from);
        let claude = zerod::process::environment(std::iter::empty(), &conversation.id)
            .into_iter()
            .find(|(k, _)| k == "CLAUDE_CODE_AUTO_COMPACT_WINDOW")
            .map(|(_, v)| v);
        starts.lock().unwrap().push((conversation.id.clone(), if conversation.provider == Provider::Codex { codex } else { claude }));
        listening(conversation, dir, argv)
    })
}

fn last_start(starts: &Starts, id: &str) -> Option<Option<String>> {
    starts.lock().unwrap().iter().rev().find(|(s, _)| s == id).map(|(_, w)| w.clone())
}

/// The user's Settings › Compact context at, as the app sends it: zerod served on `home`, one `configure` request.
async fn configure(home: &std::path::Path, daemon: &Arc<Daemon>, tokens: u64) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let commands = || Arc::new(zerod::integrations::Commands::default());
    let socket = home.join("zerod.sock");
    tokio::spawn(zerod::server::serve(
        zerod::server::Zerod {
            daemon: daemon.clone(),
            inbox: zerod::inbox::Inbox::open(None, vec![]),
            integrations: zerod::integrations::Integrations::open(home, commands()),
            following: zerod::following::Following::open(home, commands(), zerod::integrations::Integrations::open(home, commands())),
            browsers: zerod::browser::Browsers::open(home),
            desktop: Default::default(),
            pads: Arc::new(zerod::pads::Pads::open(&home.join("scratchpads"))),
            later: Arc::new(zerod::later::Later::open(&home.join("later"))),
            loops: Arc::new(zerod::loops::Loops::open(&home.join("loops"))),
            places: Default::default(),
            notices: tokio::sync::broadcast::channel(64).0,
            peers: Arc::new(|_| true),
        },
        socket.clone(),
    ));
    let mut stream = None;
    for _ in 0..100 {
        if let Ok(connected) = tokio::net::UnixStream::connect(&socket).await {
            stream = Some(connected);
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let mut stream = stream.expect("zerod is served");
    let request = serde_json::json!({"id": 1, "op": "configure", "compactWindow": tokens});
    stream.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    let reply = tokio::io::BufReader::new(stream).lines().next_line().await.unwrap().unwrap();
    assert!(reply.contains(r#""ok":true"#), "{reply}");
}

fn idle() -> Change {
    Change::Status { status: Status::Idle, turn: None, error: None }
}

#[tokio::test(start_paused = true)]
async fn a_new_compact_window_restarts_running_agents_between_turns() {
    // The window is zerod-wide: the other test that sets it waits for this one.
    let _one = crate::common::COMPACT.lock().await;
    zerod::adapter::set_compact_window(None);
    let home = temp_dir("compact-window");
    let starts: Starts = Default::default();
    let sent = Arc::new(Mutex::new(String::new()));
    let daemon = Daemon::open(&home.join("zerod"), recording(starts.clone(), sent.clone())).unwrap();
    let options = || zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() };
    let claude = daemon.start(Provider::Claude, "hi", options()).unwrap();
    let codex = daemon.start(Provider::Codex, "hi", options()).unwrap();
    let busy = daemon.start(Provider::Claude, "hi", options()).unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    for id in [&claude, &codex] {
        daemon.session(id).unwrap().change(idle());
        assert_eq!(last_start(&starts, id), Some(None), "started with the CLI's own window");
    }
    let working = daemon.session(&busy).unwrap();
    working.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });

    // The same window again stops nothing.
    daemon.compact_window_changed().await;
    for id in [&claude, &codex, &busy] {
        assert!(daemon.session(id).unwrap().is_attached(), "unchanged, left running");
    }
    assert!(daemon.next(&busy).is_none());

    configure(&home, &daemon, 400_000).await;
    for id in [&claude, &codex] {
        until(&daemon.session(id).unwrap(), |c| c.status == Status::Offline).await;
        daemon.resume(id).await.ok();
        assert_eq!(last_start(&starts, id), Some(Some("400000".into())), "started again with the new window");
    }

    // Mid-turn: left to finish it, then started again with the new window for what was queued meanwhile.
    assert!(working.is_attached(), "not stopped mid-turn");
    assert!(daemon.next(&busy).is_some_and(|n| n.restart), "kept for the turn's end");
    daemon.queue(&busy, "and then this", &[]).unwrap();
    assert_eq!(last_start(&starts, &busy), Some(None));
    working.change(idle());
    for _ in 0..100 {
        if last_start(&starts, &busy) == Some(Some("400000".into())) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert_eq!(last_start(&starts, &busy), Some(Some("400000".into())), "started again as its turn ended");
    assert!(daemon.next(&busy).is_none());
    for _ in 0..100 {
        if sent.lock().unwrap().contains("and then this") {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(sent.lock().unwrap().contains("and then this"), "what was queued went to the new process");
    zerod::adapter::set_compact_window(None);
}

/// Between turns with the user's messages held (they stopped the turn): left running, so releasing them delivers them,
/// and started again with the new window once that turn ends.
#[tokio::test(start_paused = true)]
async fn a_held_queue_keeps_its_agent_until_its_next_turn_ends() {
    let _one = crate::common::COMPACT.lock().await;
    zerod::adapter::set_compact_window(None);
    let home = temp_dir("compact-window-held");
    let starts: Starts = Default::default();
    let sent = Arc::new(Mutex::new(String::new()));
    let daemon = Daemon::open(&home.join("zerod"), recording(starts.clone(), sent.clone())).unwrap();
    let options = zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() };
    let id = daemon.start(Provider::Claude, "hi", options).unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let session = daemon.session(&id).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    daemon.queue(&id, "held for later", &[]).unwrap();
    let _ = daemon.interrupt(&id).await;
    session.change(idle());
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert!(daemon.queued(&id).1, "held");

    zerod::adapter::set_compact_window(Some(400_000));
    daemon.compact_window_changed().await;
    assert!(session.is_attached(), "left running: a release only delivers to a running agent");
    assert!(daemon.next(&id).is_some_and(|n| n.restart));

    daemon.release(&id).unwrap();
    until(&session, |_| sent.lock().unwrap().contains("held for later")).await;
    session.change(Change::Status { status: Status::Working, turn: Some("t2".into()), error: None });
    session.change(idle());
    for _ in 0..100 {
        if last_start(&starts, &id) == Some(Some("400000".into())) || !session.is_attached() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(!session.is_attached() || last_start(&starts, &id) == Some(Some("400000".into())), "stopped for the new window");
    daemon.resume(&id).await.ok();
    assert_eq!(last_start(&starts, &id), Some(Some("400000".into())));
    zerod::adapter::set_compact_window(None);
}
