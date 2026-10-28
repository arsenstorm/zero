//! OpenCode through the Agent Client Protocol (`opencode acp`), on real output (tests/fixtures/opencode-*,
//! recorded from OpenCode 2.1.4 on opencode-go/beam-free; the approval run had a project config that asks).

mod common;

use common::replay;
use serde_json::json;
use zerod::core::Core;
use zerod::model::{ApprovalKind, Change, ChoiceKind, Conversation, ItemKind, ItemStatus, Provider, Status};

fn approvals(changes: &[Change]) -> Vec<zerod::model::Approval> {
    changes.iter().filter_map(|c| match c { Change::Approval { approval } => Some(approval.clone()), _ => None }).collect()
}

#[test]
fn a_command_reads_as_the_users_words_its_thinking_the_command_and_the_answer() {
    let (core, _) = replay(Provider::Opencode, "opencode-command");
    let conversation = core.conversation();
    assert_eq!(conversation.thread.as_deref(), Some("ses_e87e7ec46ffe1ztiRcXd8Xelqy"));
    assert_eq!(conversation.model.as_deref(), Some("opencode-go/beam-free"), "the model as set, not the one it started on");
    assert_eq!((conversation.status, conversation.turn.clone()), (Status::Idle, None));
    let kinds: Vec<&ItemKind> = conversation.items.iter().map(|i| &i.kind).collect();
    assert!(matches!(kinds[0], ItemKind::User { text, .. } if text.starts_with("Run the shell command: mkdir -p build")));
    assert!(matches!(kinds[1], ItemKind::Reasoning { text } if text.starts_with("The user wants me to run a shell command")));
    let command = conversation.items.iter().find(|i| matches!(i.kind, ItemKind::Command { .. })).unwrap();
    assert!(matches!(&command.kind, ItemKind::Command { command, cwd, output, exit_code, .. }
        if command == "mkdir -p build && touch build/marker" && cwd == "/work/project" && output == "(no output)" && *exit_code == Some(0)));
    assert_eq!(command.status, ItemStatus::Done);
    assert!(matches!(&conversation.items.last().unwrap().kind, ItemKind::Agent { text, final_answer: true } if text == "done."));
}

#[test]
fn a_file_write_reads_as_the_file_with_its_contents() {
    let (core, _) = replay(Provider::Opencode, "opencode-file-change");
    let write = core.conversation().items.iter().find(|i| matches!(i.kind, ItemKind::FileChange { .. })).unwrap();
    let ItemKind::FileChange { changes } = &write.kind else { unreachable!() };
    assert_eq!((changes[0].path.as_str(), changes[0].diff.as_str()), ("/work/project/hello.txt", "hello from zero\n"));
    assert_eq!(write.status, ItemStatus::Done);
}

#[test]
fn permission_requests_offer_opencodes_own_options_and_show_the_change_first() {
    let (core, changes) = replay(Provider::Opencode, "opencode-approval");
    let asked = approvals(&changes);
    assert_eq!(asked.len(), 2);
    let (file, command) = (&asked[0], &asked[1]);
    assert_eq!(file.kind, ApprovalKind::FileChange);
    assert_eq!(file.title, "Write hello.txt");
    assert_eq!(file.changes.len(), 1);
    assert_eq!((file.changes[0].path.as_str(), file.changes[0].kind.as_str(), file.changes[0].diff.as_str()), ("/work/project/hello.txt", "add", "hello from zero"));
    assert_eq!(command.kind, ApprovalKind::Command);
    assert_eq!(command.title, "Run mkdir -p build && touch build/marker");
    assert_eq!(command.cwd.as_deref(), Some("/work/project"));
    let offered: Vec<_> = command.choices.iter().map(|c| (c.id.as_str(), c.label.as_str(), c.kind)).collect();
    assert_eq!(offered, [("once", "Allow once", ChoiceKind::Allow), ("always", "Always allow", ChoiceKind::AllowAlways), ("reject", "Reject", ChoiceKind::Deny)]);
    assert!(core.conversation().approvals.is_empty(), "both answered");
}

#[test]
fn a_choice_answers_with_its_option_id() {
    let mut core = Core::new(Conversation::new("s1", Provider::Opencode, "/work/project"));
    core.receive(&json!({"jsonrpc": "2.0", "id": 3, "method": "session/request_permission", "params": {"sessionId": "s",
        "toolCall": {"toolCallId": "c1", "title": "ls", "kind": "execute", "rawInput": {"command": "ls"}},
        "options": [{"optionId": "once", "kind": "allow_once", "name": "Allow once"}, {"optionId": "reject", "kind": "reject_once", "name": "Reject"}]}}));
    let approval = core.conversation().approvals[0].id.clone();
    assert_eq!(core.answer(&approval, "reject").unwrap(), json!({"jsonrpc": "2.0", "id": 3, "result": {"outcome": {"outcome": "selected", "optionId": "reject"}}}));
}

#[test]
fn a_prompt_opencode_refuses_says_why() {
    let (core, _) = replay(Provider::Opencode, "opencode-refused");
    let conversation = core.conversation();
    assert_eq!(conversation.status, Status::Idle);
    assert!(conversation.error.as_deref().unwrap().contains("Free models may train on request data"), "{:?}", conversation.error);
    assert!(matches!(&conversation.items.last().unwrap().kind, ItemKind::Notice { error: true, .. }));
}

#[test]
fn opencode_runs_its_acp_server() {
    let conversation = Conversation::new("s1", Provider::Opencode, "/work/project");
    assert_eq!(Provider::Opencode.command(&conversation, false, None, None)[4..], ["opencode", "acp"]);
}
