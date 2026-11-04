//! Watching a file a process writes to (a build's log, a server's) for the task that asked: lines that say something
//! went wrong, with what led up to them; the file going quiet; and the line that says it's done, which ends the watch.


use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::{Seen, play, temp_dir};
use serde_json::json;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::{Permissions, Provider};
use zerod::watches::{Reading, Watch};

fn watch(alerts: &[&str], done: Option<&str>) -> Watch {
    Watch { id: String::new(), session: "s".into(), file: "/tmp/build.log".into(), alerts: alerts.iter().map(|a| a.to_string()).collect(),
            done: done.map(Into::into), quiet: None, offset: 0 }
}

#[test]
fn a_read_finds_whats_watched_for_with_what_led_up_to_it_across_reads() {
    let watch = watch(&[": error: ", "FAILED: "], Some("[3/3]"));
    let mut reading = Reading::new(&watch).unwrap();
    reading.read(&watch, "[1/3] Building a.cpp\nwarning: unused x\nsrc/b.cpp:4:2: err");
    assert!(reading.hits.is_empty(), "half a line isn't read yet");
    reading.read(&watch, "or: no member named 'y'\n[2/3] Building c.cpp\n");
    assert_eq!(reading.hits, ["[1/3] Building a.cpp", "warning: unused x", "src/b.cpp:4:2: error: no member named 'y'"], "the match, and the lines before it");
    assert_eq!(reading.latest.as_deref(), Some("[2/3] Building c.cpp"));
    assert!(reading.done.is_none());
    reading.read(&watch, "[3/3] Linking clickhouse\n");
    assert_eq!(reading.done.as_deref(), Some("[3/3] Linking clickhouse"), "plain text is plain text: [3/3] isn't a pattern");
}

#[test]
fn a_pattern_between_slashes_tells_a_compilers_error_from_source_that_mentions_one() {
    let watch = watch(&[r"/:\d+:\d+: (fatal )?error: /"], None);
    let mut reading = Reading::new(&watch).unwrap();
    reading.read(&watch, "  130 |   \"ZSTD stream encoder end failed: error: '{}'\",\nsrc/IO/Zstd.cpp:130:29: error: no matching function\n");
    assert_eq!(reading.hits.last().map(String::as_str), Some("src/IO/Zstd.cpp:130:29: error: no matching function"));
    assert_eq!(reading.hits.len(), 2, "the quoted source is the line before, not a hit of its own");
    assert!(Reading::new(&self::watch(&["/(unclosed/"], None)).is_err(), "a pattern that isn't one is said at once");
}

fn runtime(started: Arc<Mutex<Vec<Seen>>>) -> Runtime {
    Arc::new(move |_, _, _| {
        let (transport, seen) = play(vec![]);
        started.lock().unwrap().push(seen);
        Ok(transport)
    })
}

#[tokio::test]
async fn a_task_hears_when_its_watched_log_goes_wrong_and_when_its_done() {
    let home = temp_dir("watches");
    let started = Arc::new(Mutex::new(vec![]));
    let daemon = Daemon::open(&home, runtime(started.clone())).unwrap();
    zerod::watches::poll_every(Duration::from_millis(30));
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "build it", None, None, Permissions::Auto).unwrap();
    for _ in 0..200 { if !started.lock().unwrap().is_empty() { break } tokio::time::sleep(Duration::from_millis(10)).await }
    let seen = started.lock().unwrap()[0].clone();
    seen.said("user", 1).await;
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "watching"}));
    let log = home.join("build.log");
    std::fs::write(&log, "[1/3] old line: error: from before the watch\n").unwrap();
    assert!(daemon.watch_file(&id, &log, vec![": error: ".into()], Some("1".into()), None).unwrap_err().contains("almost every line"),
            "a text that short would end it on the first line");
    let watched = daemon.watch_file(&id, &log, vec![": error: ".into()], Some("[3/3]".into()), None).unwrap();
    assert_eq!(daemon.watches(Some(&id)).len(), 1);
    let append = |text: &str| { use std::io::Write; std::fs::OpenOptions::new().append(true).open(&log).unwrap().write_all(text.as_bytes()).unwrap() };
    append("[2/3] Building b.cpp\nsrc/b.cpp:4:2: error: no member named 'y'\n");
    let told = seen.said("user", 2).await[1]["message"]["content"].as_str().unwrap().to_string();
    assert!(told.starts_with("<!-- from: zero -->"), "Zero's word, not the user's: {told}");
    assert!(told.contains("error: no member named 'y'") && told.contains("[2/3] Building b.cpp"), "the error and what led up to it: {told}");
    assert!(!told.contains("from before the watch"), "only what's written since it started");
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "looking"}));
    append("[3/3] Linking\n");
    let done = seen.said("user", 3).await[2]["message"]["content"].as_str().unwrap().to_string();
    assert!(done.contains("[3/3] Linking"), "{done}");
    for _ in 0..50 { if daemon.watches(Some(&id)).is_empty() { break } tokio::time::sleep(Duration::from_millis(20)).await }
    assert!(daemon.watches(Some(&id)).is_empty(), "done: the watch ends");
    let _ = watched;
}
