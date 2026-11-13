//! The wire contract with the Swift apps. For each recording, the events zerod sends and the conversation they end
//! in are kept in tests/wire/, and apps/macos/Tests/ZeroCoreTests/ZerodWireTests.swift decodes and applies the same
//! files: a change to the wire on either side fails one of the two. `ZERO_WIRE_UPDATE=1 cargo test -p zerod --test
//! wire` rewrites them after a deliberate change.

use crate::common::replay;
use zerod::model::{
    Attention, Conversation, Event, Failure, FailureKind, Field, Item, ItemKind, ItemStatus, Provider, Question, QuestionOption, Status,
    Usage, UsageWindow,
};

const RECORDINGS: [(Provider, &str); 9] = [
    (Provider::Codex, "codex-command"),
    (Provider::Codex, "codex-file-change"),
    (Provider::Claude, "claude-command"),
    (Provider::Claude, "claude-command-approval"),
    (Provider::Claude, "claude-file-change"),
    (Provider::Opencode, "opencode-command"),
    (Provider::Opencode, "opencode-file-change"),
    (Provider::Opencode, "opencode-approval"),
    (Provider::Opencode, "opencode-refused"),
];

#[test]
fn the_events_and_conversations_the_apps_decode_are_what_zerod_sends() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/wire");
    let update = std::env::var("ZERO_WIRE_UPDATE").as_deref() == Ok("1");
    for (provider, name) in RECORDINGS {
        let (core, changes) = replay(provider, name);
        let events: String = changes
            .into_iter()
            .enumerate()
            .map(|(i, change)| serde_json::to_string(&Event { session: "s1".into(), seq: i as u64 + 1, change }).unwrap() + "\n")
            .collect();
        let conversation = serde_json::to_string_pretty(core.conversation()).unwrap() + "\n";
        let (events_file, conversation_file) = (dir.join(format!("{name}.events.jsonl")), dir.join(format!("{name}.conversation.json")));
        if update {
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(&events_file, &events).unwrap();
            std::fs::write(&conversation_file, &conversation).unwrap();
        }
        assert_eq!(
            std::fs::read_to_string(&events_file).unwrap_or_default(),
            events,
            "{name}: the events changed; rerun with ZERO_WIRE_UPDATE=1 if that's intended"
        );
        assert_eq!(std::fs::read_to_string(&conversation_file).unwrap_or_default(), conversation, "{name}: the conversation changed");
    }
}

/// Conversations in every state the bar shows, and the attention zerod gives each: the Swift app must agree. They
/// carry what no recording has yet (questions, limits, failures, stalls), so the app decodes those too.
#[test]
fn the_apps_attention_is_zerods() {
    let base = || {
        let mut c = Conversation::new("s1", Provider::Claude, "/work/project");
        c.status = Status::Idle;
        c
    };
    let answer = Item {
        at: None,
        id: "a".into(),
        turn: None,
        kind: ItemKind::Agent { text: "Done.\n\n[zero: done]".into(), final_answer: true },
        status: ItemStatus::Done,
    };
    let question = Question {
        id: "q1".into(),
        item: Some("t1".into()),
        fields: vec![Field {
            id: "0".into(),
            header: Some("Cache".into()),
            question: "Redis or Postgres?".into(),
            options: vec![
                QuestionOption { label: "Redis".into(), description: Some("in the stack".into()) },
                QuestionOption { label: "Postgres".into(), description: None },
            ],
            multiple: false,
            other: true,
            secret: false,
        }],
    };
    let mut cases: Vec<(&str, Conversation)> = vec![("starting", Conversation::new("s1", Provider::Codex, "/w"))];
    cases.push(("idle", base()));
    let mut done = base();
    done.items.push(answer.clone());
    cases.push(("done", done));
    let mut working = base();
    working.status = Status::Working;
    working.turn = Some("u".into());
    cases.push(("working", working.clone()));
    let mut stuck = working.clone();
    stuck.stalled = Some("No word from Claude Code for 10 minutes".into());
    cases.push(("stuck", stuck));
    let mut failed = base();
    failed.error = Some("Not logged in".into());
    failed.failure = Some(Failure { kind: FailureKind::SignIn, message: "Not logged in".into() });
    cases.push(("failed", failed));
    let mut limited = base();
    limited.usage = Some(Usage {
        limited: true,
        resets_at: Some(1793030000),
        windows: vec![
            UsageWindow { name: "5 hours".into(), used: 1.0, resets_at: Some(1793030000), read_at: None },
            UsageWindow { name: "7 days".into(), used: 0.4, resets_at: None, read_at: None },
        ],
        ..Default::default()
    });
    cases.push(("limited", limited));
    let mut asking = working.clone();
    asking.status = Status::Waiting;
    asking.questions.push(question);
    cases.push(("question", asking));
    let mut blocked = base();
    blocked
        .items
        .push(Item { kind: ItemKind::Agent { text: "CI is down.\n\n[zero: blocked]".into(), final_answer: true }, ..answer.clone() });
    cases.push(("blocked", blocked));
    let mut offline = base();
    offline.status = Status::Offline;
    cases.push(("offline", offline));
    let table: Vec<serde_json::Value> =
        cases.into_iter().map(|(name, c)| serde_json::json!({"name": name, "attention": c.attention(), "conversation": c})).collect();
    let attention: Vec<Attention> = table.iter().map(|case| serde_json::from_value(case["attention"].clone()).unwrap()).collect();
    assert_eq!(
        attention,
        [
            Attention::Starting,
            Attention::Idle,
            Attention::Done,
            Attention::Working,
            Attention::Stuck,
            Attention::Failed,
            Attention::Limited,
            Attention::NeedsYou,
            Attention::Blocked,
            Attention::Offline
        ]
    );
    let file = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/wire/attention.json");
    let text = serde_json::to_string_pretty(&table).unwrap() + "\n";
    if std::env::var("ZERO_WIRE_UPDATE").as_deref() == Ok("1") {
        std::fs::write(&file, &text).unwrap()
    }
    assert_eq!(
        std::fs::read_to_string(&file).unwrap_or_default(),
        text,
        "the attention table changed; rerun with ZERO_WIRE_UPDATE=1 if that's intended"
    );
}
