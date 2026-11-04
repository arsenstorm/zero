//! Zero keeps the CLIs' sign-ins and gives each CLI the one chosen as a task starts: Claude Code a token or an API key
//! in its environment, Codex a home of its own where it keeps its ChatGPT sign-in, OpenCode its providers' keys. The
//! CLIs still make every call to their providers; Zero only hands them what to sign in with.


use crate::common::temp_dir;
use std::sync::Arc;
use zerod::model::Provider;
use zerod::signins::*;

fn secrets() -> Secrets { Arc::new(|service: &str, account: &str| (service == KEYCHAIN).then(|| format!("secret-for-{account}"))) }

fn signin(cli: Provider, kind: Kind, label: &str) -> SignIn {
    SignIn { id: String::new(), cli, kind, label: label.into(), plan: None, variable: None, pending: false }
}

#[test]
fn sign_ins_are_kept_without_their_values_and_each_cli_has_a_default() {
    let home = temp_dir("signins-store");
    let store = SignIns::open(&home);
    let first = store.save(signin(Provider::Claude, Kind::Token, "a@example.com")).unwrap();
    let second = store.save(signin(Provider::Claude, Kind::Token, "b@example.com")).unwrap();
    store.save(signin(Provider::Codex, Kind::CodexHome, "c@example.com")).unwrap();
    assert_eq!(store.default_for(Provider::Claude).map(|s| s.id), Some(first.id.clone()), "the first of a CLI's is its default");
    store.set_default(Provider::Claude, &second.id).unwrap();
    let again = SignIns::open(&home);
    assert_eq!(again.default_for(Provider::Claude).map(|s| s.id), Some(second.id.clone()), "kept across restarts");
    assert_eq!(again.list().len(), 3);
    again.delete(&second.id).unwrap();
    assert_eq!(again.default_for(Provider::Claude).map(|s| s.id), Some(first.id), "its default gone: the next of that CLI's");
    let file = std::fs::read_to_string(home.join("signins.json")).unwrap();
    assert!(!file.contains("secret"), "no values in the file: they're in the Keychain");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(home.join("signins.json")).unwrap().permissions().mode() & 0o777, 0o600);
    }
    assert_eq!(store.save(signin(Provider::Claude, Kind::Token, " ")).unwrap_err(), "A sign-in needs a name");
}

#[test]
fn each_cli_gets_its_sign_in_the_way_it_reads_one() {
    let home = temp_dir("signins-env");
    let store = SignIns::open(&home);
    store.set_secrets(secrets());
    let token = store.save(signin(Provider::Claude, Kind::Token, "a@example.com")).unwrap();
    assert_eq!(store.environment(&token).unwrap(), [("CLAUDE_CODE_OAUTH_TOKEN".to_string(), format!("secret-for-{}", token.id))]);
    let key = store.save(signin(Provider::Claude, Kind::ApiKey, "Team key")).unwrap();
    assert_eq!(store.environment(&key).unwrap()[0].0, "ANTHROPIC_API_KEY");
    let go = store.save(SignIn { variable: Some("OPENCODE_API_KEY".into()), ..signin(Provider::Opencode, Kind::ApiKey, "OpenCode Go") }).unwrap();
    assert_eq!(store.environment(&go).unwrap()[0].0, "OPENCODE_API_KEY", "an OpenCode provider's own variable");
    store.set_secrets(Arc::new(|_, _| None));
    assert_eq!(store.environment(&token).unwrap_err(), "a@example.com isn't in the Keychain any more: sign in again", "missing: said, not started unsigned");
}

#[test]
fn a_codex_account_has_a_home_of_its_own_sharing_everything_but_its_sign_in() {
    let home = temp_dir("signins-codex");
    let codex = home.join("dot-codex");
    std::fs::create_dir_all(codex.join("sessions")).unwrap();
    std::fs::write(codex.join("config.toml"), "model = \"gpt\"").unwrap();
    std::fs::write(codex.join("auth.json"), "{\"personal\": true}").unwrap();
    let store = SignIns::open(&home);
    store.set_codex_dir(codex.clone());
    let account = store.save(signin(Provider::Codex, Kind::CodexHome, "c@example.com")).unwrap();
    let env = store.environment(&account).unwrap();
    assert_eq!(env[0].0, "CODEX_HOME");
    let own = std::path::PathBuf::from(&env[0].1);
    assert_eq!(std::fs::read_to_string(own.join("config.toml")).unwrap(), "model = \"gpt\"", "the user's config, shared");
    assert!(std::fs::symlink_metadata(own.join("sessions")).unwrap().file_type().is_symlink(), "threads resume under any account");
    assert!(!own.join("auth.json").exists(), "its sign-in is its own, written by Codex's login there");
}

#[tokio::test]
async fn a_task_runs_as_its_sign_in_or_its_clis_default() {
    let home = temp_dir("signins-task");
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let daemon = zerod::daemon::Daemon::open(&home, Arc::new(|_, _, _| Ok(crate::common::play(vec![]).0))).unwrap();
    daemon.signins.set_secrets(secrets());
    let a = daemon.signins.save(signin(Provider::Claude, Kind::Token, "a@example.com")).unwrap();
    let b = daemon.signins.save(signin(Provider::Claude, Kind::Token, "b@example.com")).unwrap();
    let token = |id: &str| zerod::process::environment(std::iter::empty(), id).into_iter().find(|(k, _)| k == "CLAUDE_CODE_OAUTH_TOKEN").map(|(_, v)| v);
    let plain = daemon.start(Provider::Claude, project.to_str().unwrap(), "hi", None, None, zerod::model::Permissions::Auto).unwrap();
    assert_eq!(token(&plain), Some(format!("secret-for-{}", a.id)), "no account chosen: the CLI's default");
    let chosen = daemon.start_with(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(project.to_str().unwrap().into()), signin: Some(b.id.clone()), ..Default::default() }).unwrap();
    assert_eq!(token(&chosen), Some(format!("secret-for-{}", b.id)));
    assert_eq!(daemon.get(&chosen).unwrap().signin.as_deref(), Some(b.id.as_str()), "kept with the task, for its restarts");
}

#[test]
fn a_sign_in_still_waiting_on_the_browser_is_no_ones_default_and_starts_nothing() {
    let store = SignIns::open(&temp_dir("signins-pending"));
    let waiting = store.save(SignIn { pending: true, ..signin(Provider::Codex, Kind::CodexHome, "Codex") }).unwrap();
    assert!(store.default_for(Provider::Codex).is_none(), "not signed in yet: tasks don't start as it");
    assert_eq!(store.environment(&waiting).unwrap_err(), "Codex is still signing in");
    store.save(SignIn { pending: false, label: "c@example.com".into(), ..waiting }).unwrap();
    assert_eq!(store.default_for(Provider::Codex).map(|s| s.label), Some("c@example.com".into()));
}

#[test]
fn a_claude_account_has_a_folder_of_its_own_sharing_everything_but_its_sign_in() {
    let home = temp_dir("signins-claude");
    let dot = home.join("dot-claude");
    std::fs::create_dir_all(dot.join("projects")).unwrap();
    std::fs::write(dot.join("settings.json"), "{}").unwrap();
    std::fs::write(dot.join(".credentials.json"), "{\"personal\": true}").unwrap();
    std::fs::write(home.join(".claude.json"), r#"{"oauthAccount": {"emailAddress": "me@example.com"}, "mcpServers": {"docs": {}}}"#).unwrap();
    let store = SignIns::open(&home);
    store.set_claude_dir(dot);
    let account = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    let env = store.environment(&account).unwrap();
    assert_eq!(env[0].0, "CLAUDE_CONFIG_DIR");
    let own = std::path::PathBuf::from(&env[0].1);
    assert!(std::fs::symlink_metadata(own.join("projects")).unwrap().file_type().is_symlink(), "conversations resume under any account");
    assert!(own.join("settings.json").exists());
    assert!(!own.join(".credentials.json").exists(), "its sign-in is its own, kept by Claude Code there");
    let state: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(own.join(".claude.json")).unwrap()).unwrap();
    assert!(state["mcpServers"]["docs"].is_object(), "the user's own Claude Code state to start from");
    assert!(state.get("oauthAccount").is_none(), "but not who they're signed in as");
}

fn usage(five: f64, seven: f64, seven_resets: i64) -> zerod::model::Usage {
    let window = |name: &str, used: f64, resets: i64| zerod::model::UsageWindow { name: name.into(), used, resets_at: Some(resets) };
    zerod::model::Usage { limited: five >= 1.0, resets_at: (five >= 1.0).then_some(NOW + 3_600),
                          windows: vec![window("5 hours", five, NOW + 3_600), window("7 days", seven, seven_resets)] }
}
const NOW: i64 = 1_800_000_000;
const DAY: i64 = 86_400;

#[test]
fn a_task_runs_as_the_account_with_the_least_of_its_week_left_that_isnt_at_a_limit() {
    let store = SignIns::open(&temp_dir("signins-choose"));
    let account = |label: &str| store.save(signin(Provider::Claude, Kind::ClaudeHome, label)).unwrap();
    let (nearly, plenty, stopped, fresh) = (account("nearly@example.com"), account("plenty@example.com"), account("stopped@example.com"), account("fresh@example.com"));
    store.record_usage(&nearly.id, &usage(0.2, 0.9, NOW + 2 * DAY));
    store.record_usage(&plenty.id, &usage(0.1, 0.3, NOW + 5 * DAY));
    store.record_usage(&stopped.id, &usage(1.0, 0.95, NOW + DAY));
    let chosen = |except: Option<&str>| store.choose(Provider::Claude, NOW, except).map(|s| s.label);
    assert_eq!(chosen(None).as_deref(), Some("nearly@example.com"), "the least of its week left goes first; one at its 5-hour limit doesn't");
    assert_eq!(chosen(Some(&nearly.id)).as_deref(), Some("plenty@example.com"), "then the next least");
    // Its week over, an account's allowance is whole again.
    store.record_usage(&nearly.id, &usage(0.2, 0.9, NOW - 60));
    assert_eq!(chosen(None).as_deref(), Some("plenty@example.com"));
    store.record_usage(&plenty.id, &usage(1.0, 0.3, NOW + 5 * DAY));
    store.record_usage(&nearly.id, &usage(1.0, 0.9, NOW + DAY));
    assert_eq!(chosen(None).as_deref(), Some("fresh@example.com"), "never used: whole, and used once the others can't be");
    let _ = fresh;
    store.delete(&store.choose(Provider::Claude, NOW, None).unwrap().id).unwrap();
    assert_eq!(chosen(None), None, "every account at a limit: none to switch to");
}

#[tokio::test]
async fn codex_and_opencode_get_zeros_own_tools_as_claude_code_does_from_its_plugin() {
    let home = temp_dir("zero-mcp");
    let daemon = zerod::daemon::Daemon::open(&home, Arc::new(|_, _, _| Ok(crate::common::play(vec![]).0))).unwrap();
    let start = |provider| daemon.start(provider, home.to_str().unwrap(), "hi", None, None, zerod::model::Permissions::Auto).unwrap();
    for provider in [Provider::Codex, Provider::Opencode] {
        let id = start(provider);
        let mcp = daemon.session(&id).unwrap().snapshot().mcp;
        let zero = mcp.iter().find(|s| s.id == "zero").unwrap_or_else(|| panic!("{provider:?} has no Zero tools: {mcp:?}"));
        assert_eq!(zero.args, ["mcp"], "zerod's MCP server: scratchpads and the browser");
        assert!(zero.env.contains(&("ZERO_SESSION".to_string(), id.clone())), "for this task's browser");
    }
    let claude = start(Provider::Claude);
    assert!(daemon.session(&claude).unwrap().snapshot().mcp.iter().all(|s| s.id != "zero"), "Claude Code has them from Zero's plugin already");
}

#[test]
fn a_claude_account_switched_to_a_token_keeps_its_id_and_uses_the_users_own_folder() {
    let home = temp_dir("signins-to-token");
    let dot = home.join("dot-claude");
    std::fs::create_dir_all(&dot).unwrap();
    let store = SignIns::open(&home);
    store.set_claude_dir(dot);
    store.set_secrets(secrets());
    let account = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    let folder = std::path::PathBuf::from(&store.environment(&account).unwrap()[0].1);
    assert!(folder.exists());
    let token = store.save(SignIn { kind: Kind::Token, ..account.clone() }).unwrap();
    assert_eq!(token.id, account.id, "tasks set to it carry on as it");
    assert_eq!(store.environment(&token).unwrap(), [("CLAUDE_CODE_OAUTH_TOKEN".to_string(), format!("secret-for-{}", account.id))],
               "the token alone: the user's own Claude Code folder for everything else, MCP sign-ins included");
    assert!(!folder.exists(), "its own folder gone with it");
}
