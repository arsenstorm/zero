//! What tasks left running: processes their commands started that outlived the command (`nohup … &`, a daemon,
//! launchd's now) or still run between turns, an iOS Simulator one booted, containers one brought up. Shown to the
//! user with what each holds; stopped only when they ask, and only what's recorded as the task's.
//!
//! A process is a task's when it's under its CLI as a command (uses.rs tells those from its MCP servers), or, let go
//! to launchd, when its environment has the task's ZERO_SESSION (every process its commands start inherits it) or
//! it's in the process group of a command seen under the CLI. macOS keeps Apple's own programs' environments to
//! themselves, so one of those let go between two samples isn't known as anyone's. Simulators and containers aren't
//! the task's processes: they're read from its commands (`simctl boot`, `docker run`, `compose up`; `hint`) and
//! matched against what runs (`simulators`, `containers`), read-only.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::uses::{self, Kind as Part};

/// How often processes are looked at; simulators and containers (a `docker ps`, a `simctl list`) every sixth time.
const EVERY: Duration = Duration::from_secs(5);
const OUTSIDE_EVERY: u32 = 6;
/// A task whose last step is this old has settled: what it left running is worth a look.
const SETTLED_AFTER: i64 = 30 * 60 * 1000;
/// What a command brought up that runs no more is forgotten after this.
const HINT_LIFE: i64 = 10 * 60 * 1000;
/// Between asking a process to end (SIGTERM) and making it (SIGKILL).
const GRACE: Duration = Duration::from_secs(5);
/// Zero's own programs, run by agents in the background (`zero wait &`), aren't anything left running.
const ZEROS: [&str; 4] = ["zerod", "zero", "zero-full", "zero-host"];

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Process,
    Simulator,
    Container,
}

/// One thing left running, as clients see it.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Thing {
    pub id: String,
    pub kind: Kind,
    /// Its command line, a simulator's device name, a container's name or a Compose project's.
    pub name: String,
    /// Since when, in milliseconds since 1970.
    pub since: i64,
    /// Bytes (physical footprint, with what it started; a container's as its runtime counts it).
    pub memory: u64,
    /// Percent of a core; none for simulators and containers.
    pub cpu: f32,
    #[serde(skip)]
    stop: Stop,
}

impl Thing {
    pub fn pid(&self) -> Option<i32> {
        match self.stop {
            Stop::Process { pid, .. } => Some(pid),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Stop {
    /// `group`: it leads a process group of its own, which is stopped whole.
    Process {
        pid: i32,
        start: u64,
        group: bool,
    },
    Simulator {
        udid: String,
    },
    Container {
        runtime: Runtime,
        id: String,
    },
    Compose {
        runtime: Runtime,
        project: String,
    },
}

/// A task's things left running, for clients: its name, whether it's archived, and whether it has settled (done,
/// archived, or nothing new for half an hour), when what it left is worth pointing out.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Left {
    pub task: String,
    pub archived: bool,
    pub settled: bool,
    pub things: Vec<Thing>,
}

/// By session id; a task with nothing left running isn't in it.
pub type Tasks = BTreeMap<String, Left>;

/// A task to look for: its CLI's pid while it runs (none, parked or archived), and whether it's between turns.
pub struct Root {
    pub session: String,
    pub pid: Option<i32>,
    pub idle: bool,
}

/// What the last look saw: whose each process let go to launchd is (by pid and start), the process groups of
/// commands seen under each CLI, and each process's CPU time, for the next look's share of a core.
#[derive(Default)]
pub struct Finder {
    owners: HashMap<(i32, u64), Option<String>>,
    groups: HashMap<u32, String>,
    cpu: HashMap<i32, u64>,
    at: Option<Instant>,
}

impl Finder {
    /// Each task's processes left running now: commands under its CLI between its turns, and what it let go to launchd.
    pub fn processes(&mut self, roots: &[Root]) -> BTreeMap<String, Vec<Thing>> {
        let now = Instant::now();
        let interval = self.at.map(|at| now.duration_since(at).as_nanos().max(1) as f32);
        let mut cpu = HashMap::new();
        let mut found: BTreeMap<String, Vec<Thing>> = BTreeMap::new();
        let sessions: HashSet<&str> = roots.iter().map(|r| r.session.as_str()).collect();
        let clis: HashSet<i32> = roots.iter().filter_map(|r| r.pid).collect();
        for root in roots {
            let Some(pid) = root.pid else { continue };
            let Some(cli) = uses::info(pid) else { continue };
            for child in uses::children(pid) {
                if uses::kind_of(child, cli.start_sec) != Part::Command {
                    continue;
                }
                for (_, info) in tree(child) {
                    if info.pgid != cli.pgid {
                        self.groups.insert(info.pgid, root.session.clone());
                    }
                }
                if root.idle
                    && let Some(thing) = self.thing(child, cli.pgid, interval, &mut cpu)
                {
                    found.entry(root.session.clone()).or_default().push(thing);
                }
            }
        }
        let (mut seen, mut pgids) = (HashSet::new(), HashSet::new());
        for pid in uses::all_pids() {
            let Some(info) = uses::info(pid) else { continue };
            pgids.insert(info.pgid);
            if info.ppid != 1 || clis.contains(&pid) || ZEROS.contains(&info.name()) {
                continue;
            }
            let key = (pid, info.start_sec);
            seen.insert(key);
            let owner = self.owners.entry(key).or_insert_with(|| session_of(pid)).clone().or_else(|| self.groups.get(&info.pgid).cloned());
            if let Some(owner) = owner.filter(|o| sessions.contains(o.as_str()))
                && let Some(thing) = self.thing(pid, 0, interval, &mut cpu)
            {
                found.entry(owner).or_default().push(thing);
            }
        }
        self.owners.retain(|key, _| seen.contains(key));
        self.groups.retain(|pgid, _| pgids.contains(pgid));
        (self.cpu, self.at) = (cpu, Some(now));
        found
    }

    /// `pid` and what it started, as one thing: `cli_group`, its CLI's process group, which it isn't to stop.
    fn thing(&self, pid: i32, cli_group: u32, interval: Option<f32>, cpu: &mut HashMap<i32, u64>) -> Option<Thing> {
        let info = uses::info(pid)?;
        let (mut memory, mut spent) = (0, 0);
        for (each, _) in tree(pid) {
            let Some((time, footprint)) = uses::rusage(each) else { continue };
            spent += time.saturating_sub(self.cpu.get(&each).copied().unwrap_or(time));
            cpu.insert(each, time);
            memory += footprint;
        }
        Some(Thing {
            id: format!("p{pid}-{}", info.start_sec),
            kind: Kind::Process,
            name: name(pid, 0),
            since: info.start_sec as i64 * 1000,
            memory,
            cpu: interval.map_or(0.0, |interval| (spent as f32 * 1000.0 / interval).round() / 10.0),
            stop: Stop::Process { pid, start: info.start_sec, group: info.pgid == pid as u32 && info.pgid != cli_group },
        })
    }
}

/// `pid` and everything under it, with what the kernel says of each.
fn tree(pid: i32) -> Vec<(i32, uses::BsdInfo)> {
    let (mut all, mut stack) = (vec![], vec![pid]);
    while let Some(pid) = stack.pop() {
        let Some(info) = uses::info(pid) else { continue };
        stack.extend(uses::children(pid));
        all.push((pid, info));
    }
    all
}

/// The task a process was started for, from its environment.
fn session_of(pid: i32) -> Option<String> {
    let (_, env) = uses::arguments(pid)?;
    env.into_iter().find_map(|v| v.strip_prefix("ZERO_SESSION=").map(String::from)).filter(|s| !s.is_empty())
}

/// A process as the user would know it: its command line, the program by its name. A shell is named by what it runs
/// (its first child that isn't a shell, else its script).
fn name(pid: i32, depth: usize) -> String {
    let args = uses::arguments(pid).map(|(args, _)| args).unwrap_or_default();
    let program = args.first().map(|a| a.rsplit('/').next().unwrap_or(a).trim_start_matches('-').to_string());
    let Some(program) = program else { return uses::info(pid).map(|i| i.name().to_string()).unwrap_or_default() };
    if uses::SHELLS.contains(&program.as_str()) {
        if depth < 4
            && let Some(child) = uses::children(pid).into_iter().next()
        {
            return name(child, depth + 1);
        }
        if let Some(at) = args.iter().position(|a| a == "-c" || a == "-lc" || a == "-ic")
            && let Some(script) = args.get(at + 1)
        {
            return shorten(script.lines().next().unwrap_or(script));
        }
    }
    shorten(&std::iter::once(program.as_str()).chain(args.iter().skip(1).map(String::as_str)).collect::<Vec<_>>().join(" "))
}

fn shorten(text: &str) -> String {
    let text = text.trim();
    if text.chars().count() <= 200 { text.to_string() } else { text.chars().take(199).collect::<String>() + "…" }
}

/// Stops it: a process with SIGTERM, then SIGKILL for whatever of it is still there after a grace period (its whole
/// group when it leads one); a simulator shut down; a container, or a Compose project's, stopped (nothing removed).
pub async fn stop(thing: &Thing) -> Result<(), String> {
    match &thing.stop {
        Stop::Process { pid, start, group } => {
            let alive = |(pid, start): &(i32, u64)| uses::info(*pid).is_some_and(|i| i.start_sec == *start && i.status != SZOMB);
            if !alive(&(*pid, *start)) {
                return Ok(());
            }
            let all: Vec<(i32, u64)> = tree(*pid).into_iter().map(|(p, i)| (p, i.start_sec)).collect();
            let signal = |signal: i32| {
                if *group {
                    kill(-pid, signal);
                }
                for each in all.iter().filter(|each| alive(each)) {
                    kill(each.0, signal);
                }
            };
            signal(SIGTERM);
            let began = Instant::now();
            while all.iter().any(alive) && began.elapsed() < GRACE {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            if all.iter().any(alive) {
                signal(SIGKILL);
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            Ok(())
        }
        Stop::Simulator { udid } => run(&["xcrun", "simctl", "shutdown", udid]).await.map(|_| ()),
        Stop::Container { runtime, id } => run(&[runtime.program(), "stop", id]).await.map(|_| ()),
        Stop::Compose { runtime, project } => run(&[runtime.program(), "compose", "-p", project, "stop"]).await.map(|_| ()),
    }
}

const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;
const SZOMB: u32 = 5;

unsafe extern "C" {
    safe fn kill(pid: i32, signal: i32) -> i32;
}

/// Runs a program on the user's login PATH: what it printed, or why it failed.
async fn run(args: &[&str]) -> Result<String, String> {
    let argv = crate::adapter::on_login_path(args);
    let output = tokio::process::Command::new(&argv[0]).args(&argv[1..]).stdin(std::process::Stdio::null()).kill_on_drop(true).output();
    match tokio::time::timeout(Duration::from_secs(60), output).await {
        Ok(Ok(output)) if output.status.success() => Ok(String::from_utf8_lossy(&output.stdout).into_owned()),
        Ok(Ok(output)) => Err(format!("{} failed: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim())),
        Ok(Err(error)) => Err(format!("couldn't run {}: {error}", args[0])),
        Err(_) => Err(format!("{} took over a minute", args.join(" "))),
    }
}

// What commands bring up.

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub enum Runtime {
    Docker,
    Podman,
}

impl Runtime {
    fn program(self) -> &'static str {
        match self {
            Runtime::Docker => "docker",
            Runtime::Podman => "podman",
        }
    }
}

/// What a command brought up, as far as it says.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Hint {
    /// `simctl boot <device>`, an `xcodebuild` for a simulator, or `open -a Simulator` (no device: whichever boots).
    Simulator { device: Option<String> },
    /// `docker run`: the container's id when it printed one (`-d`), its name when it was given one.
    Container { runtime: Runtime, id: Option<String>, name: Option<String> },
    /// `compose up`: its project when named, else what's brought up from the command's folder or under it.
    Compose { runtime: Runtime, project: Option<String>, dir: String },
}

/// What `command`, run in `cwd`, brought up, from its words and what it printed.
pub fn hint(command: &str, cwd: &str, output: &str) -> Option<Hint> {
    static ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^([0-9a-f]{64})\s*$").unwrap());
    static PARTS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"&&|\|\||[;|\n]").unwrap());
    // Where each part runs: the command's folder, then wherever a `cd` in it went.
    let mut dir = std::path::PathBuf::from(cwd);
    PARTS.split(command).find_map(|part| {
        let words = words(part);
        if words.first().is_some_and(|w| w == "cd") {
            if let Some(to) = words.get(1) {
                dir = dir
                    .join(to.strip_prefix("~/").map_or(to.clone(), |rest| format!("{}/{rest}", std::env::var("HOME").unwrap_or_default())));
            }
            return None;
        }
        let word = |w: &str| words.iter().position(|x| x == w);
        let after = |flags: &[&str]| {
            words.iter().enumerate().find_map(|(i, w)| {
                flags
                    .iter()
                    .find_map(|f| if w == f { words.get(i + 1).cloned() } else { w.strip_prefix(&format!("{f}=")).map(String::from) })
            })
        };
        let program = words.first().map(|w| w.rsplit('/').next().unwrap_or(w).to_string()).unwrap_or_default();
        let runtime = match program.as_str() {
            "docker" | "docker-compose" => Some(Runtime::Docker),
            "podman" | "podman-compose" => Some(Runtime::Podman),
            _ => None,
        };
        if program == "xcrun" || program == "simctl" {
            let boot =
                word("simctl").or((program == "simctl").then_some(0)).and_then(|at| (words.get(at + 1)? == "boot").then_some(at + 2))?;
            return Some(Hint::Simulator { device: words.get(boot).filter(|d| !d.starts_with('-')).cloned() });
        }
        if program == "open" && after(&["-a"]).is_some_and(|app| app.trim_end_matches(".app").ends_with("Simulator")) {
            return Some(Hint::Simulator { device: None });
        }
        if program == "xcodebuild" {
            let destination = after(&["-destination"]).filter(|d| d.contains("Simulator"))?;
            let device = destination.split(',').find_map(|kv| kv.strip_prefix("name=").or(kv.strip_prefix("id=")).map(String::from));
            return Some(Hint::Simulator { device });
        }
        let runtime = runtime?;
        let compose = program.ends_with("-compose") || words.get(1).is_some_and(|w| w == "compose");
        if compose && word("up").is_some() {
            return Some(Hint::Compose { runtime, project: after(&["-p", "--project-name"]), dir: dir.to_string_lossy().into_owned() });
        }
        let run = match words.get(1).map(String::as_str) {
            Some("run") => true,
            Some("container") => words.get(2).is_some_and(|w| w == "run"),
            _ => false,
        };
        run.then(|| Hint::Container { runtime, id: ID.captures(output).map(|c| c[1].to_string()), name: after(&["--name"]) })
    })
}

/// A command's words, as a shell splits them on spaces and quotes (near enough to read it by).
fn words(command: &str) -> Vec<String> {
    let (mut words, mut word, mut quote, mut any) = (vec![], String::new(), None, false);
    for c in command.chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => word.push(c),
            (None, '\'' | '"') => (quote, any) = (Some(c), true),
            (None, c) if c.is_whitespace() => {
                if any || !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
                any = false;
            }
            (None, c) => word.push(c),
        }
    }
    if any || !word.is_empty() {
        words.push(word);
    }
    words
}

/// What each task brought up, by session, with when (ms): newest first, so the latest of two claims wins.
type Hints<'a> = &'a [(String, i64, Hint)];

/// The containers `ps` lists (`<runtime> ps --no-trunc --format '{{json .}}'`, a line each) that a task's commands
/// brought up: by the id or name `run` gave, or, for Compose, by the project's name or the folder it came up from.
/// A project is one thing. `memory`: each container's, by id.
pub fn containers(runtime: Runtime, ps: &str, memory: &HashMap<String, u64>, hints: Hints) -> BTreeMap<String, Vec<Thing>> {
    let mut hints: Vec<&(String, i64, Hint)> = hints.iter().collect();
    hints.sort_by_key(|(_, at, _)| std::cmp::Reverse(*at));
    let mut found: BTreeMap<String, Vec<Thing>> = BTreeMap::new();
    for line in ps.lines() {
        let Ok(container) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        let id = container["ID"].as_str().or(container["Id"].as_str()).unwrap_or_default().to_string();
        let name = match &container["Names"] {
            serde_json::Value::Array(names) => names.first().and_then(|n| n.as_str()).unwrap_or_default().to_string(),
            names => names.as_str().unwrap_or_default().split(',').next().unwrap_or_default().to_string(),
        };
        let labels: HashMap<String, String> = match &container["Labels"] {
            serde_json::Value::Object(labels) => {
                labels.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or_default().to_string())).collect()
            }
            labels => labels
                .as_str()
                .unwrap_or_default()
                .split(',')
                .filter_map(|kv| kv.split_once('='))
                .map(|(k, v)| (k.into(), v.into()))
                .collect(),
        };
        let memory = memory.get(&id).copied().unwrap_or(0);
        let project = labels.get("com.docker.compose.project");
        let folder = labels.get("com.docker.compose.project.working_dir").map(String::as_str).unwrap_or_default();
        let claim = hints.iter().find(|(_, _, hint)| match (hint, project) {
            (Hint::Compose { runtime: r, project: p, dir }, Some(project)) => {
                *r == runtime && p.as_ref().map_or(folder == dir || folder.starts_with(&format!("{dir}/")), |p| p == project)
            }
            (Hint::Container { runtime: r, id: i, name: n }, None) => {
                *r == runtime
                    && (i.as_ref().is_some_and(|i| !id.is_empty() && (i.starts_with(&id) || id.starts_with(i)))
                        || n.as_ref() == Some(&name))
            }
            _ => false,
        });
        let Some((session, at, _)) = claim else { continue };
        let things = found.entry(session.clone()).or_default();
        match project {
            Some(project) => match things.iter_mut().find(|t| t.stop == Stop::Compose { runtime, project: project.clone() }) {
                Some(thing) => thing.memory += memory,
                None => things.push(Thing {
                    id: format!("compose-{}-{project}", runtime.program()),
                    kind: Kind::Container,
                    name: project.clone(),
                    since: *at,
                    memory,
                    cpu: 0.0,
                    stop: Stop::Compose { runtime, project: project.clone() },
                }),
            },
            None => things.push(Thing {
                id: format!("container-{}", &id[..id.len().min(12)]),
                kind: Kind::Container,
                name,
                since: *at,
                memory,
                cpu: 0.0,
                stop: Stop::Container { runtime, id },
            }),
        }
    }
    found
}

/// The simulators `list` (`xcrun simctl list devices booted -j`) has booted that a task booted: named by its
/// device's name or udid, or, unnamed (`open -a Simulator`), booted within five minutes of its command. `booted`:
/// when each booted (its launchd_sim's start, ms) and what it holds, by udid; one booted before the command isn't its.
pub fn simulators(list: &str, booted: &HashMap<String, (i64, u64)>, hints: Hints) -> BTreeMap<String, Vec<Thing>> {
    let list: serde_json::Value = serde_json::from_str(list).unwrap_or_default();
    let devices =
        list["devices"].as_object().into_iter().flat_map(|runtimes| runtimes.values()).flat_map(|d| d.as_array().into_iter().flatten());
    let mut hints: Vec<&(String, i64, Hint)> = hints.iter().collect();
    hints.sort_by_key(|(_, at, _)| std::cmp::Reverse(*at));
    let mut found: BTreeMap<String, Vec<Thing>> = BTreeMap::new();
    for device in devices.filter(|d| d["state"] == "Booted") {
        let (udid, name) = (device["udid"].as_str().unwrap_or_default(), device["name"].as_str().unwrap_or_default());
        let (since, memory) = booted.get(udid).copied().unwrap_or_default();
        let after = |at: i64| since == 0 || since >= at - 10_000;
        let named = hints.iter().find(|(_, at, hint)| {
            matches!(hint, Hint::Simulator { device: Some(d) } if d.eq_ignore_ascii_case(name) || d.eq_ignore_ascii_case(udid))
                && after(*at)
        });
        let unnamed = || {
            hints
                .iter()
                .find(|(_, at, hint)| matches!(hint, Hint::Simulator { device: None }) && since != 0 && after(*at) && since <= at + 300_000)
        };
        let Some((session, at, _)) = named.or_else(unnamed) else { continue };
        found.entry(session.clone()).or_default().push(Thing {
            id: format!("simulator-{udid}"),
            kind: Kind::Simulator,
            name: name.to_string(),
            since: if since == 0 { *at } else { since },
            memory,
            cpu: 0.0,
            stop: Stop::Simulator { udid: udid.to_string() },
        });
    }
    found
}

/// Simulators and containers tasks brought up, by session: asked of `simctl` and each runtime only when a task's
/// commands brought one up.
async fn outside(hints: Hints<'_>) -> BTreeMap<String, Vec<Thing>> {
    let mut found = BTreeMap::new();
    if hints.iter().any(|(_, _, h)| matches!(h, Hint::Simulator { .. }))
        && let Ok(list) = run(&["xcrun", "simctl", "list", "devices", "booted", "-j"]).await
    {
        merge(&mut found, simulators(&list, &booted(), hints));
    }
    for runtime in [Runtime::Docker, Runtime::Podman] {
        let brought = |h: &Hint| matches!(h, Hint::Container { runtime: r, .. } | Hint::Compose { runtime: r, .. } if *r == runtime);
        if !hints.iter().any(|(_, _, h)| brought(h)) {
            continue;
        }
        let Ok(ps) = run(&[runtime.program(), "ps", "--no-trunc", "--format", "{{json .}}"]).await else { continue };
        let mut things = containers(runtime, &ps, &HashMap::new(), hints);
        if !things.is_empty() {
            let stats = run(&[runtime.program(), "stats", "--no-stream", "--no-trunc", "--format", "{{.ID}}\t{{.MemUsage}}"]).await;
            let memory = stats
                .unwrap_or_default()
                .lines()
                .filter_map(|line| Some((line.split('\t').next()?.to_string(), bytes(line.split('\t').nth(1)?)?)))
                .collect();
            things = containers(runtime, &ps, &memory, hints);
        }
        merge(&mut found, things);
    }
    found
}

/// `123.4MiB / 7.6GiB`'s first figure, in bytes.
fn bytes(usage: &str) -> Option<u64> {
    let used = usage.split('/').next()?.trim();
    let at = used.find(|c: char| c.is_ascii_alphabetic())?;
    let (number, unit) = used.split_at(at);
    let scale: f64 = match unit {
        "B" => 1.0,
        "kB" | "KB" | "KiB" => 1024.0,
        "MB" | "MiB" => 1024.0 * 1024.0,
        "GB" | "GiB" => 1024.0 * 1024.0 * 1024.0,
        _ => return None,
    };
    Some((number.trim().parse::<f64>().ok()? * scale) as u64)
}

/// When each booted simulator booted and what it holds, by udid: its launchd_sim (whose arguments name its device's
/// folder) and everything under it.
fn booted() -> HashMap<String, (i64, u64)> {
    static UDID: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"Devices/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})").unwrap());
    let mut booted = HashMap::new();
    for pid in uses::all_pids() {
        let Some(info) = uses::info(pid).filter(|i| i.name() == "launchd_sim") else { continue };
        let Some((args, _)) = uses::arguments(pid) else { continue };
        let Some(udid) = args.iter().find_map(|a| UDID.captures(a).map(|c| c[1].to_string())) else { continue };
        let memory = tree(pid).iter().filter_map(|(p, _)| uses::rusage(*p)).map(|(_, m)| m).sum();
        booted.insert(udid, (info.start_sec as i64 * 1000, memory));
    }
    booted
}

fn merge(into: &mut BTreeMap<String, Vec<Thing>>, from: BTreeMap<String, Vec<Thing>>) {
    for (session, things) in from {
        into.entry(session).or_default().extend(things)
    }
}

/// What a command brought up, kept (left.json) so a restart doesn't forget it: the task, the command's item, when.
#[derive(Serialize, Deserialize, Clone)]
struct Kept {
    session: String,
    item: String,
    at: i64,
    hint: Hint,
}

const KEPT: &str = "left.json";

/// Every few seconds, what each task left running, published for clients when it changed enough to show. Learns what
/// commands bring up from the tasks' steps as they come.
pub async fn follow(daemon: Arc<crate::daemon::Daemon>) {
    let home = daemon.home().to_path_buf();
    let mut kept: Vec<Kept> = std::fs::read(home.join(KEPT)).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
    let mut events = daemon.subscribe();
    let mut tick = tokio::time::interval(EVERY);
    let (mut finder, mut outside_things, mut ticks, mut learned) = (Finder::default(), BTreeMap::new(), 0u32, true);
    let mut sent: Option<Tasks> = None;
    loop {
        tokio::select! {
            event = events.recv() => match event {
                Ok(crate::model::Event { session, change: crate::model::Change::Item { item }, .. }) => {
                    let crate::model::ItemKind::Command { command, cwd, output, .. } = &item.kind else { continue };
                    let Some(hint) = hint(command, cwd, output) else { continue };
                    kept.retain(|k| !(k.session == session && k.item == item.id));
                    kept.push(Kept { session, item: item.id.clone(), at: item.at.unwrap_or_else(crate::now_ms), hint });
                    save(&home, &kept);
                    learned = true;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                _ => {}
            },
            _ = tick.tick() => {
                let tasks = daemon.left_roots();
                let roots: Vec<Root> = tasks.iter().map(|t| Root { session: t.id.clone(), pid: t.pid, idle: t.idle }).collect();
                let mut found = finder.processes(&roots);
                if learned || ticks.is_multiple_of(OUTSIDE_EVERY) {
                    let known: HashSet<&str> = tasks.iter().map(|t| t.id.as_str()).collect();
                    let now = crate::now_ms();
                    let hints: Vec<(String, i64, Hint)> =
                        kept.iter().filter(|k| known.contains(k.session.as_str())).map(|k| (k.session.clone(), k.at, k.hint.clone())).collect();
                    outside_things = outside(&hints).await;
                    // What brought up nothing that still runs is let go once it's old enough to have come up.
                    let before = kept.len();
                    kept.retain(|k| known.contains(k.session.as_str()) && (now - k.at < HINT_LIFE || outside_things.contains_key(&k.session)));
                    if kept.len() != before {
                        save(&home, &kept);
                    }
                    learned = false;
                }
                ticks = ticks.wrapping_add(1);
                merge(&mut found, outside_things.clone());
                let now = crate::now_ms();
                let left: Tasks = tasks
                    .into_iter()
                    .filter_map(|t| {
                        let things = found.remove(&t.id)?;
                        let settled = t.archived || t.done || t.last.is_some_and(|last| now - last >= SETTLED_AFTER);
                        Some((t.id, Left { task: t.label, archived: t.archived, settled, things }))
                    })
                    .collect();
                if sent.as_ref().is_none_or(|sent| differs(sent, &left)) {
                    daemon.publish_left(left.clone());
                    sent = Some(left);
                }
            }
        }
    }
}

fn save(home: &Path, kept: &[Kept]) {
    let _ = std::fs::write(home.join(KEPT), serde_json::to_vec(kept).unwrap_or_default());
}

/// Enough to show: something come or gone, a task settled, or what one holds moved as uses.rs would show it.
fn differs(a: &Tasks, b: &Tasks) -> bool {
    a.len() != b.len()
        || a.iter().zip(b).any(|((ia, la), (ib, lb))| {
            ia != ib
                || la.settled != lb.settled
                || la.archived != lb.archived
                || la.task != lb.task
                || la.things.len() != lb.things.len()
                || la.things.iter().zip(&lb.things).any(|(x, y)| {
                    let moved = x.memory.abs_diff(y.memory);
                    x.id != y.id || (moved > 10 << 20 && moved * 20 > x.memory.max(y.memory)) || (x.cpu - y.cpu).abs() >= 5.0
                })
        })
}

/// A task as `follow` looks for what it left: its CLI while it runs, whether it's between turns, done or archived,
/// and when its last step was (ms).
pub struct Task {
    pub id: String,
    pub label: String,
    pub pid: Option<i32>,
    pub idle: bool,
    pub done: bool,
    pub archived: bool,
    pub last: Option<i64>,
}
