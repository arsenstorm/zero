//! A task opened in its CLI's own terminal (zero-host), and back to Zero.

use super::*;

impl Daemon {
    /// Hands the task to its provider's own terminal, on its own thread: Zero's headless process stops first, so only
    /// one of them ever writes to the thread. Watched until its program ends, which brings the task back.
    pub async fn open_terminal(&self, id: &str) -> Result<String, String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        if let Some(open) = &conversation.terminal {
            return Ok(open.id.clone());
        }
        if matches!(conversation.status, Status::Working | Status::Waiting) {
            return Err(format!("{} is working; stop its turn first", conversation.provider.title()));
        }
        let argv = terminal_command(&conversation, &crate::git::variables(Path::new(&conversation.cwd)))?;
        self.take_offline(&session).await;
        let mark = match conversation.provider {
            Provider::Claude => std::fs::read_to_string(self.claude_file(&conversation)).map(|text| text.lines().count()).unwrap_or(0),
            _ => 0,
        };
        let terminal = self.host().open(&conversation.cwd, &argv, &crate::bridge::label(&conversation)).await?;
        session.change(Change::Terminal { terminal: Some(Opened { id: terminal.clone(), mark }) });
        let (weak, task, watched) = (self.me.clone(), id.to_string(), terminal.clone());
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(2)).await;
                let Some(daemon) = weak.upgrade() else { return };
                if daemon.get(&task).and_then(|c| c.terminal).map(|t| t.id) != Some(watched.clone()) {
                    return;
                }
                if matches!(
                    crate::terminal::Terminal::state(&daemon.host(), &watched).await,
                    crate::terminal::State::Exited | crate::terminal::State::Missing
                ) {
                    if let Err(error) = daemon.close_terminal(&task).await {
                        eprintln!("zerod: {task} came back from its terminal badly: {error}")
                    }
                    return;
                }
            }
        });
        Ok(terminal)
    }

    /// Back from the provider's terminal: it closes, what happened there joins the task's record, and Zero's UI has the
    /// task again (the next message resumes the provider headless on the same thread).
    pub async fn close_terminal(&self, id: &str) -> Result<(), String> {
        let session = self.session(id)?;
        let conversation = session.snapshot();
        let Some(open) = conversation.terminal.clone() else { return Ok(()) };
        self.host().shut(&open.id).await;
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
                // Codex lets go of the thread once its terminal's program has exited, a moment after it's told to.
                // ponytail: two more tries over about 4 s; zero-host saying when the program is gone would make it exact.
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
        Ok(())
    }
}

/// The task's terminal command, with `vars` (Settings › Git's) handed over by `env` in front of it: zero-host starts
/// a terminal with an environment of its own, so nothing of zerod's reaches the agent otherwise.
pub fn terminal_command(conversation: &crate::model::Conversation, vars: &[(String, String)]) -> Result<Vec<String>, String> {
    let mut argv = conversation.provider.terminal(conversation)?;
    if !vars.is_empty() {
        // After the login shell's own words ("/bin/zsh -lic 'exec "$@"' zsh"), before the program.
        let at = argv.iter().position(|a| a == "zsh").map_or(0, |i| i + 1);
        argv.splice(at..at, std::iter::once("env".to_string()).chain(vars.iter().map(|(k, v)| format!("{k}={v}"))));
    }
    Ok(argv)
}
