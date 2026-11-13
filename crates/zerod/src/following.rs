//! Following: what a session wants to hear about while it isn't looking. A session follows a topic (a pull request,
//! a Linear issue or one of its comment threads, a Slack thread or channel); zerod polls each followed thing, diffs
//! it against its last reading, and tells every follower what changed through the words-between-turns path
//! (`Daemon::notify`), which resumes a parked session for them. So an agent that has ended its turn is woken by a
//! review or a reply, with no hook and no process of its own waiting. Follows and the last readings live in
//! following.json in zerod's home; a follow goes with its session.
//!
//! Topics are `<source>/<segments>`, as agent-events named them, so what agents learned there carries over:
//! `github/<owner>/<repo>/<number>`, `linear/<ISSUE>[/<thread>]`, `slack/<channel>[/<thread-ts>]`. A URL is accepted
//! wherever a topic is. Following `a/b` also hears events on `a/b/...`.

use crate::now;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::broadcast;

use crate::integrations::{Fetcher, Integrations};
use crate::model::ItemKind;

pub mod github;
pub mod linear;
pub mod own;
pub mod slack;

/// After this many polls failing in a row, followers hear of it (once), and once more when polling works again.
pub const REPORT_FAILS: u32 = 3;

/// Events for a task between turns are held this long from the first, then wake it once with all of them: a burst
/// (six issues moved, each polled on its own) is one turn, not six.
pub const BATCH: i64 = 30;

/// How long what a step did is remembered, to know the events it causes as the task's own.
pub const OWN_FOR: i64 = 300;

/// A filtered follow that passed an author's message passes their next ones in the same place too, as one sequence (a
/// deploy bot's "Running migrations", "Deploy complete"): until they name something else, this long passes quietly,
/// or this many have passed.
pub const QUIET: i64 = 30 * 60;
pub const SEQUENCE: u32 = 20;

/// How a follower hears of events: news wakes it; its own changes coming back are only noted in its conversation.
/// Settled is news that only confirms an end (Event::settled): a finished task notes it and isn't woken.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Heard {
    News,
    Own,
    Settled,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Follow {
    pub session: String,
    pub topic: String,
    /// Only events that name a pull request the session follows (`repo#N`, `pull/N`, `#N`) or its merge commit, and the
    /// sequences they start (QUIET): a busy channel's share.
    #[serde(default)]
    pub mine: bool,
    /// Only events with one of these words in them.
    #[serde(default)]
    pub about: Vec<String>,
    pub at: i64,
}

/// One followed thing as polled: its last reading, the line that describes it, and how polling it is going.
#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<Value>,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub last_poll: i64,
    #[serde(default)]
    pub next_poll: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default)]
    pub fails: u32,
}

#[derive(Serialize, Deserialize, Default)]
struct Kept {
    follows: Vec<Follow>,
    targets: BTreeMap<String, Target>,
    /// Per session, the events it was told of that could come again from another poll (a Slack reply seen by the
    /// channel's poll and the thread's): `topic#dedupe`, the latest last.
    #[serde(default)]
    seen: HashMap<String, Vec<String>>,
    /// Per session between turns, the events held for one wake (BATCH), and since when.
    #[serde(default)]
    held: HashMap<String, (i64, Vec<Event>)>,
    #[serde(default)]
    sequences: Vec<Sequence>,
}

/// An author's messages a session's filtered follow passes for following the one it matched (QUIET, SEQUENCE).
#[derive(Serialize, Deserialize, Clone)]
struct Sequence {
    session: String,
    topic: String,
    actor: String,
    /// The matched message, which the next ones continue.
    matched: String,
    /// When the last of it was said, and how many have followed the matched one.
    at: i64,
    count: u32,
}

/// Something that changed on a followed thing.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Event {
    pub topic: String,
    pub kind: String,
    pub summary: String,
    pub body: String,
    pub url: String,
    pub actor: String,
    /// By the account zerod reads as: often the agent's own action echoing back.
    pub mine: bool,
    /// Unique on the topic, when the same event can come from two polls.
    pub dedupe: Option<String>,
    /// For a reply in a thread: the thread's first message, which decides whether a filtered follow wants the reply.
    pub root: Option<String>,
    /// For a message a filtered follow passes as part of a sequence (QUIET): the one that matched, which it continues:
    /// a deploy bot's "Deploy complete" after its "Deploying commit 5425391615".
    pub after: Option<String>,
    /// Only confirms an end, nothing to act on: an issue completed or canceled, a pull request merged, closed or
    /// approved, CI passing, a bot's words, bookkeeping on what has ended. Not known to, it's news (the default).
    pub settled: bool,
    /// When it happened, in seconds, when the source says (a Slack message); 0 when it was heard.
    pub at: i64,
}

/// One poll's outcome: the fresh reading, the events since the last, and the line describing the thing.
pub struct Poll {
    pub state: Value,
    pub events: Vec<Event>,
    pub summary: String,
}

/// A follow as listed: the follow, the thing's description, and how polling it goes.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Followed {
    #[serde(flatten)]
    pub follow: Follow,
    pub summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub last_poll: i64,
    /// Whether this call made the follow (`follow`), rather than finding it there.
    #[serde(default)]
    pub new: bool,
    /// What else `follow` learned, e.g. whose comment thread it is.
    #[serde(default)]
    pub detail: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Source {
    GitHub,
    Linear,
    Slack,
}

impl Source {
    fn of(topic: &str) -> Result<Source, String> {
        match topic.split('/').next() {
            Some("github") => Ok(Source::GitHub),
            Some("linear") => Ok(Source::Linear),
            Some("slack") => Ok(Source::Slack),
            _ => Err(format!(
                "Not a topic Zero can follow: {topic} (github/<owner>/<repo>/<pr>, linear/<ISSUE>[/<thread>], slack/<channel>[/<thread-ts>], or a URL)"
            )),
        }
    }
    /// Seconds between polls of one key, and the least between any two polls of this source (its rate limit's share):
    /// with n keys followed each is polled at most every n × spacing seconds.
    fn interval(self) -> i64 {
        match self {
            Source::Slack => 30,
            _ => 60,
        }
    }
    fn spacing(self) -> i64 {
        match self {
            Source::GitHub => 2,
            _ => 3,
        }
    }
}

/// The canonical topic for what was given: a topic as typed, or a GitHub, Linear or Slack URL.
pub fn topic(given: &str) -> Result<String, String> {
    let given = given.trim().trim_matches('/');
    let given =
        github::from_url(given).or_else(|| linear::from_url(given)).or_else(|| slack::from_url(given)).unwrap_or_else(|| given.to_string());
    let parts: Vec<&str> = given.split('/').collect();
    let segments = match Source::of(&given)? {
        Source::GitHub => github::normalize(&parts[1..])?,
        Source::Linear => linear::normalize(&parts[1..])?,
        Source::Slack => slack::normalize(&parts[1..])?,
    };
    Ok(format!("{}/{}", parts[0], segments.join("/")))
}

/// What has to be polled for a topic: a Linear thread is read with its issue.
fn poll_key(topic: &str) -> String {
    match Source::of(topic) {
        Ok(Source::Linear) => topic.splitn(3, '/').take(2).collect::<Vec<_>>().join("/"),
        _ => topic.to_string(),
    }
}

fn covers(follow: &str, topic: &str) -> bool {
    topic == follow || topic.strip_prefix(follow).is_some_and(|rest| rest.starts_with('/'))
}

pub struct Following {
    file: PathBuf,
    fetcher: Arc<dyn Fetcher>,
    integrations: Arc<Integrations>,
    kept: Mutex<Kept>,
    /// What sessions' steps did lately (OWN_FOR): session, when, what.
    touches: Mutex<Vec<(String, i64, own::Touch)>>,
    /// Seconds events for a session between turns are held (BATCH).
    window: AtomicI64,
    /// Fires when follows or targets change, for the app.
    pub changed: broadcast::Sender<()>,
}

impl Following {
    pub fn open(home: &Path, fetcher: Arc<dyn Fetcher>, integrations: Arc<Integrations>) -> Arc<Following> {
        let file = home.join("following.json");
        let kept = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        Arc::new(Following {
            file,
            fetcher,
            integrations,
            kept: Mutex::new(kept),
            touches: Mutex::default(),
            window: AtomicI64::new(BATCH),
            changed: broadcast::channel(16).0,
        })
    }

    /// How long events for a session between turns are held for one wake.
    pub fn set_window(&self, seconds: i64) {
        self.window.store(seconds, Ordering::Relaxed)
    }

    /// A step of `session`'s, as it starts: what it does to things followed is remembered a while, so the events it
    /// causes come back as its own.
    pub fn touched(&self, session: &str, kind: &ItemKind) {
        let found = own::touches(kind);
        let mut touches = self.touches.lock().unwrap();
        let now = now();
        touches.retain(|(s, at, t)| now - at <= OWN_FOR && !(s == session && found.contains(t)));
        touches.extend(found.into_iter().map(|t| (session.to_string(), now, t)));
    }

    /// Whether `event` is what one of `session`'s steps did lately.
    pub fn own(&self, session: &str, event: &Event) -> bool {
        let now = now();
        self.touches.lock().unwrap().iter().any(|(s, at, t)| s == session && now - at <= OWN_FOR && own::matches(t, event))
    }

    fn keep(&self, kept: &Kept) {
        if let Ok(data) = serde_json::to_vec(kept) {
            let _ = std::fs::write(&self.file, data);
        }
        let _ = self.changed.send(());
    }

    /// Every follow, or one session's, with how each followed thing is doing.
    pub fn list(&self, session: Option<&str>) -> Vec<Followed> {
        let kept = self.kept.lock().unwrap();
        kept.follows
            .iter()
            .filter(|f| session.is_none_or(|s| f.session == s))
            .map(|f| {
                let target = kept.targets.get(&poll_key(&f.topic)).cloned().unwrap_or_default();
                Followed {
                    follow: f.clone(),
                    summary: target.summary,
                    error: target.error,
                    last_poll: target.last_poll,
                    new: false,
                    detail: String::new(),
                }
            })
            .collect()
    }

    /// `session` follows `given` (a topic or URL). The thing is read first, so a typo or no access fails here, and so
    /// that what happened before the follow isn't news to it.
    pub async fn follow(&self, session: &str, given: &str, mine: bool, about: Vec<String>) -> Result<Followed, String> {
        let topic = topic(given)?;
        let key = poll_key(&topic);
        let source = Source::of(&topic)?;
        let target = self.kept.lock().unwrap().targets.get(&key).cloned();
        let stale = |t: &Target| t.state.is_none() || now() - t.last_poll > 2 * self.interval(source);
        if target.as_ref().is_none_or(stale) {
            self.poll(&key).await;
            let mut kept = self.kept.lock().unwrap();
            if let Some(error) = kept.targets.get(&key).and_then(|t| t.state.is_none().then(|| t.error.clone()).flatten()) {
                if !kept.follows.iter().any(|f| poll_key(&f.topic) == key) {
                    kept.targets.remove(&key);
                }
                return Err(format!("Can't follow {key}: {error}"));
            }
        }
        let (topic, detail) = {
            let kept = self.kept.lock().unwrap();
            let state = kept
                .targets
                .get(&key)
                .and_then(|t| t.state.as_ref())
                .ok_or_else(|| format!("Can't follow {key}: nothing read yet, try again"))?;
            match source {
                Source::Linear => linear::resolve(&topic, state)?,
                _ => (topic.clone(), String::new()),
            }
        };
        let mut kept = self.kept.lock().unwrap();
        let new = !kept.follows.iter().any(|f| f.session == session && f.topic == topic);
        kept.follows.retain(|f| !(f.session == session && f.topic == topic));
        kept.follows.push(Follow { session: session.into(), topic: topic.clone(), mine, about, at: now() });
        self.keep(&kept);
        let target = kept.targets.get(&key).cloned().unwrap_or_default();
        Ok(Followed {
            follow: kept.follows.last().unwrap().clone(),
            summary: target.summary,
            error: target.error,
            last_poll: target.last_poll,
            new,
            detail,
        })
    }

    /// `session` follows a pull request it opened (`opened`, or set as its PR): no read first, as `follow` does, since
    /// it was just made: its first poll is the reading events are told against. The topic when it's new to the session.
    pub fn adopt(&self, session: &str, given: &str) -> Option<String> {
        let topic = topic(given).ok()?;
        let mut kept = self.kept.lock().unwrap();
        if kept.follows.iter().any(|f| f.session == session && f.topic == topic) {
            return None;
        }
        kept.follows.push(Follow { session: session.into(), topic: topic.clone(), mine: false, about: vec![], at: now() });
        kept.targets.entry(poll_key(&topic)).or_default();
        self.keep(&kept);
        Some(topic)
    }

    /// A worker's pull requests, followed by its lead too (the lead acts on the merge): the topics new to the lead.
    pub fn pass(&self, worker: &str, lead: &str) -> Vec<String> {
        let prs: Vec<String> = self.list(Some(worker)).into_iter().map(|f| f.follow.topic).filter(|t| is_pr(t)).collect();
        prs.iter().filter_map(|t| self.adopt(lead, t)).collect()
    }

    /// How many of `session`'s follows `other` doesn't share.
    pub fn unshared(&self, session: &str, other: &str) -> usize {
        let kept = self.kept.lock().unwrap();
        let theirs: HashSet<&str> = kept.follows.iter().filter(|f| f.session == other).map(|f| f.topic.as_str()).collect();
        kept.follows.iter().filter(|f| f.session == session && !theirs.contains(f.topic.as_str())).count()
    }

    /// `session` stops following what `other` follows too: a worker put away, its lead carrying on with them.
    pub fn drop_shared(&self, session: &str, other: &str) {
        let shared: Vec<String> = {
            let kept = self.kept.lock().unwrap();
            let theirs: HashSet<&str> = kept.follows.iter().filter(|f| f.session == other).map(|f| f.topic.as_str()).collect();
            kept.follows.iter().filter(|f| f.session == session && theirs.contains(f.topic.as_str())).map(|f| f.topic.clone()).collect()
        };
        if !shared.is_empty() {
            self.unfollow(session, Some(&shared));
        }
    }

    /// Takes back a session's follows: the topics named (as given, or as canonical), or all of them. How many went.
    pub fn unfollow(&self, session: &str, topics: Option<&[String]>) -> usize {
        let wanted: Option<Vec<String>> =
            topics.map(|ts| ts.iter().map(|t| topic(t).unwrap_or_else(|_| t.trim().trim_matches('/').to_string())).collect());
        let mut kept = self.kept.lock().unwrap();
        let before = kept.follows.len();
        kept.follows.retain(|f| {
            f.session != session || wanted.as_ref().is_some_and(|w| !w.iter().any(|t| *t == f.topic || linear::same_thread(t, &f.topic)))
        });
        kept.seen.remove(session);
        let removed = before - kept.follows.len();
        if removed > 0 {
            self.prune(&mut kept);
            self.keep(&kept);
        }
        removed
    }

    /// Whether every pull request and issue `session` follows has ended (merged or closed; completed or canceled),
    /// at least one of them: nothing more is to come of its work.
    pub fn finished(&self, session: &str) -> bool {
        let kept = self.kept.lock().unwrap();
        let ended = |f: &Follow| {
            let state = kept.targets.get(&poll_key(&f.topic)).and_then(|t| t.state.as_ref());
            match Source::of(&f.topic) {
                Ok(Source::GitHub) => state.is_some_and(github::ended),
                Ok(Source::Linear) => state.is_some_and(linear::ended),
                _ => true,
            }
        };
        let ending: Vec<&Follow> =
            kept.follows.iter().filter(|f| f.session == session && Source::of(&f.topic).is_ok_and(|s| s != Source::Slack)).collect();
        !ending.is_empty() && kept.follows.iter().filter(|f| f.session == session).all(ended)
    }

    /// Have everything polled on the next tick.
    pub fn hurry(&self) {
        let mut kept = self.kept.lock().unwrap();
        for target in kept.targets.values_mut() {
            target.next_poll = 0
        }
    }

    fn interval(&self, source: Source) -> i64 {
        let n = self.kept.lock().unwrap().targets.keys().filter(|k| Source::of(k) == Ok(source)).count() as i64;
        source.interval().max(n * source.spacing())
    }

    /// Targets nobody follows go.
    fn prune(&self, kept: &mut Kept) {
        let wanted: HashSet<String> = kept.follows.iter().map(|f| poll_key(&f.topic)).collect();
        kept.targets.retain(|key, _| wanted.contains(key));
    }

    /// One pass: follows of sessions gone are dropped, each thing due is polled, and its followers are told what
    /// changed. `alive` says whether a session still exists; `idle` whether it's between turns (what it's told is
    /// held a while, for one wake); `tell` gives a session words.
    pub async fn tick(&self, alive: impl Fn(&str) -> bool, idle: impl Fn(&str) -> bool, tell: impl Fn(&str, &str, Heard)) {
        let due: Vec<String> = {
            let mut kept = self.kept.lock().unwrap();
            let before = kept.follows.len();
            kept.follows.retain(|f| alive(&f.session));
            kept.held.retain(|session, _| alive(session));
            if kept.follows.len() != before {
                self.prune(&mut kept);
                self.keep(&kept);
            }
            let now = now();
            kept.targets.iter().filter(|(_, t)| t.next_poll <= now).map(|(k, _)| k.clone()).collect()
        };
        // ponytail: one after another; poll several at once if a tick gets slow with many follows.
        let mut events = vec![];
        for key in due {
            events.extend(self.poll(&key).await)
        }
        self.hold(&events);
        self.flush(&idle, &tell);
    }

    /// Polls `key`, keeps the reading, and gives the events (polling trouble included).
    async fn poll(&self, key: &str) -> Vec<Event> {
        let (state, fails) = {
            let kept = self.kept.lock().unwrap();
            let t = kept.targets.get(key).cloned().unwrap_or_default();
            (t.state, t.fails)
        };
        let source = match Source::of(key) {
            Ok(source) => source,
            Err(_) => return vec![],
        };
        let interval = self.interval(source);
        let result = self.fetch(source, key, state.as_ref()).await;
        let mut kept = self.kept.lock().unwrap();
        let target = kept.targets.entry(key.into()).or_default();
        let before = (target.state.clone(), target.summary.clone(), target.error.clone(), target.fails);
        let mut events = vec![];
        match result {
            Ok(poll) => {
                if state.is_some() {
                    events = poll.events
                }
                if fails >= REPORT_FAILS {
                    events.push(Event {
                        topic: key.into(),
                        kind: "recovered".into(),
                        summary: "polling works again".into(),
                        ..Default::default()
                    })
                }
                *target = Target {
                    state: Some(poll.state),
                    summary: poll.summary,
                    last_poll: now(),
                    next_poll: now() + interval,
                    error: None,
                    fails: 0,
                };
            }
            Err(error) => {
                eprintln!("zerod: following {key}: {error}");
                target.fails = fails + 1;
                target.next_poll = now() + (interval << fails.min(6)).min(900);
                target.error = Some(error.clone());
                if state.is_some() && target.fails == REPORT_FAILS {
                    events.push(Event {
                        topic: key.into(),
                        kind: "error".into(),
                        summary: format!("polling is failing: {error}"),
                        ..Default::default()
                    });
                }
            }
        }
        // Written only when what it found is new: the times of the polls aren't worth the file (hundreds of kilobytes
        // with many things followed) after every poll of every one; lost with a restart, it's polled again, early.
        if (target.state.clone(), target.summary.clone(), target.error.clone(), target.fails) != before {
            self.keep(&kept)
        }
        events
    }

    async fn fetch(&self, source: Source, key: &str, state: Option<&Value>) -> Result<Poll, String> {
        let parts: Vec<&str> = key.split('/').skip(1).collect();
        match source {
            Source::GitHub => {
                let argv = crate::adapter::on_login_path(&github::argv(&parts).iter().map(String::as_str).collect::<Vec<_>>());
                let reply: Value =
                    serde_json::from_str(&self.fetcher.run(argv, None).await?).map_err(|e| format!("gh answered oddly: {e}"))?;
                github::poll(&reply, state, key)
            }
            Source::Linear => linear::poll(&self.integrations.linear(linear::query(parts[0])).await?, state, key),
            Source::Slack => slack::poll(&self.integrations, &parts, state).await,
        }
    }

    /// What changed, held for each follower that wants it, once; a filtered follow hears only what it asked for.
    fn hold(&self, events: &[Event]) {
        if events.is_empty() {
            return;
        }
        let mut kept = self.kept.lock().unwrap();
        kept.sequences.retain(|s| now() - s.at <= 4 * QUIET);
        let sessions: Vec<String> = kept.follows.iter().map(|f| f.session.clone()).collect::<HashSet<_>>().into_iter().collect();
        for session in sessions {
            let follows: Vec<Follow> = kept.follows.iter().filter(|f| f.session == session).cloned().collect();
            let mine = mine_terms(&follows);
            let commits = merge_commits(&follows, &kept.targets);
            let mut wanted: Vec<Event> = vec![];
            for event in events {
                let covering: Vec<&Follow> = follows.iter().filter(|f| covers(&f.topic, &event.topic)).collect();
                if covering.is_empty() {
                    continue;
                }
                let texts = [event.summary.as_str(), &event.body, event.root.as_deref().unwrap_or("")];
                let filtered = covering.iter().all(|f| f.mine || !f.about.is_empty());
                let mut asked = !filtered
                    || covering.iter().any(|f| {
                        let terms: Vec<&str> = f
                            .about
                            .iter()
                            .map(String::as_str)
                            .chain(if f.mine { mine.iter().map(String::as_str).collect() } else { vec![] })
                            .collect();
                        passes(&terms, &texts) || (f.mine && names_commit(&commits, &texts))
                    });
                let mut event = event.clone();
                if filtered {
                    asked = continues(&mut kept.sequences, &session, &mut event, asked);
                }
                if !asked {
                    continue;
                }
                if let Some(dedupe) = &event.dedupe {
                    let seen = kept.seen.entry(session.clone()).or_default();
                    let mark = format!("{}#{dedupe}", event.topic);
                    if seen.contains(&mark) {
                        continue;
                    }
                    seen.push(mark);
                    if seen.len() > 500 {
                        seen.drain(..100);
                    }
                }
                wanted.push(event);
            }
            if !wanted.is_empty() {
                kept.held.entry(session).or_insert_with(|| (now(), vec![])).1.extend(wanted);
            }
        }
        self.keep(&kept);
    }

    /// What's held for each session goes when it's mid-turn (its queue joins them) or its window has passed: its own
    /// changes noted, the rest in one message that wakes it.
    fn flush(&self, idle: &impl Fn(&str) -> bool, tell: &impl Fn(&str, &str, Heard)) {
        let window = self.window.load(Ordering::Relaxed);
        let mut kept = self.kept.lock().unwrap();
        let due: Vec<String> =
            kept.held.iter().filter(|(s, (since, _))| !idle(s) || now() - since >= window).map(|(s, _)| s.clone()).collect();
        if due.is_empty() {
            return;
        }
        for session in due {
            let Some((_, events)) = kept.held.remove(&session) else { continue };
            let (mine, news): (Vec<&Event>, Vec<&Event>) = events.iter().partition(|e| self.own(&session, e));
            if !mine.is_empty() {
                let what: Vec<String> = mine.iter().map(|e| format!("{} {}", name(&e.topic), e.summary.trim())).collect();
                let s = if mine.len() == 1 { "" } else { "s" };
                tell(&session, &format!("Your own change{s} on what you follow, heard back: {}", what.join("; ")), Heard::Own);
            }
            if news.iter().all(|e| e.settled) && !news.is_empty() {
                let what: Vec<String> = news.iter().map(|e| line(e)).collect();
                tell(&session, &what.join("; "), Heard::Settled);
            } else if !news.is_empty() {
                let text = format(&news, |topic| kept.targets.get(&poll_key(topic)).map(|t| t.summary.clone()).unwrap_or_default());
                tell(&session, &text, Heard::News);
            }
        }
        self.keep(&kept);
    }
}

fn is_pr(topic: &str) -> bool {
    topic.starts_with("github/") && topic.split('/').count() == 4
}

/// A thing as a line names it: `repo#N` for a pull request, an issue by its id.
fn name(topic: &str) -> String {
    match topic.split('/').collect::<Vec<_>>()[..] {
        ["linear", issue, ..] => issue.to_string(),
        _ => short(topic),
    }
}

/// A topic as the conversation names it: `repo#N` for a pull request.
pub fn short(topic: &str) -> String {
    match topic.split('/').collect::<Vec<_>>()[..] {
        ["github", _, repo, number] => format!("{repo}#{number}"),
        _ => topic.to_string(),
    }
}

/// The pull request a finished step opened, if it opened one: `gh pr create` (the link it prints), a POST to a
/// repository's pulls API (`gh api repos/O/R/pulls`: its html_url), or an MCP tool creating one. A link a step only
/// mentions, or git push's offer to open one, isn't one. GitHub's, the forge `follow` reads pull requests from.
pub fn opened(kind: &ItemKind) -> Option<String> {
    let output = match kind {
        ItemKind::Command { command, output, exit_code, .. } if exit_code.is_none_or(|c| c == 0) && creates_pr(command) => output,
        ItemKind::Tool { name, output, .. } if name.to_lowercase().replace(['_', '-', '.'], "").contains("createpullrequest") => output,
        _ => return None,
    };
    // The API's answer names the pull request in html_url, before its body's links; gh pr create prints it last.
    match output.find("\"html_url\"") {
        Some(at) => pr_links(&output[at..]).into_iter().next(),
        None => pr_links(output).pop(),
    }
}

fn creates_pr(command: &str) -> bool {
    let words: Vec<&str> = command.split_whitespace().map(|w| w.trim_matches(['\'', '"'])).collect();
    words.windows(3).any(|w| w == ["gh", "pr", "create"])
        || command.split(['&', ';', '|', '\n']).any(|part| {
            let words: Vec<&str> = part.split_whitespace().map(|w| w.trim_matches(['\'', '"'])).collect();
            let Some(at) = words.windows(2).position(|w| w == ["gh", "api"]) else { return false };
            let words = &words[at + 2..];
            let pulls = words.iter().any(|w| {
                let path: Vec<&str> = w.split('?').next().unwrap_or("").trim_matches('/').split('/').collect();
                path.len() == 4 && path[0] == "repos" && path[3] == "pulls"
            });
            let method = words.iter().enumerate().find_map(|(i, w)| match *w {
                "-X" | "--method" => words.get(i + 1).map(|m| m.to_uppercase()),
                w => w.strip_prefix("-X").or_else(|| w.strip_prefix("--method=")).filter(|m| !m.is_empty()).map(str::to_uppercase),
            });
            let fields = words.iter().any(|w| ["-f", "-F", "--field", "--raw-field", "--input"].contains(w));
            pulls && method.map_or(fields, |m| m == "POST")
        })
}

/// The links to GitHub pull requests in a text, in order: `https://github.com/O/R/pull/N`.
fn pr_links(text: &str) -> Vec<String> {
    text.match_indices("https://github.com/")
        .filter_map(|(at, _)| {
            let parts: Vec<&str> = text[at + 19..].splitn(4, '/').collect();
            let number: String = parts.get(3)?.chars().take_while(char::is_ascii_digit).collect();
            let name = |p: &str| !p.is_empty() && p.chars().all(|c| c.is_alphanumeric() || "-_.".contains(c));
            (parts[2] == "pull" && name(parts[0]) && name(parts[1]) && !number.is_empty())
                .then(|| format!("https://github.com/{}/{}/pull/{number}", parts[0], parts[1]))
        })
        .collect()
}

/// What a message about one of the pull requests followed says: `repo#123`, `pull/123`, `#123`.
fn mine_terms(follows: &[Follow]) -> Vec<String> {
    follows
        .iter()
        .filter_map(|f| {
            let parts: Vec<&str> = f.topic.split('/').collect();
            (parts.len() == 4 && parts[0] == "github")
                .then(|| vec![format!("{}#{}", parts[2], parts[3]), format!("pull/{}", parts[3]), format!("#{}", parts[3])])
        })
        .flatten()
        .collect()
}

/// The merge commits of the pull requests followed, as read.
fn merge_commits(follows: &[Follow], targets: &BTreeMap<String, Target>) -> Vec<String> {
    follows
        .iter()
        .filter(|f| is_pr(&f.topic))
        .filter_map(|f| targets.get(&f.topic)?.state.as_ref()?["merge"].as_str().map(str::to_lowercase))
        .collect()
}

/// Whether a text names one of the commits, as much of its hash as it gives (seven digits or more).
fn names_commit(commits: &[String], texts: &[&str]) -> bool {
    texts.iter().flat_map(|t| t.split(|c: char| !c.is_alphanumeric())).any(|word| {
        let word = word.to_lowercase();
        slack::is_sha(&word) && commits.iter().any(|c| c.starts_with(&word))
    })
}

/// Whether `event` passes `session`'s filtered follow as part of an author's sequence, given whether it `matched`
/// itself: a message that matches starts one (or starts it again); the author's next in the same place continue it
/// (`after` says what), until they name something else, QUIET passes or SEQUENCE have.
fn continues(sequences: &mut Vec<Sequence>, session: &str, event: &mut Event, matched: bool) -> bool {
    if event.kind != "message" || event.root.is_some() || event.actor.is_empty() {
        return matched;
    }
    let at = if event.at > 0 { event.at } else { now() };
    let at_place = |s: &Sequence| s.session == session && s.topic == event.topic && s.actor == event.actor;
    let found = sequences.iter().position(at_place);
    if matched {
        let sequence = Sequence {
            session: session.into(),
            topic: event.topic.clone(),
            actor: event.actor.clone(),
            matched: first_line(&event.body, 120),
            at,
            count: 0,
        };
        match found {
            Some(i) => sequences[i] = sequence,
            None => sequences.push(sequence),
        }
        return true;
    }
    let Some(i) = found else { return false };
    let s = &mut sequences[i];
    if slack::cites(&event.body) || at - s.at > QUIET || s.count >= SEQUENCE {
        sequences.remove(i);
        return false;
    }
    (s.at, s.count) = (at, s.count + 1);
    event.after = Some(s.matched.clone());
    true
}

/// An event on a line: what it's on, what happened, its words' first line and what it continues.
fn line(e: &Event) -> String {
    let mut out = format!("{} {}", name(&e.topic), e.summary.trim());
    if !e.body.trim().is_empty() {
        out.push_str(&format!(": {}", first_line(&e.body, 120)))
    }
    if let Some(after) = &e.after {
        out.push_str(&format!(" (continuing: {})", first_line(after, 120)))
    }
    out
}

/// Any term in any text as a whole word, case ignored: `#124` doesn't match `#1240`.
pub fn passes(terms: &[&str], texts: &[&str]) -> bool {
    let word = |c: char| c.is_alphanumeric() || c == '_';
    terms.iter().map(|t| t.trim().to_lowercase()).filter(|t| !t.is_empty()).any(|term| {
        texts.iter().any(|text| {
            let text = text.to_lowercase();
            text.match_indices(&term).any(|(i, _)| {
                let before = text[..i].chars().next_back();
                let after = text[i + term.len()..].chars().next();
                !(before.is_some_and(word) && term.starts_with(word)) && !(after.is_some_and(word) && term.ends_with(word))
            })
        })
    })
}

/// The events as words for a session: grouped by topic under the line describing the thing, each with its summary,
/// its text (cut short when long) and its link.
pub fn format(events: &[&Event], describe: impl Fn(&str) -> String) -> String {
    let mut out = vec![format!("{} new event{} on what you follow:", events.len(), if events.len() == 1 { "" } else { "s" })];
    let mut topics: Vec<&str> = vec![];
    for e in events {
        if !topics.contains(&e.topic.as_str()) {
            topics.push(&e.topic)
        }
    }
    for topic in topics {
        let target = describe(topic);
        out.push(String::new());
        out.push(if target.is_empty() { topic.to_string() } else { format!("{topic}  —  {target}") });
        for e in events.iter().filter(|e| e.topic == topic) {
            let you = if e.mine { " (you: possibly your own action echoing back)" } else { "" };
            out.push(format!("  {}{you}", e.summary.trim()));
            if !e.body.trim().is_empty() {
                out.extend(clip(&e.body, 20, 2000).lines().map(|l| format!("    {l}")))
            }
            if let Some(after) = &e.after {
                out.push(format!("    (continues their earlier message: {})", first_line(after, 120)))
            }
            if !e.url.is_empty() && !target.contains(&e.url) {
                out.push(format!("    {}", e.url))
            }
        }
    }
    out.join("\n")
}

fn clip(text: &str, max_lines: usize, max_chars: usize) -> String {
    let mut text = text.replace("\r\n", "\n").trim().to_string();
    if text.chars().count() > max_chars {
        text = text.chars().take(max_chars).collect::<String>().trim_end().to_string() + " …"
    }
    let lines: Vec<&str> = text.lines().collect();
    if lines.len() > max_lines { format!("{}\n… ({} more lines)", lines[..max_lines].join("\n"), lines.len() - max_lines) } else { text }
}

/// The lines that went and came between two texts, `-` and `+`, up to 40 of them.
/// ponytail: lines by set difference, not a real diff; good enough for a description's edit.
pub fn text_diff(old: &str, new: &str) -> String {
    let (before, after): (Vec<&str>, Vec<&str>) = (old.lines().collect(), new.lines().collect());
    let mut lines: Vec<String> = before.iter().filter(|l| !after.contains(l)).map(|l| format!("-{l}")).collect();
    lines.extend(after.iter().filter(|l| !before.contains(l)).map(|l| format!("+{l}")));
    if lines.len() > 40 {
        let more = lines.len() - 40;
        lines.truncate(40);
        lines.push(format!("... ({more} more diff lines)"))
    }
    lines.join("\n")
}

pub fn first_line(text: &str, limit: usize) -> String {
    let line = text.trim().lines().next().unwrap_or("");
    if line.chars().count() <= limit { line.to_string() } else { format!("{}…", line.chars().take(limit - 1).collect::<String>()) }
}
