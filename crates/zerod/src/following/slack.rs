//! `slack/<channel-id>[/<thread-ts>]`: a Slack thread (replies, edits, deletions, reactions), or a whole channel (new
//! messages, and new replies in its recently active threads, published on each thread's topic so a thread's follower
//! hears them too). Read on the Slack connection Zero's integration keeps; the names of people and channels are
//! looked up once each.

use std::collections::{BTreeMap, HashMap};
use std::hash::{Hash, Hasher};
use std::sync::{Mutex, OnceLock};

use serde_json::{Map, Value, json};

use super::{Event, Poll, first_line};
use crate::integrations::Integrations;

fn is_channel(id: &str) -> bool { id.len() >= 7 && matches!(id.chars().next(), Some('C' | 'D' | 'G')) && id.chars().all(|c| c.is_ascii_alphanumeric()) }

fn is_ts(ts: &str) -> bool { ts.len() == 17 && ts.as_bytes()[10] == b'.' && ts.chars().enumerate().all(|(i, c)| i == 10 || c.is_ascii_digit()) }

/// `p1712345678123456` as Slack's links write a message's time, to `1712345678.123456`.
fn ts_from_p(p: &str) -> Option<String> {
    let digits = p.strip_prefix('p')?;
    (digits.len() == 16 && digits.chars().all(|c| c.is_ascii_digit())).then(|| format!("{}.{}", &digits[..10], &digits[10..]))
}

pub fn normalize(parts: &[&str]) -> Result<Vec<String>, String> {
    let (channel, thread) = match parts { [channel] => (channel, None), [channel, thread] => (channel, Some(thread)), _ => return Err("expected slack/<channel-id> or slack/<channel-id>/<thread-ts>".into()) };
    let channel = channel.to_uppercase();
    if !is_channel(&channel) { return Err("expected slack/<channel-id> or slack/<channel-id>/<thread-ts>".into()) }
    let mut out = vec![channel];
    if let Some(thread) = thread {
        let ts = ts_from_p(thread).unwrap_or_else(|| thread.to_string());
        if !is_ts(&ts) { return Err(format!("bad thread ts {thread:?}; expected like 1712345678.123456")) }
        out.push(ts);
    }
    Ok(out)
}

/// `https://<ws>.slack.com/archives/<channel>/p<ts>?thread_ts=<ts>`: a message's thread (a reply's link names it).
pub fn from_url(url: &str) -> Option<String> {
    let rest = url.trim().strip_prefix("https://").or_else(|| url.trim().strip_prefix("http://"))?;
    let (host, path) = rest.split_once('/')?;
    if !host.ends_with("slack.com") { return None }
    let path = path.strip_prefix("archives/")?;
    let (path, query) = path.split_once('?').unwrap_or((path, ""));
    let mut parts = path.split('/');
    let channel = parts.next().filter(|c| is_channel(&c.to_uppercase()))?.to_uppercase();
    let Some(message) = parts.next().and_then(ts_from_p) else { return Some(format!("slack/{channel}")) };
    let thread = query.split('&').find_map(|pair| pair.strip_prefix("thread_ts=")).filter(|ts| is_ts(ts)).unwrap_or(&message);
    Some(format!("slack/{channel}/{thread}"))
}

fn str(v: &Value) -> &str { v.as_str().unwrap_or("") }

fn short_hash(text: &str) -> String {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

fn names() -> &'static Mutex<HashMap<String, String>> {
    static NAMES: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    NAMES.get_or_init(Default::default)
}

/// Who a user id is, asked of Slack once; the id itself when Slack won't say.
async fn user_name(integrations: &Integrations, id: &str) -> String {
    if let Some(name) = names().lock().unwrap().get(id) { return name.clone() }
    let Ok(reply) = integrations.slack("users.info", &[("user", id)]).await else { return id.to_string() };
    let user = &reply["user"];
    let name = [&user["profile"]["display_name"], &user["real_name"], &user["name"]].into_iter().map(str).find(|n| !n.is_empty()).unwrap_or(id).to_string();
    names().lock().unwrap().insert(id.into(), name.clone());
    name
}

async fn channel_name(integrations: &Integrations, id: &str) -> String {
    if let Some(name) = integrations.slack_channel_name(id) { return format!("#{name}") }
    if let Some(name) = names().lock().unwrap().get(id) { return name.clone() }
    let Ok(reply) = integrations.slack("conversations.info", &[("channel", id)]).await else { return id.to_string() };
    let channel = &reply["channel"];
    let name = match channel["name"].as_str() { Some(name) => format!("#{name}"), None if channel["is_im"] == true => "DM".into(), None => id.to_string() };
    names().lock().unwrap().insert(id.into(), name.clone());
    name
}

async fn author(integrations: &Integrations, m: &Value) -> String {
    match m["user"].as_str() {
        Some(user) => user_name(integrations, user).await,
        None => [&m["bot_profile"]["name"], &m["username"]].into_iter().map(str).find(|n| !n.is_empty()).unwrap_or("bot").to_string(),
    }
}

/// Slack's mrkdwn as plain text: people named, links unwrapped, channels and entities plain.
async fn render(integrations: &Integrations, text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(open) = rest.find('<') {
        out.push_str(&rest[..open]);
        let Some(close) = rest[open..].find('>') else { out.push_str(&rest[open..]); rest = ""; break };
        let inside = &rest[open + 1..open + close];
        let (target, label) = inside.split_once('|').map(|(t, l)| (t, Some(l))).unwrap_or((inside, None));
        if let Some(user) = target.strip_prefix('@') { out.push('@'); out.push_str(&user_name(integrations, user).await) }
        else if let Some(channel) = target.strip_prefix('#') { out.push('#'); out.push_str(label.unwrap_or(channel)) }
        else if let Some(command) = target.strip_prefix('!') { out.push('@'); out.push_str(command) }
        else if let Some(label) = label { out.push_str(&format!("{label} ({target})")) }
        else { out.push_str(target) }
        rest = &rest[open + close + 1..];
    }
    out.push_str(rest);
    out.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

/// A message's words: its text, then what its attachments say (a GitHub notification is all attachment, its text
/// empty), as Slack renders them.
async fn words(integrations: &Integrations, m: &Value) -> String {
    let mut parts = vec![render(integrations, str(&m["text"])).await];
    for a in m["attachments"].as_array().into_iter().flatten() {
        let said = [&a["fallback"], &a["title"], &a["text"]].into_iter().map(str).find(|t| !t.is_empty()).unwrap_or("");
        if !said.is_empty() { parts.push(render(integrations, said).await) }
    }
    parts.into_iter().filter(|p| !p.trim().is_empty()).collect::<Vec<_>>().join("\n")
}

/// Whether a message names something to act on: a pull request (#42), a ticket (ABC-123) or a link. One that
/// doesn't continues its sender's last one that did.
pub fn cites(text: &str) -> bool {
    if text.contains("http://") || text.contains("https://") { return true }
    let chars: Vec<char> = text.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        if c == '#' && chars.get(i + 1).is_some_and(|d| d.is_ascii_digit()) { return true }
        if c == '-' && i > 0 && chars[i - 1].is_ascii_uppercase() && chars.get(i + 1).is_some_and(|d| d.is_ascii_digit()) {
            let start = chars[..i].iter().rposition(|c| !c.is_ascii_uppercase() && !c.is_ascii_digit()).map_or(0, |p| p + 1);
            if chars[start..i].iter().any(|c| c.is_ascii_uppercase()) { return true }
        }
    }
    false
}

/// Who sent a message, as a key: the user, or the bot's name (one deploy bot per environment).
fn sender(m: &Value) -> String { [&m["user"], &m["username"], &m["bot_profile"]["name"], &m["bot_id"]].into_iter().map(str).find(|s| !s.is_empty()).unwrap_or("?").to_string() }

/// How long a sender's message that names nothing is read as continuing their last that did.
const CONTINUES_FOR: f64 = 30.0 * 60.0;

fn permalink(domain: &str, channel: &str, ts: &str, thread: Option<&str>) -> String {
    let link = format!("https://{domain}.slack.com/archives/{channel}/p{}", ts.replace('.', ""));
    match thread { Some(thread) if thread != ts => format!("{link}?thread_ts={thread}&cid={channel}"), _ => link }
}

async fn replies(integrations: &Integrations, channel: &str, thread: &str, oldest: Option<&str>) -> Result<Vec<Value>, String> {
    let (mut out, mut cursor) = (vec![], String::new());
    loop {
        let mut params = vec![("channel", channel), ("ts", thread), ("limit", "200")];
        if let Some(oldest) = oldest { params.push(("oldest", oldest)) }
        if !cursor.is_empty() { params.push(("cursor", &cursor)) }
        let page = integrations.slack("conversations.replies", &params).await?;
        out.extend(page["messages"].as_array().cloned().unwrap_or_default());
        cursor = page["response_metadata"]["next_cursor"].as_str().unwrap_or("").to_string();
        if cursor.is_empty() || out.len() > 2000 { return Ok(out) }
    }
}

fn ts_of(m: &Value) -> f64 { str(&m["ts"]).parse().unwrap_or(0.0) }

/// A thread's reading: each message's author, text hash, edit time and reactions, and the first line of its root.
pub fn thread_snapshot(messages: &[Value]) -> Value {
    let mut msgs = Map::new();
    for m in messages {
        let reactions: Map<String, Value> = m["reactions"].as_array().into_iter().flatten().map(|r| (str(&r["name"]).to_string(), r["count"].clone())).collect();
        msgs.insert(str(&m["ts"]).into(), json!({"user": m["user"], "hash": short_hash(str(&m["text"])), "edited": m["edited"]["ts"], "reactions": reactions}));
    }
    json!({"msgs": msgs, "root_text": messages.first().map(|m| first_line(str(&m["text"]), 80))})
}

/// `place` is the team's domain, the channel and the thread.
pub fn thread_events(old: &Value, messages: &[Value], who: &dyn Fn(&Value) -> String, text: &dyn Fn(&Value) -> String, me: &str, place: (&str, &str, &str)) -> Vec<Event> {
    let (domain, channel, thread) = place;
    let topic = format!("slack/{channel}/{thread}");
    let (new, old) = (thread_snapshot(messages), &old["msgs"]);
    let mut ev = vec![];
    for m in messages {
        let ts = str(&m["ts"]);
        let (cur, prev) = (&new["msgs"][ts], &old[ts]);
        let (name, url, mine) = (who(m), permalink(domain, channel, ts, Some(thread)), !me.is_empty() && m["user"] == me);
        if prev.is_null() {
            ev.push(Event { topic: topic.clone(), kind: "message".into(), summary: format!("reply by {name}"), body: text(m), url, actor: name, mine, dedupe: Some(format!("msg:{ts}")), ..Default::default() });
            continue;
        }
        if prev["hash"] != cur["hash"] {
            ev.push(Event { topic: topic.clone(), kind: "message_edited".into(), summary: format!("message by {name} edited"), body: text(m), url: url.clone(), actor: name.clone(), mine, ..Default::default() });
        }
        for (reaction, count) in cur["reactions"].as_object().into_iter().flatten() {
            if count.as_u64().unwrap_or(0) > prev["reactions"][reaction].as_u64().unwrap_or(0) {
                ev.push(Event { topic: topic.clone(), kind: "reaction".into(), summary: format!(":{reaction}: added to message by {name}"), body: first_line(&text(m), 80), url: url.clone(), ..Default::default() });
            }
        }
        for (reaction, _) in prev["reactions"].as_object().into_iter().flatten() {
            if cur["reactions"].get(reaction).is_none() {
                ev.push(Event { topic: topic.clone(), kind: "reaction".into(), summary: format!(":{reaction}: removed from message by {name}"), url: url.clone(), ..Default::default() });
            }
        }
    }
    for (ts, _) in old.as_object().into_iter().flatten() {
        if new["msgs"].get(ts).is_none() { ev.push(Event { topic: topic.clone(), kind: "message_deleted".into(), summary: "a message in the thread was deleted".into(), ..Default::default() }) }
    }
    ev
}

async fn poll_thread(integrations: &Integrations, channel: &str, thread: &str, state: Option<&Value>) -> Result<Poll, String> {
    let messages = replies(integrations, channel, thread, None).await?;
    if messages.is_empty() { return Err(format!("Slack thread {channel}/{thread} not found")) }
    let (team, me) = integrations.slack_team().ok_or("Slack isn't connected")?;
    // Names and texts first (they ask Slack), so the diff itself needs nothing.
    let mut whos = HashMap::new();
    let mut texts = HashMap::new();
    for m in &messages { whos.insert(str(&m["ts"]).to_string(), author(integrations, m).await); texts.insert(str(&m["ts"]).to_string(), words(integrations, m).await); }
    let root = &messages[0];
    let summary = format!("{} thread by {}: {} {}", channel_name(integrations, channel).await, whos[str(&root["ts"])], first_line(&texts[str(&root["ts"])], 80), permalink(&team.domain, channel, thread, None));
    let events = match state {
        Some(old) => thread_events(old, &messages, &|m| whos[str(&m["ts"])].clone(), &|m| texts[str(&m["ts"])].clone(), &me, (&team.domain, channel, thread)),
        None => vec![],
    };
    Ok(Poll { state: thread_snapshot(&messages), events, summary })
}

async fn poll_channel(integrations: &Integrations, channel: &str, state: Option<&Value>) -> Result<Poll, String> {
    let history = integrations.slack("conversations.history", &[("channel", channel), ("limit", "100")]).await?;
    let (team, me) = integrations.slack_team().ok_or("Slack isn't connected")?;
    let messages = history["messages"].as_array().cloned().unwrap_or_default();
    let mut top: Vec<&Value> = messages.iter().filter(|m| m["thread_ts"].is_null() || m["thread_ts"] == m["ts"]).collect();
    top.sort_by(|a, b| ts_of(a).total_cmp(&ts_of(b)));
    let was_latest = state.map(|s| str(&s["latest"]).to_string()).unwrap_or_else(|| "0".into());
    let latest = top.last().map(|m| str(&m["ts"])).filter(|ts| ts.parse::<f64>().unwrap_or(0.0) > was_latest.parse().unwrap_or(0.0)).unwrap_or(&was_latest).to_string();
    let threads: BTreeMap<String, String> = top.iter().filter_map(|m| m["latest_reply"].as_str().map(|last| (str(&m["ts"]).to_string(), last.to_string()))).collect();
    let name = channel_name(integrations, channel).await;
    let summary = if top.is_empty() { name.clone() } else { format!("{name} {}", permalink(&team.domain, channel, &latest, None)) };
    // Each sender's last message naming something, so that one naming nothing is read as its continuation; from
    // the last reading, then from what's older here (a baseline knows the deploy under way), kept for two hours.
    let mut named: BTreeMap<String, (f64, String)> = state.and_then(|s| s["named"].as_object()).into_iter().flatten()
        .filter_map(|(k, v)| Some((k.clone(), (v[0].as_f64()?, str(&v[1]).to_string())))).collect();
    for m in top.iter().filter(|m| ts_of(m) <= was_latest.parse().unwrap_or(0.0) || state.is_none()) {
        let text = words(integrations, m).await;
        if cites(&text) && named.get(&sender(m)).is_none_or(|(at, _)| *at < ts_of(m)) { named.insert(sender(m), (ts_of(m), text)); }
    }
    let newest = top.last().map(|m| ts_of(m)).unwrap_or(0.0);
    named.retain(|_, (at, _)| newest - *at <= 4.0 * CONTINUES_FOR);
    let Some(old) = state else { return Ok(Poll { state: json!({"latest": latest, "threads": threads, "named": named}), events: vec![], summary }) };

    let topic = format!("slack/{channel}");
    let mut ev = vec![];
    for m in &top {
        if ts_of(m) <= was_latest.parse().unwrap_or(0.0) { continue }
        let (who, ts, text) = (author(integrations, m).await, str(&m["ts"]), words(integrations, m).await);
        let after = if cites(&text) { None } else { named.get(&sender(m)).filter(|(at, _)| ts_of(m) - at <= CONTINUES_FOR).map(|(_, text)| text.clone()) };
        if cites(&text) { named.insert(sender(m), (ts_of(m), text.clone())); }
        ev.push(Event { topic: topic.clone(), kind: "message".into(), summary: format!("message by {who} in {name}"), body: text,
                        url: permalink(&team.domain, channel, ts, None), actor: who, mine: !me.is_empty() && m["user"] == me, dedupe: Some(format!("msg:{ts}")), root: None, after });
    }
    for (ts, last) in &threads {
        // A brand-new message: all its replies are new.
        let seen = old["threads"][ts].as_str().unwrap_or(ts).to_string();
        if last.parse::<f64>().unwrap_or(0.0) <= seen.parse::<f64>().unwrap_or(0.0) { continue }
        let root = top.iter().find(|m| str(&m["ts"]) == ts).map(|m| str(&m["text"])).unwrap_or("");
        let root = render(integrations, root).await;
        for r in replies(integrations, channel, ts, Some(&seen)).await? {
            if str(&r["ts"]) == ts || ts_of(&r) <= seen.parse::<f64>().unwrap_or(0.0) { continue }
            let (who, rts) = (author(integrations, &r).await, str(&r["ts"]).to_string());
            ev.push(Event { topic: format!("{topic}/{ts}"), kind: "message".into(), summary: format!("reply by {who} in {name} thread"), body: words(integrations, &r).await,
                            url: permalink(&team.domain, channel, &rts, Some(ts)), actor: who, mine: !me.is_empty() && r["user"] == me, dedupe: Some(format!("msg:{rts}")), root: Some(root.clone()), after: None });
        }
    }
    // Threads that scrolled out of the last hundred messages stay known for a while.
    let mut merged: BTreeMap<String, String> = old["threads"].as_object().into_iter().flatten().map(|(k, v)| (k.clone(), str(v).to_string())).collect();
    merged.extend(threads);
    if merged.len() > 500 {
        let mut by_time: Vec<(String, String)> = merged.into_iter().collect();
        by_time.sort_by(|a, b| a.1.parse::<f64>().unwrap_or(0.0).total_cmp(&b.1.parse::<f64>().unwrap_or(0.0)));
        merged = by_time.into_iter().rev().take(500).collect();
    }
    Ok(Poll { state: json!({"latest": latest, "threads": merged, "named": named}), events: ev, summary })
}

pub async fn poll(integrations: &Integrations, key: &[&str], state: Option<&Value>) -> Result<Poll, String> {
    match key { [channel, thread] => poll_thread(integrations, channel, thread, state).await, [channel] => poll_channel(integrations, channel, state).await, _ => Err("bad Slack topic".into()) }
}
