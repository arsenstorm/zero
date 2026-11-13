//! A task's own changes coming back: what a step of its did to something followed (an issue moved, a pull request
//! merged or commented on, a branch pushed, a message posted), read from the step, so that the event its next poll
//! finds for it is told as the task's own, quietly, rather than waking it. Every source goes through `matches`.

use serde_json::Value;

use super::{Event, github, linear};
use crate::model::ItemKind;

/// What one step did: events of `kinds` on `topic` (or under it; a `*` segment is any), with what they must say.
#[derive(Clone, Debug, PartialEq)]
pub struct Touch {
    pub topic: String,
    pub kinds: Vec<&'static str>,
    /// The value a field was set to: the event's summary ends `→ <to>`.
    pub to: Option<String>,
    /// What it wrote, as words, its first 80 characters: the event's text starts the same.
    pub text: Option<String>,
}

impl Touch {
    fn new(topic: String, kinds: &[&'static str]) -> Touch {
        Touch { topic, kinds: kinds.to_vec(), to: None, text: None }
    }
    fn to(mut self, to: Option<&str>) -> Touch {
        self.to = to.filter(|t| !t.trim().is_empty()).map(|t| t.trim().to_lowercase());
        self
    }
    fn text(mut self, text: Option<&str>) -> Touch {
        self.text = text.map(words).filter(|t| !t.is_empty()).map(|t| t.chars().take(80).collect());
        self
    }
}

/// Whether `event` is what `touch` did.
pub fn matches(touch: &Touch, event: &Event) -> bool {
    let (pattern, topic): (Vec<&str>, Vec<&str>) = (touch.topic.split('/').collect(), event.topic.split('/').collect());
    pattern.len() <= topic.len()
        && pattern.iter().zip(&topic).all(|(p, t)| *p == "*" || p.eq_ignore_ascii_case(t))
        && touch.kinds.contains(&event.kind.as_str())
        && touch.to.as_ref().is_none_or(|to| event.summary.to_lowercase().trim_end().ends_with(&format!("→ {to}")))
        && touch.text.as_ref().is_none_or(|text| words(&event.body).chars().take(80).collect::<String>() == *text)
}

/// A text as its words, lowercased: markdown and spacing as a service keeps them don't count.
fn words(text: &str) -> String {
    text.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ").to_lowercase()
}

/// What a step did to things that can be followed.
pub fn touches(kind: &ItemKind) -> Vec<Touch> {
    match kind {
        ItemKind::Command { command, .. } => command.split(['\n', ';', '|', '&']).flat_map(|part| shell(&split(part))).collect(),
        ItemKind::Tool { name, detail, .. } => {
            let args: Value = serde_json::from_str(detail).unwrap_or(Value::Null);
            if !args.is_object() {
                return vec![];
            }
            let name = name.to_lowercase();
            if name.contains("linear") {
                linear_tool(&name, &args)
            } else if name.contains("slack") {
                slack_tool(&args)
            } else {
                github_tool(&name, &args)
            }
        }
        _ => vec![],
    }
}

fn str<'a>(args: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|k| args[k].as_str())
}

/// Linear's MCP tools: an issue saved (`id` and the fields set), a comment written (`issueId`, `body`).
fn linear_tool(name: &str, args: &Value) -> Vec<Touch> {
    let Some(issue) = str(args, &["issueId", "id", "identifier", "issue"]).filter(|id| linear::is_issue(id)) else { return vec![] };
    let topic = format!("linear/{}", issue.to_uppercase());
    if name.contains("comment") {
        return vec![Touch::new(topic, &["comment", "comment_edited"]).text(str(args, &["body"]))];
    }
    const FIELDS: [(&str, &str); 12] = [
        ("state", "state"),
        ("title", "title"),
        ("assignee", "assignee"),
        ("priority", "priority"),
        ("project", "project"),
        ("cycle", "cycle"),
        ("estimate", "estimate"),
        ("dueDate", "due"),
        ("parentId", "parent"),
        ("parent", "parent"),
        ("labels", "labels"),
        ("description", "description"),
    ];
    FIELDS
        .iter()
        .filter(|(arg, _)| !args[arg].is_null())
        .map(|(arg, kind)| {
            let touch = Touch::new(topic.clone(), &[kind]);
            if ["state", "title"].contains(kind) { touch.to(args[arg].as_str()) } else { touch }
        })
        .collect()
}

/// Slack's: a message posted to a channel (`channel_id`, `text`), its thread's or its own.
fn slack_tool(args: &Value) -> Vec<Touch> {
    let Some(channel) = str(args, &["channel_id", "channel", "channelId"]) else { return vec![] };
    let text = str(args, &["text", "message", "markdown_text", "payload"]);
    vec![Touch::new(format!("slack/{}", channel.to_uppercase()), &["message", "message_edited"]).text(text)]
}

/// GitHub's: one naming a pull request (`owner`, `repo`, its number) merged, commented on, reviewed or edited; files
/// pushed to a branch.
fn github_tool(name: &str, args: &Value) -> Vec<Touch> {
    if name.contains("push") || name.contains("create_or_update_file") {
        return vec![Touch::new("github".into(), &["push"])];
    }
    let (Some(owner), Some(repo)) = (str(args, &["owner"]), str(args, &["repo"])) else { return vec![] };
    let number = ["pullNumber", "pull_number", "issue_number", "number"].iter().find_map(|k| args[k].as_u64());
    let Some(number) = number else { return vec![] };
    let topic = format!("github/{}/{}/{number}", owner.to_lowercase(), repo.to_lowercase());
    let body = str(args, &["body"]);
    let kinds: &[&'static str] = if name.contains("merge") {
        &["merged"]
    } else if name.contains("review") {
        &["review", "review_comment"]
    } else if name.contains("comment") {
        &["comment"]
    } else if name.contains("update") {
        &EDITS
    } else {
        return vec![];
    };
    vec![Touch::new(topic, kinds).text(body)]
}

const EDITS: [&str; 7] = ["title", "description", "labels", "assignees", "reviewers", "base", "draft"];

/// A command's words, quotes taken off: `gh pr comment 7 --body 'Merged, thanks'`.
/// ponytail: quotes and backslashes only; no expansions or heredocs, which leave a step unmatched (it wakes).
fn split(command: &str) -> Vec<String> {
    let (mut out, mut word, mut quote, mut any) = (vec![], String::new(), None, false);
    let mut chars = command.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (None, '\'' | '"') => (quote, any) = (Some(c), true),
            (None, c) if c.is_whitespace() => {
                if any {
                    out.push(std::mem::take(&mut word));
                    any = false
                }
            }
            (q, '\\') if q != Some('\'') => {
                word.extend(chars.next());
                any = true
            }
            (_, c) => {
                word.push(c);
                any = true
            }
        }
    }
    if any {
        out.push(word)
    }
    out
}

/// `gh pr merge|close|reopen|ready|comment|review|edit <number or link>`, and `git push`.
fn shell(words: &[String]) -> Vec<Touch> {
    let at = |a: &str, b: &str| words.windows(2).position(|w| w[0] == a && w[1] == b);
    if at("git", "push").is_some() {
        return vec![Touch::new("github".into(), &["push"])];
    }
    let Some(at) = at("gh", "pr") else { return vec![] };
    let words = &words[at + 2..];
    let Some(verb) = words.first() else { return vec![] };
    let kinds: &[&'static str] = match verb.as_str() {
        "merge" => &["merged"],
        "close" => &["closed"],
        "reopen" => &["reopened"],
        "ready" => &["draft"],
        "comment" => &["comment"],
        "review" => &["review", "review_comment"],
        "edit" => &EDITS,
        _ => return vec![],
    };
    let flag = |names: &[&str]| words.iter().position(|w| names.contains(&w.as_str())).and_then(|i| words.get(i + 1));
    let mut repo = flag(&["-R", "--repo"]).map(|r| r.trim_end_matches(".git").to_lowercase());
    let mut number = None;
    for word in &words[1..] {
        if let Some(topic) = github::from_url(word) {
            let parts: Vec<&str> = topic.split('/').collect();
            repo = Some(format!("{}/{}", parts[1], parts[2]).to_lowercase());
            number = Some(parts[3].to_string());
        } else if number.is_none() && !word.is_empty() && word.chars().all(|c| c.is_ascii_digit()) {
            number = Some(word.clone())
        }
    }
    let Some(number) = number else { return vec![] };
    let topic = format!("github/{}/{number}", repo.filter(|r| r.contains('/')).unwrap_or_else(|| "*/*".into()));
    vec![Touch::new(topic, kinds).text(flag(&["-b", "--body"]).map(String::as_str))]
}
