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
