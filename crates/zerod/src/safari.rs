//! Safari for Zero: Safari's automation windows (safaridriver, which comes with Safari), for seeing a page as Safari
//! draws it and acting on it with real clicks and keys. Each task has a window of its own in one automation session.
//! An automation window starts signed out of everything and keeps nothing; it's for testing, as `browser_compare`
//! uses it beside Chrome and Firefox.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Where Zero's safaridriver listens.
pub const PORT: u16 = 4456;
/// WebDriver's key for an element in an answer.
const ELEMENT: &str = "element-6066-11e4-a52e-4f735466cecf";
/// The longest side of an image an agent is sent, as the extension sends them.
const MAX_PX: u32 = 1568;

/// One step of a comparison, the same in every browser: go to a page, size it, act on it, then look.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Step {
    pub url: Option<String>,
    pub width: Option<u64>,
    pub height: Option<u64>,
    /// click, type, key, scroll, js, or screenshot (the default).
    pub action: String,
    /// The element to act on, as a CSS selector: the same element in every browser.
    pub selector: Option<String>,
    /// What to type, the key to press, or the script to run.
    pub text: Option<String>,
    /// How far to scroll down (up, if negative), in CSS pixels.
    pub scroll: Option<i64>,
    pub full_page: bool,
}

impl Step {
    pub fn from(args: &Value) -> Result<Step, String> {
        let step = Step {
            url: args["url"].as_str().map(String::from),
            width: args["width"].as_u64(),
            height: args["height"].as_u64(),
            action: args["action"].as_str().unwrap_or("screenshot").to_string(),
            selector: args["selector"].as_str().map(String::from),
            text: args["text"].as_str().map(String::from),
            scroll: args["scroll"].as_i64(),
            full_page: args["full_page"].as_bool().unwrap_or(false),
        };
        match step.action.as_str() {
            "screenshot" => {}
            "click" if step.selector.is_none() => return Err("Click what? A selector".into()),
            "type" | "key" | "js" if step.text.is_none() => return Err(format!("{} what? text", step.action)),
            "scroll" if step.scroll.is_none() => return Err("Scroll how far? scroll, in pixels".into()),
            "click" | "type" | "key" | "js" | "scroll" => {}
            other => return Err(format!("No action {other}: click, type, key, scroll, js or screenshot")),
        }
        Ok(step)
    }
}

pub struct Safari {
    /// safaridriver's address: started by Zero on PORT, or given (tests).
    address: String,
    start: bool,
    /// Where the session's id is kept: safaridriver outlives zerod's restart, still paired with Safari, and Safari
    /// takes one session at a time, so zerod started again uses that one.
    kept: Option<std::path::PathBuf>,
    state: tokio::sync::Mutex<State>,
}

#[derive(Default)]
struct State {
    driver: Option<tokio::process::Child>,
    session: Option<String>,
    /// Each task's window.
    windows: HashMap<String, String>,
}

impl Safari {
    /// Safari through a safaridriver Zero starts.
    pub fn new(kept: Option<std::path::PathBuf>) -> Arc<Safari> {
        Arc::new(Safari { address: format!("127.0.0.1:{PORT}"), start: true, kept, state: Default::default() })
    }

    /// Safari through a safaridriver already listening at `address`.
    pub fn at(address: &str, kept: Option<std::path::PathBuf>) -> Arc<Safari> {
        Arc::new(Safari { address: address.into(), start: false, kept, state: Default::default() })
    }

    /// One WebDriver request: its value, or WebDriver's error as words.
    async fn http(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Value, String> {
        let mut stream = tokio::net::TcpStream::connect(&self.address).await.map_err(|e| format!("Safari's driver isn't running: {e}"))?;
        let body = body.map(|b| b.to_string()).unwrap_or_default();
        let request = format!(
            "{method} {path} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            self.address,
            body.len()
        );
        stream.write_all(request.as_bytes()).await.map_err(|e| e.to_string())?;
        let mut response = vec![];
        tokio::time::timeout(Duration::from_secs(60), stream.read_to_end(&mut response))
            .await
            .map_err(|_| "Safari didn't answer")?
            .map_err(|e| e.to_string())?;
        let split = response.windows(4).position(|w| w == b"\r\n\r\n").ok_or("Safari's driver answered oddly")?;
        let answer: Value = serde_json::from_slice(&response[split + 4..]).map_err(|_| "Safari's driver answered oddly")?;
        let value = answer["value"].clone();
        if let Some(error) = value["error"].as_str() {
            return Err(format!("Safari: {}", value["message"].as_str().filter(|m| !m.is_empty()).unwrap_or(error)));
        }
        Ok(value)
    }

    /// The automation session, safaridriver started and the session begun if they weren't.
    async fn session(&self, state: &mut State) -> Result<String, String> {
        if let Some(session) = &state.session {
            return Ok(session.clone());
        }
        let saved = self
            .kept
            .as_ref()
            .and_then(|file| std::fs::read_to_string(file).ok())
            .map(|id| id.trim().to_string())
            .filter(|id| !id.is_empty());
        if let Some(id) = saved
            && self.http("GET", &format!("/session/{id}/window"), None).await.is_ok()
        {
            state.session = Some(id.clone());
            state.windows.clear();
            return Ok(id);
        }
        if self.start && state.driver.as_mut().is_none_or(|d| d.try_wait().ok().flatten().is_some()) {
            let child = tokio::process::Command::new("/usr/bin/safaridriver")
                .args(["--port", &PORT.to_string()])
                .kill_on_drop(true)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .map_err(|e| format!("Couldn't start safaridriver: {e}"))?;
            state.driver = Some(child);
            for _ in 0..40 {
                if self.http("GET", "/status", None).await.is_ok() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
        let started = self
            .http("POST", "/session", Some(&json!({"capabilities": {"alwaysMatch": {"browserName": "safari"}}})))
            .await
            .map_err(|e| {
                if e.contains("remote automation") {
                    "Safari won't take remote control: turn on Settings › Developer › Allow remote automation in Safari".to_string()
                } else {
                    e
                }
            })?;
        let session = started["sessionId"].as_str().ok_or("Safari didn't start a session")?.to_string();
        if let Some(file) = &self.kept {
            let _ = std::fs::write(file, &session);
        }
        state.session = Some(session.clone());
        state.windows.clear();
        Ok(session)
    }

    /// The task's window, made the current one: opened if it has none (the session's first window is the first task's).
    async fn window(&self, state: &mut State, task: &str) -> Result<String, String> {
        let session = self.session(state).await?;
        let handle = match state.windows.get(task) {
            Some(handle) => handle.clone(),
            None if state.windows.is_empty() => {
                self.http("GET", &format!("/session/{session}/window"), None).await?.as_str().unwrap_or_default().to_string()
            }
            None => self.http("POST", &format!("/session/{session}/window/new"), Some(&json!({"type": "window"}))).await?["handle"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
        };
        self.http("POST", &format!("/session/{session}/window"), Some(&json!({"handle": handle}))).await?;
        state.windows.insert(task.to_string(), handle);
        Ok(session)
    }

    /// Whether Safari takes remote control: its automation session started (or found), as browser_compare would.
    pub async fn check(&self) -> Result<(), String> {
        let mut state = self.state.lock().await;
        self.session(&mut state).await.map(|_| ())
    }

    /// One step in the task's window: what it said, and the page as it looks after.
    pub async fn step(&self, task: &str, step: &Step) -> Result<Vec<Value>, String> {
        let mut state = self.state.lock().await;
        match self.steps(&mut state, task, step).await {
            // The session gone (Safari quit, its window closed): begun again, once.
            Err(e) if e.contains("session") || e.contains("window") => {
                state.session = None;
                self.steps(&mut state, task, step).await
            }
            done => done,
        }
    }

    async fn steps(&self, state: &mut State, task: &str, step: &Step) -> Result<Vec<Value>, String> {
        let session = self.window(state, task).await?;
        let at = |path: &str| format!("/session/{session}{path}");
        let script = |source: &str, args: Value| json!({"script": source, "args": args});
        let mut said = vec![];
        if let Some(url) = &step.url {
            self.http("POST", &at("/url"), Some(&json!({"url": url}))).await?;
        }
        if let (Some(width), Some(height)) = (step.width, step.height) {
            // The window sized so the page inside it is width × height.
            let chrome = self
                .http("POST", &at("/execute/sync"), Some(&script("return [outerWidth - innerWidth, outerHeight - innerHeight]", json!([]))))
                .await?;
            let (dx, dy) = (chrome[0].as_u64().unwrap_or(0), chrome[1].as_u64().unwrap_or(0));
            self.http("POST", &at("/window/rect"), Some(&json!({"width": width + dx, "height": height + dy}))).await?;
        }
        let element = async |selector: &str| -> Result<String, String> {
            let found = self
                .http("POST", &at("/element"), Some(&json!({"using": "css selector", "value": selector})))
                .await
                .map_err(|_| format!("Nothing on the page matches {selector}"))?;
            found[ELEMENT].as_str().map(String::from).ok_or_else(|| format!("Nothing on the page matches {selector}"))
        };
        match step.action.as_str() {
            "click" => {
                let id = element(step.selector.as_deref().unwrap_or("")).await?;
                self.http("POST", &at(&format!("/element/{id}/click")), Some(&json!({}))).await?;
            }
            "type" => {
                let text = step.text.clone().unwrap_or_default();
                match &step.selector {
                    Some(selector) => {
                        let id = element(selector).await?;
                        self.http("POST", &at(&format!("/element/{id}/value")), Some(&json!({"text": text}))).await?;
                    }
                    None => self.keys(&at("/actions"), text.chars().map(|c| c.to_string()).collect()).await?,
                }
            }
            "key" => {
                let name = step.text.clone().unwrap_or_default();
                let key = crate::firefox::special(&name).map(String::from).unwrap_or(name);
                self.keys(&at("/actions"), vec![key]).await?;
            }
            "scroll" => {
                self.http("POST", &at("/execute/sync"), Some(&script("window.scrollBy(0, arguments[0])", json!([step.scroll])))).await?;
            }
            "js" => {
                let value =
                    self.http("POST", &at("/execute/sync"), Some(&script("return (0, eval)(arguments[0])", json!([step.text])))).await?;
                said.push(json!({"type": "text", "text": serde_json::to_string_pretty(&value).unwrap_or_default()}));
            }
            _ => {}
        }
        let shot = self.http("GET", &at("/screenshot"), None).await?;
        let png = shot.as_str().ok_or("Safari gave no screenshot")?;
        let (data, mime) = shrink(png).await;
        if step.full_page {
            said.push(json!({"type": "text", "text": "Safari shows only what's in its window: this is the view, not the whole page."}))
        }
        said.push(json!({"type": "image", "data": data, "mimeType": mime}));
        Ok(said)
    }

    /// Keys pressed and let go in turn, each a character or WebDriver's code for a key.
    async fn keys(&self, path: &str, keys: Vec<String>) -> Result<(), String> {
        let actions: Vec<Value> =
            keys.iter().flat_map(|k| [json!({"type": "keyDown", "value": k}), json!({"type": "keyUp", "value": k})]).collect();
        self.http("POST", path, Some(&json!({"actions": [{"type": "key", "id": "keyboard", "actions": actions}]}))).await?;
        Ok(())
    }
}

/// A PNG screenshot made a JPEG at most MAX_PX a side (macOS's sips does it), as the extension sends them; as it was if
/// that fails.
async fn shrink(png: &str) -> (String, &'static str) {
    let Some(bytes) = crate::images::unbase64(png) else { return (png.to_string(), "image/png") };
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let (from, to) =
        (std::env::temp_dir().join(format!("zero-safari-{stamp}.png")), std::env::temp_dir().join(format!("zero-safari-{stamp}.jpg")));
    let shrunk = async {
        tokio::fs::write(&from, &bytes).await.ok()?;
        let done = tokio::process::Command::new("/usr/bin/sips")
            .args(["-Z", &MAX_PX.to_string(), "-s", "format", "jpeg", "-s", "formatOptions", "80"])
            .arg(&from)
            .arg("--out")
            .arg(&to)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await
            .ok()?;
        if !done.success() {
            return None;
        }
        tokio::fs::read(&to).await.ok()
    }
    .await;
    let _ = tokio::fs::remove_file(&from).await;
    let _ = tokio::fs::remove_file(&to).await;
    match shrunk {
        Some(jpeg) => (crate::images::base64(&jpeg), "image/jpeg"),
        None => (png.to_string(), "image/png"),
    }
}
