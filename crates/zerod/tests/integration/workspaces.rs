//! Workspaces: the user's work split by who it's for. A task is in the workspace it was started in (or moved to), else
//! Zero; a worker is its lead's.

use crate::common::temp_dir;
use zerod::workspaces::{DEFAULT, Workspace, Workspaces};

fn workspace(name: &str) -> Workspace {
    Workspace { id: String::new(), name: name.into(), glyph: String::new(), color: String::new() }
}

#[test]
fn zero_is_always_there_and_the_rest_are_made_named_and_kept() {
    let home = temp_dir("workspaces");
    let workspaces = Workspaces::open(&home);
    assert_eq!(workspaces.list().iter().map(|w| (w.id.as_str(), w.name.as_str())).collect::<Vec<_>>(), [(DEFAULT, "Zero")]);
    assert_eq!(workspaces.save(workspace("Acme")).unwrap().id, "acme");
    assert_eq!(workspaces.save(workspace("Acme")).unwrap().id, "acme-2", "a second of the same name gets its own id");
    assert_eq!(workspaces.save(workspace("  ")).unwrap_err(), "A workspace needs a name");
    // Changed by id; Zero keeps its name whatever it is called.
    workspaces.save(Workspace { id: "acme".into(), name: "Work".into(), glyph: "briefcase".into(), color: "teal".into() }).unwrap();
    assert_eq!(
        workspaces.save(Workspace { id: DEFAULT.into(), name: "Mine".into(), glyph: "".into(), color: "".into() }).unwrap().name,
        "Zero"
    );
    assert_eq!(workspaces.delete(DEFAULT).unwrap_err(), "Zero is always there");
    workspaces.delete("acme-2").unwrap();
    assert_eq!(workspaces.delete("nope").unwrap_err(), "No workspace nope");
    let again = Workspaces::open(&home);
    assert_eq!(
        again.list().iter().map(|w| (w.id.as_str(), w.name.as_str(), w.glyph.as_str(), w.color.as_str())).collect::<Vec<_>>(),
        [(DEFAULT, "Zero", "", ""), ("acme", "Work", "briefcase", "teal")]
    );
}

#[test]
fn the_user_puts_workspaces_in_order_zero_too_and_it_is_kept() {
    let home = temp_dir("workspaces-order");
    let workspaces = Workspaces::open(&home);
    for name in ["Acme", "Home", "Club"] {
        workspaces.save(workspace(name)).unwrap();
    }
    let ids = |w: &Workspaces| w.list().into_iter().map(|w| w.id).collect::<Vec<_>>();
    // Zero moves like any other; an id that isn't one, or one named twice, is passed over; one left out keeps its place
    // after the rest.
    workspaces.reorder(&["home".into(), "nope".into(), DEFAULT.into(), "home".into(), "acme".into()]).unwrap();
    assert_eq!(ids(&workspaces), ["home", DEFAULT, "acme", "club"]);
    assert_eq!(ids(&Workspaces::open(&home)), ["home", DEFAULT, "acme", "club"], "kept");
    workspaces.save(workspace("New")).unwrap();
    assert_eq!(ids(&workspaces).last().unwrap(), "new", "a new one goes last");
}

#[test]
fn a_task_is_in_the_workspace_it_was_put_in_else_zero() {
    // Folders no longer decide: started in the app it's in the workspace it was started in; from outside it, in Zero
    // until moved. An old file's folders are read past.
    let home = temp_dir("workspaces-of");
    std::fs::write(
        home.join("workspaces.json"),
        r#"[{"id": "work", "name": "Acme", "glyph": "", "folders": ["/Users/me/Documents/work"]}]"#,
    )
    .unwrap();
    let workspaces = Workspaces::open(&home);
    assert_eq!(workspaces.of(None), DEFAULT, "its folder doesn't put it anywhere");
    assert_eq!(workspaces.of(Some("work")), "work", "put somewhere, it stays there");
    assert_eq!(workspaces.of(Some("gone")), DEFAULT, "put in a workspace since deleted: Zero");
}
