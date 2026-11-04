//! The runtime's process: attached and read, watched for a turn that's stopped making progress, stopped, ended;
//! and the lines and requests sent to it.

use super::*;

unsafe extern "C" {
    safe fn kill(pid: i32, signal: i32) -> i32;
}

impl Session {
    /// Ends the runtime's process; the session stays, offline, to be resumed.
    pub fn stop(&self) {
        let generation = {
            let mut inner = self.lock();
            match inner.child.as_mut() {
                // Its output ends when it and everything it started (its process group) are gone, and that takes the
                // session offline.
                Some(child) => {
                    if let Some(pid) = child.id().and_then(|pid| i32::try_from(pid).ok()) { kill(-pid, SIGKILL); }
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
        let Transport { reader, mut writer, child } = transport;
        let (out, mut lines_out) = mpsc::unbounded_channel::<Value>();
        let generation = {
            let mut inner = self.lock();
            inner.generation += 1;
            inner.out = Some(out);
            inner.child = child;
            inner.answered.clear();
            inner.heard = Instant::now();
            inner.generation
        };
        let watched = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(WATCH_EVERY).await;
                if !watched.watch(generation) { break }
            }
        });
        tokio::spawn(async move {
            while let Some(message) = lines_out.recv().await {
                let mut line = serde_json::to_vec(&message).unwrap_or_default();
                line.push(b'\n');
                if writer.write_all(&line).await.is_err() || writer.flush().await.is_err() { break }
            }
        });
        let session = self.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                // Anything that isn't JSON (a shell's greeting before the runtime starts) is not the runtime speaking.
                if let Ok(message) = serde_json::from_str::<Value>(&line) { session.receive(message) }
            }
            session.ended(generation);
        });
    }

    fn receive(&self, message: Value) {
        let mut inner = self.lock();
        let at = now_ms();
        inner.record(json!({"in": message, "at": at}));
        inner.core().at(at);
        inner.heard = Instant::now();
        let effects = inner.core().receive(&message);
        for change in &effects.changes {
            if let Change::Item { item } = change {
                if item.status == ItemStatus::Running && matches!(item.kind, ItemKind::Command { .. }) { inner.running.entry(item.id.clone()).or_insert_with(Instant::now); }
                else { inner.running.remove(&item.id); }
            }
        }
        for change in &effects.changes {
            if let Change::Resolved { approval: id } | Change::Answered { question: id } = change { inner.answered.remove(id); }
        }
        let asked: Vec<_> = effects.changes.iter().filter_map(|c| match c { Change::Approval { approval } => Some(approval.clone()), _ => None }).collect();
        inner.broadcast(effects.changes);
        if inner.core().conversation().permissions == Permissions::Unrestricted {
            for approval in asked { inner.allow(&approval); }
        }
        if let Some((id, outcome)) = inner.core().answers(&message) && let Some(waiter) = inner.waiting.remove(&id) {
            let _ = waiter.send(outcome);
        }
        for reply in effects.replies { let _ = inner.send(reply); }
    }

    /// The runtime's output ended: its process is gone, and so is everything waiting on it.
    fn ended(&self, generation: u64) {
        let mut inner = self.lock();
        if inner.generation != generation { return }
        inner.out = None;
        inner.child = None;
        let provider = inner.core().conversation().provider.title();
        for (_, waiter) in inner.waiting.drain() { let _ = waiter.send(Err(format!("{provider} stopped"))); }
        inner.record(json!({"offline": true}));
        let changes = inner.core().offline();
        inner.broadcast(changes);
    }

    /// Looks for a working session that has stopped making progress, and marks or clears it. False once the
    /// process it watched is gone.
    fn watch(&self, generation: u64) -> bool {
        let mut inner = self.lock();
        if inner.generation != generation || inner.out.is_none() { return false }
        let Some(core) = inner.core.as_ref() else { return true };
        let conversation = core.conversation();
        let reason = if conversation.status != crate::model::Status::Working { None } else {
            let longest = inner.running.iter().filter_map(|(id, started)| {
                let elapsed = started.elapsed();
                let command = match conversation.item(id).map(|i| &i.kind) { Some(ItemKind::Command { command, .. }) => command.clone(), _ => return None };
                (elapsed >= LONG_COMMAND).then(|| format!("{command} has been running for {} minutes", elapsed.as_secs() / 60))
            }).next();
            // The same command again and again with nothing else between: counted in full, so the number grows as it goes
            // on. Another step between (a different tool, a file changed) is work, not a loop.
            let steps = conversation.items.iter().rev().take_while(|i| i.turn == conversation.turn || conversation.turn.is_none())
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
            let silent = (inner.heard.elapsed() >= SILENT).then(|| format!("No word from {} for {} minutes", conversation.provider.title(), SILENT.as_secs() / 60));
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

/// How long a request waits for its answer. Turns run long, but the requests that wait answer at once.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(60);

/// When a working session counts as stuck: no word from its agent, one command running, or the same command in a row.
/// ponytail: fixed; a setting per project if a suite legitimately runs longer.
const SILENT: Duration = Duration::from_secs(10 * 60);

const LONG_COMMAND: Duration = Duration::from_secs(30 * 60);

const REPEATS: usize = 5;

const WATCH_EVERY: Duration = Duration::from_secs(15);

/// The two ends of a runtime's stdio, and its process when there is one.
pub struct Transport {
    reader: Box<dyn AsyncRead + Send + Unpin>,
    writer: Box<dyn AsyncWrite + Send + Unpin>,
    child: Option<Child>,
}

impl Transport {
    pub fn new(reader: impl AsyncRead + Send + Unpin + 'static, writer: impl AsyncWrite + Send + Unpin + 'static) -> Self {
        Transport { reader: Box::new(reader), writer: Box::new(writer), child: None }
    }

    pub fn with_child(mut self, child: Child) -> Self {
        self.child = Some(child);
        self
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
