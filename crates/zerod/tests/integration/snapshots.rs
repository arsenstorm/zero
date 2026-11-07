//! A task's folder as it was at each message of yours, kept with git and never touching what's yours: the index, HEAD
//! and the files stay as they are until a rewind asks for the folder back.


use std::path::Path;
use std::process::Command;

use crate::common::temp_dir;
use zerod::snapshots;

fn git(dir: &Path, args: &[&str]) -> String {
    // The fixture's own commits unsigned: the user's global config may sign through an agent that's locked.
    let output = Command::new("git").args(["-c", "commit.gpgsign=false"]).args(args).current_dir(dir).output().unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn repo(name: &str) -> std::path::PathBuf {
    let dir = temp_dir(name);
    git(&dir, &["init", "-q"]);
    git(&dir, &["config", "user.email", "t@t"]);
    git(&dir, &["config", "user.name", "T"]);
    std::fs::write(dir.join("a.txt"), "one\n").unwrap();
    std::fs::write(dir.join(".gitignore"), "ignored/\n").unwrap();
    git(&dir, &["add", "."]);
    git(&dir, &["commit", "-qm", "start"]);
    dir
}

#[test]
fn a_snapshot_keeps_the_folder_and_restoring_brings_it_back() {
    let dir = repo("snap");
    // Before the message: an edit, a new file, and something staged that's the user's business.
    std::fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
    std::fs::write(dir.join("b.txt"), "new\n").unwrap();
    std::fs::create_dir_all(dir.join("ignored")).unwrap();
    std::fs::write(dir.join("ignored/cache"), "keep me\n").unwrap();
    let snapshot = snapshots::take(&dir, "task/m1").expect("a git folder");
    assert_eq!(git(&dir, &["rev-parse", "refs/zero/task/m1"]), snapshot, "kept under a ref of Zero's");
    assert_eq!(git(&dir, &["status", "--porcelain"]), "M a.txt\n?? b.txt", "nothing staged by it");

    // What the agent did after: a.txt changed, b.txt gone, c.txt new, and a commit.
    git(&dir, &["add", "a.txt"]);
    let staged = git(&dir, &["diff", "--cached", "--name-only"]);
    std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\nfour\n").unwrap();
    std::fs::remove_file(dir.join("b.txt")).unwrap();
    std::fs::write(dir.join("c.txt"), "agent\n").unwrap();

    let since = snapshots::preview(&dir, &snapshot).unwrap();
    assert_eq!((since.files, since.insertions, since.deletions), (3, 3, 1), "a.txt +2, b.txt -1, c.txt +1");

    let restored = snapshots::restore(&dir, &snapshot, "task/restore-1").unwrap();
    assert_eq!(restored.files, 3);
    assert_eq!(std::fs::read_to_string(dir.join("a.txt")).unwrap(), "one\ntwo\n");
    assert_eq!(std::fs::read_to_string(dir.join("b.txt")).unwrap(), "new\n");
    assert!(!dir.join("c.txt").exists(), "made since: gone");
    assert_eq!(std::fs::read_to_string(dir.join("ignored/cache")).unwrap(), "keep me\n", "ignored files are never touched");
    assert_eq!(git(&dir, &["diff", "--cached", "--name-only"]), staged, "the index is the user's");
    // The restore itself can be undone: the folder as it was just before is kept too.
    let point = git(&dir, &["rev-parse", "refs/zero/task/restore-1"]);
    assert_eq!(git(&dir, &["show", &format!("{point}:c.txt")]), "agent");
    assert_eq!(snapshots::preview(&dir, &snapshot).unwrap().files, 0);
}

#[test]
fn a_folder_outside_git_has_no_snapshots() {
    let dir = temp_dir("snap-plain");
    assert!(snapshots::take(&dir, "task/m1").is_none());
}
