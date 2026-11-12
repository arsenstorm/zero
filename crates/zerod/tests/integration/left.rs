//! What a task left running: processes its commands started that outlived them (or still run between its turns), a
//! simulator it booted, containers it brought up. Found, never stopped unasked; stopped only when recorded as its.

use std::collections::HashMap;
use std::time::Duration;

use zerod::left::{Finder, Hint, Kind, Root, Runtime, containers, hint, simulators};

/// A stand-in dev server for the tests below: this test program, not one of Apple's (whose environment macOS keeps
/// from other processes), so it's found by the task's ZERO_SESSION as a real server would be.
#[test]
#[ignore]
fn stand_in_server() {
    std::thread::sleep(Duration::from_secs(60));
}

fn server_argv() -> String {
    let exe = std::env::current_exe().unwrap();
    format!("{} left::stand_in_server --exact --ignored --test-threads=1 -q", exe.display())
}

fn alive(pid: i32) -> bool {
    std::process::Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

#[tokio::test]
async fn a_server_a_command_left_behind_is_the_tasks_and_stops_when_asked() {
    // Its own session id: every test sees every process on the Mac.
    let session = format!("left-orphan-{}", std::process::id());
    // The command starts it and ends: launchd takes it in, as `nohup … &` leaves a dev server.
    let started = tokio::process::Command::new("/bin/sh")
        .args(["-c", &format!("nohup {} >/dev/null 2>&1 &", server_argv())])
        .env("ZERO_SESSION", &session)
        .status()
        .await
        .unwrap();
    assert!(started.success());
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut finder = Finder::default();
    let roots = [Root { session: session.clone(), pid: None, idle: true }, Root { session: "other".into(), pid: None, idle: true }];
    let found = finder.processes(&roots);
    let things = found.get(&session).expect("found as its task's");
    assert_eq!(things.len(), 1, "{things:?}");
    let server = &things[0];
    assert_eq!(server.kind, Kind::Process);
    assert!(server.name.contains("stand_in_server"), "named by its command line: {}", server.name);
    assert!(server.memory > 0 && server.since > 0, "{server:?}");
    assert!(!found.contains_key("other"), "nothing of another task's");
    let pid = server.pid().unwrap();
    assert!(alive(pid));

    zerod::left::stop(server).await.unwrap();
    assert!(!alive(pid), "stopped");
    assert!(!finder.processes(&roots).contains_key(&session), "and gone from the list");
}

#[tokio::test]
async fn a_command_still_running_between_turns_is_left_running_but_not_during_one() {
    // A stand-in CLI: an MCP server it starts with (not a shell), and a command (a shell) that keeps running.
    let mut cli = tokio::process::Command::new("/bin/sh")
        .args(["-c", "sleep 60 & sh -c 'sleep 60; :' & cat >/dev/null"])
        .stdin(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let pid = cli.id().unwrap() as i32;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let session = format!("left-tree-{}", std::process::id());
    let mut finder = Finder::default();
    let working = finder.processes(&[Root { session: session.clone(), pid: Some(pid), idle: false }]);
    assert!(!working.contains_key(&session), "a command running in its turn is the turn's: {working:?}");
    let idle = finder.processes(&[Root { session: session.clone(), pid: Some(pid), idle: true }]);
    let things = idle.get(&session).expect("between turns, what it still runs is left running");
    assert_eq!(things.len(), 1, "the command, not the CLI or its MCP server: {things:?}");
    assert!(things[0].name.contains("sleep 60"), "{}", things[0].name);
    zerod::left::stop(&things[0]).await.unwrap();
    assert!(alive(pid), "stopping the command leaves the CLI");
    let _ = cli.kill().await;
}

#[test]
fn commands_that_bring_things_up_are_read_for_what_they_bring_up() {
    let id = "3f2a".repeat(16);
    let cases: [(&str, &str, Option<Hint>); 9] = [
        (r#"xcrun simctl boot "iPhone 18 Pro""#, "", Some(Hint::Simulator { device: Some("iPhone 18 Pro".into()) })),
        ("open -a Simulator", "", Some(Hint::Simulator { device: None })),
        ("cd web && docker compose up -d", "", Some(Hint::Compose { runtime: Runtime::Docker, project: None, dir: "/work/web".into() })),
        ("cd /srv/shop; docker compose up", "", Some(Hint::Compose { runtime: Runtime::Docker, project: None, dir: "/srv/shop".into() })),
        (
            "docker-compose -p shop up",
            "",
            Some(Hint::Compose { runtime: Runtime::Docker, project: Some("shop".into()), dir: "/work".into() }),
        ),
        (
            "docker run -d --name db postgres:17",
            &format!("{id}\n"),
            Some(Hint::Container { runtime: Runtime::Docker, id: Some(id.clone()), name: Some("db".into()) }),
        ),
        ("podman run --rm -it alpine", "", Some(Hint::Container { runtime: Runtime::Podman, id: None, name: None })),
        ("docker ps", "", None),
        ("xcrun simctl list devices", "", None),
    ];
    for (command, output, expected) in cases {
        assert_eq!(hint(command, "/work", output), expected, "{command}");
    }
}

#[test]
fn containers_are_matched_to_the_commands_that_brought_them_up() {
    let db = "3f2a".repeat(16);
    let ps = [
        format!(r#"{{"ID":"{db}","Names":"db","Labels":"","State":"running"}}"#),
        r#"{"ID":"aaaa","Names":"shop-web-1","Labels":"com.docker.compose.project=shop,com.docker.compose.project.working_dir=/work/web","State":"running"}"#.into(),
        r#"{"ID":"bbbb","Names":"shop-db-1","Labels":"com.docker.compose.project=shop,com.docker.compose.project.working_dir=/work/web","State":"running"}"#.into(),
        r#"{"ID":"cccc","Names":"someone-elses","Labels":"com.docker.compose.project=other,com.docker.compose.project.working_dir=/elsewhere","State":"running"}"#.into(),
    ]
    .join("\n");
    let hints = [
        ("s1".to_string(), 1000, Hint::Container { runtime: Runtime::Docker, id: Some(db.clone()), name: None }),
        ("s2".to_string(), 2000, Hint::Compose { runtime: Runtime::Docker, project: None, dir: "/work".into() }),
    ];
    let memory = HashMap::from([(db.clone(), 50u64 << 20), ("aaaa".into(), 100 << 20), ("bbbb".into(), 200 << 20)]);
    let found = containers(Runtime::Docker, &ps, &memory, &hints);
    let s1 = &found["s1"];
    assert_eq!((s1.len(), s1[0].kind, s1[0].name.as_str(), s1[0].memory, s1[0].since), (1, Kind::Container, "db", 50 << 20, 1000));
    let s2 = &found["s2"];
    assert_eq!(s2.len(), 1, "a project is one thing: {s2:?}");
    assert_eq!((s2[0].name.as_str(), s2[0].memory), ("shop", 300 << 20), "{s2:?}");
    assert_eq!(found.len(), 2, "what no command of a task's brought up isn't any task's");
}

#[test]
fn a_simulator_is_the_tasks_that_booted_it() {
    let list = r#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
        {"udid":"AAAA","name":"iPhone 18 Pro","state":"Booted"},
        {"udid":"BBBB","name":"iPad Air","state":"Booted"},
        {"udid":"CCCC","name":"iPhone SE","state":"Shutdown"}]}}"#;
    // When each booted, as its launchd_sim started; and what it holds.
    let booted = HashMap::from([("AAAA".to_string(), (100_000i64, 3u64 << 30)), ("BBBB".to_string(), (10_000, 1 << 30))]);
    let hints = [
        ("s1".to_string(), 99_000, Hint::Simulator { device: Some("iPhone 18 Pro".into()) }),
        // Booted long before this task asked: someone else's.
        ("s2".to_string(), 50_000, Hint::Simulator { device: None }),
    ];
    let found = simulators(list, &booted, &hints);
    let s1 = &found["s1"];
    assert_eq!(
        (s1.len(), s1[0].kind, s1[0].name.as_str(), s1[0].memory, s1[0].since),
        (1, Kind::Simulator, "iPhone 18 Pro", 3 << 30, 100_000)
    );
    assert!(!found.contains_key("s2"), "{found:?}");
}

#[test]
fn looking_costs_zerod_little_once_it_has_looked() {
    let mut finder = Finder::default();
    let roots: Vec<Root> = (0..50).map(|n| Root { session: format!("s{n}"), pid: Some(std::process::id() as i32), idle: true }).collect();
    let began = std::time::Instant::now();
    finder.processes(&roots);
    let first = began.elapsed();
    let began = std::time::Instant::now();
    finder.processes(&roots);
    let took = began.elapsed();
    eprintln!("first look {first:?}, then {took:?}");
    assert!(took < Duration::from_millis(50), "{took:?}");
}
