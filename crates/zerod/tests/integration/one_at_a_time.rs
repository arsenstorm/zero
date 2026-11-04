//! OpenCode takes one message at a time: one sent mid-turn waits for the turn's end, as Return does while it works,
//! rather than being refused (and, refused, lost from the box it was written in).


use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::{fixture, play, temp_dir};
use zerod::daemon::{Daemon, Runtime};
use zerod::model::{Permissions, Provider};

#[tokio::test]
async fn a_message_for_opencode_mid_turn_waits_for_its_turn_to_end() {
    let home = temp_dir("one-at-a-time");
    let recorded = fixture("opencode-command");
    // Started, its first message in, and never answered: the turn goes on.
    let script: Vec<_> = recorded[..4].iter().cloned().chain([recorded[7].clone()]).collect();
    let started = Arc::new(Mutex::new(vec![]));
    let keep = started.clone();
    let runtime: Runtime = Arc::new(move |_, _, _| { let (transport, seen) = play(script.clone()); keep.lock().unwrap().push(seen); Ok(transport) });
    let daemon = Daemon::open(&home, runtime).unwrap();
    let id = daemon.start(Provider::Opencode, home.to_str().unwrap(), "list the files", None, None, Permissions::Auto).unwrap();
    for _ in 0..300 { if daemon.get(&id).is_some_and(|c| c.turn.is_some()) { break } tokio::time::sleep(Duration::from_millis(10)).await }
    assert!(daemon.get(&id).unwrap().turn.is_some(), "mid-turn");
    daemon.send(&id, "and the hidden ones", None, None).await.expect("not refused");
    assert_eq!(daemon.queued(&id).0.iter().map(|q| q.text.as_str()).collect::<Vec<_>>(), ["and the hidden ones"], "waiting for the turn's end");
}
