//! The desktop over the socket: a task's desktop_ call, checked and approved here, then done by Zero.app; the user's Stop.

use serde_json::{Value, json};

use super::{Request, Zerod, unknown};
use crate::ask::{Ask, AskKind, AskState};
use crate::desktop::{Action, SCREEN, Tier};

/// How long a card waits for the user before the call gives up.
const CARD_TTL: i64 = 3600;
const FOR_TASK: &str = "Allow for this task";
const ONCE: &str = "Allow once";
const DENY: &str = "Deny";

pub(super) async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    match request.op.as_str() {
        "desktopCall" => call(zerod, &request).await,
        "desktopStop" => {
            zerod.desktop.stop(&request.session()?);
            Ok(Value::Null)
        }
        other => unknown(other),
    }
}

async fn call(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let not_a_task = || "The desktop tools are for Zero's tasks: there's no one to approve them for outside one".to_string();
    let session = request.session.as_deref().ok_or_else(not_a_task)?;
    let conversation = zerod.daemon.get(session).ok_or_else(not_a_task)?;
    let desktop = &zerod.desktop;
    if desktop.take_stopped(session) {
        return Err("The user stopped this task's desktop use: ask them (zero ask) before using the desktop again.".into());
    }
    let task = json!({"session": session, "name": crate::bridge::label(&conversation)});
    let tool = request.tool.as_deref().ok_or("Which tool?")?;
    let mut args = request.args.clone().filter(Value::is_object).unwrap_or(json!({}));
    // What zerod sets is zerod's to say: never the agent's.
    for set in ["pid", "bundle", "approved"] {
        args.as_object_mut().map(|a| a.remove(set));
    }
    if tool == "desktop_apps" {
        args["approved"] = json!(desktop.approved(session));
        return desktop.send(&task, tool, args).await;
    }
    // Stopping the task's own recording needs no card: what it filmed was approved as it started.
    if tool == "desktop_record" && args["action"] == "stop" {
        return desktop.send(&task, tool, args).await;
    }
    let action = Action::of(tool).ok_or_else(|| format!("No desktop tool {tool}"))?;
    // The whole screen, a picture or a film of it alone: asked for, or neither an app nor a window named (a window is
    // an app's: named without it, the call asks which, never for the screen).
    let screen = matches!(tool, "desktop_screenshot" | "desktop_record")
        && (args["screen"] == true || (args["app"].is_null() && args["window"].is_null()));
    let (bundle, name) = if screen {
        (SCREEN.to_string(), "the whole screen".to_string())
    } else {
        let app = args["app"].as_str().ok_or("Which app? Its name or bundle id, as desktop_apps lists them")?.to_string();
        let found = desktop.send(&task, "resolve", json!({"app": app})).await?;
        args["pid"] = found["pid"].clone();
        (found["bundle"].as_str().ok_or("Zero.app found no bundle id")?.to_string(), found["name"].as_str().unwrap_or(&app).to_string())
    };
    args["bundle"] = json!(bundle);
    let tier = if screen { Tier::Full } else { crate::desktop::tier(&bundle) };
    args["background"] = json!(tier == Tier::Background);
    match (tier, action) {
        (Tier::Never, _) => return Err(format!("{name} is off limits to agents: it holds passwords or the Mac's permissions.")),
        (Tier::ReadOnly(why), Action::Point | Action::Type) => return Err(why.to_string()),
        (Tier::Background, _) if args["pointer"] == true => {
            return Err(format!("{name} is used in the background only, so the user isn't disturbed: never with the real pointer."));
        }
        _ => {}
    }
    if !desktop.allowed(session, &bundle) {
        let card = format!("Let {} use {name}?", crate::bridge::label(&conversation));
        let body = match tier {
            _ if screen => "It can see the whole screen: every app's windows.".to_string(),
            Tier::Background => format!(
                "It can see {name}'s windows, and click, type and scroll in them in the background, without taking the pointer or \
focus. Never on its cards, approvals, the control bar or Settings."
            ),
            Tier::ReadOnly(_) => format!("Read only: it can see {name}'s windows, not act in them."),
            Tier::Terminal => format!("It can see {name}'s windows, and click and scroll in them; typing asks each time."),
            _ => format!("It can see {name}'s windows, and click, type and scroll in them."),
        };
        match approve(zerod, &conversation, &bundle, &name, &card, &body, None, &[FOR_TASK, ONCE, DENY]).await? {
            FOR_TASK => desktop.allow(session, &bundle),
            ONCE => {}
            _ => return Err(format!("The user denied {name} to this task. Ask them (zero ask) before trying it again.")),
        }
    }
    if tier == Tier::Terminal && action == Action::Type {
        let typed = args["text"].as_str().or(args["keys"].as_str()).unwrap_or_default().to_string();
        let body = "A terminal runs what's typed as commands, outside the task's sandbox.";
        let purpose = format!("{bundle} typing {typed}");
        if approve(zerod, &conversation, &purpose, &name, &format!("Type into {name}?"), body, Some(typed), &[ONCE, DENY]).await? != ONCE {
            return Err(format!("The user denied typing that into {name}."));
        }
    }
    desktop.send(&task, tool, args).await
}

/// The task's card for `purpose`, made if none is open, waited on a while: the option the user picked, answered in Zero
/// (never read back from the log). Not answered in time, the call says so and the card stays for the next call.
#[allow(clippy::too_many_arguments)]
async fn approve(
    zerod: &Zerod, conversation: &crate::model::Conversation, purpose: &str, name: &str, title: &str, body: &str, command: Option<String>,
    options: &[&'static str],
) -> Result<&'static str, String> {
    let (inbox, desktop, session) = (&zerod.inbox, &zerod.desktop, conversation.id.as_str());
    let mut events = inbox.subscribe();
    let id = match desktop.card(session, purpose).filter(|id| inbox.ask(id).is_some()) {
        Some(id) => id,
        None => {
            let mut ask = Ask::new(AskKind::Permission, title, crate::bridge::identity(conversation, &crate::bridge::hostname()), CARD_TTL);
            ask.body = body.into();
            ask.command = command;
            ask.options = options.iter().map(|o| o.to_string()).collect();
            let id = inbox.create(ask, false).id;
            desktop.keep_card(session, purpose, &id);
            tokio::spawn(watch(zerod.clone(), session.to_string(), purpose.to_string(), id.clone(), name.to_string()));
            id
        }
    };
    let deadline = tokio::time::Instant::now() + desktop.card_wait();
    loop {
        // Gone from the inbox (trimmed, dismissed): no yes.
        let Some(ask) = inbox.ask(&id) else {
            desktop.drop_card(session, purpose);
            return Ok(DENY);
        };
        if ask.state.is_final() {
            desktop.drop_card(session, purpose);
            return match ask.state {
                AskState::Answered if inbox.answered_here(&id) => Ok(ask.choice.and_then(|c| options.get(c)).copied().unwrap_or(DENY)),
                AskState::Expired => Err("The user didn't answer the card in time: ask them (zero ask) before trying again.".into()),
                _ => Ok(DENY),
            };
        }
        // Any change (or a lagging receiver) is a reason to look again.
        match tokio::time::timeout_at(deadline, events.recv()).await {
            Err(_) => return Err(format!("Waiting for the user to allow {name} on a Zero card: call again later.")),
            Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => return Err("Zero's inbox closed".into()),
            Ok(_) => {}
        }
    }
}

/// A card answered with no call waiting on it (the call said it was waiting and returned): an allow for the task is
/// kept at once, whatever the turn does since, and the task is told, so an agent that went on (or ended its turn) knows.
async fn watch(zerod: Zerod, session: String, purpose: String, id: String, name: String) {
    let (inbox, desktop) = (&zerod.inbox, &zerod.desktop);
    let mut events = inbox.subscribe();
    let ask = loop {
        match inbox.ask(&id) {
            Some(ask) if ask.state.is_final() => break ask,
            Some(_) => {}
            None => return,
        }
        if let Err(tokio::sync::broadcast::error::RecvError::Closed) = events.recv().await {
            return;
        }
    };
    if ask.state != AskState::Answered || !inbox.answered_here(&id) {
        return;
    }
    let choice = ask.choice.and_then(|c| ask.options.get(c)).cloned().unwrap_or_default();
    if choice == FOR_TASK {
        desktop.allow(&session, &purpose)
    }
    // A call waiting on it takes it in a moment; one that isn't leaves it here.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    if desktop.card(&session, &purpose).as_deref() == Some(id.as_str()) {
        if choice == FOR_TASK {
            desktop.drop_card(&session, &purpose)
        }
        zerod.daemon.tell_from_zero(&session, &format!("The user answered the card for {name}: {choice}. Call the desktop tool again."));
    }
}
