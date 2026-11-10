//! An agent's answer, as the board reads its last lines: Zero's ending, a question in prose, the words without the ending.
#![no_main]

use libfuzzer_sys::fuzz_target;
use zerod::board::{asks_in_prose, ending, without_ending};

fuzz_target!(|answer: &str| {
    let _ = ending(answer);
    let _ = asks_in_prose(answer);
    let rest = without_ending(answer);
    assert!(answer.starts_with(rest), "the answer without its ending is the start of it");
});
