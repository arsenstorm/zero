//! The runtime's process: attached and read, watched for a turn that's stopped making progress, stopped, ended;
//! and the lines and requests sent to it.

use super::*;

unsafe extern "C" {
    safe fn kill(pid: i32, signal: i32) -> i32;
    safe fn dup(fd: i32) -> i32;
    safe fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
}

/// A runtime's process as one zerod hands it to the next across a restart (handoff.json): its pid, its pipes as file
/// descriptors that stay open through exec, and what the old zerod had read of its output but not yet taken in.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
pub struct Handoff {
    pub session: String,
    pub pid: i32,
    pub stdin: i32,
    pub stdout: i32,
    #[serde(default)]
    pub leftover: Vec<u8>,
}

impl Session {
    /// Ends the runtime's process; the session stays, offline, to be resumed.
    pub fn stop(&self) {
        let generation = {
            let mut inner = self.lock();
            // Taken over from the zerod before: no handle on it, its group by pid.
            if inner.child.is_none()
                && inner.out.is_some()
                && let Some(pid) = inner.pid
            {
                kill(-pid, SIGKILL);
                return;
            }
            match inner.child.as_mut() {
                // Its output ends when it and everything it started (its process group) are gone, and that takes the
                // session offline.
                Some(child) => {
                    if let Some(pid) = child.id().and_then(|pid| i32::try_from(pid).ok()) {
                        kill(-pid, SIGKILL);
                    }
                    let _ = child.start_kill();
                    return;
                }
                None => inner.generation,
            }
        };
        // Without a process of its own there is nothing to wait for.
        self.ended(generation);
    }

    /// Connects a runtime's stdio to the session and starts reading it.
    pub fn attach(&self, transport: Transport) {
        let Transport { mut reader, mut writer, child, pid, fds, leftover } = transport;
        let (out, mut lines_out) = mpsc::unbounded_channel::<Value>();
        let (stop, mut stopped) = oneshot::channel::<oneshot::Sender<Vec<u8>>>();
        let writing = tokio::spawn(async move {
            while let Some(message) = lines_out.recv().await {
                let mut line = serde_json::to_vec(&message).unwrap_or_default();
                line.push(b'\n');
                if writer.write_all(&line).await.is_err() || writer.flush().await.is_err() {
                    break;
                }
            }
        });
        let generation = {
            let mut inner = self.lock();
            inner.generation += 1;
            inner.out = Some(out);
            inner.child = child;
            inner.pid = pid;
            inner.fds = fds;
            inner.stop_reading = Some(stop);
            inner.writing = Some(writing);
            inner.answered.clear();
            inner.heard = Instant::now();
            inner.generation
        };
        let watched = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(WATCH_EVERY).await;
                if !watched.watch(generation) {
                    break;
                }
            }
        });
        let session = self.clone();
        tokio::spawn(async move {
            // Its own lines, not a buffered reader's: stopped for a restart, what's read and not yet a whole line goes
            // to the next zerod (hand_off), so nothing the runtime said is lost between the two.
            let (mut pending, mut chunk) = (leftover, vec![0u8; 64 * 1024]);
            loop {
                while let Some(end) = pending.iter().position(|b| *b == b'\n') {
                    let line: Vec<u8> = pending.drain(..=end).collect();
                    // Anything that isn't JSON (a shell's greeting before the runtime starts) is not the runtime speaking.
                    if let Ok(message) = serde_json::from_slice::<Value>(&line) {
                        session.receive(message)
                    }
                }
                tokio::select! {
                    read = reader.read(&mut chunk) => match read {
                        Ok(0) | Err(_) => break,
                        Ok(n) => pending.extend_from_slice(&chunk[..n]),
                    },
                    Ok(give) = &mut stopped => { let _ = give.send(pending); return }
                }
            }
            session.ended(generation);
        });
    }

    /// For zerod's restart: stops reading and writing the runtime's process, leaving it running, and gives it over:
    /// its pipes duplicated to outlive this zerod's exec, and what was read but not yet taken in. None when the session
    /// has no process of its own to give (offline, or a runtime that isn't a process).
    pub async fn hand_off(&self) -> Option<Handoff> {
        let (stop, writing, pid, (stdin, stdout), session) = {
            let mut inner = self.lock();
            let (Some(pid), Some((stdin, stdout)), true) = (inner.pid, inner.fds, inner.out.is_some()) else { return None };
            // Duplicated first: the writer and reader close their own as they finish.
            let fds = (dup(stdin), dup(stdout));
            if fds.0 < 0 || fds.1 < 0 {
                return None;
            }
            // Nothing more goes to it from here, and the end of this attach is no longer its end.
            inner.out = None;
            inner.generation += 1;
            (inner.stop_reading.take()?, inner.writing.take(), pid, fds, inner.core().conversation().id.clone())
        };
        // What was on its way to it goes first: the channel closed, the writer finishes the lines in it.
        if let Some(writing) = writing {
            let _ = writing.await;
        }
        let (give, given) = oneshot::channel();
        stop.send(give).ok()?;
        let leftover = given.await.ok()?;
        Some(Handoff { session, pid, stdin, stdout, leftover })
    }

    fn receive(&self, message: Value) {
        let mut inner = self.lock();
        let at = now_ms();
        // Not each piece of streamed words: the finished message that follows has them all, and pieces were four in
        // ten lines of a long task's transcript (written one by one, under the lock). Replayed, the words are there.
        let piece = message["type"] == "stream_event" && message["event"]["type"] == "content_block_delta";
        // Nor Claude's init (15 KB) when it says what the last one recorded did: it comes on every start, each with a
        // fresh uuid and socket. Replay needs only the latest, and that's the same.
        let repeated = message["type"] == "system" && message["subtype"] == "init" && {
            let mut said = message.clone();
            if let Some(fields) = said.as_object_mut() {
                fields.remove("uuid");
                fields.remove("messaging_socket_path");
            }
            let mut hasher = std::hash::DefaultHasher::new();
            std::hash::Hash::hash(&said.to_string(), &mut hasher);
            let said = std::hash::Hasher::finish(&hasher);
            inner.init == Some(said) || {
                inner.init = Some(said);
                false
            }
        };
        if !piece && !repeated {
            inner.record(json!({"in": message, "at": at}));
        }
        inner.core().at(at);
        inner.heard = Instant::now();
        let effects = inner.core().receive(&message);
        for change in &effects.changes {
            if let Change::Item { item } = change {
                if item.status == ItemStatus::Running && matches!(item.kind, ItemKind::Command { .. }) {
                    inner.running.entry(item.id.clone()).or_insert_with(Instant::now);
                } else {
                    inner.running.remove(&item.id);
                }
            }
        }
        for change in &effects.changes {
            if let Change::Resolved { approval: id } | Change::Answered { question: id } = change {
                inner.answered.remove(id);
            }
        }
        let asked: Vec<_> = effects
            .changes
            .iter()
            .filter_map(|c| match c {
                Change::Approval { approval } => Some(approval.clone()),
                _ => None,
            })
            .collect();
        inner.broadcast(effects.changes);
        if inner.core().conversation().permissions == Permissions::Unrestricted {
            for approval in asked {
                inner.allow(&approval);
            }
        }
        if let Some((id, outcome)) = inner.core().answers(&message)
            && let Some(waiter) = inner.waiting.remove(&id)
        {
            let _ = waiter.send(outcome);
        }
        for reply in effects.replies {
            let _ = inner.send(reply);
        }
    }

    /// The runtime's output ended: its process is gone, and so is everything waiting on it.
    fn ended(&self, generation: u64) {
        let mut inner = self.lock();
        if inner.generation != generation {
            return;
        }
        inner.out = None;
        // Taken over from the zerod before, it's this zerod's child with no handle to reap it by: reaped by pid.
        if inner.child.is_none()
            && let Some(pid) = inner.pid.take()
        {
            tokio::spawn(async move {
                for _ in 0..120 {
                    if waitpid(pid, std::ptr::null_mut(), WNOHANG) != 0 {
                        return;
                    }
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            });
        }
        inner.pid = None;
        inner.fds = None;
        inner.child = None;
        let provider = inner.core().conversation().provider.title();
        for (_, waiter) in inner.waiting.drain() {
            let _ = waiter.send(Err(format!("{provider} stopped")));
        }
        inner.record(json!({"offline": true}));
        let changes = inner.core().offline();
        inner.broadcast(changes);
    }

    /// Looks for a working session that has stopped making progress, and marks or clears it. False once the
    /// process it watched is gone.
    fn watch(&self, generation: u64) -> bool {
        let mut inner = self.lock();
        if inner.generation != generation || inner.out.is_none() {
            return false;
        }
        let Some(core) = inner.core.as_ref() else { return true };
        let conversation = core.conversation();
        let reason = if conversation.status != crate::model::Status::Working {
            None
        } else {
            let longest = inner
                .running
                .iter()
                .filter_map(|(id, started)| {
                    let elapsed = started.elapsed();
                    let command = match conversation.item(id).map(|i| &i.kind) {
                        Some(ItemKind::Command { command, .. }) => command.clone(),
                        _ => return None,
                    };
                    (elapsed >= LONG_COMMAND).then(|| format!("{command} has been running for {} minutes", elapsed.as_secs() / 60))
                })
                .next();
            // The same command again and again with nothing else between: counted in full, so the number grows as it goes
            // on. Another step between (a different tool, a file changed) is work, not a loop.
            let steps = conversation
                .items
                .iter()
                .rev()
                .take_while(|i| i.turn == conversation.turn || conversation.turn.is_none())
                .filter(|i| !matches!(i.kind, ItemKind::Reasoning { .. } | ItemKind::Agent { .. }));
            let mut run: Option<(&str, usize)> = None;
            for step in steps {
                match (&step.kind, run) {
                    (ItemKind::Command { command, .. }, None) => run = Some((command, 1)),
                    (ItemKind::Command { command, .. }, Some((same, n))) if command == same => run = Some((same, n + 1)),
                    _ => break,
                }
            }
            let repeated = run.filter(|(_, n)| *n >= REPEATS).map(|(command, n)| format!("Ran {command} {n} times in a row"));
            let silent = (inner.heard.elapsed() >= SILENT)
                .then(|| format!("No word from {} for {} minutes", conversation.provider.title(), SILENT.as_secs() / 60));
            longest.or(repeated).or(silent)
        };
        if reason != conversation.stalled {
            let change = inner.core().change(Change::Stalled { reason });
            inner.broadcast(vec![change]);
        }
        true
    }

    // What the providers' flows use to talk to their runtime.

    /// Writes a line that nothing waits on an answer to.
    pub(crate) fn write(&self, message: Value) -> Result<(), String> {
        self.lock().send(message)
    }

    /// Sends a request with a fresh id, and waits for its answer.
    pub(crate) async fn request(&self, build: impl FnOnce(&str) -> Value) -> Result<Value, String> {
        let (answer, provider) = {
            let mut inner = self.lock();
            let id = inner.fresh_id();
            let (tell, answer) = oneshot::channel();
            inner.waiting.insert(id.clone(), tell);
            if let Err(error) = inner.send(build(&id)) {
                inner.waiting.remove(&id);
                return Err(error);
            }
            (answer, inner.core().conversation().provider.title())
        };
        match tokio::time::timeout(ANSWER_TIMEOUT, answer).await {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(_)) => Err(format!("{provider} stopped")),
            Err(_) => Err(format!("{provider} didn't answer")),
        }
    }

    /// Sends a request with a fresh id whose answer the adapter handles when it comes (an ACP prompt, which answers
    /// only when its turn ends).
    pub(crate) fn request_later(&self, build: impl FnOnce(&str) -> Value) -> Result<(), String> {
        let mut inner = self.lock();
        let id = inner.fresh_id();
        inner.send(build(&id))
    }
}

const SIGKILL: i32 = 9;
const WNOHANG: i32 = 1;

/// How long a request waits for its answer. Turns run long, but the requests that wait answer at once.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(60);

/// When a working session counts as stuck: no word from its agent, one command running, or the same command in a row.
/// ponytail: fixed; a setting per project if a suite legitimately runs longer.
const SILENT: Duration = Duration::from_secs(10 * 60);

const LONG_COMMAND: Duration = Duration::from_secs(30 * 60);

const REPEATS: usize = 5;

const WATCH_EVERY: Duration = Duration::from_secs(15);

/// The two ends of a runtime's stdio, and its process when there is one: its handle, or (taken over from the zerod
/// before) its pid; with the pipes' descriptors, so it can be handed to the next zerod in turn.
pub struct Transport {
    reader: Box<dyn AsyncRead + Send + Unpin>,
    writer: Box<dyn AsyncWrite + Send + Unpin>,
    child: Option<Child>,
    pid: Option<i32>,
    fds: Option<(i32, i32)>,
    leftover: Vec<u8>,
}

impl Transport {
    pub fn new(reader: impl AsyncRead + Send + Unpin + 'static, writer: impl AsyncWrite + Send + Unpin + 'static) -> Self {
        Transport { reader: Box::new(reader), writer: Box::new(writer), child: None, pid: None, fds: None, leftover: vec![] }
    }

    pub fn with_child(mut self, child: Child) -> Self {
        self.pid = child.id().and_then(|pid| i32::try_from(pid).ok());
        self.child = Some(child);
        self
    }

    /// The descriptors of its stdin and stdout, which a restart hands over.
    pub fn with_pipes(mut self, stdin: i32, stdout: i32) -> Self {
        self.fds = Some((stdin, stdout));
        self
    }

    /// The process the zerod before handed over: its pipes from their descriptors, what it had read first.
    pub fn adopt(handoff: Handoff) -> std::io::Result<Transport> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use tokio::net::unix::pipe;
        // Safety: the descriptors were duplicated for this process by the one before it, and nothing else owns them.
        let writer = pipe::Sender::from_owned_fd(unsafe { OwnedFd::from_raw_fd(handoff.stdin) })?;
        let reader = pipe::Receiver::from_owned_fd(unsafe { OwnedFd::from_raw_fd(handoff.stdout) })?;
        let fds = (writer.as_raw_fd(), reader.as_raw_fd());
        Ok(Transport {
            reader: Box::new(reader),
            writer: Box::new(writer),
            child: None,
            pid: Some(handoff.pid),
            fds: Some(fds),
            leftover: handoff.leftover,
        })
    }
}

impl Inner {
    fn fresh_id(&mut self) -> String {
        let id = format!("z{}", self.next);
        self.next += 1;
        id
    }

    /// Every line to the runtime goes through the adapter first, which may change the conversation (Claude's and
    /// ACP's prompts start turns; their answers settle approvals).
    pub(super) fn send(&mut self, message: Value) -> Result<(), String> {
        let out = self.out.clone().ok_or_else(|| format!("{} isn't running", self.core().conversation().provider.title()))?;
        let at = now_ms();
        self.record(json!({"out": message, "at": at}));
        self.core().at(at);
        let changes = self.core().sent(&message);
        self.broadcast(changes);
        out.send(message).map_err(|_| "The runtime isn't running".to_string())
    }
}
