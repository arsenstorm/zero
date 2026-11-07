//! Workspaces: the user's work split by who it's for (personal projects, a company). Each is a name and a glyph for the
//! sidebar; a task belongs to the workspace it was started in (or moved to), else to Zero, the workspace that is always
//! there. A worker is its lead's. Switching workspaces
//! in the app changes what is shown, nothing about what runs: zerod runs every workspace's sessions alike.
//! Kept in workspaces.json in zerod's home.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

/// The workspace that is always there, and the one a task is in when nothing says otherwise.
pub const DEFAULT: &str = "zero";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub id: String,
    pub name: String,
    /// A Nucleo icon's name, or an emoji.
    #[serde(default)]
    pub glyph: String,
}

impl Workspace {
    fn zero() -> Workspace { Workspace { id: DEFAULT.into(), name: "Zero".into(), glyph: String::new() } }
}

pub struct Workspaces { file: PathBuf, list: Mutex<Vec<Workspace>> }

impl Workspaces {
    pub fn open(home: &Path) -> Workspaces {
        let file = home.join("workspaces.json");
        let mut list: Vec<Workspace> = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        if !list.iter().any(|w| w.id == DEFAULT) { list.insert(0, Workspace::zero()) }
        Workspaces { file, list: Mutex::new(list) }
    }

    /// Zero first, then the others as made.
    pub fn list(&self) -> Vec<Workspace> { self.list.lock().unwrap().clone() }

    /// Adds a workspace (no id: one from its name), or changes the one with its id. Zero keeps its name.
    pub fn save(&self, mut workspace: Workspace) -> Result<Workspace, String> {
        workspace.name = workspace.name.trim().to_string();
        if workspace.name.is_empty() { return Err("A workspace needs a name".into()) }
        let mut list = self.list.lock().unwrap();
        if workspace.id.is_empty() {
            let base: String = workspace.name.to_lowercase().chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect::<String>().trim_matches('-').to_string();
            let base = if base.is_empty() { "workspace".to_string() } else { base };
            let mut id = base.clone();
            let mut n = 2;
            while list.iter().any(|w| w.id == id) { id = format!("{base}-{n}"); n += 1; }
            workspace.id = id;
        }
        if workspace.id == DEFAULT { workspace.name = "Zero".into() }
        match list.iter_mut().position(|w| w.id == workspace.id) { Some(i) => list[i] = workspace.clone(), None => list.push(workspace.clone()) }
        self.keep(&list)?;
        Ok(workspace)
    }

    /// Removes a workspace; its tasks are Zero's again (they keep no record of it). Zero stays.
    pub fn delete(&self, id: &str) -> Result<(), String> {
        if id == DEFAULT { return Err("Zero is always there".into()) }
        let mut list = self.list.lock().unwrap();
        let before = list.len();
        list.retain(|w| w.id != id);
        if list.len() == before { return Err(format!("No workspace {id}")) }
        self.keep(&list)
    }

    pub fn exists(&self, id: &str) -> bool { self.list.lock().unwrap().iter().any(|w| w.id == id) }

    /// Which workspace a task is in: the one it was put in, if that still exists; else Zero.
    pub fn of(&self, placed: Option<&str>) -> String {
        match placed {
            Some(id) if self.list.lock().unwrap().iter().any(|w| w.id == id) => id.to_string(),
            _ => DEFAULT.into(),
        }
    }

    fn keep(&self, list: &[Workspace]) -> Result<(), String> {
        std::fs::write(&self.file, serde_json::to_vec(list).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
    }
}
