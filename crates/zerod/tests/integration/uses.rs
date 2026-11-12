//! What each task's processes use: its CLI, the MCP servers it started with, and the commands it runs, each with what
//! they started in turn; memory and CPU, sampled from the CLI's pid down.

use std::time::Duration;

use crate::common::temp_dir;
use tokio::sync::broadcast;
use zerod::model::{Conversation, Provider};
use zerod::session::Session;
use zerod::uses::Sampler;

/// A stand-in CLI: an MCP server it starts with (not a shell), and a command (a shell) whose child keeps a core busy.
fn cli() -> Vec<String> {
    let body = r#"sleep 60 & sh -c 'yes >/dev/null; :' & cat >/dev/null"#;
    vec!["/bin/sh".into(), "-c".into(), body.into()]
}

#[tokio::test]
async fn a_tasks_cli_its_mcp_servers_and_its_commands_are_measured_apart() {
    let dir = temp_dir("uses-split").canonicalize().unwrap();
    let (events, _) = broadcast::channel(16);
    let session = Session::new(Conversation::new("s1", Provider::Claude, dir.to_str().unwrap()), None, events).unwrap();
    session.attach(zerod::process::spawn(&cli(), &dir, "s1", None).unwrap());
    let pid = session.pid().expect("a CLI started as a process has a pid");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let mut sampler = Sampler::default();
    let first = sampler.sample(&[("s1".into(), pid)]).expect("a task seen for the first time is news");
    assert_eq!(first["s1"].commands.cpu, 0.0, "no CPU before there's an interval to measure it over");
    tokio::time::sleep(Duration::from_secs(1)).await;
    let tasks = sampler.sample(&[("s1".into(), pid)]).expect("a core taken up is news");
    let uses = &tasks["s1"];
    session.stop();
    eprintln!("{uses:?}");
    assert!(uses.commands.cpu > 50.0, "the command's child keeps a core busy: {uses:?}");
    assert!(uses.cli.cpu < 20.0 && uses.mcp.cpu < 20.0, "the CLI and its server are idle: {uses:?}");
    assert!(uses.cli.memory > 0 && uses.mcp.memory > 0 && uses.commands.memory > 0, "{uses:?}");
}

#[tokio::test]
async fn nothing_is_sent_again_until_it_changes_meaningfully() {
    let mut idle = tokio::process::Command::new("/bin/sh").args(["-c", "sleep 60"]).kill_on_drop(true).spawn().unwrap();
    let pid = idle.id().unwrap() as i32;
    let mut sampler = Sampler::default();
    assert!(sampler.sample(&[("s1".into(), pid)]).is_some());
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(sampler.sample(&[("s1".into(), pid)]).is_none(), "an idle task's few kilobytes either way wake no one");
    assert!(sampler.sample(&[]).is_some_and(|t| t.is_empty()), "a task parked (no process) is news: it uses nothing now");
    let _ = idle.kill().await;
}

#[test]
fn sampling_every_task_costs_zerod_little() {
    // This test process's own tree, many times over, as though each were a task.
    let me = std::process::id() as i32;
    let roots: Vec<(String, i32)> = (0..50).map(|n| (format!("s{n}"), me)).collect();
    let mut sampler = Sampler::default();
    sampler.sample(&roots);
    let began = std::time::Instant::now();
    sampler.sample(&roots);
    let took = began.elapsed();
    eprintln!("50 tasks sampled in {took:?}");
    assert!(took < Duration::from_millis(50), "{took:?}");
}
