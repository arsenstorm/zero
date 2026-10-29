//! The board: every task Zero runs on one screen, one row each. A row is a lead session with its workers folded in: what
//! the work is, where it runs, its state, where the agent is now and what it needs from the user. Made from the sessions
//! and the inbox, so it reads the same in every client.

use std::collections::HashMap;
use std::sync::Mutex;

use serde::Serialize;

use crate::ask::{Ask, AskKind, AskState};
use crate::model::{Attention, Conversation};

/// Most urgent first: the board sorts by it.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// Blocked on the user: a question, approval or run waits for them, or the agent said it's blocked or handed them
    /// something (its note's `needs`).
    NeedsYou,
    /// Failing, stuck or out of usage, on its own.
    Trouble,
    Working,
    /// The agent waits on something other than the user (another task, a deploy).
    Waiting,
    /// The work is finished: its code done, not yet merged.
    Done,
    /// Merged: shipped, by the agent's note.
    Merged,
    Idle,
    Offline,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    /// The lead session.
    pub session: String,
    pub task: String,
    pub ticket: Option<String>,
    /// Where it runs: the name the task was given, else the places command's for its ticket, else the shortest end of
    /// its folder that tells it from the other rows' ("blue-fox/app").
    pub place: String,
    /// Where that place is on disk, when the places command says (a bench's folder): what opening it opens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// Offline, `state` is the one it was last known in.
    pub online: bool,
    pub state: State,
    /// Where the agent is: its latest note, else its last answer's first line.
    pub now: Option<String>,
    /// What the agent handed to the user, by its latest note.
    pub needs: Option<String>,
    /// The open asks of the lead and its workers.
    pub asks: Vec<Waiting>,
    pub workers: usize,
    /// Each of its workers (theirs too) as it is itself, by the same rules: what a worker's own status is.
    pub team: Vec<Member>,
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
        let (place, path) = whereabouts(lead);
        let members = team[1..].iter().map(|member| {
            let own = standing(member, conversations, asks);
            let (place, path) = whereabouts(member);
            Member { session: member.id.clone(), state: own.state, place, path, now: own.now, needs: own.needs, asks: own.asks }
        }).collect();
        Row {
            session: lead.id.clone(), task: crate::bridge::label(lead), ticket: lead.ticket.clone(), place, path, online: its.online,
            state: its.state, now: its.now, needs: its.needs, asks: its.asks, workers: team.len() - 1, team: members,
        }
    }).collect();
    rows.sort_by_key(|row| row.state);
    rows
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
    let mut state = team.iter().map(|c| attention(c)).min().unwrap_or(State::Idle);
    if !open.is_empty() { state = State::NeedsYou }
    if let Some(note) = own && state > State::Trouble {
        state = match note.status.as_deref() {
            Some("blocked") => State::NeedsYou,
            _ if state == State::Working => state,
            _ if note.needs.is_some() => State::NeedsYou,
            Some("waiting") => State::Waiting,
            Some("done") => State::Done,
            Some("merged") => State::Merged,
            _ => state,
        };
    }
    // No note of its own this turn: how it ended its turn (Zero's ending, "[zero: done]") says its state.
    if own.is_none() && matches!(state, State::Idle | State::Done) && let Some(ending) = session.answer().and_then(ending) {
        state = match ending {
            "done" => State::Done,
            "working" => State::Waiting,
            _ => State::NeedsYou, // blocked, or asked: either way it waits on the user
        };
    }
    // Its first line of prose: a table, heading or rule says nothing on its own.
    let prose = |l: &&str| !l.is_empty() && !l.starts_with('|') && !l.starts_with('#') && !l.starts_with("---") && !l.starts_with("[zero:");
    let answer = session.answer().and_then(|a| a.lines().map(str::trim).find(prose)).map(String::from);
    Standing { state, online, now: own.map(|n| n.body.clone()).filter(|b| !b.is_empty()).or(answer), needs: own.and_then(|n| n.needs.clone()), asks: open }
}

/// The ending Zero's hook has an agent close its turn with, when it's the answer's last line: "done", "blocked",
/// "working", or "asked" (its ask's id dropped).
pub fn ending(answer: &str) -> Option<&'static str> {
    let last = answer.trim_end().lines().last()?.trim();
    let inner = last.strip_prefix("[zero: ")?.strip_suffix(']')?;
    match inner.split_whitespace().next()? {
        "done" => Some("done"),
        "blocked" => Some("blocked"),
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

    /// Runs the user's places command (zerod's settings.json `places`) every five minutes while zerod runs: a bench
    /// moves rarely, and the command may be slow (bench ls asks GitHub for each bench's PR).
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
    let mut own = None;
    for note in notes {
        // Closed, by the user or its runtime: nothing it said still stands.
        // zerod's own "Offline" dot is no closing: a restart takes every session offline.
        let ours = note.request.as_deref() == Some(ATTENTION);
        let closed = !ours && note.status.as_deref() == Some("closed");
        if closed || (ours && note.status.is_none()) { own = None } else if !ours { own = Some(note) }
    }
    own
}

fn attention(conversation: &Conversation) -> State {
    match conversation.attention() {
        Attention::NeedsYou => State::NeedsYou,
        Attention::Limited | Attention::Stuck | Attention::Failed => State::Trouble,
        Attention::Working | Attention::Starting => State::Working,
        Attention::Done => State::Done,
        Attention::Idle => State::Idle,
        // Offline is only not running: its last known state is between turns.
        Attention::Offline => State::Idle,
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
