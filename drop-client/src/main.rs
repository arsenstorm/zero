//! zero — file-drop client, placed in a drop folder by Zero.app. Same commands and exit codes as the `zero`
//! CLI, over files: `asks/<id>.json` goes in, `answers/<id>.json` comes back. Anything that can write to a
//! folder the Mac sees reaches Arsen with it.
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, fs, process, thread};

const USAGE: &str = "usage:
  zero ask     \"question\" [--option A --option B ...] [--title T] [--body B] [--code 'snippet']
  zero approve \"what you want to do\" [--body B] [--code 'snippet']
  zero run     'command' --why \"what you need the output for\" [--cwd DIR] [--title T]
  zero note    \"where you are now\" [--blocked | --done]
  zero wait    <id>
  zero status  <id>
common: --async --agent NAME ($ZERO_AGENT) --ticket ID --ttl MINUTES
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

    /// Without ZERO_AGENT, the folder's two parent names: on a bench that reads "<bench>/<app>".
    fn agent(&self, args: &Args) -> Agent {
        let name = args
            .flag("agent")
            .cloned()
            .or_else(|| env::var("ZERO_AGENT").ok())
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
        };
        fs::create_dir_all(self.asks()).ok();
        fs::create_dir_all(self.answers()).ok();
        let tmp = self.asks().join(format!("{}.json.tmp", ask.id));
        fs::write(&tmp, serde_json::to_vec(&ask).unwrap()).unwrap_or_else(|e| fail(&format!("zero: cannot write ask: {e}"), 1));
        fs::rename(&tmp, self.asks().join(format!("{}.json", ask.id))).unwrap_or_else(|e| fail(&format!("zero: cannot write ask: {e}"), 1));
        ask
    }

    fn wait(&self, id: &str) -> ! {
        let path = self.answers().join(format!("{id}.json"));
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(48 * 3600) {
            if let Ok(data) = fs::read(&path) {
                if let Ok(ask) = serde_json::from_slice::<Ask>(&data) {
                    fs::remove_file(&path).ok();
                    finish(ask);
                }
            }
            thread::sleep(Duration::from_millis(500));
        }
        fail("expired", 3)
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

fn main() {
    let args = Args::parse();
    let drop = Drop::here();
    let first = || args.positional.first().cloned();
    match args.command.as_str() {
        "ask" => {
            let question = first().unwrap_or_else(|| fail(USAGE, 1));
            let options = args.flags.get("option").cloned().unwrap_or_default();
            let title = args.flag("title").cloned().unwrap_or_else(|| question.clone());
            let body = args.flag("body").cloned().unwrap_or_else(|| if title == question { String::new() } else { question.clone() });
            let kind = if options.is_empty() { "question" } else { "choice" };
            let ask = drop.create(&args, kind, title, body, options, args.flag("code").cloned(), None);
            submit(&drop, &args, ask)
        }
        "approve" => {
            let what = first().unwrap_or_else(|| fail(USAGE, 1));
            let options = vec!["Yes".into(), "No".into(), "Suggest something else…".into()];
            let ask = drop.create(&args, "approve", what, args.flag("body").cloned().unwrap_or_default(), options, args.flag("code").cloned(), None);
            submit(&drop, &args, ask)
        }
        "permission" => {
            // Claude Code's PermissionRequest hook input on stdin; the plugin's hook turns the exit code into its decision.
            let mut input = String::new();
            std::io::stdin().read_to_string(&mut input).ok();
            let (title, why, code, cwd) = permission(&input).unwrap_or_else(|| fail("zero: no permission request on stdin", 1));
            let options = vec!["Allow".into(), "Deny".into(), "Deny, and say why…".into()];
            let ask = drop.create(&args, "permission", title, why, options, Some(code), cwd);
            submit(&drop, &args, ask)
        }
        "run" => {
            let command = first().unwrap_or_else(|| fail(USAGE, 1));
            if args.flag("why").is_none() && args.flag("body").is_none() {
                fail("zero run needs --why: say what you need the output for, so Arsen knows what he is running", 1)
            }
            let options = vec!["Run".into(), "Reject".into(), "Suggest something else…".into()];
            let cwd = args.flag("cwd").cloned().or_else(|| env::current_dir().ok().map(|p| p.to_string_lossy().to_string()));
            let title = args.flag("title").cloned().unwrap_or_else(|| "Run a command".into());
            let why = args.flag("why").or(args.flag("body")).cloned().unwrap_or_default();
            let ask = drop.create(&args, "run", title, why, options, Some(command), cwd);
            submit(&drop, &args, ask)
        }
        "note" => {
            let text = first().unwrap_or_else(|| fail(USAGE, 1));
            drop.create(&args, "note", "Update".into(), text, vec![], None, None);
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
