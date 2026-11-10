//! Later: things to come back to. Each is a note in plain words and the artifact behind it (everything an agent worked
//! out, in full), with the links and files that go with it, the task it came from, and every earlier version.

use crate::common::temp_dir;
use serde_json::json;
use zerod::later::*;

#[test]
fn an_item_is_a_note_and_its_artifact_kept_as_files_of_its_own() {
    let root = temp_dir("later-files");
    let later = Later::open(&root);
    let item = later
        .save(New {
            note: "Fix the flaky login test.".into(),
            artifact: "## Cause\n\nA race in `auth.rb:42`.".into(),
            links: vec!["https://example.com/thread".into()],
            from: Some("s1".into()),
            task: Some("Login bug".into()),
            workspace: Some("zero".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(item.link, format!("zero://later/{}", item.id));
    assert_eq!((item.version, item.done), (1, false));
    assert_eq!(std::fs::read_to_string(root.join(&item.id).join("artifact.md")).unwrap(), "## Cause\n\nA race in `auth.rb:42`.");
    let read = later.view(&item.link, None).unwrap();
    assert_eq!(read.artifact.as_deref(), Some("## Cause\n\nA race in `auth.rb:42`."));
    assert_eq!((read.task.as_deref(), read.links.len()), (Some("Login bug"), 1));
    // Listed without the artifact: a list is for reading the notes.
    assert_eq!(later.list(None)[0].artifact, None);
    assert!(later.save(New { note: "  ".into(), ..Default::default() }).unwrap_err().contains("note"));
}

#[test]
fn files_are_copied_in_and_kept_with_it() {
    let root = temp_dir("later-attach");
    let shot = root.join("shot.png");
    std::fs::write(&shot, b"png").unwrap();
    let later = Later::open(&root.join("later"));
    let item =
        later.save(New { note: "Look at the layout".into(), files: vec![shot.to_string_lossy().into()], ..Default::default() }).unwrap();
    assert_eq!(item.files.len(), 1);
    assert!(item.files[0].ends_with("/files/shot.png"));
    assert_eq!(std::fs::read(&item.files[0]).unwrap(), b"png");
    assert!(
        later
            .save(New { note: "x".into(), files: vec!["/nowhere/at/all.png".into()], ..Default::default() })
            .unwrap_err()
            .contains("all.png")
    );
}

#[test]
fn editing_keeps_every_earlier_version() {
    let later = Later::open(&temp_dir("later-versions"));
    let item = later.save(New { note: "Plan the migration".into(), artifact: "v1".into(), ..Default::default() }).unwrap();
    let edited = later.edit(&item.id, Edit { artifact: Some("v2".into()), by: Some("s2".into()), ..Default::default() }).unwrap();
    assert_eq!(edited.version, 2);
    assert_eq!(edited.versions.iter().map(|v| v.version).collect::<Vec<_>>(), [1, 2]);
    assert_eq!(later.view(&item.id, None).unwrap().artifact.as_deref(), Some("v2"));
    assert_eq!(later.view(&item.id, Some(1)).unwrap().artifact.as_deref(), Some("v1"));
    // Done isn't a new version: nothing it says changed.
    let done = later.edit(&item.id, Edit { done: Some(true), ..Default::default() }).unwrap();
    assert_eq!((done.done, done.version), (true, 2));
    assert!(later.view(&item.id, Some(9)).is_err());
}

#[test]
fn the_list_puts_whats_open_first_newest_first_and_finds_by_words() {
    let later = Later::open(&temp_dir("later-list"));
    let a = later.save(New { note: "Old one".into(), ..Default::default() }).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let b = later.save(New { note: "New one".into(), artifact: "mentions kafka".into(), ..Default::default() }).unwrap();
    let c = later.save(New { note: "Finished".into(), ..Default::default() }).unwrap();
    later.edit(&c.id, Edit { done: Some(true), ..Default::default() }).unwrap();
    assert_eq!(later.list(None).iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), [b.id.as_str(), a.id.as_str(), c.id.as_str()]);
    assert_eq!(later.list(Some("KAFKA")).iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), [b.id.as_str()]);
    later.delete(&a.id).unwrap();
    assert!(later.view(&a.id, None).is_err());
    assert_eq!(later.list(None).len(), 2);
}

#[test]
fn the_tools_are_called_by_name() {
    let later = Later::open(&temp_dir("later-call"));
    let saved = call(&later, "save", &json!({"note": "Write the docs", "artifact": "All of it", "links": ["https://x.dev"]})).unwrap();
    let id = saved["id"].as_str().unwrap();
    assert_eq!(call(&later, "view", &json!({"item": id})).unwrap()["artifact"], "All of it");
    assert_eq!(call(&later, "edit", &json!({"item": id, "note": "Write the API docs"})).unwrap()["version"], 2);
    assert_eq!(call(&later, "list", &json!({})).unwrap()[0]["note"], "Write the API docs");
    assert_eq!(call(&later, "delete", &json!({"item": id})).unwrap()["deleted"], true);
    assert_eq!(call(&later, "nope", &json!({})).unwrap_err(), "No later tool nope");
}

#[test]
fn a_note_is_a_headline_and_the_rest_goes_in_the_artifact() {
    let later = Later::open(&temp_dir("later-headline"));
    let long = "Ticket ideas from the production check: (1) the bell dropdown never closes on Escape; (2) a literal false class.";
    let refused = later.save(New { note: long.into(), from: Some("s1".into()), asked: true, ..Default::default() }).unwrap_err();
    assert!(refused.contains("100") && refused.contains("artifact"), "says how short, and where the rest goes: {refused}");
    let item = later
        .save(New { note: "Two small bugs from a production check".into(), from: Some("s1".into()), asked: true, ..Default::default() })
        .unwrap();
    assert!(
        later.edit(&item.id, Edit { note: Some(long.into()), by: Some("s1".into()), ..Default::default() }).is_err(),
        "an agent's edit too"
    );
}

#[test]
fn what_an_agent_saves_unasked_is_a_suggestion_a_few_per_task_gone_after_a_week() {
    let root = temp_dir("later-suggested");
    let later = Later::open(&root);
    let save =
        |note: &str, from: &str, asked: bool| later.save(New { note: note.into(), from: Some(from.into()), asked, ..Default::default() });
    let asked = save("Asked for", "s1", true).unwrap();
    assert!(!asked.suggested, "the user asked for it");
    let first = save("One", "s1", false).unwrap();
    assert!(first.suggested);
    save("Two", "s1", false).unwrap();
    save("Three", "s1", false).unwrap();
    let refused = save("Four", "s1", false).unwrap_err();
    assert!(refused.contains("zero later edit") && refused.contains(&first.id), "points at the ones it has: {refused}");
    save("Another task's", "s2", false).unwrap();
    // Kept by the user: an item like any other, and no longer one of the task's suggestions.
    let kept = later.edit(&first.id, Edit { keep: Some(true), ..Default::default() }).unwrap();
    assert!(!kept.suggested);
    save("Four", "s1", false).unwrap();
    // A suggestion not kept within a week goes; what was kept or asked for stays.
    let old = |id: &str| {
        let file = root.join(id).join("item.json");
        let mut item: serde_json::Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        item["created"] = json!(item["created"].as_i64().unwrap() - 8 * 86400);
        std::fs::write(&file, item.to_string()).unwrap();
    };
    let gone = save("Old suggestion", "s3", false).unwrap();
    for id in [&gone.id, &first.id, &asked.id] {
        old(id)
    }
    let left: Vec<String> = later.list(None).into_iter().map(|i| i.id).collect();
    assert!(!left.contains(&gone.id) && left.contains(&first.id) && left.contains(&asked.id));
}
