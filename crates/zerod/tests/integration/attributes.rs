//! What an agent says about its task beyond its name and ticket (a pull request, say), as named attributes: shown on
//! the task, kept with it.


use std::sync::Arc;

use crate::common::temp_dir;
use zerod::daemon::{Daemon, Runtime};
use zerod::model::*;

fn quiet() -> Runtime { Arc::new(|_, _, _| Ok(zerod::session::Transport::new(tokio::io::empty(), tokio::io::sink()))) }

#[tokio::test]
async fn an_agent_sets_and_clears_its_tasks_attributes() {
    let home = temp_dir("attributes");
    let daemon = Daemon::open(&home.join("zerod"), quiet()).unwrap();
    let id = daemon.start(Provider::Claude, home.to_str().unwrap(), "fix it", None, None, Permissions::Auto).unwrap();
    daemon.set_attribute(&id, "PR", Some("https://github.com/acme/app/pull/12")).unwrap();
    daemon.set_attribute(&id, "Deploy", Some("staging")).unwrap();
    daemon.set_attribute(&id, "Deploy", None).unwrap();
    assert!(daemon.set_attribute(&id, " ", Some("x")).is_err(), "an attribute has a name");
    let expected = [("PR".to_string(), "https://github.com/acme/app/pull/12".to_string())].into_iter().collect();
    assert_eq!(daemon.get(&id).unwrap().attributes, expected);
    assert_eq!(Daemon::open(&home.join("zerod"), quiet()).unwrap().get(&id).unwrap().attributes, expected, "kept");
}
