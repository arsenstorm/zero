//! Settings › Git: process-local Git identity, signing, and optional GitHub credentials for agents. The default keeps
//! the user's author identity and GitHub CLI sign-in. Opt-in settings make agents authors with a coauthor trailer and
//! give them a separate scoped GitHub token. The user's own terminal and Git config stay as they are.

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
    /// GitHub over HTTPS, with the GitHub CLI's sign-in, in place of SSH (which may be behind the user's own agent); on
    /// its own, with or without agents' own account.
    #[serde(default, rename = "httpsPush")]
    pub https: bool,
    /// The older "https", which held only with agents' own account: read once into `https` (`upgraded`), never kept.
    #[serde(default, rename = "https", skip_serializing)]
    pub old_https: Option<bool>,
    /// Only agents working in these folders (or under them); none, every folder.
    #[serde(default)]
    pub folders: Vec<String>,
    /// Make the agent the author too, with the user named in a coauthor trailer.
    #[serde(default)]
    pub agents_author: bool,
    /// Overrides for the user's identity; empty means the repository's Git config.
    #[serde(default)]
    pub coauthor_name: String,
    #[serde(default)]
    pub coauthor_email: String,
    /// Give agents a separate GitHub token from the Keychain.
    #[serde(default)]
    pub scoped_token: bool,
}

impl AgentGit {
    /// An older setting's "https" as it held: only with agents' own account on.
    pub fn upgraded(mut self) -> Self {
        if let Some(old) = self.old_https.take() {
            self.https = old && self.enabled;
        }
        self
    }
}

pub const TOKEN_SERVICE: &str = "Zero GitHub token";
pub const TOKEN_ACCOUNT: &str = "agents";

const HOOKS: &[&str] = &[
    "applypatch-msg",
    "pre-applypatch",
    "post-applypatch",
    "pre-commit",
    "prepare-commit-msg",
    "commit-msg",
    "post-commit",
    "pre-merge-commit",
    "post-merge",
    "pre-rebase",
    "post-checkout",
    "post-rewrite",
    "pre-push",
    "pre-auto-gc",
    "reference-transaction",
    "push-to-checkout",
    "pre-receive",
    "update",
    "post-receive",
    "post-update",
    "proc-receive",
    "sendemail-validate",
];

const HOOK: &str = r##"#!/bin/sh
hook=${0##*/}
# Ignore only Zero's process-local override; preserve the repository, global, and system hook setting.
original=$(GIT_CONFIG_COUNT=0 git config --path --get core.hooksPath 2>/dev/null) || original=
if [ -z "$original" ]; then
  original="$(git rev-parse --git-common-dir)/hooks"
fi
case "$original" in /*) ;; *) original="$PWD/$original" ;; esac
if [ -x "$original/$hook" ] && [ "$original/$hook" != "$0" ]; then
  "$original/$hook" "$@" || exit $?
fi
if [ "$hook" != commit-msg ] || [ -z "$ZERO_GIT_AUTHOR_EMAIL" ]; then exit 0; fi
if [ "$GIT_AUTHOR_EMAIL" != "$ZERO_GIT_AUTHOR_EMAIL" ]; then exit 0; fi
name=${ZERO_GIT_COAUTHOR_NAME:-$(GIT_CONFIG_COUNT=0 git config user.name)}
email=${ZERO_GIT_COAUTHOR_EMAIL:-$(GIT_CONFIG_COUNT=0 git config user.email)}
if [ -z "$name" ] || [ -z "$email" ]; then
  echo 'Zero needs the user name and email for the coauthor trailer (set them in Git config or Settings > Git).' >&2
  exit 1
fi
if grep -i '^Co-authored-by:' "$1" | grep -Fq "<$email>"; then exit 0; fi
git interpret-trailers --in-place --trailer "Co-authored-by: $name <$email>" "$1"
"##;

const CREDENTIAL: &str = r#"#!/bin/sh
[ "$1" = get ] || exit 0
protocol= host=
while IFS='=' read -r key value; do
  case "$key" in protocol) protocol=$value ;; host) host=$value ;; esac
done
if [ "$protocol" = https ] && [ "$host" = github.com ] && [ -n "$GH_TOKEN" ]; then
  printf 'username=x-access-token\npassword=%s\n' "$GH_TOKEN"
fi
"#;

fn script(path: &Path, contents: &str) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    if std::fs::read_to_string(path).ok().as_deref() != Some(contents) {
        std::fs::write(path, contents)?;
    }
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
}

fn install_helpers(home: &Path) -> std::io::Result<(PathBuf, PathBuf)> {
    let hooks = home.join("git-hooks");
    std::fs::create_dir_all(&hooks)?;
    for hook in HOOKS {
        script(&hooks.join(hook), HOOK)?;
    }
    let credential = home.join("git-credential");
    script(&credential, CREDENTIAL)?;
    Ok((hooks, credential))
}

/// Where Zero keeps the agents' signing key, readable by the user alone.
pub fn key_path(home: &Path) -> PathBuf {
    home.join("git-signing-key")
}

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

/// The environment `settings` give an agent working in `cwd`; signing and token use are independent opt-ins.
pub fn variables_for(settings: &AgentGit, key: &Path, cwd: &Path) -> Variables {
    let token = if settings.scoped_token { crate::mcp_servers::keychain(TOKEN_SERVICE, TOKEN_ACCOUNT) } else { None };
    variables_for_with_token(settings, key, cwd, token)
}

/// The same environment with a supplied token, so tests never read the user's Keychain.
pub fn variables_for_with_token(settings: &AgentGit, key: &Path, cwd: &Path, token: Option<String>) -> Variables {
    let inside = settings.folders.is_empty() || settings.folders.iter().any(|f| cwd.starts_with(expand(f)));
    if !inside {
        return vec![];
    }
    let identity = settings.enabled && key.exists() && !settings.email.trim().is_empty();
    let mut config = Vec::new();
    if identity {
        config.extend([
            ("gpg.format", "ssh".to_string()),
            ("gpg.ssh.program", "ssh-keygen".to_string()),
            ("user.signingKey", key.to_string_lossy().to_string()),
            ("commit.gpgSign", "true".to_string()),
            ("tag.gpgSign", "true".to_string()),
        ]);
    }
    let token = token.filter(|_| settings.scoped_token);
    if settings.https || token.is_some() {
        config.push(("url.https://github.com/.insteadOf", "git@github.com:".to_string()));
        config.push(("url.https://github.com/.insteadOf", "ssh://git@github.com/".to_string()));
    }
    let home = key.parent().unwrap_or_else(|| Path::new("/"));
    let helpers = if (identity && settings.agents_author) || settings.scoped_token { install_helpers(home).ok() } else { None };
    if identity
        && settings.agents_author
        && let Some((hooks, _)) = &helpers
    {
        config.push(("core.hooksPath", hooks.to_string_lossy().to_string()));
    }
    if token.is_some()
        && let Some((_, credential)) = &helpers
    {
        // Empty helper clears inherited helpers; the next one answers for github.com only.
        config.push(("credential.helper", String::new()));
        config.push(("credential.helper", credential.to_string_lossy().to_string()));
    }
    if config.is_empty() {
        return vec![];
    }
    let mut vars: Variables = Vec::new();
    if identity {
        vars.extend([
            ("GIT_COMMITTER_NAME".into(), if settings.name.trim().is_empty() { settings.email.clone() } else { settings.name.clone() }),
            ("GIT_COMMITTER_EMAIL".into(), settings.email.clone()),
        ]);
    }
    vars.push(("GIT_CONFIG_COUNT".into(), config.len().to_string()));
    if identity && settings.agents_author && helpers.is_some() {
        let name = if settings.name.trim().is_empty() { &settings.email } else { &settings.name };
        vars.extend([
            ("GIT_AUTHOR_NAME".into(), name.clone()),
            ("GIT_AUTHOR_EMAIL".into(), settings.email.clone()),
            ("ZERO_GIT_AUTHOR_EMAIL".into(), settings.email.clone()),
            ("ZERO_GIT_COAUTHOR_NAME".into(), settings.coauthor_name.clone()),
            ("ZERO_GIT_COAUTHOR_EMAIL".into(), settings.coauthor_email.clone()),
        ]);
    }
    if let Some(token) = token {
        vars.push(("GH_TOKEN".into(), token));
    }
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
    if !public.status.success() {
        return Err("That isn't a private key Zero can sign with: it needs one without a passphrase".into());
    }
    let to = key_path(home);
    std::fs::copy(from, &to).map_err(|e| format!("Couldn't keep the key: {e}"))?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&public.stdout).trim().to_string())
}

/// The key's public half, when there is one.
pub fn public_key(home: &Path) -> Option<String> {
    // Kept until the key file changes: `settings` asks for it on every call (ssh-keygen each time, ~4 ms).
    static KEPT: Mutex<Option<(PathBuf, std::time::SystemTime, Option<String>)>> = Mutex::new(None);
    let path = key_path(home);
    let changed = std::fs::metadata(&path).and_then(|m| m.modified()).ok()?;
    if let Some((kept, at, key)) = KEPT.lock().unwrap().as_ref()
        && *kept == path
        && *at == changed
    {
        return key.clone();
    }
    let output = std::process::Command::new("ssh-keygen").args(["-y", "-P", "", "-f"]).arg(&path).output().ok()?;
    let key = output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_string());
    *KEPT.lock().unwrap() = Some((path, changed, key.clone()));
    key
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
    keys.iter()
        .find(|k| k["key"].as_str().map(body) == Some(body(public)))
        .map(|k| k["title"].as_str().unwrap_or("Signing key").to_string())
}

/// `gh api <path>`, with the user's own GitHub CLI and sign-in.
async fn gh(path: &str) -> Result<String, String> {
    let argv = crate::adapter::on_login_path(&["gh", "api", path]);
    let output = tokio::process::Command::new(&argv[0])
        .args(&argv[1..])
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// The committer for GitHub account `login`, as GitHub has it.
pub async fn account(login: &str) -> Result<(String, String), String> {
    let login = login.trim().trim_start_matches('@');
    if login.is_empty() || !login.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err("That isn't a GitHub username".into());
    }
    committer(&gh(&format!("users/{login}")).await.map_err(|_| format!("GitHub has no account {login}"))?)
        .ok_or_else(|| format!("GitHub has no account {login}"))
}

/// Whether the agents' key is one of `login`'s signing keys, by its title there; none when it isn't, or GitHub can't say.
pub async fn on_github(login: &str, home: &Path) -> Option<String> {
    let public = public_key(home)?;
    listed_as(&gh(&format!("users/{login}/ssh_signing_keys")).await.ok()?, &public)
}

/// Only the GitHub CLI checks a saved token. Return public account and expiry metadata, never the token or gh's stderr.
pub async fn token_status() -> serde_json::Value {
    let Some(token) = crate::mcp_servers::keychain(TOKEN_SERVICE, TOKEN_ACCOUNT) else {
        return serde_json::json!({"configured": false});
    };
    let argv = crate::adapter::on_login_path(&["gh", "api", "--include", "user"]);
    let output = tokio::process::Command::new(&argv[0])
        .args(&argv[1..])
        .env("GH_TOKEN", token)
        .env("GH_HOST", "github.com")
        .stdin(std::process::Stdio::null())
        .output()
        .await;
    let Ok(output) = output else { return serde_json::json!({"configured": true, "error": "Couldn't check the token with GitHub"}) };
    if !output.status.success() {
        return serde_json::json!({"configured": true, "error": "GitHub didn't accept this token"});
    }
    let response = String::from_utf8_lossy(&output.stdout);
    let user = response.find('{').and_then(|start| serde_json::from_str::<serde_json::Value>(&response[start..]).ok());
    let login = user.as_ref().and_then(|user| user["login"].as_str()).unwrap_or("");
    let expiry = response.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("github-authentication-token-expiration").then(|| value.trim())
    });
    serde_json::json!({"configured": true, "login": login, "expires": expiry})
}
