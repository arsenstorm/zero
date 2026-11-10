//! Browsers over the socket: a task's browser calls, each browser's state and settings, and setting them up.

use serde_json::{Value, json};

use super::{Request, Zerod, unknown};

pub(super) async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    match request.op.as_str() {
        "browserCall" => call(zerod, &request).await,
        "browsers" => Ok(zerod.browsers.list(request.session.as_deref())),
        "browserState" => {
            zerod
                .browsers
                .tell_state(&request.session()?, request.browser.as_ref().and_then(|b| b["state"].as_str()).ok_or("Which state?")?);
            Ok(Value::Null)
        }
        // Safari tried (Settings › Browsers): its automation session started, as browser_compare starts it.
        "checkSafari" => {
            zerod.browsers.safari().ok_or("Safari isn't set up in Zero")?.check().await?;
            Ok(Value::Null)
        }
        // Firefox opened under remote control (Settings › Browsers), its extension installed.
        "openFirefox" => {
            zerod.browsers.firefox().ok_or("Firefox isn't set up in Zero")?.ensure().await?;
            Ok(Value::Null)
        }
        // A Chrome debugger command from Zero's extension in Firefox, done through Firefox's remote control.
        "firefox" => {
            let args = request.args.as_ref().ok_or("Which command?")?;
            let firefox = zerod.browsers.firefox().ok_or("Firefox isn't set up in Zero")?;
            firefox
                .command(
                    args["tab"].as_i64().ok_or("Which tab?")?,
                    args["nonce"].as_str(),
                    args["method"].as_str().ok_or("Which method?")?,
                    &args["params"],
                )
                .await
        }
        "browserSettings" => Ok(zerod.browsers.settings()),
        "saveBrowserSettings" => zerod.browsers.save_settings(request.browser.as_ref().ok_or("Which settings?")?),
        "browserSetup" => setup(),
        other => unknown(other),
    }
}

/// A browser tool called by a task (or Zero), in its own group of tabs.
async fn call(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    let session = request.session.as_deref();
    let conversation = session.and_then(|s| daemon.get(s));
    // A task's group is its own; its window is its team's (its lead's, through every level).
    let mut lead = conversation.clone();
    while let Some(parent) = lead.as_ref().and_then(|c| c.parent.clone()).and_then(|p| daemon.get(&p)) {
        lead = Some(parent)
    }
    let task = json!({
        "session": session, "group": session.unwrap_or("zero"), "window": lead.as_ref().map(|l| l.id.as_str()).unwrap_or("zero"),
        "name": conversation.as_ref().map(crate::bridge::label).unwrap_or_else(|| "Zero".into()),
        "state": "working",
        // What the group is called: Zero, and the work's reference when it has one (its own, else its lead's).
        "ticket": conversation.as_ref().and_then(|c| c.ticket.clone()).or_else(|| lead.as_ref().and_then(|l| l.ticket.clone())),
    });
    let tool = request.tool.as_deref().ok_or("Which tool?")?;
    let args = request.args.clone().unwrap_or(json!({}));
    if let Some(conversation) = &conversation {
        review(zerod, conversation, tool, &args).await?
    }
    zerod.browsers.call(session, task, tool, args).await
}

/// Chrome's native host installed for this zerod, and where Zero for Chrome is to load from.
fn setup() -> Result<Value, String> {
    let zerod_exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let manifest = crate::browser::install(&zerod_exe)?;
    let extension =
        zerod_exe.parent().and_then(|macos| macos.parent()).map(|contents| contents.join("Resources/chrome")).unwrap_or_default();
    Ok(json!({"manifest": manifest, "extension": extension, "id": crate::browser::EXTENSION}))
}

/// In auto mode, a site new to the task gets a second opinion before the task may open it: a one-shot run of the task's
/// own CLI. A refusal stands unless the user approved the site through an ask (`zero approve`, whose id the agent passes
/// as `approval`). ponytail: only browser_navigate is reviewed; a click that leaves for another site isn't.
async fn review(zerod: &Zerod, conversation: &crate::model::Conversation, tool: &str, args: &Value) -> Result<(), String> {
    if tool != "browser_navigate" || conversation.permissions != crate::model::Permissions::Auto {
        return Ok(());
    }
    let Some(site) = args["url"].as_str().and_then(crate::browser::site) else { return Ok(()) };
    if zerod.browsers.allowed(&conversation.id, &site) {
        return Ok(());
    }
    if let Some(approval) = args["approval"].as_str() {
        let approved = zerod.inbox.asks().iter().any(|ask| {
            ask.id == approval
                && ask.kind == crate::ask::AskKind::Approve
                && ask.state == crate::ask::AskState::Answered
                && format!("{} {}", ask.title, ask.body).to_lowercase().contains(&site)
        });
        if !approved {
            return Err(format!(
                "Ask {approval} isn't the user's approval of {site}: it must be an approve they said yes to, naming {site}"
            ));
        }
        zerod.browsers.allow(&conversation.id, &site);
        return Ok(());
    }
    // What the user asked first, and what they asked last: a long task's current work is in the latter.
    let full = zerod.daemon.session(&conversation.id).map(|s| s.snapshot()).unwrap_or_else(|_| conversation.clone());
    let yours: Vec<String> = full
        .items
        .iter()
        .filter_map(|item| match &item.kind {
            crate::model::ItemKind::User { text, .. } if crate::model::from(text).is_none() => {
                Some(text.chars().take(600).collect::<String>())
            }
            _ => None,
        })
        .collect();
    let asked = match (yours.first(), yours.last()) {
        (Some(first), Some(last)) if first != last => format!("{first}\" and most recently: \"{last}"),
        (Some(first), _) => first.clone(),
        _ => String::new(),
    };
    let prompt = crate::browser::review_prompt(&crate::bridge::label(conversation), &asked, args["url"].as_str().unwrap_or_default());
    let (_, printed) = crate::process::run(
        &crate::browser::review_command(conversation.provider, &prompt),
        std::path::Path::new(&conversation.cwd),
        &conversation.id,
    )
    .await;
    match crate::browser::verdict(&printed) {
        Ok(_) => {
            zerod.browsers.allow(&conversation.id, &site);
            Ok(())
        }
        Err(why) => Err(format!(
            "Zero's reviewer advised against opening {site}: {}. If the task needs it, ask the user with zero approve \"Open {site} in Chrome\" and pass the ask's id as approval",
            why.trim_end_matches('.')
        )),
    }
}
