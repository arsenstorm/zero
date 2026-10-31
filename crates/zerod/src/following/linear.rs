//! `linear/<ISSUE>[/<thread>]`: a Linear issue, or one comment thread in it. The issue topic hears everything: field
//! changes (status, assignee, priority, project, cycle, labels, estimate, due date, parent, title, description) and
//! every comment. Comments are published on `linear/<ISSUE>/<thread>`, `<thread>` being the first 8 hex characters of
//! the thread's top comment's id (what Linear puts in `#comment-xxxxxxxx` links), so a thread's follower hears only its
//! comments. Read on the Linear connection Zero's integration keeps.

use serde_json::{Map, Value, json};

use super::{Event, Poll, first_line, text_diff};

const QUERY: &str = r#"query($id: String!) {
  viewer { id name }
  issue(id: $id) {
    id identifier title description url priorityLabel estimate dueDate
    state { name } assignee { id name } project { name } cycle { number name } parent { identifier }
    labels(first: 50) { nodes { name } }
    comments(first: 250) { nodes { id body url createdAt updatedAt user { id name } botActor { name } externalUser { name } parent { id } } }
  }
}"#;

const FIELDS: [(&str, &str); 9] = [("state", "status"), ("assignee", "assignee"), ("priority", "priority"), ("project", "project"), ("cycle", "cycle"),
                                    ("estimate", "estimate"), ("due", "due date"), ("parent", "parent"), ("title", "title")];

fn is_issue(id: &str) -> bool {
    let Some((team, number)) = id.rsplit_once('-') else { return false };
    team.chars().next().is_some_and(|c| c.is_ascii_alphabetic()) && team.chars().all(|c| c.is_ascii_alphanumeric()) && !number.is_empty() && number.chars().all(|c| c.is_ascii_digit())
}

pub fn normalize(parts: &[&str]) -> Result<Vec<String>, String> {
    let (issue, thread) = match parts { [issue] => (issue, None), [issue, thread] => (issue, Some(thread)), _ => return Err("expected linear/<ISSUE-ID> or linear/<ISSUE-ID>/<thread-id>".into()) };
    if !is_issue(issue) { return Err("expected linear/<ISSUE-ID> or linear/<ISSUE-ID>/<thread-id>".into()) }
    let mut out = vec![issue.to_uppercase()];
    if let Some(thread) = thread {
        let thread = thread.to_lowercase().replace("comment-", "");
        if thread.len() < 4 || !thread.chars().all(|c| c.is_ascii_hexdigit() || c == '-') { return Err(format!("bad comment thread id {thread:?}")) }
        out.push(thread);
    }
    Ok(out)
}

/// `https://linear.app/<ws>/issue/<ISSUE>/<title>#comment-<id>`.
pub fn from_url(url: &str) -> Option<String> {
    let rest = url.trim().strip_prefix("https://").or_else(|| url.trim().strip_prefix("http://"))?.strip_prefix("linear.app/")?;
    let (_, rest) = rest.split_once("/issue/")?;
    let issue = rest.split(['/', '?', '#']).next().filter(|id| is_issue(id))?;
    let comment = rest.split_once("#comment-").map(|(_, id)| id.split(['?', '&', '/']).next().unwrap_or(""));
    Some(match comment { Some(id) if !id.is_empty() => format!("linear/{}/{id}", issue.to_uppercase()), _ => format!("linear/{}", issue.to_uppercase()) })
}

pub fn query(issue: &str) -> Value { json!({"query": QUERY, "variables": {"id": issue}}) }

pub fn poll(reply: &Value, state: Option<&Value>, key: &str) -> Result<Poll, String> {
    let new = snapshot(&reply["data"]).ok_or_else(|| format!("Linear issue {} not found", key.trim_start_matches("linear/")))?;
    let events = state.map(|old| diff(old, &new, key)).unwrap_or_default();
    Ok(Poll { summary: describe(&new), state: new, events })
}

fn str(v: &Value) -> &str { v.as_str().unwrap_or("") }
fn strings(v: &Value) -> Vec<&str> { v.as_array().into_iter().flatten().filter_map(Value::as_str).collect() }

pub fn snapshot(data: &Value) -> Option<Value> {
    let issue = &data["issue"];
    if !issue.is_object() { return None }
    let mut comments = Map::new();
    for c in issue["comments"]["nodes"].as_array().into_iter().flatten() {
        let author = [&c["user"]["name"], &c["externalUser"]["name"], &c["botActor"]["name"]].into_iter().find_map(|n| n.as_str()).unwrap_or("integration");
        comments.insert(str(&c["id"]).into(), json!({"parent": c["parent"]["id"], "author": author, "author_id": c["user"]["id"], "body": c["body"], "url": c["url"], "created": c["createdAt"], "updated": c["updatedAt"]}));
    }
    let cycle = &issue["cycle"];
    let labels = |issue: &Value| { let mut l: Vec<String> = issue["labels"]["nodes"].as_array().into_iter().flatten().filter_map(|n| n["name"].as_str().map(String::from)).collect(); l.sort(); l };
    Some(json!({
        "viewer": data["viewer"]["id"], "id": issue["id"], "identifier": issue["identifier"], "url": issue["url"],
        "title": issue["title"], "description": issue["description"].as_str().unwrap_or(""),
        "state": issue["state"]["name"], "assignee": issue["assignee"]["name"], "priority": issue["priorityLabel"], "project": issue["project"]["name"],
        "cycle": if cycle.is_object() { cycle["name"].as_str().map(String::from).or_else(|| cycle["number"].as_i64().map(|n| format!("Cycle {n}"))).into() } else { Value::Null },
        "estimate": issue["estimate"], "due": issue["dueDate"], "parent": issue["parent"]["identifier"],
        "labels": labels(issue),
        "truncated": comments.len() >= 250, "comments": comments,
    }))
}

fn root(comments: &Value, id: &str) -> String {
    let (mut id, mut hops) = (id.to_string(), 0);
    while let Some(parent) = comments[&id]["parent"].as_str() && hops < 50 { id = parent.to_string(); hops += 1; }
    id
}

fn thread_topic(key: &str, root: &str) -> String { format!("{key}/{}", root.chars().take(8).collect::<String>()) }

pub fn diff(old: &Value, new: &Value, key: &str) -> Vec<Event> {
    let url = str(&new["url"]).to_string();
    let mut ev: Vec<Event> = vec![];
    let name = |v: &Value| match v { Value::Null => "none".to_string(), Value::String(s) => s.clone(), other => other.to_string() };
    for (field, label) in FIELDS {
        if old[field] != new[field] { ev.push(Event { topic: key.into(), kind: field.into(), summary: format!("{label}: {} → {}", name(&old[field]), name(&new[field])), url: url.clone(), ..Default::default() }) }
    }
    let (before, after) = (strings(&old["labels"]), strings(&new["labels"]));
    for x in after.iter().filter(|x| !before.contains(x)) { ev.push(Event { topic: key.into(), kind: "labels".into(), summary: format!("label added: {x}"), url: url.clone(), ..Default::default() }) }
    for x in before.iter().filter(|x| !after.contains(x)) { ev.push(Event { topic: key.into(), kind: "labels".into(), summary: format!("label removed: {x}"), url: url.clone(), ..Default::default() }) }
    if old["description"] != new["description"] {
        ev.push(Event { topic: key.into(), kind: "description".into(), summary: "description edited".into(), body: text_diff(str(&old["description"]), str(&new["description"])), url: url.clone(), ..Default::default() });
    }
    let (olds, news) = (&old["comments"], &new["comments"]);
    let oldest = olds.as_object().into_iter().flatten().map(|(_, c)| str(&c["created"])).min().unwrap_or("");
    // In the order they were written (the map is by id).
    let mut written: Vec<(&String, &Value)> = news.as_object().into_iter().flatten().collect();
    written.sort_by_key(|(id, c)| (str(&c["created"]).to_string(), (*id).clone()));
    for (id, c) in written {
        let (author, what) = (str(&c["author"]), if c["parent"].is_null() { "comment" } else { "reply" });
        let mine = !new["viewer"].is_null() && c["author_id"] == new["viewer"];
        let topic = thread_topic(key, &root(news, id));
        match olds.get(id) {
            // An old comment that slid into the newest-250 window after a deletion isn't news.
            None if !(old["truncated"] == true && str(&c["created"]) < oldest) =>
                ev.push(Event { topic, kind: "comment".into(), summary: format!("{what} by {author}"), body: str(&c["body"]).into(), url: str(&c["url"]).into(), actor: author.into(), mine, dedupe: Some(format!("comment:{id}")), root: None, after: None }),
            Some(prev) if prev["body"] != c["body"] =>
                ev.push(Event { topic, kind: "comment_edited".into(), summary: format!("{what} by {author} edited"), body: str(&c["body"]).into(), url: str(&c["url"]).into(), actor: author.into(), mine, ..Default::default() }),
            _ => {}
        }
    }
    if new["truncated"] != true {
        for (id, c) in olds.as_object().into_iter().flatten() {
            if news.get(id).is_none() {
                ev.push(Event { topic: thread_topic(key, &root(olds, id)), kind: "comment_deleted".into(), summary: format!("comment by {} deleted", str(&c["author"])), body: str(&c["body"]).into(), url: url.clone(), ..Default::default() });
            }
        }
    }
    ev
}

pub fn describe(s: &Value) -> String { format!("{}: {} [{}] {}", str(&s["identifier"]), str(&s["title"]), str(&s["state"]), str(&s["url"])) }

/// A thread topic as canonical (its root comment's first 8 characters), with whose thread it is; an issue topic as is.
pub fn resolve(topic: &str, state: &Value) -> Result<(String, String), String> {
    let parts: Vec<&str> = topic.split('/').collect();
    let [_, issue, thread] = parts[..] else { return Ok((topic.to_string(), String::new())) };
    let comments = &state["comments"];
    let found = comments.as_object().into_iter().flatten().map(|(id, _)| id.as_str()).find(|id| id.starts_with(thread)).ok_or_else(|| format!("no comment {thread} on {issue}"))?;
    let root = root(comments, found);
    let c = &comments[&root];
    Ok((format!("linear/{issue}/{}", root.chars().take(8).collect::<String>()), format!("thread by {}: {}", str(&c["author"]), first_line(str(&c["body"]), 80))))
}

/// Whether `given` names `kept`'s thread by a longer form of the same comment id.
pub fn same_thread(given: &str, kept: &str) -> bool {
    match (given.strip_prefix("linear/").and_then(|g| g.split_once('/')), kept.strip_prefix("linear/").and_then(|k| k.split_once('/'))) {
        (Some((gi, gt)), Some((ki, kt))) => gi == ki && (gt.starts_with(kt) || kt.starts_with(gt)),
        _ => false,
    }
}
