//! Firefox through its remote control (WebDriver BiDi): Zero's browser tools are the extension's, and the Chrome
//! debugger commands they send are done in Firefox, its events coming back shaped as Chrome's.

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use zerod::firefox::{Answer, Firefox, answer, event, plan, remote};
use zerod::websocket::{read_frame, server_frame};

#[test]
fn a_click_with_shift_holds_shift_around_the_press() {
    let press =
        plan("Input.dispatchMouseEvent", &json!({"type": "mousePressed", "x": 10.4, "y": 20.6, "button": "left", "modifiers": 8}), "c1")
            .unwrap();
    assert_eq!(press.commands[0].0, "input.performActions");
    let sources = &press.commands[0].1["actions"];
    assert_eq!(
        sources[0]["actions"],
        json!([{"type": "pause"}, {"type": "pointerMove", "x": 10.0, "y": 21.0, "origin": "viewport"}, {"type": "pointerDown", "button": 0}])
    );
    assert_eq!(
        sources[1]["actions"],
        json!([{"type": "keyDown", "value": "\u{E008}"}, {"type": "pause"}, {"type": "pause"}]),
        "Shift down before the press"
    );
    let release =
        plan("Input.dispatchMouseEvent", &json!({"type": "mouseReleased", "x": 10, "y": 21, "button": "right", "modifiers": 8}), "c1")
            .unwrap();
    let sources = &release.commands[0].1["actions"];
    assert_eq!(sources[0]["actions"][1], json!({"type": "pointerUp", "button": 2}));
    assert_eq!(sources[1]["actions"][2], json!({"type": "keyUp", "value": "\u{E008}"}), "and up after the release");
}

#[test]
fn keys_are_their_characters_or_webdrivers_codes() {
    let enter = plan("Input.dispatchKeyEvent", &json!({"type": "rawKeyDown", "key": "Enter"}), "c1").unwrap();
    assert_eq!(enter.commands[0].1["actions"][0]["actions"], json!([{"type": "keyDown", "value": "\u{E007}"}]));
    let a = plan("Input.dispatchKeyEvent", &json!({"type": "keyDown", "key": "a", "text": "a", "modifiers": 2}), "c1").unwrap();
    assert_eq!(
        a.commands[0].1["actions"][0]["actions"],
        json!([{"type": "keyDown", "value": "\u{E009}"}, {"type": "keyDown", "value": "a"}])
    );
    assert!(
        plan("Input.dispatchKeyEvent", &json!({"type": "char", "text": "a"}), "c1").unwrap().commands.is_empty(),
        "a keyDown typed it already"
    );
    let typed = plan("Input.insertText", &json!({"text": "hé"}), "c1").unwrap();
    assert_eq!(typed.commands[0].1["actions"][0]["actions"].as_array().unwrap().len(), 4);
}

#[test]
fn screenshots_scripts_and_dialogs_are_firefoxs_own() {
    let shot = plan("Page.captureScreenshot", &json!({"format": "jpeg", "quality": 85, "captureBeyondViewport": true, "clip": {"x": 0, "y": 0, "width": 800, "height": 4000, "scale": 1}}), "c1").unwrap();
    assert_eq!(
        shot.commands[0],
        (
            "browsingContext.captureScreenshot".into(),
            json!({"context": "c1", "origin": "document",
        "format": {"type": "image/jpeg", "quality": 0.85}, "clip": {"type": "box", "x": 0, "y": 0, "width": 800, "height": 4000}})
        )
    );
    assert_eq!(answer(&Answer::Screenshot, &json!({"data": "abc"})).unwrap(), json!({"data": "abc"}));
    let dialog = plan("Page.handleJavaScriptDialog", &json!({"accept": true, "promptText": "yes"}), "c1").unwrap();
    assert_eq!(dialog.commands[0].1, json!({"context": "c1", "accept": true, "userText": "yes"}));
    assert!(plan("Page.enable", &json!({}), "c1").unwrap().commands.is_empty());
    assert!(plan("Page.startScreencast", &json!({}), "c1").unwrap_err().contains("Chrome"));
    let evaluated = answer(
        &Answer::Evaluated,
        &json!({"type": "success", "result": {"type": "object", "value": [["a", {"type": "number", "value": 1}],
        ["b", {"type": "array", "value": [{"type": "string", "value": "x"}, {"type": "null"}]}]]}}),
    )
    .unwrap();
    assert_eq!(evaluated, json!({"result": {"type": "object", "value": {"a": 1, "b": ["x", null]}}}));
    let thrown =
        answer(&Answer::Evaluated, &json!({"type": "exception", "exceptionDetails": {"text": "ReferenceError: x is not defined"}}))
            .unwrap();
    assert_eq!(thrown["exceptionDetails"]["exception"]["description"], "ReferenceError: x is not defined");
    assert_eq!(remote(&json!({"type": "undefined"})), None);
    assert_eq!(remote(&json!({"type": "node", "sharedId": "n1"})), Some(json!("node")));
}

#[test]
fn firefoxs_events_read_as_chromes() {
    let (context, method, params) = event(
        "log.entryAdded",
        &json!({"type": "console", "method": "warn", "level": "warn", "text": "careful", "source": {"context": "c1"}, "timestamp": 5}),
    )
    .unwrap();
    assert_eq!((context.as_str(), method), ("c1", "Runtime.consoleAPICalled"));
    assert_eq!(params["args"][0]["value"], "careful");
    assert_eq!(params["type"], "warn");
    let (_, method, params) =
        event("network.responseCompleted", &json!({"context": "c1", "request": {"request": "r7"}, "response": {"status": 404}})).unwrap();
    assert_eq!((method, &params), ("Network.responseReceived", &json!({"requestId": "r7", "response": {"status": 404}})));
    let (_, method, _) =
        event("browsingContext.userPromptOpened", &json!({"context": "c1", "type": "confirm", "message": "Sure?"})).unwrap();
    assert_eq!(method, "Page.javascriptDialogOpening");
    assert!(event("script.realmCreated", &json!({"context": "c1"})).is_none());
}

/// A stand-in for Firefox's remote control on a port of its own: answers as Firefox does, with one tab ("ctx-1")
/// that has the extension's mark on it, and a console line in it after the first click. What it heard is sent back.
pub async fn fake_firefox() -> (String, tokio::sync::mpsc::UnboundedReceiver<Value>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap().to_string();
    let (heard, hearing) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(async move {
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            let heard = heard.clone();
            tokio::spawn(async move {
                let mut request = vec![];
                while !request.ends_with(b"\r\n\r\n") {
                    let mut byte = [0u8; 1];
                    stream.read_exact(&mut byte).await.unwrap();
                    request.push(byte[0])
                }
                let path = String::from_utf8_lossy(&request).split(' ').nth(1).unwrap_or("").to_string();
                let _ = heard.send(json!({"path": path}));
                stream
                    .write_all(
                        b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n",
                    )
                    .await
                    .unwrap();
                let (mut read, mut write) = stream.into_split();
                while let Some((_, opcode, data)) = read_frame(&mut read).await {
                    if opcode != 1 {
                        continue;
                    }
                    let message: Value = serde_json::from_slice(&data).unwrap();
                    let result = match message["method"].as_str().unwrap() {
                        "session.new" => json!({"sessionId": "sess-1", "capabilities": {}}),
                        "browsingContext.getTree" => json!({"contexts": [{"context": "ctx-0"}, {"context": "ctx-1"}]}),
                        "script.evaluate" if message["params"]["expression"].as_str().unwrap().contains("data-zero-tab") => {
                            json!({"type": "success", "result": {"type": "boolean", "value": message["params"]["target"]["context"] == "ctx-1"}})
                        }
                        "script.evaluate" => json!({"type": "success", "result": {"type": "number", "value": 2}}),
                        _ => json!({}),
                    };
                    let _ = heard.send(message.clone());
                    let reply = json!({"type": "success", "id": message["id"], "result": result}).to_string();
                    write.write_all(&server_frame(1, reply.as_bytes())).await.unwrap();
                    if message["method"] == "input.performActions" {
                        let event = json!({"type": "event", "method": "log.entryAdded", "params": {"type": "console", "level": "info", "method": "log", "text": "clicked", "source": {"context": "ctx-1"}}});
                        write.write_all(&server_frame(1, event.to_string().as_bytes())).await.unwrap();
                    }
                }
            });
        }
    });
    (address, hearing)
}

#[tokio::test]
async fn the_extensions_tab_is_found_by_its_mark_and_commands_go_to_it() {
    let (address, mut heard) = fake_firefox().await;
    let firefox = Firefox::new(&address, "/Applications/Zero.app/Contents/Resources/chrome".into(), None, None);
    let (events, mut told) = tokio::sync::mpsc::unbounded_channel();
    firefox.set_extension(Some(events));
    let density = firefox
        .command(7, Some("n-123"), "Runtime.evaluate", &json!({"expression": "devicePixelRatio", "returnByValue": true}))
        .await
        .unwrap();
    assert_eq!(density, json!({"result": {"type": "number", "value": 2}}));
    let mut methods = vec![];
    while let Ok(message) = heard.try_recv() {
        if message.get("path").is_some() {
            continue;
        }
        methods.push(message["method"].as_str().unwrap().to_string());
        if message["method"] == "webExtension.install" {
            assert_eq!(
                message["params"]["extensionData"],
                json!({"type": "path", "path": "/Applications/Zero.app/Contents/Resources/chrome"})
            );
        }
    }
    assert_eq!(
        &methods[..4],
        ["session.new", "session.subscribe", "webExtension.install", "browsingContext.getTree"],
        "the session, then the extension, then the tab"
    );
    // Known now: no mark needed, and its events reach the extension under its tab.
    firefox.command(7, None, "Input.dispatchMouseEvent", &json!({"type": "mousePressed", "x": 1, "y": 2, "button": "left"})).await.unwrap();
    let event = tokio::time::timeout(std::time::Duration::from_secs(5), told.recv()).await.unwrap().unwrap();
    assert_eq!(
        event,
        json!({"event": "browserEvent", "tab": 7, "method": "Runtime.consoleAPICalled", "params": {"type": "log", "args": [{"value": "clicked"}], "timestamp": null}})
    );
    assert!(
        firefox.command(8, None, "Page.enable", &json!({})).await.unwrap_err().contains("mark"),
        "a tab it doesn't know needs its mark"
    );
}

#[tokio::test]
async fn a_firefox_not_taking_remote_control_says_how_to_fix_it() {
    let firefox = Firefox::new("127.0.0.1:1", "/tmp".into(), None, None);
    let refused = firefox.command(1, Some("n"), "Page.enable", &json!({})).await.unwrap_err();
    assert!(refused.contains("quit it"), "{refused}");
}

#[tokio::test]
async fn choosing_firefox_opens_it_and_waits_for_its_extension() {
    let (address, _heard) = fake_firefox().await;
    let browsers = zerod::browser::Browsers::open(&crate::common::temp_dir("firefox-select"));
    browsers.set_firefox(Firefox::new(&address, "/tmp/firefox".into(), None, None));
    let (chrome, _chrome_hears) = tokio::sync::mpsc::unbounded_channel();
    browsers.attach(&json!({"id": "chrome-1", "name": "Chrome"}), chrome);
    // Firefox's extension connects once the remote control has installed it.
    let (extension, mut extension_hears) = tokio::sync::mpsc::unbounded_channel();
    let later = browsers.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        later.attach(&json!({"id": "firefox-1", "name": "Firefox"}), extension);
    });
    let chosen = browsers.call(Some("s1"), json!({}), "browser_select", json!({"browser": "firefox"})).await.unwrap();
    assert!(chosen["content"][0]["text"].as_str().unwrap().contains("firefox-1"));
    assert_eq!(browsers.list(Some("s1"))[1]["used"], true);
    // Firefox's events reach that extension.
    browsers
        .firefox()
        .unwrap()
        .command(3, Some("n"), "Input.dispatchMouseEvent", &json!({"type": "mouseMoved", "x": 1, "y": 1}))
        .await
        .unwrap();
    let event = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let message = extension_hears.recv().await.unwrap();
            if message["event"] == "browserEvent" {
                return message;
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(event["tab"], 3);
}

#[tokio::test]
async fn after_a_restart_zerod_takes_up_the_session_firefox_still_has() {
    let (address, mut heard) = fake_firefox().await;
    let kept = crate::common::temp_dir("firefox-session").join("firefox-session");
    Firefox::new(&address, "/tmp/firefox".into(), None, Some(kept.clone())).ensure().await.unwrap();
    assert_eq!(std::fs::read_to_string(&kept).unwrap(), "sess-1");
    while heard.try_recv().is_ok() {}
    // zerod again: Firefox keeps its one session, so zerod connects to it rather than asking for another.
    Firefox::new(&address, "/tmp/firefox".into(), None, Some(kept.clone())).ensure().await.unwrap();
    let mut asked = vec![];
    while let Ok(message) = heard.try_recv() {
        asked.push(message["path"].as_str().map(String::from).or(message["method"].as_str().map(String::from)).unwrap())
    }
    assert_eq!(asked[0], "/session/sess-1");
    assert!(!asked.contains(&"session.new".to_string()), "{asked:?}");
}

#[tokio::test]
async fn a_task_that_didnt_choose_firefox_stays_on_chrome_whichever_connected_first() {
    let browsers = zerod::browser::Browsers::open(&crate::common::temp_dir("firefox-default"));
    let (firefox, _f) = tokio::sync::mpsc::unbounded_channel();
    let (chrome, _c) = tokio::sync::mpsc::unbounded_channel();
    browsers.attach(&json!({"id": "firefox-1", "name": "Firefox"}), firefox);
    browsers.attach(&json!({"id": "chrome-1", "name": "Chrome"}), chrome);
    let listed = browsers.list(Some("s1"));
    let used: Vec<&str> = listed.as_array().unwrap().iter().filter(|b| b["used"] == true).filter_map(|b| b["id"].as_str()).collect();
    assert_eq!(used, ["chrome-1"], "Firefox only for a task that asks for it");
}
