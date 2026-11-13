//! Signing a Codex account in through Codex's own app-server, run in that account's home (signins.rs): Codex shows
//! its ChatGPT sign-in page, hears the browser come back, and keeps what it's given in that home. Zero asks it to
//! start, passes its page on for the user to open, and reads back who signed in. Codex's "client supplies the tokens"
//! mode is OpenAI's internal one, and isn't used.

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

pub enum Method {
    /// Codex's ChatGPT sign-in, in the browser.
    ChatGpt,
    /// An OpenAI API key, given to Codex to keep.
    ApiKey(String),
}

#[derive(Debug, Default)]
pub struct Account {
    pub email: Option<String>,
    pub plan: Option<String>,
}

/// Signs in over an app-server's stdio. `page` is given Codex's sign-in page as soon as there is one (none for a
/// key); the account comes once the user has signed in there.
pub async fn sign_in<R, W>(
    reader: R, mut writer: W, method: Method, page: tokio::sync::oneshot::Sender<Option<String>>,
) -> Result<Account, String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    greet(&mut lines, &mut writer).await?;
    let params = match &method {
        Method::ChatGpt => json!({"type": "chatgpt"}),
        Method::ApiKey(key) => json!({"type": "apiKey", "apiKey": key}),
    };
    write(&mut writer, json!({"id": 2, "method": "account/login/start", "params": params})).await?;
    let started = answer(&mut lines, 2).await?;
    let _ = page.send(started["authUrl"].as_str().map(String::from));
    if let Method::ChatGpt = method {
        // The user signs in in the browser; Codex says when that's done (or wasn't).
        loop {
            let message = next(&mut lines).await?;
            if message["method"] != "account/login/completed" {
                continue;
            }
            if message["params"]["success"] != true {
                return Err(format!("Codex didn't sign in: {}", message["params"]["error"].as_str().unwrap_or("no reason given")));
            }
            break;
        }
    }
    read(&mut lines, &mut writer).await
}

/// Who the home an app-server runs in is signed in as, asked of Codex without signing in.
pub async fn account<R, W>(reader: R, mut writer: W) -> Result<Account, String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    greet(&mut lines, &mut writer).await?;
    read(&mut lines, &mut writer).await
}

/// How much of its plan's windows the home's account has used, as Codex reads it: no task needed. Codex saying the
/// account may not go on (`ordinaryUsageAllowed`) is a limit whatever the figures; no window at all, a plan without.
pub async fn rate_limits<R, W>(reader: R, mut writer: W) -> Result<crate::model::Usage, String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    greet(&mut lines, &mut writer).await?;
    write(&mut writer, json!({"id": 4, "method": "account/rateLimits/read"})).await?;
    let read = answer(&mut lines, 4).await?;
    let mut usage = crate::codex::usage(&read["rateLimits"]);
    usage.limited |= read["ordinaryUsageAllowed"] == false;
    usage.no_limits = usage.windows.is_empty() && !usage.limited;
    Ok(usage)
}

async fn greet<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
    lines: &mut tokio::io::Lines<BufReader<R>>, writer: &mut W,
) -> Result<(), String> {
    write(writer, json!({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "zero", "title": "Zero", "version": env!("CARGO_PKG_VERSION")},
                                                                     "capabilities": {"experimentalApi": false, "requestAttestation": false}}})).await?;
    answer(lines, 1).await?;
    write(writer, json!({"method": "initialized"})).await
}

async fn read<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
    lines: &mut tokio::io::Lines<BufReader<R>>, writer: &mut W,
) -> Result<Account, String> {
    write(writer, json!({"id": 3, "method": "account/read", "params": {}})).await?;
    let account = &answer(lines, 3).await?["account"];
    Ok(Account { email: account["email"].as_str().map(String::from), plan: account["planType"].as_str().map(String::from) })
}

async fn write<W: AsyncWrite + Unpin>(writer: &mut W, message: Value) -> Result<(), String> {
    writer.write_all(format!("{message}\n").as_bytes()).await.map_err(|e| format!("Codex closed: {e}"))
}

async fn next<R: AsyncRead + Unpin>(lines: &mut tokio::io::Lines<BufReader<R>>) -> Result<Value, String> {
    loop {
        let line = lines.next_line().await.map_err(|e| e.to_string())?.ok_or("Codex stopped before it had signed in")?;
        if let Ok(message) = serde_json::from_str::<Value>(&line) {
            return Ok(message);
        }
    }
}

/// The answer to request `id`, what comes before it passed over.
async fn answer<R: AsyncRead + Unpin>(lines: &mut tokio::io::Lines<BufReader<R>>, id: u64) -> Result<Value, String> {
    loop {
        let message = next(lines).await?;
        if message["id"] != id || message.get("method").is_some() {
            continue;
        }
        if let Some(error) = message.get("error") {
            return Err(format!("Codex refused: {}", error["message"].as_str().unwrap_or("no reason given")));
        }
        return Ok(message["result"].clone());
    }
}

/// Signs in to MCP server `server` through Codex's own OAuth (`mcpServer/oauth/login`), over an app-server's stdio: `page`
/// is given Codex's link for the user; Codex hears the callback, keeps the token and says when it's done.
pub async fn mcp_sign_in<R, W>(reader: R, mut writer: W, server: &str, page: tokio::sync::oneshot::Sender<String>) -> Result<(), String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    greet(&mut lines, &mut writer).await?;
    write(&mut writer, json!({"id": 5, "method": "mcpServer/oauth/login", "params": {"name": server}})).await?;
    let started = answer(&mut lines, 5).await?;
    if let Some(url) = started["authorizationUrl"].as_str() {
        let _ = page.send(url.into());
    }
    loop {
        let message = next(&mut lines).await?;
        if message["method"] != "mcpServer/oauthLogin/completed" || message["params"]["name"] != server {
            continue;
        }
        if message["params"]["success"] != true {
            return Err(message["params"]["error"].as_str().unwrap_or("no reason given").into());
        }
        return Ok(());
    }
}
