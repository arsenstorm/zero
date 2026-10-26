//! `zerod [--home DIR] [--socket PATH]`: Zero's daemon. Sessions live in ~/.zero/zerod and clients connect to
//! ~/.zero/zerod.sock. One daemon per socket: a second one finds the first answering and leaves.

use std::path::PathBuf;

use tokio::net::UnixStream;
use tokio::signal::unix::{SignalKind, signal};

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
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match (arg.as_str(), args.next()) {
            ("--home", Some(value)) => home = value.into(),
            ("--socket", Some(value)) => socket = value.into(),
            _ => {
                eprintln!("usage: zerod [--home DIR] [--socket PATH]");
                std::process::exit(2);
            }
        }
    }
    if UnixStream::connect(&socket).await.is_ok() {
        eprintln!("zerod: already running on {}", socket.display());
        return;
    }
    let daemon = match zerod::daemon::Daemon::open(&home, zerod::daemon::real_runtime()) {
        Ok(daemon) => daemon,
        Err(error) => {
            eprintln!("zerod: can't open {}: {error}", home.display());
            std::process::exit(1);
        }
    };
    let mut terminate = signal(SignalKind::terminate()).expect("a SIGTERM handler");
    eprintln!("zerod: {} sessions, listening on {}", daemon.list().len(), socket.display());
    // Codex processes end with the daemon: their input closes when it exits.
    tokio::select! {
        served = zerod::server::serve(daemon, socket.clone()) => if let Err(error) = served { eprintln!("zerod: {error}"); std::process::exit(1) },
        _ = terminate.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    let _ = std::fs::remove_file(&socket);
}
