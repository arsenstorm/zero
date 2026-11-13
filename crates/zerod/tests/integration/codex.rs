//! Codex through `codex app-server`, on real output (tests/fixtures/codex-*, recorded from codex-cli 0.160.1 with
//! its approvals accepted): what each turn becomes in Zero's model.

use crate::common::replay;
use serde_json::json;
use zerod::core::Core;
use zerod::model::{ApprovalKind, Change, ChoiceKind, Conversation, ItemKind, ItemStatus, Provider, Status};

fn approvals(changes: &[Change]) -> Vec<zerod::model::Approval> {
    changes
        .iter()
        .filter_map(|c| match c {
            Change::Approval { approval } => Some(approval.clone()),
            _ => None,
        })
        .collect()
}

fn core() -> Core {
    let mut core = Core::new(Conversation::new("s1", Provider::Codex, "/work/project"));
    core.sent(&json!({"id": "z3", "method": "turn/start", "params": {}}));
    core
}

#[test]
fn a_command_turn_reads_as_messages_and_a_command_with_its_output() {
    let (core, _) = replay(Provider::Codex, "codex-command");
    let conversation = core.conversation();
    assert_eq!(conversation.thread.as_deref(), Some("01a177f4-5525-7141-bfb3-f350d91476d6"));
    assert_eq!(conversation.model.as_deref(), Some("gpt-6-sol"));
    assert_eq!(conversation.status, Status::Idle);
    assert_eq!(conversation.turn, None);
    assert!(conversation.approvals.is_empty());
    assert!(matches!(&conversation.items[0].kind, ItemKind::User { text, .. } if text.starts_with("Run the shell command `ls -la`")));
    let command = conversation.items.iter().find(|item| matches!(item.kind, ItemKind::Command { .. })).unwrap();
    let ItemKind::Command { command: line, cwd, output, exit_code, .. } = &command.kind else { unreachable!() };
    assert_eq!(line, "ls -la", "shown without Codex's /bin/zsh -lc wrapper");
    assert_eq!(cwd, "/work/project");
    assert!(output.starts_with("total 0"), "{output}");
    assert_eq!(*exit_code, Some(0));
    assert_eq!(command.status, ItemStatus::Done);
    let ItemKind::Agent { text, final_answer } = &conversation.items.last().unwrap().kind else { panic!("last is the answer") };
    assert!(*final_answer);
    assert!(text.contains("empty"), "{text}");
    // Reasoning with an empty summary says nothing, so it isn't an item.
    assert!(!conversation.items.iter().any(|item| matches!(item.kind, ItemKind::Reasoning { .. })));
}

#[test]
fn a_command_approval_offers_exactly_what_codex_offers_and_closes_when_codex_resolves_it() {
    let (_, changes) = replay(Provider::Codex, "codex-command");
    let approval = approvals(&changes).remove(0);
    assert_eq!(approval.kind, ApprovalKind::Command);
    assert_eq!(approval.title, "Run ls -la");
    assert_eq!(approval.command.as_deref(), Some("ls -la"));
    assert_eq!(approval.cwd.as_deref(), Some("/work/project"));
    let offered: Vec<_> = approval.choices.iter().map(|c| (c.label.as_str(), c.kind)).collect();
    assert_eq!(
        offered,
        [("Allow", ChoiceKind::Allow), ("Always allow ls -la", ChoiceKind::AllowAlways), ("Deny and stop", ChoiceKind::Stop)]
    );
    assert!(changes.iter().any(|change| matches!(change, Change::Resolved { approval: id } if *id == approval.id)));
}

#[test]
fn each_choice_answers_in_codexs_own_words() {
    let mut core = core();
    let request = json!({"id": 4, "method": "item/commandExecution/requestApproval", "params": {
        "itemId": "c1", "command": "/bin/zsh -lc 'ls -la'", "cwd": "/work/project",
        "availableDecisions": ["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["ls", "-la"]}}, "cancel"]}});
    core.receive(&request);
    let id = core.conversation().approvals[0].id.clone();
    let always = core.conversation().approvals[0].choices[1].id.clone();
    let line = core.answer(&id, &always).unwrap();
    assert_eq!(line, json!({"id": 4, "result": {"decision": {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["ls", "-la"]}}}}));
    assert_eq!(core.conversation().approvals.len(), 1, "open until Codex says it resolved it");
    assert!(core.answer(&id, "no-such-choice").is_err());
    assert!(core.answer("no-such-approval", &always).is_err());
}

#[test]
fn a_file_change_reads_as_the_file_and_its_diff() {
    let (core, changes) = replay(Provider::Codex, "codex-file-change");
    let conversation = core.conversation();
    let change = conversation.items.iter().find(|item| matches!(item.kind, ItemKind::FileChange { .. })).unwrap();
    let ItemKind::FileChange { changes: files } = &change.kind else { unreachable!() };
    assert_eq!(
        (files[0].path.as_str(), files[0].kind.as_str(), files[0].diff.as_str()),
        ("/work/project/hello.txt", "add", "hello from zero\n")
    );
    assert_eq!(change.status, ItemStatus::Done);
    assert!(conversation.diff.as_deref().unwrap().contains("+++ b/hello.txt"));

    let asked = approvals(&changes);
    assert_eq!(asked.len(), 2, "the file, then reading it back");
    assert_eq!(asked[0].kind, ApprovalKind::FileChange);
    assert_eq!(asked[0].title, "Add hello.txt");
    assert_eq!(asked[0].item.as_deref(), Some(change.id.as_str()));
    assert_eq!(asked[0].changes, *files, "what will change, shown with the question");
    // A file approval lists no decisions of its own; Codex's file decisions are the fallback.
    let kinds: Vec<_> = asked[0].choices.iter().map(|c| c.kind).collect();
    assert_eq!(kinds, [ChoiceKind::Allow, ChoiceKind::AllowSession, ChoiceKind::Deny, ChoiceKind::Stop]);
    assert!(conversation.approvals.is_empty(), "both were resolved");
}

#[test]
fn streamed_deltas_build_the_text_before_the_item_completes() {
    let mut core = core();
    core.receive(&json!({"method": "item/started", "params": {"turnId": "u", "item": {"type": "agentMessage", "id": "m1", "text": "", "phase": "final_answer"}}}));
    for delta in ["Hel", "lo"] {
        core.receive(&json!({"method": "item/agentMessage/delta", "params": {"turnId": "u", "itemId": "m1", "delta": delta}}));
    }
    let item = &core.conversation().items[0];
    assert!(matches!(&item.kind, ItemKind::Agent { text, .. } if text == "Hello"));
    assert_eq!(item.status, ItemStatus::Running);
}

#[test]
fn a_request_zero_cannot_answer_yet_is_refused_with_a_notice() {
    let mut core = core();
    let effects = core.receive(&json!({"id": 7, "method": "mcpServer/elicitation/request", "params": {"itemId": "x"}}));
    assert_eq!(effects.replies[0]["id"], json!(7));
    assert!(effects.replies[0]["error"]["message"].as_str().unwrap().contains("mcpServer/elicitation/request"));
    assert!(
        matches!(&core.conversation().items[0].kind, ItemKind::Notice { text, error: true } if text.contains("mcpServer/elicitation/request"))
    );
}

#[test]
fn a_failed_turn_says_why_and_the_session_is_idle_again() {
    let mut core = core();
    core.receive(&json!({"method": "turn/started", "params": {"turn": {"id": "u", "status": "inProgress"}}}));
    assert_eq!(core.conversation().status, Status::Working);
    core.receive(&json!({"method": "turn/completed", "params": {"turn": {"id": "u", "status": "failed", "error": {"message": "usage limit reached"}}}}));
    let conversation = core.conversation();
    assert_eq!((conversation.turn.clone(), conversation.status), (None, Status::Idle));
    assert_eq!(conversation.error.as_deref(), Some("usage limit reached"));
    assert!(matches!(&conversation.items.last().unwrap().kind, ItemKind::Notice { text, error: true } if text == "usage limit reached"));
}

#[test]
fn an_error_answer_to_zeros_request_becomes_a_notice() {
    let mut core = core();
    core.receive(&json!({"id": "z3", "error": {"code": -32600, "message": "thread not found"}}));
    assert_eq!(core.conversation().error.as_deref(), Some("turn/start failed: thread not found"));
}

#[test]
fn codexs_request_for_input_is_a_question_answered_by_question_id() {
    let mut core = core();
    core.receive(&json!({"id": 11, "method": "item/tool/requestUserInput", "params": {"threadId": "t", "turnId": "u", "itemId": "i1", "isBlocking": true,
        "questions": [{"id": "env", "header": "Target", "question": "Deploy where?", "isOther": true, "isSecret": false,
                       "options": [{"label": "Staging", "description": "safe"}, {"label": "Production", "description": "careful"}]},
                      {"id": "token", "header": "Token", "question": "Paste the deploy token", "isOther": true, "isSecret": true, "options": null}]}}));
    let question = core.conversation().questions[0].clone();
    assert_eq!(question.fields.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(), ["env", "token"]);
    assert!(question.fields[1].secret);
    assert!(question.fields[1].options.is_empty());
    let answers = std::collections::HashMap::from([
        ("env".to_string(), vec!["Staging".to_string()]),
        ("token".to_string(), vec!["s3cret".to_string()]),
    ]);
    assert_eq!(
        core.reply(&question.id, &answers).unwrap(),
        json!({"id": 11, "result": {"answers": {"env": {"answers": ["Staging"]}, "token": {"answers": ["s3cret"]}}}})
    );
    core.receive(&json!({"method": "serverRequest/resolved", "params": {"threadId": "t", "requestId": 11}}));
    assert!(core.conversation().questions.is_empty());
}

#[test]
fn any_server_codex_says_needs_signing_in_is_zeros_to_sign_in_to() {
    let mut core = Core::new(Conversation::new("s1", Provider::Codex, "/work/project"));
    let needs = |name: &str| json!({"method": "mcpServer/startupStatus/updated", "params": {"name": name, "status": "failed", "failureReason": "reauthenticationRequired", "threadId": "t1"}});
    let effects = core.receive(&needs("linear"));
    assert!(effects.replies.is_empty(), "signed in by a Codex of Zero's own: not this task's");
    assert!(
        effects.changes.iter().any(|c| matches!(c, Change::McpSignIn { server, connector: false } if server == "linear")),
        "{:?}",
        effects.changes
    );
}

#[test]
fn codex_compacting_shows_while_it_runs_and_ends_as_compacted() {
    let mut core = Core::new(Conversation::new("s1", Provider::Codex, "/work/project"));
    core.receive(&json!({"method": "item/started", "params": {"turnId": "u", "item": {"type": "contextCompaction", "id": "c1"}}}));
    let item = core.conversation().items.last().unwrap().clone();
    assert_eq!(item.id, format!("{}c1", zerod::adapter::COMPACTED));
    assert!(matches!(&item.kind, ItemKind::Notice { text, .. } if text == "Compacting the conversation…"), "{item:?}");
    assert_eq!(item.status, ItemStatus::Running);
    core.receive(&json!({"method": "item/completed", "params": {"turnId": "u", "item": {"type": "contextCompaction", "id": "c1"}}}));
    let items = &core.conversation().items;
    assert_eq!(items.len(), 1, "{items:?}");
    assert!(matches!(&items[0].kind, ItemKind::Notice { text, .. } if text == "Conversation compacted"));
    assert_eq!(items[0].status, ItemStatus::Done);
}

/// Codex says a limit was reached without a full window (a workspace's credits spent): the account is limited all the
/// same.
#[test]
fn codex_saying_a_limit_was_reached_is_a_limit() {
    let usage = zerod::codex::usage(&json!({"primary": {"usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1794609866},
                                            "rateLimitReachedType": "workspace_member_usage_limit_reached"}));
    assert!(usage.limited);
    assert!(
        !zerod::codex::usage(&json!({"primary": {"usedPercent": 40, "windowDurationMins": 300}, "rateLimitReachedType": null})).limited
    );
}
