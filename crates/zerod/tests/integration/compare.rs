//! Comparing browsers: one step (open a page, size it, act on it) in Chrome, Firefox and Safari at once, each ending
//! with how the page looks there. Safari is its automation windows, through safaridriver.

use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use zerod::safari::{Safari, Step};

/// A stand-in safaridriver: answers WebDriver's requests as Safari does, and keeps what it was asked.
async fn fake_safaridriver() -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap().to_string();
    let heard = Arc::new(Mutex::new(vec![]));
    let log = heard.clone();
    tokio::spawn(async move {
        let mut windows = 0;
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = vec![0u8; 1 << 16];
            let n = stream.read(&mut request).await.unwrap();
            let request = String::from_utf8_lossy(&request[..n]).to_string();
            let line = request.lines().next().unwrap_or("").to_string();
            let (method, path) = { let mut p = line.split(' '); (p.next().unwrap_or("").to_string(), p.next().unwrap_or("").to_string()) };
            log.lock().unwrap().push(format!("{method} {}", path.replace("/session/s1", "")));
            let value = match (method.as_str(), path.as_str()) {
                ("POST", "/session") => json!({"sessionId": "s1", "capabilities": {}}),
                ("GET", "/session/s1/window") => json!("w0"),
                ("POST", "/session/s1/window/new") => { windows += 1; json!({"handle": format!("w{windows}"), "type": "window"}) }
                ("POST", "/session/s1/element") if request.contains("#missing") => json!({"error": "no such element", "message": ""}),
                ("POST", "/session/s1/element") => json!({"element-6066-11e4-a52e-4f735466cecf": "e1"}),
                ("POST", "/session/s1/execute/sync") if request.contains("outerWidth") => json!([0, 80]),
                ("POST", "/session/s1/execute/sync") => json!({"title": "Shop"}),
                ("GET", "/session/s1/screenshot") => json!("iVBORw0KGgo="),
                _ => Value::Null,
            };
            let body = json!({"value": value}).to_string();
            let _ = stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).as_bytes()).await;
        }
    });
    (address, heard)
}

#[test]
fn a_step_says_what_it_needs() {
    assert_eq!(Step::from(&json!({})).unwrap().action, "screenshot");
    assert!(Step::from(&json!({"action": "click"})).unwrap_err().contains("selector"));
    assert!(Step::from(&json!({"action": "type"})).unwrap_err().contains("text"));
    assert!(Step::from(&json!({"action": "dance"})).is_err());
}

#[tokio::test]
async fn safari_opens_sizes_clicks_and_looks_in_the_tasks_own_window() {
    let (address, heard) = fake_safaridriver().await;
    let safari = Safari::at(&address, None);
    let step = Step::from(&json!({"url": "https://shop.test", "width": 390, "height": 844, "action": "click", "selector": "#buy"})).unwrap();
    let said = safari.step("task-a", &step).await.unwrap();
    assert_eq!(said.last().unwrap()["type"], "image", "it ends with how the page looks");
    assert_eq!(*heard.lock().unwrap(), ["POST /session", "GET /window", "POST /window", "POST /url", "POST /execute/sync", "POST /window/rect",
                                        "POST /element", "POST /element/e1/click", "GET /screenshot"]);
    // Another task: a window of its own. A selector with no match says so.
    heard.lock().unwrap().clear();
    let missing = safari.step("task-b", &Step::from(&json!({"action": "click", "selector": "#missing"})).unwrap()).await.unwrap_err();
    assert!(missing.contains("#missing"));
    assert_eq!(heard.lock().unwrap()[0], "POST /window/new");
    let ran = safari.step("task-a", &Step::from(&json!({"action": "js", "text": "({title: document.title})"})).unwrap()).await.unwrap();
    assert!(ran[0]["text"].as_str().unwrap().contains("Shop"));
}

#[tokio::test]
async fn a_comparison_shows_each_browser_and_says_why_one_couldnt() {
    let (address, _) = fake_safaridriver().await;
    let browsers = zerod::browser::Browsers::open(&crate::common::temp_dir("compare"));
    browsers.set_safari(Safari::at(&address, None));
    // Chrome's extension, answering as the real one does: its tabs, then each tool.
    let (chrome, mut calls) = tokio::sync::mpsc::unbounded_channel::<Value>();
    browsers.attach(&json!({"id": "chrome-1", "name": "Chrome"}), chrome);
    let answering = browsers.clone();
    let tools = Arc::new(Mutex::new(vec![]));
    let heard = tools.clone();
    tokio::spawn(async move {
        while let Some(call) = calls.recv().await {
            if call["event"] != "browserCall" { continue }
            heard.lock().unwrap().push(format!("{} {}", call["tool"].as_str().unwrap(), call["args"]["tabId"]));
            let result = match call["tool"].as_str().unwrap() {
                "browser_tabs" => json!({"content": [{"type": "text", "text": "[{\"tabId\": 5}]"}]}),
                "browser_computer" if call["args"]["action"] == "screenshot" => json!({"content": [{"type": "image", "data": "abc", "mimeType": "image/jpeg"}]}),
                _ => json!({"content": [{"type": "text", "text": "ok"}]}),
            };
            answering.answer(&json!({"call": call["call"], "result": result}));
        }
    });
    let answer = browsers.call(Some("s1"), json!({}), "browser_compare", json!({"url": "https://shop.test", "action": "click", "selector": "#buy"})).await.unwrap();
    let texts: Vec<String> = answer["content"].as_array().unwrap().iter().filter_map(|c| c["text"].as_str().map(String::from)).collect();
    assert_eq!(texts.iter().filter(|t| t.starts_with("## ")).collect::<Vec<_>>(), ["## Chrome", "## Firefox", "## Safari"]);
    assert!(texts.iter().any(|t| t.contains("Firefox isn't set up")), "{texts:?}");
    assert_eq!(answer["content"].as_array().unwrap().iter().filter(|c| c["type"] == "image").count(), 2, "Chrome's and Safari's");
    assert_eq!(*tools.lock().unwrap(), ["browser_tabs null", "browser_navigate 5", "browser_computer 5", "browser_computer 5"]);
}

#[tokio::test]
async fn after_a_restart_zerod_takes_up_the_session_safari_still_has() {
    let (address, heard) = fake_safaridriver().await;
    let kept = crate::common::temp_dir("safari-session").join("safari-session");
    Safari::at(&address, Some(kept.clone())).step("t", &Step::default()).await.unwrap();
    assert_eq!(std::fs::read_to_string(&kept).unwrap(), "s1");
    heard.lock().unwrap().clear();
    // Safari pairs with one session at a time: zerod, started again, uses the one it had.
    Safari::at(&address, Some(kept)).step("t", &Step::default()).await.unwrap();
    assert!(!heard.lock().unwrap().contains(&"POST /session".to_string()), "{:?}", heard.lock().unwrap());
}
