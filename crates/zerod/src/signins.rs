//! The CLIs' sign-ins, kept by Zero and handed to each CLI as a task starts, in the form that CLI reads one. The CLIs
//! still make every call to their providers; Zero never does. What a sign-in is (its CLI, kind and name) is kept here,
//! in a file only the user reads; its value is in the Keychain, or (a Codex account) in the home Codex keeps it in.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::model::Provider;
use crate::process::Variables;

/// The Keychain service sign-ins' values are kept under, by the sign-in's id.
pub const KEYCHAIN: &str = "Zero sign-ins";

const ACTIVITY: &str = "activity.json";

/// Reads a value from the Keychain (service, account); a stand-in in tests.
pub type Secrets = Arc<dyn Fn(&str, &str) -> Option<String> + Send + Sync>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    /// Claude Code's long-lived token (`claude setup-token`).
    Token,
    /// A provider's API key.
    ApiKey,
    /// A Codex home of its own, where Codex keeps (and refreshes) its sign-in.
    CodexHome,
    /// A Claude Code folder of its own (`CLAUDE_CONFIG_DIR`), where Claude Code keeps (and refreshes) its sign-in.
    ClaudeHome,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignIn {
    #[serde(default)]
    pub id: String,
    pub cli: Provider,
    pub kind: Kind,
    /// What it's called: the account's email, or the user's name for a key.
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    /// An OpenCode provider's key: the variable OpenCode reads it from (OPENCODE_API_KEY, ANTHROPIC_API_KEY…).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    /// Still being signed in (a Codex account waiting on the browser): no one's default, and no task starts as it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub pending: bool,
}

#[derive(Default, Serialize, Deserialize)]
struct Kept {
    signins: Vec<SignIn>,
    /// Each CLI's default, by its name.
    #[serde(default)]
    defaults: std::collections::BTreeMap<String, String>,
    /// Each sign-in's usage as its CLI last reported it, by id: what choosing an account goes by.
    #[serde(default)]
    usage: std::collections::BTreeMap<String, crate::model::Usage>,
    /// The models each sign-in's provider refused it (no access), by id: never chosen for them.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    refused: std::collections::BTreeMap<String, Vec<String>>,
}

pub struct SignIns {
    file: PathBuf,
    /// Where accounts' own folders are: `<cli>-homes/<id>`.
    home: PathBuf,
    kept: Mutex<Kept>,
    secrets: Mutex<Secrets>,
    /// The user's own Codex home and Claude Code folder, whose config and history every account's folder shares.
    codex: Mutex<PathBuf>,
    claude: Mutex<PathBuf>,
    /// Each account's finished turns, by the hour (Unix hours) they ended in: its activity, as a contribution graph
    /// shows it. Kept in activity.json, a little over a year of it.
    activity: Mutex<Activity>,
}

/// An account's turns by hour, by its id.
pub type Activity = std::collections::BTreeMap<String, std::collections::BTreeMap<i64, u32>>;

impl SignIns {
    pub fn open(home: &Path) -> SignIns {
        let file = home.join("signins.json");
        let kept = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        let user = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let codex = std::env::var_os("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|| user.join(".codex"));
        let claude = std::env::var_os("CLAUDE_CONFIG_DIR").map(PathBuf::from).unwrap_or_else(|| user.join(".claude"));
        let activity = std::fs::read(home.join(ACTIVITY)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        SignIns {
            file,
            home: home.into(),
            kept: Mutex::new(kept),
            secrets: Mutex::new(Arc::new(crate::mcp_servers::keychain)),
            codex: Mutex::new(codex),
            claude: Mutex::new(claude),
            activity: Mutex::new(activity),
        }
    }

    /// A turn the account's task finished at `at` (Unix seconds), counted in its hour; what's over a year old let go.
    pub fn record_turn(&self, id: &str, at: i64) {
        if !self.kept.lock().unwrap().signins.iter().any(|s| s.id == id) {
            return;
        }
        let mut activity = self.activity.lock().unwrap();
        let hours = activity.entry(id.into()).or_default();
        *hours.entry(at / 3600).or_default() += 1;
        let oldest = at / 3600 - 400 * 24;
        hours.retain(|hour, _| *hour >= oldest);
        if let Ok(data) = serde_json::to_vec(&*activity) {
            let _ = std::fs::write(self.home.join(ACTIVITY), data);
        }
    }

    pub fn activity(&self) -> Activity {
        self.activity.lock().unwrap().clone()
    }

    pub fn set_secrets(&self, secrets: Secrets) {
        *self.secrets.lock().unwrap() = secrets
    }
    pub fn set_codex_dir(&self, dir: PathBuf) {
        *self.codex.lock().unwrap() = dir
    }
    pub fn set_claude_dir(&self, dir: PathBuf) {
        *self.claude.lock().unwrap() = dir
    }

    pub fn list(&self) -> Vec<SignIn> {
        self.kept.lock().unwrap().signins.clone()
    }
    pub fn get(&self, id: &str) -> Option<SignIn> {
        self.kept.lock().unwrap().signins.iter().find(|s| s.id == id).cloned()
    }

    /// A CLI's default: the one chosen, else the first of its kept.
    pub fn default_for(&self, cli: Provider) -> Option<SignIn> {
        let kept = self.kept.lock().unwrap();
        let chosen = kept.defaults.get(&name(cli)).and_then(|id| kept.signins.iter().find(|s| &s.id == id && s.cli == cli));
        chosen.filter(|s| !s.pending).or_else(|| kept.signins.iter().find(|s| s.cli == cli && !s.pending)).cloned()
    }

    /// Kept (a new one given an id), the same id replacing what it was.
    pub fn save(&self, mut signin: SignIn) -> Result<SignIn, String> {
        signin.label = signin.label.trim().to_string();
        if signin.label.is_empty() {
            return Err("A sign-in needs a name".into());
        }
        let mut kept = self.kept.lock().unwrap();
        if signin.id.is_empty() {
            signin.id = crate::ask::new_id()
        }
        match kept.signins.iter_mut().find(|s| s.id == signin.id) {
            Some(old) => {
                // A Claude account's folder of its own given up for a token (the user's own folder from now on): gone.
                if old.kind == Kind::ClaudeHome && signin.kind != Kind::ClaudeHome {
                    let _ = std::fs::remove_dir_all(self.home.join("claude-homes").join(&signin.id));
                }
                *old = signin.clone()
            }
            None => kept.signins.push(signin.clone()),
        }
        self.persist(&kept)?;
        Ok(signin)
    }

    pub fn delete(&self, id: &str) -> Result<(), String> {
        let mut kept = self.kept.lock().unwrap();
        let before = kept.signins.len();
        kept.signins.retain(|s| s.id != id);
        if kept.signins.len() == before {
            return Err(format!("No sign-in {id}"));
        }
        kept.defaults.retain(|_, chosen| chosen != id);
        for cli in ["codex", "claude"] {
            let _ = std::fs::remove_dir_all(self.home.join(format!("{cli}-homes")).join(id));
        }
        self.persist(&kept)
    }

    pub fn set_default(&self, cli: Provider, id: &str) -> Result<(), String> {
        let mut kept = self.kept.lock().unwrap();
        if !kept.signins.iter().any(|s| s.id == id && s.cli == cli) {
            return Err(format!("No {} sign-in {id}", cli.title()));
        }
        kept.defaults.insert(name(cli), id.into());
        self.persist(&kept)
    }

    /// A sign-in's usage, as a task running as it was told by its CLI.
    pub fn record_usage(&self, id: &str, usage: &crate::model::Usage) {
        let mut kept = self.kept.lock().unwrap();
        if !kept.signins.iter().any(|s| s.id == id) {
            return;
        }
        // Added to what's known: a report that has no figure for a window (a limit said in an error, an account just
        // switched to) leaves the one read before, which it used to wipe, the account's usage then shown as nothing.
        let mut merged = usage.clone();
        if let Some(before) = kept.usage.get(id) {
            for window in &before.windows {
                if !merged.windows.iter().any(|w| w.name == window.name) {
                    merged.windows.push(window.clone())
                }
            }
        }
        if kept.usage.get(id) == Some(&merged) {
            return;
        }
        kept.usage.insert(id.into(), merged);
        let _ = self.persist(&kept);
    }

    pub fn usage(&self, id: &str) -> Option<crate::model::Usage> {
        self.kept.lock().unwrap().usage.get(id).cloned()
    }

    /// The provider refused this sign-in `model` (it has no access): learnt from its CLI's error, as nothing in Zero
    /// asks a provider what an account may use.
    pub fn refuse(&self, id: &str, model: &str) {
        let mut kept = self.kept.lock().unwrap();
        if !kept.signins.iter().any(|s| s.id == id) {
            return;
        }
        let models = kept.refused.entry(id.into()).or_default();
        if models.iter().any(|m| m == model) {
            return;
        }
        models.push(model.into());
        let _ = self.persist(&kept);
    }

    pub fn refused(&self, id: &str) -> Vec<String> {
        self.kept.lock().unwrap().refused.get(id).cloned().unwrap_or_default()
    }

    /// The account a task of `cli` runs as (`except` one, the account it's leaving): of those not at a limit (a 5-hour
    /// or 7-day window full and not reset yet), the one with the least of its 7-day allowance left, so one account is
    /// used up before the next; ties go to the one resetting sooner, then to the default. A week that's reset, or an
    /// account never used, counts as whole. None: every account is at a limit.
    pub fn choose(&self, cli: Provider, now: i64, except: Option<&str>) -> Option<SignIn> {
        self.choose_for(cli, now, except, None)
    }

    /// As `choose`, for a task on `model`: an account refused it isn't one to choose.
    pub fn choose_for(&self, cli: Provider, now: i64, except: Option<&str>, model: Option<&str>) -> Option<SignIn> {
        let kept = self.kept.lock().unwrap();
        let refused = |id: &str| model.is_some_and(|m| kept.refused.get(id).is_some_and(|r| r.iter().any(|x| x == m)));
        let default = kept.defaults.get(&name(cli)).cloned();
        let live = |w: &crate::model::UsageWindow| w.resets_at.is_some_and(|at| at > now);
        let mut open: Vec<(f64, i64, bool, usize, &SignIn)> = kept
            .signins
            .iter()
            .enumerate()
            .filter(|(_, s)| s.cli == cli && !s.pending && except != Some(s.id.as_str()) && !refused(&s.id))
            .filter_map(|(order, signin)| {
                let usage = kept.usage.get(&signin.id);
                let stopped = usage.is_some_and(|u| {
                    (u.limited && u.resets_at.is_some_and(|at| at > now)) || u.windows.iter().any(|w| live(w) && w.used >= 1.0)
                });
                if stopped {
                    return None;
                }
                let week = usage.and_then(|u| u.windows.iter().find(|w| w.name == "7 days")).filter(|w| live(w));
                let left = week.map_or(1.0, |w| (1.0 - w.used).max(0.0));
                Some((
                    left,
                    week.and_then(|w| w.resets_at).unwrap_or(i64::MAX),
                    default.as_deref() != Some(signin.id.as_str()),
                    order,
                    signin,
                ))
            })
            .collect();
        open.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)).then(a.2.cmp(&b.2)).then(a.3.cmp(&b.3)));
        open.first().map(|chosen| chosen.4.clone())
    }

    /// What the CLI's process is given for this sign-in: a missing value is an error to show, never a CLI started
    /// signed in as whatever it finds.
    pub fn environment(&self, signin: &SignIn) -> Result<Variables, String> {
        if signin.pending {
            return Err(format!("{} is still signing in", signin.label));
        }
        let value = || {
            (self.secrets.lock().unwrap())(KEYCHAIN, &signin.id)
                .ok_or_else(|| format!("{} isn't in the Keychain any more: sign in again", signin.label))
        };
        Ok(match (signin.cli, signin.kind) {
            (Provider::Claude, Kind::Token) => vec![("CLAUDE_CODE_OAUTH_TOKEN".into(), value()?)],
            (Provider::Claude, Kind::ApiKey) => vec![("ANTHROPIC_API_KEY".into(), value()?)],
            (Provider::Opencode, Kind::ApiKey) => {
                let variable = signin.variable.clone().ok_or_else(|| format!("{} doesn't say which provider it's for", signin.label))?;
                vec![(variable, value()?)]
            }
            (Provider::Codex, _) => vec![("CODEX_HOME".into(), self.folder(Provider::Codex, &signin.id)?.to_string_lossy().into())],
            (Provider::Claude, Kind::ClaudeHome) => {
                vec![("CLAUDE_CONFIG_DIR".into(), self.folder(Provider::Claude, &signin.id)?.to_string_lossy().into())]
            }
            (cli, kind) => return Err(format!("{} doesn't sign in with {kind:?}", cli.title())),
        })
    }

    /// An account's own folder for its CLI (a Codex home, a Claude Code folder): everything of the user's own linked
    /// in (config, plugins, conversations, so they resume under any account) but the sign-in, which the CLI writes
    /// there itself as it signs in and refreshes. Claude Code's state file starts as a copy of the user's, without
    /// who they're signed in as.
    pub fn folder(&self, cli: Provider, id: &str) -> Result<PathBuf, String> {
        let (shared, sign_in) = match cli {
            Provider::Codex => (self.codex.lock().unwrap().clone(), "auth.json"),
            Provider::Claude => (self.claude.lock().unwrap().clone(), ".credentials.json"),
            Provider::Opencode => return Err("OpenCode's sign-ins are keys".into()),
        };
        let folder = self.home.join(format!("{}-homes", name(cli))).join(id);
        std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
        for entry in std::fs::read_dir(&shared).into_iter().flatten().flatten() {
            let entry_name = entry.file_name();
            if entry_name == sign_in || folder.join(&entry_name).symlink_metadata().is_ok() {
                continue;
            }
            #[cfg(unix)]
            std::os::unix::fs::symlink(entry.path(), folder.join(&entry_name)).map_err(|e| e.to_string())?;
        }
        if cli == Provider::Claude
            && !folder.join(".claude.json").exists()
            && let Some(user) = shared.parent().map(|p| p.join(".claude.json"))
            && let Ok(Ok(mut state)) = std::fs::read(&user).map(|data| serde_json::from_slice::<serde_json::Value>(&data))
        {
            if let Some(state) = state.as_object_mut() {
                state.remove("oauthAccount");
            }
            write_private(&folder.join(".claude.json"), &serde_json::to_vec_pretty(&state).map_err(|e| e.to_string())?)?;
        }
        Ok(folder)
    }

    fn persist(&self, kept: &Kept) -> Result<(), String> {
        let data = serde_json::to_vec_pretty(kept).map_err(|e| e.to_string())?;
        if let Some(parent) = self.file.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?
        }
        write_private(&self.file, &data)
    }
}

/// Written for the user alone to read.
fn write_private(path: &Path, data: &[u8]) -> Result<(), String> {
    std::fs::write(path, data).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// A CLI as the file names it: "claude", "codex", "opencode".
fn name(cli: Provider) -> String {
    format!("{cli:?}").to_lowercase()
}

/// Whether a CLI's error says the account can't use the model asked for (no access, or none by that name for it), not
/// that the model is busy: the CLIs say so in words, not codes.
pub fn refuses_model(message: &str) -> bool {
    let text = message.to_lowercase();
    let any = |words: &[&str]| words.iter().any(|w| text.contains(w));
    text.contains("model")
        && any(&[
            "may not have access",
            "do not have access",
            "does not have access",
            "don't have access",
            "not supported when using",
            "model_not_found",
            "may not exist",
            "does not exist",
        ])
}
