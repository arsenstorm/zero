//! Commands that look stuck, and stopping them so the agent carries on. A command is stuck when it's run well past
//! what it's expected to take (said by the agent with `zero expect`, its own timeout, learned from how long it took
//! before in that repo, else a default by kind) and it's hung: no output and its processes near no CPU for a while.
//! A busy or talkative command is slow, not stuck, and never touched; one waiting for input (a pager, an editor)
//! is stuck sooner. Stopping ends only the command's own processes, found under the task's CLI by their arguments.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, RwLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::uses::{arguments, children, info, rusage};

/// Settings › Agents › Tasks › Stuck commands.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub when: When,
    /// No output and no CPU for this long counts as hung.
    pub hung_minutes: f64,
    /// Stuck past this many times what it's expected to take…
    pub times: f64,
    /// …and never sooner than this, so a 2-second command isn't stuck at 6.
    pub floor_minutes: f64,
    /// Commands Zero never stops on its own, by any part of their text (`migrate`).
    pub never: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub enum When {
    /// Shown as stuck, for the user to stop.
    #[default]
    Tell,
    /// Stopped once stuck.
    Stop,
    /// Not looked at.
    Never,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { when: When::Tell, hung_minutes: 3.0, times: 3.0, floor_minutes: 3.0, never: vec![] }
    }
}

impl Settings {
    /// Whether Zero may stop `command` on its own.
    pub fn may_stop(&self, command: &str) -> bool {
        self.when == When::Stop && !self.never.iter().any(|p| !p.trim().is_empty() && command.contains(p.trim()))
    }
}

static SETTINGS: RwLock<Option<Settings>> = RwLock::new(None);

pub fn set(settings: Settings) {
    *SETTINGS.write().unwrap() = Some(settings)
}

pub fn settings() -> Settings {
    SETTINGS.read().unwrap().clone().unwrap_or_default()
}

/// A command by what's stable in it, so its runs compare: the program and the words after it up to the first path,
/// quote, variable or redirection, past any `cd …&&`, variables set and wrappers (`timeout 60`).
pub fn key(command: &str) -> String {
    const SETUP: [&str; 6] = ["cd", "export", "source", ".", "set", "pushd"];
    const WRAPPERS: [&str; 7] = ["time", "timeout", "nice", "env", "command", "exec", "nohup"];
    let line = command.lines().next().unwrap_or("");
    let segment = line
        .split([';', '|', '&'])
        .map(str::trim)
        .find(|s| !s.is_empty() && !SETUP.contains(&s.split_whitespace().next().unwrap_or("")))
        .unwrap_or("");
    let mut words = segment
        .split_whitespace()
        .skip_while(|w| (w.contains('=') && !w.starts_with('-')) || WRAPPERS.contains(w) || w.parse::<f64>().is_ok());
    let Some(program) = words.next() else { return String::new() };
    let program = program.trim_start_matches("./");
    let stable = |w: &&str| w.chars().all(|c| c.is_alphanumeric() || "-_:.@+,".contains(c));
    std::iter::once(program).chain(words.take_while(stable).take(3)).collect::<Vec<_>>().join(" ")
}

/// What a command is expected to take, and on whose word.
#[derive(Clone, Debug, PartialEq)]
pub enum Expected {
    /// The agent said so (`zero expect`).
    Said { seconds: u64, what: String },
    /// Its own timeout (Claude's Bash `timeout`).
    Timeout(u64),
    /// How long it took before in this repo: the middle run, and nine in ten.
    Usual { median: u64, p90: u64 },
    /// Nothing known: seconds for a quick program, minutes for anything else.
    Default(u64),
}

impl Expected {
    fn seconds(&self) -> u64 {
        match self {
            Expected::Said { seconds, .. } | Expected::Timeout(seconds) | Expected::Default(seconds) => *seconds,
            Expected::Usual { p90, .. } => *p90,
        }
    }

    fn says(&self) -> Option<String> {
        match self {
            Expected::Said { seconds, what } if what.is_empty() => Some(format!("past the {} the agent expected", span(*seconds))),
            Expected::Said { seconds, what } => Some(format!("past the {} the agent expected for {what}", span(*seconds))),
            Expected::Timeout(seconds) => Some(format!("its timeout {}", span(*seconds))),
            Expected::Usual { median, .. } => Some(format!("usually {}", span(*median))),
            Expected::Default(_) => None,
        }
    }
}

/// Programs that answer at once.
const QUICK: [&str; 22] = [
    "git", "ls", "cat", "grep", "rg", "find", "fd", "sed", "awk", "head", "tail", "echo", "pwd", "wc", "which", "mkdir", "rm", "cp", "mv",
    "gh", "zero", "jq",
];

/// For a command never seen in this repo.
pub fn default_for(key: &str) -> Expected {
    let program = key.split(' ').next().unwrap_or("");
    Expected::Default(if QUICK.contains(&program) { 30 } else { 120 })
}

/// How a running command is doing: how long it's run, how long since it last printed or used CPU, and the program
/// it's waiting on input for, if any.
pub struct Seen {
    pub elapsed: Duration,
    pub idle: Duration,
    pub input: Option<String>,
}

/// A stuck command: what the user is shown, and what the agent is told when it's stopped.
#[derive(Clone, Debug, PartialEq)]
pub struct Stuck {
    pub reason: String,
    pub note: String,
}

/// Waiting for input this long with nothing happening: no one is going to type.
const INPUT_IDLE: Duration = Duration::from_secs(30);

pub fn judge(command: &str, seen: &Seen, expected: &Expected, settings: &Settings) -> Option<Stuck> {
    if settings.when == When::Never {
        return None;
    }
    // Zero's own commands wait on the user or on other tasks by design (`zero wait`, `zero ask --block`).
    if key(command).split(' ').next() == Some("zero") {
        return None;
    }
    // The agent said it would take this long: Zero takes its word, however quiet it is.
    if let Expected::Said { seconds, .. } = expected
        && seen.elapsed < Duration::from_secs(*seconds)
    {
        return None;
    }
    let short = match key(command) {
        k if k.is_empty() => command.chars().take(40).collect(),
        k => k,
    };
    let elapsed = span(seen.elapsed.as_secs());
    if let Some(program) = &seen.input
        && seen.idle >= INPUT_IDLE
    {
        return Some(Stuck {
            reason: format!("Running `{short}` for {elapsed} · waiting for input ({program})"),
            note: format!(
                "Zero stopped `{short}`: it was waiting for input ({program}) that no one here can give. Try another way: a flag \
                 that doesn't ask, no pager (`--no-pager`, `| cat`), or no editor (`GIT_EDITOR=true`)."
            ),
        });
    }
    let minutes = |m: f64| Duration::from_secs_f64((m * 60.0).max(0.0));
    let limit = Duration::from_secs_f64(expected.seconds() as f64 * settings.times.max(1.0)).max(minutes(settings.floor_minutes));
    if seen.elapsed < limit || seen.idle < minutes(settings.hung_minutes) {
        return None;
    }
    let says = expected.says();
    let reason = match &says {
        Some(says) => format!("Running `{short}` for {elapsed} ({says}) · looks stuck"),
        None => format!("Running `{short}` for {elapsed} · looks stuck"),
    };
    let past = says
        .map(|s| match s.starts_with("past ") {
            true => format!(", {s}"),
            false => format!(", past {}", s.replace("usually", "its usual")),
        })
        .unwrap_or_default();
    let note = format!(
        "Zero stopped `{short}`: no output and no CPU for {}{past}; it was likely waiting for input or hung. Try another way, \
         and run long commands in the background.",
        span(seen.idle.as_secs())
    );
    Some(Stuck { reason, note })
}

/// "40 s", "7 min", "1 h 5 min".
pub fn span(seconds: u64) -> String {
    match seconds {
        s if s < 60 => format!("{s} s"),
        s if s < 3600 => format!("{} min", s / 60),
        s if s % 3600 < 60 => format!("{} h", s / 3600),
        s => format!("{} h {} min", s / 3600, s % 3600 / 60),
    }
}

/// `zero expect`'s "20m", "90s", "1h", "2h30m", or bare seconds.
pub fn parse_span(text: &str) -> Option<u64> {
    let text = text.trim();
    if let Ok(seconds) = text.parse::<u64>() {
        return Some(seconds);
    }
    let (mut total, mut number) = (0u64, String::new());
    for c in text.chars() {
        match c {
            '0'..='9' => number.push(c),
            'h' | 'm' | 's' if !number.is_empty() => {
                let n: u64 = number.parse().ok()?;
                total += n * [3600, 60, 1][usize::from(c == 'm') + 2 * usize::from(c == 's')];
                number.clear()
            }
            _ => return None,
        }
    }
    (number.is_empty() && total > 0).then_some(total)
}

/// How long each command took in each repo: the last runs of each, in milliseconds.
#[derive(Default)]
pub struct History {
    path: Option<PathBuf>,
    runs: HashMap<String, HashMap<String, Vec<u64>>>,
}

/// Runs kept per command: enough for a middle and a ninth decile, recent enough to follow a repo that got faster.
const KEPT: usize = 20;

impl History {
    /// Kept in `path` (durations.json), as last written there.
    pub fn open(path: PathBuf) -> History {
        let runs = std::fs::read(&path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        History { path: Some(path), runs }
    }

    /// ponytail: the whole file written on each run; a few KB. Batch it if it ever shows up in a profile.
    pub fn record(&mut self, cwd: &Path, command: &str, took: Duration) {
        let key = key(command);
        if key.is_empty() {
            return;
        }
        let runs = self.runs.entry(repo(cwd).display().to_string()).or_default().entry(key).or_default();
        runs.push(took.as_millis() as u64);
        if runs.len() > KEPT {
            runs.remove(0);
        }
        if let Some(path) = &self.path {
            let _ = std::fs::write(path, serde_json::to_vec(&self.runs).unwrap_or_default());
        }
    }

    /// Its median and p90 in seconds, from its runs in this repo.
    pub fn usual(&self, cwd: &Path, command: &str) -> Option<Expected> {
        let mut runs = self.runs.get(&repo(cwd).display().to_string())?.get(&key(command))?.clone();
        if runs.is_empty() {
            return None;
        }
        runs.sort_unstable();
        let at = |q: f64| runs[((runs.len() - 1) as f64 * q).round() as usize].div_ceil(1000);
        Some(Expected::Usual { median: at(0.5), p90: at(0.9) })
    }
}

static HISTORY: Mutex<Option<History>> = Mutex::new(None);

/// zerod's history, kept in its home.
pub fn open(home: &Path) {
    *HISTORY.lock().unwrap() = Some(History::open(home.join("durations.json")))
}

pub fn record(cwd: &Path, command: &str, took: Duration) {
    HISTORY.lock().unwrap().get_or_insert_with(History::default).record(cwd, command, took)
}

/// What a command is expected to take, from what's known of it: the agent's word, its timeout, its history, a default.
pub fn expected(cwd: &Path, command: &str, said: Option<Expected>, timeout: Option<u64>) -> Expected {
    said.or(timeout.map(Expected::Timeout))
        .or_else(|| HISTORY.lock().unwrap().as_ref().and_then(|h| h.usual(cwd, command)))
        .unwrap_or_else(|| default_for(&key(command)))
}

/// The repo a folder is in, a worktree's as its main checkout's, so every worktree of it shares one history; a folder
/// in none is its own.
pub fn repo(cwd: &Path) -> PathBuf {
    for dir in cwd.ancestors() {
        let git = dir.join(".git");
        if git.is_dir() {
            return dir.to_path_buf();
        }
        if let Ok(file) = std::fs::read_to_string(&git)
            && let Some(gitdir) = file.trim().strip_prefix("gitdir:")
        {
            // <main>/.git/worktrees/<name>
            let gitdir = Path::new(gitdir.trim());
            return gitdir
                .ancestors()
                .nth(3)
                .filter(|_| gitdir.parent().is_some_and(|p| p.ends_with("worktrees")))
                .unwrap_or(dir)
                .to_path_buf();
        }
    }
    cwd.to_path_buf()
}

// The command's processes, under its task's CLI.

/// Programs that wait for someone to type.
const ASKING: [&str; 10] = ["less", "more", "vi", "vim", "nvim", "nano", "emacs", "sudo", "pinentry", "ssh-askpass"];

/// The command's own processes: the topmost under the CLI whose arguments hold the start of its text (up to its first
/// quote or variable, which the CLI's shell may have escaped), each with everything it started.
fn processes(cli: i32, command: &str) -> Vec<Vec<i32>> {
    let line = command.lines().next().unwrap_or("");
    let needle = line[..line.find(['\'', '"', '\\', '$', '`', '!']).unwrap_or(line.len())].trim();
    if needle.len() < 2 {
        return vec![];
    }
    let (mut found, mut stack) = (vec![], children(cli));
    while let Some(pid) = stack.pop() {
        if arguments(pid).is_some_and(|(args, _)| args.join(" ").contains(needle)) {
            found.push(tree(pid));
        } else {
            stack.extend(children(pid));
        }
    }
    found
}

fn tree(root: i32) -> Vec<i32> {
    let (mut all, mut stack) = (vec![], vec![root]);
    while let Some(pid) = stack.pop() {
        all.push(pid);
        stack.extend(children(pid));
    }
    all
}

/// The command's CPU time so far (nanoseconds) and a program in it waiting for input; None when it isn't found.
pub(crate) fn sample(cli: i32, command: &str) -> Option<(u64, Option<String>)> {
    let pids: Vec<i32> = processes(cli, command).into_iter().flatten().collect();
    if pids.is_empty() {
        return None;
    }
    let cpu = pids.iter().filter_map(|p| rusage(*p)).map(|(cpu, _)| cpu).sum();
    let asking = pids.iter().filter_map(|p| info(*p)).map(|i| i.name().to_string()).find(|n| ASKING.contains(&n.as_str()));
    Some((cpu, asking))
}

unsafe extern "C" {
    safe fn kill(pid: i32, signal: i32) -> i32;
}

const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;
/// Between asking it to end and ending it.
const GRACE: Duration = Duration::from_secs(5);

/// Ends the command's processes: asked first (SIGTERM), then made to (SIGKILL) after a grace. Its own process group
/// when it has one apart from the CLI's, else each process. False when none were found.
pub(crate) fn terminate(cli: i32, command: &str) -> bool {
    let trees = processes(cli, command);
    if trees.is_empty() {
        return false;
    }
    let cli_group = info(cli).map(|i| i.pgid);
    let mut started = vec![];
    for tree in &trees {
        let top = tree[0];
        match info(top) {
            Some(i) if Some(i.pgid) != cli_group && i.pgid == top as u32 => {
                kill(-top, SIGTERM);
            }
            _ => tree.iter().for_each(|p| {
                kill(*p, SIGTERM);
            }),
        }
        started.extend(tree.iter().filter_map(|p| info(*p).map(|i| (*p, i.start_sec))));
    }
    std::thread::spawn(move || {
        std::thread::sleep(GRACE);
        // The same process still (a pid isn't taken again so soon, but its start time says for sure).
        for (pid, start) in started {
            if info(pid).is_some_and(|i| i.start_sec == start) {
                kill(pid, SIGKILL);
            }
        }
    });
    true
}
