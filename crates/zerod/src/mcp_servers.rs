//! MCP servers the user sets up once in Zero (mcp-servers.json), given to each task's CLI as it starts, on top of the
//! CLI's own: each for every workspace, or only the workspaces it's put in. A value (an env var, a header) is kept in
//! the Keychain (the default), fetched by the server's own command (nothing kept), or kept in the file (mode 0600).
//! Zero's own MCP server (mcp.rs) isn't one of these: it's set up with each CLI by the app.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

/// The Keychain service a value is kept under; its account is "<server id>.<name>".
pub const KEYCHAIN: &str = "Zero MCP";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct McpServer {
    #[serde(default)]
    pub id: String,
    pub name: String,
    /// A local server: what runs it, and its arguments.
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    /// A remote one: where it is.
    #[serde(default)]
    pub url: Option<String>,
    /// A local server's environment; a remote one's headers.
    #[serde(default)]
    pub env: Vec<Value>,
    #[serde(default)]
    pub headers: Vec<Value>,
    /// The workspaces it's for; none, every workspace.
    #[serde(default)]
    pub workspaces: Vec<String>,
    #[serde(default = "on")]
    pub enabled: bool,
    /// A local server started when first used: until then `zerod mcp lazy` (mcp_lazy.rs) stands in for it.
    #[serde(default)]
    pub lazy: bool,
}

fn on() -> bool {
    true
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Value {
    pub name: String,
    /// Kept in the file only when that's where it comes from.
    #[serde(default)]
    pub value: Option<String>,
    #[serde(default)]
    pub from: Source,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    #[default]
    Keychain,
    /// The server's command gets it itself (`op run -- …`, a variable the user sets): Zero keeps and passes nothing.
    Command,
    File,
}

/// A server as a CLI is given it: its values read, the ones there is no value for left out.
#[derive(Clone, Debug, PartialEq)]
pub struct Resolved {
    pub id: String,
    pub name: String,
    pub command: Option<String>,
    pub args: Vec<String>,
    pub url: Option<String>,
    pub env: Vec<(String, String)>,
    pub headers: Vec<(String, String)>,
}

impl McpServer {
    /// How it runs, in a line: its command and arguments or its URL, when it starts, and the values it's given.
    pub fn describe(&self) -> String {
        let how = match (&self.command, &self.url) {
            (Some(command), _) => [command].into_iter().chain(&self.args).cloned().collect::<Vec<_>>().join(" "),
            (None, Some(url)) => url.clone(),
            (None, None) => String::new(),
        };
        let names: Vec<&str> = self.env.iter().chain(&self.headers).map(|v| v.name.as_str()).collect();
        let lazy = if self.lazy { ", started when first used" } else { "" };
        let given = if names.is_empty() { String::new() } else { format!(", given {}", names.join(", ")) };
        format!("`{how}`{lazy}{given}")
    }

    /// Its values, from where each is kept; `keychain` reads one (service, account).
    pub fn resolve(&self, keychain: &dyn Fn(&str, &str) -> Option<String>) -> Resolved {
        let read = |values: &[Value]| -> Vec<(String, String)> {
            values
                .iter()
                .filter_map(|v| match v.from {
                    Source::File => v.value.clone().map(|value| (v.name.clone(), value)),
                    Source::Keychain => keychain(KEYCHAIN, &format!("{}.{}", self.id, v.name)).map(|value| (v.name.clone(), value)),
                    Source::Command => None,
                })
                .collect()
        };
        // Started when first used: zerod's stand-in in its place, given what it stands in for.
        let stand_in = std::env::current_exe().ok().map(|exe| exe.to_string_lossy().to_string()).filter(|_| self.lazy);
        let (command, args) = match (&self.command, stand_in) {
            (Some(command), Some(zerod)) => {
                (Some(zerod), ["mcp", "lazy", command].into_iter().map(String::from).chain(self.args.iter().cloned()).collect())
            }
            _ => (self.command.clone(), self.args.clone()),
        };
        Resolved {
            id: self.id.clone(),
            name: self.name.clone(),
            command,
            args,
            url: self.url.clone(),
            env: read(&self.env),
            headers: read(&self.headers),
        }
    }
}

/// What a transcript keeps in place of a server's value (an env var's, a header's).
pub const HIDDEN: &str = "<kept out of the transcript>";

/// A line to or from a CLI as its transcript keeps it: the servers it gives (Codex's thread config, ACP's
/// `mcpServers`, Claude's `mcp_set_servers`) or says back (Claude's `mcp_status`) without their values, which may be
/// secrets. None for a line that has none.
pub fn redacted(message: &serde_json::Value) -> Option<serde_json::Value> {
    let method = message["method"].as_str();
    if message["type"] == "control_response" {
        message["response"]["response"]["mcpServers"].as_array()?;
        let mut kept = message.clone();
        let servers = kept["response"]["response"]["mcpServers"].as_array_mut()?;
        servers.iter_mut().filter_map(|s| s.get_mut("config")).for_each(hide);
        return Some(kept);
    }
    let carries = match method {
        Some("thread/start" | "thread/resume") => {
            message["params"]["config"].as_object().is_some_and(|c| c.keys().any(|k| k.starts_with("mcp_servers.")))
        }
        Some("session/new" | "session/resume") => message["params"]["mcpServers"].as_array().is_some_and(|s| !s.is_empty()),
        _ => message["request"]["subtype"] == "mcp_set_servers",
    };
    if !carries {
        return None;
    }
    let mut kept = message.clone();
    let servers: Vec<&mut serde_json::Value> = match method {
        Some("thread/start" | "thread/resume") => kept["params"]["config"]
            .as_object_mut()
            .map(|c| c.iter_mut().filter(|(k, _)| k.starts_with("mcp_servers.")).map(|(_, v)| v).collect())
            .unwrap_or_default(),
        Some(_) => kept["params"]["mcpServers"].as_array_mut().map(|s| s.iter_mut().collect()).unwrap_or_default(),
        None => kept["request"]["servers"].as_object_mut().map(|s| s.values_mut().collect()).unwrap_or_default(),
    };
    servers.into_iter().for_each(hide);
    Some(kept)
}

/// A server's values (an env var's, a header's: an object of them, or ACP's list) as HIDDEN.
fn hide(server: &mut serde_json::Value) {
    for field in ["env", "headers", "http_headers"] {
        match server.get_mut(field) {
            Some(serde_json::Value::Object(values)) => values.values_mut().for_each(|v| *v = HIDDEN.into()),
            Some(serde_json::Value::Array(values)) => values.iter_mut().filter_map(|v| v.get_mut("value")).for_each(|v| *v = HIDDEN.into()),
            _ => {}
        }
    }
}

/// Takes `name` out of each Claude home's needs-auth cache (`homes`/<home>/mcp-needs-auth-cache.json): Claude Code
/// skips an HTTP server it found wanting a sign-in in the last 15 minutes by its name alone, so a server changed
/// since would be skipped for what it was. A home's file is often a link to the user's own: it's changed where it
/// is, and stays a link.
pub fn clear_needs_auth(homes: &Path, name: &str) {
    let files: std::collections::HashSet<PathBuf> = std::fs::read_dir(homes)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|home| std::fs::canonicalize(home.path().join("mcp-needs-auth-cache.json")).ok())
        .collect();
    for file in files {
        let Some(mut cache) = std::fs::read(&file).ok().and_then(|d| serde_json::from_slice::<serde_json::Value>(&d).ok()) else {
            continue;
        };
        if cache.as_object_mut().and_then(|c| c.remove(name)).is_none() {
            continue;
        }
        let partial = file.with_extension("zero-partial");
        if std::fs::write(&partial, cache.to_string()).and_then(|_| std::fs::rename(&partial, &file)).is_err() {
            eprintln!("zerod: couldn't clear {name} from {}", file.display())
        }
    }
}

/// The Keychain's value for an account, through the `security` tool (as the app keeps its own secrets): no prompt.
pub fn keychain(service: &str, account: &str) -> Option<String> {
    if !own_item(service) {
        return None;
    }
    let output = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", service, "-a", account, "-w"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?.trim_end_matches('\n').to_string();
    (!value.is_empty()).then_some(value)
}

/// Writes a value to the Keychain, never on a command line: `security -i` is given the command on its input. Only
/// `security` writes an item and leaves it trusting `security` (Claude Code's items, and the ones Zero reads through
/// it): the Security framework, called from zerod, makes the item zerod's, and `security` (Claude Code with it) then
/// can't read it. None removes it (names alone on the command line). The value as read back is checked.
// ponytail: a line of `security -i` holds about 4 KB, so a longer value (a Claude folder's item with many servers'
// sign-ins) isn't written; the Security framework can't keep its item `security`'s.
pub fn keychain_write(service: &str, account: &str, value: Option<&str>) -> Result<(), String> {
    use std::io::Write;
    if !own_item(service) {
        return Err(format!("a dev zerod keeps out of {service}"));
    }
    let Some(value) = value else {
        let output = std::process::Command::new("/usr/bin/security")
            .args(["delete-generic-password", "-s", service, "-a", account])
            .output()
            .map_err(|e| e.to_string())?;
        // 44: there was none.
        return if output.status.success() || output.status.code() == Some(44) { Ok(()) } else { Err("the Keychain refused".into()) };
    };
    if !fits_keychain(service, account, value) {
        return Err(format!("too long to give the Keychain without a command line ({} bytes)", value.len()));
    }
    let line = security_line(service, account, value);
    let mut child = std::process::Command::new("/usr/bin/security")
        .arg("-i")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())?;
    child.stdin.take().ok_or("no input")?.write_all(line.as_bytes()).map_err(|e| e.to_string())?;
    child.wait().map_err(|e| e.to_string())?;
    // `security -i` ends well whatever its command did: what it kept is how it went.
    if keychain(service, account).as_deref() != Some(value) {
        return Err("the Keychain didn't keep it".into());
    }
    Ok(())
}

/// The longest line `security -i` reads whole (4096 bytes, with room to spare).
const SECURITY_LINE: usize = 4032;

/// Whether this zerod may touch a Keychain item: none in a dev build, which runs on a home of its own where the
/// Keychain finds no keychain (a write there asks the user, offering to reset theirs), and mustn't read the user's.
fn own_item(_service: &str) -> bool {
    !cfg!(feature = "dev")
}

/// Whether `keychain_write` can give the Keychain this value: on one line of `security -i`, as it's quoted there.
pub fn fits_keychain(service: &str, account: &str, value: &str) -> bool {
    security_line(service, account, value).len() <= SECURITY_LINE && ![service, account, value].iter().any(|s| s.contains(['\n', '\r']))
}

/// The command `security -i` is given to keep a value, each word quoted.
fn security_line(service: &str, account: &str, value: &str) -> String {
    let quoted = |text: &str| format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""));
    format!("add-generic-password -U -a {} -s {} -w {}\n", quoted(account), quoted(service), quoted(value))
}

/// A local server's identity as its CLI is given it (in its environment): a new one starts it again.
pub const STAMP: &str = "ZERO_MCP_STAMP";

pub struct McpServers {
    file: PathBuf,
    list: Mutex<Vec<McpServer>>,
    /// How many times the user has had each started again (Reload), since zerod started.
    reloads: Mutex<std::collections::HashMap<String, u32>>,
}

impl McpServers {
    pub fn open(home: &Path) -> McpServers {
        let file = home.join("mcp-servers.json");
        let list = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        McpServers { file, list: Mutex::new(list), reloads: Mutex::default() }
    }

    /// Started again in every task that has it (Settings' Reload): its stamp changes.
    pub fn reload(&self, id: &str) {
        *self.reloads.lock().unwrap().entry(id.into()).or_default() += 1
    }

    /// A local server's stamp: its files as they are now, and its reloads.
    pub fn stamp(&self, server: &Resolved) -> Option<String> {
        let command = server.command.as_deref()?;
        let reloads = self.reloads.lock().unwrap().get(&server.id).copied().unwrap_or_default();
        Some(format!("{}-{reloads}", crate::mcp_lazy::stamp(command, &server.args)))
    }

    pub fn list(&self) -> Vec<McpServer> {
        self.list.lock().unwrap().clone()
    }

    /// The servers a workspace's tasks get: those for every workspace and those put in it, turned on.
    pub fn for_workspace(&self, workspace: &str) -> Vec<McpServer> {
        self.list().into_iter().filter(|s| s.enabled && (s.workspaces.is_empty() || s.workspaces.iter().any(|w| w == workspace))).collect()
    }

    /// What an agent's proposed server becomes once the user approves it: a change of the one there of that id or
    /// name (its id, name, workspaces and being on kept, and where the values of the names it still has are kept,
    /// the values themselves left to `save`), else a new one for `workspace`. With the one it changes, as it is now.
    /// `scope`, if the agent named one, is its workspaces either way (none: every workspace).
    pub fn proposal(&self, mut proposed: McpServer, workspace: &str, scope: Option<Vec<String>>) -> (McpServer, Option<McpServer>) {
        let key = proposed.name.trim().to_lowercase();
        let was = self.list().into_iter().find(|s| s.id == key || s.name.to_lowercase() == key);
        match &was {
            Some(old) => {
                (proposed.id, proposed.name, proposed.workspaces, proposed.enabled) =
                    (old.id.clone(), old.name.clone(), old.workspaces.clone(), old.enabled);
                for (new, old) in [(&mut proposed.env, &old.env), (&mut proposed.headers, &old.headers)] {
                    for value in new.iter_mut() {
                        if let Some(kept) = old.iter().find(|o| o.name == value.name) {
                            value.from = kept.from
                        }
                    }
                }
            }
            None => (proposed.id, proposed.workspaces) = (String::new(), vec![workspace.into()]),
        }
        if let Some(scope) = scope {
            proposed.workspaces = scope
        }
        (proposed, was)
    }

    /// The servers as an agent may read them: no value.
    pub fn for_agent(&self) -> Vec<McpServer> {
        let mut list = self.list();
        for value in list.iter_mut().flat_map(|s| s.env.iter_mut().chain(s.headers.iter_mut())) {
            value.value = None
        }
        list
    }

    /// A new server (no id: one made from its name) or a changed one. A value kept elsewhere isn't written here; one
    /// kept here and given none (a change an agent proposed, which never has values) keeps what it was.
    pub fn save(&self, mut server: McpServer) -> Result<McpServer, String> {
        server.name = server.name.trim().to_string();
        if server.name.is_empty() {
            return Err("A server needs a name".into());
        }
        let blank = |s: &Option<String>| s.as_deref().is_none_or(|s| s.trim().is_empty());
        if blank(&server.command) && blank(&server.url) {
            return Err("A server runs a command or is at a URL".into());
        }
        for value in server.env.iter_mut().chain(server.headers.iter_mut()) {
            if value.from != Source::File {
                value.value = None
            }
        }
        let mut list = self.list.lock().unwrap();
        if server.id.is_empty() {
            let base: String = server
                .name
                .to_lowercase()
                .chars()
                .map(|c| if c.is_alphanumeric() { c } else { '-' })
                .collect::<String>()
                .split('-')
                .filter(|p| !p.is_empty())
                .collect::<Vec<_>>()
                .join("-");
            let base = if base.is_empty() { "server".to_string() } else { base };
            let mut id = base.clone();
            let mut n = 2;
            while list.iter().any(|s| s.id == id) {
                id = format!("{base}-{n}");
                n += 1
            }
            server.id = id;
            list.push(server.clone());
        } else if let Some(kept) = list.iter_mut().find(|s| s.id == server.id) {
            for (new, old) in [(&mut server.env, &kept.env), (&mut server.headers, &kept.headers)] {
                for value in new.iter_mut().filter(|v| v.from == Source::File && v.value.is_none()) {
                    value.value = old.iter().find(|o| o.name == value.name && o.from == Source::File).and_then(|o| o.value.clone())
                }
            }
            *kept = server.clone();
        } else {
            return Err(format!("No server {}", server.id));
        }
        self.keep(&list)?;
        Ok(server)
    }

    pub fn delete(&self, id: &str) -> Result<(), String> {
        let mut list = self.list.lock().unwrap();
        let before = list.len();
        list.retain(|s| s.id != id);
        if list.len() == before {
            return Err(format!("No server {id}"));
        }
        self.keep(&list)
    }

    fn keep(&self, list: &[McpServer]) -> Result<(), String> {
        let data = serde_json::to_vec_pretty(list).map_err(|e| e.to_string())?;
        std::fs::write(&self.file, data).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&self.file, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }
}
