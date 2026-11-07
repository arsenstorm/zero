//! Settings › Git: the identity agents' Git uses. Their commits keep the user as author (as the repo has them) and are
//! committed and signed by an identity of the agents' own, with a signing key Zero keeps; pushes go over HTTPS with the
//! user's GitHub CLI sign-in. Nothing then waits on the user's own key (1Password locked, the Mac left at home). Only
//! the agents' processes get it, as environment: the user's Git config, and their own terminal, are left as they are.

use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use serde::{Deserialize, Serialize};

use crate::process::Variables;

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentGit {
    pub enabled: bool,
    /// The GitHub account that commits and signs, by its login; its name and noreply email come from GitHub.
    #[serde(default)]
    pub login: String,
    /// The committer, whose GitHub account has the signing key: its name and (noreply) email.
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub email: String,
    /// GitHub over HTTPS, with the GitHub CLI's sign-in, in place of SSH (which may be behind the user's own agent).
    #[serde(default)]
    pub https: bool,
    /// Only agents working in these folders (or under them); none, every folder.
    #[serde(default)]
    pub folders: Vec<String>,
}

/// Where Zero keeps the agents' signing key, readable by the user alone.
pub fn key_path(home: &Path) -> PathBuf { home.join("git-signing-key") }

static CURRENT: LazyLock<Mutex<Option<(AgentGit, PathBuf)>>> = LazyLock::new(Default::default);

/// What agents' processes get from here on (the settings as saved, and the key's place).
pub fn set(settings: Option<AgentGit>, key: PathBuf) {
    *CURRENT.lock().unwrap() = settings.map(|s| (s, key));
}

/// The environment for an agent's process working in `cwd`, as the settings stand.
pub fn variables(cwd: &Path) -> Variables {
    match CURRENT.lock().unwrap().as_ref() {
        Some((settings, key)) => variables_for(settings, key, cwd),
        None => vec![],
    }
}

/// The environment `settings` give an agent working in `cwd`: none when they're off, there's no key yet, or `cwd` is
/// outside their folders.
pub fn variables_for(settings: &AgentGit, key: &Path, cwd: &Path) -> Variables {
    let inside = settings.folders.is_empty() || settings.folders.iter().any(|f| cwd.starts_with(expand(f)));
    if !settings.enabled || !key.exists() || !inside || settings.email.trim().is_empty() { return vec![] }
    let mut config = vec![
        ("gpg.format", "ssh".to_string()),
        ("gpg.ssh.program", "ssh-keygen".to_string()),
        ("user.signingKey", key.to_string_lossy().to_string()),
        ("commit.gpgSign", "true".to_string()),
        ("tag.gpgSign", "true".to_string()),
    ];
    if settings.https {
        config.push(("url.https://github.com/.insteadOf", "git@github.com:".to_string()));
        config.push(("url.https://github.com/.insteadOf", "ssh://git@github.com/".to_string()));
    }
    let mut vars: Variables = vec![
        ("GIT_COMMITTER_NAME".into(), if settings.name.trim().is_empty() { settings.email.clone() } else { settings.name.clone() }),
        ("GIT_COMMITTER_EMAIL".into(), settings.email.clone()),
        ("GIT_CONFIG_COUNT".into(), config.len().to_string()),
    ];
    for (i, (key, value)) in config.into_iter().enumerate() {
        vars.push((format!("GIT_CONFIG_KEY_{i}"), key.to_string()));
        vars.push((format!("GIT_CONFIG_VALUE_{i}"), value));
    }
    vars
}

/// A folder as the user wrote it, "~/" as their home.
fn expand(folder: &str) -> PathBuf {
    match folder.strip_prefix("~/") {
        Some(rest) => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(rest),
        None => PathBuf::from(folder),
    }
}

/// Takes the private key at `from` as the agents' signing key: checked to be one ssh-keygen can sign with (no
/// passphrase, since no one is there to type it), copied where Zero keeps it, readable by the user alone. Gives its
/// public half.
pub fn take_key(from: &Path, home: &Path) -> Result<String, String> {
    let public = std::process::Command::new("ssh-keygen").args(["-y", "-P", "", "-f"]).arg(from).output().map_err(|e| e.to_string())?;
    if !public.status.success() { return Err("That isn't a private key Zero can sign with: it needs one without a passphrase".into()) }
    let to = key_path(home);
    std::fs::copy(from, &to).map_err(|e| format!("Couldn't keep the key: {e}"))?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&public.stdout).trim().to_string())
}

/// The key's public half, when there is one.
pub fn public_key(home: &Path) -> Option<String> {
    let output = std::process::Command::new("ssh-keygen").args(["-y", "-P", "", "-f"]).arg(key_path(home)).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// The committer an account's `gh api users/<login>` answer gives: its name (else its login) and its noreply email.
pub fn committer(user: &str) -> Option<(String, String)> {
    let user: serde_json::Value = serde_json::from_str(user).ok()?;
    let (id, login) = (user["id"].as_i64()?, user["login"].as_str()?);
    let name = user["name"].as_str().filter(|n| !n.trim().is_empty()).unwrap_or(login);
    Some((name.to_string(), format!("{id}+{login}@users.noreply.github.com")))
}

/// The title a signing key has among an account's (`gh api users/<login>/ssh_signing_keys`), matched by its key, not
/// its comment.
pub fn listed_as(keys: &str, public: &str) -> Option<String> {
    let body = |key: &str| key.split_whitespace().take(2).collect::<Vec<_>>().join(" ");
    let keys: Vec<serde_json::Value> = serde_json::from_str(keys).ok()?;
    keys.iter().find(|k| k["key"].as_str().map(body) == Some(body(public))).map(|k| k["title"].as_str().unwrap_or("Signing key").to_string())
}

/// `gh api <path>`, with the user's own GitHub CLI and sign-in.
async fn gh(path: &str) -> Result<String, String> {
    let argv = crate::adapter::login_shell(&["gh", "api", path]);
    let output = tokio::process::Command::new(&argv[0]).args(&argv[1..]).stdin(std::process::Stdio::null()).output().await.map_err(|e| e.to_string())?;
    if !output.status.success() { return Err(String::from_utf8_lossy(&output.stderr).trim().to_string()) }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// The committer for GitHub account `login`, as GitHub has it.
pub async fn account(login: &str) -> Result<(String, String), String> {
    let login = login.trim().trim_start_matches('@');
    if login.is_empty() || !login.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') { return Err("That isn't a GitHub username".into()) }
    committer(&gh(&format!("users/{login}")).await.map_err(|_| format!("GitHub has no account {login}"))?).ok_or_else(|| format!("GitHub has no account {login}"))
}

/// Whether the agents' key is one of `login`'s signing keys, by its title there; none when it isn't, or GitHub can't say.
pub async fn on_github(login: &str, home: &Path) -> Option<String> {
    let public = public_key(home)?;
    listed_as(&gh(&format!("users/{login}/ssh_signing_keys")).await.ok()?, &public)
}
