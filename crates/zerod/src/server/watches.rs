//! What wakes a task, over the socket: commands and files watched, reminders and schedules, and topics followed.

use serde_json::{Value, json};

use super::{Request, Zerod, unknown};

pub(super) async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    match request.op.as_str() {
        "watch" => daemon.watch(&request.session()?, request.command.as_deref().ok_or("Watch which command?")?).map(|_| Value::Null),
        "watchFile" => watch_file(zerod, &request),
        "watches" => Ok(json!(daemon.watches(request.session.as_deref()))),
        "unwatch" => daemon.unwatch(request.watch.as_ref().and_then(Value::as_str).ok_or("Which watch?")?).map(|_| Value::Null),
        "remind" => {
            let after = std::time::Duration::from_secs(request.minutes.ok_or("Remind in how many minutes?")? * 60);
            daemon.remind(&request.session()?, after, request.text.as_deref().ok_or("Remind with text")?).map(|_| Value::Null)
        }
        "schedule" => schedule(zerod, &request),
        "schedules" => Ok(json!(daemon.schedules(request.session.as_deref()))),
        "unschedule" => daemon.unschedule(request.item.as_ref().and_then(Value::as_str).ok_or("Which schedule?")?).map(|_| Value::Null),
        "follow" => {
            let followed = zerod.following.follow(&request.session()?, request.topic.as_deref().ok_or("Follow what? A topic or a URL")?, request.mine.unwrap_or(false), request.about.clone().unwrap_or_default()).await?;
            let _ = zerod.notices.send("following");
            Ok(json!(followed))
        }
        "unfollow" => {
            let removed = zerod.following.unfollow(&request.session()?, if request.all == Some(true) { None } else { Some(request.topics.as_deref().ok_or("Unfollow which topics? Or all")?) });
            let _ = zerod.notices.send("following");
            Ok(json!({"removed": removed}))
        }
        "following" => Ok(json!(zerod.following.list(request.session.as_deref()))),
        other => unknown(other),
    }
}

/// A file watched for the session: {file, alerts, done, quiet}.
fn watch_file(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let watch = request.watch.as_ref().ok_or("Watch what?")?;
    let file = watch["file"].as_str().ok_or("Watch which file?")?;
    let alerts = watch["alerts"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
    let watch = crate::watches::Watch { session: request.session()?, file: file.into(), alerts, done: watch["done"].as_str().map(String::from), quiet: watch["quiet"].as_u64(), ..Default::default() };
    zerod.daemon.watch_file(watch).map(|id| json!({"watch": id}))
}

/// A task waking itself at a time: `at` (seconds since 1970) or in `minutes`.
fn schedule(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let at = match (request.at, request.minutes) {
        (Some(at), _) => at,
        (None, Some(minutes)) => std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0) + minutes as i64 * 60,
        _ => return Err("When? at (seconds since 1970) or minutes".into()),
    };
    zerod.daemon.schedule(&request.session()?, at, request.text.as_deref().ok_or("Schedule it with what for?")?).map(|s| json!(s))
}
