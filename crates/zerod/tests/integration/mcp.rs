//! `zerod mcp`: Zero's MCP server on stdio, for any agent, giving it the scratchpads as tools. Each call goes to the
//! running zerod; here, straight to a store.

use crate::common::temp_dir;
use serde_json::{Value, json};
use zerod::mcp::respond;
use zerod::pads::{Pads, call};

async fn ask(pads: &Pads, message: Value) -> Option<Value> {
    respond(&message, |tool, args| {
        let result = call(pads, &tool, &args);
        async move { result }
    })
    .await
}

#[tokio::test]
async fn it_introduces_itself_and_lists_the_scratchpad_tools() {
    let pads = Pads::open(&temp_dir("mcp-hello"));
    let hello = ask(
        &pads,
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}}}),
    )
    .await
    .unwrap();
    assert_eq!(hello["result"]["protocolVersion"], "2025-06-18", "the client's version, answered in kind");
    assert_eq!(hello["result"]["serverInfo"]["name"], "zero");
    assert!(hello["result"]["instructions"].as_str().unwrap().contains("zero://pad/"));
    assert_eq!(ask(&pads, json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await, None, "notifications get no answer");
    let tools = ask(&pads, json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})).await.unwrap();
    let names: Vec<&str> = tools["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(
        names[..11],
        [
            "scratchpad_list",
            "scratchpad_read",
            "scratchpad_create",
            "scratchpad_write",
            "scratchpad_append",
            "scratchpad_edit",
            "scratchpad_find",
            "scratchpad_rename",
            "scratchpad_move",
            "scratchpad_delete",
            "scratchpad_folder"
        ]
    );
    assert!(
        names[11..].iter().all(|n| n.starts_with("browser_") || n.starts_with("zero_")) && names.contains(&"browser_computer"),
        "then Zero for Chrome's and Zero's own: {names:?}"
    );
    let unknown = ask(&pads, json!({"jsonrpc": "2.0", "id": 3, "method": "resources/list"})).await.unwrap();
    assert_eq!(unknown["error"]["code"], -32601);
}

#[tokio::test]
async fn an_agent_writes_a_pad_and_reads_one_section_by_its_link() {
    let pads = Pads::open(&temp_dir("mcp-calls"));
    let tool = |id: u64, name: &str, arguments: Value| json!({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": name, "arguments": arguments}});
    let created = ask(
        &pads,
        tool(
            1,
            "scratchpad_create",
            json!({"title": "Plan", "folder": "Work", "content": "# Plan\n\n## Steps\n\n1. Ship\n\n## Later\n\nMore."}),
        ),
    )
    .await
    .unwrap();
    let pad: Value = serde_json::from_str(created["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    let link = format!("{}#steps", pad["link"].as_str().unwrap());
    let read = ask(&pads, tool(2, "scratchpad_read", json!({"pad": link}))).await.unwrap();
    let text = read["result"]["content"][0]["text"].as_str().unwrap();
    // The text itself as Markdown, under one line saying what it is and how to write back.
    assert!(
        text.starts_with(&format!(
            "<!-- Plan · Work · id {} · revision {} · sections: plan, steps, later -->\n",
            pad["id"].as_str().unwrap(),
            pad["revision"].as_str().unwrap()
        )),
        "{text}"
    );
    assert!(text.ends_with("\n## Steps\n\n1. Ship\n"), "{text}");
    let stale = ask(
        &pads,
        tool(3, "scratchpad_edit", json!({"pad": pad["id"], "section": "later", "content": "Less.", "revision": "000000000000"})),
    )
    .await
    .unwrap();
    assert_eq!(stale["result"]["isError"], true);
    assert!(stale["result"]["content"][0]["text"].as_str().unwrap().contains("read it again"));
}

#[tokio::test]
async fn an_agent_asks_runs_and_notes_through_zeros_tools() {
    let list = respond(&json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}), |_, _| async { Ok(json!({})) }).await.unwrap();
    let names: Vec<&str> = list["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert!(["zero_ask", "zero_run", "zero_note"].iter().all(|n| names.contains(n)), "{names:?}");
    // Each goes to zerod as it is; an ask or a run comes back with the ending that waits on it.
    let heard = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
    let call = |name: &str, arguments: Value| {
        let heard = heard.clone();
        let message = json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": arguments}});
        async move {
            respond(&message, |tool, args| {
                heard.lock().unwrap().push((tool, args));
                async { Ok(json!({"id": "a1"})) }
            })
            .await
            .unwrap()
        }
    };
    let asked = call("zero_ask", json!({"question": "Which?", "options": ["A", "B"]})).await;
    assert!(asked["result"]["content"][0]["text"].as_str().unwrap().contains("[zero: asked a1]"), "{asked}");
    assert_eq!(heard.lock().unwrap()[0], ("zero_ask".to_string(), json!({"question": "Which?", "options": ["A", "B"]})));
    let noted = call("zero_note", json!({"text": "Blocked on CI", "state": "blocked"})).await;
    assert!(!noted["result"]["content"][0]["text"].as_str().unwrap().contains("asked"), "a note waits on nothing");
}

/// zerod down and the socket not the app's own: the call fails at once, and no zerod is started as this server's
/// child (it would inherit its caller's process tree, Chrome's quarantine with it: every file its agents made blocked).
#[tokio::test]
async fn a_server_whose_zerod_is_down_doesnt_start_one_itself() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let dir = temp_dir("mcp-down");
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_zerod"))
        .args(["mcp", "--home", &dir.join("zerod").to_string_lossy(), "--socket", &dir.join("none.sock").to_string_lossy()])
        .env("HOME", &dir)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let call = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "scratchpad_list", "arguments": {}}});
    child.stdin.as_mut().unwrap().write_all(format!("{call}\n").as_bytes()).await.unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let line =
        tokio::time::timeout(std::time::Duration::from_secs(2), lines.next_line()).await.expect("an answer at once").unwrap().unwrap();
    let answer: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(answer["result"]["isError"], true, "{answer}");
    assert!(!dir.join(".zero").exists(), "a zerod was started in the server's home");
}
