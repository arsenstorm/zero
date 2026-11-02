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
}

fn on() -> bool { true }

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
            values.iter().filter_map(|v| match v.from {
                Source::File => v.value.clone().map(|value| (v.name.clone(), value)),
                Source::Keychain => keychain(KEYCHAIN, &format!("{}.{}", self.id, v.name)).map(|value| (v.name.clone(), value)),
                Source::Command => None,
            }).collect()
        };
        Resolved { id: self.id.clone(), name: self.name.clone(), command: self.command.clone(), args: self.args.clone(), url: self.url.clone(),
                   env: read(&self.env), headers: read(&self.headers) }
    }
}

/// The Keychain's value for an account, through the `security` tool (as the app keeps its own secrets): no prompt.
pub fn keychain(service: &str, account: &str) -> Option<String> {
    let output = std::process::Command::new("/usr/bin/security").args(["find-generic-password", "-s", service, "-a", account, "-w"]).output().ok()?;
    if !output.status.success() { return None }
    let value = String::from_utf8(output.stdout).ok()?.trim_end_matches('\n').to_string();
    (!value.is_empty()).then_some(value)
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

    pub fn list(&self) -> Vec<McpServer> { self.list.lock().unwrap().clone() }

    /// The servers a workspace's tasks get: those for every workspace and those put in it, turned on.
    pub fn for_workspace(&self, workspace: &str) -> Vec<McpServer> {
        self.list().into_iter().filter(|s| s.enabled && (s.workspaces.is_empty() || s.workspaces.iter().any(|w| w == workspace))).collect()
    }

    /// A new server (no id: one made from its name) or a changed one. A value kept elsewhere isn't written here.
    pub fn save(&self, mut server: McpServer) -> Result<McpServer, String> {
        server.name = server.name.trim().to_string();
        if server.name.is_empty() { return Err("A server needs a name".into()) }
        let blank = |s: &Option<String>| s.as_deref().is_none_or(|s| s.trim().is_empty());
        if blank(&server.command) && blank(&server.url) { return Err("A server runs a command or is at a URL".into()) }
        for value in server.env.iter_mut().chain(server.headers.iter_mut()) {
            if value.from != Source::File { value.value = None }
        }
        let mut list = self.list.lock().unwrap();
        if server.id.is_empty() {
            let base: String = server.name.to_lowercase().chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect::<String>()
                .split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
            let base = if base.is_empty() { "server".to_string() } else { base };
            let mut id = base.clone();
            let mut n = 2;
            while list.iter().any(|s| s.id == id) { id = format!("{base}-{n}"); n += 1 }
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
        if list.len() == before { return Err(format!("No server {id}")) }
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
