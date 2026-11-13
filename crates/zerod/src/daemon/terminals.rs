//! A task opened in the user's own terminal app, on its CLI's own resume (`claude --resume`, `codex resume`,
//! `opencode --session`), and back to Zero once that CLI exits.

use super::*;

/// Opens a script in the user's terminal app (its name, or an .app's path).
pub type Opener = Arc<dyn Fn(&str, &Path) -> Result<(), String> + Send + Sync>;

/// The script in a new window of `app`: Terminal and iTerm run a .command file they're given (`open -a`). Ghostty asks
/// before running one given that way, so it's given the script as its command instead, in a window of its own that
/// quits once the script ends.
pub(super) fn open_app() -> Opener {
    Arc::new(|app, script| {
        let args = open_args(app, script);
        let opened = std::process::Command::new("/usr/bin/open")
            .args(&args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map_err(|e| format!("Couldn't open {app}: {e}"))?;
        if opened.success() { Ok(()) } else { Err(format!("Couldn't open {app}")) }
    })
}

/// `open`'s arguments for running `script` in `app` (its name, or an .app's path).
pub fn open_args(app: &str, script: &Path) -> Vec<String> {
    let script = script.to_string_lossy().into_owned();
    if app.trim_end_matches('/').trim_end_matches(".app").ends_with("Ghostty") {
        return ["-na", app, "--args", "--quit-after-last-window-closed=true", "-e", &script].map(String::from).to_vec();
    }
    ["-a", app, &script].map(String::from).to_vec()
}

/// How long the terminal app has to start the script, in milliseconds.
static WAIT: AtomicU64 = AtomicU64::new(30_000);

/// How long the terminal app has to start the script, for a test's own.
pub fn set_terminal_wait(wait: Duration) {
    WAIT.store(wait.as_millis() as u64, Ordering::Relaxed)
}

/// Unset in Settings: Ghostty where it's installed, else the Mac's own Terminal.
pub fn default_terminal(installed: impl Fn(&str) -> bool) -> &'static str {
    if installed("Ghostty") { "Ghostty" } else { "Terminal" }
}

/// The app tasks open in: the user's setting, else the default.
pub fn terminal_app(home: &Path) -> String {
    crate::server::Settings::load(home).terminal.unwrap_or_else(|| default_terminal(installed).into())
}

fn installed(app: &str) -> bool {
    let home = std::env::var("HOME").unwrap_or_default();
    [format!("/Applications/{app}.app"), format!("{home}/Applications/{app}.app")].iter().any(|path| Path::new(path).exists())
}

/// `text` as one word to the shell.
pub fn quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// What the terminal runs: its process id where zerod watches it, the task's folder, Zero's variables for the task's
/// CLI (its sign-in among them: the file is the user's alone, and removes itself as it starts), then the CLI's own
/// resume. Once the CLI exits, the id file goes and the task is Zero's again.
pub fn terminal_script(conversation: &Conversation, env: &[(String, String)], pid: &Path) -> Result<String, String> {
    let argv = conversation.provider.terminal(conversation)?;
    let pid = quoted(&pid.to_string_lossy());
    let title = conversation.title.clone().unwrap_or_else(|| conversation.provider.title().to_string());
    let mut script = format!(
        "#!/bin/zsh\nrm -f \"$0\"\necho $$ > {pid}\nprintf '\\e]0;%s\\a' {}\ncd {} || exit 1\nunset {}\n",
        quoted(&title),
        quoted(&conversation.cwd),
        process::LEFT_OUT.join(" ")
    );
    for (name, value) in env {
        script += &format!("export {name}={}\n", quoted(value));
    }
    script += &argv.iter().map(|a| quoted(a)).collect::<Vec<_>>().join(" ");
    // A CLI that ended badly (not found, say) leaves its words up until Return.
    script += &format!(
        "\ncode=$?\nrm -f {pid}\necho\nif [ $code = 0 ]; then echo 'Back in Zero.'; else echo \"Exited with $code; back in Zero. Return closes this.\"; read -r; fi\n"
    );
    Ok(script)
}

impl Daemon {
    /// Hands the task to its CLI in the user's terminal app, on its own thread: a turn under way is interrupted and
    /// Zero's process stopped first, so only one of them ever writes to the thread. Watched until the CLI exits, which
    /// brings the task back. Gives the CLI's process id.
    pub async fn open_terminal(&self, id: &str) -> Result<String, String> {
        let session = self.session(id)?;
        if let Some(open) = session.snapshot().terminal {
            return Ok(open.id);
        }
        if session.is_attached() && busy(session.summary().attention()) {
            let _ = tokio::time::timeout(Duration::from_secs(5), session.interrupt()).await;
        }
        self.take_offline(&session).await;
        let conversation = session.snapshot();
        self.mcp_for(&conversation)?;
        let mut env: Vec<(String, String)> =
            process::environment(std::iter::empty(), id).into_iter().filter(|(name, _)| name != "PATH" && name != "TERM").collect();
        env.extend(crate::git::variables(Path::new(&conversation.cwd)));
        let (script_file, pid_file) = self.terminal_files(id);
        std::fs::create_dir_all(script_file.parent().unwrap_or(&self.home)).map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(&pid_file);
        let script = terminal_script(&conversation, &env, &pid_file)?;
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let _ = std::fs::remove_file(&script_file);
            let mut file =
                std::fs::OpenOptions::new().write(true).create_new(true).mode(0o700).open(&script_file).map_err(|e| e.to_string())?;
            file.write_all(script.as_bytes()).map_err(|e| e.to_string())?;
        }
        let mark = match conversation.provider {
            Provider::Claude => std::fs::read_to_string(self.claude_file(&conversation)).map(|text| text.lines().count()).unwrap_or(0),
            _ => 0,
        };
        let app = terminal_app(&self.home);
        let opener = self.terminal_opener.lock().unwrap().clone();
        let started = opener(&app, &script_file);
        let deadline = tokio::time::Instant::now() + Duration::from_millis(WAIT.load(Ordering::Relaxed));
        let pid = loop {
            if let Some(pid) = read_pid(&pid_file) {
                break pid;
            }
            if started.is_err() || tokio::time::Instant::now() >= deadline {
                let _ = std::fs::remove_file(&script_file);
                started?;
                return Err(format!("{app} didn't start {}", conversation.provider.title()));
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        };
        session.change(Change::Terminal { terminal: Some(Opened { id: pid.to_string(), mark }) });
        self.watch_terminal(id);
        Ok(pid.to_string())
    }

    /// Back from the terminal: a CLI still running there is ended (as closing its window would), what happened there
    /// joins the task's record, and the task is Zero's again; words that waited for it go.
    pub async fn close_terminal(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        let Some(open) = conversation.terminal.clone() else { return Ok(()) };
        if self.terminal_running(id, &open)
            && let Ok(pid) = open.id.parse::<u32>()
        {
            let tree = crate::runs::tree(pid);
            for &p in tree.iter().rev() {
                crate::runs::signal(p, "-HUP");
            }
            for _ in 0..20 {
                if !alive(pid) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            for &p in &tree {
                if alive(p) {
                    crate::runs::signal(p, "-KILL");
                }
            }
        }
        let _ = std::fs::remove_file(self.terminal_files(id).1);
        session.change(Change::Terminal { terminal: None });
        match conversation.provider {
            Provider::Claude => {
                let text = std::fs::read_to_string(self.claude_file(&conversation)).unwrap_or_default();
                let records: Vec<serde_json::Value> =
                    text.lines().skip(open.mark).filter_map(|line| serde_json::from_str(line).ok()).collect();
                for item in crate::handoff::from_claude_session(&records) {
                    session.change(Change::Item { item })
                }
            }
            Provider::Codex => {
                // Codex lets go of the thread a moment after its terminal's program has exited.
                // ponytail: two more tries over about 4 s, should it still hold it.
                tokio::time::sleep(Duration::from_secs(1)).await;
                let mut tries = 0;
                loop {
                    match self.resume(id).await {
                        Err(error) if error.contains("active writer") && tries < 2 => {
                            tries += 1;
                            tokio::time::sleep(Duration::from_secs(2)).await
                        }
                        resumed => break resumed?,
                    }
                }
                crate::codex::catch_up(&session).await?;
            }
            // ponytail: OpenCode's terminal turns stay in OpenCode until its session export is read back.
            Provider::Opencode => {}
        }
        if self.pending.lock().unwrap().get(id).is_some_and(|words| !words.is_empty()) && !session.is_attached() {
            self.resume(id).await?;
        }
        Ok(())
    }

    /// Every task open in a terminal watched again: after a restart, its CLI may have exited while no zerod looked.
    pub(super) fn watch_terminals(&self) {
        for conversation in self.list() {
            if conversation.terminal.is_some() {
                self.watch_terminal(&conversation.id)
            }
        }
    }

    /// Looks every second until the task's CLI exits in its terminal, then brings the task back.
    fn watch_terminal(&self, id: &str) {
        let (weak, id) = (self.me.clone(), id.to_string());
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let Some(daemon) = weak.upgrade() else { return };
                let Some(open) = daemon.get(&id).and_then(|c| c.terminal) else { return };
                if daemon.terminal_running(&id, &open) {
                    continue;
                }
                if let Err(error) = daemon.close_terminal(&id).await {
                    eprintln!("zerod: {id} came back from its terminal badly: {error}")
                }
                return;
            }
        });
    }

    /// The task's script, and the file its process id is in while its CLI runs.
    fn terminal_files(&self, id: &str) -> (PathBuf, PathBuf) {
        let dir = self.home.join("terminals");
        (dir.join(format!("{id}.command")), dir.join(format!("{id}.pid")))
    }

    fn terminal_running(&self, id: &str, open: &Opened) -> bool {
        self.terminal_files(id).1.exists() && open.id.parse().is_ok_and(alive)
    }
}

fn read_pid(file: &Path) -> Option<u32> {
    std::fs::read_to_string(file).ok()?.trim().parse().ok()
}

unsafe extern "C" {
    safe fn kill(pid: i32, signal: i32) -> i32;
}

fn alive(pid: u32) -> bool {
    kill(pid as i32, 0) == 0
}
