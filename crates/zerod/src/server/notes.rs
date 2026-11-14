//! Notes over the socket: scratchpads, later's things to come back to, and loops.

use serde_json::{Value, json};

use super::{Request, Zerod, unknown};

pub(super) fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    match request.op.as_str() {
        "pad" => pad(zerod, &request),
        "later" => later(zerod, &request),
        // Loops: named instructions, by name; listed for a workspace, or all.
        "loops" => {
            let here = request.workspace.as_ref().and_then(Value::as_str);
            let all = zerod.loops.list().into_iter().map(|l| placed(zerod, l));
            Ok(json!(all.filter(|l| here.is_none_or(|w| l.workspace == w)).collect::<Vec<_>>()))
        }
        "loop" => zerod.loops.read(request.name.as_deref().ok_or("Which loop?")?).map(|l| json!(placed(zerod, l))),
        "saveLoop" => {
            let saved = zerod.loops.save_in(
                request.name.as_deref().ok_or("A loop needs a name")?,
                request.description.as_deref().unwrap_or(""),
                request.body.as_deref().unwrap_or(""),
                request.workspace.as_ref().and_then(Value::as_str),
            )?;
            let _ = zerod.notices.send("loops");
            Ok(json!(placed(zerod, saved)))
        }
        "deleteLoop" => {
            zerod.loops.delete(request.name.as_deref().ok_or("Which loop?")?)?;
            let _ = zerod.notices.send("loops");
            Ok(Value::Null)
        }
        other => unknown(other),
    }
}

/// A loop in the workspace it was put in, or Zero's if that's gone.
fn placed(zerod: &Zerod, mut found: crate::loops::Loop) -> crate::loops::Loop {
    found.workspace = zerod.daemon.workspaces.of(Some(&found.workspace));
    found
}

/// A scratchpad tool called, subscribers told of a change. One an agent makes is in its task's workspace.
fn pad(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    let tool = request.tool.as_deref().ok_or("Which scratchpad tool?")?;
    let mut args = request.args.clone().unwrap_or(json!({}));
    if tool == "create"
        && args["workspace"].is_null()
        && let (Some(task), Some(fields)) = (request.session.as_deref().and_then(|id| daemon.get(id)), args.as_object_mut())
    {
        fields.insert("workspace".into(), json!(daemon.workspace_of(&task)));
    }
    let result = crate::pads::call(&zerod.pads, tool, &args, &|w| daemon.workspaces.of(Some(w)));
    if result.is_ok() && !matches!(tool, "list" | "read" | "find") {
        let _ = zerod.notices.send("pads");
    }
    result
}

/// Later: things to come back to. Saved from a task, it knows which, and the task's name and workspace then.
fn later(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    let tool = request.tool.as_deref().ok_or("Which later tool?")?;
    let mut args = request.args.clone().unwrap_or(json!({}));
    if let (Some(id), Some(fields)) = (request.session.as_deref(), args.as_object_mut())
        && let Some(task) = daemon.get(id)
    {
        if tool == "save" {
            fields.insert("from".into(), json!(id));
            fields.insert("task".into(), json!(crate::bridge::label(&task)));
            fields.insert("workspace".into(), json!(daemon.workspace_of(&task)));
        } else if tool == "edit" {
            fields.insert("by".into(), json!(id));
        }
    }
    // A task saved whole, its item deleted: back on the board, rather than kept off it with nothing to bring it back.
    let saved =
        (tool == "delete").then(|| args["item"].as_str().and_then(|i| zerod.later.view(i, None).ok()).and_then(|i| i.resume)).flatten();
    let result = crate::later::call(&zerod.later, tool, &args);
    if result.is_ok()
        && let Some(session) = saved
    {
        let daemon = daemon.clone();
        tokio::spawn(async move { daemon.bring_back(&session).await });
    }
    if result.is_ok() && !matches!(tool, "list" | "view") {
        let _ = zerod.notices.send("later");
    }
    result
}
