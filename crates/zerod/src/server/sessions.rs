//! Sessions over the socket: started, moved and stopped, what's said to them, what's set on them, and reading them.

use serde_json::{Value, json};

use super::{RECENT, Request, VERSION, Zerod, unknown};
use crate::daemon::Rewind;
use crate::model::{Conversation, Permissions, Provider};
use crate::session::Message;

/// Tasks started, taken in, let go and archived, and zerod restarted under them.
pub(super) async fn lifecycle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    match request.op.as_str() {
        "start" => start(zerod, &request),
        "spawn" => spawn(zerod, &request),
        // From a session: the task or Claude Code session becomes its worker.
        "adopt" if request.session.is_some() => daemon
            .adopt_into(&request.session()?, request.thread.as_deref().ok_or("Which task or session?")?)
            .map(|id| json!({"session": id})),
        "adopt" => {
            let options = crate::daemon::Options {
                workspace: None,
                label: request.label.clone(),
                ticket: request.ticket.clone(),
                permissions: request.permissions,
                ..Default::default()
            };
            daemon
                .adopt(
                    request.provider.unwrap_or(Provider::Claude),
                    request.thread.as_deref().ok_or("Which session?")?,
                    request.cwd.as_deref().ok_or("Which folder?")?,
                    options,
                )
                .map(|id| json!({"session": id}))
        }
        // A worker let go of its lead: a task of its own.
        "detach" => daemon.detach(request.thread.as_deref().ok_or("Which worker? Its task's id")?).map(|_| Value::Null),
        // A Claude Code, Codex or OpenCode session from outside Zero, by its id: a task, offline, not opened.
        "migrate" => {
            let options = crate::daemon::Options {
                workspace: request.workspace_id(),
                label: request.label.clone(),
                ticket: request.ticket.clone(),
                ..Default::default()
            };
            daemon.migrate(request.thread.as_deref().ok_or("Which session? Its id")?, options).map(|id| json!({"session": id}))
        }
        "archive" => daemon.archive(&request.session()?).await.map(|_| Value::Null),
        "unarchive" => daemon.unarchive(&request.session()?).map(|back| json!(back)),
        "saveForLater" => save_for_later(zerod, &request.session()?),
        // Back from Later: on the board again, off hold, and its item done.
        "resumeLater" => {
            let args = request.args.clone().unwrap_or(json!({}));
            let item = zerod.later.view(args["item"].as_str().ok_or("Which item?")?, None)?;
            let session = item.resume.ok_or("That item isn't a task saved for later")?;
            daemon.bring_back(&session).await;
            zerod.later.edit(&item.id, crate::later::Edit { done: Some(true), ..Default::default() })?;
            let _ = zerod.notices.send("later");
            Ok(json!({"session": session}))
        }
        "archived" => Ok(json!(daemon.archived(request.limit.unwrap_or(1000)))),
        // While a restart waits for turns to pause: what it's waiting for.
        "restartStatus" => Ok(daemon.restart_status()),
        "restart" => Ok(restart(zerod)),
        other => unknown(other),
    }
}

/// A task's turn and terminal: resumed, interrupted, stopped, paused, switched, rewound or branched.
pub(super) async fn control(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    match request.op.as_str() {
        "release" => daemon.release(&request.session()?).map(|_| Value::Null),
        "resume" => daemon.resume(&request.session()?).await.map(|_| Value::Null),
        "openTerminal" => daemon.open_terminal(&request.session()?).await.map(|terminal| json!({"terminal": terminal})),
        "rewindPreview" => daemon.rewind_preview(&request.session()?, request.message.as_deref().ok_or("Back to which message?")?),
        "rewind" => {
            let what = match (request.conversation.unwrap_or(true), request.code.unwrap_or(false)) {
                (true, false) => Rewind::Conversation,
                (false, true) => Rewind::Code,
                (true, true) => Rewind::Both,
                (false, false) => return Err("Rewind what? The conversation, the code or both".into()),
            };
            daemon.rewind(&request.session()?, request.message.as_deref().ok_or("Back to which message?")?, what).await
        }
        "branch" => daemon.branch(&request.session()?, request.message.as_deref().ok_or("Branch from which message?")?),
        "closeTerminal" => daemon.close_terminal(&request.session()?).await.map(|_| Value::Null),
        "switch" => {
            let provider = request.provider.ok_or("Switch to which provider: codex, claude or opencode?")?;
            daemon.switch(&request.session()?, provider, request.choice()).await.map(|_| Value::Null)
        }
        "interrupt" => daemon.interrupt(&request.session()?).await.map(|_| Value::Null),
        "stop" => daemon.stop(&request.session()?).map(|_| Value::Null),
        // The tasks named (every task, none named) and their workers: on hold, and off it. A working one is given five
        // minutes to wrap up.
        "pause" => Ok(json!(daemon.pause(&request.sessions.clone().unwrap_or_default(), std::time::Duration::from_secs(5 * 60)).await)),
        "unpause" => Ok(json!(daemon.unpause(&request.sessions.clone().unwrap_or_default()).await)),
        other => unknown(other),
    }
}

/// What's said to a task: a message now or after its turn, an answer to what it asked, and the user having seen it.
pub(super) async fn messages(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    match request.op.as_str() {
        "send" => {
            let (id, text, images) = message(zerod, &request, "Send needs text")?;
            let text = with_open_asks(&zerod.inbox, &id, text);
            daemon.send(&id, Message { text: &text, images: &images, context: None }, request.choice()).await.map(|_| Value::Null)
        }
        // For after the current turn: queued, one turn each; between turns it goes now.
        "queue" => {
            let (id, text, images) = message(zerod, &request, "Queue needs text")?;
            daemon.queue(&id, &text, &images).map(|queued| json!(queued))
        }
        "unqueue" => daemon
            .unqueue(&request.session()?, request.item.as_ref().and_then(Value::as_str).ok_or("Which queued message?")?)
            .map(|queued| json!(queued)),
        // From another task when `from` says which: marked as its words.
        "notify" => daemon
            .notify_from(
                &daemon.resolve(&request.session()?)?,
                request.from.as_deref().unwrap_or("zero"),
                request.text.as_deref().ok_or("Notify with text")?,
            )
            .map(|_| Value::Null),
        // The user asks two tasks to work together.
        "introduce" => daemon
            .introduce(&request.session()?, request.args.as_ref().and_then(|a| a["other"].as_str()).ok_or("Introduce to which task?")?)
            .map(|_| Value::Null),
        "decide" => {
            let approval = request.approval.as_deref().ok_or("Which approval?")?;
            let choice = request.choice.as_deref().ok_or("Which choice?")?;
            daemon.decide(&request.session()?, approval, choice).await.map(|_| Value::Null)
        }
        "answer" => {
            let question = request.question.as_deref().ok_or("Which question?")?;
            let answers = request.answers.as_ref().ok_or("Answer with answers")?;
            daemon.answer(&request.session()?, question, answers).await.map(|_| Value::Null)
        }
        // The user saw a task's reply, on whichever client: Replied settles to Idle five minutes on, everywhere.
        "seen" => daemon.mark_seen(&request.session()?, request.answer.as_deref(), request.at).map(|_| Value::Null),
        other => unknown(other),
    }
}

/// What's set on a task: its name and ticket, permissions, workspace, place, attributes and tables.
pub(super) async fn properties(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    match request.op.as_str() {
        "label" => daemon.label(&request.session()?, request.label.as_deref(), request.ticket.as_deref()).map(|_| Value::Null),
        "setPermissions" => daemon
            .set_permissions(&request.session()?, request.permissions.ok_or("Which permissions: auto or unrestricted?")?)
            .await
            .map(|_| Value::Null),
        "placeInWorkspace" => daemon.place_in_workspace(&request.session()?, request.workspace_id().as_deref()).map(|_| Value::Null),
        // One of the issues the task drives, its row set: who has it, and what it needs, where it stands or why parked.
        "issue" => {
            let state = request
                .state
                .as_deref()
                .and_then(crate::model::IssueState::named)
                .ok_or("An issue's state is one of you, working, waiting, parked or done")?;
            daemon
                .set_issue(
                    &request.session()?,
                    request.ticket.as_deref().ok_or("Which issue? Its ticket")?,
                    state,
                    request.text.as_deref().unwrap_or(""),
                )
                .map(|_| Value::Null)
        }
        "attr" => daemon
            .set_attribute(&request.session()?, request.name.as_deref().ok_or("Which attribute?")?, request.value.as_deref())
            .map(|_| Value::Null),
        "table" => daemon
            .table(
                &request.session()?,
                request.title.as_deref().unwrap_or(""),
                request.columns.clone().unwrap_or_default(),
                request.rows.clone().unwrap_or_default(),
            )
            .map(|_| Value::Null),
        "place" => daemon.set_place(&request.session()?, request.place.as_deref()).map(|_| Value::Null),
        other => unknown(other),
    }
}

/// Reading sessions: the list, one session or a page of its items, a lead's workers, and waiting on them to settle.
pub(super) async fn reads(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    match request.op.as_str() {
        "hello" => Ok(json!({"version": VERSION, "pid": std::process::id()})),
        "list" => Ok(json!(daemon.sessions().iter().map(|s| summary(&s.summary())).collect::<Vec<_>>())),
        "get" => {
            daemon.get(&request.session()?).map(|c| json!(c)).ok_or_else(|| format!("No session {}", request.session.unwrap_or_default()))
        }
        "workers" => {
            let lead = request.session()?;
            Ok(json!(
                daemon
                    .sessions()
                    .iter()
                    .map(|s| s.summary())
                    .filter(|c| c.parent.as_deref() == Some(lead.as_str()))
                    .map(|c| summary(&c))
                    .collect::<Vec<_>>()
            ))
        }
        "result" => Ok(json!({"answer": daemon.last_answer(&request.session()?)})),
        "wait" => wait(zerod, &request).await,
        "usage" => {
            Ok(json!(daemon.usage().into_iter().map(|(provider, usage)| json!({"provider": provider, "usage": usage})).collect::<Vec<_>>()))
        }
        // Whole sessions, not the list's: a row falls back on its lead's last answer.
        // Each session as a summary: its latest answer for Now, not its whole conversation.
        "board" => Ok(json!(zerod.board())),
        // A session's latest items and how many came before: what a lazy subscriber shows when it opens one.
        "recent" => {
            let (conversation, earlier) = daemon.session(&request.session()?)?.recent(RECENT);
            Ok(json!({"conversation": conversation, "earlier": earlier}))
        }
        "items" => Ok(json!(daemon.session(&request.session()?)?.items(
            request.before.as_deref(),
            request.from.as_deref(),
            request.limit.unwrap_or(60)
        ))),
        "window" => {
            let (items, earlier, later) =
                daemon.session(&request.session()?)?.window(request.from.as_deref(), request.after.as_deref(), request.limit.unwrap_or(60));
            Ok(json!({"items": items, "earlier": earlier, "later": later}))
        }
        "outline" => Ok(daemon.session(&request.session()?)?.outline()),
        other => unknown(other),
    }
}

/// A new task; a loop named in the prompt (@name) is given as its words, and its use recorded once the session exists.
fn start(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let provider = request.provider.ok_or("Start needs a provider: codex, claude or opencode")?;
    let cwd = request.cwd.as_deref().ok_or("Start needs a folder")?;
    let options = options(request, Some(cwd.into()), Some(request.permissions.unwrap_or_default()));
    let (prompt, loops) = zerod.loops.expand(request.prompt.as_deref().unwrap_or(""));
    let id = zerod.daemon.start(provider, &prompt, options)?;
    for name in &loops {
        zerod.loops.record(name, &id, "lead")
    }
    Ok(json!({"session": id}))
}

/// A worker for the session, on its lead's provider unless the request names one.
fn spawn(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let lead = request.session()?;
    let provider = match request.provider {
        Some(provider) => provider,
        None => zerod.daemon.get(&lead).ok_or_else(|| format!("No session {lead}"))?.provider,
    };
    let options = options(request, request.cwd.clone(), request.permissions);
    let (prompt, loops) = zerod.loops.expand(request.prompt.as_deref().unwrap_or(""));
    let id = zerod.daemon.spawn(&lead, provider, &prompt, options)?;
    for name in &loops {
        zerod.loops.record(name, &id, "worker")
    }
    Ok(json!({"session": id}))
}

/// A new task's options as the request gives them, with its folder and permissions.
fn options(request: &Request, cwd: Option<String>, permissions: Option<Permissions>) -> crate::daemon::Options {
    crate::daemon::Options {
        cwd,
        workspace: request.workspace_id(),
        model: request.model.clone(),
        effort: request.effort.clone(),
        permissions,
        label: request.label.clone(),
        ticket: request.ticket.clone(),
        force: request.force.unwrap_or(false),
        images: request.images.clone().unwrap_or_default(),
        signin: request.signin.as_ref().and_then(Value::as_str).map(String::from),
        parent: None,
    }
}

/// What's sent or queued: the session, its words (a loop named in them given as its words, its use recorded as the
/// task's, a lead's or a worker's) and its images.
fn message(zerod: &Zerod, request: &Request, needs: &'static str) -> Result<(String, String, Vec<String>), String> {
    let images = request.images.clone().unwrap_or_default();
    let text = request.text.as_deref().filter(|t| !t.trim().is_empty() || !images.is_empty()).ok_or(needs)?;
    let (text, loops) = zerod.loops.expand(text);
    // By its name too, when one task has it.
    let id = zerod.daemon.resolve(&request.session()?)?;
    let role = if zerod.daemon.get(&id).is_some_and(|c| c.parent.is_some()) { "worker" } else { "lead" };
    for name in &loops {
        zerod.loops.record(name, &id, role)
    }
    Ok((id, text, images))
}

/// The user writing to a task may answer one of its open asks there, or write about something else and leave it open
/// on purpose (a step they're still running): Zero can't tell which, so it withdraws none and tells the agent, under
/// the user's words, what's still open, to withdraw what the words answered. The provider's own questions are its
/// adapter's (declined as the words go). Sent, as they're sent; queued, as they're given from the queue (Daemon's
/// note_with), the queue keeping the user's own words.
pub(super) fn with_open_asks(inbox: &crate::inbox::Inbox, id: &str, text: String) -> String {
    use crate::ask::AskKind;
    let open: Vec<_> = inbox
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
    let which = open.iter().map(|a| format!("{} (\"{}\")", a.id, a.title)).collect::<Vec<_>>().join(", ");
    format!(
        "{text}\n\n{} {which}. If the user's words answer one, withdraw it with `zero withdraw <id>`; leave the rest for them.)",
        crate::daemon::OPEN_ASKS_MARK
    )
}

/// A new build is on disk: turns under way pause between steps, then zerod becomes the new one, which carries them on.
/// Answered at once; the restart happens when the last turn has paused.
fn restart(zerod: &Zerod) -> Value {
    let daemon = zerod.daemon.clone();
    // The app hears a restart is under way, and asks what it waits for.
    let _ = zerod.notices.send("restarting");
    tokio::spawn(async move {
        let handed = daemon.hand_off().await;
        let paused = daemon.pause_for_restart().await;
        eprintln!(
            "zerod: restarting as the new build; {} process(es) handed over, {} turn(s) paused to carry on",
            handed.len(),
            paused.len()
        );
        crate::process::replace_self();
    });
    json!({"restarting": true})
}

/// Waits on the sessions (all of them, or `any` one) to settle, each then as how it ended.
async fn wait(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let ids = request.sessions.clone().ok_or("Wait on which sessions?")?;
    let timeout = std::time::Duration::from_secs(request.timeout.unwrap_or(30 * 60));
    let settled = zerod.daemon.wait(&ids, request.any.unwrap_or(false), timeout).await?;
    Ok(json!(
        settled
            .iter()
            .map(|c| json!({
                "id": c.id, "label": c.label, "ticket": c.ticket, "attention": c.attention(), "answer": c.answer(),
                "error": c.failure.as_ref().map(|f| &f.message), "stalled": c.stalled,
            }))
            .collect::<Vec<_>>()
    ))
}

/// A session for a list: everything but its items, and how it's doing, which can't be told without them.
fn summary(conversation: &Conversation) -> Value {
    let mut summary = json!(Conversation { items: vec![], ..conversation.clone() });
    summary["attention"] = json!(conversation.attention());
    summary
}

/// A task saved for later, whole: off the board and on hold, with an item in Later, its name for a note and its last
/// answer behind it, that resumes it.
fn save_for_later(zerod: &Zerod, id: &str) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    let task = daemon.get(id).ok_or_else(|| format!("No session {id}"))?;
    let name = crate::bridge::label(&task);
    let note: String = name.chars().take(crate::later::NOTE).collect();
    let artifact = task.answer().map(crate::board::without_ending).unwrap_or_default().to_string();
    let item = zerod.later.save(crate::later::New {
        note,
        artifact,
        from: Some(id.into()),
        task: Some(name),
        workspace: Some(daemon.workspace_of(&task)),
        asked: true,
        resume: Some(id.into()),
        ..Default::default()
    })?;
    daemon.save_for_later(id)?;
    let _ = zerod.notices.send("later");
    Ok(json!(item))
}
