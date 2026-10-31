//! Loops: named instructions an agent follows, kept as Markdown files under one folder (`<name>.md`, a `description:`
//! header above the body). A message or a brief names one as `@name`; zerod expands that into the loop's text under
//! a heading, between markers, so every provider gets plain words, and the record shows `@name` again (core.rs
//! collapses it). Inside a loop, `@child` is a reference, not an inclusion: the lead starts workers on it. Each
//! expansion is recorded: which session, as lead or worker, when.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub struct Loops {
    root: PathBuf,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Loop {
    pub name: String,
    pub description: String,
    pub body: String,
    /// The loops it names (`@child`), that exist.
    pub children: Vec<String>,
    pub uses: Vec<Use>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Use {
    pub session: String,
    /// "lead" or "worker".
    pub role: String,
    /// Milliseconds since 1970.
    pub at: i64,
}

impl Loops {
    pub fn open(root: &Path) -> Loops {
        let _ = std::fs::create_dir_all(root);
        Loops { root: root.into() }
    }

    /// Every loop, by name, without its uses' detail.
    pub fn list(&self) -> Vec<Loop> {
        let mut names: Vec<String> = std::fs::read_dir(&self.root).into_iter().flatten().flatten()
            .filter_map(|e| e.path().file_name()?.to_str()?.strip_suffix(".md").map(String::from)).collect();
        names.sort();
        names.iter().filter_map(|name| self.read(name).ok()).collect()
    }

    pub fn read(&self, name: &str) -> Result<Loop, String> {
        let file = self.file(name)?;
        let text = std::fs::read_to_string(&file).map_err(|_| format!("No loop named {name}"))?;
        let (description, body) = split(&text);
        let children = self.children_of(&body);
        Ok(Loop { name: name.into(), description, body, children, uses: self.uses(name) })
    }

    /// Saves it, refusing a name that isn't one and a body that leads back to itself through its children.
    pub fn save(&self, name: &str, description: &str, body: &str) -> Result<Loop, String> {
        let file = self.file(name)?;
        for child in self.children_of(body) {
            if child == name || self.reaches(&child, name, 0) { return Err(format!("@{child} leads back to {name}: a loop names its children, never a parent")) }
        }
        let text = if description.trim().is_empty() { body.to_string() } else { format!("---\ndescription: {}\n---\n{}", description.trim(), body) };
        std::fs::write(&file, text).map_err(|e| e.to_string())?;
        self.read(name)
    }

    pub fn delete(&self, name: &str) -> Result<(), String> {
        let file = self.file(name)?;
        std::fs::remove_file(&file).map_err(|_| format!("No loop named {name}"))
    }

    /// The text with each `@name` that is a loop expanded into that loop's words, and the names expanded.
    pub fn expand(&self, text: &str) -> (String, Vec<String>) {
        let mut out = String::new();
        let mut used = vec![];
        let mut rest = text;
        while let Some(at) = rest.find('@') {
            let (before, from) = rest.split_at(at);
            out.push_str(before);
            let starts_word = before.chars().last().is_none_or(|c| !c.is_alphanumeric());
            let name: String = from[1..].chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
            let ends_word = from[1 + name.len()..].chars().next().is_none_or(|c| !c.is_alphanumeric());
            match (starts_word && !name.is_empty() && ends_word).then(|| self.read(&name).ok()).flatten() {
                Some(found) => {
                    out.push_str(&expanded(&found));
                    used.push(name.clone());
                    rest = &from[1 + name.len()..];
                }
                None => {
                    out.push('@');
                    rest = &from[1..];
                }
            }
        }
        out.push_str(rest);
        (out, used)
    }

    /// A session ran the loop, as its lead or as a worker.
    pub fn record(&self, name: &str, session: &str, role: &str) {
        let line = serde_json::json!({"loop": name, "session": session, "role": role, "at": now()});
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(self.root.join("uses.jsonl")) {
            use std::io::Write;
            let _ = writeln!(file, "{line}");
        }
    }

    pub fn uses(&self, name: &str) -> Vec<Use> {
        std::fs::read_to_string(self.root.join("uses.jsonl")).unwrap_or_default().lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(|v| v["loop"] == name)
            .filter_map(|v| Some(Use { session: v["session"].as_str()?.into(), role: v["role"].as_str()?.into(), at: v["at"].as_i64()? }))
            .collect()
    }

    fn file(&self, name: &str) -> Result<PathBuf, String> {
        let ok = !name.is_empty() && name.len() <= 60 && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            && !name.starts_with('-') && !name.ends_with('-');
        if !ok { return Err(format!("A loop's name is lowercase words joined by hyphens (ticket-worker), not {name:?}")) }
        Ok(self.root.join(format!("{name}.md")))
    }

    fn children_of(&self, body: &str) -> Vec<String> {
        let mut children: Vec<String> = references(body).into_iter().filter(|name| self.file(name).map(|f| f.exists()).unwrap_or(false)).collect();
        children.dedup();
        children
    }

    fn reaches(&self, from: &str, target: &str, depth: usize) -> bool {
        if depth > 20 { return true }
        self.read(from).map(|l| l.children).unwrap_or_default().iter().any(|child| child == target || self.reaches(child, target, depth + 1))
    }
}

/// The `@names` in a text, in order, each once.
pub fn references(text: &str) -> Vec<String> {
    let mut names: Vec<String> = vec![];
    let mut rest = text;
    while let Some(at) = rest.find('@') {
        let (before, from) = rest.split_at(at);
        let starts_word = before.chars().last().is_none_or(|c| !c.is_alphanumeric());
        let name: String = from[1..].chars().take_while(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '-').collect();
        if starts_word && !name.is_empty() && !names.contains(&name) { names.push(name.clone()) }
        rest = &from[1..];
    }
    names
}

/// The description above the body, when the file has a header.
fn split(text: &str) -> (String, String) {
    if let Some(rest) = text.strip_prefix("---\n") && let Some((header, body)) = rest.split_once("\n---\n") {
        let description = header.lines().find_map(|l| l.strip_prefix("description:")).unwrap_or("").trim().to_string();
        return (description, body.to_string());
    }
    (String::new(), text.to_string())
}

fn expanded(found: &Loop) -> String {
    let description = if found.description.is_empty() { String::new() } else { format!("{}\n\n", found.description) };
    format!("<!-- loop: {name} -->\n## Loop: {name}\n\n{description}{}\n<!-- /loop: {name} -->", found.body.trim_end(), name = found.name)
}

/// The text with each expanded loop back as `@name`: what the record keeps, and what the user reads.
pub fn collapse(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find("<!-- loop: ") {
        let (before, from) = rest.split_at(start);
        let Some(name_end) = from.find(" -->") else { break };
        let name = &from["<!-- loop: ".len()..name_end];
        let close = format!("<!-- /loop: {name} -->");
        let Some(end) = from.find(&close) else { break };
        out.push_str(before);
        out.push('@');
        out.push_str(name);
        rest = &from[end + close.len()..];
    }
    out.push_str(rest);
    out
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}
