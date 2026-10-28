//! The board: every task Zero runs on one screen, one row each. A row is a lead session with its workers folded in: what
//! the work is, where it runs, its state, where the agent is now and what it needs from the user. Made from the sessions
//! and the inbox, so it reads the same in every client.

use serde::Serialize;

use crate::ask::{Ask, AskKind, AskState};
use crate::model::{Attention, Conversation};

/// Most urgent first: the board sorts by it.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// A question, approval or run waits for the user.
    NeedsYou,
    /// Failing, stuck, out of usage, or the agent said it is blocked.
    Trouble,
    Working,
    /// The agent waits on something other than the user (another task, a deploy).
    Waiting,
    /// Finished its part and handed something to the user.
    Ready,
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
    pub ticket: Option<String>,
    /// The shortest end of its folder that tells it from the other rows' ("blue-fox/app").
    pub place: String,
    pub state: State,
    /// Where the agent is: its latest note, else its last answer's first line.
    pub now: Option<String>,
    /// What the agent handed to the user, by its latest note.
    pub needs: Option<String>,
    /// The open asks of the lead and its workers.
    pub asks: Vec<Waiting>,
    pub workers: usize,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Waiting {
    pub id: String,
    pub title: String,
}

/// The notes zerod posts itself to follow a session's attention (bridge.rs), told from the agent's own.
pub const ATTENTION: &str = "attention";

pub fn board(conversations: &[Conversation], asks: &[Ask]) -> Vec<Row> {
    let known = |id: &Option<String>| id.as_ref().is_some_and(|id| conversations.iter().any(|c| &c.id == id));
    let mut rows: Vec<Row> = conversations.iter().filter(|c| !known(&c.parent)).filter_map(|lead| {
        let team = team(lead, conversations);
        let own = note(lead, asks);
        let open: Vec<Waiting> = asks.iter()
            .filter(|a| a.state == AskState::Waiting && !matches!(a.kind, AskKind::Note | AskKind::Message) && team.iter().any(|c| is(a, c)))
            .map(|a| Waiting { id: a.id.clone(), title: a.title.clone() }).collect();
        let mut state = team.iter().map(|c| attention(c)).min().unwrap_or(State::Idle);
        if !open.is_empty() { state = State::NeedsYou }
        if let Some(note) = own && state > State::Trouble {
            state = match note.status.as_deref() {
                Some("blocked") => State::Trouble,
                _ if state == State::Working => state,
                Some("waiting") => State::Waiting,
                _ if note.needs.is_some() => State::Ready,
                Some("done") => State::Done,
                _ => state,
            };
        }
        let answer = lead.answer().and_then(|a| a.lines().map(str::trim).find(|l| !l.is_empty())).map(String::from);
        let row = Row {
            session: lead.id.clone(), task: crate::bridge::label(lead), ticket: lead.ticket.clone(), place: String::new(), state,
            now: own.map(|n| n.body.clone()).filter(|b| !b.is_empty()).or(answer),
            needs: own.and_then(|n| n.needs.clone()), asks: open, workers: team.len() - 1,
        };
        // A session gone offline stays while it still needs the user.
        let live = team.iter().any(|c| c.attention() != Attention::Offline);
        (live || row.needs.is_some() || !row.asks.is_empty()).then_some(row)
    }).collect();
    rows.sort_by_key(|row| row.state);
    let folders: Vec<String> = rows.iter().map(|row| conversations.iter().find(|c| c.id == row.session).map(|c| c.cwd.clone()).unwrap_or_default()).collect();
    for (row, folder) in rows.iter_mut().zip(&folders) { row.place = place(folder, &folders) }
    rows
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
        Attention::Offline => State::Offline,
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
