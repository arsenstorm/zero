//! The wire contract with the Swift apps. For each recording, the events zerod sends and the conversation they end
//! in are kept in tests/wire/, and apps/macos/Tests/ZeroCoreTests/ZerodWireTests.swift decodes and applies the same
//! files: a change to the wire on either side fails one of the two. `ZERO_WIRE_UPDATE=1 cargo test -p zerod --test
//! wire` rewrites them after a deliberate change.

mod common;

use common::replay;
use zerod::model::{Event, Provider};

const RECORDINGS: [(Provider, &str); 9] = [
    (Provider::Codex, "codex-command"), (Provider::Codex, "codex-file-change"),
    (Provider::Claude, "claude-command"), (Provider::Claude, "claude-command-approval"), (Provider::Claude, "claude-file-change"),
    (Provider::Opencode, "opencode-command"), (Provider::Opencode, "opencode-file-change"), (Provider::Opencode, "opencode-approval"),
    (Provider::Opencode, "opencode-refused"),
];

#[test]
fn the_events_and_conversations_the_apps_decode_are_what_zerod_sends() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/wire");
    let update = std::env::var("ZERO_WIRE_UPDATE").as_deref() == Ok("1");
    for (provider, name) in RECORDINGS {
        let (core, changes) = replay(provider, name);
        let events: String = changes.into_iter().enumerate()
            .map(|(i, change)| serde_json::to_string(&Event { session: "s1".into(), seq: i as u64 + 1, change }).unwrap() + "\n").collect();
        let conversation = serde_json::to_string_pretty(core.conversation()).unwrap() + "\n";
        let (events_file, conversation_file) = (dir.join(format!("{name}.events.jsonl")), dir.join(format!("{name}.conversation.json")));
        if update {
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(&events_file, &events).unwrap();
            std::fs::write(&conversation_file, &conversation).unwrap();
        }
        assert_eq!(std::fs::read_to_string(&events_file).unwrap_or_default(), events, "{name}: the events changed; rerun with ZERO_WIRE_UPDATE=1 if that's intended");
        assert_eq!(std::fs::read_to_string(&conversation_file).unwrap_or_default(), conversation, "{name}: the conversation changed");
    }
}
