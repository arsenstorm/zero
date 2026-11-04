//! What every provider's session becomes is the same for a client as for the daemon: the changes, sent as JSON and
//! applied in order to an empty conversation, end in the daemon's conversation.


use crate::common::replay;
use zerod::model::{Conversation, Provider};

#[test]
fn a_client_applying_the_changes_ends_with_the_daemons_conversation() {
    let fixtures = [
        (Provider::Codex, "codex-command"), (Provider::Codex, "codex-file-change"),
        (Provider::Claude, "claude-command"), (Provider::Claude, "claude-command-approval"), (Provider::Claude, "claude-file-change"),
        (Provider::Opencode, "opencode-command"), (Provider::Opencode, "opencode-file-change"), (Provider::Opencode, "opencode-approval"),
        (Provider::Opencode, "opencode-refused"),
    ];
    for (provider, name) in fixtures {
        let (core, changes) = replay(provider, name);
        let mut mirror = Conversation::new("s1", provider, "/work/project");
        for change in changes {
            mirror.apply(serde_json::from_str(&serde_json::to_string(&change).unwrap()).unwrap());
        }
        assert_eq!(&mirror, core.conversation(), "{name}");
        assert!(!core.conversation().items.is_empty(), "{name} says something");
    }
}

#[test]
fn providers_are_named_in_lower_case_on_the_wire() {
    for (provider, name) in [(Provider::Codex, "codex"), (Provider::Claude, "claude"), (Provider::Opencode, "opencode")] {
        assert_eq!(serde_json::to_value(provider).unwrap(), name);
    }
}
