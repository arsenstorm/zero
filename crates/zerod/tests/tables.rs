//! A table an agent hands to Zero to draw (`zero table`): an item of its conversation, kept and replayed like any.

mod common;

use std::sync::Arc;

use common::temp_dir;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

#[tokio::test]
async fn a_table_is_an_item_of_the_conversation_kept_across_a_restart() {
    let home = temp_dir("tables");
    let runtime: Runtime = Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink())));
    let daemon = Daemon::open(&home, runtime.clone()).unwrap();
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "lead", None, None, Permissions::Auto).unwrap();
    daemon.table(&id, "Batch", vec!["Task".into(), "State".into()], vec![vec!["ENG-9790".into(), "working".into()], vec!["ENG-9793".into()]]).unwrap();
    assert_eq!(daemon.table(&id, "Empty", vec![], vec![]).unwrap_err(), "A table needs columns");
    let table = |daemon: &Daemon| daemon.get(&id).unwrap().items.into_iter().find_map(|i| match i.kind { ItemKind::Table { title, columns, rows } => Some((title, columns, rows)), _ => None });
    let (title, columns, rows) = table(&daemon).unwrap();
    assert_eq!((title.as_str(), columns.len()), ("Batch", 2));
    assert_eq!(rows, [vec!["ENG-9790".to_string(), "working".into()], vec!["ENG-9793".into(), String::new()]], "a short row is filled out to the columns");
    drop(daemon);
    assert!(table(&Daemon::open(&home, runtime).unwrap()).is_some(), "in the transcript, so a restart keeps it");
}
