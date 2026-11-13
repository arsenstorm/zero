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

/// The Keychain's value for an account, through the `security` tool (as the app keeps its own secrets): no prompt.
pub fn keychain(service: &str, account: &str) -> Option<String> {
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

/// Whether `keychain_write` can give the Keychain this value: on one line of `security -i`, as it's quoted there.
pub fn fits_keychain(service: &str, account: &str, value: &str) -> bool {
    security_line(service, account, value).len() <= SECURITY_LINE && ![service, account, value].iter().any(|s| s.contains(['\n', '\r']))
}

/// The command `security -i` is given to keep a value, each word quoted.
fn security_line(service: &str, account: &str, value: &str) -> String {
    let quoted = |text: &str| format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""));
    format!("add-generic-password -U -a {} -s {} -w {}\n", quoted(account), quoted(service), quoted(value))
}

pub struct McpServers {
    file: PathBuf,
    list: Mutex<Vec<McpServer>>,
}

impl McpServers {
    pub fn open(home: &Path) -> McpServers {
        let file = home.join("mcp-servers.json");
        let list = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        McpServers { file, list: Mutex::new(list) }
    }

    pub fn list(&self) -> Vec<McpServer> {
        self.list.lock().unwrap().clone()
    }

    /// The servers a workspace's tasks get: those for every workspace and those put in it, turned on.
    pub fn for_workspace(&self, workspace: &str) -> Vec<McpServer> {
        self.list().into_iter().filter(|s| s.enabled && (s.workspaces.is_empty() || s.workspaces.iter().any(|w| w == workspace))).collect()
    }

    /// A new server (no id: one made from its name) or a changed one. A value kept elsewhere isn't written here.
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
