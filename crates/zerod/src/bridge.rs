//! zerod's sessions in the inbox: every open approval a permission ask, every field of an open question an ask of its
//! own, and a dot per session that follows its attention. Answered in the inbox, the session hears once; settled anywhere
//! else (another client, the session going offline), the ask is withdrawn. Found again among the inbox's asks after a
//! restart, so nothing is asked twice.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast::error::RecvError;

use crate::adapter::Answers;
use crate::ask::{AgentIdentity, Ask, AskKind, AskState};
use crate::daemon::Daemon;
use crate::inbox::{Inbox, InboxEvent};
use crate::model::{Attention, ChoiceKind, Conversation, ItemKind};

/// What the inbox's answer asks of a session.
#[derive(Debug, PartialEq)]
pub enum Act {
    /// The choice; a typed reply denies and its words go to the agent after, so it knows what to do instead.
    Decide { session: String, approval: String, choice: String, words: Option<String> },
    /// Every field of the question, once each has its answer.
    Answer { session: String, question: String, answers: Answers },
}

pub struct Bridge {
    inbox: Arc<Inbox>,
    host: String,
    state: Mutex<Known>,
}

#[derive(Default)]
struct Known {
    /// "session/request" → the ask showing it; empty once answered (or for a secret), so it is neither asked again nor withdrawn.
    asked: HashMap<String, String>,
    /// Answers given to the fields of an open question until every field has one: "session/question" → field → answer.
    collected: HashMap<String, Answers>,
    /// The dot each session last had, so an unchanged one costs nothing.
    dots: HashMap<String, Option<(Option<String>, String)>>,
}

impl Bridge {
    pub fn new(inbox: Arc<Inbox>) -> Bridge {
        Bridge { inbox, host: hostname(), state: Mutex::default() }
    }

    /// Follows the daemon's sessions into the inbox and the inbox's answers back to the sessions.
    pub fn start(daemon: Arc<Daemon>, inbox: Arc<Inbox>) {
        let bridge = Arc::new(Bridge::new(inbox.clone()));
        let (mut sessions, mut answers) = (daemon.subscribe(), inbox.subscribe());
        bridge.sync(&daemon.list());
        let (me, weak) = (bridge.clone(), Arc::downgrade(&daemon));
        tokio::spawn(async move {
            loop {
                use crate::model::Change;
                // Only what changes a session's approvals and questions (a streaming turn's words and items don't):
                // every session is read again for each.
                match sessions.recv().await {
                    Ok(event)
                        if matches!(
                            event.change,
                            Change::Approval { .. }
                                | Change::Resolved { .. }
                                | Change::Question { .. }
                                | Change::Answered { .. }
                                | Change::Rewound { .. }
                                | Change::Archived
                        ) => {}
                    Err(RecvError::Lagged(_)) => {}
                    Ok(_) => continue,
                    Err(RecvError::Closed) => return,
                }
                let Some(daemon) = weak.upgrade() else { return };
                me.sync(&daemon.list());
            }
        });
        let weak = Arc::downgrade(&daemon);
        tokio::spawn(async move {
            loop {
                let asks = match answers.recv().await {
                    Ok(InboxEvent::Ask(ask)) => vec![*ask],
                    Ok(_) => continue,
                    // Some answers may have gone by: every ask of ours that is final now.
                    Err(RecvError::Lagged(_)) => {
                        bridge.inbox.asks().into_iter().filter(|a| a.state.is_final() && a.request.is_some()).collect()
                    }
                    Err(RecvError::Closed) => return,
                };
                let Some(daemon) = weak.upgrade() else { return };
                for ask in asks {
                    let Some(session) = ask.agent.reference.as_deref().filter(|_| ask.agent.runtime.as_deref() == Some("zerod")) else {
                        continue;
                    };
                    if ask.state == AskState::Answered
                        && let (Some(ticket), Some(at)) = (ask.agent.ticket.as_deref(), ask.answered_at)
                    {
                        daemon.ticket_answered(session, ticket, at.0)
                    }
                    let Some(act) = bridge.heard(&ask, daemon.get(session).as_ref()) else { continue };
                    let daemon = daemon.clone();
                    tokio::spawn(async move {
                        if let Err(error) = perform(&daemon, act).await {
                            eprintln!("zerod: an answer from the inbox didn't reach its session: {error}")
                        }
                    });
                }
            }
        });
    }

    /// Brings the inbox up to date with `conversations`: asks for what is open, withdrawals for what isn't, dots.
    pub fn sync(&self, conversations: &[Conversation]) {
        let mut known = self.lock();
        let mut open = std::collections::HashSet::new();
        let mut asks: Option<Vec<Ask>> = None;
        for conversation in conversations {
            let mut wanted: Vec<(String, Ask)> = vec![];
            for question in &conversation.questions {
                for field in &question.fields {
                    let request = format!("{}#{}", question.id, field.id);
                    wanted.push((
                        request,
                        if field.secret { secret(field, self.agent(conversation)) } else { self.field(field, &question.id, conversation) },
                    ));
                }
            }
            for approval in &conversation.approvals {
                let agent = self.agent(conversation);
                let files: Vec<&str> = approval.changes.iter().map(|c| c.path.as_str()).collect();
                // Asked as what it is: the agent wanting to run a command (or change files), shown in its own block, not
                // spelled out again in the question.
                let title = if approval.command.is_some() {
                    "Allow this command?"
                } else if !files.is_empty() {
                    "Allow these changes?"
                } else {
                    approval.title.as_str()
                };
                let mut ask = Ask::new(AskKind::Permission, title, agent, 86400);
                ask.body = approval.reason.clone().unwrap_or_default();
                ask.options = approval.choices.iter().map(|c| c.label.clone()).collect();
                ask.command = approval.command.clone().or_else(|| (!files.is_empty()).then(|| files.join("\n")));
                ask.cwd = Some(approval.cwd.clone().unwrap_or_else(|| conversation.cwd.clone()));
                ask.request = Some(approval.id.clone());
                wanted.push((approval.id.clone(), ask));
            }
            for (request, ask) in wanted {
                let key = format!("{}/{request}", conversation.id);
                open.insert(key.clone());
                if known.asked.contains_key(&key) {
                    continue;
                }
                let asks = asks.get_or_insert_with(|| self.inbox.asks());
                let existing = asks.iter().rev().find(|a| {
                    a.agent.reference.as_deref() == Some(&conversation.id) && a.request.as_deref() == Some(&request) && !a.state.is_final()
                });
                let id = match existing {
                    Some(existing) => existing.id.clone(),
                    // The inbox keeps every answer in its log; a secret is asked for in the workspace window instead.
                    None if ask.kind == AskKind::Note => {
                        self.inbox.create(ask, false);
                        String::new()
                    }
                    None => self.inbox.create(ask, false).id,
                };
                known.asked.insert(key, id);
            }
        }
        let settled: Vec<(String, String)> =
            known.asked.iter().filter(|(key, _)| !open.contains(*key)).map(|(k, v)| (k.clone(), v.clone())).collect();
        for (key, id) in settled {
            known.asked.remove(&key);
            if !id.is_empty() {
                self.inbox.withdraw(&id, Some("Settled in zerod"))
            }
        }
        known.collected.retain(|key, _| open.iter().any(|k| k.starts_with(&format!("{key}#"))));
        for conversation in conversations {
            self.dot(&mut known, conversation)
        }
    }

    /// The bar shows a dot per agent from its latest note: each session posts one when its attention changes. A session
    /// waiting on the user already has its asks; an offline one leaves the bar until it works again.
    fn dot(&self, known: &mut Known, conversation: &Conversation) {
        let dot = match conversation.attention() {
            Attention::Working => Some((None, "Working".to_string())),
            // Its answer, so the agent's timeline in the inbox reads like a conversation.
            Attention::Done => Some((
                Some("done"),
                conversation.answer().map(crate::board::without_ending).filter(|a| !a.is_empty()).unwrap_or("Answered").to_string(),
            )),
            Attention::Stuck => Some((Some("blocked"), conversation.stalled.clone().unwrap_or_else(|| "Stuck".into()))),
            Attention::Failed | Attention::Limited => Some((
                Some("blocked"),
                conversation.failure.as_ref().map(|f| f.message.clone()).unwrap_or_else(|| {
                    if conversation.usage.as_ref().is_some_and(|u| u.limited) { "Usage limit reached".into() } else { "Failed".into() }
                }),
            )),
            Attention::Offline => Some((Some("closed"), "Offline".into())),
            Attention::Blocked => Some((
                Some("blocked"),
                conversation.answer().map(crate::board::without_ending).filter(|a| !a.is_empty()).unwrap_or("Blocked").to_string(),
            )),
            Attention::NeedsYou | Attention::Idle | Attention::Answered | Attention::Starting => None,
        }
        .map(|(status, body)| (status.map(String::from), body));
        if known.dots.get(&conversation.id) == Some(&dot) {
            return;
        }
        known.dots.insert(conversation.id.clone(), dot.clone());
        let Some((status, body)) = dot else { return };
        let agent = self.agent(conversation);
        let latest = self.inbox.asks().into_iter().rev().find(|a| a.agent.name == agent.name && a.kind != AskKind::Message);
        if let Some(latest) = &latest
            && latest.kind == AskKind::Note
            && latest.status == status
            && (status.is_none() || status.as_deref() == Some("closed") || latest.body == body)
        {
            return;
        }
        if latest.is_none() && status.as_deref() == Some("closed") {
            return;
        }
        let mut note = Ask::new(AskKind::Note, &label(conversation), agent, 0);
        note.body = body;
        note.status = status;
        note.request = Some(crate::board::ATTENTION.into());
        self.inbox.create(note, false);
    }

    /// An ask of ours answered in the inbox: what to tell its session, once.
    pub fn heard(&self, ask: &Ask, conversation: Option<&Conversation>) -> Option<Act> {
        let (session, request) = (ask.agent.reference.clone()?, ask.request.clone()?);
        if ask.agent.runtime.as_deref() != Some("zerod")
            || !matches!(ask.state, AskState::Answered | AskState::Declined)
            || ask.status.as_deref() == Some("withdrawn")
        {
            return None;
        }
        let mut known = self.lock();
        let asked = known.asked.get_mut(&format!("{session}/{request}")).filter(|id| **id == ask.id)?;
        asked.clear();
        let conversation = conversation?;
        if let Some((question_id, field_id)) = request.split_once('#') {
            let question = conversation.questions.iter().find(|q| q.id == question_id)?;
            let field = question.fields.iter().find(|f| f.id == field_id)?;
            let words = match (ask.choice, ask.answer.as_deref()) {
                (_, None) => return None,
                (Some(choice), _) if choice < field.options.len() => field.options[choice].label.clone(),
                // "Something else…" answers "Something else: their words"; a typed reply is the words alone.
                (_, Some(answer)) => answer.split_once("Something else: ").map_or(answer, |(_, words)| words).to_string(),
            };
            if words.is_empty() {
                return None;
            }
            let key = format!("{session}/{question_id}");
            let answers = known.collected.entry(key.clone()).or_default();
            answers.insert(field_id.to_string(), vec![words]);
            if !question.fields.iter().all(|f| answers.contains_key(&f.id)) {
                return None;
            }
            let answers = known.collected.remove(&key)?;
            return Some(Act::Answer { session, question: question_id.to_string(), answers });
        }
        let approval = conversation.approvals.iter().find(|a| a.id == request)?;
        let choice = ask
            .choice
            .and_then(|i| approval.choices.get(i))
            .or_else(|| approval.choices.iter().find(|c| c.kind == ChoiceKind::Deny))
            .or_else(|| approval.choices.iter().find(|c| c.kind == ChoiceKind::Stop))?;
        let words = if ask.choice.is_none() { ask.answer.clone().filter(|a| !a.is_empty()) } else { None };
        Some(Act::Decide { session, approval: request, choice: choice.id.clone(), words })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Known> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The identity the inbox and the bar know a session by.
    fn agent(&self, conversation: &Conversation) -> AgentIdentity {
        identity(conversation, &self.host)
    }

    /// One field of a question as an ask: its options, then "Something else…" where the agent takes free text.
    fn field(&self, field: &crate::model::Field, question: &str, conversation: &Conversation) -> Ask {
        let kind = if field.options.is_empty() { AskKind::Question } else { AskKind::Choice };
        let mut ask = Ask::new(kind, &field.question, self.agent(conversation), 86400);
        if kind == AskKind::Choice {
            ask.options = field.options.iter().map(|o| o.label.clone()).collect();
            if field.other {
                ask.options.push("Something else…".into())
            }
        }
        let described: Vec<String> =
            field.options.iter().filter_map(|o| o.description.as_ref().map(|d| format!("{}: {d}", o.label))).collect();
        if !described.is_empty() {
            ask.detail = Some(described.join("\n"))
        }
        ask.request = Some(format!("{question}#{}", field.id));
        ask
    }
}

fn secret(field: &crate::model::Field, agent: AgentIdentity) -> Ask {
    let mut note = Ask::new(AskKind::Note, "Secret", agent, 0);
    note.body = format!("{} Answer it in Zero's workspace window.", field.question);
    note.status = Some("blocked".into());
    note
}

async fn perform(daemon: &Daemon, act: Act) -> Result<(), String> {
    match act {
        Act::Answer { session, question, answers } => daemon.answer(&session, &question, &answers).await,
        Act::Decide { session, approval, choice, words } => {
            daemon.decide(&session, &approval, &choice).await?;
            match words {
                Some(words) => daemon.send(&session, crate::session::Message::text(&words), Default::default()).await,
                None => Ok(()),
            }
        }
    }
}

/// The name the user or its lead gave it, else the session's title, else what it was asked first, else the provider and
/// its folder.
pub fn label(conversation: &Conversation) -> String {
    if let Some(label) = conversation.label.as_ref().or(conversation.title.as_ref()).filter(|l| !l.is_empty()) {
        return label.clone();
    }
    let asked = conversation.items.iter().find_map(|i| match &i.kind {
        ItemKind::User { text, .. } => Inbox::gist(text),
        _ => None,
    });
    asked.unwrap_or_else(|| {
        let folder = std::path::Path::new(&conversation.cwd).file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
        format!("{} in {folder}", conversation.provider.title())
    })
}

unsafe extern "C" {
    fn gethostname(name: *mut std::ffi::c_char, length: usize) -> i32;
}

/// The identity the inbox and the bar know a session by, on `host`.
pub fn identity(conversation: &Conversation, host: &str) -> AgentIdentity {
    AgentIdentity {
        name: format!("zerod-{}", conversation.id),
        host: host.into(),
        cwd: Some(conversation.cwd.clone()),
        label: Some(label(conversation)),
        runtime: Some("zerod".into()),
        reference: Some(conversation.id.clone()),
        ..Default::default()
    }
}

pub fn hostname() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is as long as said; gethostname writes at most that and terminates it.
    if unsafe { gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } != 0 {
        return "localhost".into();
    }
    std::ffi::CStr::from_bytes_until_nul(&buffer).map(|name| name.to_string_lossy().to_string()).unwrap_or_else(|_| "localhost".into())
}
