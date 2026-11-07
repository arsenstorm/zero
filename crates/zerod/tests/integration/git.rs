//! Settings › Git: agents commit with an identity and signing key of their own, and push over HTTPS with the user's
//! GitHub CLI sign-in, so nothing waits on the user's own key (1Password locked, the Mac away). The user's own terminal
//! keeps theirs: only the agents' processes get it.

use crate::common::temp_dir;
use zerod::git::AgentGit;

fn agents(folders: Vec<String>) -> AgentGit {
    AgentGit { enabled: true, login: "arsenstorm2".into(), name: "Arsen (Agent)".into(), email: "117126823+arsenstorm2@users.noreply.github.com".into(), https: true, folders }
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
        .map(|i| (get(&format!("GIT_CONFIG_KEY_{i}")).unwrap().to_string(), get(&format!("GIT_CONFIG_VALUE_{i}")).unwrap().to_string())).collect();
    let has = |k: &str, v: &str| config.iter().any(|(ck, cv)| ck == k && cv == v);
    assert!(has("gpg.format", "ssh") && has("gpg.ssh.program", "ssh-keygen") && has("user.signingKey", key.to_str().unwrap()), "{config:?}");
    assert!(has("commit.gpgSign", "true") && has("tag.gpgSign", "true"));
    assert!(has("url.https://github.com/.insteadOf", "git@github.com:") && has("url.https://github.com/.insteadOf", "ssh://git@github.com/"));
    let ssh = zerod::git::variables_for(&AgentGit { https: false, ..agents(vec![]) }, &key, &home);
    assert!(!ssh.iter().any(|(_, v)| v == "git@github.com:"), "SSH as the user has it");
}

#[test]
fn nothing_changes_when_its_off_has_no_key_or_is_outside_its_folders() {
    let home = temp_dir("git-off");
    let key = home.join("git-signing-key");
    assert!(zerod::git::variables_for(&agents(vec![]), &key, &home).is_empty(), "no key yet");
    std::fs::write(&key, "key").unwrap();
    assert!(zerod::git::variables_for(&AgentGit { enabled: false, ..agents(vec![]) }, &key, &home).is_empty());
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
    let made = std::process::Command::new("ssh-keygen").args(["-q", "-t", "ed25519", "-N", "", "-f", key.to_str().unwrap()]).status().unwrap();
    assert!(made.success());
    let repo = home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let vars = zerod::git::variables_for(&agents(vec![]), &key, &repo);
    let git = |args: &[&str]| std::process::Command::new("git").args(args).current_dir(&repo).env_clear()
        .env("PATH", "/usr/bin:/bin:/opt/homebrew/bin").env("HOME", &home).envs(vars.iter().cloned())
        .env("GIT_AUTHOR_NAME", "Arsen").env("GIT_AUTHOR_EMAIL", "arsen@example.com").output().unwrap();
    assert!(git(&["init", "-q"]).status.success());
    let commit = git(&["commit", "-q", "--allow-empty", "-m", "first"]);
    assert!(commit.status.success(), "{}", String::from_utf8_lossy(&commit.stderr));
    let raw = String::from_utf8_lossy(&git(&["cat-file", "-p", "HEAD"]).stdout).to_string();
    assert!(raw.contains("author Arsen <arsen@example.com>") && raw.contains("committer Arsen (Agent) <117126823+arsenstorm2@users.noreply.github.com>"), "{raw}");
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
    let listed = r#"[{"title": "Bitwarden", "key": "ssh-ed25519 AAAAother"}, {"title": "Signing-only Key", "key": "ssh-ed25519 AAAAmine"}]"#;
    assert_eq!(zerod::git::listed_as(listed, "ssh-ed25519 AAAAmine arsen@mac").as_deref(), Some("Signing-only Key"), "its comment aside");
    assert_eq!(zerod::git::listed_as(listed, "ssh-ed25519 AAAAnone"), None);
}
