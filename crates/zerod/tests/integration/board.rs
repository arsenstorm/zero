//! The board: one row per task Zero runs, across every agent at once. A lead's workers fold into its row; the row says
//! where it runs, its state, where the agent is now (its latest note) and what it needs from the user.

use zerod::ask::{AgentIdentity, Ask, AskKind};
use zerod::board::{State, Waiting, board};
use zerod::model::*;

fn session(id: &str, cwd: &str, status: Status) -> Conversation {
    let mut conversation = Conversation::new(id, Provider::Claude, cwd);
    conversation.status = status;
    conversation
}

fn agent(session: &str) -> AgentIdentity {
    AgentIdentity { name: format!("zerod-{session}"), host: "mac".into(), runtime: Some("zerod".into()), reference: Some(session.into()), ..Default::default() }
}

fn note(session: &str, body: &str, status: Option<&str>, needs: Option<&str>) -> Ask {
    let mut note = Ask::new(AskKind::Note, "Update", agent(session), 0);
    note.body = body.into();
    note.status = status.map(String::from);
    note.needs = needs.map(String::from);
    note
}

/// What zerod posts itself as a session's attention changes.
fn dot(body: &str, status: Option<&str>) -> Ask {
    let mut dot = note("a", body, status, None);
    dot.request = Some(zerod::board::ATTENTION.into());
    dot
}

#[test]
fn a_leads_workers_fold_into_its_row() {
    let mut lead = session("lead", "/work/app", Status::Idle);
    lead.label = Some("Save & end double mail".into());
    lead.ticket = Some("ENG-9759".into());
    let mut worker = session("worker", "/work/app", Status::Working);
    worker.parent = Some("lead".into());
    let rows = board(&[lead, worker], &[]);
    assert_eq!(rows.len(), 1);
    let row = &rows[0];
    assert_eq!((row.session.as_str(), row.task.as_str(), row.ticket.as_deref()), ("lead", "Save & end double mail", Some("ENG-9759")));
    assert_eq!((row.state, row.workers), (State::Working, 1), "a lead idle while its worker works is working");
}

#[test]
fn the_agents_own_note_says_where_it_is_and_what_it_needs() {
    let lead = session("a", "/work/app", Status::Idle);
    let asks = [note("a", "Three rounds done; rare races remain", Some("done"), Some("ship as is or one more round")), dot("Answered", Some("done"))];
    let row = &board(std::slice::from_ref(&lead), &asks)[0];
    assert_eq!(row.now.as_deref(), Some("Three rounds done; rare races remain"), "zerod's own dots aren't the agent's words");
    // Done, with a step only the user can take: over to them. Not blocked, not a decision: a to-do.
    assert_eq!((row.state, row.needs.as_deref()), (State::Handed, Some("ship as is or one more round")));

    let later = [asks[0].clone(), note("a", "Round 4 pushed", Some("done"), None)];
    let row = &board(std::slice::from_ref(&lead), &later)[0];
    assert_eq!((row.state, row.needs.as_deref(), row.now.as_deref()), (State::Done, None, Some("Round 4 pushed")), "a later note without needs clears them");
    // Done is the work finished; merged is it shipped.
    let shipped = [note("a", "Merged #13336", Some("merged"), None)];
    assert_eq!(board(std::slice::from_ref(&lead), &shipped)[0].state, State::Done, "merged, as agents said it before: done");
    assert_eq!(board(&[lead], &[note("a", "Shipped and checked", Some("completed"), None)])[0].state, State::Done, "completed, as agents said it before: done");
}

#[test]
fn a_new_turn_clears_what_the_last_note_said() {
    let lead = session("a", "/work/app", Status::Idle);
    let asks = [note("a", "Waits for ENG-9759", Some("waiting"), Some("agree the periodic job")), dot("Working", None), dot("Done", Some("done"))];
    let row = &board(&[lead], &asks)[0];
    assert_eq!((row.state, row.needs.as_deref(), row.now.as_deref()), (State::Idle, None, None));
}

#[test]
fn done_or_merged_stands_through_turns_zero_started_until_the_user_speaks() {
    // Merged, then told of a QA write-up it follows: that turn changes nothing, and Merged stands.
    let mut lead = session("a", "/work/app", Status::Idle);
    let mut merged = note("a", "Merged #6714", Some("merged"), None);
    merged.created_at = zerod::ask::Time(1_000);
    let said = |text: &str, at: i64| Item { at: Some(at * 1000), id: format!("u{at}"), turn: None, kind: ItemKind::User { text: text.into(), images: vec![] }, status: ItemStatus::Done };
    lead.items.push(said(&from_line("zero", "1 new event on what you follow"), 1_100));
    let asks = [merged.clone(), dot("Working", None), dot("Done", Some("done"))];
    assert_eq!(board(&[lead.clone()], &asks)[0].state, State::Done);
    // The user's own word after it: whatever it was is theirs to settle again.
    lead.items.push(said("Can you also bump the base image?", 1_200));
    assert_ne!(board(&[lead], &asks)[0].state, State::Done);
}

#[test]
fn without_a_note_it_shows_the_agents_last_answer() {
    let mut lead = session("a", "/work/app", Status::Idle);
    lead.items.push(Item { at: None, id: "1".into(), turn: None, kind: ItemKind::Agent { text: "PR #13336 is open.\n\nDetails follow.".into(), final_answer: true }, status: ItemStatus::Done });
    assert_eq!(board(&[lead.clone()], &[])[0].now.as_deref(), Some("PR #13336 is open."));
    lead.items[0].kind = ItemKind::Agent { text: "## Status\n\n| Issue | PR |\n|---|---|\n\nAll four are in PR created.".into(), final_answer: true };
    assert_eq!(board(&[lead], &[])[0].now.as_deref(), Some("All four are in PR created."), "its first line of prose");
}

#[test]
fn an_open_ask_of_a_worker_needs_the_user() {
    let lead = session("lead", "/work/app", Status::Working);
    let mut worker = session("worker", "/work/app", Status::Working);
    worker.parent = Some("lead".into());
    let ask = Ask::new(AskKind::Approve, "Merge it?", agent("worker"), 600);
    let answered = { let mut a = Ask::new(AskKind::Approve, "Earlier", agent("worker"), 600); a.state = zerod::ask::AskState::Answered; a };
    let row = &board(&[lead, worker], &[answered, ask.clone()])[0];
    assert_eq!((row.state, row.asks.clone()), (State::NeedsYou, vec![Waiting { id: ask.id, title: "Merge it?".into() }]));
}

#[test]
fn states_come_from_the_session_and_the_note_most_urgent_first() {
    let waits = session("waits", "/w/a", Status::Idle);
    let failing = session("failing", "/w/b", Status::Working);
    let mut stuck = session("stuck", "/w/c", Status::Working);
    stuck.stalled = Some("No word for 20 minutes".into());
    let working = session("working", "/w/d", Status::Working);
    let done = session("done", "/w/e", Status::Idle);
    let asks = [note("waits", "Waits for ENG-9759", Some("waiting"), None), note("failing", "One test shard failing", Some("blocked"), None)];
    let rows = board(&[done, working, waits, stuck, failing], &asks);
    let states: Vec<(&str, State)> = rows.iter().map(|r| (r.session.as_str(), r.state)).collect();
    // An agent that says it's blocked (or waits on something) is blocked on something the user can't fix: below what's
    // under way. One stuck or failing on its own is in trouble.
    assert_eq!(states, [("stuck", State::Trouble), ("working", State::Working), ("waits", State::Waiting), ("failing", State::Waiting), ("done", State::Idle)],
               "blocked elsewhere asks nothing of the user: it sorts below the work"); 
}

#[test]
fn every_task_is_on_the_board_the_offline_ones_last() {
    // Offline is only not running: a task taken in from elsewhere, or one zerod's restart stopped, is still work.
    let gone = session("gone", "/w/a", Status::Offline);
    let handed_off = session("handed", "/w/b", Status::Offline);
    let working = session("busy", "/w/c", Status::Working);
    let rows = board(&[gone, handed_off, working], &[note("handed", "Live", Some("done"), Some("your Self QA"))]);
    let states: Vec<(&str, bool, State)> = rows.iter().map(|r| (r.session.as_str(), r.online, r.state)).collect();
    // Offline, a row keeps the state it was last known in: what its note said, else idle between turns.
    assert_eq!(states, [("busy", true, State::Working), ("handed", false, State::Handed), ("gone", false, State::Idle)], "most urgent first, online or not");
    let closed = [note("handed", "Live", Some("done"), Some("your Self QA")), note("handed", "Closed by the user", Some("closed"), None)];
    assert_eq!(board(&[session("handed", "/w/b", Status::Offline)], &closed)[0].needs, None, "closing it takes what it handed over");
    let mut offline = dot("Offline", Some("closed"));
    offline.agent = agent("handed");
    let restarted = [note("handed", "Live", Some("done"), Some("your Self QA")), offline];
    assert_eq!(board(&[session("handed", "/w/b", Status::Offline)], &restarted)[0].needs.as_deref(), Some("your Self QA"),
        "going offline (zerod restarting, say) isn't closing it");
}

#[test]
fn where_is_the_shortest_part_of_the_folder_that_tells_rows_apart() {
    let rows = board(&[
        session("a", "/wt/app/teal-yak/app", Status::Working),
        session("b", "/wt/app/blue-fox/app", Status::Working),
        session("c", "/wt/app/blue-fox/app", Status::Working),
        session("d", "/src/zero", Status::Working),
    ], &[]);
    let places: Vec<&str> = rows.iter().map(|r| r.place.as_str()).collect();
    assert_eq!(places, ["teal-yak/app", "blue-fox/app", "blue-fox/app", "zero"]);
}

#[test]
fn where_is_the_tasks_own_place_then_the_places_command_then_its_folder() {
    let mut own = session("a", "/wt", Status::Idle);
    own.place = Some("green-elk".into());
    own.ticket = Some("ENG-1".into());
    let mut listed = session("b", "/wt", Status::Idle);
    listed.ticket = Some("WEB-2".into());
    let plain = session("c", "/wt/lab/blue-fox", Status::Idle);
    let places = zerod::board::parse_places(r#"[{"ticket": "WEB-2", "place": "pink-cod"}, {"ticket": "ENG-1", "place": "other"}, {"ticket": "WEB-2", "place": "gold-bee"}]"#).unwrap();
    let rows = zerod::board::board_with(&[own, listed, plain], &[], &places);
    let wheres: Vec<(&str, &str)> = rows.iter().map(|r| (r.session.as_str(), r.place.as_str())).collect();
    assert_eq!(wheres, [("a", "green-elk"), ("b", "pink-cod, gold-bee"), ("c", "blue-fox")]);
    assert!(zerod::board::parse_places("not json").unwrap_err().starts_with("The places command printed"));
}

#[test]
fn how_the_agent_ended_its_turn_is_the_rows_state() {
    let ended = |text: &str| {
        let mut lead = session("a", "/work/app", Status::Idle);
        lead.items.push(Item { id: "1".into(), turn: None, kind: ItemKind::Agent { text: text.into(), final_answer: true }, status: ItemStatus::Done, at: None });
        board(&[lead], &[])[0].state
    };
    assert_eq!(ended("Merged, deployed and checked; the PM moves the issue on.\n\n[zero: done]"), State::Done, "nothing left that it can do");
    assert_eq!(ended("Pushed all four commits; nothing left.\n\n[zero: completed]"), State::Done, "completed, as agents said it before: done");
    assert_eq!(ended("Deploying; QA checks after.\n[zero: waiting]"), State::Waiting, "the next move is someone else's, not the user's: they'd be asked");
    assert_eq!(ended("Can't reach staging.\n[zero: blocked]"), State::Waiting, "blocked, as agents said it before: waiting");
    assert_eq!(ended("Which one?\n[zero: asked 3f2a]"), State::NeedsYou);
    assert_eq!(ended("Waiting on CI.\n[zero: working]"), State::Answered, "pausing between steps: its reply, to read like any other");
    assert_eq!(ended("Just an answer."), State::Answered, "a turn ended is not a task done; it is a reply to read");
    assert_eq!(ended("Relaunch both, or one session each?"), State::NeedsYou, "a question put to the user in prose waits on them");
    // The agent's own note this turn says more than its ending.
    let mut lead = session("a", "/work/app", Status::Idle);
    lead.items.push(Item { id: "1".into(), turn: None, kind: ItemKind::Agent { text: "Merged.\n[zero: done]".into(), final_answer: true }, status: ItemStatus::Done, at: None });
    assert_eq!(board(&[lead], &[note("a", "Merged #1", Some("merged"), None)])[0].state, State::Done);
}

#[test]
fn a_place_can_say_where_it_is_on_disk_and_the_row_carries_it() {
    let mut listed = session("b", "/wt", Status::Idle);
    listed.ticket = Some("WEB-2".into());
    let mut two = session("c", "/wt", Status::Idle);
    two.ticket = Some("WEB-3".into());
    let places = zerod::board::parse_places(r#"[{"ticket": "WEB-2", "place": "red-owl", "path": "/wt/iron/red-owl"},
        {"ticket": "WEB-3", "place": "a", "path": "/a"}, {"ticket": "WEB-3", "place": "b", "path": "/b"}]"#).unwrap();
    let rows = zerod::board::board_with(&[listed, two], &[], &places);
    let paths: Vec<(&str, Option<&str>)> = rows.iter().map(|r| (r.session.as_str(), r.path.as_deref())).collect();
    assert_eq!(paths, [("b", Some("/wt/iron/red-owl")), ("c", None)], "one place's folder; of several, none to pick");
}

#[test]
fn a_rows_workers_each_carry_their_own_state_place_and_asks() {
    let lead = session("lead", "/wt", Status::Idle);
    let mut waiting = session("w1", "/wt", Status::Idle);
    waiting.parent = Some("lead".into());
    waiting.ticket = Some("ENG-1".into());
    // How it ended its turn says it's waiting on something else.
    waiting.items.push(Item { id: "a".into(), turn: None, status: ItemStatus::Done, at: None,
                              kind: ItemKind::Agent { text: "CI is running.\n\n[zero: working]".into(), final_answer: true } });
    let mut asking = session("w2", "/wt", Status::Waiting);
    asking.parent = Some("lead".into());
    let mut question = Ask::new(AskKind::Question, "Merge it?", agent("w2"), 600);
    question.id = "q1".into();
    let places = zerod::board::parse_places(r#"[{"ticket": "ENG-1", "place": "red-owl", "path": "/b/red-owl"}]"#).unwrap();
    let rows = zerod::board::board_with(&[lead, waiting, asking], &[question], &places);
    let row = &rows[0];
    assert_eq!(row.state, State::NeedsYou, "the lead's row: the most urgent of its team");
    assert_eq!(row.own, State::Idle, "and the lead as it is itself: it waits on nothing, its worker does");
    let team: Vec<(&str, State, &str, Option<&str>, usize)> =
        row.team.iter().map(|m| (m.session.as_str(), m.state, m.place.as_str(), m.path.as_deref(), m.asks.len())).collect();
    assert_eq!(team, [("w1", State::Answered, "red-owl", Some("/b/red-owl"), 0), ("w2", State::NeedsYou, "wt", None, 1)],
               "each worker as it is itself, by the same rules as a lead");
}

#[test]
fn an_answer_is_done_only_when_it_says_so_and_a_question_needs_you() {
    let idle = |text: &str| {
        let mut conversation = Conversation::new("s", Provider::Claude, "/w");
        conversation.apply(Change::Status { status: Status::Idle, turn: None, error: None });
        conversation.apply(Change::Item { item: Item { at: None, id: "a".into(), turn: None, kind: ItemKind::Agent { text: text.into(), final_answer: true }, status: ItemStatus::Done } });
        conversation
    };
    // Finished its turn is not finished the task: a plain answer leaves it idle.
    assert_eq!(idle("The plans are written.").attention(), Attention::Answered, "answered, nothing more: Replied until read");
    assert_eq!(idle("PR open, CI green.\n\n[zero: done]").attention(), Attention::Done);
    assert_eq!(idle("Can't reach the bench.\n\n[zero: blocked]").attention(), Attention::Blocked);
    assert_eq!(idle("Checking the bench next.\n\n[zero: working]").attention(), Attention::Idle);
    // Asked you something in prose, with no ending: it waits on you.
    assert_eq!(idle("Two options:\n1. Relaunch.\n2. One session each.\n\nWhich one do you want?").attention(), Attention::NeedsYou);
    assert_eq!(idle("Done? Not yet: tests next.").attention(), Attention::Answered, "a question inside a line isn't one to you");
    assert_eq!(idle("Both benches are blocked on your Mac.\n\nCould you finish the OrbStack update?\n\nWhere ENG-9790 is: the fix is written.").attention(),
               Attention::NeedsYou, "a question put to you anywhere in the answer waits on you");
    // A worker answers its lead, not the user: its answer is its report, and it's done.
    let mut worker = idle("The directory is empty.");
    worker.apply(Change::Parent { parent: Some("lead".into()) });
    assert_eq!(worker.attention(), Attention::Done);
}

#[test]
fn the_rows_now_is_the_answers_first_line_of_prose_without_a_list_marker() {
    let mut lead = session("a", "/work/app", Status::Idle);
    lead.items.push(Item { id: "1".into(), turn: None, kind: ItemKind::Agent { text: "| Issue | Bench |\n|---|---|\n\n- **ENG-9790:** the controller updates the text.\n- next".into(), final_answer: true }, status: ItemStatus::Done, at: None });
    assert_eq!(board(std::slice::from_ref(&lead), &[])[0].now.as_deref(), Some("**ENG-9790:** the controller updates the text."));
}

#[test]
fn a_workers_finish_does_not_make_its_lead_done() {
    // Workers raise their lead's row only with what needs attention (the user, trouble, work under way): a worker
    // that finished says nothing about the lead, whose own answer decides.
    let mut lead = session("lead", "/work/app", Status::Idle);
    lead.items.push(Item { id: "1".into(), turn: None, kind: ItemKind::Agent { text: "Both wait on you. I recommend yes.".into(), final_answer: true }, status: ItemStatus::Done, at: None });
    let worker = |id: &str, status: Status, answer: Option<&str>| {
        let mut worker = session(id, "/work/app", status);
        worker.parent = Some("lead".into());
        if let Some(text) = answer {
            worker.items.push(Item { id: "a".into(), turn: None, kind: ItemKind::Agent { text: text.into(), final_answer: true }, status: ItemStatus::Done, at: None });
        }
        worker
    };
    let state = |workers: Vec<Conversation>| { let mut all = vec![lead.clone()]; all.extend(workers); board(&all, &[]).into_iter().find(|r| r.session == "lead").unwrap().state };
    assert_eq!(state(vec![worker("w1", Status::Idle, Some("Plan ready."))]), State::Answered, "a finished worker leaves the lead as it is");
    assert_eq!(state(vec![worker("w1", Status::Working, None)]), State::Working);
    let mut asking = worker("w2", Status::Waiting, None);
    asking.questions.push(Question { id: "q".into(), item: None, fields: vec![] });
    assert_eq!(state(vec![asking]), State::NeedsYou, "a worker waiting on the user raises its lead");
}

#[test]
fn a_lead_that_replied_stays_replied_while_parked() {
    let answer = |text: &str| Item { at: None, id: "a1".into(), turn: None, kind: ItemKind::Agent { text: text.into(), final_answer: true }, status: ItemStatus::Done };
    let mut replied = session("r", "/w/a", Status::Offline);
    replied.items.push(answer("The build is green again."));
    assert_eq!(board(&[replied.clone()], &[])[0].state, State::Answered, "parked after its answer: still there to read");
    replied.status = Status::Idle;
    assert_eq!(board(&[replied], &[])[0].state, State::Answered);
    let mut finished = session("f", "/w/b", Status::Offline);
    finished.items.push(answer("All merged.\n\n[zero: done]"));
    assert_eq!(board(&[finished], &[])[0].state, State::Done);
    let mut quiet = session("q", "/w/c", Status::Offline);
    quiet.items.push(Item { at: None, id: "u1".into(), turn: None, kind: ItemKind::User { text: "go on".into(), images: vec![] }, status: ItemStatus::Done });
    assert_eq!(board(&[quiet], &[])[0].state, State::Idle, "offline with no answer to read");
}

#[test]
fn a_working_lead_is_working_itself_while_its_worker_waits_on_the_user() {
    let lead = session("lead", "/w", Status::Working);
    let mut worker = session("w1", "/w", Status::Waiting);
    worker.parent = Some("lead".into());
    let mut question = Ask::new(AskKind::Question, "Which colour?", agent("w1"), 600);
    question.id = "q1".into();
    let row = &board(&[lead, worker], &[question])[0];
    assert_eq!((row.state, row.own), (State::NeedsYou, State::Working), "the row sorts as the team needs; the lead's own is its own");
    assert_eq!(row.asks.len(), 1, "the team's asks still show on the row");
}

#[test]
fn a_reply_the_user_has_seen_is_read_for_every_client() {
    use zerod::board::{mark_read, read};
    // Seen, and its answer is still the latest: read at once (the app keeps the chat that's open purple until it's left).
    assert!(read(Some(("answer-1", 1_000)), Some("answer-1"), 1_000));
    assert!(!read(Some(("answer-1", 1_000)), Some("answer-2"), 5_000), "a newer answer is unread");
    assert!(!read(None, Some("answer-1"), 5_000));
    let mut lead = session("a", "/work/app", Status::Idle);
    lead.items.push(Item { id: "1".into(), turn: None, kind: ItemKind::Agent { text: "Just an answer.".into(), final_answer: true }, status: ItemStatus::Done, at: None });
    let mut rows = board(&[lead, session("b", "/work/api", Status::Idle)], &[]);
    assert_eq!(rows.iter().find(|r| r.session == "a").unwrap().state, State::Answered);
    mark_read(&mut rows, &|id| id == "a");
    let a = rows.iter().find(|r| r.session == "a").unwrap();
    assert_eq!((a.state, a.own), (State::Read, State::Read), "Replied still, greyed: read, nothing waiting on the user");
    assert!(State::Read > State::Waiting && State::Read < State::Done && State::Done < State::Idle, "it sorts with what needs nothing, the done last");
    assert_eq!((serde_json::json!(State::Done), serde_json::json!(State::Waiting)), (serde_json::json!("done"), serde_json::json!("waiting")));
}

#[test]
fn a_done_task_is_archived_once_its_been_done_a_while() {
    use std::collections::HashMap;
    use zerod::board::due_to_archive;
    let mut lead = session("a", "/work/app", Status::Idle);
    lead.label = Some("Ship it".into());
    let rows = board(&[lead.clone(), session("b", "/work/api", Status::Idle)], &[note("a", "Shipped", Some("completed"), None)]);
    let mut since = HashMap::new();
    let day = 24 * 3600;
    assert!(due_to_archive(&rows, &mut since, 1_000, Some(day)).is_empty(), "completed from now");
    assert!(due_to_archive(&rows, &mut since, 1_000 + day - 1, Some(day)).is_empty());
    assert_eq!(due_to_archive(&rows, &mut since, 1_000 + day, Some(day)), ["a"], "a day on");
    assert!(due_to_archive(&rows, &mut since, 1_000 + 9 * day, None).is_empty(), "never, if the user says so");
    // Taken up again (not completed any more): its clock starts over when it's completed again.
    let again = board(&[lead], &[]);
    due_to_archive(&again, &mut since, 5_000, Some(day));
    assert!(since.is_empty());
}

#[test]
fn an_offline_task_shows_the_state_its_last_answer_left_it_in() {
    // Its process stopped while it waited (parked): it's still waiting on what it said.
    let ended = |text: &str| {
        let mut lead = session("a", "/work/app", Status::Offline);
        lead.items.push(Item { id: "1".into(), turn: None, kind: ItemKind::Agent { text: text.into(), final_answer: true }, status: ItemStatus::Done, at: None });
        board(&[lead], &[])[0].state
    };
    assert_eq!(ended("Hey Arsen, what are we working on?"), State::NeedsYou, "its question is still open");
    assert_eq!(ended("The build is green."), State::Answered);
    assert_eq!(ended("Merged and checked.\n\n[zero: done]"), State::Done);
    assert_eq!(ended("Deploying.\n\n[zero: waiting]"), State::Waiting);
}

#[test]
fn zeros_own_lines_after_an_answer_dont_hide_it() {
    // "Paused for Zero's update", "Zero updated: carrying on": Zero's words, not the agent's; its answer still says.
    let mut lead = session("a", "/work/app", Status::Idle);
    lead.items.push(Item { id: "1".into(), turn: None, kind: ItemKind::Agent { text: "What should I look at?".into(), final_answer: true }, status: ItemStatus::Done, at: None });
    lead.items.push(Item { id: "2".into(), turn: None, kind: ItemKind::Notice { text: zerod::daemon::CARRIED.into(), error: false }, status: ItemStatus::Done, at: None });
    assert_eq!(board(&[lead], &[])[0].state, State::NeedsYou);
}

#[test]
fn a_reply_to_a_turn_zero_started_is_quiet() {
    // Unread still (purple), but nothing to tell the user about: Zero passed on an event, or a worker reported.
    let said = |id: &str, text: &str| Item { at: None, id: id.into(), turn: None, kind: ItemKind::User { text: text.into(), images: vec![] }, status: ItemStatus::Done };
    let answer = |id: &str| Item { at: None, id: id.into(), turn: None, kind: ItemKind::Agent { text: "Noted.".into(), final_answer: true }, status: ItemStatus::Done };
    let mut lead = session("a", "/work/app", Status::Idle);
    lead.items = vec![said("u1", "Is it merged?"), answer("a1")];
    assert!(!board(std::slice::from_ref(&lead), &[])[0].quiet, "a reply to the user's own message");
    lead.items.extend([said("u2", &from_line("zero", "1 new event on what you follow")), answer("a2")]);
    let row = &board(&[lead], &[])[0];
    assert_eq!((row.state, row.quiet), (State::Answered, true));
}
