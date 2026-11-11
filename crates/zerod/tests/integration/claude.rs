//! Claude Code through its own headless mode (`claude -p` with stream-json both ways and permission prompts on
//! stdio), on real output (tests/fixtures/claude-*, recorded from Claude Code 2.1.310 on Haiku, every request
//! allowed). Zero runs the installed `claude` and never touches its sign-in.

use crate::common::replay;
use serde_json::json;
use zerod::core::Core;
use zerod::model::{ApprovalKind, Change, ChoiceKind, Conversation, ItemKind, ItemStatus, Permissions, Provider, Status};

fn approvals(changes: &[Change]) -> Vec<zerod::model::Approval> {
    changes
        .iter()
        .filter_map(|c| match c {
            Change::Approval { approval } => Some(approval.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn a_command_claude_may_run_reads_as_the_users_words_the_command_and_the_answer() {
    let (core, changes) = replay(Provider::Claude, "claude-command");
    let conversation = core.conversation();
    assert_eq!(conversation.thread.as_deref(), Some("de7c0e2b-badd-439a-a46b-9e187476cb40"));
    assert_eq!(conversation.model.as_deref(), Some("claude-haiku-5-5"));
    assert_eq!((conversation.status, conversation.turn.clone()), (Status::Idle, None));
    let kinds: Vec<&ItemKind> = conversation.items.iter().map(|i| &i.kind).collect();
    assert!(
        matches!(kinds[0], ItemKind::User { text, .. } if text.starts_with("Run the shell command uname -s")),
        "Claude doesn't echo it; Zero records what it sent"
    );
    assert!(
        matches!(kinds[1], ItemKind::Command { command, output, cwd, .. } if command == "uname -s" && output == "Darwin" && cwd == "/work/project")
    );
    assert_eq!(conversation.items[1].status, ItemStatus::Done);
    assert!(matches!(kinds[2], ItemKind::Agent { text, final_answer: true } if text == "The command printed `Darwin`."));
    assert_eq!(kinds.len(), 3, "nothing else: no empty thinking, no status lines");
    assert!(approvals(&changes).is_empty(), "read-only, so Claude's own rules allowed it");
    // The answer streamed in before the finished message replaced it.
    let answer = &conversation.items[2].id;
    assert!(changes.iter().any(|c| matches!(c, Change::Delta { item, .. } if item == answer)));
}

#[test]
fn a_command_that_needs_permission_asks_with_claudes_own_choices() {
    let (core, changes) = replay(Provider::Claude, "claude-command-approval");
    let asked = approvals(&changes);
    assert_eq!(asked.len(), 1);
    let approval = &asked[0];
    assert_eq!(approval.kind, ApprovalKind::Command);
    assert_eq!(approval.title, "Run mkdir -p build && touch build/marker");
    assert_eq!(approval.command.as_deref(), Some("mkdir -p build && touch build/marker"));
    assert_eq!(approval.reason.as_deref(), Some("Create build directory and touch marker file"));
    assert_eq!(approval.item.as_deref(), Some("toolu_01Aa95da16TUjcCj1ouaN4Z9"));
    let offered: Vec<_> = approval.choices.iter().map(|c| (c.label.as_str(), c.kind)).collect();
    assert_eq!(
        offered,
        [
            ("Allow", ChoiceKind::Allow),
            ("Always allow Bash(mkdir -p build), Bash(touch build/marker)", ChoiceKind::AllowAlways),
            ("Deny", ChoiceKind::Deny),
            ("Deny and stop", ChoiceKind::Stop),
        ]
    );
    let conversation = core.conversation();
    assert!(conversation.approvals.is_empty(), "answering it settled it");
    assert!(matches!(&conversation.items.last().unwrap().kind, ItemKind::Agent { text, final_answer: true } if text == "done"));
    assert!(
        matches!(&conversation.items[1].kind, ItemKind::Command { output, .. } if output.is_empty()),
        "Claude's \"completed with no output\" is not output"
    );
}

#[test]
fn each_choice_answers_claudes_permission_request_as_the_sdk_would() {
    let request = json!({"type": "control_request", "request_id": "r1", "request": {
        "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "make"}, "tool_use_id": "t1",
        "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "make"}], "behavior": "allow", "destination": "localSettings"}]}});
    let answer = |choice: ChoiceKind| {
        let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
        core.receive(&request);
        let approval = core.conversation().approvals[0].clone();
        let id = approval.choices.iter().find(|c| c.kind == choice).unwrap().id.clone();
        core.answer(&approval.id, &id).unwrap()["response"].clone()
    };
    assert_eq!(
        answer(ChoiceKind::Allow),
        json!({"subtype": "success", "request_id": "r1", "response": {"behavior": "allow", "updatedInput": {"command": "make"}}})
    );
    let always = answer(ChoiceKind::AllowAlways)["response"].clone();
    assert_eq!(always["updatedPermissions"], request["request"]["permission_suggestions"]);
    assert_eq!(answer(ChoiceKind::Deny)["response"], json!({"behavior": "deny", "message": "Denied in Zero"}));
    assert_eq!(answer(ChoiceKind::Stop)["response"], json!({"behavior": "deny", "message": "Denied in Zero", "interrupt": true}));
}

#[test]
fn a_file_write_reads_as_the_file_with_its_contents_and_asks_first() {
    let (core, changes) = replay(Provider::Claude, "claude-file-change");
    let conversation = core.conversation();
    let write = conversation.items.iter().find(|i| matches!(i.kind, ItemKind::FileChange { .. })).unwrap();
    let ItemKind::FileChange { changes: files } = &write.kind else { unreachable!() };
    assert_eq!(
        (files[0].path.as_str(), files[0].kind.as_str(), files[0].diff.as_str()),
        ("/work/project/hello.txt", "add", "hello from zero\n")
    );
    assert_eq!(write.status, ItemStatus::Done);
    let approval = approvals(&changes).remove(0);
    assert_eq!(approval.kind, ApprovalKind::FileChange);
    assert_eq!(approval.title, "Write hello.txt");
    assert_eq!(approval.changes, *files);
    // Claude suggests switching the session to accepting edits: that's "for this session", not "always".
    let offered: Vec<_> = approval.choices.iter().map(|c| (c.label.as_str(), c.kind)).collect();
    assert_eq!(offered[1], ("Allow all edits this session", ChoiceKind::AllowSession));
    assert!(matches!(&conversation.items.last().unwrap().kind, ItemKind::Agent { text, final_answer: true } if text == "done"));
}

#[test]
fn an_edit_shows_what_it_replaces() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "t1", "name": "Edit",
        "input": {"file_path": "/work/project/a.rs", "old_string": "let a = 1;\nlet b = 2;", "new_string": "let a = 3;"}}]}}));
    let ItemKind::FileChange { changes } = &core.conversation().items[0].kind else { panic!() };
    assert_eq!((changes[0].kind.as_str(), changes[0].diff.as_str()), ("update", "-let a = 1;\n-let b = 2;\n+let a = 3;\n"));
}

#[test]
fn a_message_sent_mid_turn_goes_into_that_turn_and_its_result_ends_it() {
    // Claude Code hands a message sent while it works to the running turn (beside the next tool result), so one
    // result ends both: the session isn't left "working" waiting for a result that never comes.
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    let user = |text: &str| json!({"type": "user", "message": {"role": "user", "content": text}});
    let result = json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"});
    core.sent(&user("first"));
    core.sent(&user("and also this"));
    assert_eq!(core.conversation().status, Status::Working);
    core.receive(&result);
    assert_eq!(core.conversation().status, Status::Idle);
    assert_eq!(core.conversation().turn, None);
    // Sent after the turn, a message starts the next one.
    core.sent(&user("and now this"));
    assert_eq!(core.conversation().status, Status::Working);
    assert_eq!(core.conversation().turn.as_deref(), Some("turn-2"));
}

#[test]
fn the_restarts_carry_on_is_a_turn_but_not_a_message_of_yours() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": zerod::daemon::CARRY_ON}}));
    assert_eq!(core.conversation().status, Status::Working, "Claude is told, and answers");
    assert!(core.conversation().items.is_empty(), "nothing to read: Zero said it, not you");
}

#[test]
fn a_subagent_in_the_background_runs_until_it_reports_back() {
    // The Agent tool's own result comes at once, saying the subagent started: the step keeps running until Claude
    // Code's task notification says it ended, so the subagent reads as at work for as long as it is.
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": "go"}}));
    core.receive(&json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "toolu_1", "name": "Agent",
        "input": {"description": "Rebase the branch", "prompt": "Rebase onto main…", "subagent_type": "claude", "run_in_background": true}}]}}));
    assert!(
        matches!(&core.conversation().items[1].kind, ItemKind::Tool { name, detail } if name == "Agent" && detail == "Rebase the branch")
    );
    core.receive(&json!({"type": "system", "subtype": "task_started", "task_type": "local_agent", "is_backgrounded": true, "tool_use_id": "toolu_1", "description": "Rebase the branch"}));
    core.receive(&json!({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": "Agent started in background with ID a1"}]}}));
    assert_eq!(core.conversation().items[1].status, ItemStatus::Running, "started, not done");
    core.receive(
        &json!({"type": "system", "subtype": "task_notification", "tool_use_id": "toolu_1", "status": "completed", "summary": "Rebased"}),
    );
    assert_eq!(core.conversation().items[1].status, ItemStatus::Done);
}

#[test]
fn a_stopped_turn_says_interrupted_not_error() {
    // Claude Code ends an interrupted turn with an error result and no words: that's "Interrupted", as Codex's and
    // OpenCode's are, not a failure in red.
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": "go"}}));
    core.sent(&json!({"type": "control_request", "request_id": "r1", "request": {"subtype": "interrupt"}}));
    core.receive(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true}));
    let notices: Vec<(String, bool)> = core
        .conversation()
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::Notice { text, error } => Some((text.clone(), *error)),
            _ => None,
        })
        .collect();
    assert_eq!(notices, [("Interrupted".to_string(), false)]);
    assert_eq!(core.conversation().status, Status::Idle);
    assert_eq!(core.conversation().error, None);
    // A turn that failed on its own is still an error.
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": "again"}}));
    core.receive(&json!({"type": "result", "subtype": "error_during_execution", "is_error": true}));
    assert!(
        core.conversation()
            .items
            .iter()
            .any(|i| matches!(&i.kind, ItemKind::Notice { text, error: true } if text == "error_during_execution"))
    );
}

#[test]
fn claude_speaking_while_idle_starts_a_turn() {
    // A message that reached Claude Code just as its turn ended is taken up as a turn of its own: its words come with
    // no message of yours before them, and are still a turn.
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": "first"}}));
    core.receive(&json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"}));
    assert_eq!(core.conversation().status, Status::Idle);
    core.receive(&json!({"type": "assistant", "message": {"id": "m2", "content": [{"type": "text", "text": "On it."}]}}));
    assert_eq!(core.conversation().status, Status::Working);
    assert_eq!(core.conversation().turn.as_deref(), Some("turn-2"));
    assert_eq!(core.conversation().items.last().unwrap().turn.as_deref(), Some("turn-2"));
    core.receive(&json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"}));
    assert_eq!(core.conversation().status, Status::Idle);
}

#[test]
fn a_failed_turn_and_a_request_zero_cannot_answer_both_say_so() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": "hi"}}));
    core.receive(
        &json!({"type": "result", "subtype": "error_during_execution", "is_error": true, "result": "Not logged in · Please run /login"}),
    );
    assert_eq!(core.conversation().error.as_deref(), Some("Not logged in · Please run /login"));
    assert_eq!(core.conversation().status, Status::Idle);

    let effects = core.receive(&json!({"type": "control_request", "request_id": "r9", "request": {"subtype": "request_user_dialog"}}));
    assert_eq!(
        effects.replies[0],
        json!({"type": "control_response", "response": {"subtype": "error", "request_id": "r9", "error": "Zero can't answer request_user_dialog yet"}})
    );
    assert!(matches!(&core.conversation().items.last().unwrap().kind, ItemKind::Notice { error: true, .. }));
}

#[test]
fn claude_runs_unmodified_in_auto_mode_with_zeros_rules_appended() {
    let mut conversation = Conversation::new("s1", Provider::Claude, "/work/project");
    conversation.thread = Some("3f1c2b8a-0000-4000-8000-000000000001".into());
    let fresh = Provider::Claude.command(&conversation, false, Some("haiku"), Some("low"));
    assert_eq!(fresh[..4], ["/bin/zsh", "-lic", "exec \"$@\"", "zsh"]);
    let args = &fresh[4..];
    let at = |flag: &str| args.iter().position(|a| a == flag).map(|i| args[i + 1].as_str());
    assert_eq!(
        args[..8],
        ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
    );
    assert_eq!(at("--permission-prompt-tool"), Some("stdio"));
    // Claude in Chrome off, whatever the user's own default: agents in Zero use Zero for Chrome.
    assert!(args.contains(&"--no-chrome".to_string()) && !args.contains(&"--chrome".to_string()), "{args:?}");
    assert_eq!(at("--permission-mode"), Some("auto"), "The user's own mode: Claude's classifier decides, Zero hears what it can't");
    assert_eq!(at("--session-id"), Some("3f1c2b8a-0000-4000-8000-000000000001"));
    assert_eq!((at("--model"), at("--effort")), (Some("haiku"), Some("low")));
    assert_eq!(at("--append-system-prompt"), Some(zerod::adapter::INSTRUCTIONS));
    // Compacting while idle saves a cache write and costs the conversation: off, for this run only.
    assert_eq!(at("--settings"), Some(r#"{"idleCompaction":false}"#));
    let resumed = Provider::Claude.command(&conversation, true, None, None);
    assert!(resumed.windows(2).any(|w| w[0] == "--resume" && w[1] == "3f1c2b8a-0000-4000-8000-000000000001"));
    conversation.permissions = Permissions::Unrestricted;
    let unrestricted = Provider::Claude.command(&conversation, false, None, None);
    assert!(unrestricted.windows(2).any(|w| w[0] == "--permission-mode" && w[1] == "bypassPermissions"));
}

#[test]
fn a_tool_claudes_classifier_blocks_reads_as_blocked() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "git push --force"}}]}}));
    core.receive(&json!({"type": "system", "subtype": "permission_denied", "tool_name": "Bash", "tool_use_id": "t1",
        "message": "Git Destructive: force-pushing rewrites shared history"}));
    let conversation = core.conversation();
    assert_eq!(conversation.items[0].status, ItemStatus::Declined);
    assert!(
        matches!(&conversation.items[1].kind, ItemKind::Notice { text, error: true } if text == "Blocked: Git Destructive: force-pushing rewrites shared history")
    );
}

#[test]
fn a_command_carries_the_agents_words_for_what_it_does() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&json!({"type": "assistant", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "t1", "name": "Bash",
        "input": {"command": "python3 - <<'EOF'\nprint(1)\nEOF", "description": "Render six frames of the sweep"}}]}}));
    assert!(matches!(&core.conversation().items[0].kind,
        ItemKind::Command { description, .. } if description == "Render six frames of the sweep"));
    // OpenCode's, where it gives one.
    let mut core = Core::new(Conversation::new("s1", Provider::Opencode, "/work/project"));
    core.receive(&json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": {
        "sessionUpdate": "tool_call", "toolCallId": "c1", "title": "bash", "kind": "execute", "status": "pending",
        "rawInput": {"command": "make", "description": "Build the app"}}}}));
    assert!(matches!(&core.conversation().items[0].kind, ItemKind::Command { description, .. } if description == "Build the app"));
    // Kept before it was carried, a command still reads, without one.
    let old: ItemKind =
        serde_json::from_value(json!({"type": "command", "command": "ls", "cwd": "/", "output": "", "exitCode": 0, "durationMs": null}))
            .unwrap();
    assert!(matches!(old, ItemKind::Command { description, .. } if description.is_empty()));
}

fn ask_user_question() -> serde_json::Value {
    json!({"type": "control_request", "request_id": "q1", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "t9",
        "input": {"questions": [
            {"question": "Which database should the cache use?", "header": "Cache", "multiSelect": false,
             "options": [{"label": "Redis", "description": "Already in the stack"}, {"label": "Postgres", "description": "One less service"}]},
            {"question": "Which checks should run?", "header": "Checks", "multiSelect": true,
             "options": [{"label": "Lint", "description": ""}, {"label": "Tests", "description": ""}, {"label": "Types", "description": ""}]}]}}})
}

#[test]
fn claudes_ask_user_question_is_a_question_not_an_approval() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&ask_user_question());
    let conversation = core.conversation();
    assert!(conversation.approvals.is_empty());
    assert_eq!(conversation.status, Status::Waiting);
    let question = &conversation.questions[0];
    assert_eq!((question.id.as_str(), question.item.as_deref()), ("q1", Some("t9")));
    assert_eq!(question.fields.len(), 2);
    let cache = &question.fields[0];
    assert_eq!(
        (cache.header.as_deref(), cache.question.as_str(), cache.multiple, cache.other),
        (Some("Cache"), "Which database should the cache use?", false, true)
    );
    assert_eq!(cache.options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(), ["Redis", "Postgres"]);
    assert_eq!(cache.options[0].description.as_deref(), Some("Already in the stack"));
    assert!(question.fields[1].multiple);
}

#[test]
fn answers_go_back_inside_the_tools_input_keyed_by_question() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&ask_user_question());
    let answers = std::collections::HashMap::from([
        ("0".to_string(), vec!["Redis".to_string()]),
        ("1".to_string(), vec!["Lint".into(), "Tests".into()]),
    ]);
    let line = core.reply("q1", &answers).unwrap();
    let response = &line["response"]["response"];
    assert_eq!(response["behavior"], "allow");
    assert_eq!(
        response["updatedInput"]["answers"],
        json!({"Which database should the cache use?": "Redis", "Which checks should run?": "Lint, Tests"})
    );
    assert_eq!(response["updatedInput"]["questions"], ask_user_question()["request"]["input"]["questions"]);
    core.sent(&line);
    assert!(core.conversation().questions.is_empty(), "answered, so settled");
    assert!(core.reply("q1", &answers).is_err());
    let partial = std::collections::HashMap::from([("0".to_string(), vec!["Redis".to_string()])]);
    let mut again = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    again.receive(&ask_user_question());
    assert!(again.reply("q1", &partial).is_err(), "every field needs an answer");
}

fn with_remote_server(provider: Provider) -> Conversation {
    let mut conversation = Conversation::new("s1", provider, "/work/project");
    conversation.mcp = vec![zerod::mcp_servers::Resolved {
        id: "cve-lookup".into(),
        name: "CVE lookup".into(),
        command: None,
        args: vec![],
        url: Some("https://cve.example/mcp".into()),
        env: vec![],
        headers: vec![],
    }];
    conversation
}

#[test]
fn any_server_that_needs_signing_in_is_zeros_to_sign_in_to_once_per_process() {
    let mut core = Core::new(with_remote_server(Provider::Claude));
    let effects = core.receive(&json!({"type": "system", "subtype": "init", "session_id": "t1", "mcp_servers": [
        {"name": "cve-lookup", "status": "needs-auth"}, {"name": "betterstack", "status": "needs-auth"}, {"name": "docs", "status": "connected"}]}));
    assert!(effects.replies.is_empty(), "signed in by a Claude of Zero's own, which hears the callback: not this task's");
    let wanted: Vec<&str> = effects
        .changes
        .iter()
        .filter_map(|c| match c {
            Change::McpSignIn { server } => Some(server.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(wanted, ["cve-lookup", "betterstack"], "Zero's server and the user's own alike");
    let again = core.receive(
        &json!({"type": "system", "subtype": "init", "session_id": "t1", "mcp_servers": [{"name": "betterstack", "status": "needs-auth"}]}),
    );
    assert!(!again.changes.iter().any(|c| matches!(c, Change::McpSignIn { .. })), "said once: the next turn's init doesn't say it again");
}

#[test]
fn a_subagent_speaking_after_the_turn_ended_starts_no_turn() {
    // A background subagent (Claude's Agent tool, run on): its messages carry the tool's id, and go on after the
    // lead's turn has ended. They are its, not a turn of the conversation's, which would never end.
    let mut ended = Conversation::new("s1", Provider::Claude, "/work/project");
    ended.status = Status::Idle;
    let mut core = Core::new(ended);
    core.receive(&json!({"type": "assistant", "parent_tool_use_id": "toolu_bg", "message": {"id": "m9", "content": [{"type": "text", "text": "Reading the docs page."}]}}));
    core.receive(
        &json!({"type": "stream_event", "parent_tool_use_id": "toolu_bg", "event": {"type": "message_start", "message": {"id": "m10"}}}),
    );
    let conversation = core.conversation();
    assert_eq!((conversation.status, conversation.turn.clone()), (Status::Idle, None));
}

#[test]
fn a_subagents_result_after_the_turn_ended_still_ends_its_step() {
    // Its call came while the lead's turn ran (a step in the chat); its result came after the turn ended: the step
    // ends, though nothing of the subagent's starts a turn.
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&json!({"type": "assistant", "parent_tool_use_id": "toolu_bg", "message": {"id": "m1", "content": [
        {"type": "tool_use", "id": "t1", "name": "mcp__zero__browser_navigate", "input": {"url": "https://example.test"}}]}}));
    core.receive(&json!({"type": "result", "subtype": "success", "result": "Checking in the background.\n\n[zero: working]"}));
    assert_eq!(core.conversation().status, Status::Idle);
    core.receive(&json!({"type": "user", "parent_tool_use_id": "toolu_bg", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "Tab 5: loaded"}]}]}}));
    let conversation = core.conversation();
    assert_eq!(conversation.item("t1").unwrap().status, ItemStatus::Done, "its step ended");
    assert_eq!((conversation.status, conversation.turn.clone()), (Status::Idle, None));
}

fn api_error(error: &str, text: &str) -> serde_json::Value {
    json!({"type": "assistant", "error": error, "is_api_error_message": true,
           "message": {"id": "e1", "model": "<synthetic>", "role": "assistant", "content": [{"type": "text", "text": text}]}})
}

#[test]
fn claudes_api_errors_are_not_its_words() {
    // Recorded from Claude Code 2.1.319: an expired sign-in comes as a made-up assistant message, then an error result.
    // The failure is the result's to report, once; the made-up message is no answer of the agent's.
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": "hi"}}));
    let expired = "Failed to authenticate: OAuth session expired and could not be refreshed";
    core.receive(&api_error("authentication_failed", expired));
    core.receive(&json!({"type": "result", "subtype": "success", "is_error": true, "api_error_status": null, "result": expired}));
    assert!(!core.conversation().items.iter().any(|i| matches!(i.kind, ItemKind::Agent { .. })), "no answer");
    assert_eq!(core.conversation().failure.as_ref().map(|f| f.kind), Some(zerod::model::FailureKind::SignIn));
    // A server error mid-response Claude Code retries by itself, in the same turn: nothing to show.
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": "again"}}));
    core.receive(&api_error("server_error", "API Error: Server error mid-response. The response above may be incomplete."));
    core.receive(&json!({"type": "assistant", "message": {"id": "m2", "content": [{"type": "text", "text": "Done."}]}}));
    core.receive(&json!({"type": "result", "subtype": "success", "is_error": false, "result": "Done."}));
    let said: Vec<&str> = core
        .conversation()
        .items
        .iter()
        .filter_map(|i| match &i.kind {
            ItemKind::Agent { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(said, ["Done."]);
}

#[test]
fn compacting_shows_while_claude_compacts_and_ends_when_it_has() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&json!({"type": "system", "subtype": "status", "status": "compacting"}));
    let item = core.conversation().items.last().unwrap().clone();
    assert!(item.id.starts_with(zerod::adapter::COMPACTED), "Zero's recap follows it: {item:?}");
    assert!(matches!(&item.kind, ItemKind::Notice { text, error: false } if text == "Compacting the conversation…"), "{item:?}");
    assert_eq!(item.status, ItemStatus::Running);
    core.receive(&json!({"type": "system", "subtype": "status", "status": null, "compact_result": "success"}));
    let items = &core.conversation().items;
    assert_eq!(items.len(), 1, "the same row, ended: {items:?}");
    assert!(matches!(&items[0].kind, ItemKind::Notice { text, error: false } if text == "Conversation compacted"));
    assert_eq!(items[0].status, ItemStatus::Done);
}

#[test]
fn a_background_subagents_request_between_turns_needs_the_user_but_starts_no_turn() {
    // Its lead's turn has ended; a subagent left running in the background asks to run a command. The task needs the
    // user (the approval), but no turn of the lead's is under way: nothing for Stop to find, and what the subagent says
    // after stays its own, out of the lead's conversation.
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&json!({"type": "result", "subtype": "success", "is_error": false, "result": "Started it.\n\n[zero: working]"}));
    core.receive(&json!({"type": "control_request", "request_id": "r1", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "t9",
        "input": {"command": "curl -X POST https://example.com"}}}));
    assert_eq!(core.conversation().status, Status::Idle, "no turn of the lead's");
    assert_eq!(core.conversation().attention(), zerod::model::Attention::NeedsYou, "the approval waits on the user");
    let line = core.answer("r1", "allow").unwrap();
    core.sent(&line);
    assert_eq!(core.conversation().status, Status::Idle);
    let items = core.conversation().items.len();
    core.receive(&json!({"type": "assistant", "parent_tool_use_id": "toolu_agent", "agent_id": "a1",
        "message": {"id": "m9", "content": [{"type": "tool_use", "id": "t10", "name": "Bash", "input": {"command": "ls"}}]}}));
    assert_eq!(core.conversation().items.len(), items, "the subagent's words stay its own");
}

#[test]
fn what_runs_in_the_background_is_known_so_stop_can_stop_it() {
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/work/project"));
    core.receive(&json!({"type": "system", "subtype": "task_started", "task_id": "a1", "tool_use_id": "toolu_agent", "is_backgrounded": true, "task_type": "local_agent"}));
    core.receive(&json!({"type": "system", "subtype": "task_progress", "task_id": "b2"}));
    let stops: Vec<String> = core.stops().iter().map(|s| s["request"]["task_id"].as_str().unwrap().to_string()).collect();
    assert_eq!(stops.len(), 2, "{stops:?}");
    assert!(core.stops().iter().all(|s| s["type"] == "control_request" && s["request"]["subtype"] == "stop_task"));
    core.receive(
        &json!({"type": "system", "subtype": "task_notification", "task_id": "a1", "tool_use_id": "toolu_agent", "status": "completed"}),
    );
    core.receive(&json!({"type": "system", "subtype": "task_notification", "task_id": "b2", "status": "stopped"}));
    assert!(core.stops().is_empty(), "ended: nothing to stop");
}

/// Work handed to another agent goes to a Zero worker, which the user sees, steers and stops in Zero: the CLIs' own
/// subagents (Claude's Agent tool, Codex's multi-agent tools) are off in Zero's runs unless the user turns them on.
#[test]
fn the_clis_own_subagents_are_off_unless_the_user_allows_them() {
    let mut claude = Conversation::new("s", Provider::Claude, "/w");
    claude.thread = Some("3f1c".into());
    let off = Provider::Claude.command_with(&claude, false, None, None, false);
    assert!(off.iter().any(|a| a == "--disallowed-tools=Agent"), "{off:?}");
    let on = Provider::Claude.command_with(&claude, false, None, None, true);
    assert!(!on.iter().any(|a| a.starts_with("--disallowed-tools")), "{on:?}");
    let codex = Conversation::new("s", Provider::Codex, "/w");
    let off = Provider::Codex.command_with(&codex, false, None, None, false);
    assert!(off.windows(2).any(|w| w == ["-c", "features.multi_agent=false"]), "{off:?}");
    assert!(!Provider::Codex.command_with(&codex, false, None, None, true).iter().any(|a| a.contains("multi_agent")));
    // The user's setting: off unless they turn it on.
    assert!(!zerod::server::Settings::default().allows_subagents());
    let allowed: zerod::server::Settings = serde_json::from_value(json!({"subagents": true})).unwrap();
    assert!(allowed.allows_subagents());
    // Told where such work goes instead.
    assert!(zerod::adapter::INSTRUCTIONS.contains("zero spawn") && zerod::adapter::INSTRUCTIONS.contains("own subagents"));
}

/// Every turn resends the whole context, so a long task on a 1M-token model rereads most of it each time: the user may
/// have agents compact at a smaller size (Settings › Compact context at). Claude Code reads it from its environment
/// (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, which beats its own settings), Codex from its config; OpenCode keeps its own.
#[test]
fn agents_compact_their_context_at_the_size_the_user_chose() {
    let window = |settings: serde_json::Value| serde_json::from_value::<zerod::server::Settings>(settings).unwrap().compact_window();
    assert_eq!(window(json!({})), None, "unset, the CLIs' own");
    assert_eq!(window(json!({"compactWindow": 0})), None, "0 turns it back off");
    assert_eq!(window(json!({"compactWindow": 400000})), Some(400_000));
    assert_eq!(window(json!({"compactWindow": 5000})), Some(100_000), "Claude Code's smallest");
    assert_eq!(window(json!({"compactWindow": 9000000})), Some(1_000_000), "and largest");

    let variable = || {
        zerod::process::environment(std::iter::empty(), "s1")
            .into_iter()
            .find(|(k, _)| k == "CLAUDE_CODE_AUTO_COMPACT_WINDOW")
            .map(|(_, v)| v)
    };
    let mut codex = Conversation::new("s", Provider::Codex, "/w");
    codex.thread = Some("t1".into());
    let limit = "model_auto_compact_token_limit=400000";
    zerod::adapter::set_compact_window(Some(400_000));
    assert_eq!(variable().as_deref(), Some("400000"));
    assert!(Provider::Codex.command(&codex, false, None, None).windows(2).any(|w| w == ["-c", limit]));
    assert!(Provider::Codex.terminal(&codex).unwrap().windows(2).any(|w| w == ["-c", limit]));
    zerod::adapter::set_compact_window(None);
    assert_eq!(variable(), None);
    assert!(!Provider::Codex.command(&codex, false, None, None).iter().any(|a| a.contains("compact")));
}
