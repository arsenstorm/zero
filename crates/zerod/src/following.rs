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

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use crate::now;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::broadcast;

use crate::integrations::{Fetcher, Integrations};

pub mod github;
pub mod linear;
pub mod slack;

/// After this many polls failing in a row, followers hear of it (once), and once more when polling works again.
pub const REPORT_FAILS: u32 = 3;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Follow {
    pub session: String,
    pub topic: String,
    /// Only events that name a pull request the session follows (`repo#N`, `pull/N`, `#N`): a busy channel's share.
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
}

/// Something that changed on a followed thing.
#[derive(Clone, Debug, Default, PartialEq)]
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
    /// For a channel message that names nothing (no pull request, ticket or link): the sender's last message that did,
    /// within the half hour, which this one continues: a deploy bot's "Deploy complete" after its "Deploying … (#42)".
    pub after: Option<String>,
}

/// One poll's outcome: the fresh reading, the events since the last, and the line describing the thing.
pub struct Poll { pub state: Value, pub events: Vec<Event>, pub summary: String }

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
enum Source { GitHub, Linear, Slack }

impl Source {
    fn of(topic: &str) -> Result<Source, String> {
        match topic.split('/').next() {
            Some("github") => Ok(Source::GitHub),
            Some("linear") => Ok(Source::Linear),
            Some("slack") => Ok(Source::Slack),
            _ => Err(format!("Not a topic Zero can follow: {topic} (github/<owner>/<repo>/<pr>, linear/<ISSUE>[/<thread>], slack/<channel>[/<thread-ts>], or a URL)")),
        }
    }
    /// Seconds between polls of one key, and the least between any two polls of this source (its rate limit's share):
    /// with n keys followed each is polled at most every n × spacing seconds.
    fn interval(self) -> i64 { match self { Source::Slack => 30, _ => 60 } }
    fn spacing(self) -> i64 { match self { Source::GitHub => 2, _ => 3 } }
}

/// The canonical topic for what was given: a topic as typed, or a GitHub, Linear or Slack URL.
pub fn topic(given: &str) -> Result<String, String> {
    let given = given.trim().trim_matches('/');
    let given = github::from_url(given).or_else(|| linear::from_url(given)).or_else(|| slack::from_url(given)).unwrap_or_else(|| given.to_string());
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

fn covers(follow: &str, topic: &str) -> bool { topic == follow || topic.strip_prefix(follow).is_some_and(|rest| rest.starts_with('/')) }

pub struct Following {
    file: PathBuf,
    fetcher: Arc<dyn Fetcher>,
    integrations: Arc<Integrations>,
    kept: Mutex<Kept>,
    /// Fires when follows or targets change, for the app.
    pub changed: broadcast::Sender<()>,
}

impl Following {
    pub fn open(home: &Path, fetcher: Arc<dyn Fetcher>, integrations: Arc<Integrations>) -> Arc<Following> {
        let file = home.join("following.json");
        let kept = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        Arc::new(Following { file, fetcher, integrations, kept: Mutex::new(kept), changed: broadcast::channel(16).0 })
    }

    fn keep(&self, kept: &Kept) {
        if let Ok(data) = serde_json::to_vec(kept) { let _ = std::fs::write(&self.file, data); }
        let _ = self.changed.send(());
    }

    /// Every follow, or one session's, with how each followed thing is doing.
    pub fn list(&self, session: Option<&str>) -> Vec<Followed> {
        let kept = self.kept.lock().unwrap();
        kept.follows.iter().filter(|f| session.is_none_or(|s| f.session == s)).map(|f| {
            let target = kept.targets.get(&poll_key(&f.topic)).cloned().unwrap_or_default();
            Followed { follow: f.clone(), summary: target.summary, error: target.error, last_poll: target.last_poll, new: false, detail: String::new() }
        }).collect()
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
                if !kept.follows.iter().any(|f| poll_key(&f.topic) == key) { kept.targets.remove(&key); }
                return Err(format!("Can't follow {key}: {error}"));
            }
        }
        let (topic, detail) = {
            let kept = self.kept.lock().unwrap();
            let state = kept.targets.get(&key).and_then(|t| t.state.as_ref()).ok_or_else(|| format!("Can't follow {key}: nothing read yet, try again"))?;
            match source { Source::Linear => linear::resolve(&topic, state)?, _ => (topic.clone(), String::new()) }
        };
        let mut kept = self.kept.lock().unwrap();
        let new = !kept.follows.iter().any(|f| f.session == session && f.topic == topic);
        kept.follows.retain(|f| !(f.session == session && f.topic == topic));
        kept.follows.push(Follow { session: session.into(), topic: topic.clone(), mine, about, at: now() });
        self.keep(&kept);
        let target = kept.targets.get(&key).cloned().unwrap_or_default();
        Ok(Followed { follow: kept.follows.last().unwrap().clone(), summary: target.summary, error: target.error, last_poll: target.last_poll, new, detail })
    }

    /// Takes back a session's follows: the topics named (as given, or as canonical), or all of them. How many went.
    pub fn unfollow(&self, session: &str, topics: Option<&[String]>) -> usize {
        let wanted: Option<Vec<String>> = topics.map(|ts| ts.iter().map(|t| topic(t).unwrap_or_else(|_| t.trim().trim_matches('/').to_string())).collect());
        let mut kept = self.kept.lock().unwrap();
        let before = kept.follows.len();
        kept.follows.retain(|f| f.session != session || wanted.as_ref().is_some_and(|w| !w.iter().any(|t| *t == f.topic || linear::same_thread(t, &f.topic))));
        kept.seen.remove(session);
        let removed = before - kept.follows.len();
        if removed > 0 { self.prune(&mut kept); self.keep(&kept); }
        removed
    }

    /// Have everything polled on the next tick.
    pub fn hurry(&self) {
        let mut kept = self.kept.lock().unwrap();
        for target in kept.targets.values_mut() { target.next_poll = 0 }
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
    /// changed. `alive` says whether a session still exists; `tell` gives a session words.
    pub async fn tick(&self, alive: impl Fn(&str) -> bool, tell: impl Fn(&str, &str)) {
        let due: Vec<String> = {
            let mut kept = self.kept.lock().unwrap();
            let before = kept.follows.len();
            kept.follows.retain(|f| alive(&f.session));
            if kept.follows.len() != before { self.prune(&mut kept); self.keep(&kept); }
            let now = now();
            kept.targets.iter().filter(|(_, t)| t.next_poll <= now).map(|(k, _)| k.clone()).collect()
        };
        // ponytail: one after another; poll several at once if a tick gets slow with many follows.
        let mut events = vec![];
        for key in due { events.extend(self.poll(&key).await) }
        // Everything a tick found goes to each follower as one message, however many things changed.
        self.deliver(&events, &tell);
    }

    /// Polls `key`, keeps the reading, and gives the events (polling trouble included).
    async fn poll(&self, key: &str) -> Vec<Event> {
        let (state, fails) = { let kept = self.kept.lock().unwrap(); let t = kept.targets.get(key).cloned().unwrap_or_default(); (t.state, t.fails) };
        let source = match Source::of(key) { Ok(source) => source, Err(_) => return vec![] };
        let interval = self.interval(source);
        let result = self.fetch(source, key, state.as_ref()).await;
        let mut kept = self.kept.lock().unwrap();
        let target = kept.targets.entry(key.into()).or_default();
        let before = (target.state.clone(), target.summary.clone(), target.error.clone(), target.fails);
        let mut events = vec![];
        match result {
            Ok(poll) => {
                if state.is_some() { events = poll.events }
                if fails >= REPORT_FAILS { events.push(Event { topic: key.into(), kind: "recovered".into(), summary: "polling works again".into(), ..Default::default() }) }
                *target = Target { state: Some(poll.state), summary: poll.summary, last_poll: now(), next_poll: now() + interval, error: None, fails: 0 };
            }
            Err(error) => {
                eprintln!("zerod: following {key}: {error}");
                target.fails = fails + 1;
                target.next_poll = now() + (interval << fails.min(6)).min(900);
                target.error = Some(error.clone());
                if state.is_some() && target.fails == REPORT_FAILS {
                    events.push(Event { topic: key.into(), kind: "error".into(), summary: format!("polling is failing: {error}"), ..Default::default() });
                }
            }
        }
        // Written only when what it found is new: the times of the polls aren't worth the file (hundreds of kilobytes
        // with many things followed) after every poll of every one; lost with a restart, it's polled again, early.
        if (target.state.clone(), target.summary.clone(), target.error.clone(), target.fails) != before { self.keep(&kept) }
        events
    }

    async fn fetch(&self, source: Source, key: &str, state: Option<&Value>) -> Result<Poll, String> {
        let parts: Vec<&str> = key.split('/').skip(1).collect();
        match source {
            Source::GitHub => {
                let argv = crate::adapter::login_shell(&github::argv(&parts).iter().map(String::as_str).collect::<Vec<_>>());
                let reply: Value = serde_json::from_str(&self.fetcher.run(argv, None).await?).map_err(|e| format!("gh answered oddly: {e}"))?;
                github::poll(&reply, state, key)
            }
            Source::Linear => linear::poll(&self.integrations.linear(linear::query(parts[0])).await?, state, key),
            Source::Slack => slack::poll(&self.integrations, &parts, state).await,
        }
    }

    /// Each follower of what changed hears of it, once, in one message per poll; a filtered follow hears only what
    /// it asked for.
    fn deliver(&self, events: &[Event], tell: &impl Fn(&str, &str)) {
        if events.is_empty() { return }
        let mut kept = self.kept.lock().unwrap();
        let sessions: Vec<String> = kept.follows.iter().map(|f| f.session.clone()).collect::<HashSet<_>>().into_iter().collect();
        for session in sessions {
            let follows: Vec<Follow> = kept.follows.iter().filter(|f| f.session == session).cloned().collect();
            let mine = mine_terms(&follows);
            let mut wanted: Vec<&Event> = vec![];
            for event in events {
                let covering = follows.iter().filter(|f| covers(&f.topic, &event.topic));
                let asked = covering.into_iter().any(|f| {
                    if !f.mine && f.about.is_empty() { return true }
                    let terms: Vec<&str> = f.about.iter().map(String::as_str).chain(if f.mine { mine.iter().map(String::as_str).collect() } else { vec![] }).collect();
                    passes(&terms, &[&event.summary, &event.body, event.root.as_deref().unwrap_or(""), event.after.as_deref().unwrap_or("")])
                });
                if !asked { continue }
                if let Some(dedupe) = &event.dedupe {
                    let seen = kept.seen.entry(session.clone()).or_default();
                    let mark = format!("{}#{dedupe}", event.topic);
                    if seen.contains(&mark) { continue }
                    seen.push(mark);
                    if seen.len() > 500 { seen.drain(..100); }
                }
                wanted.push(event);
            }
            if wanted.is_empty() { continue }
            let text = format(&wanted, |topic| kept.targets.get(&poll_key(topic)).map(|t| t.summary.clone()).unwrap_or_default());
            tell(&session, &text);
        }
        self.keep(&kept);
    }
}

/// What a message about one of the pull requests followed says: `repo#123`, `pull/123`, `#123`.
fn mine_terms(follows: &[Follow]) -> Vec<String> {
    follows.iter().filter_map(|f| {
        let parts: Vec<&str> = f.topic.split('/').collect();
        (parts.len() == 4 && parts[0] == "github").then(|| vec![format!("{}#{}", parts[2], parts[3]), format!("pull/{}", parts[3]), format!("#{}", parts[3])])
    }).flatten().collect()
}

/// Any term in any text as a whole word, case ignored: `#124` doesn't match `#1240`.
pub fn passes(terms: &[&str], texts: &[&str]) -> bool {
    let word = |c: char| c.is_alphanumeric() || c == '_';
    terms.iter().map(|t| t.trim().to_lowercase()).filter(|t| !t.is_empty()).any(|term| texts.iter().any(|text| {
        let text = text.to_lowercase();
        text.match_indices(&term).any(|(i, _)| {
            let before = text[..i].chars().next_back();
            let after = text[i + term.len()..].chars().next();
            !(before.is_some_and(word) && term.starts_with(word)) && !(after.is_some_and(word) && term.ends_with(word))
        })
    }))
}

/// The events as words for a session: grouped by topic under the line describing the thing, each with its summary,
/// its text (cut short when long) and its link.
pub fn format(events: &[&Event], describe: impl Fn(&str) -> String) -> String {
    let mut out = vec![format!("{} new event{} on what you follow:", events.len(), if events.len() == 1 { "" } else { "s" })];
    let mut topics: Vec<&str> = vec![];
    for e in events { if !topics.contains(&e.topic.as_str()) { topics.push(&e.topic) } }
    for topic in topics {
        let target = describe(topic);
        out.push(String::new());
        out.push(if target.is_empty() { topic.to_string() } else { format!("{topic}  —  {target}") });
        for e in events.iter().filter(|e| e.topic == topic) {
            let you = if e.mine { " (you: possibly your own action echoing back)" } else { "" };
            out.push(format!("  {}{you}", e.summary.trim()));
            if !e.body.trim().is_empty() { out.extend(clip(&e.body, 20, 2000).lines().map(|l| format!("    {l}"))) }
            if let Some(after) = &e.after { out.push(format!("    (continues their earlier message: {})", first_line(after, 120))) }
            if !e.url.is_empty() && !target.contains(&e.url) { out.push(format!("    {}", e.url)) }
        }
    }
    out.join("\n")
}

fn clip(text: &str, max_lines: usize, max_chars: usize) -> String {
    let mut text = text.replace("\r\n", "\n").trim().to_string();
    if text.chars().count() > max_chars { text = text.chars().take(max_chars).collect::<String>().trim_end().to_string() + " …" }
    let lines: Vec<&str> = text.lines().collect();
    if lines.len() > max_lines { format!("{}\n… ({} more lines)", lines[..max_lines].join("\n"), lines.len() - max_lines) } else { text }
}

/// The lines that went and came between two texts, `-` and `+`, up to 40 of them.
/// ponytail: lines by set difference, not a real diff; good enough for a description's edit.
pub fn text_diff(old: &str, new: &str) -> String {
    let (before, after): (Vec<&str>, Vec<&str>) = (old.lines().collect(), new.lines().collect());
    let mut lines: Vec<String> = before.iter().filter(|l| !after.contains(l)).map(|l| format!("-{l}")).collect();
    lines.extend(after.iter().filter(|l| !before.contains(l)).map(|l| format!("+{l}")));
    if lines.len() > 40 { let more = lines.len() - 40; lines.truncate(40); lines.push(format!("... ({more} more diff lines)")) }
    lines.join("\n")
}

pub fn first_line(text: &str, limit: usize) -> String {
    let line = text.trim().lines().next().unwrap_or("");
    if line.chars().count() <= limit { line.to_string() } else { format!("{}…", line.chars().take(limit - 1).collect::<String>()) }
}

