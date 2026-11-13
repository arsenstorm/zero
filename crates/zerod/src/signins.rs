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

/// Writes a value to the Keychain (service, account, value; none removes it); a stand-in in tests.
pub type Store = Arc<dyn Fn(&str, &str, Option<&str>) -> Result<(), String> + Send + Sync>;

/// Whether a Claude Code folder has a process running in it (`folder_in_use`); a stand-in in tests.
pub type InUse = Arc<dyn Fn(&Path) -> bool + Send + Sync>;

/// The account an MCP server's sign-in is kept under in KEYCHAIN: "mcp:" and Claude Code's name for it (its name and a
/// hash of where it is).
const MCP_SIGN_IN: &str = "mcp:";

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
    /// Sign-ins removed, by id: what their activity is shown as.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    former: std::collections::BTreeMap<String, SignIn>,
    /// The turns from before Zero counted them have been counted from the transcripts (`count_earlier_turns`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    earlier_counted: bool,
    /// When a turn last ended on each account (Unix seconds), by id: the app's most recently used account.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    last_turn: std::collections::BTreeMap<String, i64>,
    /// The MCP servers' sign-ins Zero keeps (each in the Keychain), by Claude Code's name for each.
    #[serde(default, skip_serializing_if = "std::collections::BTreeSet::is_empty")]
    mcp: std::collections::BTreeSet<String>,
}

pub struct SignIns {
    file: PathBuf,
    /// Where accounts' own folders are: `<cli>-homes/<id>`.
    home: PathBuf,
    kept: Mutex<Kept>,
    secrets: Mutex<Secrets>,
    /// Writes to the Keychain: none, Zero writes nothing there (tests not given one, so they never touch the user's).
    store: Mutex<Option<Store>>,
    in_use: Mutex<InUse>,
    /// The user's own Codex home and Claude Code folder, whose config and history every account's folder shares.
    codex: Mutex<PathBuf>,
    claude: Mutex<PathBuf>,
    /// Each account's finished turns, by the hour (Unix hours) they ended in: its activity, as a contribution graph
    /// shows it. Kept in activity.json, a little over a year of it.
    activity: Mutex<Activity>,
    /// Wakes the accounts' usage reads (server/signins.rs `follow_usage`) to read now: the Accounts page opened, a
    /// limit heard in a task.
    pub read_now: tokio::sync::Notify,
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
            store: Mutex::new(None),
            in_use: Mutex::new(Arc::new(folder_in_use)),
            codex: Mutex::new(codex),
            claude: Mutex::new(claude),
            activity: Mutex::new(activity),
            read_now: tokio::sync::Notify::new(),
        }
    }

    /// A turn the account's task finished at `at` (Unix seconds), counted in its hour; what's over a year old let go.
    /// Kept whatever becomes of the account: `id` is a sign-in's, or a CLI's name for a turn run as its own sign-in.
    pub fn record_turn(&self, id: &str, at: i64) {
        let mut activity = self.activity.lock().unwrap();
        let hours = activity.entry(id.into()).or_default();
        *hours.entry(at / 3600).or_default() += 1;
        let oldest = at / 3600 - 400 * 24;
        hours.retain(|hour, _| *hour >= oldest);
        self.keep_activity(&activity);
        drop(activity);
        let mut kept = self.kept.lock().unwrap();
        if kept.last_turn.get(id).is_none_or(|last| *last < at) {
            kept.last_turn.insert(id.into(), at);
            let _ = self.persist(&kept);
        }
    }

    /// When a turn last ended on each account, by id (Unix seconds); for one with no turn since that was kept, the start
    /// of the hour its activity last counted one in.
    pub fn last_turns(&self) -> std::collections::BTreeMap<String, i64> {
        let mut last: std::collections::BTreeMap<String, i64> = self
            .activity
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(id, hours)| hours.keys().max().map(|hour| (id.clone(), hour * 3600)))
            .collect();
        last.extend(self.kept.lock().unwrap().last_turn.clone());
        last
    }

    fn keep_activity(&self, activity: &Activity) {
        if let Ok(data) = serde_json::to_vec(activity) {
            let _ = std::fs::write(self.home.join(ACTIVITY), data);
        }
    }

    /// The turns tasks finished before Zero counted them, counted once from their transcripts in `folders` (sessions,
    /// archive: each line with when zerod heard it, in milliseconds), by the hour each ended, under the task's CLI's
    /// name (which account each ran as wasn't kept). Only those before the first turn counted, so none counts twice.
    pub fn count_earlier_turns(&self, folders: &[PathBuf]) {
        use std::io::BufRead;
        if self.kept.lock().unwrap().earlier_counted {
            return;
        }
        let first = self.activity.lock().unwrap().values().filter_map(|hours| hours.keys().next().copied()).min();
        let before = first.map_or(i64::MAX, |hour| hour * 3_600_000);
        let mut found = Activity::new();
        for task in folders.iter().flat_map(|f| std::fs::read_dir(f).into_iter().flatten().flatten()) {
            let meta = std::fs::read(task.path().join("meta.json")).ok();
            let Some(cli) = meta
                .and_then(|m| serde_json::from_slice::<serde_json::Value>(&m).ok())
                .and_then(|m| m["provider"].as_str().map(String::from))
            else {
                continue;
            };
            let Ok(file) = std::fs::File::open(task.path().join("transcript.jsonl")) else { continue };
            for line in std::io::BufReader::new(file).split(b'\n').map_while(Result::ok) {
                // Most lines aren't a turn's end: only those that may be are read as JSON.
                if ![&b"\"result\""[..], b"turn/completed"].iter().any(|word| line.windows(word.len()).any(|w| w == *word)) {
                    continue;
                }
                let Ok(heard) = serde_json::from_slice::<serde_json::Value>(&line) else { continue };
                let Some(at) = heard["at"].as_i64().filter(|at| *at < before) else { continue };
                if finished(&heard["in"]) {
                    *found.entry(cli.clone()).or_default().entry(at / 3_600_000).or_default() += 1;
                }
            }
        }
        {
            let mut activity = self.activity.lock().unwrap();
            for (id, hours) in found {
                for (hour, turns) in hours {
                    *activity.entry(id.clone()).or_default().entry(hour).or_default() += turns;
                }
            }
            self.keep_activity(&activity);
        }
        let mut kept = self.kept.lock().unwrap();
        kept.earlier_counted = true;
        let _ = self.persist(&kept);
    }

    pub fn activity(&self) -> Activity {
        self.activity.lock().unwrap().clone()
    }

    /// Every sign-in activity may be counted under, by id: those kept, and those removed since.
    pub fn named(&self) -> std::collections::BTreeMap<String, SignIn> {
        let kept = self.kept.lock().unwrap();
        kept.former.clone().into_iter().chain(kept.signins.iter().map(|s| (s.id.clone(), s.clone()))).collect()
    }

    /// Each Claude account with a folder of its own named by the account Claude Code keeps there (`.claude.json`'s
    /// oauthAccount: its email and plan, nothing else read): the email unless the user gave it a name. True when one
    /// changed.
    pub fn name_claude_folders(&self) -> bool {
        let mut kept = self.kept.lock().unwrap();
        let mut changed = false;
        for signin in kept.signins.iter_mut().filter(|s| s.kind == Kind::ClaudeHome && !s.pending) {
            let file = self.home.join("claude-homes").join(&signin.id).join(".claude.json");
            let Some(account) = std::fs::read(file).ok().and_then(|d| serde_json::from_slice::<serde_json::Value>(&d).ok()) else {
                continue;
            };
            let account = &account["oauthAccount"];
            // ponytail: a name with an @ is taken for an email Zero gave it; a user's own with one is renamed.
            if let Some(email) = account["emailAddress"].as_str()
                && (signin.label == "Claude" || signin.label.contains('@'))
                && signin.label != email
            {
                signin.label = email.into();
                changed = true;
            }
            let plan = account["planDisplayName"]
                .as_str()
                .map(String::from)
                .or_else(|| account["organizationType"].as_str().map(|t| t.trim_start_matches("claude_").into()));
            if plan.is_some() && signin.plan != plan {
                signin.plan = plan;
                changed = true;
            }
        }
        if changed {
            let _ = self.persist(&kept);
        }
        changed
    }

    pub fn set_secrets(&self, secrets: Secrets) {
        *self.secrets.lock().unwrap() = secrets
    }
    pub fn set_store(&self, store: Store) {
        *self.store.lock().unwrap() = Some(store)
    }
    pub fn set_in_use(&self, in_use: InUse) {
        *self.in_use.lock().unwrap() = in_use
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
        let Some(at) = kept.signins.iter().position(|s| s.id == id) else { return Err(format!("No sign-in {id}")) };
        let removed = kept.signins.remove(at);
        kept.former.insert(removed.id.clone(), removed.clone());
        kept.defaults.retain(|_, chosen| chosen != id);
        // Claude Code's item for its folder (its account's sign-in and MCP servers') goes with the folder.
        if removed.kind == Kind::ClaudeHome
            && let Some(store) = self.store.lock().unwrap().clone()
        {
            let _ = store(&claude_keychain(Some(&self.home.join("claude-homes").join(id))), &claude_user(), None);
        }
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
        // Added to what's known: a report that has no figure for a window (a limit said in an error, an account just
        // switched to) leaves the one read before, which it used to wipe, the account's usage then shown as nothing.
        let mut merged = usage.clone();
        if let Some(before) = self.usage(id) {
            for window in before.windows {
                if !merged.windows.iter().any(|w| w.name == window.name) {
                    merged.windows.push(window)
                }
            }
        }
        self.replace_usage(id, &merged)
    }

    /// A sign-in's usage as a read of its plan gave it: every window it has, so one it no longer reports goes. A read
    /// with no window at all (its CLI answered without its limits) read nothing, so what's known stays, unless it said
    /// the plan has none.
    pub fn replace_usage(&self, id: &str, usage: &crate::model::Usage) {
        let mut kept = self.kept.lock().unwrap();
        let known = kept.usage.get(id).is_some_and(|u| !u.windows.is_empty());
        let read_nothing = usage.windows.is_empty() && !usage.no_limits && !usage.limited;
        if !kept.signins.iter().any(|s| s.id == id) || kept.usage.get(id) == Some(usage) || (read_nothing && known) {
            return;
        }
        kept.usage.insert(id.into(), usage.clone());
        let _ = self.persist(&kept);
    }

    /// Its usage, now known to be at a limit its CLI said in an error (no figures, no reset): kept as limited (an hour,
    /// until a read says otherwise) so it isn't chosen again at once, and read now for the real figures. False when it
    /// was already known to be.
    pub fn limit_said(&self, id: &str, now: i64) -> bool {
        let mut usage = self.usage(id).unwrap_or_default();
        if usage.limited && usage.resets_at.is_some_and(|at| at > now) {
            return false;
        }
        // ponytail: a guessed hour; the read it wakes (or the account's next) corrects it.
        usage.limited = true;
        usage.resets_at = Some(now + 3600);
        self.record_usage(id, &usage);
        self.read_now.notify_one();
        true
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
                let folder = self.folder(Provider::Claude, &signin.id)?;
                self.share_mcp_sign_ins(Some(&folder));
                vec![("CLAUDE_CONFIG_DIR".into(), folder.to_string_lossy().into())]
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

    /// MCP servers' sign-ins (their OAuth), which Claude Code keeps in each folder's Keychain item, made every Claude
    /// account's: each server's latest (the one expiring last, as Claude Code refreshed it in whichever folder) kept by
    /// Zero, and given to `into`'s item (a folder whose task is starting) if it has an older one or none. Only a
    /// folder signed in (one with an item) is given any, and only while no Claude runs in it: Claude Code rewrites the
    /// item as it renews the account's sign-in, rotating its refresh token, and a write at the same time would lose
    /// that. A folder in use gets them at its next start with none. What's written is the item as read just before,
    /// with only the servers' sign-ins added or renewed changed. Zero never calls a server: Claude Code signs in and
    /// refreshes, Zero copies what it kept.
    pub fn share_mcp_sign_ins(&self, into: Option<&Path>) {
        let Some(store) = self.store.lock().unwrap().clone() else { return };
        let read = self.secrets.lock().unwrap().clone();
        let user = claude_user();
        let item = |service: &str| read(service, &user).and_then(|v| serde_json::from_str::<serde_json::Value>(&v).ok());
        let (names, folders): (Vec<String>, Vec<PathBuf>) = {
            let kept = self.kept.lock().unwrap();
            let folders = kept.signins.iter().filter(|s| s.kind == Kind::ClaudeHome && !s.pending);
            (kept.mcp.iter().cloned().collect(), folders.map(|s| self.home.join("claude-homes").join(&s.id)).collect())
        };
        let mut latest: serde_json::Map<String, serde_json::Value> = names
            .iter()
            .filter_map(|name| {
                read(KEYCHAIN, &format!("{MCP_SIGN_IN}{name}")).and_then(|v| serde_json::from_str(&v).ok()).map(|e| (name.clone(), e))
            })
            .collect();
        let zeros = latest.clone();
        let own = self.claude.lock().unwrap().clone();
        let user_home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".claude");
        let own = (own != user_home).then_some(own);
        for service in std::iter::once(claude_keychain(own.as_deref())).chain(folders.iter().map(|f| claude_keychain(Some(f)))) {
            for (name, entry) in item(&service).and_then(|i| i["mcpOAuth"].as_object().cloned()).unwrap_or_default() {
                if later(&entry, latest.get(&name)) {
                    latest.insert(name, entry);
                }
            }
        }
        let mut kept_names = false;
        for (name, entry) in &latest {
            if zeros.get(name) != Some(entry) && store(KEYCHAIN, &format!("{MCP_SIGN_IN}{name}"), Some(&entry.to_string())).is_ok() {
                kept_names |= self.kept.lock().unwrap().mcp.insert(name.clone());
            }
        }
        if kept_names {
            let _ = self.persist(&self.kept.lock().unwrap());
        }
        let Some(folder) = into else { return };
        // ponytail: a Claude started in the folder between this look and the write below (milliseconds) isn't seen.
        if (self.in_use.lock().unwrap())(folder) {
            return;
        }
        let service = claude_keychain(Some(folder));
        let Some(text) = read(&service, &user) else { return };
        let Ok(theirs) = serde_json::from_str::<serde_json::Value>(&text) else { return };
        let mut renewed: Vec<(String, serde_json::Value)> =
            latest.into_iter().filter(|(name, entry)| later(entry, theirs["mcpOAuth"].get(name))).collect();
        // The item goes on one line of `security -i`: as many as fit, the servers used last first (Claude Code renews
        // a server's sign-in as it uses it, so the latest to expire); the rest wait for the folder's next start.
        renewed.sort_by_key(|(_, entry)| std::cmp::Reverse(entry["expiresAt"].as_i64().unwrap_or(0)));
        let (mut taken, mut left, mut written) = (vec![], vec![], None);
        for (name, entry) in renewed {
            taken.push((name.clone(), entry.to_string()));
            match with_servers(&text, &taken).filter(|item| crate::mcp_servers::fits_keychain(&service, &user, item)) {
                Some(item) => written = Some(item),
                None => {
                    taken.pop();
                    left.push(name)
                }
            }
        }
        if !left.is_empty() {
            eprintln!("zerod: {} has no room for {} on a line of `security -i`: left for its next start", folder.display(), left.join(", "))
        }
        let Some(written) = written else { return };
        if let Err(error) = store(&service, &user, Some(&written)) {
            eprintln!("zerod: couldn't give a Claude folder its MCP sign-ins: {error}")
        }
    }

    /// A Claude Code token signed in again in a folder of its own (`account`, as Claude Code said who signed in there):
    /// the same id, so tasks set to it carry on and its activity and usage stay; the token goes from the Keychain.
    pub fn switched_to_folder(&self, id: &str, account: crate::codex_login::Account) -> Result<SignIn, String> {
        let mut signin = self.get(id).ok_or_else(|| format!("No sign-in {id}"))?;
        signin.kind = Kind::ClaudeHome;
        signin.label = account.email.unwrap_or(signin.label);
        signin.plan = account.plan.or(signin.plan);
        let saved = self.save(signin)?;
        if let Some(store) = self.store.lock().unwrap().clone() {
            store(KEYCHAIN, id, None)?
        }
        Ok(saved)
    }

    fn persist(&self, kept: &Kept) -> Result<(), String> {
        let data = serde_json::to_vec_pretty(kept).map_err(|e| e.to_string())?;
        if let Some(parent) = self.file.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?
        }
        write_private(&self.file, &data)
    }
}

/// When to read an account's usage again, after a read at `now`: `read` what it gave, or None when it failed, the
/// `failures`th time running. A quarter of an hour on, or just after a window resets if sooner (a limit's end seen at
/// once); a failing read less and less often, half an hour apart at most, so a provider that's down isn't hammered.
pub fn next_read(now: i64, read: Option<&crate::model::Usage>, failures: u32) -> i64 {
    let Some(usage) = read else { return now + (60i64 << failures.saturating_sub(1).min(5)).min(30 * 60) };
    let limit = usage.resets_at.filter(|_| usage.limited);
    usage.windows.iter().filter_map(|w| w.resets_at).chain(limit).filter(|at| *at > now).map(|at| at + 30).fold(now + 15 * 60, i64::min)
}

/// Claude Code's Keychain item for a folder (its CLAUDE_CONFIG_DIR; none, the user's own), where it keeps the
/// account's sign-in and its MCP servers' (`mcpOAuth`) as one JSON: its name and a hash of the folder's path.
pub fn claude_keychain(folder: Option<&Path>) -> String {
    match folder {
        None => "Claude Code-credentials".into(),
        Some(folder) => {
            let hash = crate::integrations::sha256(folder.to_string_lossy().as_bytes());
            format!("Claude Code-credentials-{}", hash[..4].iter().map(|b| format!("{b:02x}")).collect::<String>())
        }
    }
}

/// The Keychain account Claude Code keeps its items under: the user's name, as it reads it.
pub fn claude_user() -> String {
    let user = std::env::var("USER").or_else(|_| std::env::var("LOGNAME")).unwrap_or_default();
    let fits = !user.is_empty() && user.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c));
    if fits { user } else { "claude-code-user".into() }
}

/// Whether a Claude Code folder has a process running in it: one whose environment has CLAUDE_CONFIG_DIR set to it (a
/// task's Claude, one the user started there, an MCP server either started). `ps` reads the environment of the user's
/// own processes (not Apple's own programs', which Claude Code isn't). Unsure (`ps` failed) is in use.
pub fn folder_in_use(folder: &Path) -> bool {
    let Ok(output) = std::process::Command::new("/bin/ps").args(["-axE", "-ww", "-o", "command="]).output() else { return true };
    if !output.status.success() {
        return true;
    }
    let wanted = format!("CLAUDE_CONFIG_DIR={}", folder.to_string_lossy());
    String::from_utf8_lossy(&output.stdout).lines().any(|line| {
        line.match_indices(&wanted).any(|(at, _)| {
            let after = &line[at + wanted.len()..];
            line[..at].ends_with(' ') && (after.is_empty() || after.starts_with(' '))
        })
    })
}

/// A folder's item (Claude Code's JSON, as read) with `servers`' sign-ins (name, JSON) put in its `mcpOAuth`: each
/// replacing the one there by that name, or added after them. Every other byte as it was.
fn with_servers(item: &str, servers: &[(String, String)]) -> Option<String> {
    let span = |raw: &serde_json::value::RawValue, within: &str| {
        let start = raw.get().as_ptr() as usize - within.as_ptr() as usize;
        start..start + raw.get().len()
    };
    let top = members(item)?;
    let mut edits: Vec<(std::ops::Range<usize>, String)> = vec![];
    let pair = |name: &str, entry: &str| format!("{}:{entry}", serde_json::Value::from(name));
    match top.iter().find(|(name, _)| name == "mcpOAuth") {
        Some((_, raw)) => {
            let at = span(raw, item);
            let inner = members(raw.get())?;
            let mut added = vec![];
            for (name, entry) in servers {
                match inner.iter().find(|(n, _)| n == name) {
                    Some((_, old)) => {
                        let old = span(old, raw.get());
                        edits.push((at.start + old.start..at.start + old.end, entry.clone()))
                    }
                    None => added.push(pair(name, entry)),
                }
            }
            if !added.is_empty() {
                let close = at.start + raw.get().rfind('}')?;
                let comma = if inner.is_empty() { "" } else { "," };
                edits.push((close..close, format!("{comma}{}", added.join(","))))
            }
        }
        None => {
            let close = item.rfind('}')?;
            let comma = if top.is_empty() { "" } else { "," };
            let all: Vec<String> = servers.iter().map(|(name, entry)| pair(name, entry)).collect();
            edits.push((close..close, format!("{comma}\"mcpOAuth\":{{{}}}", all.join(","))))
        }
    }
    edits.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    let mut written = item.to_string();
    for (range, text) in edits {
        written.replace_range(range, &text)
    }
    serde_json::from_str::<serde_json::Value>(&written).ok().map(|_| written)
}

/// A JSON object's members in order, each value as its own text within `json`.
fn members(json: &str) -> Option<Vec<(String, &serde_json::value::RawValue)>> {
    struct Members;
    impl<'de> serde::de::Visitor<'de> for Members {
        type Value = Vec<(String, &'de serde_json::value::RawValue)>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("an object")
        }
        fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
            let mut all = vec![];
            while let Some(member) = map.next_entry()? {
                all.push(member)
            }
            Ok(all)
        }
    }
    serde::Deserializer::deserialize_map(&mut serde_json::Deserializer::from_str(json), Members).ok()
}

/// Whether what a CLI said ends a turn it finished: Claude Code's result, Codex's turn completed, an ACP prompt's
/// answer (OpenCode) ending its turn. One that failed, or was stopped, isn't.
fn finished(said: &serde_json::Value) -> bool {
    (said["type"] == "result" && said["subtype"] == "success" && said["is_error"] != true)
        || (said["method"] == "turn/completed" && said["params"]["turn"]["status"] == "completed")
        || said["result"]["stopReason"] == "end_turn"
}

/// Whether an MCP server's sign-in is a later one than `than`: one that signs in at all, expiring later (a refresh), or
/// able to refresh where the other isn't.
fn later(entry: &serde_json::Value, than: Option<&serde_json::Value>) -> bool {
    let usable = |e: &serde_json::Value| e["accessToken"].is_string() || e["refreshToken"].is_string();
    let rank = |e: &serde_json::Value| (e["expiresAt"].as_i64().unwrap_or(0), e["refreshToken"].is_string());
    usable(entry) && than.is_none_or(|than| !usable(than) || rank(entry) > rank(than))
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
pub(crate) fn name(cli: Provider) -> String {
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
