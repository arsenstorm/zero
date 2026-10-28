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
    // What it hands the user blocks it on them: the board has no other way to say "needs you".
    assert_eq!((row.state, row.needs.as_deref()), (State::NeedsYou, Some("ship as is or one more round")));

    let later = [asks[0].clone(), note("a", "Round 4 pushed", Some("done"), None)];
    let row = &board(std::slice::from_ref(&lead), &later)[0];
    assert_eq!((row.state, row.needs.as_deref(), row.now.as_deref()), (State::Done, None, Some("Round 4 pushed")), "a later note without needs clears them");
    // Done is the work finished; merged is it shipped.
    let shipped = [note("a", "Merged #13336", Some("merged"), None)];
    assert_eq!(board(&[lead], &shipped)[0].state, State::Merged);
}

#[test]
fn a_new_turn_clears_what_the_last_note_said() {
    let lead = session("a", "/work/app", Status::Idle);
    let asks = [note("a", "Waits for ENG-9759", Some("waiting"), Some("agree the periodic job")), dot("Working", None), dot("Done", Some("done"))];
    let row = &board(&[lead], &asks)[0];
    assert_eq!((row.state, row.needs.as_deref(), row.now.as_deref()), (State::Idle, None, None));
}

#[test]
fn without_a_note_it_shows_the_agents_last_answer() {
    let mut lead = session("a", "/work/app", Status::Idle);
    lead.items.push(Item { id: "1".into(), turn: None, kind: ItemKind::Agent { text: "PR #13336 is open.\n\nDetails follow.".into(), final_answer: true }, status: ItemStatus::Done });
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
    // An agent that says it's blocked is blocked on the user; one stuck or failing on its own is in trouble.
    assert_eq!(states, [("failing", State::NeedsYou), ("stuck", State::Trouble), ("working", State::Working), ("waits", State::Waiting), ("done", State::Idle)]);
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
    assert_eq!(states, [("handed", false, State::NeedsYou), ("busy", true, State::Working), ("gone", false, State::Idle)], "most urgent first, online or not");
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
