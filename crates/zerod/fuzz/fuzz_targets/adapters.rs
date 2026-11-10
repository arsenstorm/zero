//! A runtime's stdout, line by line, as session/process.rs hands it to the session: Claude Code's stream-json, Codex's
//! and OpenCode's JSON-RPC. Then every approval and question it opened is answered, which builds replies from it.
#![no_main]

use libfuzzer_sys::fuzz_target;
use zerod::core::Core;
use zerod::model::{Conversation, Provider};

fuzz_target!(|data: &[u8]| {
    let Some((first, lines)) = data.split_first() else { return };
    let provider = [Provider::Claude, Provider::Codex, Provider::Opencode][*first as usize % 3];
    let mut core = Core::new(Conversation::new("s", provider, "/work"));
    for line in lines.split(|b| *b == b'\n') {
        if let Ok(message) = serde_json::from_slice(line) {
            let _ = core.answers(&message);
            core.receive(&message);
        }
    }
    let conversation = core.conversation().clone();
    for approval in &conversation.approvals {
        for choice in &approval.choices {
            let _ = core.answer(&approval.id, &choice.id);
        }
    }
    for question in &conversation.questions {
        let answers = question.fields.iter().map(|f| (f.id.clone(), vec!["yes".to_string()])).collect();
        let _ = core.reply(&question.id, &answers);
    }
    let _ = core.stops();
    core.offline();
});
