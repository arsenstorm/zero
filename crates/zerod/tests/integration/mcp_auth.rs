//! Signing in to a remote MCP server a task's CLI says needs it (its own OAuth, whether the server is the CLI's or
//! Zero's): Zero has the CLI sign in once per server, in a short-lived CLI of its own that hears the callback, puts the
//! link to the user in the inbox, and takes the ask back once the server connects.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use zerod::ask::{AskKind, AskState};
use zerod::mcp_auth::{Job, McpAuth, News, Runner};
use zerod::model::{Conversation, Provider};

fn sh(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

/// A stand-in `claude -p`: answers mcp_authenticate with `answer`, then mcp_status with the server needing sign-in
/// until it has been asked `polls` times, connected after.
fn claude(answer: &str, polls: u32) -> Vec<String> {
    sh(&format!(
        r#"read request
case "$request" in *betterstack*mcp_authenticate*) echo '{answer}';; esac
n=0
while read request; do
  n=$((n+1)); id=$(echo "$request" | sed 's/.*"request_id":"\([^"]*\)".*/\1/')
  if [ $n -lt {polls} ]; then s=needs-auth; else s=connected; fi
  echo "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{{\"mcpServers\":[{{\"name\":\"betterstack\",\"status\":\"$s\"}}]}}}}}}"
done"#
    ))
}

#[tokio::test]
async fn claude_signs_in_in_a_claude_of_zeros_own_until_the_server_connects() {
    let link = r#"{"type":"control_response","response":{"subtype":"success","request_id":"auth","response":{"authUrl":"https://bs.example/authorize?x=1","requiresUserAction":true,"callbackExpected":true}}}"#;
    let (page, opened) = tokio::sync::oneshot::channel();
    zerod::claude_login::mcp_sign_in(&claude(link, 3), &[], "/tmp", "betterstack", page, Duration::from_millis(20)).await.unwrap();
    assert_eq!(opened.await.unwrap(), "https://bs.example/authorize?x=1", "Claude's own link, for the user to open");
}

#[tokio::test]
async fn claude_saying_no_is_said() {
    let refused =
        r#"{"type":"control_response","response":{"subtype":"error","request_id":"auth","error":"Server not found: betterstack"}}"#;
    let (page, _opened) = tokio::sync::oneshot::channel();
    let error = zerod::claude_login::mcp_sign_in(&claude(refused, 1), &[], "/tmp", "betterstack", page, Duration::from_millis(20)).await;
    assert_eq!(error.unwrap_err(), "Server not found: betterstack");
}

#[tokio::test]
async fn codex_signs_in_through_its_app_server() {
    let (zero, server) = tokio::io::duplex(1 << 16);
    let heard = tokio::spawn(async move {
        let (read, mut write) = tokio::io::split(server);
        let mut lines = BufReader::new(read).lines();
        let mut heard = vec![];
        while let Ok(Some(line)) = lines.next_line().await {
            let message: Value = serde_json::from_str(&line).unwrap();
            heard.push(message.clone());
            let replies = match message["method"].as_str() {
                Some("initialize") => vec![json!({"id": message["id"], "result": {"userAgent": "codex"}})],
                Some("mcpServer/oauth/login") => vec![
                    json!({"id": message["id"], "result": {"authorizationUrl": "https://bs.example/authorize?x=1"}}),
                    json!({"method": "mcpServer/oauthLogin/completed", "params": {"name": "other", "success": false}}),
                    json!({"method": "mcpServer/oauthLogin/completed", "params": {"name": "betterstack", "success": true}}),
                ],
                _ => vec![],
            };
            for reply in replies {
                write.write_all(format!("{reply}\n").as_bytes()).await.unwrap()
            }
        }
        heard
    });
    let (read, write) = tokio::io::split(zero);
    let (page, opened) = tokio::sync::oneshot::channel();
    zerod::codex_login::mcp_sign_in(read, write, "betterstack", page).await.unwrap();
    assert_eq!(opened.await.unwrap(), "https://bs.example/authorize?x=1");
    let heard = heard.await.unwrap();
    assert_eq!(heard.iter().find(|m| m["method"] == "mcpServer/oauth/login").unwrap()["params"]["name"], "betterstack");
}

fn job(conversation: &Conversation, server: &str) -> Job {
    Job { server: server.into(), provider: conversation.provider, cwd: conversation.cwd.clone(), env: vec![], mcp: vec![] }
}

/// How the test ends each sign-in it ran, in order.
type Ends = Arc<Mutex<Vec<tokio::sync::oneshot::Sender<Result<(), String>>>>>;

/// A runner that gives each sign-in's link at once and ends when the test says, and what it was asked to run.
fn runner() -> (Runner, Arc<Mutex<Vec<String>>>, Ends) {
    let (runs, ends) = (Arc::new(Mutex::new(vec![])), Arc::new(Mutex::new(vec![])));
    let (ran, ending) = (runs.clone(), ends.clone());
    let run: Runner = Arc::new(move |job: Job, page: tokio::sync::oneshot::Sender<String>| {
        ran.lock().unwrap().push(job.server.clone());
        let _ = page.send(format!("https://{}.example/authorize", job.server));
        let (end, ended) = tokio::sync::oneshot::channel();
        ending.lock().unwrap().push(end);
        Box::pin(async move { ended.await.unwrap_or(Err("gone".into())) })
    });
    (run, runs, ends)
}

async fn until(what: impl Fn() -> bool) {
    for _ in 0..200 {
        if what() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("never happened")
}

#[tokio::test]
async fn each_server_is_signed_in_once_however_many_tasks_want_it() {
    let (run, runs, ends) = runner();
    let inbox = zerod::inbox::Inbox::open(None, vec![]);
    let told = Arc::new(Mutex::new(vec![]));
    let heard = told.clone();
    let auth = McpAuth::new(run);
    auth.attach(
        inbox.clone(),
        Box::new(move |session: &str, server: &str, news: News| {
            heard.lock().unwrap().push(format!("{session} {server} {news:?}"));
        }),
    );
    let (a, b) = (Conversation::new("a", Provider::Claude, "/work/a"), Conversation::new("b", Provider::Claude, "/work/b"));
    auth.wanted(&a, job(&a, "betterstack"));
    until(|| inbox.open_asks().len() == 1).await;
    auth.wanted(&b, job(&b, "betterstack"));
    until(|| told.lock().unwrap().len() == 2).await;
    assert_eq!(*runs.lock().unwrap(), ["betterstack"], "one sign-in, not one per task");
    let asks = inbox.open_asks();
    assert_eq!(asks.len(), 1, "one ask for the server, whichever tasks want it");
    let ask = &asks[0];
    assert_eq!((ask.kind, ask.title.as_str()), (AskKind::Approve, "Sign in to betterstack?"));
    assert_eq!(ask.link.as_deref(), Some("https://betterstack.example/authorize"), "its first option opens it");
    assert_eq!(ask.options, ["Open the sign-in page", "Not now"]);
    assert_eq!(ask.agent.reference.as_deref(), Some("a"), "the task that wanted it first");
    assert_eq!(ask.waits, None, "nothing is typed into the task when it's answered");
    assert_eq!(
        *told.lock().unwrap(),
        ["a betterstack Link(\"https://betterstack.example/authorize\")", "b betterstack Link(\"https://betterstack.example/authorize\")"],
        "each task that wants it shows the link"
    );
    ends.lock().unwrap().remove(0).send(Ok(())).unwrap();
    until(|| inbox.ask(&ask.id).is_some_and(|a| a.state == AskState::Expired)).await;
    let ask = inbox.ask(&ask.id).unwrap();
    assert_eq!((ask.status.as_deref(), ask.answer.as_deref()), (Some("withdrawn"), Some("Signed in")), "taken back once connected");
    until(|| told.lock().unwrap().len() == 4).await;
    assert_eq!(told.lock().unwrap()[2..], ["a betterstack SignedIn", "b betterstack SignedIn"], "each reconnects it");
    let c = Conversation::new("c", Provider::Claude, "/work/c");
    auth.wanted(&c, job(&c, "betterstack"));
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(runs.lock().unwrap().len(), 1, "not again once signed in");
    // Settings' Sign in starts one whenever the user asks, without an ask: they're there.
    let url = auth.sign_in(job(&c, "betterstack")).await.unwrap();
    assert_eq!(url, "https://betterstack.example/authorize");
    assert_eq!(runs.lock().unwrap().len(), 2);
    assert_eq!(inbox.open_asks().len(), 0);
    // While one is under way, another Sign in gives its link rather than a second sign-in.
    assert_eq!(auth.sign_in(job(&c, "betterstack")).await.unwrap(), url);
    assert_eq!(runs.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn a_sign_in_that_fails_takes_its_ask_back_and_isnt_tried_again_unasked() {
    let (run, runs, ends) = runner();
    let inbox = zerod::inbox::Inbox::open(None, vec![]);
    let told = Arc::new(Mutex::new(vec![]));
    let heard = told.clone();
    let auth = McpAuth::new(run);
    auth.attach(inbox.clone(), Box::new(move |_: &str, _: &str, news: News| heard.lock().unwrap().push(format!("{news:?}"))));
    let a = Conversation::new("a", Provider::Codex, "/work/a");
    auth.wanted(&a, job(&a, "linear"));
    until(|| inbox.open_asks().len() == 1).await;
    let id = inbox.open_asks()[0].id.clone();
    ends.lock().unwrap().remove(0).send(Err("the sign-in wasn't finished".into())).unwrap();
    until(|| inbox.ask(&id).is_some_and(|a| a.state == AskState::Expired)).await;
    assert_eq!(inbox.ask(&id).unwrap().answer.as_deref(), Some("Couldn't sign in: the sign-in wasn't finished"));
    until(|| told.lock().unwrap().len() == 2).await;
    assert_eq!(told.lock().unwrap()[1], "Failed(\"the sign-in wasn't finished\")");
    auth.wanted(&a, job(&a, "linear"));
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(runs.lock().unwrap().len(), 1, "once per Zero session: Settings' Sign in tries again");
}
