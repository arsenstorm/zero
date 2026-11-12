//! What each task's processes use, for the app: its CLI, the MCP servers the CLI started with, and the commands it
//! runs, each with everything they started in turn; memory (physical footprint, as Activity Monitor's Memory) and CPU
//! (percent of a core over the last interval). Read from the kernel (libproc) every few seconds, walking down from
//! the CLI's pid, and sent to clients only when it changes enough to show.
//!
//! What a task started and let go (a dev server with `nohup … &`, now launchd's) isn't under its CLI any more, and
//! isn't counted; nor is what runs in a VM (containers).

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

const EVERY: Duration = Duration::from_secs(5);
/// A child the CLI started this soon after itself, not a shell, is one of its MCP servers: CLIs start them all as they
/// start, and run commands (later, through a shell) only once the model asks.
const STARTING: u64 = 20;
pub(crate) const SHELLS: [&str; 5] = ["sh", "bash", "zsh", "fish", "dash"];
/// Smaller changes aren't sent: memory moves by kilobytes and CPU by a point or two between any two samples.
const MEMORY_CHANGE: u64 = 10 << 20;
const CPU_CHANGE: f32 = 5.0;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq)]
pub struct Part {
    /// Bytes.
    pub memory: u64,
    /// Percent of one core.
    pub cpu: f32,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq)]
pub struct Uses {
    pub cli: Part,
    pub mcp: Part,
    pub commands: Part,
}

impl Uses {
    fn memory(&self) -> u64 {
        self.cli.memory + self.mcp.memory + self.commands.memory
    }

    fn cpu(&self) -> f32 {
        self.cli.cpu + self.mcp.cpu + self.commands.cpu
    }

    /// Enough to show: a change of more than 10 MB that is more than 5% of it, or 5 points of CPU.
    fn differs(&self, other: &Uses) -> bool {
        let (a, b) = (self.memory(), other.memory());
        let moved = a.abs_diff(b);
        (moved > MEMORY_CHANGE && moved * 20 > a.max(b)) || (self.cpu() - other.cpu()).abs() >= CPU_CHANGE
    }
}

/// Each running task's uses, by session id; a task without a process (parked) isn't in it.
pub type Tasks = BTreeMap<String, Uses>;

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Kind {
    Cli,
    Mcp,
    Command,
}

/// What the last sample saw: each process's CPU time so far, which of the CLI's children are MCP servers, and what
/// was last sent.
#[derive(Default)]
pub struct Sampler {
    cpu: HashMap<i32, u64>,
    kinds: HashMap<i32, Kind>,
    at: Option<Instant>,
    sent: Option<Tasks>,
}

impl Sampler {
    /// Each task's uses now, from its CLI's pid down: None while none of them changed enough to show since the last
    /// sent. CPU is over the time since the last sample (none on the first).
    pub fn sample(&mut self, roots: &[(String, i32)]) -> Option<Tasks> {
        let now = Instant::now();
        let interval = self.at.map(|at| now.duration_since(at).as_nanos().max(1) as f32);
        let mut seen = HashMap::new();
        let mut tasks = Tasks::new();
        for (id, root) in roots {
            let Some(started) = info(*root).map(|i| i.start_sec) else { continue };
            let (mut uses, mut spent) = (Uses::default(), [0u64; 3]);
            let mut stack = vec![(*root, Kind::Cli)];
            while let Some((pid, kind)) = stack.pop() {
                let Some((cpu, memory)) = rusage(pid) else { continue };
                // One not there last time started since: all its time is in the interval.
                spent[kind as usize] += cpu.saturating_sub(self.cpu.get(&pid).copied().unwrap_or(0));
                seen.insert(pid, cpu);
                part(&mut uses, kind).memory += memory;
                for child in children(pid) {
                    let kind = if kind == Kind::Cli { *self.kinds.entry(child).or_insert_with(|| kind_of(child, started)) } else { kind };
                    stack.push((child, kind));
                }
            }
            if let Some(interval) = interval {
                for kind in [Kind::Cli, Kind::Mcp, Kind::Command] {
                    part(&mut uses, kind).cpu = (spent[kind as usize] as f32 * 1000.0 / interval).round() / 10.0;
                }
            }
            tasks.insert(id.clone(), uses);
        }
        self.kinds.retain(|pid, _| seen.contains_key(pid));
        (self.cpu, self.at) = (seen, Some(now));
        let changed = match &self.sent {
            None => true,
            Some(sent) => {
                sent.len() != tasks.len() || tasks.iter().any(|(id, uses)| sent.get(id).is_none_or(|before| uses.differs(before)))
            }
        };
        changed.then(|| {
            self.sent = Some(tasks.clone());
            tasks
        })
    }
}

fn part(uses: &mut Uses, kind: Kind) -> &mut Part {
    match kind {
        Kind::Cli => &mut uses.cli,
        Kind::Mcp => &mut uses.mcp,
        Kind::Command => &mut uses.commands,
    }
}

/// Zero's own stand-ins (`zerod mcp`, `zerod mcp lazy`) are MCP servers whenever they start; a shell runs a command;
/// anything else is a server if it started with the CLI.
pub(crate) fn kind_of(child: i32, cli_started: u64) -> Kind {
    let Some(info) = info(child) else { return Kind::Command };
    let name = info.name();
    if name == "zerod" {
        Kind::Mcp
    } else if SHELLS.contains(&name) || info.start_sec > cli_started + STARTING {
        Kind::Command
    } else {
        Kind::Mcp
    }
}

/// Every few seconds, what each task with a process uses, published for clients when it changed enough to show.
pub async fn follow(daemon: Arc<crate::daemon::Daemon>) {
    let mut sampler = Sampler::default();
    let mut tick = tokio::time::interval(EVERY);
    loop {
        tick.tick().await;
        let roots: Vec<(String, i32)> = daemon.sessions().iter().filter_map(|s| Some((s.id(), s.pid()?))).collect();
        if let Some(tasks) = sampler.sample(&roots) {
            daemon.publish_uses(tasks);
        }
    }
}

// libproc, as Activity Monitor reads it: no `ps` to start.

const PROC_PIDTBSDINFO: i32 = 3;
const RUSAGE_INFO_V2: i32 = 2;

#[repr(C)]
pub(crate) struct BsdInfo {
    flags: u32,
    pub(crate) status: u32,
    xstatus: u32,
    pid: u32,
    pub(crate) ppid: u32,
    ids: [u32; 6],
    rfu: u32,
    comm: [u8; 16],
    name: [u8; 32],
    nfiles: u32,
    pub(crate) pgid: u32,
    pjobc: u32,
    tdev: u32,
    tpgid: u32,
    nice: i32,
    pub(crate) start_sec: u64,
    start_usec: u64,
}

impl BsdInfo {
    pub(crate) fn name(&self) -> &str {
        let name = if self.name[0] != 0 { &self.name[..] } else { &self.comm[..] };
        let end = name.iter().position(|b| *b == 0).unwrap_or(name.len());
        std::str::from_utf8(&name[..end]).unwrap_or("")
    }
}

#[repr(C)]
struct RusageV2 {
    uuid: [u8; 16],
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    rest: [u64; 10],
}

#[repr(C)]
struct Timebase {
    numer: u32,
    denom: u32,
}

unsafe extern "C" {
    fn proc_listchildpids(ppid: i32, buffer: *mut i32, size: i32) -> i32;
    fn proc_listallpids(buffer: *mut i32, size: i32) -> i32;
    fn sysctl(name: *mut i32, namelen: u32, old: *mut u8, oldlen: *mut usize, new: *mut u8, newlen: usize) -> i32;
    fn proc_pidinfo(pid: i32, flavor: i32, arg: u64, buffer: *mut BsdInfo, size: i32) -> i32;
    fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut RusageV2) -> i32;
    fn mach_timebase_info(info: *mut Timebase) -> i32;
}

pub(crate) fn children(pid: i32) -> Vec<i32> {
    let mut pids = [0i32; 512];
    // Safety: the buffer is as long as said; the count returned is of pids written.
    let count = unsafe { proc_listchildpids(pid, pids.as_mut_ptr(), size_of_val(&pids) as i32) };
    pids[..count.clamp(0, pids.len() as i32) as usize].iter().copied().filter(|p| *p > 0).collect()
}

pub(crate) fn info(pid: i32) -> Option<BsdInfo> {
    let mut info = std::mem::MaybeUninit::<BsdInfo>::zeroed();
    let size = size_of::<BsdInfo>() as i32;
    // Safety: the buffer is a BsdInfo, laid out as proc_bsdinfo, and filled whole when the size comes back.
    (unsafe { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info.as_mut_ptr(), size) } == size).then(|| unsafe { info.assume_init() })
}

/// Its CPU time so far in nanoseconds, and its physical footprint in bytes.
pub(crate) fn rusage(pid: i32) -> Option<(u64, u64)> {
    let mut usage = std::mem::MaybeUninit::<RusageV2>::zeroed();
    // Safety: the buffer is a RusageV2, laid out as rusage_info_v2.
    if unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V2, usage.as_mut_ptr()) } != 0 {
        return None;
    }
    let usage = unsafe { usage.assume_init() };
    // In Mach time units (Apple silicon's tick is 125/3 ns).
    static TIMEBASE: OnceLock<(u64, u64)> = OnceLock::new();
    let (numer, denom) = *TIMEBASE.get_or_init(|| {
        let mut timebase = Timebase { numer: 1, denom: 1 };
        unsafe { mach_timebase_info(&mut timebase) };
        (timebase.numer.max(1) as u64, timebase.denom.max(1) as u64)
    });
    let ticks = (usage.user_time + usage.system_time) as u128;
    Some(((ticks * numer as u128 / denom as u128) as u64, usage.phys_footprint))
}

/// Every process's pid.
pub(crate) fn all_pids() -> Vec<i32> {
    let mut pids = vec![0i32; 8192];
    // Safety: the buffer is as long as said; the count returned is of pids written.
    let count = unsafe { proc_listallpids(pids.as_mut_ptr(), (pids.len() * size_of::<i32>()) as i32) };
    pids.truncate(count.clamp(0, pids.len() as i32) as usize);
    pids.retain(|p| *p > 0);
    pids
}

/// A process's arguments and environment, as the kernel keeps them (KERN_PROCARGS2). Another user's, or the
/// environment of one of Apple's own programs, isn't given: an empty environment.
pub(crate) fn arguments(pid: i32) -> Option<(Vec<String>, Vec<String>)> {
    const CTL_KERN: i32 = 1;
    const KERN_PROCARGS2: i32 = 49;
    let mut buffer = vec![0u8; 256 << 10];
    let mut size = buffer.len();
    let mut name = [CTL_KERN, KERN_PROCARGS2, pid];
    // Safety: the name is three ints; the buffer is as long as said, and size comes back as what was written.
    if unsafe { sysctl(name.as_mut_ptr(), 3, buffer.as_mut_ptr(), &mut size, std::ptr::null_mut(), 0) } != 0 || size < 4 {
        return None;
    }
    let argc = i32::from_ne_bytes(buffer[..4].try_into().ok()?).max(0) as usize;
    // The executable's path, then padding, then argc arguments, then the environment, each ending in a nul.
    let mut strings = buffer[4..size].split(|b| *b == 0).filter(|s| !s.is_empty()).skip(1).map(|s| String::from_utf8_lossy(s).into_owned());
    let args: Vec<String> = strings.by_ref().take(argc).collect();
    Some((args, strings.filter(|s| s.contains('=')).collect()))
}
