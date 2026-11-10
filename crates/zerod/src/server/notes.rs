//! Notes over the socket: scratchpads, later's things to come back to, and loops.

use serde_json::{Value, json};

use super::{Request, Zerod, unknown};

pub(super) fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    match request.op.as_str() {
        "pad" => pad(zerod, &request),
        "later" => later(zerod, &request),
        // Loops: named instructions, by name.
        "loops" => Ok(json!(zerod.loops.list())),
        "loop" => zerod.loops.read(request.name.as_deref().ok_or("Which loop?")?).map(|l| json!(l)),
        "saveLoop" => {
            let saved = zerod.loops.save(request.name.as_deref().ok_or("A loop needs a name")?, request.description.as_deref().unwrap_or(""), request.body.as_deref().unwrap_or(""))?;
            let _ = zerod.notices.send("loops");
            Ok(json!(saved))
        }
        "deleteLoop" => {
            zerod.loops.delete(request.name.as_deref().ok_or("Which loop?")?)?;
            let _ = zerod.notices.send("loops");
            Ok(Value::Null)
        }
        other => unknown(other),
    }
}

/// A scratchpad tool called, subscribers told of a change.
fn pad(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let tool = request.tool.as_deref().ok_or("Which scratchpad tool?")?;
    let result = crate::pads::call(&zerod.pads, tool, request.args.as_ref().unwrap_or(&Value::Null));
    if result.is_ok() && !matches!(tool, "list" | "read" | "find") { let _ = zerod.notices.send("pads"); }
    result
}

/// Later: things to come back to. Saved from a task, it knows which, and the task's name and workspace then.
fn later(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    let tool = request.tool.as_deref().ok_or("Which later tool?")?;
    let mut args = request.args.clone().unwrap_or(json!({}));
    if let (Some(id), Some(fields)) = (request.session.as_deref(), args.as_object_mut())
        && let Some(task) = daemon.get(id) {
        if tool == "save" {
            fields.insert("from".into(), json!(id));
            fields.insert("task".into(), json!(crate::bridge::label(&task)));
            fields.insert("workspace".into(), json!(daemon.workspace_of(&task)));
        } else if tool == "edit" {
            fields.insert("by".into(), json!(id));
        }
    }
    // A task saved whole, its item deleted: back on the board, rather than kept off it with nothing to bring it back.
    let saved = (tool == "delete").then(|| args["item"].as_str().and_then(|i| zerod.later.view(i, None).ok()).and_then(|i| i.resume)).flatten();
    let result = crate::later::call(&zerod.later, tool, &args);
    if result.is_ok() && let Some(session) = saved {
        let daemon = daemon.clone();
        tokio::spawn(async move { daemon.bring_back(&session).await });
    }
    if result.is_ok() && !matches!(tool, "list" | "view") { let _ = zerod.notices.send("later"); }
    result
}
