//! Firefox for Zero: the user's Firefox Developer Edition, opened with its remote control on (WebDriver BiDi), so an
//! agent's clicks and keys are real ones and its screenshots, console, requests and dialogs are Firefox's own.
//! Zero's browser tools are the extension's (apps/chrome, loaded into Firefox by the remote control as a temporary
//! add-on each time); where Chrome's extension asks Chrome's debugger, Firefox's asks zerod, which does it over BiDi.
//! So the commands here are the Chrome debugger commands tools.js sends, done in Firefox, and Firefox's events go
//! back to the extension shaped as Chrome's.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

/// Where Firefox's remote control listens: not 9222, which Chrome's debugging often has.
pub const PORT: u16 = 9227;
/// The extension's id in Firefox, which its native host manifest names.
pub const EXTENSION: &str = "browser@zero.dev";
/// How long Firefox may take to answer one command.
const COMMAND_TIMEOUT: Duration = Duration::from_secs(60);

/// What a Chrome debugger command becomes in Firefox: BiDi commands run in turn, and how the last one's answer is
/// given back.
#[derive(Debug, PartialEq)]
pub struct Plan {
    pub commands: Vec<(String, Value)>,
    pub answer: Answer,
}

#[derive(Debug, PartialEq)]
pub enum Answer {
    /// `{}`: nothing to say.
    Nothing,
    /// Runtime.evaluate's: `{result: {type, value}}` or `{exceptionDetails}`.
    Evaluated,
    /// Page.captureScreenshot's: `{data}`.
    Screenshot,
    /// Page.getLayoutMetrics's, from the page's own numbers (JSON the page wrote).
    Metrics,
}

/// The page's sizes as Chrome's Page.getLayoutMetrics gives them, in CSS pixels.
const METRICS: &str = "JSON.stringify((() => { const v = window.visualViewport, d = document.documentElement; \
  const view = { clientWidth: v ? v.width : innerWidth, clientHeight: v ? v.height : innerHeight, pageX: v ? v.pageLeft : scrollX, pageY: v ? v.pageTop : scrollY }; \
  return { cssVisualViewport: view, cssLayoutViewport: view, cssContentSize: { x: 0, y: 0, width: Math.max(d.scrollWidth, innerWidth), height: Math.max(d.scrollHeight, innerHeight) } } })())";

/// A Chrome debugger command, for the BiDi context its tab is.
pub fn plan(method: &str, params: &Value, context: &str) -> Result<Plan, String> {
    let one = |command: &str, params: Value, answer| Ok(Plan { commands: vec![(command.into(), params)], answer });
    match method {
        "Page.enable" | "Runtime.enable" | "Network.enable" | "Emulation.setFocusEmulationEnabled" | "Page.screencastFrameAck" =>
            Ok(Plan { commands: vec![], answer: Answer::Nothing }),
        "Runtime.evaluate" => one("script.evaluate", json!({"expression": params["expression"], "target": {"context": context},
            "awaitPromise": params["awaitPromise"].as_bool().unwrap_or(false), "resultOwnership": "none",
            "userActivation": params["userGesture"].as_bool().unwrap_or(false), "serializationOptions": {"maxObjectDepth": 20}}), Answer::Evaluated),
        "Page.getLayoutMetrics" => one("script.evaluate", json!({"expression": METRICS, "target": {"context": context}, "awaitPromise": false,
            "resultOwnership": "none"}), Answer::Metrics),
        "Page.captureScreenshot" => {
            let jpeg = params["format"] == "jpeg";
            let mut shot = json!({"context": context, "origin": if params["captureBeyondViewport"] == true { "document" } else { "viewport" },
                "format": if jpeg { json!({"type": "image/jpeg", "quality": params["quality"].as_f64().unwrap_or(80.0) / 100.0}) } else { json!({"type": "image/png"}) }});
            if let Some(clip) = params.get("clip").filter(|c| c.is_object()) {
                shot["clip"] = json!({"type": "box", "x": clip["x"], "y": clip["y"], "width": clip["width"], "height": clip["height"]});
            }
            one("browsingContext.captureScreenshot", shot, Answer::Screenshot)
        }
        "Page.handleJavaScriptDialog" => {
            let mut answer = json!({"context": context, "accept": params["accept"].as_bool().unwrap_or(false)});
            if let Some(text) = params["promptText"].as_str() { answer["userText"] = json!(text) }
            one("browsingContext.handleUserPrompt", answer, Answer::Nothing)
        }
        "Emulation.setDeviceMetricsOverride" => one("browsingContext.setViewport",
            json!({"context": context, "viewport": {"width": params["width"], "height": params["height"]}}), Answer::Nothing),
        "Emulation.clearDeviceMetricsOverride" => one("browsingContext.setViewport", json!({"context": context, "viewport": null}), Answer::Nothing),
        "Input.dispatchMouseEvent" => one("input.performActions", json!({"context": context, "actions": mouse(params)?}), Answer::Nothing),
        "Input.dispatchKeyEvent" => {
            let Some(actions) = key(params) else { return Ok(Plan { commands: vec![], answer: Answer::Nothing }) };
            one("input.performActions", json!({"context": context, "actions": [actions]}), Answer::Nothing)
        }
        "Input.insertText" => {
            let typed: Vec<Value> = params["text"].as_str().unwrap_or("").chars()
                .flat_map(|c| [json!({"type": "keyDown", "value": c.to_string()}), json!({"type": "keyUp", "value": c.to_string()})]).collect();
            one("input.performActions", json!({"context": context, "actions": [{"type": "key", "id": "keyboard", "actions": typed}]}), Answer::Nothing)
        }
        "Page.startScreencast" | "Page.stopScreencast" => Err("Recording isn't available in Firefox yet: record in Chrome".into()),
        other => Err(format!("Firefox can't do {other} yet")),
    }
}

/// Chrome's modifier bits (1 Alt, 2 Control, 4 Meta, 8 Shift) as WebDriver's keys.
fn modifiers(params: &Value) -> Vec<&'static str> {
    let bits = params["modifiers"].as_u64().unwrap_or(0);
    [(1, "\u{E00A}"), (2, "\u{E009}"), (4, "\u{E03D}"), (8, "\u{E008}")].into_iter().filter(|(bit, _)| bits & bit != 0).map(|(_, key)| key).collect()
}

/// A mouse event as input sources, tick by tick: modifiers held down first and let go last.
fn mouse(params: &Value) -> Result<Value, String> {
    let (x, y) = (params["x"].as_f64().unwrap_or(0.0).round(), params["y"].as_f64().unwrap_or(0.0).round());
    let button = match params["button"].as_str() { Some("middle") => 1, Some("right") => 2, _ => 0 };
    let held = modifiers(params);
    let to = json!({"type": "pointerMove", "x": x, "y": y, "origin": "viewport"});
    let (pointer, pressing) = match params["type"].as_str() {
        Some("mouseMoved") => (vec![to], true),
        Some("mousePressed") => (vec![to, json!({"type": "pointerDown", "button": button})], true),
        Some("mouseReleased") => (vec![to, json!({"type": "pointerUp", "button": button})], false),
        Some("mouseWheel") => return Ok(json!([{"type": "wheel", "id": "wheel", "actions": [{"type": "scroll", "x": x, "y": y, "origin": "viewport",
            "deltaX": params["deltaX"].as_f64().unwrap_or(0.0).round(), "deltaY": params["deltaY"].as_f64().unwrap_or(0.0).round()}]}])),
        other => return Err(format!("Firefox can't send a mouse event {other:?}")),
    };
    let pause = || json!({"type": "pause"});
    let (mut keys, mut moves) = (vec![], vec![]);
    if pressing {
        for key in &held { keys.push(json!({"type": "keyDown", "value": key})); moves.push(pause()) }
        for action in pointer { keys.push(pause()); moves.push(action) }
    } else {
        for action in pointer { keys.push(pause()); moves.push(action) }
        for key in &held { keys.push(json!({"type": "keyUp", "value": key})); moves.push(pause()) }
    }
    let mut sources = vec![json!({"type": "pointer", "id": "mouse", "parameters": {"pointerType": "mouse"}, "actions": moves})];
    if !held.is_empty() { sources.push(json!({"type": "key", "id": "keyboard", "actions": keys})) }
    Ok(json!(sources))
}

/// A key event as a key source: the key's own character, or WebDriver's code for a key without one, its modifiers
/// around it. Chrome's "char" events say nothing a keyDown didn't: none.
fn key(params: &Value) -> Option<Value> {
    let down = match params["type"].as_str()? { "keyDown" | "rawKeyDown" => true, "keyUp" => false, _ => return None };
    let name = params["key"].as_str().unwrap_or("");
    let text = params["text"].as_str().filter(|t| t.chars().count() == 1);
    let value = text.map(String::from).or_else(|| special(name).map(String::from))
        .or_else(|| (name.chars().count() == 1).then(|| name.to_string()))?;
    let held = modifiers(params);
    let mut actions = vec![];
    if down { for key in &held { actions.push(json!({"type": "keyDown", "value": key})) } }
    actions.push(json!({"type": if down { "keyDown" } else { "keyUp" }, "value": value}));
    if !down { for key in held.iter().rev() { actions.push(json!({"type": "keyUp", "value": key})) } }
    Some(json!({"type": "key", "id": "keyboard", "actions": actions}))
}

/// WebDriver's codes for keys that type nothing.
fn special(name: &str) -> Option<&'static str> {
    Some(match name {
        "Enter" => "\u{E007}", "Tab" => "\u{E004}", "Backspace" => "\u{E003}", "Escape" => "\u{E00C}", "Delete" => "\u{E017}",
        "ArrowLeft" => "\u{E012}", "ArrowUp" => "\u{E013}", "ArrowRight" => "\u{E014}", "ArrowDown" => "\u{E015}",
        "Home" => "\u{E011}", "End" => "\u{E010}", "PageUp" => "\u{E00E}", "PageDown" => "\u{E00F}", "Insert" => "\u{E016}",
        "Shift" => "\u{E008}", "Control" => "\u{E009}", "Alt" => "\u{E00A}", "Meta" => "\u{E03D}", " " => " ",
        "F1" => "\u{E031}", "F2" => "\u{E032}", "F3" => "\u{E033}", "F4" => "\u{E034}", "F5" => "\u{E035}", "F6" => "\u{E036}",
        "F7" => "\u{E037}", "F8" => "\u{E038}", "F9" => "\u{E039}", "F10" => "\u{E03A}", "F11" => "\u{E03B}", "F12" => "\u{E03C}",
        _ => return None,
    })
}

/// A BiDi answer given back as Chrome's debugger would have.
pub fn answer(answer: &Answer, result: &Value) -> Result<Value, String> {
    Ok(match answer {
        Answer::Nothing => json!({}),
        Answer::Screenshot => json!({"data": result["data"]}),
        Answer::Evaluated => match result["type"].as_str() {
            Some("exception") => {
                let details = &result["exceptionDetails"];
                let text = details["text"].as_str().unwrap_or("Uncaught exception");
                json!({"result": {"type": "object"}, "exceptionDetails": {"text": text, "exception": {"description": text}}})
            }
            _ => {
                let value = &result["result"];
                let mut out = json!({"type": value["type"]});
                match remote(value) { Some(v) => out["value"] = v, None if value["type"] != "undefined" => out["description"] = value["type"].clone(), None => {} }
                json!({"result": out})
            }
        },
        Answer::Metrics => serde_json::from_str(result["result"]["value"].as_str().unwrap_or("")).map_err(|_| "Firefox didn't give the page's size")?,
    })
}

/// A BiDi remote value as plain JSON; none for undefined, and for what isn't data (a node, a function), its type.
pub fn remote(value: &Value) -> Option<Value> {
    let inner = &value["value"];
    Some(match value["type"].as_str()? {
        "undefined" => return None,
        "null" => Value::Null,
        "string" | "boolean" => inner.clone(),
        "number" => match inner { Value::String(special) => json!(special), number => number.clone() },
        "bigint" => inner.clone(),
        "array" | "set" => json!(inner.as_array().into_iter().flatten().map(|v| remote(v).unwrap_or(Value::Null)).collect::<Vec<_>>()),
        "object" | "map" => {
            let mut map = serde_json::Map::new();
            for pair in inner.as_array().into_iter().flatten() {
                let key = match &pair[0] { Value::String(key) => key.clone(), other => remote(other).map(|k| k.as_str().map(String::from).unwrap_or(k.to_string())).unwrap_or_default() };
                if let Some(v) = remote(&pair[1]) { map.insert(key, v); }
            }
            Value::Object(map)
        }
        "date" | "regexp" => inner.clone(),
        other => json!(other),
    })
}

/// The events the extension keeps (console, requests, dialogs, navigations).
pub const EVENTS: [&str; 7] = ["log.entryAdded", "network.beforeRequestSent", "network.responseCompleted", "network.fetchError",
                               "browsingContext.userPromptOpened", "browsingContext.userPromptClosed", "browsingContext.load"];

/// A BiDi event as the Chrome debugger event the extension keeps: the context it's in, the method, its params.
pub fn event(method: &str, params: &Value) -> Option<(String, &'static str, Value)> {
    let context = params["context"].as_str().or_else(|| params["source"]["context"].as_str())?.to_string();
    let at = params["timestamp"].clone();
    let request = || params["request"]["request"].clone();
    let (method, out) = match method {
        "log.entryAdded" if params["type"] == "javascript" => ("Runtime.exceptionThrown",
            json!({"exceptionDetails": {"text": params["text"], "exception": {"description": params["text"]}}, "timestamp": at})),
        "log.entryAdded" => ("Runtime.consoleAPICalled", json!({"type": params["method"].as_str().or(params["level"].as_str()).unwrap_or("log"),
            "args": [{"value": params["text"]}], "timestamp": at})),
        "network.beforeRequestSent" => ("Network.requestWillBeSent", json!({"requestId": request(),
            "request": {"method": params["request"]["method"], "url": params["request"]["url"]},
            "type": if params["navigation"].is_string() { "Document" } else { "Other" }})),
        "network.responseCompleted" => ("Network.responseReceived", json!({"requestId": request(), "response": {"status": params["response"]["status"]}})),
        "network.fetchError" => ("Network.loadingFailed", json!({"requestId": request(), "errorText": params["errorText"], "canceled": false})),
        "browsingContext.userPromptOpened" => ("Page.javascriptDialogOpening", json!({"type": params["type"], "message": params["message"]})),
        "browsingContext.userPromptClosed" => ("Page.javascriptDialogClosed", json!({})),
        "browsingContext.load" => ("Page.frameNavigated", json!({"frame": {"url": params["url"]}})),
        _ => return None,
    };
    Some((context, method, out))
}

/// The user's Firefox under remote control: one BiDi session, the tabs the extension has named to it, and the
/// extension to tell Firefox's events to.
pub struct Firefox {
    inner: Arc<Inner>,
    /// What opens Firefox with its remote control on; none in tests, which bring their own.
    launcher: Option<Arc<dyn Fn() + Send + Sync>>,
    address: String,
    /// The extension's folder, given to Firefox as a temporary add-on.
    extension: PathBuf,
}

#[derive(Default)]
struct Inner {
    connection: Mutex<Option<mpsc::UnboundedSender<String>>>,
    pending: Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>,
    next: AtomicU64,
    /// Each tab the extension named: its BiDi context.
    tabs: Mutex<HashMap<i64, String>>,
    /// Where Firefox's events go: the extension's connection.
    extension: Mutex<Option<mpsc::UnboundedSender<Value>>>,
    /// One connection made at a time.
    connecting: tokio::sync::Mutex<()>,
}

impl Firefox {
    pub fn new(address: &str, extension: PathBuf, launcher: Option<Arc<dyn Fn() + Send + Sync>>) -> Arc<Firefox> {
        Arc::new(Firefox { inner: Arc::default(), launcher, address: address.into(), extension })
    }

    /// The user's Firefox Developer Edition, opened behind what they're doing, its remote control on.
    pub fn launcher() -> Arc<dyn Fn() + Send + Sync> {
        Arc::new(|| { std::thread::spawn(|| std::process::Command::new("/usr/bin/open")
            .args(["-g", "-a", "Firefox Developer Edition", "--args", "--remote-debugging-port", &PORT.to_string()]).status()); })
    }

    /// The extension's connection, for Firefox's events.
    pub fn set_extension(&self, send: Option<mpsc::UnboundedSender<Value>>) { *self.inner.extension.lock().unwrap() = send }

    pub fn connected(&self) -> bool { self.inner.connection.lock().unwrap().as_ref().is_some_and(|c| !c.is_closed()) }

    /// Connected to Firefox's remote control, Firefox opened first if it isn't listening; the session started and
    /// Zero's extension installed in it.
    pub async fn ensure(&self) -> Result<(), String> {
        let _one = self.inner.connecting.lock().await;
        if self.connected() { return Ok(()) }
        let mut attempt = crate::websocket::connect(&self.address, "/session").await;
        if attempt.is_err() && let Some(launch) = &self.launcher {
            launch();
            for _ in 0..40 {
                tokio::time::sleep(Duration::from_millis(500)).await;
                attempt = crate::websocket::connect(&self.address, "/session").await;
                if attempt.is_ok() { break }
            }
        }
        let (send, mut receive) = attempt.map_err(|_| "Firefox Developer Edition isn't taking remote control. If it's open, quit it (⌘Q), and Zero opens \
                                                       it again with remote control on.".to_string())?;
        *self.inner.connection.lock().unwrap() = Some(send);
        self.inner.tabs.lock().unwrap().clear();
        let weak: Weak<Inner> = Arc::downgrade(&self.inner);
        tokio::spawn(async move {
            while let Some(text) = receive.recv().await {
                let Some(inner) = weak.upgrade() else { return };
                let Ok(message) = serde_json::from_str::<Value>(&text) else { continue };
                if let Some(id) = message["id"].as_u64() {
                    let Some(waiting) = inner.pending.lock().unwrap().remove(&id) else { continue };
                    let _ = waiting.send(if message["type"] == "error" {
                        Err(format!("Firefox: {}", message["message"].as_str().or(message["error"].as_str()).unwrap_or("refused")))
                    } else { Ok(message["result"].clone()) });
                } else if let Some(method) = message["method"].as_str()
                    && let Some((context, method, params)) = event(method, &message["params"]) {
                    let tab = inner.tabs.lock().unwrap().iter().find(|(_, c)| **c == context).map(|(t, _)| *t);
                    if let (Some(tab), Some(extension)) = (tab, inner.extension.lock().unwrap().as_ref()) {
                        let _ = extension.send(json!({"event": "browserEvent", "tab": tab, "method": method, "params": params}));
                    }
                }
            }
            if let Some(inner) = weak.upgrade() {
                *inner.connection.lock().unwrap() = None;
                for (_, waiting) in inner.pending.lock().unwrap().drain() { let _ = waiting.send(Err("Firefox closed".into())); }
            }
        });
        // Prompts stay open for the agent to answer (browser_dialog) rather than being dismissed by the session.
        self.run("session.new", json!({"capabilities": {"alwaysMatch": {"unhandledPromptBehavior": {"default": "ignore"}}}})).await?;
        self.run("session.subscribe", json!({"events": EVENTS})).await?;
        self.run("webExtension.install", json!({"extensionData": {"type": "path", "path": self.extension.to_string_lossy()}})).await?;
        Ok(())
    }

    /// One BiDi command and its result.
    pub async fn run(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.inner.next.fetch_add(1, Ordering::Relaxed) + 1;
        let (tell, waiting) = oneshot::channel();
        self.inner.pending.lock().unwrap().insert(id, tell);
        let sent = self.inner.connection.lock().unwrap().as_ref().map(|c| c.send(json!({"id": id, "method": method, "params": params}).to_string()).is_ok());
        if sent != Some(true) {
            self.inner.pending.lock().unwrap().remove(&id);
            return Err("Firefox isn't connected".into());
        }
        match tokio::time::timeout(COMMAND_TIMEOUT, waiting).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("Firefox closed".into()),
            Err(_) => { self.inner.pending.lock().unwrap().remove(&id); Err(format!("Firefox didn't answer {method}")) }
        }
    }

    /// The context of the tab the extension marked with `nonce` (an attribute on the page's root, taken off again).
    async fn find(&self, nonce: &str) -> Result<String, String> {
        let tree = self.run("browsingContext.getTree", json!({"maxDepth": 0})).await?;
        let nonce = serde_json::to_string(nonce).unwrap_or_default();
        for context in tree["contexts"].as_array().into_iter().flatten().filter_map(|c| c["context"].as_str()) {
            let expression = format!("(() => {{ const r = document.documentElement; if (!r || r.getAttribute('data-zero-tab') !== {nonce}) return false; \
                                      r.removeAttribute('data-zero-tab'); return true }})()");
            let marked = self.run("script.evaluate", json!({"expression": expression, "target": {"context": context}, "awaitPromise": false})).await;
            if marked.is_ok_and(|m| m["result"]["value"] == true) { return Ok(context.to_string()) }
        }
        Err("Firefox has no tab the extension marked: reload the tab and try again".into())
    }

    /// A Chrome debugger command for one of the extension's tabs, done in Firefox. `nonce` comes with the first
    /// command for a tab (and again if its context is lost): the mark the extension put on its page.
    pub async fn command(&self, tab: i64, nonce: Option<&str>, method: &str, params: &Value) -> Result<Value, String> {
        self.ensure().await?;
        let known = self.inner.tabs.lock().unwrap().get(&tab).cloned();
        let context = match (known, nonce) {
            (Some(context), _) => context,
            (None, Some(nonce)) => {
                let context = self.find(nonce).await?;
                self.inner.tabs.lock().unwrap().insert(tab, context.clone());
                context
            }
            (None, None) => return Err("unknown tab: mark it".into()),
        };
        let plan = plan(method, params, &context)?;
        let mut last = Value::Null;
        for (command, params) in plan.commands {
            last = self.run(&command, params).await.inspect_err(|e| {
                // A context Firefox no longer has (the tab closed or went to another process): forgotten, to be found again.
                if e.contains("no such frame") { self.inner.tabs.lock().unwrap().remove(&tab); }
            })?;
        }
        answer(&plan.answer, &last)
    }

    /// The extension's tab closed: its context goes too.
    pub fn forget(&self, tab: i64) { self.inner.tabs.lock().unwrap().remove(&tab); }
}
