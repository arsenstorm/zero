//! Integrations: GitHub and Linear as views, each a saved filter the user names and changes, fetched by zerod (GitHub
//! through `gh`, which keeps its own sign-in; Linear through its API on a connection zerod makes and keeps).


use std::sync::{Arc, Mutex};

use crate::common::temp_dir;
use serde_json::{Value, json};
use zerod::integrations::*;

/// A fetcher that answers each command from a list, and records what it was asked.
#[derive(Default)]
struct Canned { answers: Mutex<Vec<Result<String, String>>>, asked: Mutex<Vec<(Vec<String>, Option<String>)>> }

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

#[test]
fn each_integration_starts_off_with_its_usual_views() {
    let settings = Settings::default();
    assert!(!settings.github.enabled && !settings.linear.enabled);
    let github: Vec<(&str, &str)> = settings.github.views.iter().map(|v| (v.name.as_str(), v.query.as_str())).collect();
    assert_eq!(github, [("My pull requests", "is:pr is:open author:@me archived:false"), ("Review requests", "is:pr is:open review-requested:@me archived:false")]);
    let linear = &settings.linear.views[0];
    assert_eq!((linear.name.as_str(), linear.assignee, linear.states.clone()), ("My issues", Assignee::Me, vec!["backlog".to_string(), "unstarted".into(), "started".into()]));
}

#[tokio::test]
async fn views_are_added_changed_removed_and_kept() {
    let home = temp_dir("integrations-views");
    let integrations = Integrations::open(&home, canned(vec![]));
    integrations.set_enabled("github", true).unwrap();
    let added = integrations.save_view("github", json!({"name": "Acme PRs", "query": "is:pr is:open org:acme"})).unwrap();
    let id = added.github.views.last().unwrap().id.clone();
    assert!(!id.is_empty(), "a new view gets an id");
    integrations.save_view("github", json!({"id": id, "name": "Acme", "query": "is:pr org:acme"})).unwrap();
    integrations.delete_view("github", &added.github.views[0].id).unwrap();
    assert_eq!(integrations.save_view("gitlab", json!({})).unwrap_err(), "No integration gitlab");
    // Reordered by their ids; any not named keep their place after those that are.
    let reviews = added.github.views[1].id.clone();
    let order: Vec<String> = integrations.order_views("github", &[id.clone(), reviews.clone()]).unwrap().github.views.iter().map(|v| v.id.clone()).collect();
    assert_eq!(order, [id.clone(), reviews.clone()]);
    integrations.order_views("github", std::slice::from_ref(&reviews)).unwrap();
    let again = Integrations::open(&home, canned(vec![])).settings();
    assert!(again.github.enabled);
    let names: Vec<&str> = again.github.views.iter().map(|v| v.name.as_str()).collect();
    assert_eq!(names, ["Review requests", "Acme"], "kept in home/integrations.json, in their order");
}

#[test]
fn a_github_search_comes_back_as_rows() {
    let reply = json!({"data": {"search": {"nodes": [
        {"id": "PR_1", "number": 19001, "title": "Fix vitals", "url": "https://github.com/o/web/pull/19001", "isDraft": true, "updatedAt": "2026-10-28T12:36:17Z",
         "repository": {"nameWithOwner": "o/web"}, "author": {"login": "arsen"}, "reviewDecision": null,
         "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}},
        {"id": "PR_2", "number": 7, "title": "Docs", "url": "u", "isDraft": false, "updatedAt": "t", "repository": {"nameWithOwner": "o/docs"},
         "author": {"login": "sam"}, "reviewDecision": "CHANGES_REQUESTED", "commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]}},
        {},
    ]}}});
    let rows = github_items(&reply);
    assert_eq!(rows.len(), 2, "anything that isn't a pull request is left out");
    assert_eq!(rows[0], Item {
        id: "PR_1".into(), key: "#19001".into(), title: "Fix vitals".into(), url: "https://github.com/o/web/pull/19001".into(), place: "o/web".into(),
        state: "Draft".into(), color: None, checks: Some("success".into()), review: None, person: Some("arsen".into()), priority: None, updated: "2026-10-28T12:36:17Z".into(),
        ..Default::default()
    });
    assert_eq!((rows[1].state.as_str(), rows[1].checks.as_deref(), rows[1].review.as_deref()), ("Open", None, Some("changes requested")));
}

#[tokio::test]
async fn a_github_view_is_fetched_through_gh() {
    let fetcher = canned(vec![json!({"data": {"search": {"nodes": []}}})]);
    let integrations = Integrations::open(&temp_dir("integrations-gh"), fetcher.clone());
    let view = integrations.settings().github.views[0].id.clone();
    assert_eq!(integrations.items("github", &view).await.unwrap(), vec![]);
    let (argv, stdin) = fetcher.asked.lock().unwrap()[0].clone();
    assert_eq!(argv[4..7], ["gh", "api", "graphql"]);
    assert!(argv.contains(&"q=is:pr is:open author:@me archived:false".to_string()), "{argv:?}");
    assert_eq!(stdin, None);
    assert_eq!(integrations.items("github", "nope").await.unwrap_err(), "No view nope");
}

#[test]
fn a_linear_view_is_a_filter_on_who_which_teams_and_which_states() {
    let view = LinearView { id: "v".into(), name: "n".into(), assignee: Assignee::Me, teams: vec!["ENG".into(), "WEB".into()], states: vec!["started".into()], state_names: vec![], start: None };
    assert_eq!(linear_filter(&view), json!({"assignee": {"isMe": {"eq": true}}, "team": {"key": {"in": ["ENG", "WEB"]}}, "state": {"type": {"in": ["started"]}}}));
    let anyone = LinearView { assignee: Assignee::Anyone, teams: vec![], states: vec![], ..view.clone() };
    assert_eq!(linear_filter(&anyone), json!({}));
    assert_eq!(linear_filter(&LinearView { assignee: Assignee::Nobody, ..anyone.clone() }), json!({"assignee": {"null": true}}));
    // The team's own states, by name, over their types.
    let named = LinearView { states: vec!["started".into()], state_names: vec!["PM review".into(), "Plan".into()], ..anyone };
    assert_eq!(linear_filter(&named), json!({"state": {"name": {"in": ["PM review", "Plan"]}}}));
}

#[test]
fn linear_issues_come_back_grouped_by_state_as_linear_lists_them() {
    let issue = |id: &str, state: &str, kind: &str, position: f64| json!({"id": id, "identifier": format!("ENG-{id}"), "title": "t", "url": "u", "priority": 2,
        "updatedAt": "t", "createdAt": "c", "state": {"name": state, "type": kind, "color": "#f2c94c", "position": position}, "team": {"key": "ENG"},
        "assignee": {"name": "Arsen", "avatarUrl": "https://public.linear.app/a"}, "labels": {"nodes": [{"name": "Bug", "color": "#eb5757"}]},
        "project": {"name": "Status pages", "icon": ":trophy:", "color": "#bec2c8"}});
    let reply = json!({"data": {"issues": {"nodes": [
        issue("1", "Triage", "triage", 0.0), issue("2", "Plan", "unstarted", 1.0), issue("3", "Working on", "started", 2.0),
        issue("4", "PM review", "started", 5.0), issue("5", "Ideas", "backlog", 0.0), issue("6", "Working on", "started", 2.0),
    ]}}});
    let rows = linear_items(&reply);
    // In progress first, the furthest along at the top; then to do, the backlog, triage. Each state's issues keep their order.
    let order: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(order, ["4", "3", "6", "2", "5", "1"]);
    assert_eq!(rows[0], Item {
        id: "4".into(), key: "ENG-4".into(), title: "t".into(), url: "u".into(), place: "ENG".into(), state: "PM review".into(), color: Some("#f2c94c".into()),
        checks: None, review: None, person: Some("Arsen".into()), priority: Some(2), updated: "t".into(),
        // What Linear's list shows too: the state's kind for its icon, labels then the project, the assignee's picture, when it was made.
        kind: Some("started".into()), avatar: Some("https://public.linear.app/a".into()), created: Some("c".into()),
        tags: vec![Tag { name: "Bug".into(), color: Some("#eb5757".into()), icon: None }, Tag { name: "Status pages".into(), color: Some("#bec2c8".into()), icon: Some(":trophy:".into()) }],
        task: None,
    });
}

#[tokio::test]
async fn linear_teams_come_with_their_own_workflow_states() {
    let home = temp_dir("integrations-linear-teams");
    std::fs::write(home.join("linear.json"), r#"{"name":"Acme","url_key":"acme","access":"lin_tok","refresh":null,"expires":9999999999}"#).unwrap();
    let fetcher = canned(vec![json!({"data": {"teams": {"nodes": [{"key": "ENG", "name": "Engineering", "states": {"nodes": [
        {"name": "Triage", "type": "triage", "color": "#aaa", "position": 0.0},
        {"name": "Working on", "type": "started", "color": "#f2c94c", "position": 2.0},
        {"name": "PM review", "type": "started", "color": "#5e6ad2", "position": 5.0},
        {"name": "Plan", "type": "unstarted", "color": "#bbb", "position": 1.0},
    ]}}]}}})]);
    let integrations = Integrations::open(&home, fetcher);
    let teams = integrations.linear_teams().await.unwrap();
    assert_eq!(teams, json!([{"key": "ENG", "name": "Engineering", "states": [
        {"name": "PM review", "type": "started", "color": "#5e6ad2"},
        {"name": "Working on", "type": "started", "color": "#f2c94c"},
        {"name": "Plan", "type": "unstarted", "color": "#bbb"},
        {"name": "Triage", "type": "triage", "color": "#aaa"},
    ]}]), "in the order Linear lists them");
}

#[test]
fn the_linear_token_reaches_curl_on_its_stdin_never_its_command_line() {
    let config = curl_config("https://api.linear.app/graphql", Some("lin_tok"), "{\"query\":\"a \\\"b\\\"\"}", "application/json");
    assert_eq!(config, "url = \"https://api.linear.app/graphql\"\nheader = \"Authorization: Bearer lin_tok\"\nheader = \"Content-Type: application/json\"\ndata = \"{\\\"query\\\":\\\"a \\\\\\\"b\\\\\\\"\\\"}\"\n");
}

#[tokio::test]
async fn linear_is_connected_in_the_browser_and_its_issues_fetched_with_that_connection() {
    let home = temp_dir("integrations-linear");
    let fetcher = canned(vec![
        json!({"access_token": "lin_tok", "refresh_token": "ref", "expires_in": 86400}),
        json!({"data": {"viewer": {"organization": {"name": "Acme", "urlKey": "acme"}}}}),
        json!({"data": {"issues": {"nodes": []}}}),
    ]);
    let integrations = Integrations::open(&home, fetcher.clone());
    integrations.listen_on(47699);
    assert_eq!(integrations.items("linear", &integrations.settings().linear.views[0].id).await.unwrap_err(), "Linear isn't connected");
    let url = integrations.connect_linear().await.unwrap();
    assert!(url.starts_with("https://linear.app/oauth/authorize?") && url.contains("code_challenge_method=S256"), "{url}");
    let state = url.split("state=").nth(1).unwrap().split('&').next().unwrap().to_string();
    // The browser comes back to zerod's listener.
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", 47699)).await.unwrap();
    tokio::io::AsyncWriteExt::write_all(&mut stream, format!("GET /oauth/linear?code=c0de&state={state} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes()).await.unwrap();
    let mut page = String::new();
    tokio::io::AsyncReadExt::read_to_string(&mut stream, &mut page).await.unwrap();
    assert!(page.contains("200 OK") && page.contains("Linear is connected"), "{page}");
    for _ in 0..100 { if integrations.linear_workspace().is_some() { break } tokio::time::sleep(std::time::Duration::from_millis(10)).await }
    assert_eq!(integrations.linear_workspace().as_deref(), Some("Acme"));
    let exchange = fetcher.asked.lock().unwrap()[0].1.clone().unwrap();
    assert!(exchange.contains("code=c0de") && exchange.contains("code_verifier="), "{exchange}");
    integrations.items("linear", &integrations.settings().linear.views[0].id).await.unwrap();
    let (argv, stdin) = fetcher.asked.lock().unwrap()[2].clone();
    assert!(!argv.iter().any(|a| a.contains("lin_tok")) && stdin.unwrap().contains("Bearer lin_tok"));
    // Kept for the next start, readable by the user alone.
    let kept = home.join("linear.json");
    assert_eq!(std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&kept).unwrap().permissions()) & 0o777, 0o600);
    assert_eq!(Integrations::open(&home, canned(vec![])).linear_workspace().as_deref(), Some("Acme"));
}

#[tokio::test]
async fn githubs_account_is_whoever_gh_is_signed_in_as() {
    let fetcher = Arc::new(Canned { answers: Mutex::new(vec![Err("not logged into any GitHub hosts".into()), Ok("arsen\n".into())]), ..Default::default() });
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
        tokio::io::AsyncWriteExt::write_all(&mut stream, format!("GET /oauth/linear?code=c0de&state={state} HTTP/1.1\r\n\r\n").as_bytes()).await.unwrap();
        let mut page = String::new();
        tokio::io::AsyncReadExt::read_to_string(&mut stream, &mut page).await.unwrap();
        page
    };
    assert!(visit(first).await.contains("Linear didn't connect"), "the old sign-in no longer counts");
    assert!(visit(second).await.contains("Linear is connected"), "and the listener keeps waiting for the new one");
    assert_eq!(integrations.linear_workspace().as_deref(), Some("Acme"));
}

#[tokio::test]
async fn a_views_last_items_are_kept_to_show_while_it_fetches_again() {
    let home = temp_dir("integrations-cache");
    let reply = json!({"data": {"search": {"nodes": [{"id": "PR_1", "number": 1, "title": "t", "url": "u", "isDraft": false, "updatedAt": "t",
        "repository": {"nameWithOwner": "o/r"}, "author": {"login": "a"}, "reviewDecision": null, "commits": {"nodes": []}}]}}});
    let fetcher = Arc::new(Canned { answers: Mutex::new(vec![Ok(reply.to_string()), Err("gh: connection reset".into())]), ..Default::default() });
    let integrations = Integrations::open(&home, fetcher);
    let view = integrations.settings().github.views[0].id.clone();
    let key = format!("github/{view}");
    assert_eq!(integrations.cached(&key), None, "nothing until a fetch comes back");
    let items = integrations.items("github", &view).await.unwrap();
    assert!(integrations.items("github", &view).await.is_err());
    let again = Integrations::open(&home, canned(vec![]));
    assert_eq!(again.cached(&key), Some(json!(items)), "kept through a failed fetch, and across a restart");
    again.save_view("github", json!({"id": view, "name": "Mine", "query": "is:pr"})).unwrap();
    assert_eq!(again.cached(&key), None, "a changed view's old items no longer fit it");
}

#[tokio::test]
async fn a_command_that_hangs_is_given_up_on() {
    let started = std::time::Instant::now();
    let commands = Commands { timeout: std::time::Duration::from_millis(200) };
    assert_eq!(commands.run(vec!["/bin/sleep".into(), "5".into()], None).await.unwrap_err(), "/bin/sleep took too long");
    assert!(started.elapsed() < std::time::Duration::from_secs(2));
}

#[test]
fn a_view_starts_tasks_from_its_template_with_the_tasks_state_pad() {
    let item = Item { key: "ENG-9767".into(), title: "Webhooks".into(), url: "https://linear.app/x/issue/ENG-9767".into(), ..Default::default() };
    assert_eq!(task_prompt("Supervise {key} ({title}, {url}) as SUPERVISE.md says.", &item, "zero://pad/abc"),
               "Supervise ENG-9767 (Webhooks, https://linear.app/x/issue/ENG-9767) as SUPERVISE.md says.\n\n\
                Keep this task's state (what's done, the PR, an open question, the next step) in the scratchpad zero://pad/abc: \
                read it first, and keep it current, since it outlives restarts. Put other notes for ENG-9767 in the scratchpads folder Tasks/ENG-9767.");
    assert_eq!(task_prompt("{key}: state in {state}", &item, "zero://pad/abc"), "ENG-9767: state in zero://pad/abc", "a template naming {{state}} places it itself");
    let view: LinearView = serde_json::from_value(json!({"name": "n", "assignee": "me"})).unwrap();
    assert_eq!(view.start, None, "a view starts nothing until told how");
}

#[test]
fn an_item_with_a_task_says_which() {
    let item = |key: &str| Item { key: key.into(), ..Default::default() };
    let tagged = with_tasks(vec![item("ENG-1"), item("ENG-2")], &[("ENG-2".to_string(), "s9".to_string())]);
    assert_eq!((tagged[0].task.as_deref(), tagged[1].task.as_deref()), (None, Some("s9")));
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
    assert_eq!(integrations.connect_slack("xoxb-not-a-user-token").await.unwrap_err(), "That isn't a user token: Slack's start with xoxp-.");
    let state = integrations.connect_slack(" xoxp-123 ").await.unwrap();
    assert_eq!(state, json!([{"team": {"id": "T0AB", "name": "Acme", "domain": "acme"}, "channels": {"docs": "C0D", "eng": "C0E"}}]), "one of the workspaces connected");
    let asked = fetcher.asked.lock().unwrap().clone();
    assert_eq!(asked[0].0[0], "curl");
    assert_eq!(asked[0].1.as_deref(), Some("url = \"https://slack.com/api/auth.test\"\nheader = \"Authorization: Bearer xoxp-123\"\n"), "the token on curl's stdin, never its command line");
    assert!(asked[2].1.as_deref().unwrap().contains("cursor=more"));
    // Kept, the user's alone; gone when disconnected.
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(home.join("slack.json")).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(Integrations::open(&home, canned(vec![])).slack_state(), state);
    integrations.disconnect_slack("T0AB").unwrap();
    assert!(integrations.slack_state() == json!([]) && !home.join("slack.json").exists());
}
