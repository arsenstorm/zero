//! The board: every task Zero runs on one screen, one row each. A row is a lead session with its workers folded in: what
//! the work is, where it runs, its state, where the agent is now and what it needs from the user. Made from the sessions
//! and the inbox, so it reads the same in every client.

use std::collections::HashMap;
use std::sync::Mutex;

use serde::Serialize;

use crate::ask::{Ask, AskKind, AskState};
use crate::model::{Attention, Conversation, ItemKind, Queued};

/// Most urgent first: the board sorts by it.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// Stopped because of the user: a question, approval or run waits for their answer, or a turn ended asking them.
    NeedsYou,
    /// Failing, stuck or out of usage, on its own.
    Trouble,
    Working,
    /// Over to the user: done, with a step only they can take (its note's `needs`: merge, deploy, check). A to-do, not a
    /// decision.
    Handed,
    /// It answered the user and waits on nothing: Replied, until the user has read it.
    Answered,
    /// Waiting on someone or something that isn't the user (CI, a deploy, QA, a review, an outage): nothing they can
    /// do, so it sorts low. Blocked, as agents said it before.
    Waiting,
    /// Put on hold by the user (daemon.rs `pause`), until they resume it.
    Paused,
    /// It answered the user, who has seen the answer: Replied still, but nothing waits on them.
    Read,
    /// Finished end to end, by its ending or note (`--done`; `--completed` and `--merged` as it was): merged and
    /// deployed, verified, or the user said so; a review, CI or QA still to come is Waiting. Last of all, and put
    /// away (Settings › archiveCompleted; a worker once its lead has its report); something it follows brings it back.
    Done,
    Idle,
    Offline,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    /// The lead session.
    pub session: String,
    pub task: String,
    /// The workspace it is in (workspaces.rs).
    #[serde(default = "default_workspace")]
    pub workspace: String,
    pub ticket: Option<String>,
    /// Where it runs: the name the task was given, else the places command's for its ticket, else the shortest end of
    /// its folder that tells it from the other rows' ("blue-fox/api").
    pub place: String,
    /// Where that place is on disk, when the places command says (a worktree's folder): what opening it opens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// Offline, `state` is the one it was last known in.
    pub online: bool,
    /// The team's: the lead's own, raised by a worker's that needs attention. What the row sorts by.
    pub state: State,
    /// The lead's own, its workers left out: what its icon shows, so a lead at work isn't shown waiting on the user
    /// because a worker is.
    pub own: State,
    /// Where the agent is: its latest note, else its last answer's first line.
    pub now: Option<String>,
    /// What the agent handed to the user, by its latest note.
    pub needs: Option<String>,
    /// The open asks of the lead and its workers.
    pub asks: Vec<Waiting>,
    pub workers: usize,
    /// Each of its workers (theirs too) as it is itself, by the same rules: what a worker's own status is.
    pub team: Vec<Member>,
    /// The user's messages waiting for after the current turn, in order; `held`, they wait for the user's say.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub queued: Vec<Queued>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub held: bool,
    /// When it next wakes itself (`zero schedule`), in seconds since 1970.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wakes: Option<i64>,
    /// A change picked mid-turn, for its next turn (model, permissions).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next: Option<crate::model::Next>,
    /// Its last turn was Zero's (an event it follows, a worker's report, a wake-up), not the user's: a reply to it is
    /// shown (unread, if it is) but not announced.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub quiet: bool,
    /// The issues it drives, a row each (`zero issue`): those on the user first, then by who has them.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub issues: Vec<crate::model::Issue>,
}

/// A worker on a lead's row: its own state, where it runs, where it is and what it needs.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    pub session: String,
    pub state: State,
    pub place: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub now: Option<String>,
    pub needs: Option<String>,
    /// Its own open asks (and its workers').
    pub asks: Vec<Waiting>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub queued: Vec<Queued>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub held: bool,
}

/// A session's standing, with its workers counted in: what a row and a member say.
struct Standing {
    state: State,
    online: bool,
    now: Option<String>,
    needs: Option<String>,
    asks: Vec<Waiting>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Waiting {
    pub id: String,
    pub title: String,
}

/// The notes zerod posts itself to follow a session's attention (bridge.rs), told from the agent's own.
pub const ATTENTION: &str = "attention";

pub fn board(conversations: &[Conversation], asks: &[Ask]) -> Vec<Row> { board_with(conversations, asks, &HashMap::new()) }

/// The board, with where tasks run by ticket from the user's places command.
pub fn board_with(conversations: &[Conversation], asks: &[Ask], places: &HashMap<String, Place>) -> Vec<Row> {
    board_full(conversations, asks, places, &HashMap::new())
}

/// The board with each session's queue (daemon.rs `queues`).
fn default_workspace() -> String { crate::workspaces::DEFAULT.into() }

pub fn board_full(conversations: &[Conversation], asks: &[Ask], places: &HashMap<String, Place>, queues: &HashMap<String, (Vec<Queued>, bool)>) -> Vec<Row> {
    board_in(conversations, asks, places, queues, &|_| default_workspace())
}

/// `workspace_of` says which workspace each lead is in.
pub fn board_in(conversations: &[Conversation], asks: &[Ask], places: &HashMap<String, Place>, queues: &HashMap<String, (Vec<Queued>, bool)>,
                workspace_of: &dyn Fn(&Conversation) -> String) -> Vec<Row> {
    let queue = |id: &str| queues.get(id).cloned().unwrap_or_default();
    let known = |id: &Option<String>| id.as_ref().is_some_and(|id| conversations.iter().any(|c| &c.id == id));
    let leads: Vec<&Conversation> = conversations.iter().filter(|c| !known(&c.parent)).collect();
    // Where a session runs: the name it was given, else the places command's for its ticket, else the shortest end of
    // its folder that tells the leads' apart.
    let folders: Vec<String> = leads.iter().map(|lead| lead.cwd.clone()).collect();
    let whereabouts = |c: &Conversation| -> (String, Option<String>) {
        if let Some(named) = &c.place { return (named.clone(), None) }
        match c.ticket.as_ref().and_then(|t| places.get(t)) {
            Some(listed) => (listed.name.clone(), listed.path.clone()),
            None => (place(&c.cwd, &folders), None),
        }
    };
    let mut rows: Vec<Row> = leads.iter().map(|lead| {
        let team = team(lead, conversations);
        let its = standing(lead, conversations, asks);
        let own = standing(lead, std::slice::from_ref(*lead), asks).state;
        let (place, path) = whereabouts(lead);
        let members = team[1..].iter().map(|member| {
            let own = standing(member, conversations, asks);
            let (place, path) = whereabouts(member);
            let (queued, held) = queue(&member.id);
            Member { session: member.id.clone(), state: own.state, place, path, now: own.now, needs: own.needs, asks: own.asks, queued, held }
        }).collect();
        let (queued, held) = queue(&lead.id);
        Row {
            session: lead.id.clone(), task: crate::bridge::label(lead), workspace: workspace_of(lead), ticket: lead.ticket.clone(), place, path, online: its.online,
            state: its.state, own, now: its.now, needs: its.needs, asks: its.asks, workers: team.len() - 1, team: members, queued, held, wakes: None, next: None,
            quiet: lead.items.iter().rev().find_map(|i| match &i.kind { ItemKind::User { text, .. } => Some(text.starts_with(crate::model::FROM)), _ => None }).unwrap_or(false),
            issues: { let mut issues = lead.issues.clone(); issues.sort_by_key(|i| (i.state, i.since)); issues },
        }
    }).collect();
    rows.sort_by_key(|row| row.state);
    rows
}

/// A reply is read once the user has seen it (`seen`: that answer's item, and when) and it's still the latest. The apps
/// tell zerod when a task is opened, and when the user does something in the one they're on (a reply arriving while
/// it's open isn't seen until then).
pub fn read(seen: Option<(&str, i64)>, latest: Option<&str>, now: i64) -> bool {
    seen.is_some_and(|(answer, at)| Some(answer) == latest && at <= now)
}

/// The rows whose reply the user has read: Read rather than Replied, on every client alike.
pub fn mark_read(rows: &mut [Row], read: &dyn Fn(&str) -> bool) {
    for row in rows.iter_mut().filter(|r| (r.state == State::Answered || r.own == State::Answered) && read(&r.session)) {
        if row.state == State::Answered { row.state = State::Read }
        if row.own == State::Answered { row.own = State::Read }
    }
    rows.sort_by_key(|row| row.state);
}

/// The done tasks due to be archived: those done for `after` seconds (never, with none), counted from when each said so
/// (`said`, in seconds: its last answer or note), so no restart starts the clock again. One not known to have said so
/// isn't due.
pub fn due_to_archive(rows: &[Row], now: i64, after: Option<i64>, said: &dyn Fn(&str) -> Option<i64>) -> Vec<String> {
    let Some(after) = after else { return vec![] };
    let mut due: Vec<String> = rows.iter().filter(|r| r.state == State::Done && r.own == State::Done)
        .filter(|r| said(&r.session).is_some_and(|at| now - at >= after)).map(|r| r.session.clone()).collect();
    due.sort();
    due
}

/// The rows of tasks the user paused, and their paused workers, shown as Paused whatever they were doing.
pub fn mark_paused(rows: &mut [Row], paused: &dyn Fn(&str) -> bool) {
    for row in rows.iter_mut() {
        for member in row.team.iter_mut().filter(|m| paused(&m.session)) { member.state = State::Paused }
        if paused(&row.session) { row.state = State::Paused; row.own = State::Paused }
    }
    rows.sort_by_key(|row| row.state);
}

/// A session's state with its workers counted in (the most urgent of them, an open ask making it the user's), then
/// its own note, else how it ended its turn; where it is, and what it needs.
fn standing(session: &Conversation, conversations: &[Conversation], asks: &[Ask]) -> Standing {
    let team = team(session, conversations);
    let own = note(session, asks);
    let open: Vec<Waiting> = asks.iter()
        .filter(|a| a.state == AskState::Waiting && !matches!(a.kind, AskKind::Note | AskKind::Message) && team.iter().any(|c| is(a, c)))
        .map(|a| Waiting { id: a.id.clone(), title: a.title.clone() }).collect();
    let online = team.iter().any(|c| c.attention() != Attention::Offline);
    // Its own standing, raised by a worker's only when that needs attention: a worker finished says nothing about
    // the lead.
    let mut state = team.iter().skip(1).map(|c| attention(c)).filter(|s| *s <= State::Working).min().unwrap_or(State::Idle).min(attention(session));
    if !open.is_empty() { state = State::NeedsYou }
    // An issue its agent says is on the user (`zero issue … you`): the task needs them, as an ask would.
    if session.issues.iter().any(|i| i.state == crate::model::IssueState::You) { state = state.min(State::NeedsYou) }
    // Ended on an ask that's no longer open (answered, withdrawn, expired), its question no longer anyone's: what it
    // said is a reply to read. Agents repeat the ending through later turns, long after the answer came.
    if state == State::NeedsYou && open.is_empty() && session.questions.is_empty() && session.approvals.is_empty()
        && team.iter().skip(1).all(|c| attention(c) != State::NeedsYou)
        && let Some(id) = session.answer().and_then(asked)
        && asks.iter().any(|a| a.id == id && a.state.is_final()) {
        state = State::Answered;
    }
    if let Some(note) = own && state > State::Trouble {
        state = match note.status.as_deref() {
            // Waiting on what isn't the user (what needs them is an ask).
            Some("blocked" | "waiting") => State::Waiting,
            _ if state == State::Working => state,
            _ if note.needs.is_some() => State::Handed,
            Some("done" | "completed" | "merged") => State::Done,
            _ => state,
        };
    }
    // No note of its own this turn: how it ended its turn (Zero's ending, "[zero: done]") says its state.
    if own.is_none() && matches!(state, State::Idle | State::Done) && let Some(ending) = session.answer().and_then(ending) {
        state = match ending {
            "done" => State::Done,
            // Between steps, its work going on elsewhere: a reply to read, as any.
            "working" => State::Answered,
            "waiting" => State::Waiting,
            _ => State::NeedsYou, // asked: it waits on the user's answer
        };
    }
    // Its first line of prose: a table, heading or rule says nothing on its own; a list's item without its marker.
    let prose = |l: &&str| !l.is_empty() && !l.starts_with('|') && !l.starts_with('#') && !l.starts_with("---") && !l.starts_with("[zero:");
    let answer = session.answer().and_then(|a| a.lines().map(str::trim).find(prose)).map(|line| unlisted(line).to_string());
    Standing { state, online, now: own.map(|n| n.body.clone()).filter(|b| !b.is_empty()).or(answer), needs: own.and_then(|n| n.needs.clone()), asks: open }
}

/// The ending Zero has an agent close its turn with, when it's the answer's last line: "done", "waiting", "working",
/// or "asked" (its ask's id dropped). "completed" and "blocked", as agents said them before, are "done" and "waiting".
/// The ask an answer's ending waits on: `[zero: asked <id>]`'s id.
fn asked(answer: &str) -> Option<&str> {
    answer.trim_end().lines().last()?.trim().strip_prefix("[zero: asked ")?.strip_suffix(']').map(str::trim)
}

/// A line without its list marker ("- ", "* ", "3. "), if it has one.
fn unlisted(line: &str) -> &str {
    if let Some(rest) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) { return rest.trim_start() }
    let digits = line.len() - line.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    if digits > 0 && let Some(rest) = line[digits..].strip_prefix(". ") { return rest.trim_start() }
    line
}

/// Whether an answer ends on a question to the user: one of its last few lines of prose (Zero's ending, headings and
/// table rows aside) ends with "?".
pub fn asks_in_prose(answer: &str) -> bool {
    answer.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with("[zero:") && !l.starts_with('#') && !l.starts_with('|')).rev().take(3)
        .any(|l| l.trim_end_matches(['*', '_', ')', '"']).ends_with('?'))
}

/// The answer without Zero's ending line, for reading.
pub fn without_ending(answer: &str) -> &str {
    let trimmed = answer.trim_end();
    match (ending(trimmed), trimmed.rsplit_once('\n')) {
        (Some(_), Some((before, _))) => before.trim_end(),
        (Some(_), None) => "",
        (None, _) => answer,
    }
}

pub fn ending(answer: &str) -> Option<&'static str> {
    let last = answer.trim_end().lines().last()?.trim();
    let inner = last.strip_prefix("[zero: ")?.strip_suffix(']')?;
    match inner.split_whitespace().next()? {
        "done" | "completed" => Some("done"),
        "waiting" | "blocked" => Some("waiting"),
        "working" => Some("working"),
        "asked" => Some("asked"),
        _ => None,
    }
}

/// Where a ticket's task runs, by the places command: its name, and its folder when the command gives one.
#[derive(Clone, Debug, PartialEq)]
pub struct Place {
    pub name: String,
    pub path: Option<String>,
}

/// What the places command printed, `[{"ticket": "ENG-1", "place": "green-elk", "path": "/…"}, …]` (path optional), by
/// ticket; a ticket in several places has them all, and then no one path.
pub fn parse_places(text: &str) -> Result<HashMap<String, Place>, String> {
    #[derive(serde::Deserialize)]
    struct Entry { ticket: String, place: String, path: Option<String> }
    let entries: Vec<Entry> = serde_json::from_str(text).map_err(|e| format!("The places command printed something other than [{{\"ticket\", \"place\"}}]: {e}"))?;
    let mut places: HashMap<String, Place> = HashMap::new();
    for entry in entries {
        places.entry(entry.ticket)
            .and_modify(|all| { all.name.push_str(", "); all.name.push_str(&entry.place); all.path = None })
            .or_insert(Place { name: entry.place, path: entry.path });
    }
    Ok(places)
}

/// Where tasks run by ticket, as the places command last said.
#[derive(Default)]
pub struct Places(Mutex<HashMap<String, Place>>);

impl Places {
    pub fn get(&self) -> HashMap<String, Place> { self.0.lock().unwrap().clone() }

    /// Runs the user's places command (zerod's settings.json `places`) every five minutes while zerod runs: a place
    /// changes rarely, and the command may be slow (one may ask GitHub for each place's PR).
    pub async fn follow(self: std::sync::Arc<Self>, home: std::path::PathBuf) {
        use crate::integrations::Fetcher;
        loop {
            if let Some(command) = crate::server::Settings::load(&home).places.filter(|c| !c.trim().is_empty()) {
                let argv = crate::adapter::login_shell(&["/bin/sh", "-c", &command]);
                match crate::integrations::Commands::default().run(argv, None).await.and_then(|text| parse_places(&text)) {
                    Ok(places) => *self.0.lock().unwrap() = places,
                    Err(error) => eprintln!("zerod: places: {error}"),
                }
            } else {
                self.0.lock().unwrap().clear();
            }
            tokio::time::sleep(std::time::Duration::from_secs(300)).await;
        }
    }
}

/// The lead and every session it started, and theirs.
fn team<'a>(lead: &'a Conversation, all: &'a [Conversation]) -> Vec<&'a Conversation> {
    let mut team = vec![lead];
    let mut i = 0;
    while i < team.len() {
        let started: Vec<&Conversation> = all.iter().filter(|c| c.parent.as_ref() == Some(&team[i].id) && !team.iter().any(|t| t.id == c.id)).collect();
        team.extend(started);
        i += 1;
    }
    team
}

fn is(ask: &Ask, conversation: &Conversation) -> bool {
    ask.agent.reference.as_deref() == Some(&conversation.id) || ask.agent.name == format!("zerod-{}", conversation.id)
}

/// The agent's latest own note, unless a turn started after it (zerod notes each new turn, and what the note said was
/// about the last one) or it was closed since.
fn note<'a>(conversation: &Conversation, asks: &'a [Ask]) -> Option<&'a Ask> {
    let notes = asks.iter().filter(|a| a.kind == AskKind::Note && is(a, conversation));
    // When the user last said something themselves (not Zero passing on an event, a worker's report, a wake-up).
    let spoke = conversation.items.iter().filter_map(|i| match &i.kind {
        ItemKind::User { text, .. } if !text.starts_with(crate::model::FROM) => i.at.map(|ms| ms / 1000), _ => None }).max();
    let mut own: Option<&Ask> = None;
    for note in notes {
        // Closed, by the user or its runtime: nothing it said still stands.
        // zerod's own "Offline" dot is no closing: a restart takes every session offline.
        let ours = note.request.as_deref() == Some(ATTENTION);
        let closed = !ours && note.status.as_deref() == Some("closed");
        // A new turn clears what it said, except that done or merged stands through turns Zero started (an event it
        // follows, a worker's report): only the user's own word since makes it theirs to settle again.
        let final_state = own.is_some_and(|n| matches!(n.status.as_deref(), Some("done" | "merged" | "completed")) && spoke.is_none_or(|at| at < n.created_at.0));
        if closed || (ours && note.status.is_none() && !final_state) { own = None } else if !ours { own = Some(note) }
    }
    own
}

fn attention(conversation: &Conversation) -> State {
    match conversation.attention() {
        Attention::NeedsYou => State::NeedsYou,
        Attention::Limited | Attention::Stuck | Attention::Failed => State::Trouble,
        Attention::Blocked => State::Waiting,
        Attention::Working | Attention::Starting => State::Working,
        Attention::Done => State::Done,
        Attention::Answered => State::Answered,
        Attention::Idle => State::Idle,
        // Offline is only not running (parked while it waited): it's as its last turn left it, a question still open.
        Attention::Offline => match conversation.ended() {
            Attention::NeedsYou => State::NeedsYou,
            Attention::Done => State::Done,
            Attention::Blocked => State::Waiting,
            Attention::Answered => State::Answered,
            _ => State::Idle,
        },
    }
}

/// The fewest trailing parts of `folder` that no other folder in `all` ends with.
fn place(folder: &str, all: &[String]) -> String {
    let parts: Vec<&str> = folder.split('/').filter(|p| !p.is_empty()).collect();
    let tail = |path: &str, n: usize| { let p: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect(); p[p.len().saturating_sub(n)..].join("/") };
    (1..=parts.len().max(1))
        .map(|n| tail(folder, n))
        .find(|end| all.iter().filter(|other| other.as_str() != folder).all(|other| tail(other, end.matches('/').count() + 1) != *end))
        .unwrap_or_else(|| parts.join("/"))
}
