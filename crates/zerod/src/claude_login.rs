//! Signing a Claude account in through Claude Code's own `claude auth login`, in a folder of that account's own
//! (signins.rs): Claude Code opens its page in the browser, hears it come back, and keeps the sign-in there. Zero
//! passes its page on (in case the browser didn't open) and reads who signed in from `claude auth status`.

use std::process::Stdio;

use tokio::io::AsyncBufReadExt;

use crate::codex_login::Account;

/// The two commands, as the login shell runs them; stand-ins in tests.
pub struct Commands {
    pub login: Vec<String>,
    pub status: Vec<String>,
}

impl Commands {
    pub fn claude() -> Commands {
        // A terminal of its own (`script`): Claude Code's sign-in expects one.
        let login = ["/usr/bin/script", "-q", "/dev/null"]
            .into_iter()
            .map(String::from)
            .chain(crate::adapter::login_shell(&["claude", "auth", "login", "--claudeai"]))
            .collect();
        Commands { login, status: crate::adapter::login_shell(&["claude", "auth", "status", "--json"]) }
    }
}

/// Signs in with `env` (the account's CLAUDE_CONFIG_DIR): `page` is given the sign-in page Claude Code prints, or
/// none; the account comes once Claude Code says it's signed in.
pub async fn sign_in(
    commands: &Commands, env: &[(String, String)], page: tokio::sync::oneshot::Sender<Option<String>>,
) -> Result<Account, String> {
    let mut login = tokio::process::Command::new(&commands.login[0]);
    login
        .args(&commands.login[1..])
        .envs(env.iter().cloned())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = login.spawn().map_err(|e| format!("Couldn't start Claude Code: {e}"))?;
    let mut lines = tokio::io::BufReader::new(child.stdout.take().ok_or("Claude Code has no output")?).lines();
    let mut page = Some(page);
    while let Ok(Some(line)) = lines.next_line().await {
        if let Some(url) = link(&line)
            && let Some(page) = page.take()
        {
            let _ = page.send(Some(url));
        }
    }
    if let Some(page) = page {
        let _ = page.send(None);
    }
    let _ = child.wait().await;
    let status = tokio::process::Command::new(&commands.status[0])
        .args(&commands.status[1..])
        .envs(env.iter().cloned())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .await
        .map_err(|e| format!("Couldn't ask Claude Code: {e}"))?;
    let said: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap_or_default();
    if said["loggedIn"] != true {
        return Err("Claude Code didn't sign in".into());
    }
    Ok(Account { email: said["email"].as_str().map(String::from), plan: said["subscriptionType"].as_str().map(String::from) })
}

/// Claude Code waiting on stream-json, with none of the user's settings, plugins or MCP servers: asked only for usage.
pub fn usage_command() -> Vec<String> {
    crate::adapter::login_shell(&[
        "claude",
        "-p",
        "--setting-sources",
        "",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
    ])
}

/// How much of its plan's windows the account `env` signs in as has used, asked of Claude Code (`get_usage`): no turn,
/// nothing spent.
pub async fn usage(command: &[String], env: &[(String, String)]) -> Result<crate::model::Usage, String> {
    use tokio::io::AsyncWriteExt;
    let mut claude = tokio::process::Command::new(&command[0]);
    claude
        .args(&command[1..])
        .envs(env.iter().cloned())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = claude.spawn().map_err(|e| format!("Couldn't start Claude Code: {e}"))?;
    let ask =
        serde_json::json!({"type": "control_request", "request_id": "usage", "request": {"subtype": "get_usage", "skip_behaviors": true}});
    child.stdin.as_mut().ok_or("Claude Code has no input")?.write_all(format!("{ask}\n").as_bytes()).await.map_err(|e| e.to_string())?;
    let mut lines = tokio::io::BufReader::new(child.stdout.take().ok_or("Claude Code has no output")?).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(message) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
        let response = &message["response"];
        if message["type"] != "control_response" || response["request_id"] != "usage" {
            continue;
        }
        if response["subtype"] != "success" {
            return Err(response["error"].as_str().unwrap_or("Claude Code didn't say").into());
        }
        // No plan limits for this account (API-billed); a Claude Code token can't read them (no profile scope), but
        // tokens aren't read (server/signins.rs).
        if response["response"]["rate_limits_available"] == false {
            return Ok(crate::model::Usage { no_limits: true, ..Default::default() });
        }
        return Ok(plan_usage(&response["response"]["rate_limits"]));
    }
    Err("Claude Code stopped before it answered".into())
}

/// `get_usage`'s rate limits: each window's use (0 to 100) and reset; one it has no figure for is left out.
fn plan_usage(limits: &serde_json::Value) -> crate::model::Usage {
    let windows: Vec<crate::model::UsageWindow> = [("five_hour", "5 hours"), ("seven_day", "7 days")]
        .iter()
        .filter_map(|(key, name)| {
            let window = limits.get(*key).filter(|w| w.is_object())?;
            Some(crate::model::UsageWindow {
                name: (*name).into(),
                used: window["utilization"].as_f64()? / 100.0,
                resets_at: window["resets_at"].as_str().and_then(crate::ask::Time::parse).map(|t| t.0),
                read_at: Some(crate::now()),
            })
        })
        .collect();
    let full = windows.iter().find(|w| w.used >= 1.0);
    crate::model::Usage { limited: full.is_some(), resets_at: full.and_then(|w| w.resets_at), windows, ..Default::default() }
}

/// The first web address in a line of a terminal's output, its control sequences and carriage returns left behind.
fn link(line: &str) -> Option<String> {
    let start = line.find("https://")?;
    let url: String = line[start..].chars().take_while(|c| !c.is_whitespace() && !c.is_control()).collect();
    (url.len() > "https://".len()).then_some(url)
}

/// `claude -p` waiting on stream-json with the user's own settings, plugins and MCP servers (and Zero's, as `mcp`
/// gives them), keeping no session: what signs in to an MCP server.
pub fn mcp_command(mcp: Option<&str>) -> Vec<String> {
    let mut args =
        vec!["claude", "-p", "--no-session-persistence", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"];
    if let Some(config) = mcp {
        args.extend(["--mcp-config", config])
    }
    crate::adapter::login_shell(&args)
}

/// Signs in to MCP server `server` through Claude Code's own OAuth (`mcp_authenticate`), in a Claude of its own run in
/// `cwd` with `env` (the task's account and MCP values): `page` is given Claude's link for the user, and Claude, which
/// hears the callback and keeps the token, is asked every `every` whether the server has connected. No turn, nothing
/// spent; Zero never calls the server itself.
pub async fn mcp_sign_in(
    command: &[String], env: &[(String, String)], cwd: &str, server: &str, page: tokio::sync::oneshot::Sender<String>,
    every: std::time::Duration,
) -> Result<(), String> {
    use tokio::io::AsyncWriteExt;
    let mut claude = tokio::process::Command::new(&command[0]);
    claude
        .args(&command[1..])
        .envs(env.iter().cloned())
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = claude.spawn().map_err(|e| format!("Couldn't start Claude Code: {e}"))?;
    let mut input = child.stdin.take().ok_or("Claude Code has no input")?;
    let mut lines = tokio::io::BufReader::new(child.stdout.take().ok_or("Claude Code has no output")?).lines();
    let mut ask = async |id: &str, request: serde_json::Value| -> Result<serde_json::Value, String> {
        let line = serde_json::json!({"type": "control_request", "request_id": id, "request": request});
        input.write_all(format!("{line}\n").as_bytes()).await.map_err(|e| format!("Claude Code closed: {e}"))?;
        while let Some(line) = lines.next_line().await.map_err(|e| e.to_string())? {
            let Ok(message) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
            let response = &message["response"];
            if message["type"] != "control_response" || response["request_id"] != id {
                continue;
            }
            if response["subtype"] != "success" {
                return Err(response["error"].as_str().unwrap_or("Claude Code refused").into());
            }
            return Ok(response["response"].clone());
        }
        Err("Claude Code stopped before it had signed in".into())
    };
    let started = ask("auth", serde_json::json!({"subtype": "mcp_authenticate", "serverName": server})).await?;
    let Some(url) = started["authUrl"].as_str() else { return Ok(()) };
    let _ = page.send(url.into());
    for n in 1.. {
        tokio::time::sleep(every).await;
        let status = ask(&format!("status-{n}"), serde_json::json!({"subtype": "mcp_status"})).await?;
        let servers = status["mcpServers"].as_array().cloned().unwrap_or_default();
        if servers.iter().any(|s| s["name"] == server && s["status"] == "connected") {
            break;
        }
    }
    Ok(())
}
