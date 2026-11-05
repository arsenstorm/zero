//! Every turn of a task Zero runs ends on Zero's ending, whichever agent runs it: done, completed, blocked, working,
//! or asked (an ask, a command or steps for the user, by its id). One that doesn't, or that ends on a question it
//! never asked, is sent back once, unseen in the conversation, to end properly.

use std::sync::Arc;
use std::time::Duration;

use crate::common::temp_dir;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

/// An agent that stays connected and keeps what it's sent, to read back.
fn listening(sent: Arc<std::sync::Mutex<String>>) -> Runtime {
    Arc::new(move |_, _, _| {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        std::mem::forget(theirs);
        let (writer, mut reader) = tokio::io::duplex(1 << 20);
        let sent = sent.clone();
        tokio::spawn(async move {
            use tokio::io::AsyncReadExt;
            let mut buffer = vec![0u8; 1 << 16];
            while let Ok(n) = reader.read(&mut buffer).await { if n == 0 { break } sent.lock().unwrap().push_str(&String::from_utf8_lossy(&buffer[..n])) }
        });
        Ok(zerod::session::Transport::new(ours, writer))
    })
}

fn item(id: &str, kind: ItemKind) -> Change { Change::Item { item: Item { at: None, id: id.into(), turn: None, kind, status: ItemStatus::Done } } }

/// A turn: the user's message (or Zero's), the agent's answer, between turns again.
async fn turn(session: &zerod::session::Session, n: usize, said: &str, answer: &str) {
    session.change(Change::Status { status: Status::Working, turn: Some(format!("t{n}")), error: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
    session.change(item(&format!("u{n}"), ItemKind::User { text: said.into(), images: vec![] }));
    session.change(item(&format!("a{n}"), ItemKind::Agent { text: answer.into(), final_answer: true }));
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    tokio::time::sleep(Duration::from_millis(300)).await;
}

/// Words Zero gave the task (an event, a report): a turn the user isn't in.
fn zeros(text: &str) -> String { zerod::model::from_line("zero", text) }

/// How many times the agent has been sent back to end its turn properly.
fn sent_back(sent: &Arc<std::sync::Mutex<String>>) -> usize { sent.lock().unwrap().matches(zerod::daemon::END_YOUR_TURN_MARK).count() }

async fn task(home: &std::path::Path, provider: Provider) -> (Arc<Daemon>, String, Arc<std::sync::Mutex<String>>) {
    let sent = Arc::new(std::sync::Mutex::new(String::new()));
    let daemon = Daemon::open(&home.join("zerod"), listening(sent.clone())).unwrap();
    daemon.require_endings();
    let id = daemon.start(provider, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    (daemon, id, sent)
}

#[tokio::test]
async fn a_turn_without_an_ending_is_sent_back_once_whichever_agent_runs_it() {
    let home = temp_dir("endings-missing");
    let (daemon, id, sent) = task(&home, Provider::Claude).await;
    let session = daemon.session(&id).unwrap();
    turn(&session, 1, &zeros("1 new event on what you follow"), "Yes, it's merged and deployed.").await;
    assert_eq!(sent_back(&sent), 1, "sent back: {}", sent.lock().unwrap());
}

#[tokio::test]
async fn a_question_it_never_asked_is_sent_back_even_with_an_ending() {
    let home = temp_dir("endings-question");
    let (daemon, id, sent) = task(&home, Provider::Claude).await;
    let session = daemon.session(&id).unwrap();
    turn(&session, 1, &zeros("1 new event on what you follow"), "The deploy finished.\n\nShould I start the check, or wait for Dana?\n\n[zero: working]").await;
    assert_eq!(sent_back(&sent), 1);
}

#[tokio::test]
async fn a_proper_ending_passes_and_a_reply_to_being_sent_back_is_taken_as_it_is() {
    let home = temp_dir("endings-fine");
    let (daemon, id, sent) = task(&home, Provider::Claude).await;
    let session = daemon.session(&id).unwrap();
    turn(&session, 1, &zeros("1 new event on what you follow"), "Merged and checked.\n\n[zero: completed]").await;
    turn(&session, 2, &zeros("A worker's report"), "Should I?\n\n[zero: asked k3x9qa]").await;
    assert_eq!(sent_back(&sent), 0, "endings that say it: nothing to send back");
    // Sent back, and its next turn still doesn't end properly: taken as it is, not sent back again.
    turn(&session, 3, &zeros("1 new event on what you follow"), "All done.").await;
    turn(&session, 4, "(sent back)", "Sorry, all done.").await;
    assert_eq!(sent_back(&sent), 1);
}

#[tokio::test]
async fn a_worker_reports_to_its_lead_and_needs_no_ending() {
    let home = temp_dir("endings-worker");
    let (daemon, lead, sent) = task(&home, Provider::Claude).await;
    let worker = daemon.spawn(&lead, Provider::Claude, "check it", Default::default()).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    turn(&daemon.session(&worker).unwrap(), 1, "check it", "Checked: all green.").await;
    assert_eq!(sent_back(&sent), 0);
}

#[tokio::test]
async fn a_turn_stopped_by_the_user_or_a_restart_isnt_sent_back() {
    let home = temp_dir("endings-stopped");
    let (daemon, id, sent) = task(&home, Provider::Claude).await;
    let session = daemon.session(&id).unwrap();
    // An answer without an ending, sent back, and taken as it was the second time.
    turn(&session, 1, &zeros("1 new event on what you follow"), "Yes.").await;
    turn(&session, 2, "(sent back)", "Yes, merged.").await;
    // Then a turn stopped before it answered: the earlier answer isn't this turn's.
    session.change(Change::Status { status: Status::Working, turn: Some("t3".into()), error: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
    session.change(item("u3", ItemKind::User { text: "Fix it".into(), images: vec![] }));
    session.change(item("a3", ItemKind::Agent { text: "Looking at the logs.".into(), final_answer: false }));
    session.change(item("n3", ItemKind::Notice { text: "Interrupted".into(), error: false }));
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(sent_back(&sent), 1, "it didn't end, it was stopped: {}", sent.lock().unwrap());
}

#[tokio::test]
async fn a_turn_stopped_after_it_said_something_isnt_sent_back_either() {
    let home = temp_dir("endings-stopped-late");
    let (daemon, id, sent) = task(&home, Provider::Claude).await;
    let session = daemon.session(&id).unwrap();
    session.change(Change::Status { status: Status::Working, turn: Some("t1".into()), error: None });
    tokio::time::sleep(Duration::from_millis(100)).await;
    session.change(item("u1", ItemKind::User { text: "Fix it".into(), images: vec![] }));
    session.change(item("a1", ItemKind::Agent { text: "Fixed the CLI too:".into(), final_answer: true }));
    session.change(item("n1", ItemKind::Notice { text: "Interrupted".into(), error: false }));
    session.change(Change::Status { status: Status::Idle, turn: None, error: None });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(sent_back(&sent), 0, "stopped mid-way, its words so far aren't its answer: {}", sent.lock().unwrap());
}

#[tokio::test]
async fn a_turn_the_users_own_words_started_is_a_conversation_and_isnt_sent_back() {
    // The user is in the chat: a question in the reply is how a conversation goes, not a need left in prose.
    let home = temp_dir("endings-conversation");
    let (daemon, id, sent) = task(&home, Provider::Claude).await;
    let session = daemon.session(&id).unwrap();
    turn(&session, 1, "What's left on the issue?", "Three things are left.\n\nWhich do you want to start with?\n\n[zero: done]").await;
    turn(&session, 2, "The formatters", "Here's what they take.").await;
    assert_eq!(sent_back(&sent), 0, "{}", sent.lock().unwrap());
}
