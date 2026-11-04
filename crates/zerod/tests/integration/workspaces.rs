//! Workspaces: the user's work split by who it's for. A task is in the workspace it was started in, else its folder's,
//! else Zero; a worker is its lead's.

mod common;

use common::temp_dir;
use zerod::workspaces::{Workspace, Workspaces, DEFAULT};

fn workspace(name: &str, folders: &[&str]) -> Workspace { Workspace { id: String::new(), name: name.into(), glyph: String::new(), folders: folders.iter().map(|f| f.to_string()).collect() } }

#[test]
fn zero_is_always_there_and_the_rest_are_made_named_and_kept() {
    let home = temp_dir("workspaces");
    let workspaces = Workspaces::open(&home);
    assert_eq!(workspaces.list().iter().map(|w| (w.id.as_str(), w.name.as_str())).collect::<Vec<_>>(), [(DEFAULT, "Zero")]);
    let work = workspaces.save(workspace("Acme", &["/Users/me/Documents/work/", "/Users/me/git"])).unwrap();
    assert_eq!((work.id.as_str(), work.folders.clone()), ("acme", vec!["/Users/me/Documents/work".to_string(), "/Users/me/git".into()]));
    assert_eq!(workspaces.save(workspace("Acme", &[])).unwrap().id, "acme-2", "a second of the same name gets its own id");
    assert_eq!(workspaces.save(workspace("  ", &[])).unwrap_err(), "A workspace needs a name");
    // Changed by id; Zero keeps its name whatever it is called.
    workspaces.save(Workspace { id: "acme".into(), name: "Work".into(), glyph: "briefcase".into(), folders: vec!["/Users/me/git".into()] }).unwrap();
    assert_eq!(workspaces.save(Workspace { id: DEFAULT.into(), name: "Mine".into(), glyph: "".into(), folders: vec![] }).unwrap().name, "Zero");
    assert_eq!(workspaces.delete(DEFAULT).unwrap_err(), "Zero is always there");
    workspaces.delete("acme-2").unwrap();
    assert_eq!(workspaces.delete("nope").unwrap_err(), "No workspace nope");
    let again = Workspaces::open(&home);
    assert_eq!(again.list().iter().map(|w| (w.id.as_str(), w.name.as_str(), w.glyph.as_str())).collect::<Vec<_>>(), [(DEFAULT, "Zero", ""), ("acme", "Work", "briefcase")]);
}

#[test]
fn a_task_is_in_the_workspace_it_was_put_in_else_its_folders_else_zero() {
    let workspaces = Workspaces::open(&temp_dir("workspaces-of"));
    workspaces.save(Workspace { id: "work".into(), name: "Acme".into(), glyph: "".into(), folders: vec!["/Users/me/Documents/work".into()] }).unwrap();
    workspaces.save(Workspace { id: "app".into(), name: "Engineering".into(), glyph: "".into(), folders: vec!["/Users/me/Documents/work/app".into()] }).unwrap();
    assert_eq!(workspaces.of(None, "/Users/me/Documents/personal/zero"), DEFAULT);
    assert_eq!(workspaces.of(None, "/Users/me/Documents/work/data"), "work");
    assert_eq!(workspaces.of(None, "/Users/me/Documents/work/app/app"), "app", "the longest folder that contains it");
    assert_eq!(workspaces.of(None, "/Users/me/Documents/workx"), DEFAULT, "a folder's name isn't a prefix");
    assert_eq!(workspaces.of(Some("work"), "/Users/me/Documents/personal"), "work", "put somewhere, it stays there");
    assert_eq!(workspaces.of(Some("gone"), "/Users/me/Documents/work/x"), "work", "put in a workspace since deleted, its folder decides");
}
