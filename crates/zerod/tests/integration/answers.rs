//! Agents' answers in plain technical English: every CLI is told the rules for its final message of a turn, unless the
//! user turned them off, for all tasks (Settings) or for one workspace.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::{Seen, fixture, play, temp_dir};
use zerod::adapter::{ANSWERS, INSTRUCTIONS};
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::{Conversation, Provider};
use zerod::workspaces::Workspace;

type Started = Arc<Mutex<Vec<(Vec<String>, Seen)>>>;

fn runtime(started: Started) -> Runtime {
    Arc::new(move |conversation: &Conversation, _: &std::path::Path, argv: &[String]| {
        let script = if conversation.provider == Provider::Codex { fixture("codex-command") } else { vec![] };
        let (transport, seen) = play(script);
        started.lock().unwrap().push((argv.to_vec(), seen));
        Ok(transport)
    })
}

fn appended(argv: &[String]) -> &str {
    let at = argv.iter().position(|a| a == "--append-system-prompt").unwrap();
    &argv[at + 1]
}

async fn codex_instructions(seen: &Seen) -> String {
    for _ in 0..500 {
        if let Some(thread) = seen.first("thread/start") {
            return thread["params"]["developerInstructions"].as_str().unwrap().to_string();
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("Codex got no thread/start")
}

#[tokio::test]
async fn agents_are_told_the_answer_rules_unless_the_user_turned_them_off_for_all_or_a_workspace() {
    let home = temp_dir("answers");
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let started: Started = Default::default();
    let daemon = Daemon::open(&home, runtime(started.clone())).unwrap();
    let quiet = Workspace { id: "quiet".into(), name: "Quiet".into(), glyph: "".into(), color: "".into(), plain_answers: Some(false) };
    daemon.workspaces.save(quiet).unwrap();
    let start = |provider: Provider, workspace: Option<&str>| {
        let options = Options { cwd: Some(project.to_str().unwrap().into()), workspace: workspace.map(Into::into), ..Default::default() };
        daemon.start(provider, "hi", options).unwrap();
        started.lock().unwrap().last().cloned().unwrap()
    };

    let (argv, _) = start(Provider::Claude, None);
    assert_eq!(appended(&argv), format!("{INSTRUCTIONS} {ANSWERS}"), "on by default");
    let (_, seen) = start(Provider::Codex, None);
    assert_eq!(codex_instructions(&seen).await, format!("{INSTRUCTIONS} {ANSWERS}"), "Codex's developer instructions too");

    let (argv, _) = start(Provider::Claude, Some("quiet"));
    assert_eq!(appended(&argv), INSTRUCTIONS, "off for its workspace");
    let (_, seen) = start(Provider::Codex, Some("quiet"));
    assert_eq!(codex_instructions(&seen).await, INSTRUCTIONS);

    std::fs::write(home.join("settings.json"), r#"{"plainAnswers": false}"#).unwrap();
    let (argv, _) = start(Provider::Claude, None);
    assert_eq!(appended(&argv), INSTRUCTIONS, "off for every task");
}

#[test]
fn the_rules_cover_the_final_message_alone_and_stay_short() {
    for said in ["final message", "20 words", "25", "active voice", "condition", "numbered list", "not your thinking", "other agents"] {
        assert!(ANSWERS.contains(said), "{said}");
    }
    assert!(ANSWERS.split_whitespace().count() < 120, "every agent's prompt carries it");
}
