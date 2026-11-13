//! Integrations over the socket: who each is connected as, and connecting Linear and Slack.

use serde_json::{Value, json};

use super::{Request, Zerod, unknown};

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
        other => unknown(other),
    }
}

/// What the app shows of the integrations: who each is connected as, and Linear's team keys for linking issue ids.
fn state_of(integrations: &crate::integrations::Integrations) -> Value {
    json!({"linear": integrations.linear_workspace(), "linearTeams": integrations.linear_teams(), "github": integrations.github_known(),
        "slack": integrations.slack_state()})
}
