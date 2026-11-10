//! A task's folder as it was when each message of yours went to the agent, so a rewind can bring it back. Kept with git:
//! the folder's files (ignored ones aside) as a commit under refs/zero/, made through a copy of the index, so the
//! user's index, HEAD and files are never touched by taking one. Restoring writes back only the files that differ
//! (and removes those made since), after keeping the folder as it was then, so a restore can be undone too.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// How a folder differs from a snapshot: what a restore would undo.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize)]
pub struct Diff {
    pub files: usize,
    pub insertions: usize,
    pub deletions: usize,
}

/// The folder kept as a commit under `refs/zero/<name>`; None outside git, or if git fails.
pub fn take(cwd: &Path, name: &str) -> Option<String> {
    let top = top(cwd)?;
    let tree = tree(cwd, &top)?;
    let head = git(&top, &["rev-parse", "--verify", "-q", "HEAD"]);
    let mut args = vec!["commit-tree", tree.as_str(), "-m", "Zero: the folder before a message"];
    if let Some(head) = &head {
        args.extend(["-p", head.as_str()])
    }
    let commit = git_as_zero(&top, &args)?;
    git(&top, &["update-ref", &format!("refs/zero/{name}"), &commit])?;
    Some(commit)
}

/// What changed in the folder since the snapshot.
pub fn preview(cwd: &Path, snapshot: &str) -> Option<Diff> {
    let top = top(cwd)?;
    let now = tree(cwd, &top)?;
    diff(&top, snapshot, &now)
}

/// The folder back as it was at the snapshot: changed and deleted files written back, files made since removed. The
/// folder as it was just before is kept first, as `refs/zero/<point>`.
pub fn restore(cwd: &Path, snapshot: &str, point: &str) -> Result<Diff, String> {
    let top = top(cwd).ok_or("The task's folder isn't in git")?;
    let now = take(cwd, point).ok_or("Couldn't keep the folder as it is before restoring it")?;
    let changed = diff(&top, snapshot, &now).ok_or("Couldn't compare the folder with its snapshot")?;
    let names = git(&top, &["diff", "--name-status", "--no-renames", "-z", snapshot, &now]).unwrap_or_default();
    let mut back: Vec<String> = vec![];
    let mut fields = names.split('\0').filter(|f| !f.is_empty());
    while let (Some(status), Some(path)) = (fields.next(), fields.next()) {
        if status == "A" {
            let _ = std::fs::remove_file(top.join(path));
        } else {
            back.push(path.to_string());
        }
    }
    if !back.is_empty() {
        // Paths on stdin, so however many there are fits.
        let mut child = Command::new("git")
            .args(["restore", &format!("--source={snapshot}"), "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul"])
            .current_dir(&top)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| e.to_string())?;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(back.join("\0").as_bytes());
        }
        let output = child.wait_with_output().map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Err(format!("git couldn't restore the files: {}", String::from_utf8_lossy(&output.stderr).trim()));
        }
    }
    Ok(changed)
}

/// The repository's top folder, if `cwd` is in one.
fn top(cwd: &Path) -> Option<PathBuf> {
    git(cwd, &["rev-parse", "--show-toplevel"]).map(PathBuf::from)
}

/// The folder's files now, as a tree: written through a copy of the index (its cached file stats spare re-reading
/// files that haven't changed), so the real one is left as it is.
fn tree(cwd: &Path, top: &Path) -> Option<String> {
    let index = git(cwd, &["rev-parse", "--path-format=absolute", "--git-path", "index"])?;
    let copy = std::env::temp_dir().join(format!(
        "zero-index-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
    ));
    if std::fs::copy(&index, &copy).is_err() {
        let _ = std::fs::remove_file(&copy);
    }
    let with = |args: &[&str]| run(Command::new("git").args(args).current_dir(top).env("GIT_INDEX_FILE", &copy));
    let tree = with(&["add", "-A"]).and_then(|_| with(&["write-tree"]));
    let _ = std::fs::remove_file(&copy);
    tree
}

fn diff(top: &Path, from: &str, to: &str) -> Option<Diff> {
    let numbers = git(top, &["diff", "--numstat", "--no-renames", from, to])?;
    Some(numbers.lines().fold(Diff::default(), |mut total, line| {
        let mut parts = line.split('\t');
        // Binary files count as changed, with no lines.
        total.insertions += parts.next().and_then(|n| n.parse::<usize>().ok()).unwrap_or(0);
        total.deletions += parts.next().and_then(|n| n.parse::<usize>().ok()).unwrap_or(0);
        total.files += 1;
        total
    }))
}

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    run(Command::new("git").args(args).current_dir(dir))
}

/// A commit Zero makes, as Zero: the user's git may have no name set, and these aren't the user's commits.
fn git_as_zero(dir: &Path, args: &[&str]) -> Option<String> {
    run(Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "Zero")
        .env("GIT_AUTHOR_EMAIL", "zero@localhost")
        .env("GIT_COMMITTER_NAME", "Zero")
        .env("GIT_COMMITTER_EMAIL", "zero@localhost"))
}

fn run(command: &mut Command) -> Option<String> {
    let output = command.stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim_end_matches('\n').to_string())
}
