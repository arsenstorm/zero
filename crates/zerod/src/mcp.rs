//! Zero's MCP server (`zerod mcp`, which `zero mcp` runs): JSON-RPC on stdio giving any agent Zero's scratchpads, the
//! browser and asks to the user as tools. It holds nothing itself; each call goes to the running zerod (started if it
//! isn't), which owns them.

use std::future::Future;
use std::path::Path;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const INSTRUCTIONS: &str = "Chrome, through Zero for Chrome: the browser_ tools act in the task's own tabs, which browser_tabs lists \
(call it first; createIfEmpty opens one). Read a page with browser_read (its elements' refs) or a screenshot (browser_computer), act with \
browser_computer, browser_form and browser_navigate, and close the tabs you opened when you're done. \
Zero's scratchpads: Markdown notes the user keeps in Zero, in folders, shared with every agent. \
A pad's link is zero://pad/<id>; zero://pad/<id>#<section> is one heading's part (its anchor as GitHub makes them). When the \
user gives you such a link, read it with scratchpad_read. Read before you change a pad, and pass the revision you read to \
scratchpad_write or scratchpad_edit, so changes made since aren't lost; scratchpad_append needs none. Give the user links \
to what you wrote, as Markdown: [Title › Section](zero://pad/<id>#section). \
In a Zero task, anything you need from the user goes through zero_ask (a question, a choice), zero_run (a command they run on their \
Mac, its output coming back to you), zero_note (where the task stands), zero_done (the task done, confirmed in two steps) or zero_blocked (it can't go on at all, as \
confirmed), when \
the `zero` command can't reach Zero (a sandbox).";

/// Zero's own: what a task asks of the user, as `zero ask`, `zero run` and `zero note` do, for agents whose commands
/// can't reach Zero's socket.
fn zero_tools() -> Vec<Value> {
    let string = |about: &str| json!({"type": "string", "description": about});
    vec![
        json!({"name": "zero_ask", "description": "Asks the user, in Zero's inbox: a question, or a choice with options. End your turn with [zero: asked <id>]; the answer comes to you as a message.",
               "inputSchema": {"type": "object", "required": ["question"], "properties": {
                   "question": string("The question, one line."),
                   "options": {"type": "array", "items": {"type": "string"}, "description": "The choices, if it's one of a few."},
                   "body": string("What the user needs to answer it: context, a recommendation."),
                   "code": string("A command or snippet the question is about, shown as code."),
                   "block": {"type": "boolean", "description": "You can't go on without the answer: Zero holds your other events until it's answered."}}}}),
        json!({"name": "zero_run", "description": "Asks the user to run a command on their Mac (their credentials, their access); its output comes back to you as a message. End your turn with [zero: asked <id>].",
               "inputSchema": {"type": "object", "required": ["command", "why"], "properties": {
                   "command": string("The command."), "why": string("What you need its output for."), "cwd": string("Where to run it; left out, the task's folder.")}}}),
        json!({"name": "zero_issue", "description": "Sets the row of one of the issues you lead, which the user reads coming back: who has it now, and what it needs. Set it whenever the issue's state changes.",
               "inputSchema": {"type": "object", "required": ["ticket", "state"], "properties": {
                   "ticket": string("The issue's ticket."), "state": string("you (on the user: a decision, access), over (done on your side, the user's step to take: a review, a merge), working, waiting (on someone else), parked or done."),
                   "text": string("On the user: what you need from them. Waiting: on whom. Parked: why. Else where it stands.")}}}),
        json!({"name": "zero_done", "description": "Marks the task done, in two steps: called with what's done, it's refused with what done means and a token; if it is so (the user said it's done, or it's finished end to end: merged, deployed and checked), call again with confirm: the token, within 5 minutes. Unsure: ask: true asks the user.",
               "inputSchema": {"type": "object", "required": ["text"], "properties": {
                   "text": string("What's done, one line."), "confirm": string("The token the first call gave."),
                   "ask": {"type": "boolean", "description": "Ask the user whether it's done instead; end your turn with [zero: asked <id>]."}}}}),
        json!({"name": "zero_blocked", "description": "Marks the task blocked (red), in two steps as zero_done: only when it can't go on at all until something outside you and the user changes (an outage, another team's access). Waiting on a review or CI is zero_note's waiting; what the user can give is zero_ask.",
               "inputSchema": {"type": "object", "required": ["text"], "properties": {
                   "text": string("What blocks it, one line."), "confirm": string("The token the first call gave.")}}}),
        json!({"name": "zero_note", "description": "Says where the task stands, on its row in Zero.",
               "inputSchema": {"type": "object", "required": ["text"], "properties": {
                   "text": string("Where it stands, one line."), "state": string("waiting (on someone else); left out, working. Done is zero_done's."), "needs": string("What it needs from the user, if anything.")}}}),
    ]
}

/// An argument: its name, what it is, whether it's needed.
type Arg = (&'static str, &'static str, bool);

/// Each tool: its name after scratchpad_, what it does, its arguments.
const TOOLS: &[(&str, &str, &[Arg])] = &[
    (
        "list",
        "Every scratchpad, the latest changed first, and the folders. Each pad has an id and a zero://pad/ link.",
        &[
            ("query", "Only pads whose title or text has this.", false),
            ("folder", "Only this folder's pads. Tasks' own pads (Tasks/<issue>) are listed only this way.", false),
        ],
    ),
    (
        "read",
        "A pad's Markdown, or one section of it, with its revision and its sections' anchors.",
        &[
            ("pad", "Its id or zero://pad/ link; a link with #section reads that section.", true),
            ("section", "A section's anchor, to read that part alone.", false),
        ],
    ),
    (
        "create",
        "A new pad. Its title is a file name, so no slashes.",
        &[
            ("title", "Its title; left out, the content's first heading's.", false),
            ("folder", "Its folder, like Work/2026; left out, the top.", false),
            ("content", "Its Markdown.", false),
        ],
    ),
    (
        "write",
        "Replaces a pad's whole text.",
        &[
            ("pad", "Its id or link.", true),
            ("content", "The new Markdown.", true),
            ("revision", "The revision you read; refused if it has changed since.", true),
        ],
    ),
    (
        "append",
        "Adds Markdown at the end of a pad, or of one of its sections.",
        &[
            ("pad", "Its id or link.", true),
            ("content", "The Markdown to add.", true),
            ("section", "The section's anchor, to add at its end.", false),
        ],
    ),
    (
        "edit",
        "Replaces one section (its heading to the next as high). Content without a heading goes under the section's own.",
        &[
            ("pad", "Its id or link.", true),
            ("section", "The section's anchor.", true),
            ("content", "The section's new Markdown.", true),
            ("revision", "The revision you read; refused if it has changed since.", true),
        ],
    ),
    ("find", "Lines with this text across every pad, with the pad, section and line.", &[("query", "The text, case aside.", true)]),
    ("rename", "Gives a pad a new title.", &[("pad", "Its id or link.", true), ("title", "The new title.", true)]),
    (
        "move",
        "Moves a pad to another folder; its link stays the same.",
        &[("pad", "Its id or link.", true), ("folder", "The folder; empty for the top.", true)],
    ),
    ("delete", "Moves a pad to the scratchpads' trash.", &[("pad", "Its id or link.", true)]),
    ("folder", "Makes a folder.", &[("folder", "Its path, like Work/2026.", true)]),
];

/// The answer to one message, if it wants one. `call` runs a tool (a scratchpad's without scratchpad_) with its arguments.
pub async fn respond<F, Fut>(message: &Value, call: F) -> Option<Value>
where
    F: FnOnce(String, Value) -> Fut,
    Fut: Future<Output = Result<Value, String>>,
{
    let id = message.get("id")?.clone();
    let params = &message["params"];
    let result = match message["method"].as_str().unwrap_or_default() {
        "initialize" => json!({
            "protocolVersion": params["protocolVersion"].as_str().unwrap_or("2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "zero", "version": env!("CARGO_PKG_VERSION")},
            "instructions": INSTRUCTIONS,
        }),
        "ping" => json!({}),
        "tools/list" => json!({"tools": TOOLS.iter().map(|(name, description, args)| json!({
            "name": format!("scratchpad_{name}"),
            "description": description,
            "inputSchema": {
                "type": "object",
                "properties": args.iter().map(|(arg, about, _)| (arg.to_string(), json!({"type": "string", "description": about}))).collect::<serde_json::Map<_, _>>(),
                "required": args.iter().filter(|(_, _, required)| *required).map(|(arg, _, _)| *arg).collect::<Vec<_>>(),
            },
        })).chain(crate::browser::tools()).chain(zero_tools()).collect::<Vec<_>>()}),
        // A browser tool's answer is already MCP content (text and screenshots), as the extension made it.
        "tools/call" if params["name"].as_str().is_some_and(|n| n.starts_with("browser_")) => {
            match call(params["name"].as_str().unwrap_or_default().to_string(), params["arguments"].clone()).await {
                Ok(answer) => json!({"content": answer["content"], "isError": answer["isError"].as_bool().unwrap_or(false)}),
                Err(why) => json!({"content": [{"type": "text", "text": why}], "isError": true}),
            }
        }
        "tools/call" if params["name"].as_str().is_some_and(|n| n.starts_with("zero_")) => {
            let name = params["name"].as_str().unwrap_or_default().to_string();
            let note = name == "zero_note" || name == "zero_issue";
            match call(name, params["arguments"].clone()).await {
                Ok(_) if note => json!({"content": [{"type": "text", "text": "Noted."}], "isError": false}),
                Ok(made) if made["done"] == true => {
                    json!({"content": [{"type": "text", "text": "Marked done. End your turn with [zero: done]."}], "isError": false})
                }
                Ok(made) if made["blocked"] == true => {
                    json!({"content": [{"type": "text", "text": "Marked blocked. End your turn with [zero: blocked]."}], "isError": false})
                }
                Ok(made) => {
                    let id = made["id"].as_str().unwrap_or_default();
                    json!({"content": [{"type": "text", "text": format!("Asked as {id}. End your turn with [zero: asked {id}]; the answer comes to you as a message.")}], "isError": false})
                }
                Err(why) => json!({"content": [{"type": "text", "text": why}], "isError": true}),
            }
        }
        "tools/call" => {
            let name = params["name"].as_str().unwrap_or_default();
            let tool = name.strip_prefix("scratchpad_").unwrap_or(name).to_string();
            let read = tool == "read";
            let (text, failed) = match call(tool, params["arguments"].clone()).await {
                Ok(pad) if read => (shown(&pad), false),
                Ok(result) => (serde_json::to_string_pretty(&result).unwrap_or_default(), false),
                Err(why) => (why, true),
            };
            json!({"content": [{"type": "text", "text": text}], "isError": failed})
        }
        other => return Some(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("No method {other}")}})),
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

/// A read pad as Markdown, under one comment line with what an agent needs to write back.
fn shown(pad: &Value) -> String {
    let folder = pad["folder"].as_str().filter(|f| !f.is_empty()).map(|f| format!(" · {f}")).unwrap_or_default();
    let sections: Vec<&str> = pad["sections"].as_array().into_iter().flatten().filter_map(|s| s["slug"].as_str()).collect();
    format!(
        "<!-- {}{folder} · id {} · revision {} · sections: {} -->\n{}",
        pad["title"].as_str().unwrap_or_default(),
        pad["id"].as_str().unwrap_or_default(),
        pad["revision"].as_str().unwrap_or_default(),
        sections.join(", "),
        pad["content"].as_str().unwrap_or_default()
    )
}

/// Serves stdin and stdout until stdin closes, each call through zerod's socket.
pub async fn serve(socket: &Path) {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut out = tokio::io::stdout();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        if let Some(answer) = respond(&message, |tool, args| through(socket, tool, args)).await {
            let mut text = answer.to_string();
            text.push('\n');
            if out.write_all(text.as_bytes()).await.is_err() || out.flush().await.is_err() {
                return;
            }
        }
    }
}

/// zerod's socket. Nothing answering on the app's own, launchd starts the LaunchAgent's zerod, or without one the
/// Zero.app this program is in is opened through Launch Services, which starts zerod as it always does: started here,
/// zerod would be the caller's child and inherit its quarantine (Chrome's, for its native host), and every file its
/// agents made would be blocked. Any other socket (a test's) isn't started.
pub async fn connect(socket: &Path) -> Result<tokio::net::UnixStream, String> {
    if let Ok(stream) = tokio::net::UnixStream::connect(socket).await {
        return Ok(stream);
    }
    let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    if socket != home.join(".zero/zerod.sock") {
        return Err("Zero isn't running".into());
    }
    if tokio::task::spawn_blocking(crate::launchd::kickstart).await.unwrap_or(false) {
        for _ in 0..50 {
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            if let Ok(stream) = tokio::net::UnixStream::connect(socket).await {
                return Ok(stream);
            }
        }
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let Some(app) = exe.ancestors().find(|dir| dir.extension().is_some_and(|e| e == "app")) else {
        return Err("Zero isn't running".into());
    };
    let opened = tokio::process::Command::new("/usr/bin/open")
        .args(["-g", "-j"])
        .arg(app)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;
    if !opened.is_ok_and(|status| status.success()) {
        return Err("Zero isn't running and didn't open".into());
    }
    // The app's launch, then zerod's.
    for _ in 0..100 {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        if let Ok(stream) = tokio::net::UnixStream::connect(socket).await {
            return Ok(stream);
        }
    }
    Err("Zero isn't running".into())
}

/// One tool call to zerod: a scratchpad's (`pad`), a browser's (`browserCall`), or an ask's (`agentAsk`), the last two for
/// the session this server runs in.
async fn through(socket: &Path, tool: String, args: Value) -> Result<Value, String> {
    let mut stream = connect(socket).await?;
    let session = std::env::var("ZERO_SESSION").ok();
    let request = if let Some(own) = tool.strip_prefix("zero_") {
        let mut args = if args.is_object() { args } else { json!({}) };
        args["tool"] = json!(own);
        json!({"id": 1, "op": "agentAsk", "session": session.ok_or("zero_ tools are for Zero's tasks; elsewhere, use the zero command")?, "args": args})
    } else if tool.starts_with("browser_") {
        json!({"id": 1, "op": "browserCall", "tool": tool, "args": args, "session": session})
    } else {
        json!({"id": 1, "op": "pad", "tool": tool, "args": args})
    };
    let mut request = request.to_string();
    request.push('\n');
    stream.write_all(request.as_bytes()).await.map_err(|e| e.to_string())?;
    let mut lines = BufReader::new(stream).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let reply: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
        if reply["id"] != 1 {
            continue;
        }
        return if reply["ok"] == true {
            Ok(reply["result"].clone())
        } else {
            Err(reply["error"].as_str().unwrap_or("zerod refused").to_string())
        };
    }
    Err("zerod closed the connection".into())
}
