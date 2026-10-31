//! Integrations: GitHub and Linear seen through views, each a saved filter the user names and changes (a GitHub view
//! is a search query; a Linear view says whose issues, which teams, which states). zerod fetches them: GitHub through
//! `gh`, which keeps its own sign-in, and Linear through its API on a connection zerod makes in the browser and keeps in
//! linear.json (the user's alone). Settings live in integrations.json, both in zerod's home.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::inbox::Fut;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub github: Source<GitHubView>,
    pub linear: Source<LinearView>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Source<V> {
    pub enabled: bool,
    pub views: Vec<V>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GitHubView {
    #[serde(default)]
    pub id: String,
    pub name: String,
    /// GitHub's search syntax: `is:pr is:open author:@me org:acme`.
    pub query: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<Start>,
}

/// How a view's items start tasks: in which folder, with which agent, saying what. The prompt fills in {key},
/// {title}, {url} and {state} (the task's state pad).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Start {
    pub cwd: String,
    pub prompt: String,
    /// codex, claude or opencode; Claude when left out.
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    /// auto or unrestricted.
    #[serde(default)]
    pub permissions: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct LinearView {
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub assignee: Assignee,
    /// Team keys ("ENG", "WEB"); none means every team.
    #[serde(default)]
    pub teams: Vec<String>,
    /// Workflow state types (backlog, unstarted, started, completed, canceled, triage); none means every state.
    #[serde(default)]
    pub states: Vec<String>,
    /// The teams' own workflow states by name ("PM review", "Plan"); when any are picked they stand in for `states`.
    #[serde(default, rename = "stateNames")]
    pub state_names: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<Start>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Assignee { Me, Anyone, Nobody }

impl Default for Settings {
    fn default() -> Self {
        let github = |id: &str, name: &str, query: &str| GitHubView { id: id.into(), name: name.into(), query: query.into(), start: None };
        Settings {
            github: Source { enabled: false, views: vec![
                github("mine", "My pull requests", "is:pr is:open author:@me archived:false"),
                github("reviews", "Review requests", "is:pr is:open review-requested:@me archived:false"),
            ] },
            linear: Source { enabled: false, views: vec![LinearView {
                id: "mine".into(), name: "My issues".into(), assignee: Assignee::Me, teams: vec![],
                states: vec!["backlog".into(), "unstarted".into(), "started".into()], state_names: vec![], start: None,
            }] },
        }
    }
}

/// One row of a view, the same for both: a pull request or an issue.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    /// "#19001" or "ENG-9759".
    pub key: String,
    pub title: String,
    pub url: String,
    /// The repository or the team.
    pub place: String,
    /// "Open", "Draft", or the issue's workflow state.
    pub state: String,
    /// An issue's state's colour in Linear ("#f2c94c").
    pub color: Option<String>,
    /// A pull request's checks: success, failure, pending.
    pub checks: Option<String>,
    /// A pull request's review: approved, changes requested, review required.
    pub review: Option<String>,
    /// Who it's by (a pull request) or with (an issue).
    pub person: Option<String>,
    /// Linear's priority, 1 urgent to 4 low; 0 or none for none.
    pub priority: Option<u8>,
    pub updated: String,
    /// An issue's state's type (started, triage…), which its icon shows.
    #[serde(default)]
    pub kind: Option<String>,
    /// An issue's labels, then its project.
    #[serde(default)]
    pub tags: Vec<Tag>,
    /// The assignee's picture.
    #[serde(default)]
    pub avatar: Option<String>,
    #[serde(default)]
    pub created: Option<String>,
    /// The task started from it, if one has been.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
}

impl Item {
    /// What its task is filed under: an issue's key, a pull request's repository and number.
    pub fn ticket(&self) -> String { if self.key.starts_with('#') { format!("{}{}", self.place, self.key) } else { self.key.clone() } }
}

/// A task's first words, from its view's template: the item filled in, and where to keep the task's state, unless the
/// template places {state} itself.
pub fn task_prompt(template: &str, item: &Item, state: &str) -> String {
    let filled = template.replace("{key}", &item.key).replace("{title}", &item.title).replace("{url}", &item.url).replace("{state}", state);
    if template.contains("{state}") { return filled }
    let ticket = item.ticket();
    format!("{filled}\n\nKeep this task's state (what's done, the PR, an open question, the next step) in the scratchpad {state}: read it first, \
             and keep it current, since it outlives restarts. Put other notes for {ticket} in the scratchpads folder Tasks/{ticket}.")
}

/// The items, each with the task filed under its ticket, if there is one: (ticket, session) pairs.
pub fn with_tasks(items: Vec<Item>, tasks: &[(String, String)]) -> Vec<Item> {
    items.into_iter().map(|item| {
        let task = tasks.iter().find(|(ticket, _)| *ticket == item.ticket()).map(|(_, session)| session.clone());
        Item { task, ..item }
    }).collect()
}

/// A label or a project: its name, colour, and a project's icon (an emoji's shortcode, ":fire:", or one of Linear's own).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Tag {
    pub name: String,
    pub color: Option<String>,
    pub icon: Option<String>,
}

/// Runs a command (argv, through the login shell where it needs one) with what to write to its stdin, and returns
/// what it printed. A seam so tests can answer for gh and curl.
pub trait Fetcher: Send + Sync {
    fn run(&self, argv: Vec<String>, stdin: Option<String>) -> Fut<'_, Result<String, String>>;
}

/// The real one: the command in the user's login environment, as agents run, given up on (and killed) after `timeout`
/// so a hung gh or curl can't hold a view.
pub struct Commands { pub timeout: std::time::Duration }

impl Default for Commands {
    fn default() -> Self { Commands { timeout: std::time::Duration::from_secs(30) } }
}

impl Fetcher for Commands {
    fn run(&self, argv: Vec<String>, stdin: Option<String>) -> Fut<'_, Result<String, String>> {
        Box::pin(async move {
            let (program, arguments) = argv.split_first().ok_or("Nothing to run")?;
            let mut command = tokio::process::Command::new(program);
            command.args(arguments).env_clear().envs(crate::process::environment(std::env::vars(), "integrations")).kill_on_drop(true)
                .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
            let mut child = command.spawn().map_err(|e| format!("{program} didn't start: {e}"))?;
            if let (Some(mut input), Some(text)) = (child.stdin.take(), stdin) { input.write_all(text.as_bytes()).await.map_err(|e| e.to_string())? }
            let output = tokio::time::timeout(self.timeout, child.wait_with_output()).await
                .map_err(|_| format!("{program} took too long"))?.map_err(|e| e.to_string())?;
            let printed = String::from_utf8_lossy(&output.stdout).to_string();
            if output.status.success() { Ok(printed) } else {
                let why = String::from_utf8_lossy(&output.stderr).trim().to_string();
                Err(if why.is_empty() { printed } else { why })
            }
        })
    }
}

/// Zero's Linear OAuth app (authorization code with PKCE: a public client id and no secret).
const LINEAR_CLIENT: &str = "6a5057347cad54818f0b528ee7763622";
const LINEAR_GRAPHQL: &str = "https://api.linear.app/graphql";
const GITHUB_SEARCH: &str = "query($q:String!){search(query:$q,type:ISSUE,first:50){nodes{... on PullRequest{id number title url isDraft updatedAt repository{nameWithOwner} author{login} reviewDecision commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}";
const LINEAR_ISSUES: &str = "query($filter:IssueFilter){issues(filter:$filter,first:250,orderBy:updatedAt){nodes{id identifier title url priority updatedAt createdAt state{name type color position} team{key} assignee{name avatarUrl} labels{nodes{name color}} project{name icon color}}}}";

#[derive(Serialize, Deserialize, Clone)]
struct Account { name: String, url_key: String, access: String, refresh: Option<String>, expires: i64 }

/// The Slack workspace connected: a user token of Zero's own Slack app (made from the app's manifest, read-only scopes),
/// the team it is for, and the channels' ids by name (what Slack's app opens by). In slack.json, the user's alone.
#[derive(Serialize, Deserialize, Clone, Default, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SlackTeam { pub id: String, pub name: String, pub domain: String }

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct SlackAccount { token: String, team: SlackTeam, user_id: String, channels: BTreeMap<String, String> }

pub struct Integrations {
    home: PathBuf,
    fetcher: Arc<dyn Fetcher>,
    settings: Mutex<Settings>,
    linear: Mutex<Option<Account>>,
    slack: Mutex<Option<SlackAccount>>,
    port: Mutex<u16>,
    /// The Linear sign-in the listener waits for (its state and verifier), and whether one is listening.
    signing_in: Mutex<(Option<(String, String)>, bool)>,
    /// Who gh is signed in as, once it has said.
    github: Mutex<Option<String>>,
    /// Each view's last items ("github/mine") and Linear's teams ("linear/teams"), to show while fetching them again;
    /// in integrations-cache.json.
    cache: Mutex<serde_json::Map<String, Value>>,
}

impl Integrations {
    pub fn open(home: &Path, fetcher: Arc<dyn Fetcher>) -> Arc<Integrations> {
        let settings = std::fs::read(home.join("integrations.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        let linear = std::fs::read(home.join("linear.json")).ok().and_then(|data| serde_json::from_slice(&data).ok());
        let slack = std::fs::read(home.join("slack.json")).ok().and_then(|data| serde_json::from_slice(&data).ok());
        let cache = std::fs::read(home.join("integrations-cache.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        Arc::new(Integrations {
            home: home.into(), fetcher, settings: Mutex::new(settings), linear: Mutex::new(linear), slack: Mutex::new(slack), port: Mutex::new(47615),
            signing_in: Mutex::new((None, false)), github: Mutex::new(None), cache: Mutex::new(cache),
        })
    }

    /// What `key` last fetched, however long ago.
    pub fn cached(&self, key: &str) -> Option<Value> { self.cache.lock().unwrap().get(key).cloned() }

    /// Keeps what `key` fetched, or with none forgets every key it starts.
    fn remember(&self, key: &str, value: Option<Value>) {
        let mut cache = self.cache.lock().unwrap();
        match value { Some(value) => { cache.insert(key.into(), value); } None => cache.retain(|k, _| !k.starts_with(key)) }
        if let Ok(data) = serde_json::to_vec(&*cache) { let _ = write_private(&self.home.join("integrations-cache.json"), &data); }
    }

    /// Where Linear's sign-in comes back to (Zero's registered redirect is on 47615); a test's own port.
    pub fn listen_on(&self, port: u16) { *self.port.lock().unwrap() = port }

    pub fn settings(&self) -> Settings { self.settings.lock().unwrap().clone() }

    /// Who gh is signed in as: asked until it answers, then remembered.
    pub async fn github_account(&self) -> Option<String> {
        if let Some(known) = self.github_known() { return Some(known) }
        let argv = crate::adapter::login_shell(&["gh", "api", "user", "--jq", ".login"]);
        let login = self.fetcher.run(argv, None).await.ok().map(|out| out.trim().to_string()).filter(|login| !login.is_empty())?;
        *self.github.lock().unwrap() = Some(login.clone());
        Some(login)
    }

    /// The account gh was last found signed in as, without asking.
    pub fn github_known(&self) -> Option<String> { self.github.lock().unwrap().clone() }

    /// The connected Linear workspace's name.
    pub fn linear_workspace(&self) -> Option<String> { self.linear.lock().unwrap().as_ref().map(|a| a.name.clone()) }

    pub fn set_enabled(&self, integration: &str, enabled: bool) -> Result<Settings, String> {
        self.change(|settings| { match integration { "github" => settings.github.enabled = enabled, "linear" => settings.linear.enabled = enabled, other => return Err(format!("No integration {other}")) }; Ok(()) })
    }

    /// Adds the view, or replaces the one with its id; a view without an id is new.
    pub fn save_view(&self, integration: &str, view: Value) -> Result<Settings, String> {
        if let Some(id) = view["id"].as_str().filter(|id| !id.is_empty()) { self.remember(&format!("{integration}/{id}"), None) }
        self.change(|settings| {
            match integration {
                "github" => upsert(&mut settings.github.views, serde_json::from_value(view).map_err(|e| format!("Not a GitHub view: {e}"))?, |v| &mut v.id),
                "linear" => upsert(&mut settings.linear.views, serde_json::from_value(view).map_err(|e| format!("Not a Linear view: {e}"))?, |v| &mut v.id),
                other => return Err(format!("No integration {other}")),
            }
            Ok(())
        })
    }

    /// Puts the views named by `ids` first, in that order; the rest follow as they were.
    pub fn order_views(&self, integration: &str, ids: &[String]) -> Result<Settings, String> {
        fn order<V>(views: &mut [V], ids: &[String], id: impl Fn(&V) -> &str) {
            views.sort_by_key(|v| ids.iter().position(|i| i == id(v)).unwrap_or(usize::MAX));
        }
        self.change(|settings| { match integration { "github" => order(&mut settings.github.views, ids, |v| &v.id), "linear" => order(&mut settings.linear.views, ids, |v| &v.id), other => return Err(format!("No integration {other}")) }; Ok(()) })
    }

    pub fn delete_view(&self, integration: &str, id: &str) -> Result<Settings, String> {
        self.remember(&format!("{integration}/{id}"), None);
        self.change(|settings| { match integration { "github" => settings.github.views.retain(|v| v.id != id), "linear" => settings.linear.views.retain(|v| v.id != id), other => return Err(format!("No integration {other}")) }; Ok(()) })
    }

    fn change(&self, edit: impl FnOnce(&mut Settings) -> Result<(), String>) -> Result<Settings, String> {
        let mut settings = self.settings.lock().unwrap();
        edit(&mut settings)?;
        std::fs::write(self.home.join("integrations.json"), serde_json::to_vec_pretty(&*settings).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        Ok(settings.clone())
    }

    /// A view's name and how its items start tasks.
    pub fn start_of(&self, integration: &str, view: &str) -> Result<(String, Option<Start>), String> {
        let settings = self.settings();
        let found = match integration {
            "github" => settings.github.views.iter().find(|v| v.id == view).map(|v| (v.name.clone(), v.start.clone())),
            "linear" => settings.linear.views.iter().find(|v| v.id == view).map(|v| (v.name.clone(), v.start.clone())),
            other => return Err(format!("No integration {other}")),
        };
        found.ok_or_else(|| format!("No view {view}"))
    }

    /// What a view shows now, kept to show next time while it's fetched again.
    pub async fn items(&self, integration: &str, view: &str) -> Result<Vec<Item>, String> {
        let items = self.fetch(integration, view).await?;
        self.remember(&format!("{integration}/{view}"), Some(json!(items)));
        Ok(items)
    }

    async fn fetch(&self, integration: &str, view: &str) -> Result<Vec<Item>, String> {
        let settings = self.settings();
        match integration {
            "github" => {
                let view = settings.github.views.iter().find(|v| v.id == view).ok_or_else(|| format!("No view {view}"))?;
                let argv = crate::adapter::login_shell(&["gh", "api", "graphql", "-f", &format!("query={GITHUB_SEARCH}"), "-f", &format!("q={}", view.query)]);
                let reply = self.fetcher.run(argv, None).await?;
                Ok(github_items(&serde_json::from_str(&reply).map_err(|e| format!("gh answered oddly: {e}"))?))
            }
            "linear" => {
                let view = settings.linear.views.iter().find(|v| v.id == view).ok_or_else(|| format!("No view {view}"))?;
                let reply = self.linear(json!({"query": LINEAR_ISSUES, "variables": {"filter": linear_filter(view)}})).await?;
                Ok(linear_items(&reply))
            }
            other => Err(format!("No integration {other}")),
        }
    }

    /// Linear's teams, each with its own workflow states in the order Linear lists them, for picking a view's.
    pub async fn linear_teams(&self) -> Result<Value, String> {
        let reply = self.linear(json!({"query": "{teams(first:100){nodes{key name states{nodes{name type color position}}}}}"})).await?;
        let teams: Value = reply["data"]["teams"]["nodes"].as_array().into_iter().flatten().map(|team| {
            let mut states = team["states"]["nodes"].as_array().cloned().unwrap_or_default();
            by_workflow(&mut states, |state| state);
            json!({"key": team["key"], "name": team["name"],
                   "states": states.iter().map(|s| json!({"name": s["name"], "type": s["type"], "color": s["color"]})).collect::<Vec<_>>()})
        }).collect();
        self.remember("linear/teams", Some(teams.clone()));
        Ok(teams)
    }

    /// One GraphQL request to Linear on the connection, refreshed first if it has run out.
    pub(crate) async fn linear(&self, body: Value) -> Result<Value, String> {
        let mut account = self.linear.lock().unwrap().clone().ok_or("Linear isn't connected")?;
        if account.expires <= now() + 60 && let Some(refresh) = account.refresh.clone() {
            let form = encode_form(&[("grant_type", "refresh_token"), ("refresh_token", &refresh), ("client_id", LINEAR_CLIENT)]);
            let tokens = self.exchange(&form).await?;
            account = Account { access: tokens.0, refresh: tokens.1.or(Some(refresh)), expires: tokens.2, ..account };
            self.keep(Some(account.clone()))?;
        }
        let config = curl_config(LINEAR_GRAPHQL, Some(&account.access), &body.to_string(), "application/json");
        let reply: Value = serde_json::from_str(&self.fetcher.run(curl(), Some(config)).await?).map_err(|e| format!("Linear answered oddly: {e}"))?;
        if let Some(error) = reply["errors"][0]["message"].as_str() { return Err(format!("Linear: {error}")) }
        Ok(reply)
    }

    /// Starts connecting Linear: the page to open in the browser. zerod listens for it to come back, then keeps the
    /// connection.
    pub async fn connect_linear(self: &Arc<Self>) -> Result<String, String> {
        let port = *self.port.lock().unwrap();
        let (verifier, state) = (random(), random());
        let redirect = format!("http://localhost:{port}/oauth/linear");
        let url = format!("https://linear.app/oauth/authorize?{}", encode_form(&[
            ("client_id", LINEAR_CLIENT), ("redirect_uri", &redirect), ("response_type", "code"), ("scope", "read"), ("state", &state),
            ("prompt", "consent"), ("code_challenge", &base64url(&sha256(verifier.as_bytes()))), ("code_challenge_method", "S256"),
        ]));
        // A sign-in started again (its tab closed unfinished) replaces the one the listener waits for.
        let listening = {
            let mut signing_in = self.signing_in.lock().unwrap();
            signing_in.0 = Some((state, verifier));
            std::mem::replace(&mut signing_in.1, true)
        };
        if listening { return Ok(url) }
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
                let query: std::collections::HashMap<String, String> = line.split_whitespace().nth(1).and_then(|path| path.split_once('?')).map(|(_, q)| decode_form(q)).unwrap_or_default();
                let waiting = me.signing_in.lock().unwrap().0.clone();
                let outcome = match (query.get("state"), query.get("code"), waiting) {
                    (Some(back), Some(code), Some((state, verifier))) if *back == state => Some(me.finish_linear(code, &redirect, &verifier).await),
                    _ => None,
                };
                let text = match &outcome {
                    Some(Ok(name)) => format!("Linear is connected to Zero ({name}). You can close this tab."),
                    Some(Err(why)) => format!("Linear didn't connect: {why}"),
                    None => format!("Linear didn't connect: {}", query.get("error_description").or(query.get("error")).map_or("this sign-in was replaced by a newer one", |s| s)),
                };
                let page = format!("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}", text.len());
                let _ = write.write_all(page.as_bytes()).await;
                let _ = write.shutdown().await;
                if outcome.is_some() { break }
            }
            drop(listener); // the port is free before the next connect may bind it
            *me.signing_in.lock().unwrap() = (None, false);
        });
        Ok(url)
    }

    async fn finish_linear(&self, code: &str, redirect: &str, verifier: &str) -> Result<String, String> {
        let form = encode_form(&[("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect), ("client_id", LINEAR_CLIENT), ("code_verifier", verifier)]);
        let (access, refresh, expires) = self.exchange(&form).await?;
        *self.linear.lock().unwrap() = Some(Account { name: String::new(), url_key: String::new(), access, refresh, expires });
        let viewer = self.linear(json!({"query": "{viewer{organization{name urlKey}}}"})).await?;
        let organization = &viewer["data"]["viewer"]["organization"];
        let mut account = self.linear.lock().unwrap().clone().ok_or("Linear disconnected")?;
        account.name = organization["name"].as_str().unwrap_or("Linear").into();
        account.url_key = organization["urlKey"].as_str().unwrap_or_default().into();
        self.keep(Some(account.clone()))?;
        Ok(account.name)
    }

    /// Forgets the connection and everything fetched through it.
    pub fn disconnect_linear(&self) -> Result<(), String> {
        self.remember("linear/", None);
        self.keep(None)
    }

    // Slack.

    /// The connected Slack workspace and its channels' ids by name, for the app: `{"team", "channels"}`.
    pub fn slack_state(&self) -> Option<Value> {
        self.slack.lock().unwrap().as_ref().map(|a| json!({"team": a.team, "channels": a.channels}))
    }

    /// The team connected and the user the token is for.
    pub(crate) fn slack_team(&self) -> Option<(SlackTeam, String)> { self.slack.lock().unwrap().as_ref().map(|a| (a.team.clone(), a.user_id.clone())) }

    /// A channel's name by its id, when it is one the connection listed.
    pub(crate) fn slack_channel_name(&self, id: &str) -> Option<String> {
        self.slack.lock().unwrap().as_ref().and_then(|a| a.channels.iter().find(|(_, i)| *i == id).map(|(name, _)| name.clone()))
    }

    /// Checks `token` with Slack, reads the workspace's channels, and keeps the connection. The state, as the app shows it.
    pub async fn connect_slack(&self, token: &str) -> Result<Value, String> {
        let token = token.trim();
        if !token.starts_with("xoxp-") { return Err("That isn't a user token: Slack's start with xoxp-.".into()) }
        let identity = slack_call(&*self.fetcher, token, "auth.test", &[]).await?;
        let (Some(id), Some(name)) = (identity["team_id"].as_str(), identity["team"].as_str()) else { return Err("Slack didn't say which workspace the token is for.".into()) };
        let domain = identity["url"].as_str().and_then(|u| u.strip_prefix("https://")).and_then(|u| u.split('.').next()).unwrap_or("").to_string();
        let channels = slack_channels(&*self.fetcher, token).await?;
        let account = SlackAccount { token: token.into(), team: SlackTeam { id: id.into(), name: name.into(), domain }, user_id: identity["user_id"].as_str().unwrap_or("").into(), channels };
        self.keep_slack(Some(account))?;
        Ok(self.slack_state().unwrap_or(Value::Null))
    }

    pub fn disconnect_slack(&self) -> Result<(), String> { self.keep_slack(None) }

    /// The channels again: new ones get ids too.
    pub async fn refresh_slack(&self) -> Result<(), String> {
        let Some(mut account) = self.slack.lock().unwrap().clone() else { return Ok(()) };
        account.channels = slack_channels(&*self.fetcher, &account.token).await?;
        self.keep_slack(Some(account))
    }

    /// One call to Slack's Web API on the connection; the answer when Slack says ok.
    pub(crate) async fn slack(&self, method: &str, params: &[(&str, &str)]) -> Result<Value, String> {
        let token = self.slack.lock().unwrap().as_ref().map(|a| a.token.clone()).ok_or("Slack isn't connected")?;
        slack_call(&*self.fetcher, &token, method, params).await
    }

    fn keep_slack(&self, account: Option<SlackAccount>) -> Result<(), String> {
        let file = self.home.join("slack.json");
        match &account {
            Some(account) => write_private(&file, &serde_json::to_vec(account).map_err(|e| e.to_string())?)?,
            None => { let _ = std::fs::remove_file(&file); }
        }
        *self.slack.lock().unwrap() = account;
        Ok(())
    }

    /// Tokens for a form sent to Linear's token endpoint: access, refresh, when the access runs out.
    async fn exchange(&self, form: &str) -> Result<(String, Option<String>, i64), String> {
        let config = curl_config("https://api.linear.app/oauth/token", None, form, "application/x-www-form-urlencoded");
        let reply: Value = serde_json::from_str(&self.fetcher.run(curl(), Some(config)).await?).map_err(|e| format!("Linear answered oddly: {e}"))?;
        let access = reply["access_token"].as_str().ok_or_else(|| reply["error_description"].as_str().unwrap_or("Linear gave no token").to_string())?;
        Ok((access.into(), reply["refresh_token"].as_str().map(Into::into), now() + reply["expires_in"].as_i64().unwrap_or(10 * 365 * 86400)))
    }

    /// The connection, in linear.json, readable by the user alone; none removes it.
    fn keep(&self, account: Option<Account>) -> Result<(), String> {
        let file = self.home.join("linear.json");
        match &account {
            Some(account) => write_private(&file, &serde_json::to_vec(account).map_err(|e| e.to_string())?)?,
            None => { let _ = std::fs::remove_file(&file); }
        }
        *self.linear.lock().unwrap() = account;
        Ok(())
    }
}

/// Writes `file` readable by the user alone.
fn write_private(file: &Path, data: &[u8]) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut out = std::fs::OpenOptions::new().create(true).write(true).truncate(true).mode(0o600).open(file).map_err(|e| e.to_string())?;
    std::io::Write::write_all(&mut out, data).map_err(|e| e.to_string())
}

fn upsert<V>(views: &mut Vec<V>, mut view: V, id: impl Fn(&mut V) -> &mut String) {
    if id(&mut view).is_empty() { *id(&mut view) = random()[..8].to_string() }
    let key = id(&mut view).clone();
    match views.iter_mut().position(|v| *id(v) == key) { Some(i) => views[i] = view, None => views.push(view) }
}

pub fn github_items(reply: &Value) -> Vec<Item> {
    reply["data"]["search"]["nodes"].as_array().into_iter().flatten().filter_map(|pr| {
        let review = pr["reviewDecision"].as_str().map(|d| d.to_lowercase().replace('_', " "));
        Some(Item {
            id: pr["id"].as_str()?.into(), key: format!("#{}", pr["number"].as_i64()?), title: pr["title"].as_str()?.into(), url: pr["url"].as_str()?.into(),
            place: pr["repository"]["nameWithOwner"].as_str().unwrap_or_default().into(), state: if pr["isDraft"] == true { "Draft" } else { "Open" }.into(), color: None,
            checks: pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["state"].as_str().map(|s| s.to_lowercase()),
            review, person: pr["author"]["login"].as_str().map(Into::into), priority: None, updated: pr["updatedAt"].as_str().unwrap_or_default().into(),
            ..Default::default()
        })
    }).collect()
}

pub fn linear_filter(view: &LinearView) -> Value {
    let mut filter = serde_json::Map::new();
    match view.assignee {
        Assignee::Me => { filter.insert("assignee".into(), json!({"isMe": {"eq": true}})); }
        Assignee::Nobody => { filter.insert("assignee".into(), json!({"null": true})); }
        Assignee::Anyone => {}
    }
    if !view.teams.is_empty() { filter.insert("team".into(), json!({"key": {"in": view.teams}})); }
    if !view.state_names.is_empty() { filter.insert("state".into(), json!({"name": {"in": view.state_names}})); }
    else if !view.states.is_empty() { filter.insert("state".into(), json!({"type": {"in": view.states}})); }
    Value::Object(filter)
}

/// Grouped by state as Linear lists them: in progress, to do, backlog, triage, done, canceled; within each type, the
/// furthest along (highest position) first.
fn by_workflow(values: &mut [Value], state: impl Fn(&Value) -> &Value) {
    const TYPES: [&str; 6] = ["started", "unstarted", "backlog", "triage", "completed", "canceled"];
    let rank = |value: &Value| TYPES.iter().position(|t| state(value)["type"] == *t).unwrap_or(TYPES.len());
    let position = |value: &Value| state(value)["position"].as_f64().unwrap_or(0.0);
    values.sort_by(|a, b| rank(a).cmp(&rank(b)).then(position(b).total_cmp(&position(a))));
}

pub fn linear_items(reply: &Value) -> Vec<Item> {
    let mut issues = reply["data"]["issues"]["nodes"].as_array().cloned().unwrap_or_default();
    by_workflow(&mut issues, |issue| &issue["state"]);
    issues.iter().filter_map(|issue| Some(Item {
        id: issue["id"].as_str()?.into(), key: issue["identifier"].as_str()?.into(), title: issue["title"].as_str()?.into(), url: issue["url"].as_str()?.into(),
        place: issue["team"]["key"].as_str().unwrap_or_default().into(), state: issue["state"]["name"].as_str().unwrap_or_default().into(),
        color: issue["state"]["color"].as_str().map(Into::into), checks: None, review: None, person: issue["assignee"]["name"].as_str().map(Into::into),
        priority: issue["priority"].as_u64().map(|p| p as u8), updated: issue["updatedAt"].as_str().unwrap_or_default().into(),
        kind: issue["state"]["type"].as_str().map(Into::into), avatar: issue["assignee"]["avatarUrl"].as_str().map(Into::into),
        created: issue["createdAt"].as_str().map(Into::into),
        task: None,
        tags: issue["labels"]["nodes"].as_array().into_iter().flatten().chain(issue["project"].is_object().then_some(&issue["project"])).filter_map(|tag| Some(Tag {
            name: tag["name"].as_str()?.into(), color: tag["color"].as_str().map(Into::into), icon: tag["icon"].as_str().map(Into::into),
        })).collect(),
    })).collect()
}

async fn slack_call(fetcher: &dyn Fetcher, token: &str, method: &str, params: &[(&str, &str)]) -> Result<Value, String> {
    let url = format!("https://slack.com/api/{method}{}{}", if params.is_empty() { "" } else { "?" }, encode_form(params));
    let config = format!("url = \"{url}\"\nheader = \"Authorization: Bearer {token}\"\n");
    let reply: Value = serde_json::from_str(&fetcher.run(curl(), Some(config)).await?).map_err(|e| format!("Slack answered oddly: {e}"))?;
    if reply["ok"] != true { return Err(format!("Slack {method}: {}", reply["error"].as_str().unwrap_or("no"))) }
    Ok(reply)
}

/// Every channel's id by name, public and private, page by page.
async fn slack_channels(fetcher: &dyn Fetcher, token: &str) -> Result<BTreeMap<String, String>, String> {
    let (mut all, mut cursor) = (BTreeMap::new(), String::new());
    loop {
        let mut params = vec![("types", "public_channel,private_channel"), ("exclude_archived", "true"), ("limit", "1000")];
        if !cursor.is_empty() { params.push(("cursor", &cursor)) }
        let page = slack_call(fetcher, token, "conversations.list", &params).await?;
        for channel in page["channels"].as_array().into_iter().flatten() {
            if let (Some(name), Some(id)) = (channel["name"].as_str(), channel["id"].as_str()) { all.entry(name.to_string()).or_insert(id.to_string()); }
        }
        cursor = page["response_metadata"]["next_cursor"].as_str().unwrap_or("").to_string();
        if cursor.is_empty() { return Ok(all) }
    }
}

/// curl's config, read from its stdin (`curl -K -`), so the token and the body stay off the command line.
pub fn curl_config(url: &str, token: Option<&str>, body: &str, content: &str) -> String {
    let quote = |text: &str| format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""));
    let mut config = format!("url = {}\n", quote(url));
    if let Some(token) = token { config += &format!("header = {}\n", quote(&format!("Authorization: Bearer {token}"))) }
    config += &format!("header = {}\ndata = {}\n", quote(&format!("Content-Type: {content}")), quote(body));
    config
}

fn curl() -> Vec<String> { ["curl", "-sS", "--fail-with-body", "-K", "-"].map(String::from).to_vec() }

fn now() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0) }

fn random() -> String {
    let mut bytes = [0u8; 32];
    if let Ok(mut source) = std::fs::File::open("/dev/urandom") { let _ = std::io::Read::read_exact(&mut source, &mut bytes); }
    base64url(&bytes)
}

fn encode_form(pairs: &[(&str, &str)]) -> String {
    let encode = |text: &str| text.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect::<String>();
    pairs.iter().map(|(k, v)| format!("{}={}", encode(k), encode(v))).collect::<Vec<_>>().join("&")
}

fn decode_form(query: &str) -> std::collections::HashMap<String, String> {
    let decode = |text: &str| {
        let bytes = text.replace('+', " ").into_bytes();
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            let escaped = (bytes[i] == b'%' && i + 2 < bytes.len()).then(|| std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok())).flatten();
            match escaped { Some(b) => { out.push(b); i += 3 } None => { out.push(bytes[i]); i += 1 } }
        }
        String::from_utf8_lossy(&out).to_string()
    };
    query.split('&').filter_map(|pair| pair.split_once('=')).map(|(k, v)| (decode(k), decode(v))).collect()
}

pub fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    bytes.chunks(3).flat_map(|chunk| {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
        (0..=chunk.len()).map(move |i| ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char)
    }).collect()
}

/// SHA-256, for PKCE's code challenge: a few lines rather than a crate for one hash.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 { message.push(0) }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in message.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 { w[i] = u32::from_be_bytes([block[4 * i], block[4 * i + 1], block[4 * i + 2], block[4 * i + 3]]) }
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
        for i in 0..8 { h[i] = h[i].wrapping_add(v[i]) }
    }
    let mut out = [0u8; 32];
    for i in 0..8 { out[4 * i..4 * i + 4].copy_from_slice(&h[i].to_be_bytes()) }
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
