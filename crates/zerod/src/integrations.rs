//! Integrations: who gh is signed in as, and the Linear and Slack connections zerod makes in the browser (Linear) or
//! with a pasted token (Slack): what they are in linear.json and slack.json, their tokens in zerod's vault (vault.rs),
//! with the switches that let agents write through them. Following reads through them; Linear's team keys and Slack's
//! channels make issue keys and channels in messages links.

use crate::now;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::inbox::Fut;

/// Runs a command (argv, through the login shell where it needs one) with what to write to its stdin, and returns
/// what it printed. A seam so tests can answer for gh and curl.
pub trait Fetcher: Send + Sync {
    fn run(&self, argv: Vec<String>, stdin: Option<String>) -> Fut<'_, Result<String, String>>;
}

/// The real one: the command in the user's login environment, as agents run, given up on (and killed) after `timeout`
/// so a hung gh or curl can't hold anything up.
pub struct Commands {
    pub timeout: std::time::Duration,
}

impl Default for Commands {
    fn default() -> Self {
        Commands { timeout: std::time::Duration::from_secs(30) }
    }
}

impl Fetcher for Commands {
    fn run(&self, argv: Vec<String>, stdin: Option<String>) -> Fut<'_, Result<String, String>> {
        Box::pin(async move {
            let (program, arguments) = argv.split_first().ok_or("Nothing to run")?;
            let mut command = tokio::process::Command::new(program);
            command
                .args(arguments)
                .env_clear()
                .envs(crate::process::environment(std::env::vars(), "integrations"))
                .kill_on_drop(true)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped());
            let mut child = command.spawn().map_err(|e| format!("{program} didn't start: {e}"))?;
            if let (Some(mut input), Some(text)) = (child.stdin.take(), stdin) {
                input.write_all(text.as_bytes()).await.map_err(|e| e.to_string())?
            }
            let output = tokio::time::timeout(self.timeout, child.wait_with_output())
                .await
                .map_err(|_| format!("{program} took too long"))?
                .map_err(|e| e.to_string())?;
            let printed = String::from_utf8_lossy(&output.stdout).to_string();
            if output.status.success() {
                Ok(printed)
            } else {
                let why = String::from_utf8_lossy(&output.stderr).trim().to_string();
                Err(if why.is_empty() { printed } else { why })
            }
        })
    }
}

/// The approvals agents' writes have used, in zerod's home.
const SPENT: &str = "spent-approvals.json";

/// Zero's Linear OAuth app (authorization code with PKCE: a public client id and no secret).
const LINEAR_CLIENT: &str = "6a5057347cad54818f0b528ee7763622";
const LINEAR_GRAPHQL: &str = "https://api.linear.app/graphql";
#[derive(Serialize, Deserialize, Clone)]
struct Account {
    name: String,
    url_key: String,
    /// The tokens: in the vault, never in linear.json.
    #[serde(default, skip_serializing)]
    access: String,
    #[serde(default, skip_serializing)]
    refresh: Option<String>,
    expires: i64,
    /// Its teams' keys ("ENG"), whose issue ids link to it.
    #[serde(default)]
    teams: Vec<String>,
}

/// A Slack workspace connected: a user token of Zero's own Slack app (made from the app's manifest, read-only scopes),
/// the team it is for, and the channels' ids by name (what Slack's app opens by). In slack.json, but for its token.
#[derive(Serialize, Deserialize, Clone, Default, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SlackTeam {
    pub id: String,
    pub name: String,
    pub domain: String,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct SlackAccount {
    /// In the vault, never in slack.json.
    #[serde(default, skip_serializing)]
    token: String,
    team: SlackTeam,
    user_id: String,
    channels: BTreeMap<String, String>,
}

/// Whether the user lets agents write through the connections (`zero slack`, `zero linear`), each write still theirs
/// to approve. Set by the app alone (server.rs, APP_ONLY), kept in the vault.
#[derive(Serialize, Deserialize, Clone, Copy, Default, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Writes {
    #[serde(default)]
    pub slack_posts: bool,
    #[serde(default)]
    pub linear_changes: bool,
}

/// What the vault holds: Slack's tokens by team id, Linear's tokens, and the write switches.
#[derive(Serialize, Deserialize, Default)]
struct Secrets {
    #[serde(default)]
    slack: BTreeMap<String, String>,
    #[serde(default)]
    linear: Option<(String, Option<String>)>,
    #[serde(default, flatten)]
    writes: Writes,
}

pub struct Integrations {
    home: PathBuf,
    vault: crate::vault::Vault,
    writes: Mutex<Writes>,
    /// Held while the connections are written, so two changes can't each write the other's old tokens.
    saving: Mutex<()>,
    fetcher: Arc<dyn Fetcher>,
    linear: Mutex<Option<Account>>,
    /// Every Slack workspace connected, in the order connected.
    slack: Mutex<Vec<SlackAccount>>,
    /// Which workspace a channel or person (an id the connections don't list) turned out to be in.
    slack_homes: Mutex<std::collections::HashMap<String, String>>,
    port: Mutex<u16>,
    /// Approvals agents' writes were made with: each is for one call, kept in spent-approvals.json so a restart can't
    /// let one run twice.
    spent: Mutex<std::collections::HashSet<String>>,
    /// The Linear sign-in the listener waits for (its state and verifier), and whether one is listening.
    signing_in: Mutex<(Option<(String, String)>, bool)>,
    /// Who gh is signed in as, once it has said.
    github: Mutex<Option<String>>,
}

impl Integrations {
    /// With its tokens in a file of `home`'s own (secrets.json): a zerod on a home other than the user's.
    pub fn open(home: &Path, fetcher: Arc<dyn Fetcher>) -> Arc<Integrations> {
        Self::open_in(home, fetcher, crate::vault::Vault::File(home.join("secrets.json")))
    }

    /// Tokens left in linear.json or slack.json (by a zerod from before the vault) move into it.
    pub fn open_in(home: &Path, fetcher: Arc<dyn Fetcher>, vault: crate::vault::Vault) -> Arc<Integrations> {
        let secrets: Secrets = match vault.read() {
            Ok(data) => data.and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default(),
            Err(error) => {
                eprintln!("zerod: couldn't read the integrations' tokens: {error}");
                Secrets::default()
            }
        };
        let mut linear: Option<Account> = std::fs::read(home.join("linear.json")).ok().and_then(|data| serde_json::from_slice(&data).ok());
        // One workspace, as slack.json kept it before there could be several, or a list.
        let mut slack: Vec<SlackAccount> = std::fs::read(home.join("slack.json"))
            .ok()
            .and_then(|data| {
                serde_json::from_slice::<Vec<SlackAccount>>(&data)
                    .ok()
                    .or_else(|| serde_json::from_slice::<SlackAccount>(&data).ok().map(|one| vec![one]))
            })
            .unwrap_or_default();
        let left_in_files = slack.iter().any(|a| !a.token.is_empty()) || linear.as_ref().is_some_and(|a| !a.access.is_empty());
        for account in slack.iter_mut().filter(|a| a.token.is_empty()) {
            account.token = secrets.slack.get(&account.team.id).cloned().unwrap_or_default()
        }
        if let (Some(account), Some((access, refresh))) = (linear.as_mut().filter(|a| a.access.is_empty()), secrets.linear) {
            (account.access, account.refresh) = (access, refresh)
        }
        let integrations = Arc::new(Integrations {
            home: home.into(),
            vault,
            writes: Mutex::new(secrets.writes),
            saving: Mutex::new(()),
            fetcher,
            linear: Mutex::new(linear),
            slack: Mutex::new(slack),
            slack_homes: Mutex::default(),
            spent: Mutex::new(std::fs::read(home.join(SPENT)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()),
            port: Mutex::new(47615),
            signing_in: Mutex::new((None, false)),
            github: Mutex::new(None),
        });
        if left_in_files && let Err(error) = integrations.save() {
            eprintln!("zerod: couldn't move the integrations' tokens out of their files: {error}")
        }
        integrations
    }

    /// Whether agents may write through the connections.
    pub fn writes(&self) -> Writes {
        *self.writes.lock().unwrap()
    }

    /// The write switches the app set (each, if given), kept in the vault.
    pub fn set_writes(&self, slack_posts: Option<bool>, linear_changes: Option<bool>) -> Result<(), String> {
        if slack_posts.is_none() && linear_changes.is_none() {
            return Ok(());
        }
        let _saving = self.saving.lock().unwrap();
        let mut writes = self.writes.lock().unwrap();
        writes.slack_posts = slack_posts.unwrap_or(writes.slack_posts);
        writes.linear_changes = linear_changes.unwrap_or(writes.linear_changes);
        drop(writes);
        self.save()
    }

    /// Everything kept as it is now: the tokens and switches in the vault first, then the connections in their files
    /// without their tokens (none left, the file goes). The vault refusing, the files stay as they were.
    fn save(&self) -> Result<(), String> {
        let slack = self.slack.lock().unwrap().clone();
        let linear = self.linear.lock().unwrap().clone();
        let secrets = Secrets {
            slack: slack.iter().map(|a| (a.team.id.clone(), a.token.clone())).collect(),
            linear: linear.as_ref().map(|a| (a.access.clone(), a.refresh.clone())),
            writes: self.writes(),
        };
        self.vault.write(&serde_json::to_vec(&secrets).map_err(|e| e.to_string())?)?;
        let (slack_file, linear_file) = (self.home.join("slack.json"), self.home.join("linear.json"));
        match slack.is_empty() {
            true => drop(std::fs::remove_file(slack_file)),
            false => write_private(&slack_file, &serde_json::to_vec(&slack).map_err(|e| e.to_string())?)?,
        }
        match &linear {
            Some(account) => write_private(&linear_file, &serde_json::to_vec(account).map_err(|e| e.to_string())?)?,
            None => drop(std::fs::remove_file(linear_file)),
        }
        Ok(())
    }

    /// Where Linear's sign-in comes back to (Zero's registered redirect is on 47615); a test's own port.
    pub fn listen_on(&self, port: u16) {
        *self.port.lock().unwrap() = port
    }

    /// Who gh is signed in as: asked until it answers, then remembered.
    pub async fn github_account(&self) -> Option<String> {
        if let Some(known) = self.github_known() {
            return Some(known);
        }
        let argv = crate::adapter::on_login_path(&["gh", "api", "user", "--jq", ".login"]);
        let login = self.fetcher.run(argv, None).await.ok().map(|out| out.trim().to_string()).filter(|login| !login.is_empty())?;
        *self.github.lock().unwrap() = Some(login.clone());
        Some(login)
    }

    /// The account gh was last found signed in as, without asking.
    pub fn github_known(&self) -> Option<String> {
        self.github.lock().unwrap().clone()
    }

    /// The connected Linear workspace's name.
    pub fn linear_workspace(&self) -> Option<String> {
        self.linear.lock().unwrap().as_ref().map(|a| a.name.clone())
    }

    /// Each of the connected workspace's team keys, to its URL key ("ENG" → "acme"): where an issue id links.
    pub fn linear_teams(&self) -> BTreeMap<String, String> {
        let account = self.linear.lock().unwrap();
        account.iter().flat_map(|a| a.teams.iter().map(|team| (team.clone(), a.url_key.clone()))).collect()
    }

    /// Asks Linear for the workspace's teams again (one made since the connection links too).
    pub async fn refresh_linear_teams(&self) -> Result<(), String> {
        let reply = self.linear(json!({"query": "{teams(first:250){nodes{key}}}"})).await?;
        let mut account = self.linear.lock().unwrap().clone().ok_or("Linear disconnected")?;
        account.teams = team_keys(&reply);
        self.keep(Some(account))
    }

    /// One GraphQL request to Linear on the connection, refreshed first if it has run out.
    pub(crate) async fn linear(&self, body: Value) -> Result<Value, String> {
        let access = self.linear_access().await?;
        let config = curl_config(LINEAR_GRAPHQL, Some(&access), &body.to_string(), "application/json");
        let reply: Value =
            serde_json::from_str(&self.fetcher.run(curl(), Some(config)).await?).map_err(|e| format!("Linear answered oddly: {e}"))?;
        if let Some(error) = reply["errors"][0]["message"].as_str() {
            return Err(format!("Linear: {error}"));
        }
        Ok(reply)
    }

    /// The connection's access token, refreshed first if it has run out.
    async fn linear_access(&self) -> Result<String, String> {
        let mut account = self.linear.lock().unwrap().clone().ok_or("Linear isn't connected")?;
        if account.expires <= now() + 60
            && let Some(refresh) = account.refresh.clone()
        {
            let form = encode_form(&[("grant_type", "refresh_token"), ("refresh_token", &refresh), ("client_id", LINEAR_CLIENT)]);
            let tokens = self.exchange(&form).await?;
            account = Account { access: tokens.0, refresh: tokens.1.or(Some(refresh)), expires: tokens.2, ..account };
            self.keep(Some(account.clone()))?;
        }
        Ok(account.access)
    }

    /// An agent's GraphQL request to Linear (`zero linear`), Linear's whole answer back; its first error as the error.
    /// Over Linear's rate or complexity limits, says when they reset rather than waiting that long.
    pub async fn linear_for_agent(&self, query: &str, variables: Option<&Value>) -> Result<Value, String> {
        let mut body = json!({"query": query});
        if let Some(variables) = variables.filter(|v| !v.is_null()) {
            body["variables"] = variables.clone()
        }
        let access = self.linear_access().await?;
        let config = curl_config(LINEAR_GRAPHQL, Some(&access), &body.to_string(), "application/json");
        let reply = api(&*self.fetcher, config).await?;
        let error = &reply.body["errors"][0];
        if let Some(message) = error["message"].as_str() {
            let limited = reply.status == 429 || error["extensions"]["code"] == "RATELIMITED";
            let reset = reply
                .resets
                .filter(|_| limited)
                .map(|at| format!(" (rate limited: it resets in {}s)", (at - now()).max(1)))
                .unwrap_or_default();
            return Err(format!("Linear: {message}{reset}"));
        }
        if reply.status >= 400 {
            return Err(format!("Linear answered {}: {}", reply.status, reply.body));
        }
        Ok(reply.body)
    }

    /// Spends an approval on the write it was for: true the first time only.
    pub fn spend(&self, approval: &str) -> bool {
        let mut spent = self.spent.lock().unwrap();
        if !spent.insert(approval.into()) {
            return false;
        }
        // ponytail: kept forever (6-letter ids, a few a day); trim when it's ever large.
        if let Err(error) = write_private(&self.home.join(SPENT), &serde_json::to_vec(&*spent).unwrap_or_default()) {
            eprintln!("zerod: couldn't keep a spent approval: {error}")
        }
        true
    }

    /// Starts connecting Linear: the page to open in the browser. zerod listens for it to come back, then keeps the
    /// connection.
    pub async fn connect_linear(self: &Arc<Self>) -> Result<String, String> {
        let port = *self.port.lock().unwrap();
        let (verifier, state) = (random(), random());
        let redirect = format!("http://localhost:{port}/oauth/linear");
        let url = format!(
            "https://linear.app/oauth/authorize?{}",
            encode_form(&[
                ("client_id", LINEAR_CLIENT),
                ("redirect_uri", &redirect),
                ("response_type", "code"),
                // Changes need Linear's write scope, asked for only once the user lets agents make them.
                ("scope", if self.writes().linear_changes { "read,write" } else { "read" }),
                ("state", &state),
                ("prompt", "consent"),
                ("code_challenge", &base64url(&sha256(verifier.as_bytes()))),
                ("code_challenge_method", "S256"),
            ])
        );
        // A sign-in started again (its tab closed unfinished) replaces the one the listener waits for.
        let listening = {
            let mut signing_in = self.signing_in.lock().unwrap();
            signing_in.0 = Some((state, verifier));
            std::mem::replace(&mut signing_in.1, true)
        };
        if listening {
            return Ok(url);
        }
        let listener = match tokio::net::TcpListener::bind(("127.0.0.1", port)).await {
            Ok(listener) => listener,
            Err(e) => {
                *self.signing_in.lock().unwrap() = (None, false);
                return Err(format!("Can't listen for Linear on port {port}: {e}"));
            }
        };
        let me = self.clone();
        tokio::spawn(async move {
            // Until a sign-in comes back, or none has for 10 minutes; anything else (an old tab) is answered and waited past.
            while let Ok(Ok((mut stream, _))) = tokio::time::timeout(std::time::Duration::from_secs(600), listener.accept()).await {
                let mut line = String::new();
                let (read, mut write) = stream.split();
                let _ = BufReader::new(read).read_line(&mut line).await;
                let query: std::collections::HashMap<String, String> =
                    line.split_whitespace().nth(1).and_then(|path| path.split_once('?')).map(|(_, q)| decode_form(q)).unwrap_or_default();
                let waiting = me.signing_in.lock().unwrap().0.clone();
                let outcome = match (query.get("state"), query.get("code"), waiting) {
                    (Some(back), Some(code), Some((state, verifier))) if *back == state => {
                        Some(me.finish_linear(code, &redirect, &verifier).await)
                    }
                    _ => None,
                };
                let text = match &outcome {
                    Some(Ok(name)) => format!("Linear is connected to Zero ({name}). You can close this tab."),
                    Some(Err(why)) => format!("Linear didn't connect: {why}"),
                    None => format!(
                        "Linear didn't connect: {}",
                        query.get("error_description").or(query.get("error")).map_or("this sign-in was replaced by a newer one", |s| s)
                    ),
                };
                let page = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
                    text.len()
                );
                let _ = write.write_all(page.as_bytes()).await;
                let _ = write.shutdown().await;
                if outcome.is_some() {
                    break;
                }
            }
            drop(listener); // the port is free before the next connect may bind it
            *me.signing_in.lock().unwrap() = (None, false);
        });
        Ok(url)
    }

    async fn finish_linear(&self, code: &str, redirect: &str, verifier: &str) -> Result<String, String> {
        let form = encode_form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirect),
            ("client_id", LINEAR_CLIENT),
            ("code_verifier", verifier),
        ]);
        let (access, refresh, expires) = self.exchange(&form).await?;
        *self.linear.lock().unwrap() =
            Some(Account { name: String::new(), url_key: String::new(), access, refresh, expires, teams: vec![] });
        let viewer = self.linear(json!({"query": "{viewer{organization{name urlKey}} teams(first:250){nodes{key}}}"})).await?;
        let organization = &viewer["data"]["viewer"]["organization"];
        let mut account = self.linear.lock().unwrap().clone().ok_or("Linear disconnected")?;
        account.name = organization["name"].as_str().unwrap_or("Linear").into();
        account.url_key = organization["urlKey"].as_str().unwrap_or_default().into();
        account.teams = team_keys(&viewer);
        self.keep(Some(account.clone()))?;
        Ok(account.name)
    }

    pub fn disconnect_linear(&self) -> Result<(), String> {
        self.keep(None)
    }

    /// Each connected Slack workspace and its channels' ids by name, for the app: `[{"team", "channels"}]`.
    pub fn slack_state(&self) -> Value {
        json!(self.slack.lock().unwrap().iter().map(|a| json!({"team": a.team, "channels": a.channels})).collect::<Vec<_>>())
    }

    /// The team a channel is in, and the user its token is for: the workspace listing it, or that it was found in.
    pub(crate) fn slack_team(&self, channel: &str) -> Option<(SlackTeam, String)> {
        let accounts = self.slack.lock().unwrap();
        self.slack_home(&accounts, channel).map(|a| (a.team.clone(), a.user_id.clone()))
    }

    fn slack_home<'a>(&self, accounts: &'a [SlackAccount], id: &str) -> Option<&'a SlackAccount> {
        let found = self.slack_homes.lock().unwrap().get(id).cloned();
        accounts.iter().find(|a| a.channels.values().any(|c| c == id) || found.as_deref() == Some(a.team.id.as_str()))
    }

    /// A channel's name by its id, when it is one a connection listed.
    pub(crate) fn slack_channel_name(&self, id: &str) -> Option<String> {
        self.slack.lock().unwrap().iter().find_map(|a| a.channels.iter().find(|(_, i)| *i == id).map(|(name, _)| name.clone()))
    }

    /// Checks `token` with Slack, reads the workspace's channels, and keeps the connection beside the others (in place
    /// of the one it is for, connected again). The state, as the app shows it.
    pub async fn connect_slack(&self, token: &str) -> Result<Value, String> {
        let token = token.trim();
        if !token.starts_with("xoxp-") {
            return Err("That isn't a user token: Slack's start with xoxp-.".into());
        }
        let identity = slack_call(&*self.fetcher, token, "auth.test", &[]).await?;
        let (Some(id), Some(name)) = (identity["team_id"].as_str(), identity["team"].as_str()) else {
            return Err("Slack didn't say which workspace the token is for.".into());
        };
        let domain =
            identity["url"].as_str().and_then(|u| u.strip_prefix("https://")).and_then(|u| u.split('.').next()).unwrap_or("").to_string();
        let channels = slack_channels(&*self.fetcher, token).await?;
        let account = SlackAccount {
            token: token.into(),
            team: SlackTeam { id: id.into(), name: name.into(), domain },
            user_id: identity["user_id"].as_str().unwrap_or("").into(),
            channels,
        };
        let mut accounts = self.slack.lock().unwrap().clone();
        match accounts.iter_mut().find(|a| a.team.id == account.team.id) {
            Some(kept) => *kept = account,
            None => accounts.push(account),
        }
        self.keep_slack(accounts)?;
        Ok(self.slack_state())
    }

    /// The workspace `team` let go of; the others stay.
    pub fn disconnect_slack(&self, team: &str) -> Result<(), String> {
        let accounts = self.slack.lock().unwrap().iter().filter(|a| a.team.id != team).cloned().collect();
        self.keep_slack(accounts)
    }

    /// Every workspace's channels again: new ones get ids too.
    pub async fn refresh_slack(&self) -> Result<(), String> {
        let mut accounts = self.slack.lock().unwrap().clone();
        for account in &mut accounts {
            account.channels = slack_channels(&*self.fetcher, &account.token).await?;
        }
        self.keep_slack(accounts)
    }

    /// One call to Slack's Web API; the answer when Slack says ok. It goes to the workspace of the channel or person it
    /// names, when that's known; else to each in turn, the first to answer being theirs from then on.
    pub(crate) async fn slack(&self, method: &str, params: &[(&str, &str)]) -> Result<Value, String> {
        let about = params.iter().find(|(k, _)| matches!(*k, "channel" | "user")).map(|(_, v)| v.to_string());
        let mut accounts = self.slack.lock().unwrap().clone();
        if accounts.is_empty() {
            return Err("Slack isn't connected".into());
        }
        if let Some(home) = about.as_deref().and_then(|id| self.slack_home(&accounts, id)).map(|a| a.team.id.clone()) {
            accounts.sort_by_key(|a| a.team.id != home);
        }
        let mut failed = String::new();
        for account in &accounts {
            match slack_call(&*self.fetcher, &account.token, method, params).await {
                Ok(reply) => {
                    if let Some(id) = &about {
                        self.slack_homes.lock().unwrap().insert(id.clone(), account.team.id.clone());
                    }
                    return Ok(reply);
                }
                Err(error) => failed = error,
            }
        }
        Err(failed)
    }

    /// An agent's call to Slack's Web API (`zero slack`): to `workspace` (its name, id or domain), else the first
    /// connected; Slack's whole answer back, or its error. Rate limited, it waits as Slack's Retry-After says (up to
    /// half a minute) and asks again; longer, it says how long.
    pub async fn slack_for_agent(&self, workspace: Option<&str>, method: &str, params: &[(String, String)]) -> Result<Value, String> {
        let token = {
            let accounts = self.slack.lock().unwrap();
            let named = |a: &&SlackAccount| {
                workspace.is_none_or(|w| [&a.team.name, &a.team.id, &a.team.domain].iter().any(|n| n.eq_ignore_ascii_case(w.trim())))
            };
            match accounts.iter().find(named) {
                Some(account) => account.token.clone(),
                None if accounts.is_empty() => return Err("Slack isn't connected to Zero: the user connects it in Settings › Slack".into()),
                None => {
                    let names: Vec<&str> = accounts.iter().map(|a| a.team.name.as_str()).collect();
                    return Err(format!("No Slack workspace {}: Zero is connected to {}", workspace.unwrap_or_default(), names.join(", ")));
                }
            }
        };
        let pairs: Vec<(&str, &str)> = params.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let config = curl_config(
            &format!("https://slack.com/api/{method}"),
            Some(&token),
            &encode_form(&pairs),
            "application/x-www-form-urlencoded",
        );
        let mut waited = 0;
        loop {
            let reply = api(&*self.fetcher, config.clone()).await?;
            if reply.status == 429 || reply.body["error"] == "ratelimited" {
                let wait = reply.retry_after.unwrap_or(1);
                if waited + wait > 30 {
                    return Err(format!("Slack {method}: ratelimited (Slack says to wait {wait}s)"));
                }
                waited += wait.max(1);
                tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
                continue;
            }
            if reply.body["ok"] != true {
                let error = reply.body["error"].as_str().unwrap_or("no answer");
                if let Some(needed) = reply.body["needed"].as_str().filter(|_| error == "missing_scope") {
                    return Err(format!(
                        "Slack {method}: missing_scope: Zero's Slack app hasn't {needed}. The user adds it to the app's User Token Scopes in Slack, reinstalls the app and connects Slack again in Settings › Slack"
                    ));
                }
                return Err(format!("Slack {method}: {error}"));
            }
            return Ok(reply.body);
        }
    }

    fn keep_slack(&self, accounts: Vec<SlackAccount>) -> Result<(), String> {
        let _saving = self.saving.lock().unwrap();
        *self.slack.lock().unwrap() = accounts;
        self.save()
    }

    /// Tokens for a form sent to Linear's token endpoint: access, refresh, when the access runs out.
    async fn exchange(&self, form: &str) -> Result<(String, Option<String>, i64), String> {
        let config = curl_config("https://api.linear.app/oauth/token", None, form, "application/x-www-form-urlencoded");
        let reply: Value =
            serde_json::from_str(&self.fetcher.run(curl(), Some(config)).await?).map_err(|e| format!("Linear answered oddly: {e}"))?;
        let access = reply["access_token"]
            .as_str()
            .ok_or_else(|| reply["error_description"].as_str().unwrap_or("Linear gave no token").to_string())?;
        Ok((
            access.into(),
            reply["refresh_token"].as_str().map(Into::into),
            now() + reply["expires_in"].as_i64().unwrap_or(10 * 365 * 86400),
        ))
    }

    /// The Linear connection kept; none removes it.
    fn keep(&self, account: Option<Account>) -> Result<(), String> {
        let _saving = self.saving.lock().unwrap();
        *self.linear.lock().unwrap() = account;
        self.save()
    }
}

/// Writes `file` readable by the user alone.
pub(crate) fn write_private(file: &Path, data: &[u8]) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut out = std::fs::OpenOptions::new().create(true).write(true).truncate(true).mode(0o600).open(file).map_err(|e| e.to_string())?;
    std::io::Write::write_all(&mut out, data).map_err(|e| e.to_string())
}

/// The team keys in a reply's `teams`, upper-cased as issue ids write them.
fn team_keys(reply: &Value) -> Vec<String> {
    reply["data"]["teams"]["nodes"].as_array().into_iter().flatten().filter_map(|t| t["key"].as_str()).map(str::to_uppercase).collect()
}

async fn slack_call(fetcher: &dyn Fetcher, token: &str, method: &str, params: &[(&str, &str)]) -> Result<Value, String> {
    let url = format!("https://slack.com/api/{method}{}{}", if params.is_empty() { "" } else { "?" }, encode_form(params));
    let config = format!("url = \"{url}\"\nheader = \"Authorization: Bearer {token}\"\n");
    let reply: Value = serde_json::from_str(&fetcher.run(curl(), Some(config)).await?).map_err(|e| format!("Slack answered oddly: {e}"))?;
    if reply["ok"] != true {
        return Err(format!("Slack {method}: {}", reply["error"].as_str().unwrap_or("no")));
    }
    Ok(reply)
}

/// Slack's Web API methods agents may call without the user's leave: they read. Anything else writes.
const SLACK_READS: &[&str] = &[
    "auth.test",
    "bookmarks.list",
    "bots.info",
    "chat.getPermalink",
    "conversations.history",
    "conversations.info",
    "conversations.list",
    "conversations.members",
    "conversations.replies",
    "dnd.info",
    "emoji.list",
    "files.info",
    "files.list",
    "pins.list",
    "reactions.get",
    "reactions.list",
    "search.all",
    "search.files",
    "search.messages",
    "stars.list",
    "team.info",
    "team.profile.get",
    "usergroups.list",
    "usergroups.users.list",
    "users.conversations",
    "users.getPresence",
    "users.info",
    "users.list",
    "users.lookupByEmail",
    "users.profile.get",
];

pub fn slack_reads(method: &str) -> bool {
    SLACK_READS.contains(&method)
}

/// Whether a GraphQL document would change Linear: any of its operations isn't a query. Read off the words outside
/// every brace, parenthesis, string and comment, where an operation says what it is.
pub fn changes_linear(document: &str) -> bool {
    let (mut depth, mut word, mut words) = (0i32, String::new(), vec![]);
    let mut chars = document.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '#' => while chars.next_if(|c| *c != '\n').is_some() {},
            '"' => {
                while let Some(c) = chars.next() {
                    match c {
                        '\\' => {
                            chars.next();
                        }
                        '"' => break,
                        _ => {}
                    }
                }
            }
            '{' | '(' => depth += 1,
            '}' | ')' => depth -= 1,
            c if depth == 0 && (c.is_alphanumeric() || c == '_') => {
                word.push(c);
                continue;
            }
            _ => {}
        }
        words.push(std::mem::take(&mut word));
    }
    words.push(word);
    words.iter().any(|w| w == "mutation" || w == "subscription")
}

/// An answer from an API, with what its headers say of its rate limits.
struct Reply {
    status: u16,
    body: Value,
    /// Slack's Retry-After, in seconds.
    retry_after: Option<u64>,
    /// When Linear's request or complexity limit resets, in seconds since 1970.
    resets: Option<i64>,
}

/// One request (curl's config, token and all, on its stdin), its status and rate-limit headers read off a last line
/// curl writes after the body.
async fn api(fetcher: &dyn Fetcher, config: String) -> Result<Reply, String> {
    let config = config
        + "write-out = \"\\n%{http_code}|%header{retry-after}|%header{x-ratelimit-requests-reset}|%header{x-ratelimit-complexity-reset}\"\n";
    let printed = fetcher.run(["curl", "-sS", "-K", "-"].map(String::from).to_vec(), Some(config)).await?;
    let (body, last) = printed.trim_end_matches('\n').rsplit_once('\n').unwrap_or(("", &printed));
    let mut fields = last.split('|');
    let status = fields.next().and_then(|s| s.trim().parse().ok()).unwrap_or(0);
    let retry_after = fields.next().and_then(|s| s.trim().parse().ok());
    // Linear's resets are milliseconds since 1970; the later of the two is when both allow again.
    let resets = fields.filter_map(|s| s.trim().parse::<i64>().ok()).max().map(|ms| ms / 1000);
    let body =
        serde_json::from_str(body).map_err(|_| format!("The API answered {status}: {}", body.chars().take(300).collect::<String>()))?;
    Ok(Reply { status, body, retry_after, resets })
}

/// Every channel's id by name, public and private, page by page.
async fn slack_channels(fetcher: &dyn Fetcher, token: &str) -> Result<BTreeMap<String, String>, String> {
    let (mut all, mut cursor) = (BTreeMap::new(), String::new());
    loop {
        let mut params = vec![("types", "public_channel,private_channel"), ("exclude_archived", "true"), ("limit", "1000")];
        if !cursor.is_empty() {
            params.push(("cursor", &cursor))
        }
        let page = slack_call(fetcher, token, "conversations.list", &params).await?;
        for channel in page["channels"].as_array().into_iter().flatten() {
            if let (Some(name), Some(id)) = (channel["name"].as_str(), channel["id"].as_str()) {
                all.entry(name.to_string()).or_insert(id.to_string());
            }
        }
        cursor = page["response_metadata"]["next_cursor"].as_str().unwrap_or("").to_string();
        if cursor.is_empty() {
            return Ok(all);
        }
    }
}

/// curl's config, read from its stdin (`curl -K -`), so the token and the body stay off the command line.
pub fn curl_config(url: &str, token: Option<&str>, body: &str, content: &str) -> String {
    let quote = |text: &str| format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""));
    let mut config = format!("url = {}\n", quote(url));
    if let Some(token) = token {
        config += &format!("header = {}\n", quote(&format!("Authorization: Bearer {token}")))
    }
    config += &format!("header = {}\ndata = {}\n", quote(&format!("Content-Type: {content}")), quote(body));
    config
}

fn curl() -> Vec<String> {
    ["curl", "-sS", "--fail-with-body", "-K", "-"].map(String::from).to_vec()
}

fn random() -> String {
    let mut bytes = [0u8; 32];
    if let Ok(mut source) = std::fs::File::open("/dev/urandom") {
        let _ = std::io::Read::read_exact(&mut source, &mut bytes);
    }
    base64url(&bytes)
}

fn encode_form(pairs: &[(&str, &str)]) -> String {
    let encode = |text: &str| {
        text.bytes()
            .map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
            .collect::<String>()
    };
    pairs.iter().map(|(k, v)| format!("{}={}", encode(k), encode(v))).collect::<Vec<_>>().join("&")
}

fn decode_form(query: &str) -> std::collections::HashMap<String, String> {
    let decode = |text: &str| {
        let bytes = text.replace('+', " ").into_bytes();
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            let escaped = (bytes[i] == b'%' && i + 2 < bytes.len())
                .then(|| std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()))
                .flatten();
            match escaped {
                Some(b) => {
                    out.push(b);
                    i += 3
                }
                None => {
                    out.push(bytes[i]);
                    i += 1
                }
            }
        }
        String::from_utf8_lossy(&out).to_string()
    };
    query.split('&').filter_map(|pair| pair.split_once('=')).map(|(k, v)| (decode(k), decode(v))).collect()
}

pub fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    bytes
        .chunks(3)
        .flat_map(|chunk| {
            let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
            (0..=chunk.len()).map(move |i| ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char)
        })
        .collect()
}

/// SHA-256, for PKCE's code challenge: a few lines rather than a crate for one hash.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be,
        0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa,
        0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
        0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
        0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0)
    }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in message.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([block[4 * i], block[4 * i + 1], block[4 * i + 2], block[4 * i + 3]])
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let choose = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7].wrapping_add(s1).wrapping_add(choose).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let majority = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(majority);
            v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
        }
        for i in 0..8 {
            h[i] = h[i].wrapping_add(v[i])
        }
    }
    let mut out = [0u8; 32];
    for i in 0..8 {
        out[4 * i..4 * i + 4].copy_from_slice(&h[i].to_be_bytes())
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_and_base64url_match_the_published_vectors() {
        let hex: String = sha256(b"abc").iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        // RFC 7636's own PKCE example.
        assert_eq!(base64url(&sha256(b"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        assert_eq!(decode_form("a=1%202&b=x+y")["a"], "1 2");
    }
}
