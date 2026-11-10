//! A session's transcript.jsonl replayed as zerod does after a restart (session.rs `replay`): what was sent, what came
//! back, and Zero's own changes, for any provider.
#![no_main]

use libfuzzer_sys::fuzz_target;
use zerod::core::Core;
use zerod::model::{Conversation, Provider};

fuzz_target!(|data: &[u8]| {
    let Some((first, lines)) = data.split_first() else { return };
    let provider = [Provider::Claude, Provider::Codex, Provider::Opencode][*first as usize % 3];
    let mut core = Core::new(Conversation::new("s", provider, "/work"));
    for line in lines.split(|b| *b == b'\n') {
        if let Ok(entry) = serde_json::from_slice(line) {
            zerod::session::replay_entry(&mut core, &entry);
        }
    }
    core.offline();
});
