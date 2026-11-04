//! Integrations over the socket: their settings and views, what a view shows now, connecting Linear and Slack, and a
//! view's item started as a task.

use serde_json::{Value, json};

use super::{Request, Zerod, unknown};
use crate::daemon::Daemon;
use crate::model::{Permissions, Provider};

/// Integrations: their settings and views, what a view shows now, and connecting Linear.
pub(super) async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let (daemon, integrations) = (&zerod.daemon, &zerod.integrations);
    let state = |settings: crate::integrations::Settings| state_of(integrations, settings);
    match request.op.as_str() {
        "integrations" => { integrations.github_account().await; Ok(state(integrations.settings())) }
        "setIntegration" => integrations.set_enabled(&request.integration()?, request.enabled.ok_or("On or off?")?).map(state),
        "saveView" => integrations.save_view(&request.integration()?, request.view.clone().ok_or("Which view?")?).map(state),
        "deleteView" => integrations.delete_view(&request.integration()?, &request.view()?).map(state),
        "orderViews" => integrations.order_views(&request.integration()?, request.ids.as_deref().ok_or("Which views, in what order?")?).map(state),
        "viewItems" if request.cached == Some(true) => match integrations.cached(&format!("{}/{}", request.integration()?, request.view()?)) {
            Some(kept) => Ok(json!(crate::integrations::with_tasks(serde_json::from_value(kept).unwrap_or_default(), &tasks(daemon)))),
            None => Ok(Value::Null),
        },
        "viewItems" => integrations.items(&request.integration()?, &request.view()?).await.map(|items| json!(crate::integrations::with_tasks(items, &tasks(daemon)))),
        "startTask" => start_task(zerod, &request.integration()?, &request.view()?, request.item.clone().ok_or("Which item?")?),
        "linearTeams" if request.cached == Some(true) => Ok(integrations.cached("linear/teams").unwrap_or_default()),
        "linearTeams" => integrations.linear_teams().await,
        "connectLinear" => integrations.connect_linear().await.map(|url| json!({"url": url})),
        "disconnectLinear" => integrations.disconnect_linear().map(|_| state(integrations.settings())),
        "connectSlack" => { integrations.connect_slack(request.token.as_deref().ok_or("Slack's user token (xoxp-…)")?).await?; Ok(state(integrations.settings())) }
        "disconnectSlack" => integrations.disconnect_slack().map(|_| state(integrations.settings())),
        "refreshSlack" => { integrations.refresh_slack().await?; Ok(state(integrations.settings())) }
        other => unknown(other),
    }
}

/// What the app shows of the integrations: their settings, and who each is connected as.
fn state_of(integrations: &crate::integrations::Integrations, settings: crate::integrations::Settings) -> Value {
    json!({"settings": settings, "linear": integrations.linear_workspace(), "github": integrations.github_known(), "slack": integrations.slack_state()})
}

/// Each session filed under a ticket: (ticket, session).
fn tasks(daemon: &Daemon) -> Vec<(String, String)> {
    daemon.sessions().iter().map(|s| s.summary()).filter_map(|c| Some((c.ticket?, c.id))).collect()
}

/// One task per item: its existing one, or a new one from the view's template with a state pad of its own in
/// Tasks/<ticket>.
fn start_task(zerod: &Zerod, integration: &str, view: &str, item: Value) -> Result<Value, String> {
    let item: crate::integrations::Item = serde_json::from_value(item).map_err(|e| format!("Not an item: {e}"))?;
    let ticket = item.ticket();
    let folder = format!("{}/{ticket}", crate::pads::TASKS);
    let pad = |pads: &crate::pads::Pads| pads.list_in(None, Some(&folder)).into_iter().find(|p| p.title == "State" && p.folder == folder).map(|p| p.link);
    if let Some((_, session)) = tasks(&zerod.daemon).into_iter().find(|(t, _)| *t == ticket) {
        return Ok(json!({"session": session, "existing": true, "pad": pad(&zerod.pads)}));
    }
    let (name, start) = zerod.integrations.start_of(integration, view)?;
    let start = start.ok_or_else(|| format!("{name} doesn't start tasks yet: give it a folder and a prompt in Integrations"))?;
    let pad = match pad(&zerod.pads) {
        Some(link) => link,
        None => zerod.pads.create("State", &folder, &format!("# {ticket} {}

{}

## State

## Next
", item.title, item.url))?.link,
    };
    let provider: Provider = serde_json::from_value(json!(start.provider.as_deref().unwrap_or("claude"))).map_err(|_| "The provider is codex, claude or opencode")?;
    let permissions: Option<Permissions> = start.permissions.as_ref().map(|p| serde_json::from_value(json!(p))).transpose().map_err(|_| "Permissions are auto or unrestricted")?;
    let options = crate::daemon::Options {
        cwd: Some(match start.cwd.strip_prefix("~/") { Some(rest) => format!("{}/{rest}", std::env::var("HOME").unwrap_or_default()), None => start.cwd.clone() }),
        workspace: None, model: start.model.clone(), effort: start.effort.clone(), permissions: Some(permissions.unwrap_or_default()),
        label: Some(format!("{ticket} {}", item.title)), ticket: Some(ticket), force: false, images: vec![], signin: None, parent: None,
    };
    let session = zerod.daemon.start(provider, &crate::integrations::task_prompt(&start.prompt, &item, &pad), options)?;
    Ok(json!({"session": session, "existing": false, "pad": pad}))
}
