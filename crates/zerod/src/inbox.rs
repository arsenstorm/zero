//! The inbox: every ask from every agent, with its state machine:
//! waiting → pending (the take-back window) → answered | declined, or → running → answered for a run;
//! waiting → expired on timeout or when withdrawn. Every change is appended to the log the Swift app kept
//! (~/.zero/asks.jsonl), and the latest line per id wins when it is read back. Agents that asked with --async get
//! their answer typed into their session through the runtime that hosts them (`Runtime`).

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;

use tokio::sync::broadcast;
use tokio::task::JoinHandle;

use crate::ask::{AgentIdentity, Ask, AskKind, AskState, Delivery, Time};

pub type Fut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Somewhere agents run that the inbox can reach: Zero's own terminals, zerod's sessions. Only what an
/// inbox needs: type into the agent's session, read what it replied, tell whether it still runs, stop it.
pub trait Runtime: Send + Sync {
    fn name(&self) -> &str;
    fn can_reach(&self, agent: &AgentIdentity) -> bool;
    fn send<'a>(&'a self, text: &'a str, agent: &'a AgentIdentity) -> Fut<'a, Result<(), String>>;
    /// The identity to deliver to now: the agent's session running, started again if it isn't.
    fn connect<'a>(&'a self, agent: &'a AgentIdentity) -> Fut<'a, Result<AgentIdentity, String>> {
        Box::pin(async move { Ok(agent.clone()) })
    }
    /// What the agent said back to `text`, once its turn is over.
    fn reply<'a>(&'a self, _: &'a AgentIdentity, _: &'a str) -> Fut<'a, Option<String>> {
        Box::pin(async { None })
    }
    /// What the runtime calls the agent now (its session's title).
    fn display_name<'a>(&'a self, _: &'a AgentIdentity) -> Fut<'a, Option<String>> {
        Box::pin(async { None })
    }
    /// The session whose first prompt was `prompt`, for an agent from before sessions were recorded.
    fn find_session<'a>(&'a self, _: &'a AgentIdentity, _: &'a str) -> Fut<'a, Option<String>> {
        Box::pin(async { None })
    }
    fn screen<'a>(&'a self, _: &'a AgentIdentity) -> Fut<'a, Option<String>> {
        Box::pin(async { None })
    }
    /// Keys into the agent's terminal; the screen just after.
    fn press<'a>(&'a self, _: &'a [u8], _: &'a AgentIdentity) -> Fut<'a, Result<Option<String>, String>> {
        Box::pin(async { Ok(None) })
    }
    /// Changes a running agent's model and effort, where its runtime has a way.
    fn switch_model<'a>(&'a self, agent: &'a AgentIdentity, _: Option<&'a str>, _: Option<&'a str>) -> Fut<'a, Result<(), String>> {
        Box::pin(async move { Err(format!("{} can't change {}'s model", self.name(), agent.name)) })
    }
    /// Of `agents`, the names whose session isn't running.
    fn offline<'a>(&'a self, _: &'a [AgentIdentity]) -> Fut<'a, HashSet<String>> {
        Box::pin(async { HashSet::new() })
    }
    /// Of `agents`, the names whose process is gone from the runtime altogether.
    fn gone<'a>(&'a self, _: &'a [AgentIdentity]) -> Fut<'a, HashSet<String>> {
        Box::pin(async { HashSet::new() })
    }
    fn stop<'a>(&'a self, _: &'a AgentIdentity) -> Fut<'a, ()> {
        Box::pin(async {})
    }
}

#[derive(Clone, Debug)]
pub enum InboxEvent {
    /// An ask was made or changed: its whole state now.
    Ask(Box<Ask>),
    /// More of a run's output.
    Output { id: String, chunk: String },
    /// Dismissed from the inbox, or out of its window.
    Removed(String),
    /// Many out of its window at once (`TRIMMED_AT_ONCE` or more): the asks again, rather than one event each, each a
    /// redraw in every app.
    Trimmed,
    /// Which agents' sessions aren't running, and which Zero can type into, when either changes.
    Agents { offline: Vec<String>, reachable: Vec<String> },
}

/// How many asks leaving the window at once are sent as the asks again instead (`InboxEvent::Trimmed`).
pub const TRIMMED_AT_ONCE: usize = 10;

/// What's kept of a run's output: the end, since that's where results and errors are.
const OUTPUT_KEPT: usize = 256 * 1024;

struct State {
    asks: Vec<Ask>,
    timers: HashMap<String, JoinHandle<()>>,
    offline: HashSet<String>,
    /// What Zero typed into each agent lately, so a prompt it caused isn't taken for the user typing.
    sent: HashMap<String, Vec<(String, Time)>>,
    reported: HashMap<String, String>,
    /// The last `Agents` event, to send the next only when it differs.
    agents: (Vec<String>, Vec<String>),
    ticks: u64,
    take_back: Duration,
    default_ttl: i64,
    /// The user's words to a task while one of its asks was open, by that ask: what the agent answers them is the ask's.
    said_on: Vec<(String, String)>,
    /// `zero done`'s and `zero blocked`'s tokens, by "<status> <agent>": the second word that confirms one, good once, for DONE_WINDOW.
    done_tokens: HashMap<String, (String, std::time::Instant)>,
}

/// How long `zero done`'s token is good for.
const DONE_WINDOW: Duration = Duration::from_secs(5 * 60);

pub struct Inbox {
    state: Mutex<State>,
    events: broadcast::Sender<InboxEvent>,
    log: Option<PathBuf>,
    runtimes: Vec<Arc<dyn Runtime>>,
    /// Where the user's commands run, out of zerod's reach (runs.rs).
    runs: Arc<crate::runs::Runs>,
    me: Weak<Inbox>,
    /// Which agents are workers (a task under a lead), as the daemon knows it: their done is their lead's to judge.
    workers: std::sync::OnceLock<WorkerTest>,
    /// A zerod task's conversation, for what its asks are about (about.rs).
    conversations: std::sync::OnceLock<Conversations>,
}

/// Whether an agent is a worker, given once by whoever holds the daemon (server.rs).
pub type WorkerTest = Box<dyn Fn(&AgentIdentity) -> bool + Send + Sync>;
/// A task's conversation by its session's id: its current turn's items, or with `all` every item. Given once (server.rs).
pub type Conversations = Box<dyn Fn(&str, bool) -> Option<Vec<crate::model::Item>> + Send + Sync>;

impl Inbox {
    pub fn open(log: Option<PathBuf>, runtimes: Vec<Arc<dyn Runtime>>) -> Arc<Inbox> {
        Self::open_with(log, runtimes, None)
    }

    /// As `open`, runs in zero-host's terminals where it keeps them (a real terminal the user can attach to); given
    /// here, so the runs under way it picks up are found where they run.
    pub fn open_with(log: Option<PathBuf>, runtimes: Vec<Arc<dyn Runtime>>, host: Option<crate::host::Host>) -> Arc<Inbox> {
        let (events, _) = broadcast::channel(4096);
        let inbox = Arc::new_cyclic(|me| Inbox {
            state: Mutex::new(State {
                asks: vec![],
                timers: HashMap::new(),
                offline: HashSet::new(),
                sent: HashMap::new(),
                reported: HashMap::new(),
                agents: Default::default(),
                ticks: 0,
                take_back: Duration::from_secs(2),
                default_ttl: 3600,
                done_tokens: HashMap::new(),
                said_on: vec![],
            }),
            runs: Arc::new(crate::runs::Runs::new(runs_dir(log.as_deref()), host)),
            events,
            log,
            runtimes,
            me: me.clone(),
            workers: std::sync::OnceLock::new(),
            conversations: std::sync::OnceLock::new(),
        });
        inbox.load();
        inbox
    }

    fn runs(&self) -> Arc<crate::runs::Runs> {
        self.runs.clone()
    }

    /// The take-back window, and how long an ask without its own expiry waits (seconds).
    pub fn configure(&self, take_back: Duration, default_ttl: i64) {
        let mut state = self.lock();
        state.take_back = take_back;
        state.default_ttl = default_ttl;
    }

    /// How to tell a worker, given once.
    pub fn know_workers(&self, test: WorkerTest) {
        let _ = self.workers.set(test);
    }

    /// How to read a task's conversation, given once.
    pub fn know_conversations(&self, read: Conversations) {
        let _ = self.conversations.set(read);
    }

    /// What an ask from a zerod task is about (about.rs): the heading or item it names, else its agent's words just
    /// before it. Err when what it names isn't there, for the agent to fix; `create` then takes the words before it.
    pub fn about(&self, ask: &mut Ask) -> Result<(), String> {
        let session = (ask.agent.runtime.as_deref() == Some("zerod")).then_some(ask.agent.reference.as_deref()).flatten();
        let (Some(session), Some(read), true) = (session, self.conversations.get(), crate::about::asks(ask)) else {
            ask.about = None;
            return Ok(());
        };
        // Already worked out (checked before it's made, then made).
        if ask.about.as_ref().is_some_and(|a| !a.item.is_empty()) {
            return Ok(());
        }
        let anchor = ask.about.take().and_then(|a| a.anchor).filter(|a| !a.trim().trim_start_matches('#').is_empty());
        let items = read(session, anchor.is_some()).unwrap_or_default();
        ask.about = match anchor {
            Some(anchor) => Some(crate::about::linked(&items, &anchor)?),
            None => crate::about::automatic(&items),
        };
        Ok(())
    }

    /// The user writing to a task may answer one of its open asks there, or write about something else and leave it
    /// open on purpose (a step they're still running): Zero can't tell which, so it withdraws none and tells the agent,
    /// under the user's words, what's still open, to withdraw what the words answered. The provider's own questions are
    /// its adapter's (declined as the words go). Sent, as they're sent; queued, as they're given from the queue (Daemon's
    /// note_with), the queue keeping the user's own words. With one ask open, the words are taken as about it: the
    /// agent's answer to them is kept with it (keep_reply).
    pub fn with_open_asks(&self, id: &str, text: String) -> String {
        let open: Vec<_> = self
            .asks()
            .into_iter()
            .filter(|a| {
                !a.state.is_final()
                    && a.request.is_none()
                    && !matches!(a.kind, AskKind::Note | AskKind::Message)
                    && a.agent.runtime.as_deref() == Some("zerod")
                    && a.agent.reference.as_deref() == Some(id)
            })
            .collect();
        if open.is_empty() {
            return text;
        }
        if let [ask] = open.as_slice() {
            let said = &mut self.lock().said_on;
            said.push((ask.id.clone(), text.trim().to_string()));
            let keep = said.len().saturating_sub(20);
            said.drain(..keep);
        }
        let which = open.iter().map(|a| format!("{} (\"{}\")", a.id, a.title)).collect::<Vec<_>>().join(", ");
        format!(
            "{text}\n\n{} {which}. If the user's words answer one, withdraw it with `zero withdraw <id>`; leave the rest for them.)",
            crate::daemon::OPEN_ASKS_MARK
        )
    }

    /// The agent's answer to the user's words on one of its asks, kept with that ask (about.rs reply), as a turn ends.
    pub fn keep_reply(&self, items: &[crate::model::Item]) {
        let said = self.lock().said_on.clone();
        let Some((id, reply)) = crate::about::reply(items, &self.asks(), &said) else { return };
        self.update(&id, |a| {
            a.replies.push(reply);
            true
        });
    }

    /// A worker (a task under a lead): its done goes to its lead with its report, never asked of the user.
    pub fn is_worker(&self, agent: &AgentIdentity) -> bool {
        self.workers.get().is_some_and(|test| test(agent))
    }

    pub fn subscribe(&self) -> broadcast::Receiver<InboxEvent> {
        self.events.subscribe()
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn asks(&self) -> Vec<Ask> {
        self.lock().asks.clone()
    }

    pub fn ask(&self, id: &str) -> Option<Ask> {
        self.lock().asks.iter().find(|a| a.id == id).cloned()
    }

    pub fn open_asks(&self) -> Vec<Ask> {
        self.lock().asks.iter().filter(|a| !a.state.is_final()).cloned().collect()
    }

    pub fn offline(&self) -> HashSet<String> {
        self.lock().offline.clone()
    }

    /// The latest identity known for an agent.
    pub fn identity(&self, name: &str) -> Option<AgentIdentity> {
        identity(&self.lock().asks, name)
    }

    /// `keep_id` keeps the caller's id (a drop client names its files by it) unless it is taken.
    pub fn create(&self, incoming: Ask, keep_id: bool) -> Ask {
        let mut ask = incoming.clone();
        if self.about(&mut ask).is_err() {
            ask.about = None;
            let _ = self.about(&mut ask);
        }
        let mut state = self.lock();
        // Done is confirmed through `done` alone (its token, or the user's word): never taken as a client sent it.
        ask.confirmed = false;
        ask.done_check = false;
        if !keep_id || incoming.id.is_empty() || state.asks.iter().any(|a| a.id == incoming.id) {
            ask.id = crate::ask::new_id()
        }
        // The options are the agent's guesses: the user can always answer in their own words instead.
        if ask.kind == AskKind::Choice && !ask.options.is_empty() && !ask.options.iter().any(|o| Ask::expects_text(o)) {
            ask.options.push("Something else…".into());
        }
        ask.state = AskState::Waiting;
        let requested = incoming.expires_at.0 - incoming.created_at.0;
        let ttl = if requested > 0 { requested } else { state.default_ttl };
        ask.created_at = Time::now();
        ask.expires_at = Time(ask.created_at.0 + ttl);
        if matches!(ask.kind, AskKind::Note | AskKind::Message) {
            ask.state = AskState::Answered;
            ask.answered_at = Some(ask.created_at);
        }
        // What's known about the agent carries into every later item, however little the caller said.
        ask.agent.name = resolve(&state.asks, &ask.agent);
        if let Some(known) = identity(&state.asks, &ask.agent.name) {
            let a = &mut ask.agent;
            a.session = a.session.clone().or(known.session);
            a.label = a.label.clone().or(known.label);
            a.account = a.account.clone().or(known.account);
            a.runtime = a.runtime.clone().or(known.runtime);
            a.reference = a.reference.clone().or(known.reference);
            a.launch = a.launch.clone().or(known.launch);
        }
        // Saying where it is again within ten minutes, nothing else between, rewrites the last note.
        if ask.kind == AskKind::Note
            && ask.status.is_none()
            && let Some(i) = state.asks.iter().rposition(|a| a.agent.name == ask.agent.name && a.kind != AskKind::Message)
            && state.asks[i].kind == AskKind::Note
            && state.asks[i].status.is_none()
            && ask.created_at.0 - state.asks[i].created_at.0 < 600
        {
            let last = &mut state.asks[i];
            last.body = ask.body;
            last.title = ask.title;
            last.needs = ask.needs;
            last.request = ask.request;
            last.created_at = ask.created_at;
            last.answered_at = Some(ask.created_at);
            let last = last.clone();
            drop(state);
            self.changed(&last);
            return last;
        }
        // A run of a kind the agent named: allowed for its task already, it runs now; otherwise the user may allow it.
        if ask.kind == AskKind::Run && ask.allow.is_some() && !of_its_kind(&ask) {
            ask.allow = None
        }
        if ask.kind == AskKind::Run && ask.allow.is_some() {
            if allowed(&state.asks, &ask) {
                ask.state = AskState::Pending;
                ask.answer = Some("Run (allowed for this task)".into());
                ask.choice = Some(0);
                state.asks.push(ask.clone());
                drop(state);
                self.changed(&ask);
                self.run(ask.clone());
                return ask;
            }
            ask.options.insert(1, ALLOW_FOR_TASK.into());
        }
        // A run another agent already asks for, unanswered: one card, one run, both told the outcome.
        if ask.kind == AskKind::Run
            && let Some(original) = state.asks.iter().rev().find(|a| {
                a.kind == AskKind::Run
                    && a.state == AskState::Waiting
                    && a.same_as.is_none()
                    && a.command == ask.command
                    && a.cwd == ask.cwd
                    && ask.created_at.0 - a.created_at.0 < 600
            })
        {
            ask.same_as = Some(original.id.clone());
        }
        state.asks.push(ask.clone());
        let expires = !matches!(ask.kind, AskKind::Note | AskKind::Message);
        drop(state);
        self.changed(&ask);
        if expires {
            self.schedule_expiry(&ask.id, ttl)
        }
        ask
    }

    fn schedule_expiry(&self, id: &str, seconds: i64) {
        let (me, key) = (self.me.clone(), format!("expire-{id}"));
        let id = id.to_string();
        let timer = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(seconds.max(0) as u64)).await;
            if let Some(inbox) = me.upgrade() {
                inbox.expire(&id)
            }
        });
        if let Some(old) = self.lock().timers.insert(key, timer) {
            old.abort()
        }
    }

    /// Picks option `index`.
    pub fn choose(&self, id: &str, index: usize) {
        let Some(ask) = self.ask(id).filter(|a| a.state == AskState::Waiting && index < a.options.len()) else { return };
        self.stage(id, ask.options[index].clone(), declines(&ask, index), Some(index));
    }

    /// Picks a text option with its text: the answer reads "label: text", or the label alone when empty.
    pub fn answer(&self, id: &str, index: usize, text: &str) {
        let Some(ask) = self.ask(id).filter(|a| a.state == AskState::Waiting && index < a.options.len()) else { return };
        let label = ask.options[index].trim_end_matches(['…', '.', ' ']).to_string();
        let text = text.trim();
        let answer = if text.is_empty() { label } else { format!("{label}: {text}") };
        self.stage(id, answer, declines(&ask, index), Some(index));
    }

    /// A typed reply; on a run, only a reason to decline it.
    pub fn reply(&self, id: &str, text: &str) {
        let Some(ask) = self.ask(id).filter(|a| a.state == AskState::Waiting) else { return };
        self.stage(id, text.into(), ask.kind == AskKind::Run, None);
    }

    pub fn take_back(&self, id: &str) -> bool {
        let mut state = self.lock();
        let Some(ask) = state.asks.iter_mut().find(|a| a.id == id && a.state == AskState::Pending) else { return false };
        ask.state = AskState::Waiting;
        ask.answer = None;
        ask.choice = None;
        let ask = ask.clone();
        if let Some(timer) = state.timers.remove(id) {
            timer.abort()
        }
        drop(state);
        self.changed(&ask);
        true
    }

    pub fn dismiss(&self, id: &str) {
        let mut state = self.lock();
        let before = state.asks.len();
        state.asks.retain(|a| a.id != id || !a.state.is_final());
        if state.asks.len() != before {
            let _ = self.events.send(InboxEvent::Removed(id.into()));
        }
    }

    pub fn cancel_run(&self, id: &str) {
        let Some(handle) = self.ask(id).and_then(|a| a.run) else { return };
        let runs = self.runs();
        tokio::spawn(async move { runs.stop(&handle).await });
    }

    /// Takes back an open ask: the agent withdrew it, or the user answered it some other way. Nobody is told.
    /// `zero done`: an agent's word that its task is done, taken in two. Without a token it isn't done yet: the agent
    /// is told what done means and given a token; with that token (once, within DONE_WINDOW) the task is done,
    /// confirmed. A bare "done" cost an agent nothing to say, and it said it when a piece felt finished (committed, not
    /// shipped), putting the task away.
    pub fn done(&self, agent: &AgentIdentity, said: &str, token: Option<&str>) -> Result<(), String> {
        // Done in two, and the user asked when unsure, is a lead's word to the user. A worker's goes to its lead with its
        // report, which judges it: taken at its word.
        if self.is_worker(agent) {
            self.confirm(agent, said, "done");
            return Ok(());
        }
        let quoted = said.replace('"', "'");
        self.second_word(agent, said, token, "done", || {
            format!(
                "Not marked done yet. Done means one of these, not a piece that feels finished:\n\
            - the user said the task is done;\n\
            - the work is finished end to end: merged, deployed and checked, its ticket closed, nothing left that \
            anyone has to do for it. Committed, pushed, or sent for review is not done.\n\
            If one of those is so, confirm within 5 minutes: zero done \"{quoted}\" --confirm {{token}}\n\
            Unsure? Ask the user instead: zero done \"{quoted}\" --ask"
            )
        })
    }

    /// `zero blocked`: an agent's word that its task can't go on at all, taken in two as done is: red on the board,
    /// so it's kept for what's big. Waiting on a review or CI is Waiting; what the user can give is an ask.
    pub fn blocked(&self, agent: &AgentIdentity, said: &str, token: Option<&str>) -> Result<(), String> {
        let quoted = said.replace('"', "'");
        self.second_word(agent, said, token, "blocked", || {
            format!(
                "Not marked blocked yet. Blocked means the task can't go on at all, on any \
            part of it, until something outside you and the user changes: an outage, access only another team can \
            grant, a dependency broken upstream. A worker is blocked too when it can't go on without a decision only its \
            lead or the user can make (its lead takes it to them). It shows red, so keep it for that.\n\
            - Waiting on a review, CI, a deploy or QA is waiting: zero note \"…\" --waiting.\n\
            - Something the user can give (an answer, access, a decision) is an ask: zero ask.\n\
            If it is blocked, confirm within 5 minutes: zero blocked \"{quoted}\" --confirm {{token}}"
            )
        })
    }

    /// Done or blocked, confirmed with the token the first call gave: a note with that status the board believes.
    fn second_word(
        &self, agent: &AgentIdentity, said: &str, token: Option<&str>, status: &str, meaning: impl Fn() -> String,
    ) -> Result<(), String> {
        let key = format!("{status} {}", agent.name);
        let mut state = self.lock();
        let Some(token) = token else {
            let token = crate::ask::new_id();
            state.done_tokens.insert(key, (token.clone(), std::time::Instant::now()));
            return Err(meaning().replace("{token}", &token));
        };
        let good = state.done_tokens.get(&key).is_some_and(|(kept, at)| kept == token && at.elapsed() < DONE_WINDOW);
        if !good {
            return Err(format!("That token isn't good (wrong, used, or older than 5 minutes): run zero {status} again."));
        }
        state.done_tokens.remove(&key);
        drop(state);
        self.confirm(agent, said, status);
        Ok(())
    }

    /// `zero done --ask`: the user asked whether the task is done; their Done confirms it (finish).
    pub fn ask_done(&self, agent: &AgentIdentity, said: &str) -> Ask {
        let ttl = self.lock().default_ttl;
        let mut question = Ask::new(AskKind::Choice, "Is this task done?", agent.clone(), ttl);
        question.body = said.to_string();
        question.options = vec!["Done".into(), "Not yet…".into()];
        question.waits = Some(false);
        let created = self.create(question, false);
        self.update(&created.id, |a| {
            a.done_check = true;
            true
        });
        self.ask(&created.id).unwrap_or(created)
    }

    /// The user's own word on where a task stands (done, waiting, blocked): taken as its agent's confirmed note.
    pub fn mark(&self, agent: &AgentIdentity, status: &str) {
        self.confirm(agent, &format!("You marked it {status}"), status)
    }

    /// The task done or blocked, confirmed: a note the board takes as said.
    fn confirm(&self, agent: &AgentIdentity, said: &str, status: &str) {
        let mut note = Ask::new(AskKind::Note, "Update", agent.clone(), 0);
        note.body = said.to_string();
        note.status = Some(status.into());
        let created = self.create(note, false);
        self.update(&created.id, |a| {
            a.confirmed = true;
            true
        });
    }

    pub fn withdraw(&self, id: &str, reason: Option<&str>) {
        // A command under way stops with it: nothing else would stop it, and with its ask closed the user had no way to.
        let running = self.ask(id).filter(|a| a.state == AskState::Running).and_then(|a| a.run);
        let updated = self.update(id, |a| {
            if a.state.is_final() {
                return false;
            }
            a.status = Some("withdrawn".into());
            a.answer = reason.map(String::from);
            a.choice = None;
            true
        });
        if updated {
            if let Some(timer) = self.lock().timers.remove(id) {
                timer.abort()
            }
            if let Some(handle) = running {
                self.append_output(id, "\n(Stopped: the agent withdrew it.)\n");
                let runs = self.runs();
                tokio::spawn(async move { runs.stop(&handle).await });
            }
            self.finish(id, AskState::Expired, None);
        }
    }

    fn stage(&self, id: &str, answer: String, declined: bool, choice: Option<usize>) {
        self.update(id, |a| {
            a.state = AskState::Pending;
            a.answer = Some(answer);
            a.choice = choice;
            true
        });
        let (me, key, delay) = (self.me.clone(), id.to_string(), self.lock().take_back);
        let id = id.to_string();
        let timer = tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            if let Some(inbox) = me.upgrade() {
                inbox.commit(&id, declined)
            }
        });
        if let Some(old) = self.lock().timers.insert(key, timer) {
            old.abort()
        }
    }

    fn commit(&self, id: &str, declined: bool) {
        self.lock().timers.remove(id);
        let Some(ask) = self.ask(id).filter(|a| a.state == AskState::Pending) else { return };
        if declined {
            self.finish(id, AskState::Declined, None)
        } else if ask.kind == AskKind::Run {
            self.run(ask)
        } else {
            self.finish(id, AskState::Answered, None)
        }
    }

    fn expire(&self, id: &str) {
        if self.ask(id).is_some_and(|a| a.state == AskState::Waiting) {
            self.finish(id, AskState::Expired, None)
        }
    }

    fn finish(&self, id: &str, state: AskState, exit_code: Option<i32>) {
        if let Some(timer) = self.lock().timers.remove(&format!("expire-{id}")) {
            timer.abort()
        }
        // Asked whether its task is done, the user said Done: done, confirmed.
        if state == AskState::Answered
            && let Some(question) = self.ask(id).filter(|a| a.done_check && a.choice == Some(0))
        {
            self.confirm(&question.agent, &question.body, "done");
        }
        self.update(id, |a| {
            a.state = state;
            a.answered_at = Some(Time::now());
            if exit_code.is_some() {
                a.exit_code = exit_code
            }
            true
        });
        self.deliver_answer(id);
        let Some(done) = self.ask(id) else { return };
        let twins: Vec<String> =
            self.lock().asks.iter().filter(|a| a.same_as.as_deref() == Some(id) && !a.state.is_final()).map(|a| a.id.clone()).collect();
        for twin in twins {
            self.update(&twin, |a| {
                a.output = done.output.clone();
                a.answer = done.answer.clone();
                a.choice = done.choice;
                true
            });
            self.finish(&twin, state, done.exit_code);
        }
    }

    /// Changes an ask, logs it and tells everyone; false when `change` declined to.
    fn update(&self, id: &str, change: impl FnOnce(&mut Ask) -> bool) -> bool {
        let mut state = self.lock();
        let Some(ask) = state.asks.iter_mut().find(|a| a.id == id) else { return false };
        if !change(ask) {
            return false;
        }
        let ask = ask.clone();
        drop(state);
        self.changed(&ask);
        true
    }

    fn changed(&self, ask: &Ask) {
        self.write_log(ask);
        let _ = self.events.send(InboxEvent::Ask(Box::new(ask.clone())));
    }

    /// Runs the command where zerod's restart can't reach it (runs.rs), in its folder through the user's login shell,
    /// and follows it to its end: its output into the ask as it comes, then its exit code.
    fn run(&self, ask: Ask) {
        let id = ask.id.clone();
        self.update(&id, |a| {
            a.state = AskState::Running;
            true
        });
        let (me, runs) = (self.me.clone(), self.runs());
        tokio::spawn(async move {
            let started = runs.start(&id, ask.command.as_deref().unwrap_or(""), ask.cwd.as_deref(), &ask.title).await;
            let Some(inbox) = me.upgrade() else { return };
            match started {
                Ok(handle) => {
                    inbox.update(&id, |a| {
                        a.run = Some(handle.clone());
                        true
                    });
                    inbox.follow(&id, handle);
                }
                Err(error) => {
                    inbox.append_output(&id, &format!("zero: {error}\n"));
                    inbox.finish(&id, AskState::Answered, Some(127));
                }
            }
        });
    }

    /// Reads a run's files until it ends: what it printed into its ask, then its outcome. Nothing knows of it any more
    /// and no exit code was kept: lost, said so (runs.rs).
    fn follow(&self, id: &str, handle: String) {
        let (me, id, runs) = (self.me.clone(), id.to_string(), self.runs());
        tokio::spawn(async move {
            let Some((out, exit)) = runs.files(&handle) else {
                if let Some(inbox) = me.upgrade() {
                    inbox.lose(&id)
                }
                return;
            };
            let (mut offset, mut carry) = (0u64, vec![]);
            loop {
                let ended = exit.exists();
                let printed = read_from(&out, &mut offset);
                let Some(inbox) = me.upgrade() else { return };
                if !printed.is_empty() {
                    inbox.append_output(&id, &crate::runs::plain(&mut carry, &printed))
                }
                if ended {
                    let code = std::fs::read_to_string(&exit).ok().and_then(|c| c.trim().parse().ok());
                    // Withdrawn while it ran (and stopped): its outcome kept, its ask left withdrawn, not answered.
                    if inbox.ask(&id).is_some_and(|a| a.status.as_deref() == Some("withdrawn")) {
                        inbox.update(&id, |a| {
                            a.exit_code = Some(code.unwrap_or(-1));
                            true
                        });
                    } else {
                        inbox.finish(&id, AskState::Answered, Some(code.unwrap_or(-1)));
                    }
                    drop(inbox);
                    runs.release(&handle).await;
                    return;
                }
                if !runs.alive(&handle).await && !exit.exists() {
                    // Ended between the two looks: its exit code is there now.
                    tokio::time::sleep(crate::runs::POLL).await;
                    if exit.exists() {
                        continue;
                    }
                    let withdrawn = inbox.ask(&id).is_some_and(|a| a.status.as_deref() == Some("withdrawn"));
                    inbox.lose(&id);
                    // Stopped on purpose: nothing to keep of it.
                    if withdrawn {
                        drop(inbox);
                        runs.release(&handle).await
                    }
                    return;
                }
                drop(inbox);
                tokio::time::sleep(crate::runs::POLL).await;
            }
        });
    }

    /// A run whose outcome nobody knows (cut off with nothing kept of how it ended): never a success or an expiry,
    /// which read as "it never ran". Its agent is told to check before running it again.
    fn lose(&self, id: &str) {
        // Withdrawn and stopped: gone as it was meant to, nothing lost (and it stays withdrawn).
        if self.ask(id).is_some_and(|a| a.status.as_deref() == Some("withdrawn")) {
            return;
        }
        self.append_output(id, "\n(Zero lost track of this command: it may or may not have finished.)\n");
        self.update(id, |a| {
            a.status = Some("lost".into());
            true
        });
        self.finish(id, AskState::Answered, None);
    }

    fn append_output(&self, id: &str, chunk: &str) {
        let mut state = self.lock();
        let Some(ask) = state.asks.iter_mut().find(|a| a.id == id) else { return };
        ask.output.push_str(chunk);
        if ask.output.len() > OUTPUT_KEPT + 64 * 1024 {
            // The log keeps the end; the waiting agent already got everything as it streamed.
            let total = ask.output.len();
            let mut cut = total - OUTPUT_KEPT;
            while !ask.output.is_char_boundary(cut) {
                cut += 1
            }
            let end = ask.output.split_off(cut);
            let earlier = ask
                .output
                .strip_prefix("(Zero kept only the end of the output, ")
                .and_then(|r| r.split(' ').next())
                .and_then(|n| n.parse::<usize>().ok());
            let seen = earlier.unwrap_or(0) + total;
            ask.output = format!("(Zero kept only the end of the output, {seen} bytes in all)\n{end}");
        }
        drop(state);
        let _ = self.events.send(InboxEvent::Output { id: id.into(), chunk: chunk.into() });
    }

    /// Types the answer into the session of an agent that asked with --async and so isn't waiting for it; again
    /// when the user retries a failed delivery.
    pub fn deliver_answer(&self, id: &str) {
        let Some(ask) = self.ask(id) else { return };
        if ask.waits != Some(false)
            || ask.status.as_deref() == Some("withdrawn")
            || (ask.same_as.is_some() && ask.state == AskState::Expired)
            || !ask.state.is_final()
        {
            return;
        }
        let text = Inbox::delivery_text(&ask);
        self.update(id, |a| {
            a.delivery = Some(Delivery::Sending);
            true
        });
        let (me, id, name) = (self.me.clone(), id.to_string(), ask.agent.name.clone());
        tokio::spawn(async move {
            let Some(inbox) = me.upgrade() else { return };
            let outcome = inbox.reach(&name, &text).await;
            inbox.update(&id, |a| {
                a.delivery = Some(if outcome.is_ok() { Delivery::Delivered } else { Delivery::Failed });
                true
            });
            if let Ok((identity, runtime)) = outcome {
                inbox.watch_reply(identity, text, runtime)
            }
        });
    }

    /// What an agent that isn't waiting is told: the answer, or for a run, how it went and the end of its output.
    pub fn delivery_text(ask: &Ask) -> String {
        let id = &ask.id;
        if ask.state == AskState::Expired {
            return format!(
                "Your ask {id} (\"{}\") expired without an answer from the user. Go on with what you recommended (or, \
                with none, what you would have), and say in your next message that you did; but what others will see or can't be \
                undone (a push, a merge, a message, a production change) waits for the user's word: ask again when they're back.",
                ask.title
            );
        }
        let reason = ask.answer.as_ref().map(|a| format!(": {a}")).unwrap_or_else(|| ".".into());
        if ask.kind != AskKind::Run {
            return if ask.state == AskState::Answered {
                format!("The user answered your ask {id} (\"{}\"): {}", ask.title, ask.answer.as_deref().unwrap_or(""))
            } else {
                format!("The user declined your ask {id} (\"{}\"){reason}", ask.title)
            };
        }
        let command = ask.command.as_deref().unwrap_or("");
        if ask.state != AskState::Answered {
            return format!("The user rejected your command {id} (`{command}`){reason}");
        }
        if ask.status.as_deref() == Some("lost") {
            return format!(
                "The user ran your command {id} (`{command}`), but Zero lost track of it while it ran: it may or may not have \
                finished. Check what it did before running it again."
            );
        }
        let code = ask.exit_code.unwrap_or(0);
        let lines: Vec<&str> = ask.output.split('\n').collect();
        let tail = lines[lines.len().saturating_sub(40)..].join("\n");
        let tail = tail.chars().rev().take(3000).collect::<Vec<_>>().into_iter().rev().collect::<String>();
        let tail = tail.trim();
        let verdict = if code == 0 { "It succeeded (exit 0).".to_string() } else { format!("It FAILED with exit {code}.") };
        let printed = if tail.is_empty() { "It printed nothing.".to_string() } else { format!("Last of its output:\n```\n{tail}\n```") };
        format!("The user ran your command {id} (`{command}`). {verdict} {printed}")
    }

    /// The user's words to an agent: delivered into its session (started again if it isn't running), then shown.
    pub async fn message(&self, text: &str, to: &str) -> Result<(), String> {
        let (identity, runtime) = self.reach(to, text).await?;
        let mut item = Ask::new(AskKind::Message, "Message", identity.clone(), 3600);
        item.body = text.into();
        item.status = Some("sent".into());
        self.create(item, false);
        // A slash command opens a picker in the agent's terminal; anything else gets an answer worth reading back.
        if !is_slash_command(text) {
            self.watch_reply(identity, text.into(), runtime)
        }
        Ok(())
    }

    /// The agent's answer to something it was sent comes back as a note from it.
    fn watch_reply(&self, identity: AgentIdentity, text: String, runtime: Arc<dyn Runtime>) {
        let me = self.me.clone();
        tokio::spawn(async move {
            let Some(reply) = runtime.reply(&identity, &text).await else { return };
            let Some(inbox) = me.upgrade() else { return };
            let mut note = Ask::new(AskKind::Note, "Replied", identity.clone(), 7 * 86400);
            note.body = reply;
            note.status = Some("done".into());
            inbox.create(note, false);
            inbox.relabel(&identity).await;
        });
    }

    /// Connects to the agent's session and types `text` into it.
    async fn reach(&self, name: &str, text: &str) -> Result<(AgentIdentity, Arc<dyn Runtime>), String> {
        let mut identity = self.identity(name).ok_or_else(|| format!("Zero doesn't know {name}"))?;
        let runtime = self.runtime_for(&identity).ok_or_else(|| format!("No way to reach {name}"))?;
        // An agent from before sessions were recorded: its session is the one that began with its first prompt.
        if identity.session.is_none() {
            let first = self.lock().asks.iter().find(|a| a.agent.name == name && a.kind == AskKind::Message).map(|a| a.body.clone());
            if let Some(first) = first
                && let Some(session) = runtime.find_session(&identity, &first).await
            {
                identity.session = Some(session);
                self.rebind(name, &identity);
            }
        }
        let connected = runtime.connect(&identity).await?;
        if connected != identity {
            self.rebind(name, &connected);
            identity = connected
        }
        {
            let mut state = self.lock();
            state.offline.remove(name);
            let sent = state.sent.entry(name.into()).or_default();
            sent.push((text.into(), Time::now()));
            let keep = sent.len().saturating_sub(10);
            sent.drain(..keep);
        }
        runtime.send(text, &identity).await?;
        Ok((identity, runtime))
    }

    fn runtime_for(&self, identity: &AgentIdentity) -> Option<Arc<dyn Runtime>> {
        self.runtimes.iter().find(|r| r.can_reach(identity)).cloned()
    }

    /// The agents whose sessions aren't running, and those Zero can reach, by name and sorted.
    pub fn agents(&self) -> (Vec<String>, Vec<String>) {
        let mut offline: Vec<String> = self.offline().into_iter().collect();
        let mut identities: HashMap<String, AgentIdentity> = HashMap::new();
        for ask in self.asks() {
            identities.insert(ask.agent.name.clone(), ask.agent);
        }
        let mut reachable: Vec<String> = identities.into_values().filter(|i| self.runtime_for(i).is_some()).map(|i| i.name).collect();
        offline.sort();
        reachable.sort();
        (offline, reachable)
    }

    pub fn can_message(&self, name: &str) -> bool {
        self.identity(name).is_some_and(|i| self.runtime_for(&i).is_some())
    }

    /// Moves everything recorded under one name to the identity the runtime reported.
    fn rebind(&self, name: &str, identity: &AgentIdentity) {
        let changed: Vec<Ask> = {
            let mut state = self.lock();
            state
                .asks
                .iter_mut()
                .filter(|a| a.agent.name == name)
                .map(|a| {
                    a.agent = identity.clone();
                    a.clone()
                })
                .collect()
        };
        for ask in changed {
            self.changed(&ask)
        }
    }

    /// Takes the runtime's current name for the agent as its label.
    pub async fn relabel(&self, identity: &AgentIdentity) {
        let Some(runtime) = self.runtime_for(identity) else { return };
        let Some(label) = runtime.display_name(identity).await else { return };
        if self.identity(&identity.name).and_then(|i| i.label).as_deref() == Some(label.as_str()) {
            return;
        }
        let last = {
            let mut state = self.lock();
            for ask in state.asks.iter_mut().filter(|a| a.agent.name == identity.name) {
                ask.agent.label = Some(label.clone())
            }
            state.asks.iter().rev().find(|a| a.agent.name == identity.name).cloned()
        };
        if let Some(last) = last {
            self.changed(&last)
        }
    }

    /// A prompt arrived in an agent's session (the plugin's prompt hook reports it): "zero" when Zero typed it;
    /// otherwise the user did, in the terminal, so the agent's open questions are answered there and withdrawn.
    /// Runs, and steps for the user to run themselves (a question with its command), stay open: only the user can
    /// run them, whatever they typed.
    pub fn prompted(&self, identity: &AgentIdentity, text: &str) -> &'static str {
        let name = resolve(&self.lock().asks, identity);
        if let Some(session) = &identity.session
            && let Some(mut known) = self.identity(&name)
            && known.session.as_ref() != Some(session)
        {
            known.session = Some(session.clone());
            known.label = None;
            self.rebind(&name, &known);
            if let Some(me) = self.me.upgrade() {
                tokio::spawn(async move { me.relabel(&known).await });
            }
        }
        let clean = text.trim();
        let ours = self.lock().sent.get(&name).is_some_and(|sent| {
            sent.iter()
                .any(|(words, at)| Time::now().0 - at.0 < 600 && clean.starts_with(&words.trim().chars().take(120).collect::<String>()))
        });
        if ours {
            return "zero";
        }
        let open: Vec<String> = self
            .lock()
            .asks
            .iter()
            .filter(|a| {
                a.agent.name == name
                    && a.kind != AskKind::Run
                    && a.command.is_none()
                    && a.same_as.is_none()
                    && matches!(a.state, AskState::Waiting | AskState::Pending)
            })
            .map(|a| a.id.clone())
            .collect();
        for id in open {
            self.withdraw(&id, Some("The user replied in the chat"))
        }
        "human"
    }

    /// Takes the agent out of the bar: a closing note in its timeline, its open asks expired, and its process
    /// stopped unless it's already gone. Anything it says afterwards brings it back.
    pub fn close_agent(&self, name: &str, stop: bool) {
        let Some(last) = self.lock().asks.iter().rev().find(|a| a.agent.name == name).cloned() else { return };
        if self.is_closed(name) && !self.has_open_asks(name) {
            return;
        }
        let open: Vec<String> = self
            .lock()
            .asks
            .iter()
            .filter(|a| a.agent.name == name && matches!(a.state, AskState::Waiting | AskState::Pending))
            .map(|a| a.id.clone())
            .collect();
        for id in open {
            self.finish(&id, AskState::Expired, None)
        }
        let mut note = Ask::new(AskKind::Note, "Closed", last.agent.clone(), 3600);
        note.body = if stop { "Closed by the user".into() } else { "Closed in its runtime".into() };
        note.status = Some("closed".into());
        self.create(note, false);
        if stop && let Some(runtime) = self.runtime_for(&last.agent) {
            tokio::spawn(async move { runtime.stop(&last.agent).await });
        }
    }

    /// True when closing the agent would also stop a running process.
    pub fn can_stop(&self, name: &str) -> bool {
        self.identity(name).is_some_and(|i| !self.lock().offline.contains(name) && self.runtime_for(&i).is_some())
    }

    fn has_open_asks(&self, name: &str) -> bool {
        self.lock().asks.iter().any(|a| a.agent.name == name && matches!(a.state, AskState::Waiting | AskState::Pending))
    }

    pub fn is_closed(&self, name: &str) -> bool {
        self.lock().asks.iter().rev().find(|a| a.agent.name == name && a.kind != AskKind::Message).and_then(|a| a.status.as_deref())
            == Some("closed")
    }

    pub async fn screen(&self, name: &str) -> Option<String> {
        let identity = self.identity(name)?;
        self.runtime_for(&identity)?.screen(&identity).await
    }

    pub async fn press(&self, name: &str, bytes: &[u8]) -> Result<Option<String>, String> {
        let identity = self.identity(name).ok_or_else(|| format!("Zero doesn't know {name}"))?;
        self.runtime_for(&identity).ok_or_else(|| format!("No way to reach {name}"))?.press(bytes, &identity).await
    }

    pub async fn switch_model(&self, name: &str, model: Option<&str>, level: Option<&str>) -> Result<(), String> {
        let identity = self.identity(name).ok_or_else(|| format!("Zero doesn't know {name}"))?;
        self.runtime_for(&identity).ok_or_else(|| format!("No way to reach {name}"))?.switch_model(&identity, model, level).await
    }

    /// Which agents still run (every few seconds): stopped ones go grey, closed ones leave, titles catch up, and once a
    /// minute each running agent's screen is read for trouble it can't report itself.
    pub async fn refresh_liveness(&self) {
        let mut identities: HashMap<String, AgentIdentity> = HashMap::new();
        for ask in self.asks().into_iter().filter(|a| a.state != AskState::Expired) {
            identities.insert(ask.agent.name.clone(), ask.agent);
        }
        let all: Vec<AgentIdentity> = identities.values().cloned().collect();
        let mut stopped = HashSet::new();
        for runtime in &self.runtimes {
            stopped.extend(runtime.offline(&all).await)
        }
        self.lock().offline = stopped.clone();
        let open: Vec<AgentIdentity> = all.iter().filter(|a| !self.is_closed(&a.name)).cloned().collect();
        for runtime in &self.runtimes {
            for name in runtime.gone(&open).await {
                self.close_agent(&name, false)
            }
        }
        for identity in all.iter().filter(|i| i.session.is_some()) {
            self.relabel(identity).await
        }
        let agents = self.agents();
        if std::mem::replace(&mut self.lock().agents, agents.clone()) != agents {
            let _ = self.events.send(InboxEvent::Agents { offline: agents.0, reachable: agents.1 });
        }
        let tick = {
            let mut state = self.lock();
            state.ticks += 1;
            state.ticks
        };
        if tick % 12 != 1 {
            return;
        }
        self.trim(Time::now());
        for identity in all.iter().filter(|i| !stopped.contains(&i.name) && !self.is_closed(&i.name)) {
            let Some(runtime) = self.runtime_for(identity) else { continue };
            let Some(trouble) = runtime.screen(identity).await.as_deref().and_then(Inbox::trouble) else { continue };
            if self.lock().reported.get(&identity.name) == Some(&trouble) {
                continue;
            }
            self.lock().reported.insert(identity.name.clone(), trouble.clone());
            let mut note = Ask::new(AskKind::Note, "Stuck", identity.clone(), 3600);
            note.body = format!("Claude Code stopped: {trouble}");
            note.status = Some("blocked".into());
            self.create(note, false);
        }
    }

    /// Lets go of what has left the window (`window`), telling clients (`Removed`) so they let go of it too.
    pub fn trim(&self, now: Time) {
        let removed: Vec<String> = {
            let mut state = self.lock();
            let mut keep = window(&state.asks, now).into_iter();
            let mut removed = vec![];
            state.asks.retain(|a| {
                let kept = keep.next().unwrap_or(true);
                if !kept {
                    removed.push(a.id.clone())
                }
                kept
            });
            removed
        };
        if removed.len() >= TRIMMED_AT_ONCE {
            let _ = self.events.send(InboxEvent::Trimmed);
            return;
        }
        for id in removed {
            let _ = self.events.send(InboxEvent::Removed(id));
        }
    }

    /// A line on an agent's screen that means it stopped and can't say so: signed out, out of usage, or an API
    /// error ending its turn.
    pub fn trouble(screen: &str) -> Option<String> {
        let lines: Vec<&str> = screen.lines().collect();
        let tail = &lines[lines.len().saturating_sub(25)..];
        let signs = [
            "please run /login",
            "not logged in",
            "oauth access token is invalid",
            "usage limit",
            "credit balance is too low",
            "api error: 5",
            "api error: 401",
            "api error: 403",
        ];
        tail.iter()
            .rev()
            .find(|line| {
                let lower = line.to_lowercase();
                signs.iter().any(|s| lower.contains(s))
            })
            .map(|line| line.trim().trim_matches(|c| "⏺⎿ ".contains(c)).to_string())
    }

    /// The first line of a prompt, cut to five words, as an agent's label; none when too short to name anything.
    pub fn gist(prompt: &str) -> Option<String> {
        let line = prompt.lines().next().unwrap_or("");
        let words: Vec<String> = line
            .split(' ')
            .map(|w| w.trim_matches(|c: char| c.is_ascii_punctuation() && c != '\'').to_string())
            .filter(|w| !w.is_empty())
            .collect();
        if words.len() < 3 {
            return None;
        }
        let kept = words[..words.len().min(5)].join(" ");
        let mut chars = kept.chars();
        let first = chars.next().map(|c| c.to_uppercase().collect::<String>()).unwrap_or_default();
        Some(first + chars.as_str() + if words.len() > 5 { "…" } else { "" })
    }

    fn write_log(&self, ask: &Ask) {
        let Some(path) = &self.log else { return };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let Ok(mut line) = serde_json::to_vec(ask) else { return };
        line.push(b'\n');
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = file.write_all(&line);
        }
    }

    /// Replays the log: the latest line per id wins, and what's kept of it is `window`'s. An answer still being staged waits again; a run that was running died with whatever ran it.
    fn load(&self) {
        let Some(path) = &self.log else { return };
        let Ok(text) = std::fs::read_to_string(path) else { return };
        let mut by_id: HashMap<String, Ask> = HashMap::new();
        let mut order: Vec<String> = vec![];
        for line in text.lines() {
            let Ok(ask) = serde_json::from_str::<Ask>(line) else { continue };
            if !by_id.contains_key(&ask.id) {
                order.push(ask.id.clone())
            }
            by_id.insert(ask.id.clone(), ask);
        }
        let all: Vec<Ask> = order.iter().filter_map(|id| by_id.remove(id)).collect();
        let mut kept = vec![];
        let mut died = vec![];
        let mut running = vec![];
        for mut ask in all {
            if ask.state == AskState::Pending {
                ask.state = AskState::Waiting;
                ask.answer = None;
                ask.choice = None;
            }
            // A run under way: followed again from its files, its output read afresh from them. One from before runs
            // were kept apart from zerod has nothing to follow: lost, said so.
            if ask.state == AskState::Running {
                match ask.run.clone() {
                    Some(handle) => {
                        ask.output.clear();
                        running.push((ask.id.clone(), handle))
                    }
                    None => {
                        ask.state = AskState::Answered;
                        ask.status = Some("lost".into());
                        ask.output.push_str("\n(Zero lost track of this command: it may or may not have finished.)\n");
                        ask.answered_at = Some(Time::now());
                        died.push(ask.clone());
                    }
                }
            }
            kept.push(ask)
        }
        let window = window(&kept, Time::now());
        let mut keep = window.into_iter();
        kept.retain(|_| keep.next().unwrap_or(true));
        let waiting: Vec<(String, i64)> =
            kept.iter().filter(|a| a.state == AskState::Waiting).map(|a| (a.id.clone(), a.expires_at.0 - Time::now().0)).collect();
        self.lock().asks = kept;
        for ask in died {
            self.write_log(&ask)
        }
        // Expiry timers need a runtime; an inbox opened outside one (a script) just doesn't expire.
        if tokio::runtime::Handle::try_current().is_ok() {
            for (id, seconds) in waiting {
                self.schedule_expiry(&id, seconds)
            }
            for (id, handle) in running {
                self.follow(&id, handle)
            }
        }
    }
}

/// The option that runs a run and allows its kind for the rest of its task.
pub const ALLOW_FOR_TASK: &str = "Run, and allow the same for this task";

/// A run whose command is its kind's prefix and one plain path after it: nothing chained on, redirected or expanded.
fn of_its_kind(ask: &Ask) -> bool {
    let (Some(command), Some(prefix)) = (ask.command.as_deref(), ask.allow.as_deref()) else { return false };
    let Some(rest) = command.strip_prefix(prefix) else { return false };
    let rest = rest.trim();
    !prefix.trim().is_empty() && !rest.is_empty() && rest.chars().all(|c| c.is_ascii_alphanumeric() || "._/~-+@:,=".contains(c))
}

/// Its kind allowed already for its task: an earlier run of that kind from the same task (its session, or the agent
/// without one) answered with the allowing option.
fn allowed(asks: &[Ask], ask: &Ask) -> bool {
    let task = |a: &Ask| a.agent.session.clone().unwrap_or_else(|| a.agent.name.clone());
    asks.iter().any(|a| {
        a.kind == AskKind::Run
            && a.allow == ask.allow
            && task(a) == task(ask)
            && a.cwd == ask.cwd
            && a.choice.and_then(|c| a.options.get(c)).is_some_and(|o| o == ALLOW_FOR_TASK)
            && matches!(a.state, AskState::Running | AskState::Answered)
    })
}

/// For approve and run every option after the first declines (but the one allowing a run's kind); a permission
/// declines only with a "Deny" option.
fn declines(ask: &Ask, index: usize) -> bool {
    match ask.kind {
        AskKind::Permission => ask.options.get(index).is_some_and(|o| o.starts_with("Deny")),
        AskKind::Run => index >= 1 && ask.options.get(index).is_none_or(|o| o != ALLOW_FOR_TASK),
        AskKind::Approve => index >= 1,
        _ => false,
    }
}

fn identity(asks: &[Ask], name: &str) -> Option<AgentIdentity> {
    asks.iter().rev().find(|a| a.agent.name == name).map(|a| a.agent.clone())
}

/// The name Zero knows an agent by: its own, or that of the agent on the same runtime reference.
fn resolve(asks: &[Ask], agent: &AgentIdentity) -> String {
    if identity(asks, &agent.name).is_some() {
        return agent.name.clone();
    }
    if let Some(reference) = &agent.reference
        && let Some(owner) = asks.iter().rev().find(|a| a.agent.reference.as_ref() == Some(reference))
    {
        return owner.agent.name.clone();
    }
    agent.name.clone()
}

/// Claude Code's own slash commands, whose pickers live in its terminal.
fn is_slash_command(message: &str) -> bool {
    const BUILT_IN: [&str; 26] = [
        "add-dir",
        "agents",
        "clear",
        "compact",
        "config",
        "context",
        "cost",
        "doctor",
        "effort",
        "export",
        "help",
        "hooks",
        "init",
        "login",
        "logout",
        "mcp",
        "memory",
        "model",
        "permissions",
        "plugin",
        "resume",
        "review",
        "rewind",
        "status",
        "usage",
        "vim",
    ];
    message.strip_prefix('/').and_then(|rest| rest.split_whitespace().next()).is_some_and(|word| BUILT_IN.contains(&word))
}

/// Where detached runs keep their files: beside the inbox's log, else (an inbox with none, a test's) a temporary folder.
fn runs_dir(log: Option<&Path>) -> PathBuf {
    log.and_then(Path::parent)
        .map(|dir| dir.join("runs"))
        .unwrap_or_else(|| std::env::temp_dir().join(format!("zero-runs-{}", std::process::id())))
}

/// What a file holds past `offset`, and the offset moved past it.
fn read_from(path: &Path, offset: &mut u64) -> Vec<u8> {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut file) = std::fs::File::open(path) else { return vec![] };
    if file.seek(SeekFrom::Start(*offset)).is_err() {
        return vec![];
    }
    let mut bytes = vec![];
    let _ = file.read_to_end(&mut bytes);
    *offset += bytes.len() as u64;
    bytes
}

/// Which asks the inbox keeps, at start and every minute after: what isn't final, the last day, and each agent's latest
/// (its dot) unless that's its "Closed" (every archived task's last word). The log keeps everything; neither zerod nor
/// the apps following it hold days of notes.
fn window(asks: &[Ask], now: Time) -> Vec<bool> {
    let cutoff = now.0 - 86400;
    let latest: HashMap<&str, &str> = asks.iter().map(|a| (a.agent.name.as_str(), a.id.as_str())).collect();
    asks.iter()
        .map(|ask| {
            let recent = ask.answered_at.unwrap_or(ask.created_at).0 > cutoff;
            let its_latest = latest.get(ask.agent.name.as_str()) == Some(&ask.id.as_str()) && ask.status.as_deref() != Some("closed");
            !ask.state.is_final() || recent || its_latest
        })
        .collect()
}
