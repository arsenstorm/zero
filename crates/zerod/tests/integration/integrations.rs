//! Integrations: who gh is signed in as, and the Linear and Slack connections zerod makes and keeps, which following
//! reads through and which make issue keys and channels in messages links.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::common::temp_dir;
use serde_json::{Value, json};
use zerod::integrations::*;

/// A fetcher that answers each command from a list, and records what it was asked.
#[derive(Default)]
struct Canned {
    answers: Mutex<Vec<Result<String, String>>>,
    asked: Mutex<Vec<(Vec<String>, Option<String>)>>,
}

impl Fetcher for Canned {
    fn run(&self, argv: Vec<String>, stdin: Option<String>) -> zerod::inbox::Fut<'_, Result<String, String>> {
        self.asked.lock().unwrap().push((argv, stdin));
        let answer = self.answers.lock().unwrap().remove(0);
        Box::pin(async move { answer })
    }
}

fn canned(answers: Vec<Value>) -> Arc<Canned> {
    Arc::new(Canned { answers: Mutex::new(answers.into_iter().map(|a| Ok(a.to_string())).collect()), ..Default::default() })
}

#[tokio::test]
async fn linear_teams_link_their_issue_keys_to_the_connected_workspace() {
    let home = temp_dir("integrations-linear-teams");
    std::fs::write(home.join("linear.json"), r#"{"name":"Acme","url_key":"acme","access":"lin_tok","refresh":null,"expires":9999999999}"#)
        .unwrap();
    let integrations = Integrations::open(&home, canned(vec![json!({"data": {"teams": {"nodes": [{"key": "ENG"}, {"key": "web"}]}}})]));
    assert!(integrations.linear_teams().is_empty(), "none known until Linear is asked");
    integrations.refresh_linear_teams().await.unwrap();
    let teams = BTreeMap::from([("ENG".to_string(), "acme".to_string()), ("WEB".into(), "acme".into())]);
    assert_eq!(integrations.linear_teams(), teams);
    assert_eq!(Integrations::open(&home, canned(vec![])).linear_teams(), teams, "kept in linear.json");
}

#[test]
fn the_linear_token_reaches_curl_on_its_stdin_never_its_command_line() {
    let config = curl_config("https://api.linear.app/graphql", Some("lin_tok"), "{\"query\":\"a \\\"b\\\"\"}", "application/json");
    assert_eq!(
        config,
        "url = \"https://api.linear.app/graphql\"\nheader = \"Authorization: Bearer lin_tok\"\nheader = \"Content-Type: application/json\"\ndata = \"{\\\"query\\\":\\\"a \\\\\\\"b\\\\\\\"\\\"}\"\n"
    );
}

#[tokio::test]
async fn linear_is_connected_in_the_browser_and_its_teams_read_with_that_connection() {
    let home = temp_dir("integrations-linear");
    let fetcher = canned(vec![
        json!({"access_token": "lin_tok", "refresh_token": "ref", "expires_in": 86400}),
        json!({"data": {"viewer": {"organization": {"name": "Acme", "urlKey": "acme"}}, "teams": {"nodes": [{"key": "ENG"}]}}}),
    ]);
    let integrations = Integrations::open(&home, fetcher.clone());
    integrations.listen_on(47699);
    assert_eq!(integrations.refresh_linear_teams().await.unwrap_err(), "Linear isn't connected");
    let url = integrations.connect_linear().await.unwrap();
    assert!(url.starts_with("https://linear.app/oauth/authorize?") && url.contains("code_challenge_method=S256"), "{url}");
    let state = url.split("state=").nth(1).unwrap().split('&').next().unwrap().to_string();
    // The browser comes back to zerod's listener.
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", 47699)).await.unwrap();
    tokio::io::AsyncWriteExt::write_all(
        &mut stream,
        format!("GET /oauth/linear?code=c0de&state={state} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes(),
    )
    .await
    .unwrap();
    let mut page = String::new();
    tokio::io::AsyncReadExt::read_to_string(&mut stream, &mut page).await.unwrap();
    assert!(page.contains("200 OK") && page.contains("Linear is connected"), "{page}");
    for _ in 0..100 {
        if integrations.linear_workspace().is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await
    }
    assert_eq!(integrations.linear_workspace().as_deref(), Some("Acme"));
    let exchange = fetcher.asked.lock().unwrap()[0].1.clone().unwrap();
    assert!(exchange.contains("code=c0de") && exchange.contains("code_verifier="), "{exchange}");
    assert_eq!(integrations.linear_teams(), BTreeMap::from([("ENG".to_string(), "acme".to_string())]));
    let (argv, stdin) = fetcher.asked.lock().unwrap()[1].clone();
    assert!(!argv.iter().any(|a| a.contains("lin_tok")) && stdin.unwrap().contains("Bearer lin_tok"));
    // Kept for the next start, readable by the user alone.
    let kept = home.join("linear.json");
    assert_eq!(std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&kept).unwrap().permissions()) & 0o777, 0o600);
    assert_eq!(Integrations::open(&home, canned(vec![])).linear_workspace().as_deref(), Some("Acme"));
}

#[tokio::test]
async fn githubs_account_is_whoever_gh_is_signed_in_as() {
    let fetcher = Arc::new(Canned {
        answers: Mutex::new(vec![Err("not logged into any GitHub hosts".into()), Ok("arsen\n".into())]),
        ..Default::default()
    });
    let integrations = Integrations::open(&temp_dir("integrations-gh-account"), fetcher.clone());
    assert_eq!(integrations.github_account().await, None, "gh isn't signed in");
    assert_eq!(integrations.github_account().await.as_deref(), Some("arsen"));
    assert_eq!(integrations.github_account().await.as_deref(), Some("arsen"), "asked once, then remembered");
    assert_eq!(fetcher.asked.lock().unwrap().len(), 2);
    assert!(fetcher.asked.lock().unwrap()[1].0.ends_with(&["gh".to_string(), "api".into(), "user".into(), "--jq".into(), ".login".into()]));
}

#[tokio::test]
async fn connecting_linear_again_while_one_waits_starts_over_on_the_same_listener() {
    let fetcher = canned(vec![
        json!({"access_token": "lin_tok", "expires_in": 86400}),
        json!({"data": {"viewer": {"organization": {"name": "Acme", "urlKey": "acme"}}}}),
    ]);
    let integrations = Integrations::open(&temp_dir("integrations-linear-again"), fetcher.clone());
    integrations.listen_on(47698);
    let state = |url: String| url.split("state=").nth(1).unwrap().split('&').next().unwrap().to_string();
    let first = state(integrations.connect_linear().await.unwrap());
    // The first tab was closed unfinished; Connect again.
    let second = state(integrations.connect_linear().await.expect("a second connect reuses the waiting listener"));
    let visit = |state: String| async move {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", 47698)).await.unwrap();
        tokio::io::AsyncWriteExt::write_all(&mut stream, format!("GET /oauth/linear?code=c0de&state={state} HTTP/1.1\r\n\r\n").as_bytes())
            .await
            .unwrap();
        let mut page = String::new();
        tokio::io::AsyncReadExt::read_to_string(&mut stream, &mut page).await.unwrap();
        page
    };
    assert!(visit(first).await.contains("Linear didn't connect"), "the old sign-in no longer counts");
    assert!(visit(second).await.contains("Linear is connected"), "and the listener keeps waiting for the new one");
    assert_eq!(integrations.linear_workspace().as_deref(), Some("Acme"));
}

#[tokio::test]
async fn a_command_that_hangs_is_given_up_on() {
    let started = std::time::Instant::now();
    let commands = Commands { timeout: std::time::Duration::from_millis(200) };
    assert_eq!(commands.run(vec!["/bin/sleep".into(), "5".into()], None).await.unwrap_err(), "/bin/sleep took too long");
    assert!(started.elapsed() < std::time::Duration::from_secs(2));
}

#[tokio::test]
async fn slack_is_connected_with_a_user_token_and_its_channels_read() {
    let fetcher = canned(vec![
        json!({"ok": true, "team_id": "T0AB", "team": "Acme", "url": "https://acme.slack.com/", "user_id": "U2"}),
        json!({"ok": true, "channels": [{"id": "C0D", "name": "docs"}], "response_metadata": {"next_cursor": "more"}}),
        json!({"ok": true, "channels": [{"id": "C0E", "name": "eng"}], "response_metadata": {"next_cursor": ""}}),
    ]);
    let home = temp_dir("integrations-slack");
    let integrations = Integrations::open(&home, fetcher.clone());
    assert_eq!(
        integrations.connect_slack("xoxb-not-a-user-token").await.unwrap_err(),
        "That isn't a user token: Slack's start with xoxp-."
    );
    let state = integrations.connect_slack(" xoxp-123 ").await.unwrap();
    assert_eq!(
        state,
        json!([{"team": {"id": "T0AB", "name": "Acme", "domain": "acme"}, "channels": {"docs": "C0D", "eng": "C0E"}}]),
        "one of the workspaces connected"
    );
    let asked = fetcher.asked.lock().unwrap().clone();
    assert_eq!(asked[0].0[0], "curl");
    assert_eq!(
        asked[0].1.as_deref(),
        Some("url = \"https://slack.com/api/auth.test\"\nheader = \"Authorization: Bearer xoxp-123\"\n"),
        "the token on curl's stdin, never its command line"
    );
    assert!(asked[2].1.as_deref().unwrap().contains("cursor=more"));
    // Kept, the user's alone; gone when disconnected.
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(home.join("slack.json")).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(Integrations::open(&home, canned(vec![])).slack_state(), state);
    integrations.disconnect_slack("T0AB").unwrap();
    assert!(integrations.slack_state() == json!([]) && !home.join("slack.json").exists());
}

/// What curl prints for an agent's call: the body, then a line of the status and the rate-limit headers.
fn http(body: Value, status: u16, retry_after: &str) -> Result<String, String> {
    Ok(format!("{body}\n{status}|{retry_after}||"))
}

/// zerod served on a home with Slack (two workspaces) and Linear connected, and one task, answering curl from a list.
async fn connected(name: &str, answers: Vec<Result<String, String>>) -> (Arc<Canned>, Arc<zerod::inbox::Inbox>, std::path::PathBuf) {
    connected_as(name, answers, Arc::new(|_| true)).await
}

/// The same, with who may make the app's own ops decided by `peers`.
async fn connected_as(
    name: &str, answers: Vec<Result<String, String>>, peers: zerod::server::Peers,
) -> (Arc<Canned>, Arc<zerod::inbox::Inbox>, std::path::PathBuf) {
    let home = temp_dir(name);
    let slack = |token: &str, id: &str, name: &str| json!({"token": token, "team": {"id": id, "name": name, "domain": name.to_lowercase()}, "userId": "U1", "channels": {}});
    std::fs::write(home.join("slack.json"), json!([slack("xoxp-one", "T1", "Acme"), slack("xoxp-two", "T2", "Beta")]).to_string()).unwrap();
    std::fs::write(home.join("linear.json"), r#"{"name":"Acme","url_key":"acme","access":"lin_tok","refresh":null,"expires":9999999999}"#)
        .unwrap();
    let cwd = home.to_str().unwrap().to_string();
    let conversation = zerod::model::Conversation::new("0123456789abcdef", zerod::model::Provider::Claude, &cwd);
    drop(zerod::session::Session::new(conversation, Some(home.join("sessions/0123456789abcdef")), tokio::sync::broadcast::channel(8).0));
    let fetcher = Arc::new(Canned { answers: Mutex::new(answers), ..Default::default() });
    let runtime: zerod::daemon::Runtime = Arc::new(|_, _, _| Err(std::io::Error::other("no runtime here")));
    let inbox = zerod::inbox::Inbox::open(None, vec![]);
    inbox.configure(std::time::Duration::ZERO, 3600);
    let integrations = Integrations::open(&home, fetcher.clone());
    let socket = home.join("zerod.sock");
    tokio::spawn(zerod::server::serve(
        zerod::server::Zerod {
            daemon: zerod::daemon::Daemon::open(&home, runtime).unwrap(),
            inbox: inbox.clone(),
            integrations: integrations.clone(),
            following: zerod::following::Following::open(&home, fetcher.clone(), integrations),
            pads: Arc::new(zerod::pads::Pads::open(&home.join("scratchpads"))),
            later: Arc::new(zerod::later::Later::open(&home.join("later"))),
            loops: Arc::new(zerod::loops::Loops::open(&home.join("loops"))),
            browsers: zerod::browser::Browsers::open(&home),
            places: Default::default(),
            notices: tokio::sync::broadcast::channel(64).0,
            peers,
        },
        socket.clone(),
    ));
    for _ in 0..100 {
        if tokio::net::UnixStream::connect(&socket).await.is_ok() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await
    }
    (fetcher, inbox, socket)
}

/// One request on zerod's socket: its result, or its error.
async fn call(socket: &std::path::Path, request: Value) -> Result<Value, String> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let mut stream = tokio::net::UnixStream::connect(socket).await.unwrap();
    let mut request = request;
    request["id"] = json!(1);
    stream.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    let mut lines = tokio::io::BufReader::new(stream).lines();
    let reply: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
    if reply["ok"] == true { Ok(reply["result"].clone()) } else { Err(reply["error"].as_str().unwrap().to_string()) }
}

/// The user answers an ask (its first option, yes, or the second, no), past the take-back window.
async fn answer(inbox: &zerod::inbox::Inbox, id: &str, option: usize) {
    inbox.choose(id, option);
    for _ in 0..100 {
        if inbox.ask(id).is_some_and(|a| a.state.is_final()) {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await
    }
    panic!("ask {id} wasn't answered")
}

/// The ask id in a refusal that asked the user: "… (ask abc123) …".
fn asked(refusal: &str) -> String {
    refusal.split("(ask ").nth(1).and_then(|rest| rest.split(')').next()).unwrap_or_else(|| panic!("no ask in {refusal}")).to_string()
}

#[tokio::test]
async fn agents_read_slack_through_zeros_connection_and_post_only_with_the_users_leave() {
    let messages = json!({"ok": true, "messages": [{"text": "hi"}], "response_metadata": {"next_cursor": "c2"}});
    let (fetcher, inbox, socket) = connected(
        "agents-slack",
        vec![
            http(messages.clone(), 200, ""),
            http(json!({"ok": true, "user": {"id": "U9"}}), 200, ""),
            http(json!({"ok": false, "error": "channel_not_found"}), 200, ""),
            http(json!({"ok": false, "error": "missing_scope", "needed": "search:read"}), 200, ""),
            // Slack's rate limit: waited out as Retry-After says, then asked again.
            http(json!({"ok": false, "error": "ratelimited"}), 429, "0"),
            http(messages.clone(), 200, ""),
            http(json!({"ok": true, "ts": "1.2"}), 200, ""),
        ],
    )
    .await;
    let slack = |args: Value| json!({"op": "slack", "session": "0123456789abcdef", "args": args});
    let read = call(&socket, slack(json!({"method": "conversations.history", "params": {"channel": "C1", "limit": 2, "cursor": "c1"}})))
        .await
        .unwrap();
    assert_eq!(read, messages, "Slack's own answer, its paging cursor with it");
    let (argv, config) = fetcher.asked.lock().unwrap()[0].clone();
    let config = config.unwrap();
    assert!(!argv.iter().any(|a| a.contains("xoxp")), "the token never on the command line: {argv:?}");
    assert!(config.contains("Bearer xoxp-one"), "the first workspace, unless one is named");
    assert!(
        config.contains("slack.com/api/conversations.history") && ["channel=C1", "limit=2", "cursor=c1"].iter().all(|p| config.contains(p)),
        "{config}"
    );

    call(&socket, slack(json!({"method": "users.info", "params": {"user": "U9"}, "workspace": "beta"}))).await.unwrap();
    assert!(fetcher.asked.lock().unwrap()[1].1.as_deref().unwrap().contains("Bearer xoxp-two"), "a workspace by its name");
    let unknown = call(&socket, slack(json!({"method": "users.info", "workspace": "Gamma"}))).await.unwrap_err();
    assert!(unknown.contains("Acme") && unknown.contains("Beta"), "the workspaces there are: {unknown}");
    let failed = call(&socket, slack(json!({"method": "conversations.info", "params": {"channel": "C404"}}))).await.unwrap_err();
    assert_eq!(failed, "Slack conversations.info: channel_not_found");
    let scope = call(&socket, slack(json!({"method": "search.messages", "params": {"query": "deploy"}}))).await.unwrap_err();
    assert!(scope.contains("search:read") && scope.contains("connects Slack again"), "what the user does about it: {scope}");
    assert_eq!(call(&socket, slack(json!({"method": "conversations.history", "params": {"channel": "C1"}}))).await.unwrap(), messages);

    // Posting: refused while the user hasn't let agents post, and Slack never asked.
    let post = slack(json!({"method": "chat.postMessage", "params": {"channel": "C1", "text": "Deployed"}}));
    let refused = call(&socket, post.clone()).await.unwrap_err();
    assert!(refused.contains("Let agents post"), "{refused}");
    assert_eq!(fetcher.asked.lock().unwrap().len(), 6);

    // Let: each post is the user's to approve first, the call itself shown to them.
    call(&socket, json!({"op": "configure", "slackPosts": true, "takeBack": 0})).await.unwrap();
    let id = asked(&call(&socket, post.clone()).await.unwrap_err());
    let ask = inbox.ask(&id).unwrap();
    assert_eq!(ask.kind, zerod::ask::AskKind::Approve);
    assert!(ask.command.as_deref().unwrap().contains("chat.postMessage") && ask.command.as_deref().unwrap().contains("text=Deployed"));
    assert_eq!(ask.agent.reference.as_deref(), Some("0123456789abcdef"), "the task's own ask");
    let early =
        call(&socket, slack(json!({"method": "chat.postMessage", "params": {"channel": "C1", "text": "Deployed"}, "approval": id})))
            .await
            .unwrap_err();
    assert!(early.contains("isn't the user's approval"), "not approved yet: {early}");
    answer(&inbox, &id, 0).await;
    let approved = |text: &str| slack(json!({"method": "chat.postMessage", "params": {"channel": "C1", "text": text}, "approval": id}));
    let other = call(&socket, approved("Rolled back")).await.unwrap_err();
    assert!(other.contains("isn't the user's approval"), "another post than the one approved: {other}");
    assert_eq!(call(&socket, approved("Deployed")).await.unwrap()["ts"], "1.2");
    assert!(fetcher.asked.lock().unwrap()[6].1.as_deref().unwrap().contains("text=Deployed"));
    let again = call(&socket, approved("Deployed")).await.unwrap_err();
    assert!(again.contains("isn't the user's approval"), "an approval is for one post: {again}");

    // Declined stays declined; outside a task there is no one to ask.
    let id = asked(&call(&socket, post.clone()).await.unwrap_err());
    answer(&inbox, &id, 1).await;
    assert!(call(&socket, approved("Deployed")).await.is_err());
    let outside = call(&socket, json!({"op": "slack", "args": {"method": "chat.postMessage", "params": {"channel": "C1"}}})).await;
    assert!(outside.unwrap_err().contains("task"));
    assert_eq!(fetcher.asked.lock().unwrap().len(), 7, "no post but the approved one");
}

#[tokio::test]
async fn agents_query_linear_through_zeros_connection_and_change_it_only_with_the_users_leave() {
    let issue = json!({"data": {"issue": {"title": "Fix it"}}});
    let (fetcher, inbox, socket) = connected(
        "agents-linear",
        vec![
            http(issue.clone(), 200, ""),
            http(json!({"errors": [{"message": "Entity not found", "extensions": {"code": "INVALID_INPUT"}}]}), 200, ""),
            http(json!({"data": {"issueUpdate": {"success": true}}}), 200, ""),
        ],
    )
    .await;
    let linear = |query: &str, more: Value| {
        let mut args = json!({"query": query});
        args.as_object_mut().unwrap().extend(more.as_object().unwrap().clone());
        json!({"op": "linear", "session": "0123456789abcdef", "args": args})
    };
    let query = "query($id: String!) { issue(id: $id) { title } }";
    assert_eq!(call(&socket, linear(query, json!({"variables": {"id": "ENG-1"}}))).await.unwrap(), issue);
    let (argv, config) = fetcher.asked.lock().unwrap()[0].clone();
    assert!(!argv.iter().any(|a| a.contains("lin_tok")) && config.as_deref().unwrap().contains("Bearer lin_tok"));
    assert!(config.unwrap().contains("ENG-1"), "the variables go with the query");
    assert_eq!(call(&socket, linear("{ issue(id: \"X\") { id } }", json!({}))).await.unwrap_err(), "Linear: Entity not found");

    let change = "mutation { issueUpdate(id: \"ENG-1\", input: {stateId: \"done\"}) { success } }";
    let refused = call(&socket, linear(change, json!({}))).await.unwrap_err();
    assert!(refused.contains("Let agents make changes"), "{refused}");
    call(&socket, json!({"op": "configure", "linearChanges": true, "takeBack": 0})).await.unwrap();
    let id = asked(&call(&socket, linear(change, json!({}))).await.unwrap_err());
    assert!(inbox.ask(&id).unwrap().command.as_deref().unwrap().contains("issueUpdate"));
    answer(&inbox, &id, 0).await;
    let made = call(&socket, linear(change, json!({"approval": id}))).await.unwrap();
    assert_eq!(made["data"]["issueUpdate"]["success"], true);
    assert_eq!(fetcher.asked.lock().unwrap().len(), 3);
}

#[test]
fn a_graphql_document_changes_linear_when_any_of_its_operations_is_a_mutation() {
    assert!(!changes_linear("{ viewer { id } }"));
    assert!(!changes_linear("query Issues { issues(filter: {title: {contains: \"mutation\"}}) { nodes { id } } }"));
    assert!(!changes_linear("# mutation { issueDelete }\nquery { viewer { id } }"));
    assert!(changes_linear("mutation { issueDelete(id: \"x\") { success } }"));
    assert!(changes_linear("query A { viewer { id } }\n  mutation B($id: String!) { issueArchive(id: $id) { success } }"));
    assert!(changes_linear("subscription { issues }"), "anything but a query is refused as a change");
}

#[test]
fn agents_slack_reads_are_a_list_and_everything_else_is_a_write() {
    for read in ["conversations.history", "conversations.replies", "search.messages", "users.info", "chat.getPermalink", "team.info"] {
        assert!(slack_reads(read), "{read}")
    }
    for write in ["chat.postMessage", "chat.delete", "reactions.add", "conversations.join", "auth.revoke", "files.upload"] {
        assert!(!slack_reads(write), "{write}")
    }
}

#[tokio::test]
async fn linear_is_connected_with_its_write_scope_only_once_agents_may_change_it() {
    let home = temp_dir("integrations-linear-scope");
    let integrations = Integrations::open(&home, canned(vec![]));
    integrations.listen_on(47696);
    assert!(integrations.connect_linear().await.unwrap().contains("scope=read&"), "read alone by default");
    std::fs::write(home.join("settings.json"), r#"{"linearChanges": true, "slackPosts": true}"#).unwrap();
    assert!(
        integrations.connect_linear().await.unwrap().contains("scope=read&"),
        "settings.json, which any process can write, doesn't turn it on"
    );
    assert!(!integrations.writes().slack_posts);
    integrations.set_writes(None, Some(true)).unwrap();
    assert!(integrations.connect_linear().await.unwrap().contains("scope=read%2Cwrite&"));
    assert!(Integrations::open(&home, canned(vec![])).writes().linear_changes, "kept with the tokens, where only zerod reads");
}

#[tokio::test]
async fn the_write_switches_are_set_by_the_app_and_never_read_from_settings_json() {
    let (_, _, socket) = connected("agents-switches", vec![]).await;
    let home = socket.parent().unwrap().to_path_buf();
    std::fs::write(home.join("settings.json"), r#"{"slackPosts": true, "linearChanges": true}"#).unwrap();
    let settings = call(&socket, json!({"op": "settings"})).await.unwrap();
    assert_eq!((settings["slackPosts"].clone(), settings["linearChanges"].clone()), (json!(false), json!(false)), "{settings}");
    let post = json!({"op": "slack", "session": "0123456789abcdef", "args": {"method": "chat.postMessage", "params": {"channel": "C1"}}});
    assert!(call(&socket, post).await.unwrap_err().contains("Let agents post"), "a hand-edited settings.json lets nothing through");
    call(&socket, json!({"op": "configure", "slackPosts": true})).await.unwrap();
    assert_eq!(call(&socket, json!({"op": "settings"})).await.unwrap()["slackPosts"], true);
    let kept = std::fs::read_to_string(home.join("settings.json")).unwrap();
    assert!(!kept.contains("slackPosts") && !kept.contains("linearChanges"), "not kept where anyone edits it: {kept}");
}

#[tokio::test]
async fn tokens_move_out_of_slack_json_and_linear_json_into_zerods_vault() {
    let home = temp_dir("integrations-vault");
    let slack =
        json!([{"token": "xoxp-one", "team": {"id": "T1", "name": "Acme", "domain": "acme"}, "userId": "U1", "channels": {"eng": "C1"}}]);
    std::fs::write(home.join("slack.json"), slack.to_string()).unwrap();
    std::fs::write(
        home.join("linear.json"),
        r#"{"name":"Acme","url_key":"acme","access":"lin_tok","refresh":"lin_ref","expires":9999999999}"#,
    )
    .unwrap();
    let integrations = Integrations::open(&home, canned(vec![]));
    let files = ["slack.json", "linear.json"].map(|f| std::fs::read_to_string(home.join(f)).unwrap());
    for (file, token) in [(&files[0], "xoxp-one"), (&files[1], "lin_tok"), (&files[1], "lin_ref")] {
        assert!(!file.contains(token), "{token} left in {file}");
    }
    assert!(files[0].contains("C1") && files[1].contains("acme"), "what isn't secret stays: {files:?}");
    assert_eq!(integrations.slack_state()[0]["team"]["id"], "T1");

    // Read back from the vault (here a file of the test's own; the user's zerod's is its Keychain item).
    let fetcher = canned(vec![]);
    fetcher.answers.lock().unwrap().extend([http(json!({"ok": true}), 200, ""), http(json!({"data": {}}), 200, "")]);
    let reopened = Integrations::open(&home, fetcher.clone());
    reopened.slack_for_agent(None, "auth.test", &[]).await.unwrap();
    reopened.linear_for_agent("{ viewer { id } }", None).await.unwrap();
    let asked = fetcher.asked.lock().unwrap().clone();
    assert!(asked[0].1.as_deref().unwrap().contains("Bearer xoxp-one") && asked[1].1.as_deref().unwrap().contains("Bearer lin_tok"));

    // Connected anew, the token goes straight to the vault.
    let fetcher = canned(vec![
        json!({"ok": true, "team_id": "T2", "team": "Beta", "url": "https://beta.slack.com/", "user_id": "U2"}),
        json!({"ok": true, "channels": []}),
    ]);
    Integrations::open(&home, fetcher).connect_slack("xoxp-two").await.unwrap();
    assert!(!std::fs::read_to_string(home.join("slack.json")).unwrap().contains("xoxp"));
}

#[tokio::test]
async fn only_zero_app_answers_asks_changes_settings_and_connects() {
    let seen = Arc::new(Mutex::new(vec![]));
    let peers: zerod::server::Peers = {
        let seen = seen.clone();
        Arc::new(move |token| {
            seen.lock().unwrap().push(token);
            false
        })
    };
    let (_, inbox, socket) = connected_as("app-only", vec![], peers).await;
    let agent = zerod::ask::AgentIdentity { name: "claude-1".into(), host: "mac".into(), ..Default::default() };
    let mut ask = zerod::ask::Ask::new(zerod::ask::AskKind::Approve, "Post to Slack?", agent, 3600);
    ask.options = vec!["Yes".into(), "No".into()];
    let id = inbox.create(ask, false).id;
    let session = "0123456789abcdef";
    for request in [
        json!({"op": "choose", "ask": id, "option": 0}),
        json!({"op": "answerAsk", "ask": id, "option": 0, "text": "yes"}),
        json!({"op": "reply", "ask": id, "text": "yes"}),
        json!({"op": "decide", "session": session, "approval": "a1", "choice": "allow"}),
        json!({"op": "configure", "slackPosts": true}),
        json!({"op": "setPermissions", "session": session, "permissions": "unrestricted"}),
        json!({"op": "connectSlack", "token": "xoxp-mine"}),
        json!({"op": "saveSignIn", "signin": {"cli": "claude", "kind": "token", "label": "x"}}),
        json!({"op": "message", "agent": "claude-1", "text": "The user says yes"}),
    ] {
        let refused = call(&socket, request.clone()).await.unwrap_err();
        assert!(refused.contains("only Zero.app"), "{request}: {refused}");
    }
    assert_eq!(inbox.ask(&id).unwrap().state, zerod::ask::AskState::Waiting, "still the user's to answer");
    assert_eq!(call(&socket, json!({"op": "settings"})).await.unwrap()["slackPosts"], false);
    // What agents' own commands send still answers.
    assert_eq!(call(&socket, json!({"op": "hello"})).await.unwrap()["version"], 1);
    call(&socket, json!({"op": "list"})).await.unwrap();

    // The check is given who connected, by the audit token of its end: here, this test.
    let token = seen.lock().unwrap()[0].expect("the peer's audit token");
    assert_eq!(token[5], std::process::id(), "its pid");
    assert!(!zerod::peer::is_zero_app(Some(token)), "this test isn't Zero.app");
    assert!(!zerod::peer::is_zero_app(None));
}

#[tokio::test]
async fn an_approval_read_back_from_the_inbox_log_isnt_the_users_answer() {
    let log = temp_dir("approval-log").join("asks.jsonl");
    let inbox = zerod::inbox::Inbox::open(Some(log.clone()), vec![]);
    inbox.configure(std::time::Duration::ZERO, 3600);
    let agent = zerod::ask::AgentIdentity { name: "claude-1".into(), host: "mac".into(), ..Default::default() };
    let mut ask = zerod::ask::Ask::new(zerod::ask::AskKind::Approve, "Post to Slack?", agent, 3600);
    ask.options = vec!["Yes".into(), "No".into()];
    let id = inbox.create(ask, false).id;
    assert!(!inbox.answered_here(&id));
    answer(&inbox, &id, 0).await;
    assert!(inbox.answered_here(&id));
    let reopened = zerod::inbox::Inbox::open(Some(log), vec![]);
    assert_eq!(reopened.ask(&id).unwrap().state, zerod::ask::AskState::Answered);
    assert!(!reopened.answered_here(&id), "asks.jsonl is a file any of the user's processes can write");
}

/// zerod's Keychain item, in a keychain of the test's own (never the user's): read back by the code that wrote it,
/// trusting it alone, and refused to every other process without a word to the user. Run by hand:
/// `cargo test -p zerod --test integration -- --ignored keychain`.
#[test]
#[ignore = "makes a keychain of its own: run by hand"]
fn zerods_keychain_item_is_its_own() {
    let path = temp_dir("vault-keychain").join("zero-test.keychain-db");
    let security = |args: &[&str]| {
        let out = std::process::Command::new("/usr/bin/security").args(args).output().unwrap();
        assert!(out.status.success(), "security {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr)
    };
    let keychain = path.to_str().unwrap();
    security(&["create-keychain", "-p", "throwaway", keychain]);
    // create-keychain puts it in the user's search list: deleting it takes it out, whatever the test does.
    struct Gone<'a>(&'a str);
    impl Drop for Gone<'_> {
        fn drop(&mut self) {
            let _ = std::process::Command::new("/usr/bin/security").args(["delete-keychain", self.0]).output();
        }
    }
    let _gone = Gone(keychain);
    zerod::vault::no_prompts();
    let vault = zerod::vault::Vault::Keychain(Some(path.clone()));
    assert_eq!(vault.read().unwrap(), None);
    vault.write(b"{\"slack\":{}}").unwrap();
    vault.write(b"{\"slack\":{\"T1\":\"xoxp-test\"}}").unwrap();
    assert_eq!(vault.read().unwrap().as_deref(), Some(&b"{\"slack\":{\"T1\":\"xoxp-test\"}}"[..]), "zerod reads its own, updated in place");
    let acl = security(&["dump-keychain", "-a", keychain]);
    let me = std::env::current_exe().unwrap();
    assert!(acl.contains(me.to_str().unwrap()), "trusts the code that wrote it: {acl}");
    assert!(!acl.contains("/usr/bin/security"), "and not `security`: {acl}");
    // Another program (here one of the test's own, its prompts turned off so none can show) is refused, not answered.
    let dir = path.parent().unwrap();
    let source = dir.join("reader.c");
    std::fs::write(&source, READER).unwrap();
    let reader = dir.join("reader");
    let built =
        std::process::Command::new("/usr/bin/cc").args(["-framework", "Security", "-o"]).arg(&reader).arg(&source).output().unwrap();
    assert!(built.status.success(), "{}", String::from_utf8_lossy(&built.stderr));
    let read = std::process::Command::new(&reader).arg(keychain).output().unwrap();
    let said = String::from_utf8_lossy(&read.stdout).to_string();
    // errSecAuthFailed: found, and refused; with prompts on, the Keychain would have asked the user instead.
    assert_eq!(said.trim(), "-25293", "another program read zerod's item, or didn't find it");
}

/// Reads zerod's item from the keychain given, never prompting: prints the Keychain's status, and the value if given it.
const READER: &str = r#"
#include <Security/Security.h>
#include <stdio.h>
int main(int argc, char **argv) {
    SecKeychainSetUserInteractionAllowed(false);
    SecKeychainRef keychain = NULL;
    if (SecKeychainOpen(argv[1], &keychain) != 0) return 2;
    UInt32 length = 0; void *value = NULL;
    OSStatus status = SecKeychainFindGenericPassword(keychain, 17, "Zero integrations", 5, "zerod", &length, &value, NULL);
    printf("%d\n", (int)status);
    if (status == 0) printf("%.*s\n", (int)length, (char *)value);
    return 0;
}
"#;

#[test]
fn an_approval_spent_stays_spent_across_a_restart() {
    let home = temp_dir("integrations-spent");
    let integrations = Integrations::open(&home, canned(vec![]));
    assert!(integrations.spend("abc123"));
    assert!(!integrations.spend("abc123"));
    assert!(!Integrations::open(&home, canned(vec![])).spend("abc123"), "a restarted zerod remembers it");
    assert!(Integrations::open(&home, canned(vec![])).spend("def456"));
}
