//! `zerod [--home DIR] [--socket PATH] [--cli-socket PATH] [--asks FILE] [--resources DIR]`: Zero's daemon. Sessions
//! live in ~/.zero/zerod and clients connect to ~/.zero/zerod.sock; the inbox keeps its log in asks.jsonl and serves the
//! `zero` CLI on zero.sock, both next to the home (so a test's home keeps them its own). One daemon per socket: a second
//! one finds the first answering and leaves.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tokio::net::UnixStream;
use tokio::signal::unix::{SignalKind, signal};
use zerod::inbox::Runtime;

unsafe extern "C" {
    safe fn setsid() -> i32;
}

#[tokio::main]
async fn main() {
    // A session of its own, so the app that started it quitting (or the terminal it ran in closing) doesn't end it.
    // From a shell it is already a group leader and this fails, harmlessly.
    setsid();
    let zero = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".zero");
    let (mut home, mut socket) = (zero.join("zerod"), zero.join("zerod.sock"));
    let (mut cli_socket, mut asks_log, mut resources): (Option<PathBuf>, Option<PathBuf>, Option<PathBuf>) = (None, None, None);
    let mut args = std::env::args().skip(1).peekable();
    // `zerod mcp`: the MCP server on stdio, for an agent, talking to the running zerod.
    let mcp = args.next_if_eq("mcp").is_some();
    while let Some(arg) = args.next() {
        match (arg.as_str(), args.next()) {
            ("--home", Some(value)) => home = value.into(),
            ("--socket", Some(value)) => socket = value.into(),
            ("--cli-socket", Some(value)) => cli_socket = Some(value.into()),
            ("--asks", Some(value)) => asks_log = Some(value.into()),
            ("--resources", Some(value)) => resources = Some(value.into()),
            _ => {
                eprintln!("usage: zerod [mcp] [--home DIR] [--socket PATH] [--cli-socket PATH] [--asks FILE] [--resources DIR]");
                std::process::exit(2);
            }
        }
    }
    if mcp { return zerod::mcp::serve(&socket).await }
    let beside = home.parent().map(PathBuf::from).unwrap_or_else(|| zero.clone());
    let cli_socket = cli_socket.unwrap_or_else(|| beside.join("zero.sock"));
    let asks_log = asks_log.unwrap_or_else(|| beside.join("asks.jsonl"));
    // Zero.app's Resources, beside the MacOS folder zerod is in: the drop clients.
    let resources = resources.unwrap_or_else(|| {
        std::env::current_exe().ok().and_then(|exe| exe.parent()?.parent().map(|contents| contents.join("Resources"))).unwrap_or_default()
    });
    if UnixStream::connect(&socket).await.is_ok() {
        eprintln!("zerod: already running on {}", socket.display());
        return;
    }
    // One daemon per home, however many start at once: two would serve the same inbox and deliver every answer twice.
    let _lock = match std::fs::create_dir_all(&home).and_then(|_| std::fs::File::create(home.join("zerod.lock"))) {
        Ok(file) if file.try_lock().is_ok() => file,
        _ => {
            eprintln!("zerod: another zerod has {}", home.display());
            return;
        }
    };
    let daemon = match zerod::daemon::Daemon::open(&home, zerod::daemon::real_runtime()) {
        Ok(daemon) => daemon,
        Err(error) => {
            eprintln!("zerod: can't open {}: {error}", home.display());
            std::process::exit(1);
        }
    };
    let runtimes: Vec<Arc<dyn Runtime>> = vec![
        Arc::new(zerod::daemon::Sessions::of(&daemon)), Arc::new(zerod::solo::Solo::installed()),
        Arc::new(zerod::rex::Rex::installed()), Arc::new(zerod::host::Host::installed()),
    ];
    let inbox = zerod::inbox::Inbox::open(Some(asks_log), runtimes);
    let drops = zerod::drops::Drops::new(inbox.clone(), resources);
    zerod::server::Settings::load(&home).apply(&inbox, Some(&drops));
    drops.start();
    zerod::bridge::Bridge::start(daemon.clone(), inbox.clone());
    let watched = Arc::downgrade(&inbox);
    // Which agents still run, for the bar's dots and for resuming one before a message.
    tokio::spawn(async move {
        while let Some(inbox) = watched.upgrade() {
            inbox.refresh_liveness().await;
            drop(inbox);
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    });
    let cli = inbox.clone();
    tokio::spawn(async move {
        if let Err(error) = zerod::cli::serve(cli, cli_socket).await { eprintln!("zerod: the CLI socket stopped: {error}") }
    });
    let mut terminate = signal(SignalKind::terminate()).expect("a SIGTERM handler");
    eprintln!("zerod: {} sessions, listening on {}", daemon.list().len(), socket.display());
    let integrations = zerod::integrations::Integrations::open(&home, Arc::new(zerod::integrations::Commands::default()));
    let pads = Arc::new(zerod::pads::Pads::open(&beside.join("scratchpads")));
    let places = Arc::new(zerod::board::Places::default());
    tokio::spawn(places.clone().follow(home.clone()));
    let zerod = zerod::server::Zerod { daemon: daemon.clone(), inbox, drops: Some(drops), integrations, pads, places, notices: tokio::sync::broadcast::channel(64).0 };
    // Codex processes end with the daemon: their input closes when it exits.
    tokio::select! {
        served = zerod::server::serve(zerod, socket.clone()) => if let Err(error) = served { eprintln!("zerod: {error}"); std::process::exit(1) },
        _ = terminate.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    let _ = std::fs::remove_file(&socket);
}
