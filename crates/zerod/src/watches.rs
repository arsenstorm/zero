//! Watching a file a process writes to (a build's log, a server's) for the task that asked (`zero watch --file`):
//! lines with what it's watching for, told with the lines that led up to them; the file going quiet; and the line
//! that says it's done, which ends the watch. What's watched for is plain text the agent chose, as it knows what this
//! process's trouble looks like; Zero tells, and the agent judges. Read from where the watch started (or left off),
//! never from the top.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde::{Deserialize, Serialize};

static POLL_MS: AtomicU64 = AtomicU64::new(2000);

/// How often watched files are read; quicker in tests.
pub fn poll_every(every: Duration) { POLL_MS.store(every.as_millis() as u64, Ordering::Relaxed) }
pub fn poll() -> Duration { Duration::from_millis(POLL_MS.load(Ordering::Relaxed)) }

/// The lines told before each match: what led up to it.
const BEFORE: usize = 3;
/// At most this many lines in one alert: a flood of errors is one message, not hundreds.
const MOST: usize = 40;
/// At most one alert this often; what matches meanwhile goes in the next.
pub const COOL_DOWN: Duration = Duration::from_secs(60);
/// At most this much read in one go, so a log that grew by gigabytes is caught up on over a few reads.
pub const CHUNK: u64 = 8 << 20;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Watch {
    #[serde(default)]
    pub id: String,
    pub session: String,
    pub file: PathBuf,
    /// What a line with trouble in it has: text (": error: ", "FAILED: "), or a pattern between slashes
    /// ("/:\d+:\d+: error: /", a compiler's error and not source quoting one). Any one is enough.
    #[serde(default)]
    pub alerts: Vec<String>,
    /// What the line saying it's finished has, the same way ("[4142/4142]"): told, and the watch ends.
    #[serde(default)]
    pub done: Option<String>,
    /// Minutes without the file growing before it's told it's gone quiet.
    #[serde(default)]
    pub quiet: Option<u64>,
    /// How far it's been read.
    #[serde(default)]
    pub offset: u64,
}

impl Watch {
    pub fn name(&self) -> String { self.file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| self.file.display().to_string()) }

    /// Its first line is what the app shows folded: which file, and the line that matched last.
    pub fn alert(&self, hits: &[String], latest: Option<&str>) -> String {
        let watched = self.alerts.iter().map(|a| format!("`{a}`")).collect::<Vec<_>>().join(", ");
        let last = hits.last().map(|l| l.trim()).unwrap_or_default();
        let latest = latest.filter(|l| hits.last().map(String::as_str) != Some(*l)).map(|l| format!("\nIts latest line: `{l}`")).unwrap_or_default();
        format!("Watch: `{}` printed `{last}`\n```\n{}\n```\nWatched for {watched}.{latest}\nThe watch goes on; `zero watch stop {}` ends it.", self.name(), hits.join("\n"), self.id)
    }

    pub fn finished(&self, line: &str) -> String {
        format!("Watch: `{}` is done (it printed `{}`), so the watch has ended.\n```\n{line}\n```", self.name(), self.done.as_deref().unwrap_or(""))
    }

    pub fn quieted(&self, latest: Option<&str>) -> String {
        format!("Watch: `{}` hasn't grown for {} minutes: it may have hung or stopped.{}", self.name(), self.quiet.unwrap_or(0),
                latest.map(|l| format!(" Its latest line: `{l}`")).unwrap_or_default())
    }
}

/// What a line is looked for by: text, or a pattern between slashes.
enum Pattern { Text(String), Regex(regex::Regex) }

impl Pattern {
    fn of(text: &str) -> Result<Pattern, String> {
        match text.strip_prefix('/').and_then(|t| t.strip_suffix('/')).filter(|t| !t.is_empty()) {
            Some(pattern) => regex::Regex::new(pattern).map(Pattern::Regex).map_err(|e| format!("Not a pattern, {text}: {e}")),
            None => Ok(Pattern::Text(text.into())),
        }
    }
    fn finds(&self, line: &str) -> bool {
        match self { Pattern::Text(text) => line.contains(text.as_str()), Pattern::Regex(regex) => regex.is_match(line) }
    }
}

/// What's been read of a watched file and not told yet.
pub struct Reading {
    alerts: Vec<Pattern>,
    until: Option<Pattern>,
    partial: String,
    recent: VecDeque<String>,
    pub hits: Vec<String>,
    pub done: Option<String>,
    pub latest: Option<String>,
}

impl Reading {
    /// For `watch`: its patterns read once; one that isn't a pattern is an error.
    pub fn new(watch: &Watch) -> Result<Reading, String> {
        Ok(Reading { alerts: watch.alerts.iter().map(|a| Pattern::of(a)).collect::<Result<_, _>>()?, until: watch.done.as_deref().map(Pattern::of).transpose()?,
                     partial: String::new(), recent: VecDeque::new(), hits: vec![], done: None, latest: None })
    }

    /// The next of what the file has: its lines, a line not yet ended kept for the next read.
    pub fn read(&mut self, _watch: &Watch, text: &str) {
        self.partial.push_str(text);
        while let Some(end) = self.partial.find('\n') {
            let line = self.partial[..end].trim_end_matches('\r').to_string();
            self.partial.drain(..=end);
            self.line(line);
        }
        // ponytail: a "line" that never ends (a progress bar's carriage returns) is let go past 1 MB.
        if self.partial.len() > 1 << 20 { self.partial.clear() }
    }

    fn line(&mut self, line: String) {
        if self.until.as_ref().is_some_and(|until| until.finds(&line)) { self.done = Some(line.clone()) }
        if self.alerts.iter().any(|alert| alert.finds(&line)) {
            if self.hits.len() < MOST { self.hits.extend(self.recent.drain(..)); self.hits.push(line.clone()) }
            self.recent.clear();
        } else {
            self.recent.push_back(line.clone());
            if self.recent.len() > BEFORE { self.recent.pop_front(); }
        }
        self.latest = Some(line);
    }
}

/// The watches, kept so they carry on after zerod restarts.
pub fn load(home: &Path) -> Vec<Watch> {
    std::fs::read(home.join("watches.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
}

pub fn keep(home: &Path, watches: &[Watch]) {
    if let Ok(data) = serde_json::to_vec_pretty(watches) { let _ = std::fs::write(home.join("watches.json"), data); }
}
