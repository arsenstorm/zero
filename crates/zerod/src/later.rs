//! Later: things to come back to (~/.zero/later). Each is a folder of its own: item.json (its note in plain words, the
//! task it came from, its links, its versions), artifact.md (everything behind it, in full), files/ (what was attached)
//! and versions/<n>.md (each earlier artifact). A link reaches it: zero://later/<id>.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub struct Later {
    root: PathBuf,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Item {
    pub id: String,
    /// What needs doing later, in a sentence or two of plain words.
    pub note: String,
    /// Everything behind it; left out of lists.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artifact: Option<String>,
    /// The session it came from, its task's name then, and its workspace.
    pub from: Option<String>,
    pub task: Option<String>,
    pub workspace: Option<String>,
    pub links: Vec<String>,
    /// Each attached file's path.
    pub files: Vec<String>,
    pub created: i64,
    pub updated: i64,
    pub done: bool,
    /// Saved by an agent without the user asking: shown apart until the user keeps it, and gone after a week if they
    /// don't.
    pub suggested: bool,
    pub version: u32,
    pub versions: Vec<Version>,
    pub link: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Version {
    pub version: u32,
    pub note: String,
    pub at: i64,
    /// The session that wrote it; none, the user.
    pub by: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct New {
    pub note: String,
    pub artifact: String,
    pub links: Vec<String>,
    /// Paths of files to copy in.
    pub files: Vec<String>,
    pub from: Option<String>,
    pub task: Option<String>,
    pub workspace: Option<String>,
    /// The user asked for it to be saved; otherwise, from a task, it's a suggestion.
    pub asked: bool,
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Edit {
    pub note: Option<String>,
    pub artifact: Option<String>,
    /// Added to those it has.
    pub links: Vec<String>,
    pub files: Vec<String>,
    pub done: Option<bool>,
    /// The user keeps a suggestion.
    pub keep: Option<bool>,
    pub by: Option<String>,
}

const TRASH: &str = ".trash";
/// The longest note: a headline read at a glance.
pub const NOTE: usize = 100;
/// The most suggestions one task has open: past that it adds to one it has.
pub const SUGGESTIONS: usize = 3;
/// How long a suggestion waits to be kept.
const SUGGESTED_FOR: i64 = 7 * 86400;

impl Later {
    pub fn open(root: &Path) -> Later {
        let _ = std::fs::create_dir_all(root);
        Later { root: root.into() }
    }

    pub fn save(&self, new: New) -> Result<Item, String> {
        let note = clean_note(&new.note)?;
        if new.from.is_some() { headline(&note)? }
        let suggested = !new.asked && new.from.is_some();
        if suggested {
            let open: Vec<String> = self.list(None).into_iter().filter(|i| i.suggested && !i.done && i.from == new.from).map(|i| i.id).collect();
            if open.len() >= SUGGESTIONS {
                return Err(format!("This task already has {} suggestions open in Later ({}), the most it may have. Add this to the one it belongs with \
                                    (`zero later edit <id> --file -`), or leave it out: Later is for what the user will come back to, not every \
                                    idea along the way.", open.len(), open.join(", ")));
            }
        }
        let id = self.new_id();
        let dir = self.root.join(&id);
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let files = match self.attach(&dir, &new.files) {
            Ok(files) => files,
            Err(error) => { let _ = std::fs::remove_dir_all(&dir); return Err(error) }
        };
        let now = now();
        let item = Item { id: id.clone(), note: note.clone(), artifact: None, from: new.from.clone(), task: new.task, workspace: new.workspace,
            links: new.links, files, created: now, updated: now, done: false, suggested, version: 1,
            versions: vec![Version { version: 1, note, at: now, by: new.from }], link: link(&id) };
        std::fs::write(dir.join("artifact.md"), &new.artifact).map_err(|e| e.to_string())?;
        self.store(&item)?;
        self.view(&id, None)
    }

    /// Every item, without its artifact: what's open first, then the newest; with a query, those whose note, task or
    /// artifact has it.
    pub fn list(&self, query: Option<&str>) -> Vec<Item> {
        let query = query.map(str::to_lowercase).filter(|q| !q.is_empty());
        let mut items: Vec<Item> = std::fs::read_dir(&self.root).into_iter().flatten().flatten().filter_map(|entry| {
            let id = entry.file_name().to_string_lossy().to_string();
            if id.starts_with('.') { return None }
            let item = self.load(&id).ok()?;
            if item.suggested && !item.done && now() - item.created > SUGGESTED_FOR {
                let _ = self.delete(&id);
                return None
            }
            if let Some(query) = &query {
                let artifact = std::fs::read_to_string(self.root.join(&id).join("artifact.md")).unwrap_or_default();
                let words = format!("{}\n{}\n{}", item.note, item.task.as_deref().unwrap_or(""), artifact).to_lowercase();
                if !words.contains(query) { return None }
            }
            Some(item)
        }).collect();
        items.sort_by(|a, b| a.done.cmp(&b.done).then(b.created.cmp(&a.created)).then(a.id.cmp(&b.id)));
        items
    }

    /// An item by its id or link, with its artifact; with a version, that version's.
    pub fn view(&self, item: &str, version: Option<u32>) -> Result<Item, String> {
        let id = parse(item);
        let mut read = self.load(&id)?;
        let dir = self.root.join(&id);
        let file = match version {
            Some(v) if v == read.version => dir.join("artifact.md"),
            Some(v) if read.versions.iter().any(|x| x.version == v) => dir.join("versions").join(format!("{v}.md")),
            Some(v) => return Err(format!("{id} has no version {v}")),
            None => dir.join("artifact.md"),
        };
        read.artifact = Some(std::fs::read_to_string(file).unwrap_or_default());
        Ok(read)
    }

    /// A new version when its note or artifact changes (the old artifact kept); links and files added; done or not.
    pub fn edit(&self, item: &str, edit: Edit) -> Result<Item, String> {
        let id = parse(item);
        let mut kept = self.load(&id)?;
        let dir = self.root.join(&id);
        let artifact = std::fs::read_to_string(dir.join("artifact.md")).unwrap_or_default();
        let note = edit.note.as_deref().map(clean_note).transpose()?;
        if let Some(note) = &note && edit.by.is_some() { headline(note)? }
        let changed = note.as_ref().is_some_and(|n| *n != kept.note) || edit.artifact.as_ref().is_some_and(|a| *a != artifact);
        let now = now();
        if changed {
            std::fs::create_dir_all(dir.join("versions")).map_err(|e| e.to_string())?;
            std::fs::write(dir.join("versions").join(format!("{}.md", kept.version)), &artifact).map_err(|e| e.to_string())?;
            if let Some(new) = &edit.artifact { std::fs::write(dir.join("artifact.md"), new).map_err(|e| e.to_string())? }
            if let Some(note) = note { kept.note = note }
            kept.version += 1;
            kept.versions.push(Version { version: kept.version, note: kept.note.clone(), at: now, by: edit.by });
        }
        kept.files.extend(self.attach(&dir, &edit.files)?.into_iter().map(|path| name_of(&path)));
        kept.files.dedup();
        for link in edit.links { if !kept.links.contains(&link) { kept.links.push(link) } }
        if let Some(done) = edit.done { kept.done = done }
        if edit.keep == Some(true) { kept.suggested = false }
        kept.updated = now;
        self.store(&kept)?;
        self.view(&id, None)
    }

    /// Into the trash, where it can be got back from by hand.
    pub fn delete(&self, item: &str) -> Result<(), String> {
        let id = parse(item);
        self.load(&id)?;
        let trash = self.root.join(TRASH);
        std::fs::create_dir_all(&trash).map_err(|e| e.to_string())?;
        std::fs::rename(self.root.join(&id), trash.join(format!("{id}-{}", now()))).map_err(|e| e.to_string())
    }

    fn load(&self, id: &str) -> Result<Item, String> {
        let data = std::fs::read(self.root.join(id).join("item.json")).map_err(|_| format!("Nothing saved for later as {id}"))?;
        let mut item: Item = serde_json::from_slice(&data).map_err(|e| e.to_string())?;
        let files = self.root.join(id).join("files");
        item.files = item.files.iter().map(|name| files.join(name).to_string_lossy().to_string()).collect();
        item.link = link(id);
        item.artifact = None;
        Ok(item)
    }

    /// Kept with names for its files, so the folder can move.
    fn store(&self, item: &Item) -> Result<(), String> {
        let mut kept = item.clone();
        kept.artifact = None;
        kept.files = kept.files.iter().map(|path| name_of(path)).collect();
        let data = serde_json::to_vec_pretty(&kept).map_err(|e| e.to_string())?;
        std::fs::write(self.root.join(&item.id).join("item.json"), data).map_err(|e| e.to_string())
    }

    /// Copies each file into the item's files/, a name already there getting a number; their new paths.
    fn attach(&self, dir: &Path, paths: &[String]) -> Result<Vec<String>, String> {
        if paths.is_empty() { return Ok(vec![]) }
        let files = dir.join("files");
        std::fs::create_dir_all(&files).map_err(|e| e.to_string())?;
        paths.iter().map(|path| {
            let source = Path::new(path);
            let name = source.file_name().map(|n| n.to_string_lossy().to_string()).ok_or_else(|| format!("{path} isn't a file"))?;
            let mut target = files.join(&name);
            let mut n = 2;
            while target.exists() {
                let stem = source.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                let ext = source.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
                target = files.join(format!("{stem}-{n}{ext}"));
                n += 1;
            }
            std::fs::copy(source, &target).map_err(|e| format!("Couldn't attach {name}: {e}"))?;
            Ok(target.to_string_lossy().to_string())
        }).collect()
    }

    fn new_id(&self) -> String {
        loop {
            let mut bytes = [0u8; 6];
            if let Ok(mut source) = std::fs::File::open("/dev/urandom") { let _ = std::io::Read::read_exact(&mut source, &mut bytes); }
            let id: String = bytes.iter().map(|b| b"abcdefghijkmnpqrstuvwxyz23456789"[(*b % 32) as usize] as char).collect();
            if !self.root.join(&id).exists() { return id }
        }
    }
}

fn clean_note(note: &str) -> Result<String, String> {
    let note = note.trim();
    if note.is_empty() { Err("Something saved for later needs a note: what's to be done, in plain words".into()) } else { Ok(note.to_string()) }
}

/// A note short enough to read at a glance; what's behind it goes in the artifact.
fn headline(note: &str) -> Result<(), String> {
    let length = note.chars().count();
    if length <= NOTE { return Ok(()) }
    Err(format!("The note is {length} characters; keep it under {NOTE}: a headline the user reads at a glance, in plain words, \
                 saying what's to be done (no ids, paths or lists). Everything else goes in the artifact (--file)."))
}

fn link(id: &str) -> String { format!("zero://later/{id}") }

/// An id from itself or its link; no slashes or dots, so it stays a folder in the root.
fn parse(item: &str) -> String {
    item.trim().trim_start_matches("zero://later/").chars().filter(|c| c.is_ascii_alphanumeric()).collect()
}

fn name_of(path: &str) -> String { Path::new(path).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default() }

fn now() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0) }

/// One tool by its name, as the `later` op calls them.
pub fn call(later: &Later, tool: &str, args: &serde_json::Value) -> Result<serde_json::Value, String> {
    use serde_json::json;
    let item = || args["item"].as_str().ok_or_else(|| format!("{tool} needs item"));
    let parse_as = |what: &str| format!("{tool}: {what}");
    match tool {
        "list" => Ok(json!(later.list(args["query"].as_str()))),
        "view" => later.view(item()?, args["version"].as_u64().map(|v| v as u32)).map(|i| json!(i)),
        "save" => later.save(serde_json::from_value(args.clone()).map_err(|e| parse_as(&e.to_string()))?).map(|i| json!(i)),
        "edit" => later.edit(item()?, serde_json::from_value(args.clone()).map_err(|e| parse_as(&e.to_string()))?).map(|i| json!(i)),
        "delete" => later.delete(item()?).map(|_| json!({"deleted": true})),
        other => Err(format!("No later tool {other}")),
    }
}
