//! zero — file-drop client, placed in a drop folder by Zero.app. Same commands and exit codes as the `zero`
//! CLI, over files: `asks/<id>.json` goes in, `answers/<id>.json` comes back. Anything that can write to a
//! folder the Mac sees reaches the user with it.
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, fs, process, thread};

const USAGE: &str = "usage:
  zero ask     \"short question?\" [--option A --option B ...] [--body \"details\"] [--title T] [--code 'snippet']
               the question is one line (about 12 words); the details the user may need go in --body
  zero approve \"what you want to do\" [--body B] [--code 'snippet']
  zero run     'command' --why \"what you need the output for\" [--cwd DIR] [--title T]
  zero note    \"where you are now\" [--blocked | --done]
  zero withdraw <id> [--reason \"why\"]   (take back an open ask that no longer needs the user)
  zero wait    <id>
  zero status  <id>
common: --async --agent NAME ($ZERO_AGENT) --ticket ID (shown as the ask's context) --ttl MINUTES --help
exit: 0 answered (answer on stdout; for run, its output and exit code), 2 declined, 3 expired";

#[derive(Serialize, Deserialize)]
struct Agent {
    name: String,
    host: String,
    cwd: Option<String>,
    #[serde(rename = "soloProcessID")]
    solo_process_id: Option<i64>,
    #[serde(rename = "soloProjectID", default)]
    solo_project_id: Option<i64>,
    ticket: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Ask {
    id: String,
    kind: String,
    title: String,
    body: String,
    options: Vec<String>,
    command: Option<String>,
    cwd: Option<String>,
    agent: Agent,
    #[serde(rename = "createdAt")]
    created_at: String,
    #[serde(rename = "expiresAt")]
    expires_at: String,
    state: String,
    output: String,
    #[serde(default)]
    answer: Option<String>,
    #[serde(rename = "exitCode", default)]
    exit_code: Option<i32>,
    #[serde(default)]
    status: Option<String>,
    /// False with --async: nothing waits for the answer, so Zero types it into the agent's session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    waits: Option<bool>,
    /// A question's supporting text, shown under it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    /// A run's script file, shown to the user beside the command.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    script: Option<String>,
}

fn fail(message: &str, code: i32) -> ! {
    eprintln!("{message}");
    process::exit(code)
}

/// ISO 8601 UTC without fractions, the form Zero's decoder accepts.
fn iso(secs_from_now: i64) -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64 + secs_from_now;
    let days = now.div_euclid(86_400);
    let rem = now.rem_euclid(86_400);
    // civil-from-days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

fn short_id() -> String {
    let alphabet: Vec<char> = "abcdefghjkmnpqrstuvwxyz23456789".chars().collect();
    let mut seed = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64 ^ (process::id() as u64) << 32;
    (0..6)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            alphabet[(seed % alphabet.len() as u64) as usize]
        })
        .collect()
}

fn hostname() -> String {
    fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "unknown".into())
}

struct Args {
    command: String,
    positional: Vec<String>,
    flags: HashMap<String, Vec<String>>,
}

impl Args {
    fn parse() -> Args {
        let mut raw = env::args().skip(1);
        let command = raw.next().unwrap_or_else(|| fail(USAGE, 1));
        let raw: Vec<String> = raw.collect();
        if matches!(command.as_str(), "help" | "--help" | "-h") || raw.iter().any(|a| a == "--help" || a == "-h") {
            println!("{USAGE}");
            process::exit(0)
        }
        let mut flags: HashMap<String, Vec<String>> = HashMap::new();
        let mut positional = Vec::new();
        let mut i = 0;
        while i < raw.len() {
            if let Some(key) = raw[i].strip_prefix("--") {
                if matches!(key, "async" | "blocked" | "done") {
                    flags.entry(key.into()).or_default().push("1".into());
                } else {
                    i += 1;
                    let value = raw.get(i).unwrap_or_else(|| fail(&format!("zero: missing value for --{key}"), 1));
                    flags.entry(key.into()).or_default().push(value.clone());
                }
            } else {
                positional.push(raw[i].clone());
            }
            i += 1;
        }
        Args { command, positional, flags }
    }
    fn flag(&self, key: &str) -> Option<&String> { self.flags.get(key).and_then(|v| v.last()) }
    fn has(&self, key: &str) -> bool { self.flags.contains_key(key) }
}

struct Drop {
    root: PathBuf,
}

impl Drop {
    fn here() -> Drop {
        let exe = env::current_exe().unwrap_or_else(|_| fail("zero: cannot locate myself", 1));
        let exe = fs::canonicalize(&exe).unwrap_or(exe);
        Drop { root: exe.parent().map(Path::to_path_buf).unwrap_or_else(|| ".".into()) }
    }
    fn asks(&self) -> PathBuf { self.root.join("asks") }
    fn answers(&self) -> PathBuf { self.root.join("answers") }

    /// Without ZERO_AGENT, the folder's two parent names: in a worktree that reads "<worktree>/<repo>".
    fn agent(&self, args: &Args) -> Agent {
        let name = args
            .flag("agent")
            .cloned()
            .or_else(|| env::var("ZERO_AGENT").ok())
            // An agent Solo runs on this Mac is known to Zero by its process, whichever folder it calls from.
            .or_else(|| env::var("SOLO_PROCESS_ID").ok().map(|id| format!("solo-{id}")))
            .unwrap_or_else(|| {
                let parent = self.root.parent();
                let leaf = |p: Option<&Path>| p.and_then(Path::file_name).map(|n| n.to_string_lossy().to_string());
                match (leaf(parent.and_then(Path::parent)), leaf(parent)) {
                    (Some(a), Some(b)) => format!("{a}/{b}"),
                    (_, Some(b)) => b,
                    _ => "drop".into(),
                }
            });
        Agent {
            name,
            host: hostname(),
            cwd: env::current_dir().ok().map(|p| p.to_string_lossy().to_string()),
            // Set when Solo started the agent on this Mac; Zero reaches its session through Solo.
            solo_process_id: env::var("SOLO_PROCESS_ID").ok().and_then(|id| id.parse().ok()),
            solo_project_id: env::var("SOLO_PROJECT_ID").ok().and_then(|id| id.parse().ok()),
            ticket: args.flag("ticket").cloned(),
        }
    }

    fn create(&self, args: &Args, kind: &str, title: String, body: String, options: Vec<String>, command: Option<String>, cwd: Option<String>) -> Ask {
        let ask = self.create_unsent(args, kind, title, body, options, command, cwd);
        self.send(&ask);
        ask
    }

    fn create_unsent(&self, args: &Args, kind: &str, title: String, body: String, options: Vec<String>, command: Option<String>, cwd: Option<String>) -> Ask {
        let ttl: f64 = args.flag("ttl").and_then(|t| t.parse().ok()).unwrap_or(0.0) * 60.0;
        let status = if kind == "note" {
            if args.has("blocked") { Some("blocked".into()) } else if args.has("done") { Some("done".into()) } else { None }
        } else {
            None
        };
        let ask = Ask {
            id: short_id(),
            kind: kind.into(),
            title,
            body,
            options,
            command,
            cwd,
            agent: self.agent(args),
            created_at: iso(0),
            expires_at: iso(ttl as i64),
            state: "waiting".into(),
            output: String::new(),
            answer: None,
            exit_code: None,
            status,
            waits: if args.has("async") { Some(false) } else { None },
            script: None,
            detail: None,
        };
        fs::create_dir_all(self.asks()).ok();
        fs::create_dir_all(self.answers()).ok();
        ask
    }

    /// Writes the ask atomically, so Zero never reads half a file.
    fn send(&self, ask: &Ask) {
        let tmp = self.asks().join(format!("{}.json.tmp", ask.id));
        fs::write(&tmp, serde_json::to_vec(&ask).unwrap()).unwrap_or_else(|e| fail(&format!("zero: cannot write ask: {e}"), 1));
        fs::rename(&tmp, self.asks().join(format!("{}.json", ask.id))).unwrap_or_else(|e| fail(&format!("zero: cannot write ask: {e}"), 1));
    }

    fn wait(&self, id: &str) -> ! {
        match self.wait_ask(id) {
            Some(ask) => finish(ask),
            None => fail("expired", 3),
        }
    }

    /// The answered ask, once its answer file lands; None after 48 hours.
    fn wait_ask(&self, id: &str) -> Option<Ask> {
        let path = self.answers().join(format!("{id}.json"));
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(48 * 3600) {
            if let Ok(data) = fs::read(&path) {
                if let Ok(ask) = serde_json::from_slice::<Ask>(&data) {
                    fs::remove_file(&path).ok();
                    return Some(ask);
                }
            }
            thread::sleep(Duration::from_millis(500));
        }
        None
    }
}

fn finish(ask: Ask) -> ! {
    match ask.state.as_str() {
        "answered" => {
            if ask.kind == "run" {
                let mut out = std::io::stdout();
                out.write_all(ask.output.as_bytes()).ok();
                out.flush().ok();
                process::exit(ask.exit_code.unwrap_or(0));
            }
            println!("{}", ask.answer.unwrap_or_default());
            process::exit(0)
        }
        "declined" => {
            // A text option answers as "label: text"; the agent gets just the text.
            let mut reason = ask.answer.unwrap_or_default();
            for label in ask.options.iter().map(|o| o.trim_end_matches(['…', '.', ' '])) {
                if !label.is_empty() && reason.starts_with(label) {
                    reason = reason[label.len()..].trim_start_matches([':', ' ']).to_string();
                }
            }
            fail(&if reason.is_empty() { "declined".to_string() } else { format!("declined: {reason}") }, 2)
        }
        "expired" => fail("expired", 3),
        other => fail(&format!("zero: unexpected state {other}"), 1),
    }
}

fn submit(drop: &Drop, args: &Args, ask: Ask) -> ! {
    if args.has("async") {
        println!("{}", ask.id);
        process::exit(0)
    }
    eprintln!("zero: waiting on ask {}", ask.id);
    drop.wait(&ask.id)
}

/// The ask a PermissionRequest hook input becomes, as Zero.app's `Ask.permission` builds it: what the tool will
/// do, why (the agent's latest words in its transcript), the command or target, and the folder.
fn permission(input: &str) -> Option<(String, String, String, Option<String>)> {
    let json: serde_json::Value = serde_json::from_str(input).ok()?;
    let tool = json["tool_name"].as_str()?;
    let field = |key: &str| json["tool_input"][key].as_str().map(str::to_string);
    let (what, code) = match tool {
        "Bash" => (field("description").map(|d| d.trim_end_matches('?').to_string()).unwrap_or_else(|| "Run a command".into()), field("command").unwrap_or_default()),
        "Write" => ("Write a file".into(), field("file_path").unwrap_or_default()),
        "Edit" | "MultiEdit" | "NotebookEdit" => ("Edit a file".into(), field("file_path").or_else(|| field("notebook_path")).unwrap_or_default()),
        "WebFetch" => ("Fetch a page".into(), field("url").unwrap_or_default()),
        other => (format!("Use {other}"), json["tool_input"].to_string()),
    };
    let why = json["transcript_path"].as_str().and_then(last_words).unwrap_or_default();
    Some((what, why, code.chars().take(2000).collect(), json["cwd"].as_str().map(str::to_string)))
}

/// The latest assistant text in a Claude Code transcript, trimmed to 500 characters.
fn last_words(path: &str) -> Option<String> {
    let data = fs::read(path).ok()?;
    let tail = &data[data.len().saturating_sub(400_000)..];
    String::from_utf8_lossy(tail).lines().rev().find_map(|line| {
        let entry: serde_json::Value = serde_json::from_str(line).ok()?;
        if entry["type"] != "assistant" { return None; }
        let text = entry["message"]["content"].as_array()?.iter().rev().find(|c| c["type"] == "text")?["text"].as_str()?.trim().to_string();
        if text.is_empty() { return None; }
        Some(if text.chars().count() > 500 { text.chars().take(500).collect::<String>() + "…" } else { text })
    })
}

/// A question or a request is the headline of its card; the reasoning behind it belongs in --body.
fn short_headline(text: &str) {
    let n = text.chars().count();
    if n > 140 {
        fail(&format!("zero: keep the question to one short line (about 12 words, ending in ?) and put the details in --body; this one is {n} characters"), 1)
    }
}

/// The text under a question is two or three plain sentences; anything longer goes in a file the agent links.
fn short_detail(text: Option<&String>, name: &str) {
    if let Some(text) = text {
        let n = text.chars().count();
        if n > 280 {
            fail(&format!("zero: keep --{name} to two or three plain sentences (280 characters; this is {n}): the problem, what you recommend and why. Put anything longer in a file and give its path"), 1)
        }
    }
}

/// The script a run executes, when it is a readable text file: `sh|bash|zsh <file> …` or `<file> …`.
fn script_of(command: &str, cwd: Option<&str>) -> Option<String> {
    let words: Vec<&str> = command.split_whitespace().collect();
    let first = *words.first()?;
    let path = if matches!(first, "sh" | "bash" | "zsh") { *words.get(1)? } else { first };
    if path.starts_with('-') { return None; }
    let full = if path.starts_with('/') { PathBuf::from(path) } else { PathBuf::from(cwd.unwrap_or(".")).join(path) };
    let text = fs::read_to_string(full).ok()?;
    Some(if text.chars().count() > 6000 { text.chars().take(6000).collect::<String>() + "\n…" } else { text })
}

fn main() {
    let args = Args::parse();
    let drop = Drop::here();
    let first = || args.positional.first().cloned();
    match args.command.as_str() {
        "ask" => {
            let question = first().unwrap_or_else(|| fail(USAGE, 1));
            short_headline(&question);
            short_detail(args.flag("body"), "body");
            let options = args.flags.get("option").cloned().unwrap_or_default();
            // Choices written into the question can only be answered by typing; as options they take one key.
            if options.is_empty() && (question.contains("(a)") && question.contains("(b)") || question.contains("(1)") && question.contains("(2)")) {
                fail("zero: put the choices in --option, one each (the first is the one you recommend), not as (a)/(b) in the question", 1)
            }
            let title = args.flag("title").or(args.flag("ticket")).cloned().unwrap_or_else(|| question.clone());
            let body = if title == question { String::new() } else { question.clone() };
            let kind = if options.is_empty() { "question" } else { "choice" };
            let mut ask = drop.create_unsent(&args, kind, title, body, options, args.flag("code").cloned(), None);
            ask.detail = args.flag("body").cloned();
            drop.send(&ask);
            submit(&drop, &args, ask)
        }
        "approve" => {
            let what = first().unwrap_or_else(|| fail(USAGE, 1));
            short_headline(&what);
            short_detail(args.flag("body"), "body");
            let options = vec!["Yes".into(), "No".into(), "Suggest something else…".into()];
            let ask = drop.create(&args, "approve", what, args.flag("body").cloned().unwrap_or_default(), options, args.flag("code").cloned(), None);
            submit(&drop, &args, ask)
        }
        "permission" => {
            // Claude Code's PermissionRequest hook input on stdin; the user's answer goes back as the hook's decision.
            // If the ask expires, nothing is printed and Claude Code's own permission flow carries on.
            let mut input = String::new();
            std::io::stdin().read_to_string(&mut input).ok();
            if serde_json::from_str::<serde_json::Value>(&input).ok().and_then(|j| j["tool_name"].as_str().map(str::to_string)).as_deref() == Some("AskUserQuestion") {
                process::exit(0) // answered by the question hook, as questions
            }
            let (title, why, code, cwd) = permission(&input).unwrap_or_else(|| fail("zero: no permission request on stdin", 1));
            let suggestions = serde_json::from_str::<serde_json::Value>(&input).ok()
                .and_then(|j| j.get("permission_suggestions").cloned())
                .filter(|s| s.as_array().map_or(false, |a| !a.is_empty()));
            let mut options: Vec<String> = vec!["Allow".into()];
            if suggestions.is_some() { options.push("Always allow".into()); }
            options.extend(["Deny".into(), "Deny, and say why…".into()]);
            let ask = drop.create(&args, "permission", title, why, options, Some(code), cwd);
            let done = drop.wait_ask(&ask.id).unwrap_or_else(|| process::exit(0));
            let decision = match done.state.as_str() {
                "answered" => {
                    let mut d = serde_json::json!({"behavior": "allow"});
                    if done.answer.as_deref() == Some("Always allow") { if let Some(s) = suggestions { d["updatedPermissions"] = s; } }
                    d
                }
                "declined" => {
                    let reason = done.answer.unwrap_or_default();
                    let reason = reason.split_once(": ").map(|(_, r)| r.to_string()).unwrap_or_default();
                    let message = if reason.is_empty() { "The user said no in Zero".to_string() } else { format!("The user said no in Zero: {reason}") };
                    serde_json::json!({"behavior": "deny", "message": message})
                }
                _ => process::exit(0),
            };
            println!("{}", serde_json::json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}));
            process::exit(0)
        }
        "question" => {
            // Claude Code's PreToolUse hook input for AskUserQuestion: each question becomes a Zero question and the
            // answers go back as the tool's input. Anything short of all answers prints nothing.
            let mut raw = String::new();
            std::io::stdin().read_to_string(&mut raw).ok();
            let hook: serde_json::Value = serde_json::from_str(&raw).unwrap_or_else(|_| process::exit(0));
            let mut input = hook["tool_input"].clone();
            let questions = input["questions"].as_array().cloned().unwrap_or_default();
            if questions.is_empty() { process::exit(0) }
            let mut answers = serde_json::Map::new();
            for item in questions {
                let question = item["question"].as_str().unwrap_or_else(|| process::exit(0)).to_string();
                let opts = item["options"].as_array().cloned().unwrap_or_default();
                let labels: Vec<String> = opts.iter().filter_map(|o| o["label"].as_str().map(str::to_string)).collect();
                let details: Vec<String> = opts.iter().filter_map(|o| {
                    let (l, d) = (o["label"].as_str()?, o["description"].as_str()?);
                    if d.is_empty() { None } else { Some(format!("{l}: {d}")) }
                }).collect();
                let several = item["multiSelect"].as_bool() == Some(true);
                let mut options = labels.clone();
                options.push(if several { "Several, or something else…".into() } else { "Something else…".into() });
                let title = item["header"].as_str().map(str::to_string).unwrap_or_else(|| question.clone());
                let cwd = hook["cwd"].as_str().map(str::to_string);
                let mut ask = drop.create_unsent(&args, "choice", title, question.clone(), options, None, cwd);
                if !details.is_empty() { ask.detail = Some(details.join("\n")); }
                drop.send(&ask);
                let done = drop.wait_ask(&ask.id).unwrap_or_else(|| process::exit(0));
                if done.state != "answered" { process::exit(0) }
                let answer = done.answer.unwrap_or_default();
                let value = if labels.contains(&answer) { answer } else { answer.split_once(": ").map(|(_, t)| t.to_string()).unwrap_or(answer) };
                answers.insert(question, serde_json::Value::String(value));
            }
            input["answers"] = serde_json::Value::Object(answers);
            println!("{}", serde_json::json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input}}));
            process::exit(0)
        }
        "withdraw" => {
            let id = first().unwrap_or_else(|| fail(USAGE, 1));
            fs::create_dir_all(drop.asks()).ok();
            fs::write(drop.asks().join(format!("{id}.withdraw")), args.flag("reason").cloned().unwrap_or_default())
                .unwrap_or_else(|e| fail(&format!("zero: {e}"), 1));
        }
        "run" => {
            let command = first().unwrap_or_else(|| fail(USAGE, 1));
            short_detail(args.flag("why").or(args.flag("body")), "why");
            if args.flag("why").is_none() && args.flag("body").is_none() {
                fail("zero run needs --why: say what you need the output for, so the user knows what they are running", 1)
            }
            let options = vec!["Run".into(), "Reject".into(), "Suggest something else…".into()];
            let cwd = args.flag("cwd").cloned().or_else(|| env::current_dir().ok().map(|p| p.to_string_lossy().to_string()));
            let title = args.flag("title").cloned().unwrap_or_else(|| "Run a command".into());
            let why = args.flag("why").or(args.flag("body")).cloned().unwrap_or_default();
            let script = script_of(&command, cwd.as_deref());
            let mut ask = drop.create_unsent(&args, "run", title, why, options, Some(command), cwd);
            ask.script = script;
            drop.send(&ask);
            submit(&drop, &args, ask)
        }
        "note" => {
            let text = first().unwrap_or_else(|| fail(USAGE, 1));
            drop.create(&args, "note", args.flag("ticket").cloned().unwrap_or_else(|| "Update".into()), text, vec![], None, None);
        }
        "wait" => drop.wait(&first().unwrap_or_else(|| fail(USAGE, 1))),
        "status" => {
            let id = first().unwrap_or_else(|| fail(USAGE, 1));
            let path = drop.answers().join(format!("{id}.json"));
            let state = fs::read(&path).ok().and_then(|d| serde_json::from_slice::<Ask>(&d).ok()).map(|a| a.state);
            println!("{}", state.unwrap_or_else(|| "waiting".into()));
        }
        _ => fail(USAGE, 1),
    }
}
