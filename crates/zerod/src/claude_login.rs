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
        let login = ["/usr/bin/script", "-q", "/dev/null"].into_iter().map(String::from)
            .chain(crate::adapter::login_shell(&["claude", "auth", "login", "--claudeai"])).collect();
        Commands { login, status: crate::adapter::login_shell(&["claude", "auth", "status", "--json"]) }
    }
}

/// Signs in with `env` (the account's CLAUDE_CONFIG_DIR): `page` is given the sign-in page Claude Code prints, or
/// none; the account comes once Claude Code says it's signed in.
pub async fn sign_in(commands: &Commands, env: &[(String, String)], page: tokio::sync::oneshot::Sender<Option<String>>) -> Result<Account, String> {
    let mut login = tokio::process::Command::new(&commands.login[0]);
    login.args(&commands.login[1..]).envs(env.iter().cloned()).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true);
    let mut child = login.spawn().map_err(|e| format!("Couldn't start Claude Code: {e}"))?;
    let mut lines = tokio::io::BufReader::new(child.stdout.take().ok_or("Claude Code has no output")?).lines();
    let mut page = Some(page);
    while let Ok(Some(line)) = lines.next_line().await {
        if let Some(url) = link(&line) && let Some(page) = page.take() { let _ = page.send(Some(url)); }
    }
    if let Some(page) = page { let _ = page.send(None); }
    let _ = child.wait().await;
    let status = tokio::process::Command::new(&commands.status[0]).args(&commands.status[1..]).envs(env.iter().cloned())
        .stdin(Stdio::null()).stderr(Stdio::null()).output().await.map_err(|e| format!("Couldn't ask Claude Code: {e}"))?;
    let said: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap_or_default();
    if said["loggedIn"] != true { return Err("Claude Code didn't sign in".into()) }
    Ok(Account { email: said["email"].as_str().map(String::from), plan: said["subscriptionType"].as_str().map(String::from) })
}

/// The first web address in a line of a terminal's output, its control sequences and carriage returns left behind.
fn link(line: &str) -> Option<String> {
    let start = line.find("https://")?;
    let url: String = line[start..].chars().take_while(|c| !c.is_whitespace() && !c.is_control()).collect();
    (url.len() > "https://".len()).then_some(url)
}
