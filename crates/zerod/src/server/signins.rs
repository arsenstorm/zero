//! Sign-ins over the socket: what each is and each CLI's default, and signing a Codex or Claude account in through
//! its own CLI.

use serde_json::{Value, json};
use tokio::sync::broadcast;

use super::{Request, Zerod, unknown};
use crate::daemon::Daemon;
use crate::model::Provider;

/// The CLIs' sign-ins: what each is (never its value, which the app keeps in the Keychain) and each CLI's default.
pub(super) async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    match request.op.as_str() {
        "signIns" => Ok(list(daemon)),
        // Every account's finished turns by the hour (Unix hours), for the Activity graph, and what each id is (removed
        // sign-ins too; an id that's a CLI's name is its own sign-in): asked for apart from the list, read every minute.
        "accountActivity" => Ok(json!({"hours": daemon.signins.activity(), "accounts": daemon.signins.named()})),
        "saveSignIn" => {
            let signin =
                serde_json::from_value(request.signin.clone().ok_or("Which sign-in?")?).map_err(|e| format!("Not a sign-in: {e}"))?;
            let saved = daemon.signins.save(signin)?;
            let _ = zerod.notices.send("signins");
            Ok(json!(saved))
        }
        // A Codex account signed in by Codex itself, in a home of its own: its page back now, the rest in the background.
        "codexSignIn" => codex_sign_in(zerod, request.signin.as_ref()).await,
        // A Claude account signed in by Claude Code itself, in a folder of its own: the same, through `claude auth login`.
        // With `signin` a token's id: that account signed in again in a folder of its own, the token let go once it is.
        "claudeSignIn" => claude_sign_in(zerod, request.signin.as_ref().and_then(Value::as_str)).await,
        "deleteSignIn" => {
            daemon.signins.delete(request.signin.as_ref().and_then(|s| s.as_str()).ok_or("Which sign-in?")?)?;
            let _ = zerod.notices.send("signins");
            Ok(Value::Null)
        }
        "defaultSignIn" => {
            let chosen = request.signin.as_ref().ok_or("Which sign-in?")?;
            let cli: Provider = serde_json::from_value(chosen["cli"].clone()).map_err(|_| "Which CLI?")?;
            daemon.signins.set_default(cli, chosen["id"].as_str().ok_or("Which sign-in?")?)?;
            let _ = zerod.notices.send("signins");
            Ok(Value::Null)
        }
        // Each account's usage asked of its CLI now (the Accounts page is open), not only when it's next due.
        "readUsage" => {
            daemon.signins.read_now.notify_one();
            Ok(Value::Null)
        }
        other => unknown(other),
    }
}

/// Every subscription's usage, asked of its CLI as that account, for as long as zerod runs: what's kept for choosing
/// accounts by and what the app shows. Each account is read when `next_read` says (a quarter of an hour on, just after
/// a reset, backing off while reads fail) and when woken (`read_now`); one read in the last minute isn't read again.
/// A read that fails keeps what was known, its age showing how old.
pub async fn follow_usage(daemon: std::sync::Arc<Daemon>, notices: broadcast::Sender<&'static str>) {
    // By account: when it's next due, its failed reads running, when it was last tried.
    let mut due: std::collections::HashMap<String, (i64, u32, i64)> = Default::default();
    loop {
        let now = crate::now();
        let mut reads = tokio::task::JoinSet::new();
        for signin in daemon.signins.list().into_iter().filter(|s| !s.pending) {
            if due.get(&signin.id).is_some_and(|(at, _, _)| *at > now) {
                continue;
            }
            let daemon = daemon.clone();
            reads.spawn(async move {
                let read = tokio::time::timeout(std::time::Duration::from_secs(30), usage_of(&daemon, &signin)).await;
                (signin.id, read.unwrap_or_else(|_| Some(Err("its CLI didn't answer in time".into()))))
            });
        }
        let mut read_any = false;
        while let Some(Ok((id, read))) = reads.join_next().await {
            let failures = due.get(&id).map_or(0, |d| d.1);
            let next = match read {
                Some(Ok(usage)) => {
                    daemon.signins.replace_usage(&id, &usage);
                    // Its folder's sign-in may have changed since (signed in again as someone else): named again.
                    daemon.signins.name_claude_folders();
                    read_any = true;
                    (crate::signins::next_read(now, Some(&usage), 0), 0)
                }
                Some(Err(error)) => {
                    eprintln!("zerod: couldn't read {id}'s usage: {error}");
                    (crate::signins::next_read(now, None, failures + 1), failures + 1)
                }
                // Nothing to read (a key, a Claude Code token): its usage comes from its tasks.
                None => (i64::MAX, 0),
            };
            due.insert(id, (next.0, next.1, now));
        }
        if read_any {
            let _ = notices.send("signins");
        }
        tokio::select! {
            _ = tokio::time::sleep(std::time::Duration::from_secs(30)) => {}
            _ = daemon.signins.read_now.notified() => {
                let now = crate::now();
                due.retain(|_, (_, _, tried)| *tried > now - 60);
            }
        }
    }
}

/// One sign-in's usage, asked of its CLI; none for a key, or a Claude Code token (`claude setup-token` has no profile
/// scope, so `get_usage` has no limits to give: its tasks' reports are all there is).
async fn usage_of(daemon: &Daemon, signin: &crate::signins::SignIn) -> Option<Result<crate::model::Usage, String>> {
    use crate::signins::Kind;
    Some(match signin.kind {
        Kind::ClaudeHome => match daemon.signins.environment(signin) {
            Ok(env) => crate::claude_login::usage(&crate::claude_login::usage_command(), &env).await,
            Err(error) => Err(error),
        },
        Kind::CodexHome => {
            let home = daemon.signins.folder(Provider::Codex, &signin.id).ok()?;
            let (_child, input, output) = codex_in(&home).ok()?;
            crate::codex_login::rate_limits(output, input).await
        }
        Kind::ApiKey | Kind::Token => return None,
    })
}

/// Every sign-in, each CLI's default and each sign-in's usage.
fn list(daemon: &Daemon) -> Value {
    let list = daemon.signins.list();
    let defaults: serde_json::Map<String, Value> = [Provider::Claude, Provider::Codex, Provider::Opencode]
        .into_iter()
        .filter_map(|cli| daemon.signins.default_for(cli).map(|s| (format!("{cli:?}").to_lowercase(), json!(s.id))))
        .collect();
    let usage: serde_json::Map<String, Value> =
        list.iter().filter_map(|s| daemon.signins.usage(&s.id).map(|u| (s.id.clone(), json!(u)))).collect();
    let refused: serde_json::Map<String, Value> = list
        .iter()
        .map(|s| (s.id.clone(), json!(daemon.signins.refused(&s.id))))
        .filter(|(_, r)| r.as_array().is_some_and(|r| !r.is_empty()))
        .collect();
    let last = daemon.signins.last_turns();
    let last_turn: serde_json::Map<String, Value> =
        list.iter().filter_map(|s| last.get(&s.id).map(|at| (s.id.clone(), json!(at)))).collect();
    json!({"signins": list, "defaults": defaults, "usage": usage, "refused": refused, "lastTurn": last_turn})
}

/// Starts a Codex sign-in: a pending sign-in and its home, Codex's app-server run there, and its ChatGPT page given
/// back for the app to open (none for an API key). Once Codex says who signed in, the sign-in takes their email and
/// plan; turned down or left for a quarter of an hour, it goes. The key, if one is given, goes only to Codex.
async fn codex_sign_in(zerod: &Zerod, asked: Option<&Value>) -> Result<Value, String> {
    use crate::signins::{Kind, SignIn};
    let key = asked.and_then(|a| a["apiKey"].as_str()).filter(|k| !k.trim().is_empty()).map(|k| k.trim().to_string());
    let label = asked
        .and_then(|a| a["label"].as_str())
        .filter(|l| !l.trim().is_empty())
        .unwrap_or(if key.is_some() { "OpenAI API key" } else { "Codex" })
        .to_string();
    let signins = &zerod.daemon.signins;
    let signin = signins.save(SignIn {
        id: String::new(),
        cli: Provider::Codex,
        kind: Kind::CodexHome,
        label: label.clone(),
        plan: None,
        variable: None,
        pending: true,
    })?;
    let home = signins.folder(Provider::Codex, &signin.id)?;
    let (child, input, output) = codex_in(&home).inspect_err(|_| {
        let _ = signins.delete(&signin.id);
    })?;
    let (page, opened) = tokio::sync::oneshot::channel();
    let method = key.map(crate::codex_login::Method::ApiKey).unwrap_or(crate::codex_login::Method::ChatGpt);
    let (daemon, notices, id) = (zerod.daemon.clone(), zerod.notices.clone(), signin.id.clone());
    tokio::spawn(async move {
        let outcome = tokio::time::timeout(SIGN_IN_TIME, crate::codex_login::sign_in(output, input, method, page))
            .await
            .unwrap_or_else(|_| Err("the sign-in wasn't finished".into()));
        signed_in(&daemon, &notices, &id, label, outcome);
        drop(child);
        name_accounts(&daemon, &notices).await;
    });
    let _ = zerod.notices.send("signins");
    let page = tokio::time::timeout(std::time::Duration::from_secs(30), opened).await.ok().and_then(Result::ok).flatten();
    Ok(json!({"id": signin.id, "page": page}))
}

/// Codex's app-server, run in a sign-in's home.
fn codex_in(home: &std::path::Path) -> Result<(tokio::process::Child, tokio::process::ChildStdin, tokio::process::ChildStdout), String> {
    let argv = Provider::Codex.command(&crate::model::Conversation::new("", Provider::Codex, ""), false, None, None);
    let mut child = tokio::process::Command::new(&argv[0])
        .args(&argv[1..])
        .env("CODEX_HOME", home)
        .current_dir(home)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("Couldn't start Codex: {e}"))?;
    let (Some(input), Some(output)) = (child.stdin.take(), child.stdout.take()) else { return Err("Codex has no stdio".into()) };
    Ok((child, input, output))
}

/// Accounts named by who they are. Codex accounts that don't say (signed in before Zero asked, or Codex hadn't said
/// yet) are asked of Codex, in their homes: the email becomes the name unless the user gave it one, and the plan is kept.
pub async fn name_accounts(daemon: &Daemon, notices: &broadcast::Sender<&'static str>) {
    use crate::signins::Kind;
    // Claude accounts with folders of their own say so in a file there: read at once.
    if daemon.signins.name_claude_folders() {
        let _ = notices.send("signins");
    }
    for mut signin in daemon.signins.list() {
        if signin.kind != Kind::CodexHome || signin.pending || signin.plan.is_some() {
            continue;
        }
        let Ok(home) = daemon.signins.folder(Provider::Codex, &signin.id) else { continue };
        let Ok((child, input, output)) = codex_in(&home) else { continue };
        let account = tokio::time::timeout(std::time::Duration::from_secs(30), crate::codex_login::account(output, input)).await;
        drop(child);
        let Ok(Ok(account)) = account else { continue };
        let before = signin.clone();
        if signin.label == "Codex"
            && let Some(email) = account.email
        {
            signin.label = email
        }
        signin.plan = account.plan;
        if signin != before && daemon.signins.save(signin).is_ok() {
            let _ = notices.send("signins");
        }
    }
}

/// How long a sign-in is waited for in the browser before it's let go.
const SIGN_IN_TIME: std::time::Duration = std::time::Duration::from_secs(15 * 60);

/// A sign-in's end: who signed in, on the pending sign-in; else it goes.
fn signed_in(
    daemon: &Daemon, notices: &broadcast::Sender<&'static str>, id: &str, label: String,
    outcome: Result<crate::codex_login::Account, String>,
) {
    match (outcome, daemon.signins.get(id)) {
        (Ok(account), Some(mut signin)) => {
            signin.label = account.email.unwrap_or(label);
            signin.plan = account.plan;
            signin.pending = false;
            if let Err(error) = daemon.signins.save(signin) {
                eprintln!("zerod: sign-in: {error}")
            }
        }
        (Err(error), _) => {
            eprintln!("zerod: sign-in: {error}");
            let _ = daemon.signins.delete(id);
        }
        (Ok(_), None) => {}
    }
    let _ = notices.send("signins");
}

/// Starts a Claude sign-in: a pending sign-in and its own Claude Code folder, `claude auth login` run there (Claude
/// Code opens its page in the browser), and that page given back in case it didn't open. Once Claude Code is signed
/// in, the sign-in takes the account's email and plan from `claude auth status`. `replacing` a token, the token stays
/// in use while the folder (under its id) signs in, and becomes it once signed in; a sign-in that fails leaves it.
async fn claude_sign_in(zerod: &Zerod, replacing: Option<&str>) -> Result<Value, String> {
    use crate::signins::{Kind, SignIn};
    let signins = &zerod.daemon.signins;
    if let Some(id) = replacing {
        let token = signins.get(id).filter(|s| s.kind == Kind::Token).ok_or("Only a Claude Code token switches to a browser sign-in")?;
        let env = signins.environment(&SignIn { kind: Kind::ClaudeHome, ..token })?;
        let (page, opened) = tokio::sync::oneshot::channel();
        let (daemon, notices, id) = (zerod.daemon.clone(), zerod.notices.clone(), id.to_string());
        let answer = json!({"id": id});
        tokio::spawn(async move {
            let outcome =
                tokio::time::timeout(SIGN_IN_TIME, crate::claude_login::sign_in(&crate::claude_login::Commands::claude(), &env, page))
                    .await
                    .unwrap_or_else(|_| Err("the sign-in wasn't finished".into()));
            match outcome.and_then(|account| daemon.signins.switched_to_folder(&id, account)) {
                Ok(_) => daemon.signins.share_mcp_sign_ins(None),
                Err(error) => {
                    eprintln!("zerod: switching {id} to a browser sign-in: {error}");
                    // The folder, which never signed in, goes; the token carries on.
                    if daemon.signins.get(&id).is_some_and(|s| s.kind == Kind::Token) {
                        let _ = std::fs::remove_dir_all(daemon.home().join("claude-homes").join(&id));
                    }
                }
            }
            daemon.signins.name_claude_folders();
            let _ = notices.send("signins");
        });
        let page = tokio::time::timeout(std::time::Duration::from_secs(3), opened).await.ok().and_then(Result::ok).flatten();
        return Ok(json!({"id": answer["id"], "page": page}));
    }
    let signin = signins.save(SignIn {
        id: String::new(),
        cli: Provider::Claude,
        kind: Kind::ClaudeHome,
        label: "Claude".into(),
        plan: None,
        variable: None,
        pending: true,
    })?;
    let env = signins.environment(&SignIn { pending: false, ..signin.clone() })?;
    let (page, opened) = tokio::sync::oneshot::channel();
    let (daemon, notices, id) = (zerod.daemon.clone(), zerod.notices.clone(), signin.id.clone());
    tokio::spawn(async move {
        let outcome =
            tokio::time::timeout(SIGN_IN_TIME, crate::claude_login::sign_in(&crate::claude_login::Commands::claude(), &env, page))
                .await
                .unwrap_or_else(|_| Err("the sign-in wasn't finished".into()));
        signed_in(&daemon, &notices, &id, "Claude".into(), outcome);
        if daemon.signins.name_claude_folders() {
            let _ = notices.send("signins");
        }
    });
    let _ = zerod.notices.send("signins");
    let page = tokio::time::timeout(std::time::Duration::from_secs(3), opened).await.ok().and_then(Result::ok).flatten();
    Ok(json!({"id": signin.id, "page": page}))
}
