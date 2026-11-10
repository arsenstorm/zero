//! Scratchpads: Markdown files under one folder (folders in it are the user's), each with a short id that links reach it
//! by (zero://pad/<id>, or zero://pad/<id>#<section> for one heading's part), and a revision that guards a write
//! against one made since it was read.

use crate::common::temp_dir;
use zerod::pads::*;

const PLAN: &str = "# Release plan\n\nIntro.\n\n## Plan\n\n- ship it\n\n### Risks\n\nNone.\n\n## Notes\n\n```\n## not a heading\n```\n\n## Plan\n\nAgain.\n";

#[test]
fn a_pad_is_a_markdown_file_with_an_id_kept_through_renames_and_moves() {
    let root = temp_dir("pads-files");
    let pads = Pads::open(&root);
    let pad = pads.create("Release plan", "", PLAN).unwrap();
    assert_eq!(std::fs::read_to_string(root.join("Release plan.md")).unwrap(), PLAN);
    assert_eq!(pad.link, format!("zero://pad/{}", pad.id));
    assert_eq!(pads.create("Release plan", "", "").unwrap().title, "Release plan 2", "titles in a folder stay apart");
    pads.make_folder("Work/2026").unwrap();
    let moved = pads.move_to(&pad.id, "Work/2026").unwrap();
    let renamed = pads.rename(&pad.id, "Launch").unwrap();
    assert_eq!((moved.folder.as_str(), renamed.title.as_str()), ("Work/2026", "Launch"));
    assert!(root.join("Work/2026/Launch.md").exists());
    // Another start reads the same ids back.
    let again = Pads::open(&root);
    assert_eq!(again.read(&pad.id, None).unwrap().content, PLAN);
    assert_eq!(again.folders(), ["Work", "Work/2026"]);
    assert_eq!(pads.move_to(&pad.id, "../out").unwrap_err(), "A folder is a name inside Zero's scratchpads");
}

#[test]
fn files_added_outside_zero_get_ids_and_removed_ones_go() {
    let root = temp_dir("pads-outside");
    let pads = Pads::open(&root);
    std::fs::create_dir_all(root.join("Ideas")).unwrap();
    std::fs::write(root.join("Ideas/Later.md"), "later").unwrap();
    std::fs::write(root.join("Ideas/picture.png"), "not a pad").unwrap();
    let listed = pads.list(None);
    assert_eq!(listed.iter().map(|p| (p.title.as_str(), p.folder.as_str())).collect::<Vec<_>>(), [("Later", "Ideas")]);
    std::fs::remove_file(root.join("Ideas/Later.md")).unwrap();
    assert!(pads.list(None).is_empty());
    assert_eq!(pads.read(&listed[0].id, None).unwrap_err(), format!("No scratchpad {}", listed[0].id));
}

#[test]
fn sections_are_its_headings_with_links_of_their_own() {
    let outline = sections(PLAN);
    let slugs: Vec<(&str, u8, &str)> = outline.iter().map(|s| (s.slug.as_str(), s.level, s.title.as_str())).collect();
    assert_eq!(
        slugs,
        [("release-plan", 1, "Release plan"), ("plan", 2, "Plan"), ("risks", 3, "Risks"), ("notes", 2, "Notes"), ("plan-1", 2, "Plan")],
        "a heading in a code block isn't one; a repeated one gets a number, as GitHub's anchors do"
    );
    let pads = Pads::open(&temp_dir("pads-sections"));
    let pad = pads.create("Release plan", "", PLAN).unwrap();
    // A section runs to the next heading as high as its own, so it holds its subsections.
    let plan = pads.read(&format!("zero://pad/{}#plan", pad.id), None).unwrap();
    assert_eq!(plan.content, "## Plan\n\n- ship it\n\n### Risks\n\nNone.\n");
    assert_eq!(plan.revision, pad.revision, "the revision is the whole pad's");
    assert_eq!(pads.read(&pad.id, Some("nope")).unwrap_err(), "No section nope in Release plan: release-plan, plan, risks, notes, plan-1");
}

#[test]
fn a_write_from_an_old_revision_is_refused() {
    let pads = Pads::open(&temp_dir("pads-revisions"));
    let pad = pads.create("Notes", "", "one\n").unwrap();
    let written = pads.write(&pad.id, "two\n", Some(&pad.revision)).unwrap();
    assert_ne!(written.revision, pad.revision);
    assert_eq!(
        pads.write(&pad.id, "three\n", Some(&pad.revision)).unwrap_err(),
        format!("Notes changed since revision {}; read it again (it's at {} now)", pad.revision, written.revision)
    );
    assert_eq!(pads.write(&pad.id, "three\n", None).unwrap().content, "three\n", "no revision: written over");
}

#[test]
fn text_is_added_at_the_end_or_a_sections_and_a_section_replaced() {
    let pads = Pads::open(&temp_dir("pads-edits"));
    let pad = pads.create("Release plan", "", PLAN).unwrap();
    let appended = pads.append(&pad.id, "- and tell people", Some("plan")).unwrap();
    assert!(appended.content.contains("None.\n\n- and tell people\n\n## Notes"), "{}", appended.content);
    let ended = pads.append(&pad.id, "Last.", None).unwrap();
    assert!(ended.content.ends_with("Again.\n\nLast.\n"), "{}", ended.content);
    let edited = pads.edit(&pad.id, "risks", "### Risks\n\nSome.", Some(&ended.revision)).unwrap();
    assert!(edited.content.contains("### Risks\n\nSome.\n\n## Notes"), "{}", edited.content);
    // Without its own heading, the new text goes under the old one.
    let kept = pads.edit(&pad.id, "notes", "Fresh.", None).unwrap();
    assert!(kept.content.contains("## Notes\n\nFresh.\n\n## Plan"), "{}", kept.content);
}

#[test]
fn pads_are_found_by_title_and_by_their_text() {
    let pads = Pads::open(&temp_dir("pads-find"));
    let plan = pads.create("Release plan", "Work", PLAN).unwrap();
    pads.create("Groceries", "", "eggs\nmilk\n").unwrap();
    assert_eq!(pads.list(Some("release")).iter().map(|p| p.title.as_str()).collect::<Vec<_>>(), ["Release plan"]);
    let found = pads.find("SHIP");
    assert_eq!(found.len(), 1);
    assert_eq!(
        (found[0].id.as_str(), found[0].section.as_deref(), found[0].line, found[0].text.as_str()),
        (plan.id.as_str(), Some("plan"), 7, "- ship it")
    );
}

#[test]
fn a_deleted_pad_goes_to_the_trash_folder_not_away() {
    let root = temp_dir("pads-trash");
    let pads = Pads::open(&root);
    let pad = pads.create("Old", "", "keep me").unwrap();
    pads.delete(&pad.id).unwrap();
    assert!(pads.list(None).is_empty());
    assert_eq!(std::fs::read_to_string(root.join(".trash/Old.md")).unwrap(), "keep me");
}

#[test]
fn a_tasks_pads_keep_to_its_own_folder_out_of_the_way() {
    let pads = Pads::open(&temp_dir("pads-tasks"));
    pads.create("Notes", "", "the word").unwrap();
    let state = pads.create("State", "Tasks/ENG-1", "# ENG-1\n\nthe word").unwrap();
    let titles = |list: Vec<Summary>| list.into_iter().map(|p| p.title).collect::<Vec<_>>();
    assert_eq!(titles(pads.list(None)), ["Notes"], "the scratchpads leave tasks' pads out");
    assert!(pads.folders().is_empty());
    assert_eq!(pads.find("word").len(), 1);
    assert_eq!(titles(pads.list_in(None, Some("Tasks/ENG-1"))), ["State"], "asked for by its folder, a task's are there");
    assert_eq!(pads.read(&state.link, None).unwrap().folder, "Tasks/ENG-1", "and its link reads it as any pad's does");
}
