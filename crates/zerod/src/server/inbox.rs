//! The inbox over the socket: asks made, answered and taken back, the agents' terminals, and a task's asks through
//! Zero's own tools.

use serde_json::{Value, json};

use super::{Request, Settings, Zerod, unknown};
use crate::ask::{AgentIdentity, Ask, AskKind};
use crate::model::Conversation;

pub(super) async fn handle(zerod: &Zerod, request: Request) -> Result<Value, String> {
    let inbox = &zerod.inbox;
    match request.op.as_str() {
        "agentAsk" => agent_ask(zerod, &request),
        "create" => {
            let mut incoming: Ask =
                serde_json::from_value(request.ask.clone().ok_or("Create which ask?")?).map_err(|e| format!("Not an ask: {e}"))?;
            inbox.admit(&mut incoming)?;
            Ok(json!(inbox.create(incoming, request.keep.unwrap_or(false))))
        }
        "asks" => Ok(json!(inbox.asks())),
        "choose" => {
            inbox.choose(&request.ask()?, request.option()?);
            Ok(Value::Null)
        }
        "answerAsk" => {
            inbox.answer(&request.ask()?, request.option()?, request.text.as_deref().unwrap_or(""));
            Ok(Value::Null)
        }
        "reply" => {
            inbox.reply(&request.ask()?, request.text.as_deref().ok_or("Reply with text")?);
            Ok(Value::Null)
        }
        "takeBack" => Ok(json!(inbox.take_back(&request.ask()?))),
        "withdraw" => {
            inbox.withdraw(&request.ask()?, request.text.as_deref());
            Ok(Value::Null)
        }
        "dismiss" => {
            inbox.dismiss(&request.ask()?);
            Ok(Value::Null)
        }
        "cancelRun" => {
            inbox.cancel_run(&request.ask()?);
            Ok(Value::Null)
        }
        "deliver" => {
            inbox.deliver_answer(&request.ask()?);
            Ok(Value::Null)
        }
        "message" => inbox.message(request.text.as_deref().ok_or("Message with text")?, &request.agent()?).await.map(|_| Value::Null),
        "close" => {
            inbox.close_agent(&request.agent()?, request.stop.unwrap_or(true));
            Ok(Value::Null)
        }
        "switchModel" => {
            inbox.switch_model(&request.agent()?, request.model.as_deref(), request.effort.as_deref()).await.map(|_| Value::Null)
        }
        other => unknown(other),
    }
}

/// A task asking, running or noting through Zero's own tools (the MCP server's zero_ ones): for agents whose
/// commands can't reach Zero's socket (Codex's sandbox), the same asks `zero ask`, `zero run` and `zero note` make.
fn agent_ask(zerod: &Zerod, request: &Request) -> Result<Value, String> {
    let daemon = &zerod.daemon;
    let id = request.session()?;
    let conversation = daemon.get(&id).ok_or_else(|| format!("No session {id}"))?;
    let args = request.args.clone().unwrap_or(json!({}));
    if args["tool"] == "issue" {
        let state = args["state"]
            .as_str()
            .and_then(crate::model::IssueState::named)
            .ok_or("An issue's state is one of you, over, working, waiting, parked or done")?;
        let text = |key: &str| args[key].as_str().map(String::from);
        let fields = args["fields"].as_array().map(|f| f.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
        let more = crate::model::IssueMore { needs: text("needs"), pr: text("pr"), fields };
        let ticket = args["ticket"].as_str().ok_or("Which issue? Its ticket")?;
        daemon.set_issue_with(&id, ticket, state, args["text"].as_str().unwrap_or(""), &more)?;
        return Ok(json!({}));
    }
    // `zero mcp list`: the servers there are, to propose a change of one; their values aren't the agent's.
    if args["tool"] == "mcp_list" {
        return Ok(json!(daemon.mcp_servers.for_agent()));
    }
    let agent = crate::bridge::identity(&conversation, &crate::bridge::hostname());
    // zero_done: as `zero done` (Inbox::done): refused with a token, done with it, or the user asked.
    if args["tool"] == "done" {
        let said = args["text"].as_str().unwrap_or("Done").trim().to_string();
        if args["ask"].as_bool() == Some(true) && !zerod.inbox.is_worker(&agent) {
            return Ok(json!({"id": zerod.inbox.ask_done(&agent, &said).id}));
        }
        return zerod.inbox.done(&agent, &said, args["confirm"].as_str()).map(|_| json!({"done": true}));
    }
    if args["tool"] == "blocked" {
        let said = args["text"].as_str().unwrap_or("Blocked").trim().to_string();
        return zerod.inbox.blocked(&agent, &said, args["confirm"].as_str()).map(|_| json!({"blocked": true}));
    }
    let ttl = Settings::load(daemon.home()).ttl.unwrap_or(3600);
    let mut ask = match args["tool"].as_str() {
        Some("mcp") => mcp_ask(daemon, &args, &conversation, agent, ttl)?,
        _ => ask_of(&args, &conversation, agent, ttl)?,
    };
    // A tool call returns at once, so nothing waits on the answer: it goes to the task as a message, as `--async`'s.
    if ask.kind != crate::ask::AskKind::Note {
        ask.waits = Some(false)
    }
    zerod.inbox.admit(&mut ask)?;
    let made = if ask.mcp.is_some() { zerod.inbox.create_mcp(ask) } else { zerod.inbox.create(ask, false) };
    Ok(json!({"id": made.id}))
}

/// The ask a zero_ tool makes: `ask` a question or choice, `run` a command, `note` an update.
fn ask_of(args: &Value, conversation: &Conversation, agent: AgentIdentity, ttl: i64) -> Result<Ask, String> {
    let text = |key: &str| args[key].as_str().map(str::trim).filter(|s| !s.is_empty()).map(String::from);
    Ok(match args["tool"].as_str() {
        Some("ask") => {
            let question = text("question").ok_or("Ask what? question")?;
            let options: Vec<String> =
                args["options"].as_array().into_iter().flatten().filter_map(|o| o.as_str().map(String::from)).collect();
            let mut ask = Ask::new(if options.is_empty() { AskKind::Question } else { AskKind::Choice }, &question, agent, ttl);
            ask.options = options;
            ask.detail = text("body");
            ask.command = text("code");
            ask.blocks = args["block"].as_bool().unwrap_or(false);
            ask.about = text("about").map(|anchor| crate::ask::About { anchor: Some(anchor), ..Default::default() });
            ask
        }
        Some("run") => {
            let command = text("command").ok_or("Run what? command")?;
            let why = text("why").ok_or("A run says why: what you need its output for, so the user knows what they're running")?;
            let mut ask = Ask::new(AskKind::Run, "Run a command", agent, ttl);
            ask.body = why;
            ask.command = Some(command);
            ask.cwd = text("cwd").or(Some(conversation.cwd.clone()));
            ask.options = ["Run", "Reject", "Suggest something else…"].map(String::from).to_vec();
            ask
        }
        Some("note") => {
            let mut note = Ask::new(AskKind::Note, "Update", agent, 0);
            note.body = text("text").ok_or("Note what? text")?;
            note.status = text("state").map(|s| if s == "merged" { "completed".into() } else { s });
            note.needs = text("needs");
            note
        }
        other => return Err(format!("No tool {other:?}: ask, run or note")),
    })
}

/// `zero mcp add`: an MCP server to add, or a change of the one there of that name, for the user to approve; kept
/// and given to the running tasks once they do (server::apply_mcp_asks).
fn mcp_ask(
    daemon: &crate::daemon::Daemon, args: &Value, conversation: &Conversation, agent: AgentIdentity, ttl: i64,
) -> Result<Ask, String> {
    use crate::mcp_servers::{McpServer, Source};
    let text = |key: &str| args[key].as_str().map(str::trim).filter(|s| !s.is_empty()).map(String::from);
    let list =
        |key: &str| -> Vec<String> { args[key].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(String::from)).collect() };
    let names =
        |key: &str| list(key).into_iter().map(|name| crate::mcp_servers::Value { name, value: None, from: Source::Keychain }).collect();
    let why = text("why").ok_or("Say why: what the server is for, so the user knows what they're adding")?;
    let proposed = McpServer {
        id: String::new(),
        name: text("name").ok_or("Which server? name")?,
        command: text("command"),
        args: list("args"),
        url: text("url"),
        env: names("env"),
        headers: names("headers"),
        workspaces: vec![],
        enabled: true,
        lazy: args["lazy"].as_bool().unwrap_or(false),
    };
    if proposed.command.is_some() == proposed.url.is_some() {
        return Err("A server runs a command or is at a URL: give one of them".into());
    }
    // "all", or workspaces by id or name: given as a list, or a comma-separated line (the CLI's).
    let workspaces = daemon.workspaces.list();
    let named: Option<Vec<String>> = match &args["workspaces"] {
        Value::String(line) => Some(line.split(',').map(|w| w.trim().to_string()).filter(|w| !w.is_empty()).collect()),
        Value::Array(_) => Some(list("workspaces")),
        _ => None,
    };
    let scope = match named {
        Some(named) if named.iter().any(|w| w.eq_ignore_ascii_case("all")) => Some(vec![]),
        Some(named) => Some(
            named
                .iter()
                .map(|w| {
                    workspaces.iter().find(|k| k.id == *w || k.name.eq_ignore_ascii_case(w)).map(|k| k.id.clone()).ok_or_else(|| {
                        let known: Vec<&str> = workspaces.iter().map(|k| k.id.as_str()).collect();
                        format!("No workspace {w}: say all, or some of {}", known.join(", "))
                    })
                })
                .collect::<Result<Vec<_>, _>>()?,
        ),
        None => None,
    };
    let (server, was) = daemon.mcp_servers.proposal(proposed, &daemon.workspace_of(conversation), scope);
    let scoped = |server: &McpServer| {
        let names: Vec<String> =
            server.workspaces.iter().map(|id| workspaces.iter().find(|w| w.id == *id).map_or(id.clone(), |w| w.name.clone())).collect();
        let scope = if names.is_empty() { "every workspace".to_string() } else { names.join(", ") };
        format!("{}, for {scope}", server.describe())
    };
    let (title, yes) = match &was {
        Some(_) => (format!("Change the MCP server {}?", server.id), "Change it"),
        None => (format!("Add the MCP server {}?", server.name), "Add it"),
    };
    let mut ask = Ask::new(AskKind::Approve, &title, agent, ttl);
    ask.body = match &was {
        Some(old) => format!("{why}\n\nNow: {}\nWas: {}", scoped(&server), scoped(old)),
        None => format!("{why}\n\n{}", scoped(&server)),
    };
    ask.options = [yes, "Reject", "Suggest something else…"].map(String::from).to_vec();
    ask.mcp = Some(server);
    Ok(ask)
}
