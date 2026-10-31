//! Loops: named instructions an agent follows, kept as Markdown files, named as `@name` in a message or a brief and
//! expanded into their words for the agent; a loop names its children, never a parent; each use is recorded.

mod common;

use common::temp_dir;
use serde_json::json;
use zerod::core::Core;
use zerod::loops::*;
use zerod::model::*;

#[test]
fn a_loop_is_a_markdown_file_with_a_description_and_the_children_it_names() {
    let root = temp_dir("loops-files");
    let loops = Loops::open(&root);
    let worker = loops.save("ticket-worker", "One ticket, on its bench", "Claim a bench. Do the task. Verify with /verify.").unwrap();
    assert_eq!(std::fs::read_to_string(root.join("ticket-worker.md")).unwrap(), "---\ndescription: One ticket, on its bench\n---\nClaim a bench. Do the task. Verify with /verify.");
    assert!(worker.children.is_empty());
    let batch = loops.save("batch", "", "For each ticket, start a worker on @ticket-worker; @nothing isn't a loop.").unwrap();
    assert_eq!(batch.children, ["ticket-worker"]);
    assert_eq!(loops.list().iter().map(|l| l.name.as_str()).collect::<Vec<_>>(), ["batch", "ticket-worker"]);
    assert!(loops.save("Ticket Worker", "", "x").unwrap_err().contains("lowercase"));
    loops.delete("batch").unwrap();
    assert!(loops.read("batch").is_err());
}

#[test]
fn a_loop_names_its_children_never_a_parent() {
    let loops = Loops::open(&temp_dir("loops-cycle"));
    loops.save("batch", "", "Start workers on @ticket-worker.").unwrap();
    loops.save("ticket-worker", "", "Do the ticket.").unwrap();
    assert!(loops.save("ticket-worker", "", "When done, run @batch again.").unwrap_err().contains("leads back"));
    assert!(loops.save("batch", "", "Run @batch again.").unwrap_err().contains("leads back"));
}

#[test]
fn a_name_in_the_words_becomes_the_loops_words_and_the_record_keeps_the_name() {
    let loops = Loops::open(&temp_dir("loops-expand"));
    loops.save("batch", "Tickets, one worker each", "For each ticket, start a worker on @ticket-worker.").unwrap();
    loops.save("ticket-worker", "", "Do the ticket.").unwrap();
    let (text, used) = loops.expand("Run @batch for ENG-9790 and ENG-9793. Mail me@example.com; @nobody stays.");
    assert_eq!(used, ["batch"]);
    assert_eq!(text, "Run <!-- loop: batch -->\n## Loop: batch\n\nTickets, one worker each\n\nFor each ticket, start a worker on @ticket-worker.\n<!-- /loop: batch --> for ENG-9790 and ENG-9793. Mail me@example.com; @nobody stays.",
               "the child stays a name inside: a reference, not an inclusion");
    assert_eq!(collapse(&text), "Run @batch for ENG-9790 and ENG-9793. Mail me@example.com; @nobody stays.");
    // A message of yours that named a loop is kept with the name, whatever the agent was given.
    let mut core = Core::new(Conversation::new("s1", Provider::Claude, "/w"));
    core.sent(&json!({"type": "user", "message": {"role": "user", "content": text}}));
    assert!(matches!(&core.conversation().items[0].kind, ItemKind::User { text, .. } if text == "Run @batch for ENG-9790 and ENG-9793. Mail me@example.com; @nobody stays."));
}

#[test]
fn each_use_is_recorded_by_session_and_role() {
    let loops = Loops::open(&temp_dir("loops-uses"));
    loops.save("batch", "", "Go.").unwrap();
    loops.record("batch", "s1", "lead");
    loops.record("batch", "s2", "worker");
    let uses = loops.read("batch").unwrap().uses;
    assert_eq!(uses.iter().map(|u| (u.session.as_str(), u.role.as_str())).collect::<Vec<_>>(), [("s1", "lead"), ("s2", "worker")]);
    assert!(uses.iter().all(|u| u.at > 0));
}
