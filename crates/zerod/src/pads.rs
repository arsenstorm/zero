//! Scratchpads: plain Markdown files under one folder (~/.zero/scratchpads), in folders of the user's own, so any editor
//! or agent can read them and they outlive Zero. zerod gives each a short id, kept in the folder's .index.json, that a
//! link reaches it by: zero://pad/<id>, or zero://pad/<id>#<section> for one heading's part. A pad's revision is a hash
//! of its text, so a write made from an old read is refused, whoever changed it since (an agent, the app, another
//! editor).

use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::UNIX_EPOCH;

use serde::Serialize;

pub struct Pads {
    root: PathBuf,
    /// Each pad's id to its file, relative to the root.
    index: Mutex<BTreeMap<String, String>>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Pad {
    pub id: String,
    pub title: String,
    /// "Work/2026"; empty at the top.
    pub folder: String,
    /// The whole text, or the section asked for.
    pub content: String,
    pub revision: String,
    pub sections: Vec<Section>,
    pub link: String,
    /// When the file last changed, in seconds since 1970.
    pub updated: i64,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub id: String,
    pub title: String,
    pub folder: String,
    pub link: String,
    pub updated: i64,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Section {
    /// Its anchor, as GitHub makes them: "release-plan", a repeat "plan-1".
    pub slug: String,
    pub title: String,
    pub level: u8,
    /// Where its heading is, from 1.
    pub line: usize,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Match {
    pub id: String,
    pub title: String,
    /// The heading it's under.
    pub section: Option<String>,
    pub line: usize,
    pub text: String,
}

const TRASH: &str = ".trash";
/// Tasks' own pads (Tasks/ENG-9767/State): kept apart, so the scratchpads stay the user's own notes.
pub const TASKS: &str = "Tasks";

fn in_folder(folder: &str, root: &str) -> bool { folder == root || folder.starts_with(&format!("{root}/")) }

impl Pads {
    pub fn open(root: &Path) -> Pads {
        let _ = std::fs::create_dir_all(root);
        let index = std::fs::read(root.join(".index.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        let pads = Pads { root: root.into(), index: Mutex::new(index) };
        pads.sync();
        pads
    }

    pub fn root(&self) -> &Path { &self.root }

    /// Every pad but tasks', the latest changed first; with a query, those whose title or text has it.
    pub fn list(&self, query: Option<&str>) -> Vec<Summary> { self.list_in(query, None) }

    /// The pads in a folder and those inside it (a task's too, asked for by name); with none, all but tasks'.
    pub fn list_in(&self, query: Option<&str>, folder: Option<&str>) -> Vec<Summary> {
        self.sync();
        let query = query.map(str::to_lowercase).filter(|q| !q.is_empty());
        let folder = folder.map(|f| f.trim_matches('/')).filter(|f| !f.is_empty());
        let mut pads: Vec<Summary> = self.index.lock().unwrap().iter().filter_map(|(id, file)| {
            let within = folder_of(file);
            if !folder.map_or(!in_folder(&within, TASKS), |folder| in_folder(&within, folder)) { return None }
            let path = self.root.join(file);
            if let Some(query) = &query {
                let text = std::fs::read_to_string(&path).unwrap_or_default().to_lowercase();
                if !title_of(file).to_lowercase().contains(query) && !text.contains(query) { return None }
            }
            Some(Summary { id: id.clone(), title: title_of(file), folder: folder_of(file), link: link(id), updated: modified(&path) })
        }).collect();
        pads.sort_by(|a, b| b.updated.cmp(&a.updated).then(a.title.cmp(&b.title)));
        pads
    }

    /// Every folder, empty ones too, by path.
    pub fn folders(&self) -> Vec<String> {
        fn walk(dir: &Path, root: &Path, out: &mut Vec<String>) {
            for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.is_dir() && !hidden(&path) {
                    out.push(relative(&path, root));
                    walk(&path, root, out);
                }
            }
        }
        let mut folders = vec![];
        walk(&self.root, &self.root, &mut folders);
        folders.retain(|f| !in_folder(f, TASKS));
        folders.sort();
        folders
    }

    /// A pad by its id or link; with a section (or a link's #section), that part of it alone.
    pub fn read(&self, pad: &str, section: Option<&str>) -> Result<Pad, String> {
        let (id, anchor) = parse_link(pad);
        let (file, text) = self.load(&id)?;
        let mut read = self.pad(&id, &file, &text);
        if let Some(slug) = section.or(anchor.as_deref()) {
            let (start, end) = self.span(&read, slug)?;
            read.content = lines(&text)[start..end].join("\n").trim_end().to_string() + "\n";
        }
        Ok(read)
    }

    /// A new pad. With no title, its first heading's (or "Untitled"); a title already in the folder gets a number.
    pub fn create(&self, title: &str, folder: &str, content: &str) -> Result<Pad, String> {
        let folder = clean_folder(folder)?;
        let title = match title.trim() {
            "" => sections(content).first().filter(|s| s.level == 1).map(|s| s.title.clone()).unwrap_or_else(|| "Untitled".into()),
            title => title.to_string(),
        };
        let title = clean_title(&title)?;
        std::fs::create_dir_all(self.root.join(&folder)).map_err(|e| e.to_string())?;
        let file = (1..).map(|n| join(&folder, &if n == 1 { title.clone() } else { format!("{title} {n}") })).find(|file| !self.root.join(file).exists()).unwrap();
        std::fs::write(self.root.join(&file), content).map_err(|e| e.to_string())?;
        let id = self.new_id();
        self.index.lock().unwrap().insert(id.clone(), file.clone());
        self.save_index();
        Ok(self.pad(&id, &file, content))
    }

    /// The whole text replaced; with a revision, only if nobody has changed it since.
    pub fn write(&self, pad: &str, content: &str, revision: Option<&str>) -> Result<Pad, String> {
        let (id, _) = parse_link(pad);
        let (file, text) = self.load(&id)?;
        self.check(&file, &text, revision)?;
        self.store(&id, &file, content)
    }

    /// Text added at the end, or at the end of a section.
    pub fn append(&self, pad: &str, content: &str, section: Option<&str>) -> Result<Pad, String> {
        let (id, anchor) = parse_link(pad);
        let (file, text) = self.load(&id)?;
        let added = content.trim_end();
        let next = match section.or(anchor.as_deref()) {
            None if text.trim().is_empty() => format!("{added}\n"),
            None => format!("{}\n\n{added}\n", text.trim_end()),
            Some(slug) => {
                let read = self.pad(&id, &file, &text);
                let (start, end) = self.span(&read, slug)?;
                let all = lines(&text);
                splice(&all, start, end, &format!("{}\n\n{added}", all[start..end].join("\n").trim_end()))
            }
        };
        self.store(&id, &file, &next)
    }

    /// A section replaced. Text that doesn't start with a heading goes under the section's own.
    pub fn edit(&self, pad: &str, section: &str, content: &str, revision: Option<&str>) -> Result<Pad, String> {
        let (id, _) = parse_link(pad);
        let (file, text) = self.load(&id)?;
        self.check(&file, &text, revision)?;
        let read = self.pad(&id, &file, &text);
        let (start, end) = self.span(&read, section)?;
        let all = lines(&text);
        let body = content.trim_end();
        let replacement = if body.trim_start().starts_with('#') { body.to_string() } else { format!("{}\n\n{body}", all[start]) };
        self.store(&id, &file, &splice(&all, start, end, &replacement))
    }

    pub fn rename(&self, pad: &str, title: &str) -> Result<Pad, String> {
        let (id, _) = parse_link(pad);
        let (file, _) = self.load(&id)?;
        self.relocate(&id, &file, join(&folder_of(&file), &clean_title(title)?))
    }

    pub fn move_to(&self, pad: &str, folder: &str) -> Result<Pad, String> {
        let (id, _) = parse_link(pad);
        let (file, _) = self.load(&id)?;
        let folder = clean_folder(folder)?;
        std::fs::create_dir_all(self.root.join(&folder)).map_err(|e| e.to_string())?;
        self.relocate(&id, &file, join(&folder, &title_of(&file)))
    }

    /// Into the scratchpads' .trash folder, not away: a pad is the user's writing.
    pub fn delete(&self, pad: &str) -> Result<(), String> {
        let (id, _) = parse_link(pad);
        let (file, _) = self.load(&id)?;
        std::fs::create_dir_all(self.root.join(TRASH)).map_err(|e| e.to_string())?;
        let title = title_of(&file);
        let to = (1..).map(|n| self.root.join(TRASH).join(if n == 1 { format!("{title}.md") } else { format!("{title} {n}.md") })).find(|p| !p.exists()).unwrap();
        std::fs::rename(self.root.join(&file), to).map_err(|e| e.to_string())?;
        self.index.lock().unwrap().remove(&id);
        self.save_index();
        Ok(())
    }

    pub fn make_folder(&self, folder: &str) -> Result<(), String> {
        let folder = clean_folder(folder)?;
        if folder.is_empty() { return Err("Name the folder".into()) }
        std::fs::create_dir_all(self.root.join(folder)).map_err(|e| e.to_string())
    }

    /// Lines with the text in them, case aside, across every pad.
    pub fn find(&self, query: &str) -> Vec<Match> {
        let query = query.to_lowercase();
        if query.is_empty() { return vec![] }
        let mut found = vec![];
        for summary in self.list(None) {
            let Ok((file, text)) = self.load(&summary.id) else { continue };
            let outline = sections(&text);
            for (index, line) in text.lines().enumerate() {
                if !line.to_lowercase().contains(&query) { continue }
                let section = outline.iter().rev().find(|s| s.line <= index + 1).map(|s| s.slug.clone());
                found.push(Match { id: summary.id.clone(), title: title_of(&file), section, line: index + 1, text: line.to_string() });
            }
        }
        found
    }

    fn pad(&self, id: &str, file: &str, text: &str) -> Pad {
        Pad {
            id: id.into(), title: title_of(file), folder: folder_of(file), content: text.into(), revision: revision(text),
            sections: sections(text), link: link(id), updated: modified(&self.root.join(file)),
        }
    }

    /// Where a section's lines start and end (its heading to the next heading as high as it).
    fn span(&self, pad: &Pad, slug: &str) -> Result<(usize, usize), String> {
        let Some(at) = pad.sections.iter().position(|s| s.slug == slug) else {
            return Err(format!("No section {slug} in {}: {}", pad.title, pad.sections.iter().map(|s| s.slug.as_str()).collect::<Vec<_>>().join(", ")));
        };
        let section = &pad.sections[at];
        let end = pad.sections[at + 1..].iter().find(|s| s.level <= section.level).map(|s| s.line - 1).unwrap_or_else(|| lines(&pad.content).len());
        Ok((section.line - 1, end))
    }

    fn check(&self, file: &str, text: &str, revision: Option<&str>) -> Result<(), String> {
        match revision {
            Some(revision) if revision != self::revision(text) => {
                Err(format!("{} changed since revision {revision}; read it again (it's at {} now)", title_of(file), self::revision(text)))
            }
            _ => Ok(()),
        }
    }

    fn store(&self, id: &str, file: &str, content: &str) -> Result<Pad, String> {
        std::fs::write(self.root.join(file), content).map_err(|e| e.to_string())?;
        Ok(self.pad(id, file, content))
    }

    fn relocate(&self, id: &str, from: &str, to: String) -> Result<Pad, String> {
        if to != from {
            if self.root.join(&to).exists() { return Err(format!("There's already a {} in {}", title_of(&to), shown(&folder_of(&to)))) }
            std::fs::rename(self.root.join(from), self.root.join(&to)).map_err(|e| e.to_string())?;
            self.index.lock().unwrap().insert(id.into(), to.clone());
            self.save_index();
        }
        let (_, text) = self.load(id)?;
        Ok(self.pad(id, &to, &text))
    }

    /// The pad's file and text, looking again for files changed outside Zero when it isn't where it was.
    fn load(&self, id: &str) -> Result<(String, String), String> {
        let found = |pads: &Pads| {
            let file = pads.index.lock().unwrap().get(id).cloned()?;
            std::fs::read_to_string(pads.root.join(&file)).ok().map(|text| (file, text))
        };
        found(self).or_else(|| { self.sync(); found(self) }).ok_or_else(|| format!("No scratchpad {id}"))
    }

    /// The index matched to the files: one added outside Zero gets an id, one gone loses its.
    // ponytail: a file moved outside Zero gets a new id, so links to it break; an id kept in the file's xattrs if that matters.
    fn sync(&self) {
        fn walk(dir: &Path, root: &Path, out: &mut Vec<String>) {
            for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                let path = entry.path();
                if hidden(&path) { continue }
                if path.is_dir() { walk(&path, root, out) } else if path.extension().is_some_and(|e| e == "md") { out.push(relative(&path, root)) }
            }
        }
        let mut files = vec![];
        walk(&self.root, &self.root, &mut files);
        let changed = {
            let mut index = self.index.lock().unwrap();
            let before = index.len();
            index.retain(|_, file| files.contains(file));
            let known: Vec<String> = index.values().cloned().collect();
            let new: Vec<&String> = files.iter().filter(|f| !known.contains(f)).collect();
            for file in &new {
                let id = self.new_id_in(&index);
                index.insert(id, (*file).clone());
            }
            before != index.len() || !new.is_empty()
        };
        if changed { self.save_index() }
    }

    fn new_id(&self) -> String { self.new_id_in(&self.index.lock().unwrap()) }

    fn new_id_in(&self, index: &BTreeMap<String, String>) -> String {
        loop {
            let mut bytes = [0u8; 6];
            if let Ok(mut source) = std::fs::File::open("/dev/urandom") { let _ = std::io::Read::read_exact(&mut source, &mut bytes); }
            let id: String = bytes.iter().map(|b| b"abcdefghijkmnpqrstuvwxyz23456789"[(*b % 32) as usize] as char).collect();
            if !index.contains_key(&id) { return id }
        }
    }

    fn save_index(&self) {
        if let Ok(data) = serde_json::to_vec_pretty(&*self.index.lock().unwrap()) { let _ = std::fs::write(self.root.join(".index.json"), data); }
    }
}

/// A pad's headings, those in code blocks aside, with GitHub's anchors.
pub fn sections(text: &str) -> Vec<Section> {
    let mut found: Vec<Section> = vec![];
    let mut fenced = false;
    for (index, line) in text.lines().enumerate() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") { fenced = !fenced; continue }
        if fenced { continue }
        let level = line.bytes().take_while(|b| *b == b'#').count();
        if !(1..=6).contains(&level) || !line[level..].starts_with(' ') { continue }
        let title = line[level..].trim().trim_end_matches('#').trim().to_string();
        let base: String = title.to_lowercase().chars().filter_map(|c| match c {
            c if c.is_alphanumeric() || c == '_' || c == '-' => Some(c),
            ' ' => Some('-'),
            _ => None,
        }).collect();
        let repeats = found.iter().filter(|s| s.slug == base || s.slug.strip_prefix(&format!("{base}-")).is_some_and(|n| n.parse::<u32>().is_ok())).count();
        let slug = if repeats == 0 { base } else { format!("{base}-{repeats}") };
        found.push(Section { slug, title, level: level as u8, line: index + 1 });
    }
    found
}

/// An id or a link's id and section: "zero://pad/8f3k2a#plan" is ("8f3k2a", Some("plan")).
pub fn parse_link(pad: &str) -> (String, Option<String>) {
    let bare = pad.trim().strip_prefix("zero://pad/").unwrap_or(pad.trim());
    match bare.split_once('#') {
        Some((id, section)) if !section.is_empty() => (id.into(), Some(section.into())),
        Some((id, _)) => (id.into(), None),
        None => (bare.into(), None),
    }
}

pub fn link(id: &str) -> String { format!("zero://pad/{id}") }

fn revision(text: &str) -> String {
    crate::integrations::sha256(text.as_bytes())[..6].iter().map(|b| format!("{b:02x}")).collect()
}

fn lines(text: &str) -> Vec<&str> { text.lines().collect() }

/// The lines with [start, end) replaced, a blank line before what follows.
fn splice(all: &[&str], start: usize, end: usize, replacement: &str) -> String {
    let before = all[..start].join("\n");
    let after = all[end..].join("\n");
    let mut out = if start == 0 { String::new() } else { before + "\n" };
    out.push_str(replacement.trim_end());
    out.push('\n');
    if !after.trim().is_empty() { out.push('\n'); out.push_str(after.trim_start_matches('\n')); out.push('\n') }
    out
}

fn title_of(file: &str) -> String { Path::new(file).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default() }

fn folder_of(file: &str) -> String { Path::new(file).parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default() }

fn join(folder: &str, title: &str) -> String { if folder.is_empty() { format!("{title}.md") } else { format!("{folder}/{title}.md") } }

fn shown(folder: &str) -> &str { if folder.is_empty() { "Scratchpads" } else { folder } }

fn relative(path: &Path, root: &Path) -> String { path.strip_prefix(root).unwrap_or(path).to_string_lossy().to_string() }

fn hidden(path: &Path) -> bool { path.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')) }

fn modified(path: &Path) -> i64 {
    std::fs::metadata(path).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// A folder inside the root: plain names, no "..", no hidden ones.
fn clean_folder(folder: &str) -> Result<String, String> {
    let folder = folder.trim().trim_matches('/');
    let fine = Path::new(folder).components().all(|c| matches!(c, Component::Normal(name) if !name.to_string_lossy().starts_with('.')));
    if fine { Ok(folder.to_string()) } else { Err("A folder is a name inside Zero's scratchpads".into()) }
}

fn clean_title(title: &str) -> Result<String, String> {
    let title = title.trim();
    if title.is_empty() || title.starts_with('.') || title.contains('/') { return Err(format!("{title:?} can't be a scratchpad's name")) }
    Ok(title.to_string())
}

/// One scratchpad tool by its name, as the app's `pad` op and the MCP server both call them.
pub fn call(pads: &Pads, tool: &str, args: &serde_json::Value) -> Result<serde_json::Value, String> {
    use serde_json::json;
    let text = |key: &str| args[key].as_str();
    let need = |key: &str| text(key).ok_or_else(|| format!("{tool} needs {key}"));
    let pad = |result: Result<Pad, String>| result.map(|pad| json!(pad));
    match tool {
        "list" => Ok(json!({"pads": pads.list_in(text("query"), text("folder")), "folders": pads.folders()})),
        "read" => pad(pads.read(need("pad")?, text("section"))),
        "create" => pad(pads.create(text("title").unwrap_or(""), text("folder").unwrap_or(""), text("content").unwrap_or(""))),
        "write" => pad(pads.write(need("pad")?, need("content")?, text("revision"))),
        "append" => pad(pads.append(need("pad")?, need("content")?, text("section"))),
        "edit" => pad(pads.edit(need("pad")?, need("section")?, need("content")?, text("revision"))),
        "find" => Ok(json!(pads.find(need("query")?))),
        "rename" => pad(pads.rename(need("pad")?, need("title")?)),
        "move" => pad(pads.move_to(need("pad")?, text("folder").unwrap_or(""))),
        "delete" => pads.delete(need("pad")?).map(|_| json!({"deleted": true})),
        "folder" => pads.make_folder(need("folder")?).map(|_| json!({"folders": pads.folders()})),
        other => Err(format!("No scratchpad tool {other}")),
    }
}
