//! Settings › Git: agents commit with an identity and signing key of their own, and push over HTTPS with the user's
//! GitHub CLI sign-in, so nothing waits on the user's own key (1Password locked, the Mac away). The user's own terminal
//! keeps theirs: only the agents' processes get it.

use crate::common::temp_dir;
use zerod::git::AgentGit;

fn agents(folders: Vec<String>) -> AgentGit {
    AgentGit {
        enabled: true,
        login: "arsenstorm2".into(),
        name: "Arsen (Agent)".into(),
        email: "117126823+arsenstorm2@users.noreply.github.com".into(),
        https: true,
        folders,
        agents_author: false,
        coauthor_name: String::new(),
        coauthor_email: String::new(),
        scoped_token: false,
        old_https: None,
    }
}

#[test]
fn author_and_token_are_opt_in_and_the_token_is_only_for_github() {
    let home = temp_dir("git-options");
    let key = home.join("git-signing-key");
    std::fs::write(&key, "key").unwrap();
    let normal = zerod::git::variables_for(&agents(vec![]), &key, &home);
    assert!(!normal.iter().any(|(k, _)| k == "GIT_AUTHOR_NAME" || k == "GIT_AUTHOR_EMAIL" || k == "GH_TOKEN"));
    assert!(!normal.iter().any(|(_, v)| v.contains("core.hooksPath") || v.contains("credential.helper")));

    let settings = AgentGit { agents_author: true, scoped_token: true, ..agents(vec![]) };
    let vars = zerod::git::variables_for_with_token(&settings, &key, &home, None);
    assert!(vars.iter().any(|(k, v)| k == "GIT_AUTHOR_NAME" && v == "Arsen (Agent)"));
    assert!(vars.iter().any(|(k, v)| k == "GIT_AUTHOR_EMAIL" && v == "117126823+arsenstorm2@users.noreply.github.com"));
    assert!(!vars.iter().any(|(k, _)| k == "GH_TOKEN"), "no saved token");
    assert!(
        !zerod::git::variables_for_with_token(&agents(vec![]), &key, &home, Some("secret".into())).iter().any(|(k, _)| k == "GH_TOKEN"),
        "the option is off"
    );
    let with_token = zerod::git::variables_for_with_token(&settings, &key, &home, Some("secret".into()));
    assert!(with_token.iter().any(|(k, v)| k == "GH_TOKEN" && v == "secret"));
    assert!(with_token.iter().any(|(_, v)| v == "credential.helper"));
    let token_only = zerod::git::variables_for_with_token(
        &AgentGit { enabled: false, scoped_token: true, ..agents(vec![]) },
        &key,
        &home,
        Some("secret".into()),
    );
    assert!(token_only.iter().any(|(k, _)| k == "GH_TOKEN"));
    assert!(!token_only.iter().any(|(k, _)| k == "GIT_COMMITTER_NAME"));
    let helper = home.join("git-credential");
    let reply = |input: &str| {
        use std::io::Write;
        let mut child = std::process::Command::new(&helper)
            .arg("get")
            .env("GH_TOKEN", "secret")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        String::from_utf8(child.wait_with_output().unwrap().stdout).unwrap()
    };
    assert!(reply("protocol=https\nhost=github.com\n").contains("password=secret"));
    assert!(reply("protocol=https\nhost=example.com\n").is_empty());
    assert!(reply("protocol=http\nhost=github.com\n").is_empty());
}

#[test]
fn agent_authored_commit_chains_hooks_and_amend_has_one_coauthor() {
    let home = temp_dir("git-coauthor");
    let key = home.join("git-signing-key");
    assert!(
        std::process::Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-f", key.to_str().unwrap()])
            .status()
            .unwrap()
            .success()
    );
    let repo = home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let hooks = home.join("original-hooks");
    std::fs::create_dir_all(&hooks).unwrap();
    let marker = home.join("ran-hook");
    std::fs::write(hooks.join("commit-msg"), format!("#!/bin/sh\ntouch '{}'\n", marker.display())).unwrap();
    let precommit = home.join("ran-pre-commit");
    std::fs::write(hooks.join("pre-commit"), format!("#!/bin/sh\ntouch '{}'\n", precommit.display())).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(hooks.join("commit-msg"), std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::set_permissions(hooks.join("pre-commit"), std::fs::Permissions::from_mode(0o700)).unwrap();
    let settings = AgentGit { agents_author: true, ..agents(vec![]) };
    let vars = zerod::git::variables_for(&settings, &key, &repo);
    let git = |args: &[&str]| {
        std::process::Command::new("git")
            .args(args)
            .current_dir(&repo)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/opt/homebrew/bin")
            .env("HOME", &home)
            .envs(vars.iter().cloned())
            .output()
            .unwrap()
    };
    assert!(git(&["init", "-q"]).status.success());
    assert!(git(&["config", "user.name", "User Name"]).status.success());
    assert!(git(&["config", "user.email", "user@example.com"]).status.success());
    assert!(git(&["config", "core.hooksPath", hooks.to_str().unwrap()]).status.success());
    let first = git(&["commit", "-q", "--allow-empty", "-m", "first"]);
    assert!(first.status.success(), "{}", String::from_utf8_lossy(&first.stderr));
    assert!(marker.exists(), "the repository's own commit-msg hook ran");
    assert!(precommit.exists(), "the repository's own pre-commit hook ran");
    let amended = git(&["commit", "-q", "--amend", "--allow-empty", "--no-edit"]);
    assert!(amended.status.success(), "{}", String::from_utf8_lossy(&amended.stderr));
    let raw = String::from_utf8_lossy(&git(&["cat-file", "-p", "HEAD"]).stdout).to_string();
    assert!(raw.contains("author Arsen (Agent) <117126823+arsenstorm2@users.noreply.github.com>"), "{raw}");
    assert_eq!(raw.matches("Co-authored-by: User Name <user@example.com>").count(), 1, "{raw}");

    let branch = String::from_utf8(git(&["symbolic-ref", "--short", "HEAD"]).stdout).unwrap().trim().to_string();
    assert!(git(&["checkout", "-q", "-b", "side"]).status.success());
    std::fs::write(repo.join("side"), "side\n").unwrap();
    assert!(git(&["add", "side"]).status.success());
    assert!(git(&["commit", "-q", "-m", "side"]).status.success());
    assert!(git(&["checkout", "-q", &branch]).status.success());
    std::fs::write(repo.join("main"), "main\n").unwrap();
    assert!(git(&["add", "main"]).status.success());
    assert!(git(&["commit", "-q", "-m", "main"]).status.success());
    assert!(git(&["checkout", "-q", "side"]).status.success());
    let rebased = git(&["rebase", &branch]);
    assert!(rebased.status.success(), "{}", String::from_utf8_lossy(&rebased.stderr));
    assert!(git(&["checkout", "-q", &branch]).status.success());
    let merged = git(&["merge", "-q", "--no-ff", "side", "-m", "merge"]);
    assert!(merged.status.success(), "{}", String::from_utf8_lossy(&merged.stderr));
    let merge = String::from_utf8_lossy(&git(&["cat-file", "-p", "HEAD"]).stdout).to_string();
    assert_eq!(merge.matches("Co-authored-by: User Name <user@example.com>").count(), 1, "{merge}");
}

#[test]
fn agents_sign_as_their_own_committer_with_their_key_and_push_over_https() {
    let home = temp_dir("git-vars");
    let key = home.join("git-signing-key");
    std::fs::write(&key, "key").unwrap();
    let vars = zerod::git::variables_for(&agents(vec![]), &key, &home);
    let get = |name: &str| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str());
    assert_eq!(get("GIT_COMMITTER_EMAIL"), Some("117126823+arsenstorm2@users.noreply.github.com"));
    assert_eq!(get("GIT_COMMITTER_NAME"), Some("Arsen (Agent)"));
    assert!(get("GIT_AUTHOR_EMAIL").is_none(), "the author stays the user, as the repo has them");
    let config: Vec<(String, String)> = (0..get("GIT_CONFIG_COUNT").unwrap().parse::<usize>().unwrap())
        .map(|i| (get(&format!("GIT_CONFIG_KEY_{i}")).unwrap().to_string(), get(&format!("GIT_CONFIG_VALUE_{i}")).unwrap().to_string()))
        .collect();
    let has = |k: &str, v: &str| config.iter().any(|(ck, cv)| ck == k && cv == v);
    assert!(
        has("gpg.format", "ssh") && has("gpg.ssh.program", "ssh-keygen") && has("user.signingKey", key.to_str().unwrap()),
        "{config:?}"
    );
    assert!(has("commit.gpgSign", "true") && has("tag.gpgSign", "true"));
    assert!(
        has("url.https://github.com/.insteadOf", "git@github.com:") && has("url.https://github.com/.insteadOf", "ssh://git@github.com/")
    );
    let ssh = zerod::git::variables_for(&AgentGit { https: false, ..agents(vec![]) }, &key, &home);
    assert!(!ssh.iter().any(|(_, v)| v == "git@github.com:"), "SSH as the user has it");
}

#[test]
fn nothing_changes_when_its_off_has_no_key_or_is_outside_its_folders() {
    let home = temp_dir("git-off");
    let key = home.join("git-signing-key");
    let ssh = AgentGit { https: false, ..agents(vec![]) };
    assert!(zerod::git::variables_for(&ssh, &key, &home).is_empty(), "no key yet");
    std::fs::write(&key, "key").unwrap();
    assert!(zerod::git::variables_for(&AgentGit { enabled: false, ..ssh }, &key, &home).is_empty());
    let work = home.join("work");
    std::fs::create_dir_all(work.join("repo")).unwrap();
    let only = agents(vec![work.to_str().unwrap().into()]);
    assert!(!zerod::git::variables_for(&only, &key, &work.join("repo")).is_empty(), "inside its folders");
    assert!(zerod::git::variables_for(&only, &key, &home).is_empty(), "outside them");
}

#[tokio::test]
async fn an_agents_commit_is_signed_with_its_key_as_its_committer() {
    // Real git, a real key: what an agent's own `git commit` makes.
    let home = temp_dir("git-commit");
    let key = home.join("git-signing-key");
    let made =
        std::process::Command::new("ssh-keygen").args(["-q", "-t", "ed25519", "-N", "", "-f", key.to_str().unwrap()]).status().unwrap();
    assert!(made.success());
    let repo = home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let vars = zerod::git::variables_for(&agents(vec![]), &key, &repo);
    let git = |args: &[&str]| {
        std::process::Command::new("git")
            .args(args)
            .current_dir(&repo)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/opt/homebrew/bin")
            .env("HOME", &home)
            .envs(vars.iter().cloned())
            .env("GIT_AUTHOR_NAME", "Arsen")
            .env("GIT_AUTHOR_EMAIL", "arsen@example.com")
            .output()
            .unwrap()
    };
    assert!(git(&["init", "-q"]).status.success());
    let commit = git(&["commit", "-q", "--allow-empty", "-m", "first"]);
    assert!(commit.status.success(), "{}", String::from_utf8_lossy(&commit.stderr));
    let raw = String::from_utf8_lossy(&git(&["cat-file", "-p", "HEAD"]).stdout).to_string();
    assert!(
        raw.contains("author Arsen <arsen@example.com>")
            && raw.contains("committer Arsen (Agent) <117126823+arsenstorm2@users.noreply.github.com>"),
        "{raw}"
    );
    assert!(raw.contains("gpgsig -----BEGIN SSH SIGNATURE-----"), "{raw}");
}

#[test]
fn a_github_account_gives_the_committer_its_name_and_noreply_email() {
    // What `gh api users/<login>` says, as the settings take it: no address of the user's own to know or type.
    let (name, email) = zerod::git::committer(r#"{"id": 117126823, "login": "arsenstorm2", "name": "Arsen (Agent)"}"#).unwrap();
    assert_eq!((name.as_str(), email.as_str()), ("Arsen (Agent)", "117126823+arsenstorm2@users.noreply.github.com"));
    let (unnamed, _) = zerod::git::committer(r#"{"id": 5, "login": "bot", "name": null}"#).unwrap();
    assert_eq!(unnamed, "bot", "no name on the account: its login");
    assert!(zerod::git::committer(r#"{"message": "Not Found"}"#).is_none());
}

#[test]
fn the_key_is_found_among_the_accounts_signing_keys_by_its_body() {
    let listed =
        r#"[{"title": "Bitwarden", "key": "ssh-ed25519 AAAAother"}, {"title": "Signing-only Key", "key": "ssh-ed25519 AAAAmine"}]"#;
    assert_eq!(zerod::git::listed_as(listed, "ssh-ed25519 AAAAmine arsen@mac").as_deref(), Some("Signing-only Key"), "its comment aside");
    assert_eq!(zerod::git::listed_as(listed, "ssh-ed25519 AAAAnone"), None);
}

#[test]
fn a_tasks_own_terminal_commits_as_the_agents_too() {
    // Opened in the user's terminal (which starts it with an environment of its own), the task's agent still gets the
    // agents' identity: the script exports it before the command.
    let home = temp_dir("git-terminal");
    std::fs::write(home.join("git-signing-key"), "key").unwrap();
    let mut conversation = zerod::model::Conversation::new("s1", zerod::model::Provider::Claude, home.to_str().unwrap());
    conversation.thread = Some("3f1c".into());
    let vars = zerod::git::variables_for(&agents(vec![]), &home.join("git-signing-key"), &home);
    let script = zerod::daemon::terminal_script(&conversation, &vars, &home.join("s1.pid")).unwrap();
    let exported = script.find("export GIT_COMMITTER_EMAIL='117126823+arsenstorm2@users.noreply.github.com'").expect(&script);
    assert!(script.find("'claude'").is_some_and(|at| at > exported), "then the command: {script}");
}

#[test]
fn https_push_works_on_its_own_and_an_old_setting_keeps_its_meaning() {
    let home = temp_dir("git-https-alone");
    let key = home.join("git-signing-key");
    let alone = AgentGit { enabled: false, https: true, ..agents(vec![]) };
    let vars = zerod::git::variables_for(&alone, &key, &home);
    assert!(vars.iter().any(|(_, v)| v == "git@github.com:"), "pushes over HTTPS without agents' own account: {vars:?}");
    assert!(!vars.iter().any(|(k, _)| k.starts_with("GIT_COMMITTER") || k.starts_with("GIT_AUTHOR")), "commits stay the user's");
    assert!(!vars.iter().any(|(_, v)| v == "commit.gpgSign"));

    // Before, "https" held only with agents' own account: an old setting with it off stays SSH.
    let old: AgentGit = serde_json::from_str(r#"{"enabled": false, "https": true}"#).unwrap();
    assert!(!old.upgraded().https);
    let old: AgentGit = serde_json::from_str(r#"{"enabled": true, "https": true}"#).unwrap();
    assert!(old.upgraded().https);
    let new: AgentGit = serde_json::from_str(r#"{"enabled": false, "httpsPush": true}"#).unwrap();
    assert!(new.clone().upgraded().https);
    assert!(!serde_json::to_string(&new.upgraded()).unwrap().contains("\"https\""), "kept under its new name only");
}
