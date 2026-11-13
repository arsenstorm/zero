//! Where the user's commands run (`zero run`, a production deploy say): somewhere a restart of zerod can't reach, their
//! output and exit code going to files that zerod follows, and that a zerod started again picks up: detached from
//! zerod in a shell of their own. Never as zerod's own children: its restart would cut them off mid-run.

use std::path::{Path, PathBuf};
use std::time::Duration;

pub struct Runs {
    /// Where runs keep their output, exit code and process id.
    dir: PathBuf,
}

impl Runs {
    pub fn new(dir: PathBuf) -> Runs {
        Runs { dir }
    }

    /// Starts `command` for ask `id`, in `cwd`: the handle to find it by again ("file:<id>").
    pub async fn start(&self, id: &str, command: &str, cwd: Option<&str>) -> Result<String, String> {
        let shell = format!("export ZERO_ASK_ID={id}; {command}");
        std::fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        let (out, exit, pid) =
            (self.dir.join(format!("{id}.out")), self.dir.join(format!("{id}.exit")), self.dir.join(format!("{id}.pid")));
        // The run in the background of a shell that exits at once: launchd takes it on, so nothing of zerod's ends it.
        // The exit code lands whole (written aside, then moved), so a half-written one is never read.
        let script = r#"( /bin/zsh -lic "$ZERO_RUN" < /dev/null > "$ZERO_OUT" 2>&1; echo $? > "$ZERO_EXIT.part"; mv "$ZERO_EXIT.part" "$ZERO_EXIT" ) & echo $! > "$ZERO_PID""#;
        let mut start = std::process::Command::new("/bin/sh");
        start
            .args(["-c", script])
            .env("ZERO_RUN", &shell)
            .env("ZERO_OUT", &out)
            .env("ZERO_EXIT", &exit)
            .env("ZERO_PID", &pid)
            .env("TERM", "dumb")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        if let Some(cwd) = cwd.filter(|c| Path::new(c).is_dir()) {
            start.current_dir(cwd);
        }
        let started = start.status().map_err(|e| format!("The command didn't start: {e}"))?;
        if !started.success() {
            return Err("The command didn't start".into());
        }
        Ok(format!("file:{id}"))
    }

    /// The run's output file and the file its exit code lands in.
    pub fn files(&self, handle: &str) -> Option<(PathBuf, PathBuf)> {
        let name = handle.strip_prefix("file:")?;
        Some((self.dir.join(format!("{name}.out")), self.dir.join(format!("{name}.exit"))))
    }

    /// Whether something still runs it: false once it has ended, or nothing knows of it any more.
    pub async fn alive(&self, handle: &str) -> bool {
        handle.strip_prefix("file:").and_then(|id| self.pid(id)).is_some_and(|pid| signal(pid, "-0"))
    }

    /// Stops it: the user cancelled the run.
    pub async fn stop(&self, handle: &str) {
        let Some(pid) = handle.strip_prefix("file:").and_then(|id| self.pid(id)) else { return };
        // Everything under it, held still so none goes on to what's next, asked to stop, then made to: its
        // shell is an interactive one (`zsh -lic`), which ignores a polite stop, and signalled only it and its
        // own children, the command's went on.
        let tree = tree(pid);
        for &p in &tree {
            signal(p, "-STOP");
        }
        // The shells (whatever has a process under it) go at once: asked politely, an interactive one ignored
        // it, and as soon as the command under it ended it went on to the next one (`sleep 3; touch x`
        // touched x before the KILL below came). Then the commands themselves are asked to stop.
        let parents: Vec<u32> = tree.iter().copied().filter(|&p| tree.iter().any(|&c| c != p && parent_of(c) == Some(p))).collect();
        for &p in &parents {
            signal(p, "-KILL");
        }
        for &p in tree.iter().filter(|p| !parents.contains(p)) {
            signal(p, "-TERM");
            signal(p, "-CONT");
        }
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        for &p in &tree {
            if signal(p, "-0") {
                signal(p, "-KILL");
            }
        }
    }

    /// Let go of, once its outcome is kept on its ask: its files gone.
    pub async fn release(&self, handle: &str) {
        if let Some((out, exit)) = self.files(handle) {
            let _ = std::fs::remove_file(&out);
            let _ = std::fs::remove_file(&exit);
            let _ = std::fs::remove_file(out.with_extension("pid"));
        }
    }

    fn pid(&self, id: &str) -> Option<u32> {
        std::fs::read_to_string(self.dir.join(format!("{id}.pid"))).ok()?.trim().parse().ok()
    }
}

/// A process's parent, by `ps`.
fn parent_of(pid: u32) -> Option<u32> {
    let out = std::process::Command::new("/bin/ps").args(["-o", "ppid=", "-p", &pid.to_string()]).output().ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse().ok()
}

/// A process and all under it.
pub(crate) fn tree(pid: u32) -> Vec<u32> {
    let mut all = vec![pid];
    let mut next = 0;
    while next < all.len() {
        let parent = all[next].to_string();
        next += 1;
        let Ok(found) = std::process::Command::new("/usr/bin/pgrep").args(["-P", &parent]).output() else { continue };
        all.extend(String::from_utf8_lossy(&found.stdout).lines().filter_map(|l| l.trim().parse::<u32>().ok()));
    }
    all
}

pub(crate) fn signal(pid: u32, which: &str) -> bool {
    std::process::Command::new("/bin/kill")
        .args([which, &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// How often a run's files are read.
pub const POLL: Duration = Duration::from_millis(250);

/// A terminal's output as text: escape sequences (colours, cursor moves, titles) dropped, CRLF and a lone CR as a
/// newline. `carry` keeps what a read cut off mid-sequence (an escape, a UTF-8 character) for the next.
pub fn plain(carry: &mut Vec<u8>, bytes: &[u8]) -> String {
    let mut input = std::mem::take(carry);
    input.extend_from_slice(bytes);
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        match input[i] {
            0x1b => {
                let Some(&next) = input.get(i + 1) else { break };
                let end = match next {
                    // CSI: parameters, then a final byte.
                    b'[' => input[i + 2..].iter().position(|b| (0x40..=0x7e).contains(b)).map(|at| i + 2 + at + 1),
                    // OSC: to BEL, or ESC \.
                    b']' => (i + 2..input.len())
                        .find(|&j| input[j] == 0x07 || (input[j] == 0x1b && input.get(j + 1) == Some(&b'\\')))
                        .map(|j| if input[j] == 0x07 { j + 1 } else { j + 2 }),
                    // A character set (ESC ( B) takes one more byte; anything else is the escape and its letter.
                    b'(' | b')' => (i + 2 < input.len()).then_some(i + 3),
                    _ => Some(i + 2),
                };
                match end {
                    Some(end) => i = end,
                    None => break,
                }
                continue;
            }
            b'\r' => {
                if input.get(i + 1) == Some(&b'\n') {
                    i += 1;
                    continue;
                }
                if i + 1 == input.len() {
                    break;
                }
                out.push(b'\n');
            }
            b'\n' | b'\t' => out.push(input[i]),
            byte if byte < 0x20 || byte == 0x7f => {}
            byte => out.push(byte),
        }
        i += 1;
    }
    carry.extend_from_slice(&input[i..]);
    // A character cut off at the end waits for the rest of it.
    let whole = match std::str::from_utf8(&out) {
        Ok(_) => out.len(),
        Err(error) if error.error_len().is_none() => error.valid_up_to(),
        Err(_) => out.len(),
    };
    let mut rest = out.split_off(whole);
    rest.extend_from_slice(carry);
    *carry = rest;
    String::from_utf8_lossy(&out).into_owned()
}
