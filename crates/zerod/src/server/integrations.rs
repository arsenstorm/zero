//! Integrations over the socket: who each is connected as, connecting Linear and Slack, and agents' calls through
//! those connections (`zero slack`, `zero linear`): reads as they are, writes only once the user lets agents make
//! them, each approved by the user first.

use serde_json::{Value, json};

use super::{Request, Settings, Zerod, unknown};
use crate::ask::{Ask, AskKind, AskState};

pub(super) async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let integrations = &zerod.integrations;
    let state = || state_of(integrations);
    match request.op.as_str() {
        "integrations" => {
            integrations.github_account().await;
            Ok(state())
        }
        "linearTeams" => {
            integrations.refresh_linear_teams().await?;
            Ok(state())
        }
        "connectLinear" => integrations.connect_linear().await.map(|url| json!({"url": url})),
        "disconnectLinear" => integrations.disconnect_linear().map(|_| state()),
        "connectSlack" => {
            integrations.connect_slack(request.token.as_deref().ok_or("Slack's user token (xoxp-…)")?).await?;
            Ok(state())
        }
        "disconnectSlack" => integrations.disconnect_slack(request.team.as_deref().ok_or("Which Slack workspace?")?).map(|_| state()),
        "refreshSlack" => {
            integrations.refresh_slack().await?;
            Ok(state())
        }
        "slack" => slack(zerod, &request).await,
        "linear" => linear(zerod, &request).await,
        other => unknown(other),
    }
}

/// `zero slack <method> [key=value…]`: a Web API method, its parameters, the workspace, and an approval for a write.
async fn slack(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let args = request.args.clone().unwrap_or_default();
    let method = args["method"].as_str().filter(|m| !m.is_empty()).ok_or("Which Slack method? Such as conversations.history")?;
    let params: Vec<(String, String)> = args["params"]
        .as_object()
        .into_iter()
        .flatten()
        .map(|(key, value)| (key.clone(), value.as_str().map_or_else(|| value.to_string(), String::from)))
        .collect();
    let workspace = args["workspace"].as_str().filter(|w| !w.is_empty());
    if !crate::integrations::slack_reads(method) {
        let shown: Vec<String> = params.iter().map(|(k, v)| format!("{k}={v}")).collect();
        let call = format!("{method}{}\n{}", workspace.map(|w| format!(" (in {w})")).unwrap_or_default(), shown.join("\n"));
        let allowed = zerod.integrations.writes().slack_posts;
        let why = format!("{method} isn't one of the Slack methods agents may call to read");
        permit(
            zerod,
            request,
            &args,
            Write { allowed, setting: "Settings › Slack › Let agents post", title: "Post to Slack?", why, call },
        )?;
    }
    zerod.integrations.slack_for_agent(workspace, method, &params).await
}

/// `zero linear '<graphql>' [--variables JSON]`: a query, or with the user's leave, a mutation.
async fn linear(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let args = request.args.clone().unwrap_or_default();
    let query = args["query"].as_str().map(str::trim).filter(|q| !q.is_empty()).ok_or("Which GraphQL query?")?;
    let variables = Some(&args["variables"]).filter(|v| !v.is_null());
    if crate::integrations::changes_linear(query) {
        let call = match variables {
            Some(variables) => format!("{query}\n\nvariables: {variables}"),
            None => query.to_string(),
        };
        let allowed = zerod.integrations.writes().linear_changes;
        let why = "It's a mutation".to_string();
        permit(
            zerod,
            request,
            &args,
            Write { allowed, setting: "Settings › Linear › Let agents make changes", title: "Change Linear?", why, call },
        )?;
    }
    zerod.integrations.linear_for_agent(query, variables).await
}

/// A write an agent asked for: whether the user lets agents make them, where they say so, what the approval asks,
/// why it's a write, and the call as the user approves it (an approval is for this call alone).
struct Write {
    allowed: bool,
    setting: &'static str,
    title: &'static str,
    why: String,
    call: String,
}

/// Lets a write through once the user approved this very call, for this task, and only once. Without an approval it
/// asks for one (the agent hears the answer as a message, then makes the call again with it).
fn permit(zerod: &Zerod, request: &Request, args: &Value, write: Write) -> Result<(), String> {
    let Write { allowed, setting, title, why, call } = write;
    if !allowed {
        return Err(format!("{why}: agents read only, unless the user turns on {setting}. If the task needs it, ask the user."));
    }
    let session = request.session.as_deref().ok_or("Writes are for Zero's tasks, each approved by the user: run this in one")?;
    if let Some(approval) = args["approval"].as_str() {
        // Answered by the user while this zerod ran: an answer read back from asks.jsonl, a file any process of the
        // user's can write, isn't taken for one.
        let approved = zerod.inbox.answered_here(approval)
            && zerod.inbox.ask(approval).is_some_and(|ask| {
                ask.kind == AskKind::Approve
                    && ask.state == AskState::Answered
                    && ask.agent.reference.as_deref() == Some(session)
                    && ask.command.as_deref() == Some(call.as_str())
            });
        if !approved || !zerod.integrations.spend(approval) {
            return Err(format!(
                "Ask {approval} isn't the user's approval of this call: an approval is for the exact call it showed, once, and only once they said yes"
            ));
        }
        return Ok(());
    }
    let conversation = zerod.daemon.get(session).ok_or_else(|| format!("No session {session}"))?;
    let agent = crate::bridge::identity(&conversation, &crate::bridge::hostname());
    let mut ask = Ask::new(AskKind::Approve, title, agent, Settings::load(zerod.daemon.home()).ttl.unwrap_or(3600));
    ask.body = "The task makes this call through Zero's connection once you approve it.".into();
    ask.command = Some(call);
    ask.options = ["Yes", "No", "Suggest something else…"].map(String::from).to_vec();
    // The answer goes to the task as a message: nothing waits on it.
    ask.waits = Some(false);
    let id = zerod.inbox.create(ask, false).id;
    Err(format!(
        "{why}, so it needs the user's approval: asked them (ask {id}). End your turn with [zero: asked {id}]; once they approve, make the same call again with approval {id}."
    ))
}

/// What the app shows of the integrations: who each is connected as, and Linear's team keys for linking issue ids.
fn state_of(integrations: &crate::integrations::Integrations) -> Value {
    json!({"linear": integrations.linear_workspace(), "linearTeams": integrations.linear_teams(), "github": integrations.github_known(),
        "slack": integrations.slack_state()})
}
