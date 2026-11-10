//! Signing a Codex account in through Codex's own app-server, in that account's home: Codex shows its ChatGPT sign-in
//! page and keeps what it's given; Zero only asks it to start, passes the link on, and reads back who signed in.

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use zerod::codex_login::{Method, account, rate_limits, sign_in};

/// A stand-in app-server: answers each request as Codex's schema has it; `finish` is how the browser part ends.
fn codex(finish: Option<Value>) -> (tokio::io::DuplexStream, tokio::task::JoinHandle<Vec<Value>>) {
    let (zero, server) = tokio::io::duplex(1 << 16);
    let task = tokio::spawn(async move {
        let (read, mut write) = tokio::io::split(server);
        let mut lines = BufReader::new(read).lines();
        let mut heard = vec![];
        while let Ok(Some(line)) = lines.next_line().await {
            let message: Value = serde_json::from_str(&line).unwrap();
            heard.push(message.clone());
            let reply = match message["method"].as_str() {
                Some("initialize") => Some(json!({"id": message["id"], "result": {"userAgent": "codex"}})),
                Some("account/login/start") if message["params"]["type"] == "chatgpt" => Some(
                    json!({"id": message["id"], "result": {"type": "chatgpt", "loginId": "l1", "authUrl": "https://auth.openai.com/authorize?x=1"}}),
                ),
                Some("account/login/start") => Some(json!({"id": message["id"], "result": {"type": "apiKey"}})),
                Some("account/read") => Some(
                    json!({"id": message["id"], "result": {"account": {"type": "chatgpt", "email": "c@example.com", "planType": "pro"}}}),
                ),
                Some("account/rateLimits/read") => Some(json!({"id": message["id"], "result": {"rateLimits": {
                    "primary": {"usedPercent": 12.0, "windowDurationMins": 300, "resetsAt": 1793970000},
                    "secondary": {"usedPercent": 64.0, "windowDurationMins": 10080, "resetsAt": 1794400000}}}})),
                _ => None,
            };
            if let Some(reply) = reply {
                write.write_all(format!("{reply}\n").as_bytes()).await.unwrap()
            }
            if message["method"] == "account/login/start"
                && let Some(finish) = &finish
            {
                write.write_all(format!("{finish}\n").as_bytes()).await.unwrap();
            }
            if message["method"] == "account/read" || message["method"] == "account/rateLimits/read" {
                break;
            }
        }
        heard
    });
    (zero, task)
}

#[tokio::test]
async fn a_chatgpt_sign_in_gives_its_page_then_who_signed_in() {
    let (zero, server) = codex(Some(json!({"method": "account/login/completed", "params": {"loginId": "l1", "success": true}})));
    let (read, write) = tokio::io::split(zero);
    let (link, page) = tokio::sync::oneshot::channel();
    let account = sign_in(read, write, Method::ChatGpt, link).await.unwrap();
    assert_eq!(page.await.unwrap().as_deref(), Some("https://auth.openai.com/authorize?x=1"), "Codex's own page, for the user to open");
    assert_eq!((account.email.as_deref(), account.plan.as_deref()), (Some("c@example.com"), Some("pro")));
    let heard = server.await.unwrap();
    assert_eq!(
        heard.iter().filter_map(|m| m["method"].as_str()).collect::<Vec<_>>(),
        ["initialize", "initialized", "account/login/start", "account/read"]
    );
}

#[tokio::test]
async fn a_sign_in_turned_down_says_why() {
    let (zero, _server) = codex(Some(
        json!({"method": "account/login/completed", "params": {"loginId": "l1", "success": false, "error": "Login was cancelled"}}),
    ));
    let (read, write) = tokio::io::split(zero);
    let (link, _page) = tokio::sync::oneshot::channel();
    assert_eq!(sign_in(read, write, Method::ChatGpt, link).await.unwrap_err(), "Codex didn't sign in: Login was cancelled");
}

#[tokio::test]
async fn an_api_key_is_given_to_codex_to_keep() {
    let (zero, server) = codex(None);
    let (read, write) = tokio::io::split(zero);
    let (link, page) = tokio::sync::oneshot::channel();
    sign_in(read, write, Method::ApiKey("sk-test".into()), link).await.unwrap();
    assert_eq!(page.await.unwrap(), None, "no page to open");
    let heard = server.await.unwrap();
    assert_eq!(heard[2]["params"], json!({"type": "apiKey", "apiKey": "sk-test"}));
}

#[tokio::test]
async fn whose_home_it_is_is_read_back_without_signing_in() {
    let (zero, server) = codex(None);
    let (read, write) = tokio::io::split(zero);
    let account = account(read, write).await.unwrap();
    assert_eq!((account.email.as_deref(), account.plan.as_deref()), (Some("c@example.com"), Some("pro")));
    let heard = server.await.unwrap();
    assert_eq!(heard.iter().filter_map(|m| m["method"].as_str()).collect::<Vec<_>>(), ["initialize", "initialized", "account/read"]);
}

#[tokio::test]
async fn an_accounts_usage_is_read_without_a_task() {
    let (zero, server) = codex(None);
    let (read, write) = tokio::io::split(zero);
    let usage = rate_limits(read, write).await.unwrap();
    let windows: Vec<_> = usage.windows.iter().map(|w| (w.name.as_str(), w.used, w.resets_at)).collect();
    assert_eq!(windows, [("5 hours", 0.12, Some(1793970000)), ("7 days", 0.64, Some(1794400000))]);
    assert!(!usage.limited);
    let heard = server.await.unwrap();
    assert_eq!(
        heard.iter().filter_map(|m| m["method"].as_str()).collect::<Vec<_>>(),
        ["initialize", "initialized", "account/rateLimits/read"]
    );
}
