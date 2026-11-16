//! A task started with no folder gets one of its own: ~/Zero/<its first words>, a git repo, gone again if its agent
//! didn't start.

use std::sync::{Arc, Mutex};

use crate::common::temp_dir;
use zerod::daemon::{Daemon, Options, Runtime};
use zerod::model::Provider;

fn silent(started: Arc<Mutex<Vec<tokio::io::DuplexStream>>>) -> Runtime {
    Arc::new(move |_, _, _| {
        let (zero_side, runtime_side) = tokio::io::duplex(1 << 16);
        started.lock().unwrap().push(runtime_side);
        let (read, write) = tokio::io::split(zero_side);
        Ok(zerod::session::Transport::new(read, write))
    })
}

fn daemon(name: &str, runtime: Runtime) -> (Arc<Daemon>, std::path::PathBuf) {
    let home = temp_dir(name);
    let daemon = Daemon::open(&home.join("zerod"), runtime).unwrap();
    daemon.place(&home);
    (daemon, home)
}

fn cwd_of(daemon: &Daemon, id: &str) -> String {
    daemon.get(id).unwrap().cwd
}

#[tokio::test]
async fn a_task_with_no_folder_gets_a_new_one_in_zero_named_from_its_first_words() {
    let (daemon, home) = daemon("new-folder-named", silent(Arc::default()));
    let id = daemon.start(Provider::Claude, "Fix the login page, it times out on Safari", Options::default()).unwrap();
    let cwd = cwd_of(&daemon, &id);
    assert_eq!(cwd, home.join("Zero/fix-the-login-page-it").to_str().unwrap());
    assert!(home.join("Zero/fix-the-login-page-it/.git").is_dir(), "a git repo, so rewind works");
}

#[tokio::test]
async fn the_same_words_again_get_a_folder_of_their_own() {
    let (daemon, home) = daemon("new-folder-twice", silent(Arc::default()));
    let first = daemon.start(Provider::Claude, "test", Options::default()).unwrap();
    let second = daemon.start(Provider::Claude, "test", Options::default()).unwrap();
    assert_eq!(cwd_of(&daemon, &first), home.join("Zero/test").to_str().unwrap());
    assert_eq!(cwd_of(&daemon, &second), home.join("Zero/test-2").to_str().unwrap());
}

#[tokio::test]
async fn words_with_nothing_to_name_it_by_make_a_task_folder() {
    let (daemon, home) = daemon("new-folder-unnamed", silent(Arc::default()));
    let id = daemon.start(Provider::Claude, "!!! ???", Options::default()).unwrap();
    assert_eq!(cwd_of(&daemon, &id), home.join("Zero/task").to_str().unwrap());
}

#[tokio::test]
async fn a_new_folder_goes_again_if_its_agent_does_not_start() {
    let failing: Runtime = Arc::new(|_, _, _| Err(std::io::Error::other("no such program")));
    let (daemon, home) = daemon("new-folder-failed", failing);
    assert!(daemon.start(Provider::Claude, "test", Options::default()).is_err());
    assert!(!home.join("Zero/test").exists(), "nothing left behind");
}

#[tokio::test]
async fn a_task_refused_makes_no_folder() {
    let (daemon, home) = daemon("new-folder-refused", silent(Arc::default()));
    assert!(daemon.start(Provider::Claude, "   ", Options::default()).is_err());
    assert!(!home.join("Zero").exists());
}

/// A task of its own folder, its turn over: "test" in ~/Zero, with `files` made in it.
fn idle_task(daemon: &Daemon, files: &[&str]) -> (String, std::path::PathBuf) {
    use zerod::model::{Change, Status};
    let id = daemon.start(Provider::Claude, "test", Options::default()).unwrap();
    let cwd = std::path::PathBuf::from(cwd_of(daemon, &id));
    for file in files {
        std::fs::write(cwd.join(file), "made here").unwrap();
    }
    daemon.session(&id).unwrap().change(Change::Status { status: Status::Idle, turn: None, error: None });
    (id, cwd)
}

#[tokio::test]
async fn a_task_moved_to_a_project_takes_its_files_and_thread_and_leaves_no_folder_behind() {
    use zerod::model::{Change, ItemKind};
    // The folder each start of its agent was in.
    let folders = Arc::new(Mutex::new(vec![]));
    let (seen, quiet) = (folders.clone(), silent(Arc::default()));
    let runtime: Runtime = Arc::new(move |conversation, dir, argv| {
        seen.lock().unwrap().push(conversation.cwd.clone());
        quiet(conversation, dir, argv)
    });
    let (daemon, home) = daemon("move-to-project", runtime);
    let project = home.join("code/site");
    std::fs::create_dir_all(&project).unwrap();
    let (id, old) = idle_task(&daemon, &["notes.md"]);
    let thread = daemon.get(&id).unwrap().thread.expect("Claude's session id, chosen at its start");
    let claude = zerod::handoff::claude_folder(&home, old.to_str().unwrap());
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::write(claude.join(format!("{thread}.jsonl")), "{}\n").unwrap();
    daemon.session(&id).unwrap().change(Change::Snapshot { item: "u1".into(), commit: "abc".into() });

    daemon.move_to(&id, project.to_str().unwrap()).await.unwrap();

    // Its agent is told as it resumes, in the new folder.
    let session = daemon.session(&id).unwrap();
    let told = |c: &zerod::model::Conversation| {
        c.items.iter().any(|i| matches!(&i.kind, ItemKind::User { text, .. } if text.contains("Your folder is now")))
    };
    crate::common::until(&session, told).await;
    let moved = daemon.get(&id).unwrap();
    assert_eq!(moved.cwd, project.to_str().unwrap());
    assert_eq!(std::fs::read_to_string(project.join("notes.md")).unwrap(), "made here");
    assert!(!old.exists(), "its own folder, emptied, is gone");
    assert!(
        zerod::handoff::claude_folder(&home, project.to_str().unwrap()).join(format!("{thread}.jsonl")).exists(),
        "Claude Code resumes its thread from the new folder"
    );
    assert_eq!(folders.lock().unwrap().last().unwrap(), project.to_str().unwrap(), "its agent resumed in the project");
    assert!(moved.snapshots.is_empty(), "rewind points of the old folder are gone with it");
}

#[tokio::test]
async fn a_task_mid_turn_is_not_moved() {
    let (daemon, home) = daemon("move-mid-turn", silent(Arc::default()));
    let project = home.join("code/site");
    std::fs::create_dir_all(&project).unwrap();
    let id = daemon.start(Provider::Claude, "test", Options::default()).unwrap();
    let error = daemon.move_to(&id, project.to_str().unwrap()).await.unwrap_err();
    assert!(error.contains("turn"), "{error}");
    assert!(home.join("Zero/test").exists());
}

#[tokio::test]
async fn nothing_moves_over_a_file_the_project_has_already() {
    let (daemon, home) = daemon("move-no-overwrite", silent(Arc::default()));
    let project = home.join("code/site");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join("README.md"), "the project's").unwrap();
    let (id, old) = idle_task(&daemon, &["a.txt", "README.md"]);
    let error = daemon.move_to(&id, project.to_str().unwrap()).await.unwrap_err();
    assert!(error.contains("README.md"), "{error}");
    assert_eq!(std::fs::read_to_string(project.join("README.md")).unwrap(), "the project's");
    assert!(old.join("a.txt").exists() && !project.join("a.txt").exists(), "nothing moved");
    assert_eq!(daemon.get(&id).unwrap().cwd, old.to_str().unwrap());
}

#[tokio::test]
async fn only_a_folder_zero_made_is_moved_out_of() {
    let (daemon, home) = daemon("move-not-ours", silent(Arc::default()));
    let mine = home.join("code/mine");
    let project = home.join("code/site");
    std::fs::create_dir_all(&mine).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(mine.join("a.txt"), "the user's").unwrap();
    let id = daemon.start(Provider::Claude, "test", Options { cwd: Some(mine.to_str().unwrap().into()), ..Default::default() }).unwrap();
    daemon.session(&id).unwrap().change(zerod::model::Change::Status { status: zerod::model::Status::Idle, turn: None, error: None });
    assert!(daemon.move_to(&id, project.to_str().unwrap()).await.is_err());
    assert!(mine.join("a.txt").exists());
}
