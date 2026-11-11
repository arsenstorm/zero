//! Signing in to remote MCP servers a task's CLI says need it (their OAuth), the CLI's own servers and Zero's alike. The
//! CLI signs in, never Zero: a short-lived CLI of Zero's (claude -p, codex app-server) is asked for its sign-in link
//! and hears the callback itself, so it doesn't matter whether the task that wanted it is still running. Once per
//! server per zerod: its link goes to the user in the inbox (one ask, whichever tasks want it) and in each task that
//! wants it; the ask is taken back once the server connects, and the tasks reconnect it. Settings' Sign in starts one
//! whenever the user asks.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use serde_json::json;

use crate::ask::{Ask, AskKind};
use crate::inbox::Inbox;
use crate::model::{Change, Conversation, Item, ItemKind, ItemStatus, Provider};

/// How long a sign-in waits for the user in the browser before it's let go.
pub const SIGN_IN_TIME: Duration = Duration::from_secs(15 * 60);

/// A sign-in to run: the server, and the CLI it's for as the task that wanted it runs (its folder, which has its
/// project's servers, its account's environment, Zero's servers).
#[derive(Clone)]
pub struct Job {
    pub server: String,
    pub provider: Provider,
    pub cwd: String,
    pub env: Vec<(String, String)>,
    pub mcp: Vec<crate::mcp_servers::Resolved>,
}

/// Runs a sign-in: its link to `page` as soon as there is one, then done once the server has signed in. A stand-in in
/// tests.
pub type Runner = Arc<dyn Fn(Job, tokio::sync::oneshot::Sender<String>) -> crate::inbox::Fut<'static, Result<(), String>> + Send + Sync>;

/// What a task that wanted a server hears of its sign-in.
#[derive(Debug)]
pub enum News<'a> {
    Link(&'a str),
    SignedIn,
    Failed(&'a str),
}

/// Tells a task (by id) about a server's sign-in.
pub type Tell = Box<dyn Fn(&str, &str, News) + Send + Sync>;

#[derive(Default)]
struct Attempt {
    /// The tasks that wanted it, to tell.
    sessions: Vec<String>,
    url: Option<String>,
    /// The inbox's ask for it, while open.
    ask: Option<String>,
    /// Ended (signed in, failed or let go): not started again unless the user asks.
    over: bool,
}

pub struct McpAuth {
    run: Runner,
    inbox: OnceLock<(Arc<Inbox>, Tell)>,
    attempts: Mutex<HashMap<String, Attempt>>,
    me: Weak<McpAuth>,
}

impl McpAuth {
    pub fn new(run: Runner) -> Arc<McpAuth> {
        Arc::new_cyclic(|me| McpAuth { run, inbox: OnceLock::new(), attempts: Mutex::default(), me: me.clone() })
    }

    /// Where its asks go, and how tasks are told: given once.
    pub fn attach(&self, inbox: Arc<Inbox>, tell: Tell) {
        let _ = self.inbox.set((inbox, tell));
    }

    /// A task's CLI says `job.server` needs signing in: signed in to the first time this zerod hears of it; a task that
    /// wants one under way is shown its link.
    pub fn wanted(&self, conversation: &Conversation, job: Job) {
        let server = job.server.clone();
        let link = {
            let mut attempts = self.attempts.lock().unwrap();
            let fresh = !attempts.contains_key(&server);
            let attempt = attempts.entry(server.clone()).or_default();
            if attempt.over {
                return;
            }
            if !attempt.sessions.contains(&conversation.id) {
                attempt.sessions.push(conversation.id.clone())
            }
            if fresh {
                drop(attempts);
                let agent = crate::bridge::identity(conversation, &crate::bridge::hostname());
                self.start(job, Some(agent));
                return;
            }
            attempt.url.clone()
        };
        if let (Some(url), Some((_, tell))) = (link, self.inbox.get()) {
            tell(&conversation.id, &server, News::Link(&url))
        }
    }

    /// Settings' Sign in: the link of the sign-in under way, else a new one's (the user is there: no ask).
    pub async fn sign_in(&self, job: Job) -> Result<String, String> {
        {
            let mut attempts = self.attempts.lock().unwrap();
            let attempt = attempts.entry(job.server.clone()).or_default();
            if !attempt.over
                && let Some(url) = &attempt.url
            {
                return Ok(url.clone());
            }
            *attempt = Attempt::default();
        }
        let server = job.server.clone();
        self.start(job, None);
        for _ in 0..300 {
            {
                let attempts = self.attempts.lock().unwrap();
                let attempt = attempts.get(&server);
                if let Some(url) = attempt.and_then(|a| a.url.clone()) {
                    return Ok(url);
                }
                if attempt.is_some_and(|a| a.over) {
                    return Err(format!("{server} didn't give a sign-in link"));
                }
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        Err(format!("{server} didn't give a sign-in link"))
    }

    /// Runs a sign-in: its link to the user (an ask for `agent`'s, none from Settings) and the tasks; its end takes the
    /// ask back and tells them.
    fn start(&self, job: Job, agent: Option<crate::ask::AgentIdentity>) {
        let (me, server) = (self.me.clone(), job.server.clone());
        let (page, opened) = tokio::sync::oneshot::channel();
        let running = (self.run)(job, page);
        let linked = me.clone();
        let named = server.clone();
        tokio::spawn(async move {
            if let (Ok(url), Some(me)) = (opened.await, linked.upgrade()) {
                me.linked(&named, &url, agent)
            }
        });
        tokio::spawn(async move {
            let outcome = tokio::time::timeout(SIGN_IN_TIME, running).await.unwrap_or_else(|_| Err("the sign-in wasn't finished".into()));
            if let Some(me) = me.upgrade() {
                me.ended(&server, outcome)
            }
        });
    }

    fn linked(&self, server: &str, url: &str, agent: Option<crate::ask::AgentIdentity>) {
        let sessions = {
            let mut attempts = self.attempts.lock().unwrap();
            let attempt = attempts.entry(server.into()).or_default();
            attempt.url = Some(url.into());
            attempt.sessions.clone()
        };
        let Some((inbox, tell)) = self.inbox.get() else { return };
        if let Some(agent) = agent {
            let mut ask = Ask::new(AskKind::Approve, &format!("Sign in to {server}?"), agent, SIGN_IN_TIME.as_secs() as i64);
            ask.body = format!(
                "Tasks can't use {server}'s tools until you sign in to it on this Mac: [open its sign-in page]({url}). \
                 This goes once it's signed in."
            );
            ask.options = vec!["Open the sign-in page".into(), "Not now".into()];
            ask.link = Some(url.into());
            let id = inbox.create(ask, false).id;
            self.attempts.lock().unwrap().entry(server.into()).or_default().ask = Some(id);
        }
        for session in &sessions {
            tell(session, server, News::Link(url))
        }
    }

    fn ended(&self, server: &str, outcome: Result<(), String>) {
        let (ask, sessions) = {
            let mut attempts = self.attempts.lock().unwrap();
            let attempt = attempts.entry(server.into()).or_default();
            attempt.over = true;
            (attempt.ask.take(), attempt.sessions.clone())
        };
        let Some((inbox, tell)) = self.inbox.get() else { return };
        if let Some(id) = ask {
            let reason = match &outcome {
                Ok(()) => "Signed in".to_string(),
                Err(error) => format!("Couldn't sign in: {error}"),
            };
            inbox.withdraw(&id, Some(&reason))
        }
        for session in &sessions {
            match &outcome {
                Ok(()) => tell(session, server, News::SignedIn),
                Err(error) => tell(session, server, News::Failed(error)),
            }
        }
    }
}

/// The real sign-ins: the task's CLI, run by Zero for as long as the sign-in takes.
pub fn runner() -> Runner {
    Arc::new(|job: Job, page| {
        Box::pin(async move {
            match job.provider {
                Provider::Claude => {
                    let config = crate::claude::mcp_config(&job.mcp).map(|(config, _)| config);
                    let command = crate::claude_login::mcp_command(config.as_deref());
                    crate::claude_login::mcp_sign_in(&command, &job.env, &job.cwd, &job.server, page, Duration::from_secs(3)).await
                }
                Provider::Codex => {
                    // Zero's servers at a URL, as Codex is given them (their headers aren't for the command line).
                    let mut args = vec!["codex".to_string(), "app-server".to_string()];
                    for server in job.mcp.iter().filter(|s| s.command.is_none()) {
                        if let Some(url) = &server.url {
                            args.extend(["-c".into(), format!("mcp_servers.{}.url={}", server.id, json!(url))])
                        }
                    }
                    let argv = crate::adapter::login_shell(&args.iter().map(String::as_str).collect::<Vec<_>>());
                    let mut child = tokio::process::Command::new(&argv[0])
                        .args(&argv[1..])
                        .envs(job.env.iter().cloned())
                        .current_dir(&job.cwd)
                        .stdin(std::process::Stdio::piped())
                        .stdout(std::process::Stdio::piped())
                        .stderr(std::process::Stdio::null())
                        .kill_on_drop(true)
                        .spawn()
                        .map_err(|e| format!("Couldn't start Codex: {e}"))?;
                    let (Some(input), Some(output)) = (child.stdin.take(), child.stdout.take()) else {
                        return Err("Codex has no stdio".into());
                    };
                    crate::codex_login::mcp_sign_in(output, input, &job.server, page).await
                }
                Provider::Opencode => Err("OpenCode signs in to a server with `opencode mcp auth`, in a terminal".into()),
            }
        })
    })
}

/// Follows the daemon's tasks: each server one says needs signing in is signed in to (once), and the tasks that wanted
/// it are told how that goes (a notice; reconnected, for Claude, once signed in).
pub fn start(daemon: Arc<crate::daemon::Daemon>, inbox: Arc<Inbox>) {
    let auth = daemon.mcp_auth.clone();
    let weak = Arc::downgrade(&daemon);
    auth.attach(
        inbox,
        Box::new(move |session, server, news| {
            let Some(session) = weak.upgrade().and_then(|d| d.session(session).ok()) else { return };
            let (text, error) = match news {
                News::Link(url) => (
                    format!("{server} needs you to sign in on your Mac before this task can use it: [open its sign-in page]({url}) (asked in Zero's inbox too)"),
                    false,
                ),
                News::SignedIn => (format!("Signed in to {server}"), false),
                News::Failed(why) => (format!("Couldn't sign in to {server}: {why}"), true),
            };
            notice(&session, &text, error);
            // Claude skipped the server when it started: it connects now, with what the sign-in kept.
            if matches!(news, News::SignedIn) && session.summary().provider == Provider::Claude && session.is_attached() {
                let _ = session.write(json!({"type": "control_request", "request_id": format!("mcp-reconnect-{server}"),
                                             "request": {"subtype": "mcp_reconnect", "serverName": server}}));
            }
        }),
    );
    let mut events = daemon.subscribe();
    let weak = Arc::downgrade(&daemon);
    tokio::spawn(async move {
        loop {
            let event = match events.recv().await {
                Ok(event) => event,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => return,
            };
            let Change::McpSignIn { server } = event.change else { continue };
            let Some(daemon) = weak.upgrade() else { return };
            let Some(conversation) = daemon.get(&event.session) else { continue };
            let env = crate::process::SESSION_ENV.lock().unwrap().get(&conversation.id).cloned().unwrap_or_default();
            let job = Job { server, provider: conversation.provider, cwd: conversation.cwd.clone(), env, mcp: conversation.mcp.clone() };
            daemon.mcp_auth.wanted(&conversation, job);
        }
    });
}

/// A line in a task, as Zero says it.
fn notice(session: &crate::session::Session, text: &str, error: bool) {
    let item = Item {
        at: None,
        id: format!("mcp-auth-{}", session.summary().seq + 1),
        turn: None,
        kind: ItemKind::Notice { text: text.into(), error },
        status: ItemStatus::Done,
    };
    session.change(Change::Item { item });
}
