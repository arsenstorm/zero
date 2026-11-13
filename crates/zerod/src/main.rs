//! `zerod [--home DIR] [--socket PATH] [--cli-socket PATH] [--asks FILE]`: Zero's daemon. Sessions
//! live in ~/.zero/zerod and clients connect to ~/.zero/zerod.sock; the inbox keeps its log in asks.jsonl and serves the
//! `zero` CLI on zero.sock, both next to the home (so a test's home keeps them its own). One daemon per socket: a second
//! one finds the first answering and leaves.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use tokio::net::UnixStream;
use tokio::signal::unix::{SignalKind, signal};
use zerod::inbox::Runtime;

unsafe extern "C" {
    safe fn setsid() -> i32;
    fn dup2(from: i32, to: i32) -> i32;
    fn getrlimit(resource: i32, limits: *mut [u64; 2]) -> i32;
    fn setrlimit(resource: i32, limits: *const [u64; 2]) -> i32;
}

/// Descriptors up to the hard limit (macOS takes no more than OPEN_MAX): started by the app, zerod has its 256, and
/// two pipes an agent, their transcripts and every client's connection ran it out, failing accepts and spawns.
fn more_descriptors() {
    const RLIMIT_NOFILE: i32 = 8;
    const OPEN_MAX: u64 = 10240;
    let mut limits = [0u64; 2];
    // Safety: both read or write the two u64s of an rlimit, which `limits` is.
    unsafe {
        if getrlimit(RLIMIT_NOFILE, &mut limits) == 0 {
            limits[0] = limits[0].max(limits[1].min(OPEN_MAX));
            setrlimit(RLIMIT_NOFILE, &limits);
        }
    }
}

#[tokio::main]
async fn main() {
    // A session of its own, so the app that started it quitting (or the terminal it ran in closing) doesn't end it.
    // From a shell it is already a group leader and this fails, harmlessly.
    setsid();
    more_descriptors();
    let zero = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".zero");
    let mut args = std::env::args().skip(1).peekable();
    // `zerod mcp`: the MCP server on stdio, for an agent, talking to the running zerod.
    let mcp = args.next_if_eq("mcp").is_some();
    // Started by Chrome as Zero for Chrome's native host (its origin first, then Chrome's own arguments), or by Firefox
    // (the host manifest's path, then the extension's id).
    if args.peek().is_some_and(|a| a.starts_with("chrome-extension://") || a.ends_with(&format!("/{}.json", zerod::browser::HOST))) {
        zerod::browser::host(tokio::io::stdin(), tokio::io::stdout(), zero.join("zerod.sock")).await;
        // Out at once: the runtime would otherwise wait on its blocking read of Chrome's stdin, which Chrome keeps open.
        std::process::exit(0);
    }
    // `zerod mcp lazy <command> <args…>`: standing in for an MCP server until it's first used (mcp_lazy.rs).
    if mcp && args.next_if_eq("lazy").is_some() {
        let Some(command) = args.next() else { return eprintln!("usage: zerod mcp lazy <command> [args…]") };
        return zerod::mcp_lazy::serve(command, args.collect()).await;
    }
    // Started by launchd as the LaunchAgent (launchd.rs): no one reads its output, so it goes to the log.
    let launchd = args.next_if_eq("--launchd").is_some();
    let args = Args::parse(args, &zero);
    if mcp {
        return zerod::mcp::serve(&args.socket).await;
    }
    if launchd {
        log_to(&args.beside.join("zerod.log"));
    }
    // launchd's is started as the one before leaves for it, and waits for its home; any other leaves at once.
    let waited = if launchd { lock_within(&args.home, Duration::from_secs(10)).await } else { None };
    if UnixStream::connect(&args.socket).await.is_ok() {
        eprintln!("zerod: already running on {}", args.socket.display());
        return;
    }
    let Some(_lock) = waited.or_else(|| lock(&args.home)) else {
        eprintln!("zerod: another zerod has {}", args.home.display());
        return;
    };
    zerod::self_check::at_start(&args.home);
    let daemon = open_daemon(&args.home);
    let inbox = open_inbox(&daemon, &args);
    keep_liveness(&inbox);
    let (cli, cli_socket) = (inbox.clone(), args.cli_socket.clone());
    tokio::spawn(async move {
        if let Err(error) = zerod::cli::serve(cli, cli_socket).await {
            eprintln!("zerod: the CLI socket stopped: {error}")
        }
    });
    let mut terminate = signal(SignalKind::terminate()).expect("a SIGTERM handler");
    eprintln!("zerod: {} sessions, listening on {}", daemon.list().len(), args.socket.display());
    let zerod = zerod_for(&args, &daemon, inbox);
    tokio::spawn(zerod::server::archive_completed(zerod.clone()));
    tokio::spawn(zerod::uses::follow(daemon.clone()));
    tokio::spawn(zerod::left::follow(daemon.clone()));
    let (named, notices) = (daemon.clone(), zerod.notices.clone());
    tokio::spawn(async move { zerod::server::name_codex_accounts(&named, &notices).await });
    // Codex processes end with the daemon: their input closes when it exits.
    tokio::select! {
        served = zerod::server::serve(zerod, args.socket.clone()) => if let Err(error) = served { eprintln!("zerod: {error}"); std::process::exit(1) },
        _ = terminate.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    let _ = std::fs::remove_file(&args.socket);
}

/// The sessions in `home`, the turns a restart paused carrying on; zerod ends if they can't be read.
fn open_daemon(home: &Path) -> Arc<zerod::daemon::Daemon> {
    zerod::stuck::open(home);
    let daemon = match zerod::daemon::Daemon::open(home, zerod::daemon::real_runtime()) {
        Ok(daemon) => daemon,
        Err(error) => {
            eprintln!("zerod: can't open {}: {error}", home.display());
            std::process::exit(1);
        }
    };
    // After a restart: the turns it paused carry on.
    daemon.take_over();
    daemon.carry_on();
    // Every task's turns end on Zero's ending, whichever agent runs it: one that doesn't is sent back once.
    daemon.require_endings();
    daemon.name_tasks();
    daemon
}

/// The inbox with every runtime its agents run in, and the bridge from tasks to it.
fn open_inbox(daemon: &Arc<zerod::daemon::Daemon>, args: &Args) -> Arc<zerod::inbox::Inbox> {
    let runtimes: Vec<Arc<dyn Runtime>> = vec![Arc::new(zerod::daemon::Sessions::of(daemon))];
    let inbox = zerod::inbox::Inbox::open(Some(args.asks_log.clone()), runtimes);
    let settings = zerod::server::Settings::load(&args.home);
    settings.apply(&inbox);
    settings.apply_git(&args.home);
    zerod::bridge::Bridge::start(daemon.clone(), inbox.clone());
    zerod::mcp_auth::start(daemon.clone(), inbox.clone());
    zerod::recap::start(daemon.clone(), inbox.clone());
    zerod::server::hold_while_blocked(daemon, &inbox);
    zerod::server::know_what_wakes(daemon, &inbox);
    zerod::server::know_workers(daemon, &inbox);
    zerod::server::link_asks(daemon, &inbox);
    inbox
}

/// What a connection reaches, each part opened from where it's kept, and what follows on its own set going.
fn zerod_for(args: &Args, daemon: &Arc<zerod::daemon::Daemon>, inbox: Arc<zerod::inbox::Inbox>) -> zerod::server::Zerod {
    let (home, beside) = (&args.home, &args.beside);
    let integrations = zerod::integrations::Integrations::open(home, Arc::new(zerod::integrations::Commands::default()));
    let pads = Arc::new(zerod::pads::Pads::open(&beside.join("scratchpads")));
    let later = Arc::new(zerod::later::Later::open(&beside.join("later")));
    let loops = Arc::new(zerod::loops::Loops::open(&beside.join("loops")));
    let following = zerod::following::Following::open(home, Arc::new(zerod::integrations::Commands::default()), integrations.clone());
    daemon.set_following(following.clone());
    poll_following(following.clone(), daemon.clone());
    let browsers = open_browsers(home);
    browsers.follow(daemon.clone(), inbox.clone());
    let places = Arc::new(zerod::board::Places::default());
    tokio::spawn(places.clone().follow(home.clone()));
    zerod::server::Zerod {
        daemon: daemon.clone(),
        inbox,
        integrations,
        pads,
        later,
        loops,
        following,
        browsers,
        places,
        notices: tokio::sync::broadcast::channel(64).0,
    }
}

/// Where this zerod keeps its sessions and serves them, from its flags; the rest beside its home.
struct Args {
    home: PathBuf,
    socket: PathBuf,
    cli_socket: PathBuf,
    asks_log: PathBuf,
    /// The folder the home is in: the `zero` CLI's socket, the inbox's log, scratchpads, later and loops by default.
    beside: PathBuf,
}

impl Args {
    /// Every flag takes a value; anything else is a usage error.
    fn parse(mut args: impl Iterator<Item = String>, zero: &Path) -> Args {
        let (mut home, mut socket) = (zero.join("zerod"), zero.join("zerod.sock"));
        let (mut cli_socket, mut asks_log): (Option<PathBuf>, Option<PathBuf>) = (None, None);
        while let Some(arg) = args.next() {
            match (arg.as_str(), args.next()) {
                ("--home", Some(value)) => home = value.into(),
                ("--socket", Some(value)) => socket = value.into(),
                ("--cli-socket", Some(value)) => cli_socket = Some(value.into()),
                ("--asks", Some(value)) => asks_log = Some(value.into()),
                _ => {
                    eprintln!("usage: zerod [mcp] [--home DIR] [--socket PATH] [--cli-socket PATH] [--asks FILE]");
                    std::process::exit(2);
                }
            }
        }
        let beside = home.parent().map(PathBuf::from).unwrap_or_else(|| zero.to_path_buf());
        Args {
            cli_socket: cli_socket.unwrap_or_else(|| beside.join("zero.sock")),
            asks_log: asks_log.unwrap_or_else(|| beside.join("asks.jsonl")),
            home,
            socket,
            beside,
        }
    }
}

/// One daemon per home, however many start at once: two would serve the same inbox and deliver every answer twice.
/// The home's lock, held while it's kept; none, another zerod has it.
fn lock(home: &Path) -> Option<std::fs::File> {
    let file = std::fs::create_dir_all(home).and_then(|_| std::fs::File::create(home.join("zerod.lock"))).ok()?;
    file.try_lock().is_ok().then_some(file)
}

/// The home's lock once whoever holds it lets go, within `wait`.
async fn lock_within(home: &Path, wait: Duration) -> Option<std::fs::File> {
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        if let Some(file) = lock(home) {
            return Some(file);
        }
        if tokio::time::Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// stdout and stderr appended to `log`, as the app has them when it starts zerod.
fn log_to(log: &Path) {
    use std::os::fd::AsRawFd;
    let _ = std::fs::create_dir_all(log.parent().unwrap_or(log));
    let Ok(file) = std::fs::OpenOptions::new().create(true).append(true).open(log) else { return };
    // Safety: both descriptors are open; the file's own closes when it drops, the duplicates stay.
    unsafe {
        dup2(file.as_raw_fd(), 1);
        dup2(file.as_raw_fd(), 2);
    }
}

/// Which agents still run, for the bar's dots and for resuming one before a message: looked at every 5 seconds.
fn keep_liveness(inbox: &Arc<zerod::inbox::Inbox>) {
    let watched = Arc::downgrade(inbox);
    tokio::spawn(async move {
        while let Some(inbox) = watched.upgrade() {
            inbox.refresh_liveness().await;
            drop(inbox);
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    });
}

/// What tasks follow, polled every 5 seconds, each change told to its task: held a while for one between turns.
fn poll_following(poller: Arc<zerod::following::Following>, polled: Arc<zerod::daemon::Daemon>) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            poller
                .tick(
                    |id| polled.exists(id),
                    |id| polled.summary(id).is_none_or(|c| c.status != zerod::model::Status::Working),
                    |id, words, heard| match heard {
                        zerod::following::Heard::Own => polled.say_quietly(id, words),
                        zerod::following::Heard::News => {
                            if let Err(error) = polled.notify(id, words) {
                                eprintln!("zerod: couldn't tell {id} what it follows changed: {error}")
                            }
                        }
                    },
                )
                .await;
        }
    });
}

/// The browsers tasks use: Chrome opened by a call that finds it closed (behind what the user's doing), Safari, and
/// Firefox Developer Edition under remote control with Zero's extension from the app's resources.
fn open_browsers(home: &Path) -> Arc<zerod::browser::Browsers> {
    let browsers = zerod::browser::Browsers::open(home);
    browsers.set_launcher(zerod::browser::Browsers::chrome());
    if let Ok(exe) = std::env::current_exe()
        && exe.starts_with("/Applications")
    {
        let _ = zerod::browser::install_firefox(&exe);
    }
    let firefox_extension =
        std::env::current_exe().ok().and_then(|exe| Some(exe.parent()?.parent()?.join("Resources/firefox"))).unwrap_or_default();
    browsers.set_safari(zerod::safari::Safari::new(Some(home.join("safari-session"))));
    browsers.set_firefox(zerod::firefox::Firefox::new(
        &format!("127.0.0.1:{}", zerod::firefox::PORT),
        firefox_extension,
        Some(zerod::firefox::Firefox::launcher()),
        Some(home.join("firefox-session")),
    ));
    browsers
}
