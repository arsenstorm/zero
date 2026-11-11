//! Asks over files. Every folder matching one of the user's patterns is a drop: zerod keeps the client in it, reads
//! `asks/<id>.json` as they appear and writes `answers/<id>.json` when the ask is final. Anything that can write to a
//! folder this machine sees reaches the user this way, with nothing installed and no credential shared.

use std::collections::{HashMap, HashSet};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, SystemTime};

use crate::ask::{Ask, AskKind};
use crate::inbox::{Inbox, InboxEvent};

/// The `zero` placed in every drop: runs the static client built for the machine it runs on (crates/zero-drop).
pub const SHIM: &str = "#!/bin/sh\n# zero — placed here by Zero. Runs the static client for this machine; see crates/zero-drop/ in the Zero repo.\n\
exec \"$(dirname \"$0\")/zero-drop-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)\" \"$@\"\n";

pub struct Drops {
    inbox: Arc<Inbox>,
    /// Where the client binaries are (Zero.app's Resources), named zero-drop-<os>-<arch>.
    resources: PathBuf,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    patterns: Vec<String>,
    /// "<drop>/<file>" already read.
    ingested: HashSet<String>,
    /// Each drop's asks folder as last read, by when it last changed: one that hasn't isn't listed again (hundreds
    /// of drops, each listed every second, kept zerod at a few percent of a core).
    read: HashMap<PathBuf, std::time::SystemTime>,
    /// Ask id → the drop it came from, until its answer is written there.
    origin: HashMap<String, PathBuf>,
    /// The drops last found, and when: patterns over a thousand folders aren't walked every second.
    found: Option<(std::time::Instant, Vec<PathBuf>)>,
    /// When an ask last came from each drop: one in use is looked at every second, the rest (most, quiet) less.
    asked: HashMap<PathBuf, std::time::Instant>,
}

/// How often the patterns are walked again (thousands of folders), and each drop's folders, client and old answers
/// seen to: a new drop is a new bench, rare.
const LOOK_AGAIN: Duration = Duration::from_secs(120);
/// A drop asked from this lately is looked at every second; the others every `QUIET_EVERY` seconds.
const LIVELY: Duration = Duration::from_secs(600);
const QUIET_EVERY: u64 = 5;

impl Drops {
    pub fn new(inbox: Arc<Inbox>, resources: PathBuf) -> Arc<Drops> {
        let drops = Arc::new(Drops { inbox: inbox.clone(), resources, state: Mutex::new(State::default()) });
        let weak: Weak<Drops> = Arc::downgrade(&drops);
        let mut events = inbox.subscribe();
        tokio::spawn(async move {
            while let Ok(event) = events.recv().await {
                let InboxEvent::Ask(ask) = event else { continue };
                let Some(drops) = weak.upgrade() else { return };
                if ask.state.is_final() {
                    drops.answer(&ask)
                }
            }
        });
        drops
    }

    /// Looks every second at the drops asked from lately, every few at the rest.
    pub fn start(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            for round in 1u64.. {
                tokio::time::sleep(Duration::from_secs(1)).await;
                match weak.upgrade() {
                    Some(drops) => drops.look(round % QUIET_EVERY == 0),
                    None => return,
                }
            }
        });
    }

    pub fn set_patterns(&self, patterns: Vec<String>) {
        let mut state = self.state.lock().unwrap();
        state.patterns = patterns;
        state.found = None;
    }

    /// The drops the patterns find now; a plain last name under matching folders is made there.
    pub fn folders(&self) -> Vec<PathBuf> {
        let patterns = self.state.lock().unwrap().patterns.clone();
        patterns.iter().flat_map(|p| expand(p)).collect()
    }

    /// Every drop, quiet or not.
    pub fn scan(&self) {
        self.look(true)
    }

    fn look(&self, quiet_too: bool) {
        let found = self.state.lock().unwrap().found.clone().filter(|(at, _)| at.elapsed() < LOOK_AGAIN);
        let (drops, fresh) = match found {
            Some((_, drops)) => (drops, false),
            None => (self.folders(), true),
        };
        if fresh {
            self.state.lock().unwrap().found = Some((std::time::Instant::now(), drops.clone()))
        }
        for drop in drops {
            if fresh {
                self.prepare(&drop);
                sweep(&drop.join("answers"));
            }
            let lively = || self.state.lock().unwrap().asked.get(&drop).is_some_and(|at| at.elapsed() < LIVELY);
            if !fresh && !quiet_too && !lively() {
                continue;
            }
            let asks = drop.join("asks");
            // Unchanged since it was read (a file added, removed or renamed in it changes it): nothing new.
            let changed = std::fs::metadata(&asks).and_then(|m| m.modified()).ok();
            if changed.is_some() && self.state.lock().unwrap().read.get(&asks) == changed.as_ref() {
                continue;
            }
            let Ok(entries) = std::fs::read_dir(&asks) else { continue };
            let files: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
            let mut unfinished = false;
            // `zero withdraw` from a drop: "<id>.withdraw", holding the reason.
            for file in files.iter().filter(|f| f.extension().is_some_and(|e| e == "withdraw")) {
                let reason = std::fs::read_to_string(file).map(|r| r.trim().to_string()).unwrap_or_default();
                let id = file.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                self.inbox.withdraw(&id, if reason.is_empty() { None } else { Some(&reason) });
                let _ = std::fs::remove_file(file);
            }
            for file in files.iter().filter(|f| f.extension().is_some_and(|e| e == "json")) {
                let key = file.display().to_string();
                if self.state.lock().unwrap().ingested.contains(&key) {
                    continue;
                }
                let Ok(incoming) = std::fs::read(file).map(|data| serde_json::from_slice::<Ask>(&data)) else { continue };
                // Half-written by the sync: read it on a later look (the folder isn't marked read, so there is one).
                let Ok(incoming) = incoming else {
                    unfinished = true;
                    continue;
                };
                {
                    let mut state = self.state.lock().unwrap();
                    state.ingested.insert(key);
                    state.asked.insert(drop.clone(), std::time::Instant::now());
                }
                let ask = self.inbox.create(incoming, true);
                if ask.kind == AskKind::Note {
                    let _ = std::fs::remove_file(file);
                } else {
                    self.state.lock().unwrap().origin.insert(ask.id, drop.clone());
                }
            }
            // Marked as it was before it was listed: a file that came while it was read changes it again, and is read
            // next time (what this look removed changes it too: one more listing, no more).
            if !unfinished && let Some(changed) = changed {
                self.state.lock().unwrap().read.insert(asks, changed);
            }
        }
    }

    /// A final ask that came from a drop goes back there as its answer.
    fn answer(&self, ask: &Ask) {
        let Some(drop) = self.state.lock().unwrap().origin.remove(&ask.id) else { return };
        let Ok(data) = serde_json::to_vec(ask) else { return };
        let (answer, partial) = (drop.join(format!("answers/{}.json", ask.id)), drop.join(format!("answers/{}.json.tmp", ask.id)));
        if std::fs::write(&partial, data).is_ok() {
            let _ = std::fs::rename(&partial, &answer);
        }
        let _ = std::fs::remove_file(drop.join(format!("asks/{}.json", ask.id)));
    }

    /// The two folders, the client binaries (copied only when their size differs, so a sync isn't asked to move them
    /// every second) and the shim.
    fn prepare(&self, drop: &Path) {
        for name in ["asks", "answers"] {
            let _ = std::fs::create_dir_all(drop.join(name));
        }
        if let Ok(entries) = std::fs::read_dir(&self.resources) {
            for source in entries.filter_map(|e| e.ok().map(|e| e.path())) {
                let Some(name) = source.file_name().map(|n| n.to_string_lossy().to_string()).filter(|n| n.starts_with("zero-drop-")) else {
                    continue;
                };
                let target = drop.join(&name);
                let size = |p: &Path| std::fs::metadata(p).map(|m| m.len()).ok();
                if size(&source) == size(&target) {
                    continue;
                }
                let _ = std::fs::remove_file(&target);
                if std::fs::copy(&source, &target).is_ok() {
                    let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755));
                }
            }
        }
        let shim = drop.join("zero");
        if std::fs::read_to_string(&shim).ok().as_deref() != Some(SHIM) && std::fs::write(&shim, SHIM).is_ok() {
            let _ = std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755));
        }
    }
}

/// Answers nobody collected within a day (an --async ask whose agent never came back) are removed.
fn sweep(answers: &Path) {
    let Ok(entries) = std::fs::read_dir(answers) else { return };
    for file in entries.filter_map(|e| e.ok().map(|e| e.path())) {
        let old = std::fs::metadata(&file)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|at| SystemTime::now().duration_since(at).ok())
            .is_some_and(|age| age > Duration::from_secs(86400));
        if old {
            let _ = std::fs::remove_file(file);
        }
    }
}

/// A pattern's folders. A plain last name (no glob characters) is made under the folders its parent matches:
/// "~/worktrees/*/*/.zero" makes a `.zero` drop in every folder two levels down, so the other side finds the client.
fn expand(pattern: &str) -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let path = if let Some(rest) = pattern.strip_prefix("~/") { format!("{home}/{rest}") } else { pattern.to_string() };
    braces(&path)
        .into_iter()
        .flat_map(|path| {
            let (parent, leaf) = path.rsplit_once('/').unwrap_or(("", path.as_str()));
            if !leaf.chars().any(|c| "*?[".contains(c)) {
                for folder in glob(parent) {
                    let _ = std::fs::create_dir(folder.join(leaf));
                }
            }
            glob(&path)
        })
        .collect()
}

/// "{a,b}" alternatives spelled out, every brace in turn.
fn braces(pattern: &str) -> Vec<String> {
    let Some(open) = pattern.find('{') else { return vec![pattern.into()] };
    let Some(close) = pattern[open..].find('}').map(|i| open + i) else { return vec![pattern.into()] };
    pattern[open + 1..close]
        .split(',')
        .flat_map(|choice| braces(&format!("{}{choice}{}", &pattern[..open], &pattern[close + 1..])))
        .collect()
}

/// The folders matching an absolute pattern of `*`, `?` and `[...]` in its parts.
fn glob(pattern: &str) -> Vec<PathBuf> {
    let mut found = vec![PathBuf::from("/")];
    for part in pattern.split('/').filter(|p| !p.is_empty()) {
        let glob = part.chars().any(|c| "*?[".contains(c));
        found = found
            .into_iter()
            .flat_map(|dir| {
                if !glob {
                    return vec![dir.join(part)];
                }
                std::fs::read_dir(&dir)
                    .map(|entries| {
                        entries
                            .filter_map(|e| e.ok())
                            .filter_map(|e| {
                                let name = e.file_name().to_string_lossy().to_string();
                                // A leading dot is matched only by a pattern that says so, as the shell does.
                                (matches(part, &name) && (!name.starts_with('.') || part.starts_with('.'))).then(|| e.path())
                            })
                            .collect()
                    })
                    .unwrap_or_default()
            })
            .collect();
    }
    found.into_iter().filter(|p| p.is_dir()).collect()
}

/// fnmatch for one path part.
fn matches(pattern: &str, name: &str) -> bool {
    let (p, n): (Vec<char>, Vec<char>) = (pattern.chars().collect(), name.chars().collect());
    fn go(p: &[char], n: &[char]) -> bool {
        match p.first() {
            None => n.is_empty(),
            Some('*') => (0..=n.len()).any(|i| go(&p[1..], &n[i..])),
            Some('?') => !n.is_empty() && go(&p[1..], &n[1..]),
            Some('[') => {
                let Some(end) = p.iter().position(|c| *c == ']') else { return !n.is_empty() && n[0] == '[' && go(&p[1..], &n[1..]) };
                let Some(&c) = n.first() else { return false };
                let set = &p[1..end];
                let (negate, set) = if set.first() == Some(&'!') { (true, &set[1..]) } else { (false, set) };
                let mut hit = false;
                let mut i = 0;
                while i < set.len() {
                    if i + 2 < set.len() && set[i + 1] == '-' {
                        hit |= set[i] <= c && c <= set[i + 2];
                        i += 3
                    } else {
                        hit |= set[i] == c;
                        i += 1
                    }
                }
                hit != negate && go(&p[end + 1..], &n[1..])
            }
            Some(&c) => n.first() == Some(&c) && go(&p[1..], &n[1..]),
        }
    }
    go(&p, &n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_match_as_the_shell_matches_them() {
        assert!(matches("*", "anything"));
        assert!(matches("app-?", "app-1") && !matches("app-?", "app-12"));
        assert!(matches("[a-c]x", "bx") && !matches("[!a-c]x", "bx"));
        assert!(matches("*.zero", ".zero"));
        assert_eq!(braces("/a/{x,y}/b/{1,2}"), ["/a/x/b/1", "/a/x/b/2", "/a/y/b/1", "/a/y/b/2"]);
    }
}
