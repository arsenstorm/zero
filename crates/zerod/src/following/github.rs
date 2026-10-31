//! `github/<owner>/<repo>/<number>`: everything that happens on a pull request, read through `gh` in one GraphQL
//! query and diffed against the last reading: state, draft, title, description, base, labels, assignees, reviewers,
//! review decision, conflicts, pushes, CI (each failed check, then the overall result), comments, review comments,
//! reviews, and review threads resolved or not.

use serde_json::{Map, Value, json};

use super::{Event, Poll, text_diff};

const QUERY: &str = r#"query($owner: String!, $repo: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      title url state isDraft body baseRefName headRefName headRefOid mergeable reviewDecision
      author { login }
      mergedBy { login }
      assignees(first: 20) { nodes { login } }
      labels(first: 30) { nodes { name } }
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } ... on Bot { login } } } }
      comments(last: 100) { nodes { id author { login } body url createdAt updatedAt } }
      reviews(last: 100) { nodes { id author { login } state body url submittedAt updatedAt } }
      reviewThreads(last: 100) { nodes { id isResolved path line comments(last: 50) { nodes { id author { login } body url createdAt updatedAt state } } } }
      commits(last: 30) { totalCount nodes { commit { oid messageHeadline statusCheckRollup { state contexts(first: 100) { nodes {
        __typename ... on CheckRun { name status conclusion detailsUrl } ... on StatusContext { context state targetUrl } } } } } } }
    }
  }
}"#;

const FAILED: [&str; 6] = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"];
const PASSED: [&str; 4] = ["SUCCESS", "NEUTRAL", "SKIPPED", "STALE"];
const TERMINAL: [&str; 3] = ["SUCCESS", "FAILURE", "ERROR"];

/// `owner/repo/number`, from `github/o/r/42`, `github/o/r/pull/42` or a pull request's URL.
pub fn normalize(parts: &[&str]) -> Result<Vec<String>, String> {
    let parts: Vec<&str> = if parts.len() == 4 && matches!(parts[2], "pull" | "pulls") { vec![parts[0], parts[1], parts[3]] } else { parts.to_vec() };
    let [owner, repo, number] = parts[..] else { return Err("expected github/<owner>/<repo>/<pr-number>".into()) };
    let number: u64 = number.parse().map_err(|_| "expected github/<owner>/<repo>/<pr-number>".to_string())?;
    Ok(vec![owner.to_lowercase(), repo.to_lowercase(), number.to_string()])
}

pub fn from_url(url: &str) -> Option<String> {
    let rest = url.trim().strip_prefix("https://").or_else(|| url.trim().strip_prefix("http://"))?;
    let rest = rest.strip_prefix("www.").unwrap_or(rest).strip_prefix("github.com/")?;
    let parts: Vec<&str> = rest.split(['/', '?', '#']).collect();
    if parts.len() < 4 || parts[2] != "pull" || !parts[3].chars().all(|c| c.is_ascii_digit()) || parts[3].is_empty() { return None }
    Some(format!("github/{}/{}/{}", parts[0], parts[1], parts[3]))
}

/// The `gh` command that reads the pull request.
pub fn argv(key: &[&str]) -> Vec<String> {
    ["gh", "api", "graphql", "-f", &format!("query={QUERY}"), "-f", &format!("owner={}", key[0]), "-f", &format!("repo={}", key[1]), "-F", &format!("number={}", key[2])]
        .map(String::from).to_vec()
}

/// What `gh` answered, diffed against the last snapshot into events on `topic`.
pub fn poll(reply: &Value, state: Option<&Value>, topic: &str) -> Result<Poll, String> {
    if let Some(error) = reply["errors"][0]["message"].as_str() { return Err(error.into()) }
    let mut new = snapshot(&reply["data"]).ok_or_else(|| format!("{} not found", topic.trim_start_matches("github/")))?;
    // GitHub works mergeability out lazily; UNKNOWN keeps the last known value, so MERGEABLE → UNKNOWN → CONFLICTING is still a change.
    if let Some(old) = state && new["mergeable"] == "UNKNOWN" { new["mergeable"] = old["mergeable"].clone() }
    let events = state.map(|old| diff(old, &new, topic)).unwrap_or_default();
    Ok(Poll { summary: describe(&new), state: new, events })
}

fn login(node: &Value) -> String { node["author"]["login"].as_str().unwrap_or("ghost").to_string() }

fn names(nodes: &Value, key: &str) -> Vec<String> {
    let mut out: Vec<String> = nodes.as_array().into_iter().flatten().filter_map(|n| n[key].as_str().map(String::from)).collect();
    out.sort();
    out
}

pub fn snapshot(data: &Value) -> Option<Value> {
    let pr = &data["repository"]["pullRequest"];
    if !pr.is_object() { return None }
    let commits: Vec<&Value> = pr["commits"]["nodes"].as_array().into_iter().flatten().map(|n| &n["commit"]).collect();
    let rollup = commits.last().map(|c| &c["statusCheckRollup"]).cloned().unwrap_or(Value::Null);
    let mut checks = Map::new();
    for c in rollup["contexts"]["nodes"].as_array().into_iter().flatten() {
        match c["__typename"].as_str() {
            Some("CheckRun") => { checks.insert(c["name"].as_str().unwrap_or("").into(), json!({"s": c["conclusion"].as_str().or(c["status"].as_str()), "url": c["detailsUrl"]})); }
            Some("StatusContext") => { checks.insert(c["context"].as_str().unwrap_or("").into(), json!({"s": c["state"], "url": c["targetUrl"]})); }
            _ => {}
        }
    }
    let mut comments = Map::new();
    for c in pr["comments"]["nodes"].as_array().into_iter().flatten() {
        comments.insert(c["id"].as_str().unwrap_or("").into(), json!({"kind": "comment", "author": login(c), "body": c["body"], "url": c["url"], "created": c["createdAt"], "updated": c["updatedAt"]}));
    }
    let mut threads = Map::new();
    for t in pr["reviewThreads"]["nodes"].as_array().into_iter().flatten() {
        let r#where = match t["line"].as_i64() { Some(line) => format!("{}:{line}", t["path"].as_str().unwrap_or("")), None => t["path"].as_str().unwrap_or("").into() };
        let first = t["comments"]["nodes"].get(0).cloned().unwrap_or(Value::Null);
        threads.insert(t["id"].as_str().unwrap_or("").into(), json!({"resolved": t["isResolved"], "where": r#where, "url": first["url"]}));
        for c in t["comments"]["nodes"].as_array().into_iter().flatten() {
            if c["state"] == "PENDING" { continue } // part of a review not yet submitted
            comments.insert(c["id"].as_str().unwrap_or("").into(), json!({"kind": "review_comment", "author": login(c), "body": c["body"], "url": c["url"], "created": c["createdAt"], "updated": c["updatedAt"], "where": r#where}));
        }
    }
    let mut reviews = Map::new();
    for r in pr["reviews"]["nodes"].as_array().into_iter().flatten() {
        if r["state"] == "PENDING" { continue } // the viewer's own draft
        let (submitted, updated) = (r["submittedAt"].as_str(), r["updatedAt"].as_str());
        reviews.insert(r["id"].as_str().unwrap_or("").into(), json!({"author": login(r), "state": r["state"], "body": r["body"], "url": r["url"], "created": submitted.or(updated), "updated": updated.or(submitted)}));
    }
    let mut reviewers: Vec<String> = pr["reviewRequests"]["nodes"].as_array().into_iter().flatten().filter_map(|n| {
        let rv = &n["requestedReviewer"];
        rv["login"].as_str().map(String::from).or_else(|| rv["slug"].as_str().map(|slug| format!("team:{slug}")))
    }).collect();
    reviewers.sort();
    Some(json!({
        "viewer": data["viewer"]["login"], "title": pr["title"], "url": pr["url"], "body": pr["body"].as_str().unwrap_or(""),
        "state": pr["state"], "draft": pr["isDraft"], "base": pr["baseRefName"], "head_ref": pr["headRefName"],
        "mergeable": pr["mergeable"], "review_decision": pr["reviewDecision"], "author": login(pr), "merged_by": pr["mergedBy"]["login"],
        "assignees": names(&pr["assignees"]["nodes"], "login"), "labels": names(&pr["labels"]["nodes"], "name"), "reviewers": reviewers,
        "head": pr["headRefOid"], "commits": commits.iter().map(|c| json!({"oid": c["oid"], "headline": c["messageHeadline"]})).collect::<Vec<_>>(),
        "total_commits": pr["commits"]["totalCount"], "checks": checks, "rollup": rollup["state"],
        "comments": comments, "reviews": reviews, "threads": threads,
    }))
}

pub fn describe(s: &Value) -> String {
    let state = s["state"].as_str().unwrap_or("").to_lowercase();
    let draft = if s["draft"] == true && s["state"] == "OPEN" { ", draft" } else { "" };
    format!("{} ({state}{draft}) {}", s["title"].as_str().unwrap_or(""), s["url"].as_str().unwrap_or(""))
}

fn str(v: &Value) -> &str { v.as_str().unwrap_or("") }
fn list(v: &Value) -> Vec<&str> { v.as_array().into_iter().flatten().filter_map(Value::as_str).collect() }
fn lower(v: &Value) -> String { str(v).to_lowercase().replace('_', " ") }
fn is_failed(s: &Value) -> bool { s.as_str().is_some_and(|s| FAILED.contains(&s)) }

pub fn diff(old: &Value, new: &Value, topic: &str) -> Vec<Event> {
    let me = new["viewer"].as_str();
    let url = str(&new["url"]).to_string();
    let mut ev: Vec<Event> = vec![];
    let mut add = |kind: &str, summary: String, body: &str, link: &str, actor: &str| {
        ev.push(Event { topic: topic.into(), kind: kind.into(), summary, body: body.into(), url: if link.is_empty() { url.clone() } else { link.into() },
                        actor: actor.into(), mine: me.is_some_and(|m| m == actor), ..Default::default() });
    };
    if old["state"] != new["state"] {
        match str(&new["state"]) {
            "MERGED" => { let by = str(&new["merged_by"]); add("merged", format!("PR merged into {}{}", str(&new["base"]), if by.is_empty() { String::new() } else { format!(" by @{by}") }), "", "", by) }
            "CLOSED" => add("closed", "PR closed without merging".into(), "", "", ""),
            _ => add("reopened", "PR reopened".into(), "", "", ""),
        }
    }
    if old["draft"] != new["draft"] { add("draft", (if new["draft"] == true { "PR converted to draft" } else { "PR marked ready for review" }).into(), "", "", "") }
    if old["title"] != new["title"] { add("title", format!("title changed: {:?} → {:?}", str(&old["title"]), str(&new["title"])), "", "", "") }
    if old["base"] != new["base"] { add("base", format!("base branch changed: {} → {}", str(&old["base"]), str(&new["base"])), "", "", "") }
    if old["body"] != new["body"] { add("description", "PR description edited".into(), &text_diff(str(&old["body"]), str(&new["body"])), "", "") }
    for (key, added, removed) in [("labels", "label added: ", "label removed: "), ("assignees", "assignee added: ", "assignee removed: "), ("reviewers", "review requested from ", "review request removed: ")] {
        let (before, after) = (list(&old[key]), list(&new[key]));
        for x in after.iter().filter(|x| !before.contains(x)) { add(key, format!("{added}{x}"), "", "", "") }
        for x in before.iter().filter(|x| !after.contains(x)) { add(key, format!("{removed}{x}"), "", "", "") }
    }
    if old["review_decision"] != new["review_decision"] && new["state"] == "OPEN" {
        let name = |v: &Value| if v.is_null() { "none".to_string() } else { lower(v) };
        add("review_decision", format!("review decision: {} → {}", name(&old["review_decision"]), name(&new["review_decision"])), "", "", "");
    }
    if old["mergeable"] != new["mergeable"] && old["mergeable"] != "UNKNOWN" && new["mergeable"] != "UNKNOWN" {
        if new["mergeable"] == "CONFLICTING" { add("conflicts", format!("PR now has merge conflicts with {}", str(&new["base"])), "", "", "") }
        else if old["mergeable"] == "CONFLICTING" { add("conflicts", "merge conflicts resolved".into(), "", "", "") }
    }
    let same_head = old["head"] == new["head"];
    if !same_head {
        let known: Vec<&str> = old["commits"].as_array().into_iter().flatten().map(|c| str(&c["oid"])).collect();
        let commits: Vec<&Value> = new["commits"].as_array().into_iter().flatten().collect();
        let pushed: Vec<&&Value> = commits.iter().filter(|c| !known.contains(&str(&c["oid"]))).collect();
        let forced = !commits.iter().any(|c| c["oid"] == old["head"]) && new["total_commits"].as_u64().unwrap_or(0) as usize <= commits.len();
        let lines: Vec<String> = pushed.iter().rev().take(15).rev().map(|c| format!("{} {}", str(&c["oid"]).chars().take(8).collect::<String>(), str(&c["headline"]))).collect();
        let what = format!("{} new commit{}", pushed.len(), if pushed.len() == 1 { "" } else { "s" });
        let summary = if forced { format!("force-pushed ({what})") } else { format!("{what} pushed to {}", str(&new["head_ref"])) };
        add("push", summary, &lines.join("\n"), &format!("{url}/commits"), "");
    }
    let (old_checks, new_checks) = (old["checks"].as_object(), new["checks"].as_object());
    for (name, c) in new_checks.into_iter().flatten() {
        let prev = if same_head { old_checks.and_then(|o| o.get(name)) } else { None };
        if is_failed(&c["s"]) && prev.is_none_or(|p| p["s"] != c["s"]) {
            add("check_failed", format!("check failed: {name} ({})", lower(&c["s"])), "", str(&c["url"]), "");
        }
    }
    let rollup = str(&new["rollup"]);
    if TERMINAL.contains(&rollup) && (!same_head || old["rollup"] != new["rollup"]) {
        let states: Vec<&str> = new_checks.into_iter().flatten().map(|(_, c)| str(&c["s"])).collect();
        let ok = states.iter().filter(|s| PASSED[..3].contains(s)).count();
        let bad = states.iter().filter(|s| FAILED.contains(s)).count();
        add("checks", format!("CI {}: {ok} passed, {bad} failed, {} total", rollup.to_lowercase(), states.len()), "", &format!("{url}/checks"), "");
    }
    // New to us, not an old item that slid into the last-N window after a deletion.
    let fresh = |item: &Value, olds: &Value| -> bool {
        let oldest = olds.as_object().into_iter().flatten().map(|(_, o)| str(&o["created"])).filter(|c| !c.is_empty()).min();
        oldest.is_none_or(|oldest| str(&item["created"]) >= oldest)
    };
    for (cid, c) in new["comments"].as_object().into_iter().flatten() {
        let r#where = c["where"].as_str().map(|w| format!(" on {w}")).unwrap_or_default();
        let what = if c["kind"] == "review_comment" { "review comment" } else { "comment" };
        let author = str(&c["author"]);
        match old["comments"].get(cid) {
            None if fresh(c, &old["comments"]) => add(str(&c["kind"]), format!("{what}{where} by @{author}"), str(&c["body"]), str(&c["url"]), author),
            Some(prev) if prev["body"] != c["body"] => add(&format!("{}_edited", str(&c["kind"])), format!("{what}{where} edited by @{author}"), str(&c["body"]), str(&c["url"]), author),
            _ => {}
        }
    }
    for (rid, r) in new["reviews"].as_object().into_iter().flatten() {
        let (author, verdict) = (str(&r["author"]), lower(&r["state"]));
        match old["reviews"].get(rid) {
            // A review with no words of its own only holds inline comments, reported one by one.
            None if fresh(r, &old["reviews"]) && !(r["state"] == "COMMENTED" && str(&r["body"]).trim().is_empty()) =>
                add("review", format!("review by @{author}: {verdict}"), str(&r["body"]), str(&r["url"]), author),
            Some(prev) if prev["state"] != r["state"] => add("review", format!("review by @{author} is now {verdict}"), "", str(&r["url"]), author),
            Some(prev) if prev["body"] != r["body"] => add("review_edited", format!("review by @{author} edited"), str(&r["body"]), str(&r["url"]), author),
            _ => {}
        }
    }
    for (tid, t) in new["threads"].as_object().into_iter().flatten() {
        if let Some(prev) = old["threads"].get(tid) && prev["resolved"] != t["resolved"] {
            add("thread", format!("review thread on {} {}", str(&t["where"]), if t["resolved"] == true { "resolved" } else { "unresolved" }), "", str(&t["url"]), "");
        }
    }
    ev
}
