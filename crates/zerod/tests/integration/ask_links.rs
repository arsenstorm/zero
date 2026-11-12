//! Asks that link to what they're about: the agent's words just before an ask go with it, or a heading it names
//! (`zero ask --about "#bench-plan"`); and the agent's answer to the user's question about an ask stays with that ask.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::common::{Seen, play, temp_dir};
use serde_json::json;
use zerod::ask::{About, AgentIdentity, Ask, AskKind};
use zerod::daemon::{Daemon, Runtime};
use zerod::inbox::Inbox;
use zerod::model::{Attention, Change, Conversation, Item, ItemKind, ItemStatus, Provider};

struct World {
    daemon: Arc<Daemon>,
    project: PathBuf,
    claude: Arc<Mutex<Vec<Seen>>>,
}

fn world(name: &str) -> World {
    let home = temp_dir(name);
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let claude = Arc::new(Mutex::new(vec![]));
    let seen = claude.clone();
    let runtime: Runtime = Arc::new(move |_: &Conversation, _: &std::path::Path, _: &[String]| {
        let (transport, recorder) = play(vec![]);
        seen.lock().unwrap().push(recorder);
        Ok(transport)
    });
    World { daemon: Daemon::open(&home, runtime).unwrap(), project, claude }
}

/// A Claude session past its first turn, idle; the inbox reaching it, its asks linked.
async fn asking(w: &World) -> (String, Seen, Arc<Inbox>) {
    let options = zerod::daemon::Options { cwd: Some(w.project.to_str().unwrap().into()), ..Default::default() };
    let id = w.daemon.start(Provider::Claude, "hi", options).unwrap();
    let mut seen = None;
    for _ in 0..500 {
        if let Some(found) = w.claude.lock().unwrap().last().cloned() {
            seen = Some(found);
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let seen = seen.expect("Claude started");
    seen.said("user", 1).await;
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"}));
    until(&w.daemon, &id, |c| c.attention() == Attention::Idle).await;
    let inbox = Inbox::open(None, vec![Arc::new(zerod::daemon::Sessions::of(&w.daemon))]);
    inbox.configure(Duration::from_millis(20), 3600);
    zerod::server::link_asks(&w.daemon, &inbox);
    (id, seen, inbox)
}

async fn until(daemon: &Daemon, session: &str, test: impl Fn(&Conversation) -> bool) -> Conversation {
    for _ in 0..1000 {
        if let Some(now) = daemon.get(session)
            && test(&now)
        {
            return now;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out: {:#?}", daemon.get(session));
}

fn said(id: &str, kind: ItemKind) -> Change {
    Change::Item { item: Item { at: Some(1_700_000_000_000), id: id.into(), turn: None, kind, status: ItemStatus::Done } }
}

fn user(text: &str) -> ItemKind {
    ItemKind::User { text: text.into(), images: vec![], sent: None }
}

fn agent(text: &str, final_answer: bool) -> ItemKind {
    ItemKind::Agent { text: text.into(), final_answer }
}

fn question(session: &str, title: &str) -> Ask {
    let agent = AgentIdentity {
        name: format!("zerod-{session}"),
        host: "mac".into(),
        runtime: Some("zerod".into()),
        reference: Some(session.into()),
        ..Default::default()
    };
    let mut ask = Ask::new(AskKind::Choice, title, agent, 3600);
    ask.options = vec!["Bench 3".into(), "Bench 5".into()];
    ask.waits = Some(false);
    ask
}

fn about(anchor: &str) -> Option<About> {
    Some(About { anchor: Some(anchor.into()), ..Default::default() })
}

#[tokio::test]
async fn an_ask_is_about_what_its_agent_wrote_just_before_it() {
    let w = world("links-auto");
    let (id, _seen, inbox) = asking(&w).await;
    let session = w.daemon.session(&id).unwrap();
    session.change(said("u2", user("Pick a bench for the migration")));
    session.change(said("a1", agent("## Bench plan\n\nBench 3 has Redis; bench 5 is free.\n\n## Risks\n\nNone.", false)));
    let ask = inbox.create(question(&id, "Which bench?"), false);
    let about = ask.about.expect("about the words before it");
    assert_eq!((about.item.as_str(), about.title.as_str(), about.anchor), ("a1", "Bench plan", None));
    assert!(about.text.contains("Bench 3 has Redis") && about.text.contains("None."), "the whole message: {}", about.text);
    assert_eq!(about.at, Some(1_700_000_000_000));

    // Without a heading, its first words.
    session.change(said("a2", agent("The migration needs a bench with Redis on it, and two of them are free right now.", false)));
    let worded = inbox.create(question(&id, "Which bench?"), false).about.unwrap();
    assert!(worded.title.starts_with("The migration needs a bench") && worded.title.ends_with('…'), "{}", worded.title);
    assert!(worded.title.chars().count() <= 61, "{}", worded.title);

    // A turn with no words of the agent's before its ask is about nothing: an earlier turn's words aren't this one's.
    session.change(said("u3", user("Go on")));
    assert_eq!(inbox.create(question(&id, "Go?"), false).about, None);

    // An agent outside Zero's sessions has no conversation here to point into.
    let mut outside = question(&id, "Elsewhere?");
    outside.agent = AgentIdentity { name: "terminal-agent".into(), host: "mac".into(), ..Default::default() };
    assert_eq!(inbox.create(outside, false).about, None);
}

#[tokio::test]
async fn an_ask_links_to_a_heading_of_its_conversation_by_its_anchor() {
    let w = world("links-anchor");
    let (id, _seen, inbox) = asking(&w).await;
    let session = w.daemon.session(&id).unwrap();
    session.change(said("u2", user("Plan it")));
    session.change(said("a1", agent("## Bench plan\n\nThe old plan.", true)));
    session.change(said("u3", user("Plan it again")));
    let plan = "# Status\n\n## Bench plan\n\nBench 3.\n\n### Why\n\nRedis.\n\n## Risks\n\nNone.\n\n[zero: asked k2m4p6]";
    session.change(said("a2", agent(plan, true)));
    session.change(said("u4", user("And the docs?")));
    session.change(said("a3", agent("Docs are fine.", false)));

    // The latest heading with that anchor, its section alone (to the next heading as high as it), over the automatic.
    let mut ask = question(&id, "Which bench?");
    ask.about = about("#bench-plan");
    let linked = inbox.create(ask, false).about.unwrap();
    assert_eq!((linked.item.as_str(), linked.title.as_str(), linked.anchor.as_deref()), ("a2", "Bench plan", Some("bench-plan")));
    assert!(linked.text.contains("Bench 3.") && linked.text.contains("Redis."), "{}", linked.text);
    assert!(!linked.text.contains("None.") && !linked.text.contains("old plan"), "{}", linked.text);

    // An item's own id is an anchor too: the whole message, Zero's ending left out.
    let mut ask = question(&id, "This one?");
    ask.about = about("a2");
    let whole = inbox.create(ask, false).about.unwrap();
    assert_eq!((whole.item.as_str(), whole.title.as_str()), ("a2", "Status"));
    assert!(whole.text.contains("None.") && !whole.text.contains("[zero:"), "{}", whole.text);

    // An anchor that isn't there is the agent's to fix: told which there are, and no ask is made.
    let mut ask = question(&id, "Which?");
    ask.about = about("#bench-plans");
    let refused = inbox.about(&mut ask).unwrap_err();
    assert!(refused.contains("#bench-plans") && refused.contains("#risks"), "{refused}");
}

#[tokio::test]
async fn the_agents_answer_to_the_users_question_on_an_ask_stays_with_it() {
    let w = world("links-replies");
    let (id, seen, inbox) = asking(&w).await;
    let ask = inbox.create(question(&id, "Which bench?"), false);
    // "Something else…", in the user's words: a question back.
    inbox.answer(&ask.id, 2, "what's on bench 5?");
    seen.said("user", 2).await;
    let reply = "Bench 5 runs the staging Redis, so the migration would share it.\n\n[zero: asked k2m4p7]";
    seen.say(json!({"type": "assistant", "message": {"id": "m2", "content": [{"type": "text", "text": reply}]}}));
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": reply}));
    let mut replies = vec![];
    for _ in 0..300 {
        replies = inbox.ask(&ask.id).unwrap().replies;
        if !replies.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(replies.len(), 1, "kept with the ask");
    assert_eq!(replies[0].item, "m2:0");
    assert_eq!(replies[0].text, "Bench 5 runs the staging Redis, so the migration would share it.");

    // An option picked is a decision, not a question: what the agent says next isn't the ask's.
    let decided = inbox.create(question(&id, "Merge it?"), false);
    inbox.choose(&decided.id, 0);
    seen.said("user", 3).await;
    seen.say(json!({"type": "assistant", "message": {"id": "m3", "content": [{"type": "text", "text": "Merging."}]}}));
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "Merging."}));
    until(&w.daemon, &id, |c| c.items.iter().any(|i| i.id == "m3:0") && c.attention() != Attention::Working).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(inbox.ask(&decided.id).unwrap().replies.is_empty());
    assert_eq!(inbox.ask(&ask.id).unwrap().replies.len(), 1, "nor the earlier ask's");
}

#[tokio::test]
async fn words_written_to_a_task_while_one_ask_is_open_are_about_it_and_so_is_the_answer() {
    // The user asks about the card in the chat, under it, rather than answering it: the ask stays open, and the agent's
    // answer is kept with it. With two open, Zero can't tell which the words are about: neither keeps it.
    let w = world("links-chat");
    let (id, seen, inbox) = asking(&w).await;
    let ask = inbox.create(question(&id, "Which bench?"), false);
    // As the send op gives the user's words to the task.
    let text = inbox.with_open_asks(&id, "is bench 5 shared?".into());
    w.daemon.send(&id, zerod::session::Message::text(&text), Default::default()).await.unwrap();
    seen.said("user", 2).await;
    seen.say(json!({"type": "assistant", "message": {"id": "m2", "content": [{"type": "text", "text": "Yes, with staging."}]}}));
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "Yes, with staging."}));
    let mut replies = vec![];
    for _ in 0..300 {
        replies = inbox.ask(&ask.id).unwrap().replies;
        if !replies.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(replies.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(), ["Yes, with staging."]);
    assert!(!inbox.ask(&ask.id).unwrap().state.is_final(), "still the user's to answer");

    let other = inbox.create(question(&id, "Merge it?"), false);
    let text = inbox.with_open_asks(&id, "and the docs?".into());
    w.daemon.send(&id, zerod::session::Message::text(&text), Default::default()).await.unwrap();
    seen.said("user", 3).await;
    seen.say(json!({"type": "assistant", "message": {"id": "m3", "content": [{"type": "text", "text": "Docs are fine."}]}}));
    seen.say(json!({"type": "result", "subtype": "success", "is_error": false, "result": "Docs are fine."}));
    until(&w.daemon, &id, |c| c.items.iter().any(|i| i.id == "m3:0") && c.attention() != Attention::Working).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(inbox.ask(&ask.id).unwrap().replies.len(), 1);
    assert!(inbox.ask(&other.id).unwrap().replies.is_empty());
}
