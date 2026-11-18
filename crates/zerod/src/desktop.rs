//! The desktop tools: agents see and use the Mac's apps through Zero.app, which holds the Accessibility and Screen
//! Recording permissions (a fixed signed identity; agents' shells can't get them). Zero.app attaches as the desktop
//! (`desktopAttach`, the app's alone); a task's desktop_ call is pushed to it as `{"desktop": {"call", "tool", "args",
//! "task"}}` and answered with `desktopAnswer`. Before it goes, zerod has the app found (`resolve`), checks its tier, and
//! has the user allow it for the task on a card (server/desktop.rs).

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

/// How long Zero.app may take over one call: a recording's stop, a slow app's accessibility tree.
const CALL_TIMEOUT: Duration = Duration::from_secs(120);

/// The tools agents are offered.
pub fn tools() -> Vec<Value> {
    serde_json::from_str(include_str!("desktop_tools.json")).unwrap_or_default()
}

/// What a tool does to an app: looks at it, points in it (click, scroll, drag), or types into it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Action {
    Look,
    Point,
    Type,
}

impl Action {
    pub fn of(tool: &str) -> Option<Action> {
        Some(match tool {
            "desktop_screenshot" | "desktop_read" | "desktop_record" => Action::Look,
            "desktop_click" | "desktop_scroll" | "desktop_drag" => Action::Point,
            "desktop_type" | "desktop_key" => Action::Type,
            _ => return None,
        })
    }
}

/// How far an app may be used once the user allows it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tier {
    Full,
    /// Looked at only; the reason says what to do instead.
    ReadOnly(&'static str),
    /// Looked at and pointed in; each typing asks, as it runs commands outside the task's sandbox.
    Terminal,
    /// Looked at and acted in, in the background only (accessibility actions, events sent to it alone): never the real
    /// pointer, never brought forward, so the user isn't disturbed.
    Background,
    /// Never, whatever the user says on a card: it holds passwords or the Mac's permissions.
    Never,
}

/// The user's Zero: one value, so it can change. In the background only, as the user is in it; Zero.app refuses any
/// event that lands on its cards, approvals, the control bar or Settings, so an agent can't answer its own asks.
pub const ZERO: Tier = Tier::Background;
const BROWSER: Tier =
    Tier::ReadOnly("Browsers are read only to the desktop tools: act in them with the browser_ tools, which check the sites a task opens.");

/// The bundle id that stands for the whole screen, approved as an app of its own.
pub const SCREEN: &str = "screen";

pub fn tier(bundle: &str) -> Tier {
    const NEVER: &[&str] = &[
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.systempreferences",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.1password.",
        "com.agilebits.",
        "com.bitwarden.",
        "com.dashlane.",
    ];
    const TERMINALS: &[&str] = &[
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
    ];
    const BROWSERS: &[&str] = &[
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.",
        "org.mozilla.",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.",
        "com.vivaldi.",
        "org.chromium.",
        "app.zen-browser.",
        "com.arsen.zero.browser",
        "com.arsen.zero.dev.browser",
    ];
    let named = |list: &[&str]| {
        list.iter().any(|p| if p.ends_with('.') { bundle.starts_with(p) } else { bundle == *p || bundle.starts_with(&format!("{p}.")) })
    };
    if named(NEVER) {
        Tier::Never
    } else if named(BROWSERS) {
        BROWSER
    } else if bundle == "com.arsen.zero" {
        ZERO
    } else if named(TERMINALS) {
        Tier::Terminal
    } else {
        Tier::Full
    }
}

#[derive(Default)]
struct State {
    /// Zero.app's connection, by the number it attached under.
    app: Option<(u64, mpsc::UnboundedSender<Value>)>,
    attached: u64,
    next: u64,
    pending: HashMap<u64, oneshot::Sender<Result<Value, String>>>,
    /// Apps allowed for the rest of a task: (session, bundle id). ponytail: in memory, so a zerod restart asks again;
    /// read back from the asks' log instead, any process of the user's could write itself an approval there.
    allowed: HashSet<(String, String)>,
    /// Tasks the user stopped, until they're told so.
    stopped: HashSet<String>,
    /// Cards open for a task, by what they're for (an app's bundle id, a typing), outliving the call that made them and
    /// its turn: the next call takes the answer, and an answer with no call waiting wakes the task (server/desktop.rs).
    cards: HashMap<(String, String), String>,
}

/// Zero.app as the desktop, the calls on their way to it, and what the user allowed.
pub struct Desktop {
    state: Mutex<State>,
    card_wait: Mutex<Duration>,
}

impl Default for Desktop {
    fn default() -> Desktop {
        // Under Codex's 60 s for a tool call: the call says it's waiting before Codex gives up on it.
        Desktop { state: Mutex::default(), card_wait: Mutex::new(Duration::from_secs(45)) }
    }
}

impl Desktop {
    /// How long one call waits on a card before it returns, the card left open.
    pub fn card_wait(&self) -> Duration {
        *self.card_wait.lock().unwrap()
    }
    pub fn set_card_wait(&self, wait: Duration) {
        *self.card_wait.lock().unwrap() = wait
    }

    /// The card open for this task and purpose, if one is.
    pub fn card(&self, session: &str, purpose: &str) -> Option<String> {
        self.state.lock().unwrap().cards.get(&(session.to_string(), purpose.to_string())).cloned()
    }
    pub fn keep_card(&self, session: &str, purpose: &str, id: &str) {
        self.state.lock().unwrap().cards.insert((session.to_string(), purpose.to_string()), id.to_string());
    }
    pub fn drop_card(&self, session: &str, purpose: &str) {
        self.state.lock().unwrap().cards.remove(&(session.to_string(), purpose.to_string()));
    }

    /// Zero.app's connection becomes the desktop: its number, to detach it by.
    pub fn attach(&self, out: mpsc::UnboundedSender<Value>) -> u64 {
        let mut state = self.state.lock().unwrap();
        state.attached += 1;
        let id = state.attached;
        state.app = Some((id, out));
        id
    }

    /// That connection closed: the calls it had are told, unless a newer one took its place.
    pub fn detach(&self, id: u64) {
        let mut state = self.state.lock().unwrap();
        if state.app.as_ref().is_some_and(|(current, _)| *current == id) {
            state.app = None;
            for (_, waiting) in state.pending.drain() {
                let _ = waiting.send(Err("Zero.app closed before answering".into()));
            }
        }
    }

    /// Zero.app's answer to call `{"call", "result"}` or `{"call", "error"}`.
    pub fn answer(&self, answer: &Value) {
        let Some(call) = answer["call"].as_u64() else { return };
        let Some(waiting) = self.state.lock().unwrap().pending.remove(&call) else { return };
        let _ = waiting.send(match answer["error"].as_str() {
            Some(error) => Err(error.to_string()),
            None => Ok(answer["result"].clone()),
        });
    }

    /// One call to Zero.app, waited for.
    pub async fn send(&self, task: &Value, tool: &str, args: Value) -> Result<Value, String> {
        let (tx, rx) = oneshot::channel();
        let call = {
            let mut state = self.state.lock().unwrap();
            let Some((_, out)) = state.app.clone() else {
                return Err("Zero.app isn't open: the desktop tools need it running. Ask the user to open Zero.".into());
            };
            state.next += 1;
            let call = state.next;
            state.pending.insert(call, tx);
            let _ = out.send(json!({"desktop": {"call": call, "tool": tool, "args": args, "task": task}}));
            call
        };
        match tokio::time::timeout(CALL_TIMEOUT, rx).await {
            Ok(Ok(answer)) => answer,
            Ok(Err(_)) => Err("Zero.app closed before answering".into()),
            Err(_) => {
                self.state.lock().unwrap().pending.remove(&call);
                Err(format!("Zero.app didn't answer {tool} within {} seconds", CALL_TIMEOUT.as_secs()))
            }
        }
    }

    pub fn allowed(&self, session: &str, bundle: &str) -> bool {
        self.state.lock().unwrap().allowed.contains(&(session.to_string(), bundle.to_string()))
    }

    pub fn allow(&self, session: &str, bundle: &str) {
        self.state.lock().unwrap().allowed.insert((session.to_string(), bundle.to_string()));
    }

    /// The bundle ids a task may use: Zero.app shows their windows' titles in desktop_apps, the rest's only names.
    pub fn approved(&self, session: &str) -> Vec<String> {
        let mut approved: Vec<String> =
            self.state.lock().unwrap().allowed.iter().filter(|(s, _)| s == session).map(|(_, b)| b.clone()).collect();
        approved.sort();
        approved
    }

    /// The user's Stop: the task's approvals dropped, Zero.app told to end what it has going for it (a recording).
    pub fn stop(&self, session: &str) {
        let mut state = self.state.lock().unwrap();
        state.allowed.retain(|(s, _)| s != session);
        state.stopped.insert(session.to_string());
        if let Some((_, out)) = &state.app {
            let _ = out.send(json!({"desktop": {"stop": session}}));
        }
    }

    /// Whether the task was stopped and not yet told: true once.
    pub fn take_stopped(&self, session: &str) -> bool {
        self.state.lock().unwrap().stopped.remove(session)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiers_go_by_bundle_id() {
        assert_eq!(tier("com.apple.Notes"), Tier::Full);
        assert_eq!(tier("com.arsen.zero.dev"), Tier::Full, "Zero Dev is how agents test Zero");
        assert_eq!(tier("com.arsen.zero"), ZERO);
        assert_eq!(tier("com.google.Chrome.canary"), BROWSER);
        assert_eq!(tier("com.google.Chromecast"), Tier::Full, "a prefix is a whole part of the id");
        assert_eq!(tier("com.1password.1password"), Tier::Never);
        assert_eq!(tier("dev.warp.Warp-Stable"), Tier::Terminal);
    }
}
