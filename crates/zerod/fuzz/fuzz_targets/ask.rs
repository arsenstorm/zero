//! An ask as the `zero` CLI sends it over zero.sock and ~/.zero/asks.jsonl keeps it, its times in Swift's ISO 8601.
//! One that reads must write back as the same ask.
#![no_main]

use libfuzzer_sys::fuzz_target;
use zerod::ask::{Ask, Time};

fuzz_target!(|data: &[u8]| {
    if let Ok(text) = std::str::from_utf8(data)
        && let Some(time) = Time::parse(text)
    {
        assert_eq!(Time::parse(&time.iso()), Some(time), "{text} reads back as itself");
    }
    if let Ok(ask) = serde_json::from_slice::<Ask>(data) {
        let written = serde_json::to_vec(&ask).unwrap();
        assert_eq!(serde_json::from_slice::<Ask>(&written).unwrap(), ask);
    }
});
