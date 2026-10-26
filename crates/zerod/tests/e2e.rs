//! The real runtimes, through the daemon: for each provider a session started, answered, stopped and resumed.
//! Ignored by default, since each runs as its CLI's own sign-in and spends two short turns of its usage:
//! `cargo test -p zerod --test e2e -- --ignored`, or one provider with its name after `--ignored`.

mod common;

use std::time::Duration;

use common::temp_dir;
use zerod::daemon::Daemon;
use zerod::model::{Conversation, ItemKind, Provider, Status};

async fn until(daemon: &Daemon, session: &str, test: impl Fn(&Conversation) -> bool) -> Conversation {
    for _ in 0..1200 {
        let now = daemon.get(session).unwrap();
        if test(&now) { return now }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("timed out: {:#?}", daemon.get(session));
}

fn answer(conversation: &Conversation) -> Option<String> {
    conversation.items.iter().rev().find_map(|item| match &item.kind {
        ItemKind::Agent { text, final_answer: true } => Some(text.to_lowercase()),
        _ => None,
    })
}

async fn answers_stops_and_resumes(provider: Provider, model: Option<&str>) {
    let home = temp_dir(&format!("e2e-{provider:?}"));
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let daemon = Daemon::open(&home, zerod::daemon::real_runtime()).unwrap();
    let id = daemon.start(provider, project.to_str().unwrap(), "Reply with the single word pong, nothing else.", model, None, Default::default()).unwrap();
    let first = until(&daemon, &id, |c| c.status == Status::Idle && answer(c).is_some()).await;
    assert!(answer(&first).unwrap().contains("pong"), "{first:#?}");
    assert!(first.thread.is_some());

    daemon.stop(&id).unwrap();
    until(&daemon, &id, |c| c.status == Status::Offline).await;
    daemon.send(&id, "Now reply with the single word ping, nothing else.", None, None).await.unwrap();
    let second = until(&daemon, &id, |c| c.status == Status::Idle && answer(c).is_some_and(|a| a.contains("ping"))).await;
    assert_eq!(second.thread, first.thread, "the same conversation, resumed");
}

#[tokio::test]
#[ignore = "runs the real Codex"]
async fn codex() {
    answers_stops_and_resumes(Provider::Codex, None).await
}

#[tokio::test]
#[ignore = "runs the real Claude Code"]
async fn claude() {
    answers_stops_and_resumes(Provider::Claude, Some("haiku")).await
}

#[tokio::test]
#[ignore = "runs the real OpenCode"]
async fn opencode() {
    answers_stops_and_resumes(Provider::Opencode, Some("opencode-go/beam-free")).await
}

#[tokio::test]
#[ignore = "runs the real Claude Code"]
async fn claude_asks_a_question_and_uses_the_answer() {
    let home = temp_dir("e2e-question");
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let daemon = Daemon::open(&home, zerod::daemon::real_runtime()).unwrap();
    let prompt = "Use the AskUserQuestion tool to ask me one question: which colour I prefer, with the options Teal and Amber. \
                  Then reply with only the colour I picked.";
    let id = daemon.start(Provider::Claude, project.to_str().unwrap(), prompt, Some("haiku"), None, Default::default()).unwrap();
    let asked = until(&daemon, &id, |c| !c.questions.is_empty()).await;
    let question = &asked.questions[0];
    assert_eq!(question.fields[0].options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(), ["Teal", "Amber"], "{question:#?}");
    let answers = std::collections::HashMap::from([(question.fields[0].id.clone(), vec!["Amber".to_string()])]);
    daemon.answer(&id, &question.id, &answers).await.unwrap();
    let done = until(&daemon, &id, |c| c.status == Status::Idle && answer(c).is_some()).await;
    assert!(answer(&done).unwrap().contains("amber"), "{done:#?}");
    daemon.stop(&id).unwrap();
}

#[tokio::test]
#[ignore = "runs the real Claude Code, twice"]
async fn a_real_lead_hears_from_its_real_worker() {
    let home = temp_dir("e2e-lead");
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let daemon = Daemon::open(&home, zerod::daemon::real_runtime()).unwrap();
    let lead = daemon.start(Provider::Claude, project.to_str().unwrap(),
        "You lead one worker. Reply now with only the word ready. Later a message will report what the worker found; \
         when it does, reply with only the number it found.", Some("haiku"), None, Default::default()).unwrap();
    until(&daemon, &lead, |c| c.status == Status::Idle && answer(c).is_some_and(|a| a.contains("ready"))).await;
    let options = zerod::daemon::Options { label: Some("Counter".into()), model: Some("haiku".into()), ..Default::default() };
    let worker = daemon.spawn(&lead, Provider::Claude, "Reply with only the number 4217, nothing else.", options).unwrap();
    until(&daemon, &worker, |c| c.status == Status::Idle && answer(c).is_some_and(|a| a.contains("4217"))).await;
    let heard = until(&daemon, &lead, |c| c.status == Status::Idle && answer(c).is_some_and(|a| a.contains("4217"))).await;
    let told = heard.items.iter().any(|i| matches!(&i.kind, ItemKind::User { text } if text.starts_with("Worker Counter finished: 4217")));
    assert!(told, "{heard:#?}");
    daemon.stop(&worker).ok();
    daemon.stop(&lead).ok();
}
