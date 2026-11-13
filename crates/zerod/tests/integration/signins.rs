//! Zero keeps the CLIs' sign-ins and gives each CLI the one chosen as a task starts: Claude Code a token or an API key
//! in its environment, Codex a home of its own where it keeps its ChatGPT sign-in, OpenCode its providers' keys. The
//! CLIs still make every call to their providers; Zero only hands them what to sign in with.

use crate::common::temp_dir;
use std::sync::Arc;
use zerod::model::Provider;
use zerod::signins::*;

fn secrets() -> Secrets {
    Arc::new(|service: &str, account: &str| (service == KEYCHAIN).then(|| format!("secret-for-{account}")))
}

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
    let go = store
        .save(SignIn { variable: Some("OPENCODE_API_KEY".into()), ..signin(Provider::Opencode, Kind::ApiKey, "OpenCode Go") })
        .unwrap();
    assert_eq!(store.environment(&go).unwrap()[0].0, "OPENCODE_API_KEY", "an OpenCode provider's own variable");
    store.set_secrets(Arc::new(|_, _| None));
    assert_eq!(
        store.environment(&token).unwrap_err(),
        "a@example.com isn't in the Keychain any more: sign in again",
        "missing: said, not started unsigned"
    );
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
    let token = |id: &str| {
        zerod::process::environment(std::iter::empty(), id).into_iter().find(|(k, _)| k == "CLAUDE_CODE_OAUTH_TOKEN").map(|(_, v)| v)
    };
    let plain = daemon
        .start(Provider::Claude, "hi", zerod::daemon::Options { cwd: Some(project.to_str().unwrap().into()), ..Default::default() })
        .unwrap();
    assert_eq!(token(&plain), Some(format!("secret-for-{}", a.id)), "no account chosen: the CLI's default");
    let chosen = daemon
        .start(
            Provider::Claude,
            "hi",
            zerod::daemon::Options { cwd: Some(project.to_str().unwrap().into()), signin: Some(b.id.clone()), ..Default::default() },
        )
        .unwrap();
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
    std::fs::write(home.join(".claude.json"), r#"{"oauthAccount": {"emailAddress": "me@example.com"}, "mcpServers": {"docs": {}}}"#)
        .unwrap();
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
    let window =
        |name: &str, used: f64, resets: i64| zerod::model::UsageWindow { name: name.into(), used, resets_at: Some(resets), read_at: None };
    zerod::model::Usage {
        limited: five >= 1.0,
        resets_at: (five >= 1.0).then_some(NOW + 3_600),
        windows: vec![window("5 hours", five, NOW + 3_600), window("7 days", seven, seven_resets)],
        ..Default::default()
    }
}
const NOW: i64 = 1_800_000_000;
const DAY: i64 = 86_400;

#[test]
fn a_task_runs_as_the_account_with_the_least_of_its_week_left_that_isnt_at_a_limit() {
    let store = SignIns::open(&temp_dir("signins-choose"));
    let account = |label: &str| store.save(signin(Provider::Claude, Kind::ClaudeHome, label)).unwrap();
    let (nearly, plenty, stopped, fresh) =
        (account("nearly@example.com"), account("plenty@example.com"), account("stopped@example.com"), account("fresh@example.com"));
    store.record_usage(&nearly.id, &usage(0.2, 0.9, NOW + 2 * DAY));
    store.record_usage(&plenty.id, &usage(0.1, 0.3, NOW + 5 * DAY));
    store.record_usage(&stopped.id, &usage(1.0, 0.95, NOW + DAY));
    let chosen = |except: Option<&str>| store.choose(Provider::Claude, NOW, except).map(|s| s.label);
    assert_eq!(
        chosen(None).as_deref(),
        Some("nearly@example.com"),
        "the least of its week left goes first; one at its 5-hour limit doesn't"
    );
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

/// What a task hears of its account's usage adds to what's known, rather than wiping it: a report without window
/// figures (a limit said in an error, an account just switched to) keeps the windows read before, and one with a
/// window keeps the others.
#[test]
fn a_report_without_figures_keeps_the_accounts_windows() {
    let store = SignIns::open(&temp_dir("signins-merge"));
    let account = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    store.record_usage(&account.id, &usage(0.4, 0.7, NOW + DAY));
    store.record_usage(&account.id, &zerod::model::Usage { limited: false, resets_at: None, windows: vec![], ..Default::default() });
    assert_eq!(store.usage(&account.id).unwrap().windows.len(), 2, "kept");
    let week = zerod::model::UsageWindow { name: "7 days".into(), used: 0.8, resets_at: Some(NOW + DAY), read_at: None };
    store.record_usage(&account.id, &zerod::model::Usage { limited: false, resets_at: None, windows: vec![week], ..Default::default() });
    let now = store.usage(&account.id).unwrap();
    let used = |name: &str| now.windows.iter().find(|w| w.name == name).map(|w| w.used);
    assert_eq!((used("5 hours"), used("7 days")), (Some(0.4), Some(0.8)), "the week updated, the 5 hours kept");
}

/// A read of the account's plan is all its windows: one it no longer reports (a 5-hour window kept from an earlier
/// report, on a plan without one) goes, rather than staying at 0%.
#[test]
fn a_read_of_the_plan_drops_the_windows_it_no_longer_has() {
    let store = SignIns::open(&temp_dir("signins-replace"));
    let account = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    store.record_usage(&account.id, &usage(0.0, 0.5, NOW + DAY));
    let week = zerod::model::UsageWindow { name: "7 days".into(), used: 0.56, resets_at: Some(NOW + DAY), read_at: None };
    store.replace_usage(
        &account.id,
        &zerod::model::Usage { limited: false, resets_at: None, windows: vec![week.clone()], ..Default::default() },
    );
    assert_eq!(store.usage(&account.id).unwrap().windows, vec![week.clone()], "the 5 hours dropped");
    store.record_usage(&account.id, &zerod::model::Usage { limited: false, resets_at: None, windows: vec![], ..Default::default() });
    assert_eq!(store.usage(&account.id).unwrap().windows, vec![week.clone()], "and not brought back by a task's report");
    // A read that gave no window at all (its CLI answered without its rate limits) didn't read the plan: what was
    // known stays, rather than the account's usage going from the sidebar.
    store.replace_usage(&account.id, &zerod::model::Usage { limited: false, resets_at: None, windows: vec![], ..Default::default() });
    assert_eq!(store.usage(&account.id).unwrap().windows, vec![week], "kept");
}

/// When a turn last ended on each account, to the second: what the app shows the most recently used account by. Kept
/// across a restart; a later turn moves it on, an earlier one (counted late) doesn't move it back.
#[test]
fn an_accounts_last_turn_is_kept_to_the_second() {
    let home = temp_dir("signins-last-turn");
    let store = SignIns::open(&home);
    let (a, b) = (
        store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap(),
        store.save(signin(Provider::Codex, Kind::CodexHome, "b@example.com")).unwrap(),
    );
    store.record_turn(&a.id, NOW);
    store.record_turn(&b.id, NOW + 61);
    store.record_turn(&a.id, NOW - 600);
    let last = SignIns::open(&home).last_turns();
    assert_eq!((last.get(&a.id), last.get(&b.id)), (Some(&NOW), Some(&(NOW + 61))));
    // Counted before the exact time was kept (activity only): the start of its last hour.
    std::fs::write(home.join("activity.json"), format!(r#"{{"old": {{"{}": 2}}}}"#, NOW / 3600)).unwrap();
    assert_eq!(SignIns::open(&home).last_turns().get("old"), Some(&(NOW / 3600 * 3600)));
}

/// Each account's activity, as a contribution graph counts it: the turns its tasks finished, by the hour they ended
/// in (the app puts them in the user's own days), kept across a restart.
#[test]
fn an_accounts_finished_turns_are_counted_by_the_hour() {
    let home = temp_dir("signins-activity");
    let store = SignIns::open(&home);
    let account = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    store.record_turn(&account.id, NOW);
    store.record_turn(&account.id, NOW + 60);
    store.record_turn(&account.id, NOW + 3_600);
    let counted = SignIns::open(&home).activity();
    assert_eq!(counted.get(&account.id).map(|hours| hours.values().copied().collect::<Vec<_>>()), Some(vec![2, 1]));
}

/// One Activity for every account: an account removed (or replaced by another sign-in) keeps its days and its name,
/// and a turn run as no sign-in of Zero's (the CLI's own) counts under its CLI.
#[test]
fn activity_outlives_the_accounts_it_counts() {
    let home = temp_dir("signins-activity-kept");
    let store = SignIns::open(&home);
    let gone = store.save(signin(Provider::Claude, Kind::Token, "a@example.com")).unwrap();
    let kept = store.save(signin(Provider::Codex, Kind::CodexHome, "b@example.com")).unwrap();
    store.record_turn(&gone.id, NOW);
    store.record_turn(&kept.id, NOW);
    store.delete(&gone.id).unwrap();
    store.record_turn("claude", NOW + 3_600);
    let again = SignIns::open(&home);
    let total = |id: &str| again.activity().get(id).map_or(0, |hours| hours.values().sum::<u32>());
    assert_eq!((total(&gone.id), total(&kept.id), total("claude")), (1, 1, 1));
    let names = again.named();
    assert_eq!(names.get(&gone.id).map(|s| s.label.as_str()), Some("a@example.com"), "the removed account's name kept");
    assert_eq!(names.get(&kept.id).map(|s| s.cli), Some(Provider::Codex));
}

/// A Claude account signed in in a folder of its own is named by what Claude Code keeps there: its email (unless the
/// user named it) and its plan. Nothing else of the sign-in is read.
#[test]
fn a_claude_folder_names_its_account() {
    let home = temp_dir("signins-claude-named");
    let store = SignIns::open(&home);
    store.set_claude_dir(home.join("dot-claude"));
    let fresh = store.save(signin(Provider::Claude, Kind::ClaudeHome, "Claude")).unwrap();
    let renamed = store.save(signin(Provider::Claude, Kind::ClaudeHome, "Work")).unwrap();
    let account = serde_json::json!({"oauthAccount": {"emailAddress": "a@example.com", "organizationName": "A's Organization",
        "organizationType": "claude_max", "planDisplayName": "Max"}});
    for id in [&fresh.id, &renamed.id] {
        let folder = store.folder(Provider::Claude, id).unwrap();
        std::fs::write(folder.join(".claude.json"), account.to_string()).unwrap();
    }
    assert!(store.name_claude_folders(), "something changed");
    let named = store.get(&fresh.id).unwrap();
    assert_eq!((named.label.as_str(), named.plan.as_deref()), ("a@example.com", Some("Max")));
    let kept = store.get(&renamed.id).unwrap();
    assert_eq!((kept.label.as_str(), kept.plan.as_deref()), ("Work", Some("Max")), "the user's name kept");
    assert!(!store.name_claude_folders(), "read again, nothing new");
}

/// An account its provider refused a model on (no access to it) isn't chosen for that model again; for others it is.
#[test]
fn an_account_refused_a_model_isnt_chosen_for_it() {
    let home = temp_dir("signins-refused");
    let store = SignIns::open(&home);
    let account = |label: &str| store.save(signin(Provider::Claude, Kind::ClaudeHome, label)).unwrap();
    let (nearly, plenty) = (account("nearly@example.com"), account("plenty@example.com"));
    store.record_usage(&nearly.id, &usage(0.2, 0.9, NOW + 2 * DAY));
    store.record_usage(&plenty.id, &usage(0.1, 0.3, NOW + 5 * DAY));
    store.refuse(&nearly.id, "claude-mythos-5-2");
    let chosen = |model: Option<&str>| store.choose_for(Provider::Claude, NOW, None, model).map(|s| s.label);
    assert_eq!(chosen(Some("claude-mythos-5-2")).as_deref(), Some("plenty@example.com"));
    assert_eq!(chosen(Some("claude-opus-5-5")).as_deref(), Some("nearly@example.com"), "other models still go by usage");
    assert_eq!(store.refused(&nearly.id), ["claude-mythos-5-2"]);
    store.refuse(&plenty.id, "claude-mythos-5-2");
    assert_eq!(chosen(Some("claude-mythos-5-2")), None, "no account can use it");
    // Kept for the next start.
    let again = SignIns::open(&home);
    assert_eq!(again.refused(&plenty.id), ["claude-mythos-5-2"]);
}

#[test]
fn a_model_refused_is_told_from_a_busy_one() {
    use zerod::signins::refuses_model;
    assert!(refuses_model(
        "There's an issue with the selected model (claude-mythos-5-2). It may not exist or you may not have access to it. Run /model to pick a different model."
    ));
    assert!(refuses_model("The 'gpt-6' model is not supported when using Codex with a ChatGPT account."));
    assert!(refuses_model("model_not_found: The model `gpt-6` does not exist or you do not have access to it."));
    assert!(!refuses_model("API Error: 529 Overloaded"));
    assert!(!refuses_model("You've hit your limit"));
}

#[tokio::test]
async fn codex_and_opencode_get_zeros_own_tools_as_claude_code_does_from_its_plugin() {
    let home = temp_dir("zero-mcp");
    let daemon = zerod::daemon::Daemon::open(&home, Arc::new(|_, _, _| Ok(crate::common::play(vec![]).0))).unwrap();
    let start = |provider| {
        daemon.start(provider, "hi", zerod::daemon::Options { cwd: Some(home.to_str().unwrap().into()), ..Default::default() }).unwrap()
    };
    for provider in [Provider::Codex, Provider::Opencode] {
        let id = start(provider);
        let mcp = daemon.session(&id).unwrap().snapshot().mcp;
        let zero = mcp.iter().find(|s| s.id == "zero").unwrap_or_else(|| panic!("{provider:?} has no Zero tools: {mcp:?}"));
        assert_eq!(zero.args, ["mcp"], "zerod's MCP server: scratchpads and the browser");
        assert!(zero.env.contains(&("ZERO_SESSION".to_string(), id.clone())), "for this task's browser");
    }
    let claude = start(Provider::Claude);
    assert!(
        daemon.session(&claude).unwrap().snapshot().mcp.iter().all(|s| s.id != "zero"),
        "Claude Code has them from Zero's plugin already"
    );
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
    assert_eq!(
        store.environment(&token).unwrap(),
        [("CLAUDE_CODE_OAUTH_TOKEN".to_string(), format!("secret-for-{}", account.id))],
        "the token alone: the user's own Claude Code folder for everything else, MCP sign-ins included"
    );
    assert!(!folder.exists(), "its own folder gone with it");
}

/// Zero reads each account's usage itself: again in a quarter of an hour, or just after a window resets if that's
/// sooner (a limit's end read at once); a read that failed is tried again less and less often, at most half an hour
/// apart, so a provider that's down isn't hammered.
#[test]
fn usage_is_read_every_quarter_hour_just_after_a_reset_and_less_often_while_reads_fail() {
    use zerod::model::{Usage, UsageWindow};
    let window = |used: f64, resets: i64| UsageWindow { name: "5 hours".into(), used, resets_at: Some(resets), read_at: Some(NOW) };
    let read = Usage { windows: vec![window(0.2, NOW + 3_600)], ..Default::default() };
    assert_eq!(next_read(NOW, Some(&read), 0), NOW + 15 * 60);
    let resetting = Usage { windows: vec![window(0.9, NOW + 300)], ..Default::default() };
    assert_eq!(next_read(NOW, Some(&resetting), 0), NOW + 330, "just after the reset");
    let stopped = Usage { limited: true, resets_at: Some(NOW + 120), windows: vec![], ..Default::default() };
    assert_eq!(next_read(NOW, Some(&stopped), 0), NOW + 150);
    let reset = Usage { windows: vec![window(0.9, NOW - 60)], ..Default::default() };
    assert_eq!(next_read(NOW, Some(&reset), 0), NOW + 15 * 60, "a reset that's passed isn't waited for");
    let failed: Vec<i64> = [1, 2, 3, 4, 10].iter().map(|n| next_read(NOW, None, *n) - NOW).collect();
    assert_eq!(failed, [60, 120, 240, 480, 1800]);
}

/// A read that says the account's plan has no windows (an API-billed account) is kept as such, its figures gone.
#[test]
fn a_plan_without_limits_is_kept_as_such() {
    let store = SignIns::open(&temp_dir("signins-no-limits"));
    let account = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    store.record_usage(&account.id, &usage(0.4, 0.7, NOW + DAY));
    store.replace_usage(&account.id, &zerod::model::Usage { no_limits: true, ..Default::default() });
    let kept = store.usage(&account.id).unwrap();
    assert!(kept.no_limits && kept.windows.is_empty());
}

/// A Keychain of the test's own: what's read and written, by (service, account).
fn keychain(store: &SignIns) -> Arc<std::sync::Mutex<std::collections::HashMap<(String, String), String>>> {
    let items: Arc<std::sync::Mutex<std::collections::HashMap<(String, String), String>>> = Arc::default();
    let read = items.clone();
    store.set_secrets(Arc::new(move |service: &str, account: &str| read.lock().unwrap().get(&(service.into(), account.into())).cloned()));
    // No Claude running in any folder, unless a test says so.
    store.set_in_use(Arc::new(|_: &std::path::Path| false));
    let write = items.clone();
    store.set_store(Arc::new(move |service: &str, account: &str, value: Option<&str>| {
        let key = (service.to_string(), account.to_string());
        match value {
            Some(value) => write.lock().unwrap().insert(key, value.into()),
            None => write.lock().unwrap().remove(&key),
        };
        Ok(())
    }));
    items
}

/// Claude Code's Keychain item for a folder, as it names it: the folder's own, where it keeps its sign-in and its MCP
/// servers' alike.
fn item_of(store: &SignIns, signin: &SignIn) -> (String, String) {
    let folder = std::path::PathBuf::from(&store.environment(signin).unwrap()[0].1);
    (claude_keychain(Some(&folder)), claude_user())
}

fn entry(token: &str, expires: i64) -> serde_json::Value {
    serde_json::json!({"serverName": "linear", "accessToken": token, "refreshToken": format!("r-{token}"), "expiresAt": expires})
}

#[test]
fn claude_names_a_folders_keychain_item_by_its_path() {
    assert_eq!(claude_keychain(None), "Claude Code-credentials", "the user's own folder");
    let hash: String =
        zerod::integrations::sha256(b"/Users/me/.zero/zerod/claude-homes/abc")[..4].iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        claude_keychain(Some(std::path::Path::new("/Users/me/.zero/zerod/claude-homes/abc"))),
        format!("Claude Code-credentials-{hash}")
    );
}

/// An MCP server's sign-in (its OAuth) is kept by Claude Code in each folder's Keychain item: signed in once, in any
/// account's folder, Zero keeps it and gives it to every account's folder as its task starts, leaving the account's
/// own sign-in there as it was.
#[test]
fn an_mcp_servers_sign_in_in_one_claude_folder_is_every_accounts() {
    let home = temp_dir("signins-mcp-share");
    let store = SignIns::open(&home);
    store.set_claude_dir(home.join("dot-claude"));
    let items = keychain(&store);
    let a = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    let b = store.save(signin(Provider::Claude, Kind::ClaudeHome, "b@example.com")).unwrap();
    let (item_a, item_b) = (item_of(&store, &a), item_of(&store, &b));
    let signed_in = serde_json::json!({"claudeAiOauth": {"accessToken": "a-account"}, "mcpOAuth": {"linear|abc": entry("t1", 100)}});
    items.lock().unwrap().insert(item_a.clone(), signed_in.to_string());
    items.lock().unwrap().insert(item_b.clone(), serde_json::json!({"claudeAiOauth": {"accessToken": "b-account"}}).to_string());

    store.environment(&b).unwrap();
    let b_now: serde_json::Value = serde_json::from_str(&items.lock().unwrap()[&item_b]).unwrap();
    assert_eq!(b_now["mcpOAuth"]["linear|abc"], entry("t1", 100), "signed in to Linear in a's folder: b's has it too");
    assert_eq!(b_now["claudeAiOauth"]["accessToken"], "b-account", "b's own sign-in untouched");
    assert!(items.lock().unwrap().contains_key(&(KEYCHAIN.to_string(), "mcp:linear|abc".to_string())), "Zero keeps it itself");

    // a gone, its folder and item with it: what Zero kept still reaches a new account's folder.
    store.delete(&a.id).unwrap();
    items.lock().unwrap().remove(&item_a);
    let c = store.save(signin(Provider::Claude, Kind::ClaudeHome, "c@example.com")).unwrap();
    let item_c = item_of(&store, &c);
    items.lock().unwrap().insert(item_c.clone(), serde_json::json!({"claudeAiOauth": {"accessToken": "c-account"}}).to_string());
    store.environment(&c).unwrap();
    let c_now: serde_json::Value = serde_json::from_str(&items.lock().unwrap()[&item_c]).unwrap();
    assert_eq!(c_now["mcpOAuth"]["linear|abc"]["accessToken"], "t1");
}

/// Claude Code refreshes a server's sign-in in the folder whose task it runs: the latest to expire is the one every
/// folder gets, and a folder not signed in yet (no item) isn't given one before its account is.
#[test]
fn the_latest_refreshed_mcp_sign_in_is_the_one_shared() {
    let home = temp_dir("signins-mcp-fresh");
    let store = SignIns::open(&home);
    store.set_claude_dir(home.join("dot-claude"));
    let items = keychain(&store);
    let a = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    let b = store.save(signin(Provider::Claude, Kind::ClaudeHome, "b@example.com")).unwrap();
    let pending = store.save(SignIn { pending: true, ..signin(Provider::Claude, Kind::ClaudeHome, "Claude") }).unwrap();
    let (item_a, item_b) = (item_of(&store, &a), item_of(&store, &b));
    let item_pending = item_of(&store, &SignIn { pending: false, ..pending.clone() });
    items.lock().unwrap().insert(item_a.clone(), serde_json::json!({"mcpOAuth": {"linear|abc": entry("old", 100)}}).to_string());
    items.lock().unwrap().insert(item_b.clone(), serde_json::json!({"mcpOAuth": {"linear|abc": entry("new", 200)}}).to_string());

    store.environment(&a).unwrap();
    let a_now: serde_json::Value = serde_json::from_str(&items.lock().unwrap()[&item_a]).unwrap();
    assert_eq!(a_now["mcpOAuth"]["linear|abc"], entry("new", 200), "b refreshed it since");
    store.environment(&b).unwrap();
    let b_now: serde_json::Value = serde_json::from_str(&items.lock().unwrap()[&item_b]).unwrap();
    assert_eq!(b_now["mcpOAuth"]["linear|abc"], entry("new", 200), "a's older one doesn't go back");
    assert!(!items.lock().unwrap().contains_key(&item_pending), "an account still signing in has no item made for it");
}

/// A Claude Code token switched to a browser sign-in: the same account, signed in in a folder of its own under the
/// token's id, so tasks set to it carry on and its activity and usage stay; the token goes from the Keychain.
#[test]
fn a_token_switched_to_a_folder_keeps_its_id_and_activity_and_lets_the_token_go() {
    let home = temp_dir("signins-token-to-folder");
    let store = SignIns::open(&home);
    store.set_claude_dir(home.join("dot-claude"));
    let items = keychain(&store);
    let token = store.save(signin(Provider::Claude, Kind::Token, "Claude account")).unwrap();
    items.lock().unwrap().insert((KEYCHAIN.into(), token.id.clone()), "the-token".into());
    store.record_turn(&token.id, 7200);

    let switched = store
        .switched_to_folder(&token.id, zerod::codex_login::Account { email: Some("me@example.com".into()), plan: Some("max".into()) })
        .unwrap();
    assert_eq!((switched.id.as_str(), switched.kind, switched.label.as_str()), (token.id.as_str(), Kind::ClaudeHome, "me@example.com"));
    assert_eq!(switched.plan.as_deref(), Some("max"));
    assert_eq!(store.environment(&switched).unwrap()[0].0, "CLAUDE_CONFIG_DIR");
    assert!(!items.lock().unwrap().contains_key(&(KEYCHAIN.to_string(), token.id.clone())), "the token let go");
    assert_eq!(store.activity()[&token.id].values().sum::<u32>(), 1, "its activity kept");
}

/// Claude Code rotates an account's refresh token as it renews it, and writes the folder's item as it does: an item
/// written over at the same time would lose that and sign the account out. So a folder with Claude running in it (a
/// task's, or one the user started there) isn't written; it gets its servers' sign-ins at its next start with none.
#[test]
fn a_folder_claude_is_running_in_is_left_until_its_next_start() {
    let home = temp_dir("signins-mcp-busy");
    let store = SignIns::open(&home);
    store.set_claude_dir(home.join("dot-claude"));
    let items = keychain(&store);
    let a = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    let b = store.save(signin(Provider::Claude, Kind::ClaudeHome, "b@example.com")).unwrap();
    let (item_a, item_b) = (item_of(&store, &a), item_of(&store, &b));
    items.lock().unwrap().insert(item_a, serde_json::json!({"mcpOAuth": {"linear|abc": entry("t1", 100)}}).to_string());
    let before = serde_json::json!({"claudeAiOauth": {"accessToken": "b-account"}}).to_string();
    items.lock().unwrap().insert(item_b.clone(), before.clone());

    let running = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let busy = running.clone();
    store.set_in_use(Arc::new(move |_: &std::path::Path| busy.load(std::sync::atomic::Ordering::SeqCst)));
    store.environment(&b).unwrap();
    assert_eq!(items.lock().unwrap()[&item_b], before, "Claude is running in b's folder: not written");
    running.store(false, std::sync::atomic::Ordering::SeqCst);
    store.environment(&b).unwrap();
    assert!(items.lock().unwrap()[&item_b].contains("linear|abc"), "its next start with none running");
}

/// What Zero writes to a folder's item is the servers' sign-ins it adds or renews, and nothing else: the account's own
/// sign-in, and every other server's, stay as they were read, to the byte.
#[test]
fn only_the_servers_sign_ins_added_change_in_a_folders_item() {
    let home = temp_dir("signins-mcp-bytes");
    let store = SignIns::open(&home);
    store.set_claude_dir(home.join("dot-claude"));
    let items = keychain(&store);
    let a = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    let b = store.save(signin(Provider::Claude, Kind::ClaudeHome, "b@example.com")).unwrap();
    let (item_a, item_b) = (item_of(&store, &a), item_of(&store, &b));
    let new = serde_json::json!({"mcpOAuth": {"linear|abc": entry("new", 200), "amie|x": entry("amie", 50)}});
    items.lock().unwrap().insert(item_a, new.to_string());
    let account = r#"{"zeta":1, "accessToken":"b-account","expiresAt":1.50e3}"#;
    let other = r#"{ "accessToken" : "o" }"#;
    let old = r#"{"accessToken":"old","expiresAt":100}"#;
    let before = format!(r#"{{"claudeAiOauth": {account},"mcpOAuth":{{"other|y":{other},"linear|abc":{old}}} }}"#);
    items.lock().unwrap().insert(item_b.clone(), before);

    store.environment(&b).unwrap();
    let after = items.lock().unwrap()[&item_b].clone();
    let renewed = entry("new", 200).to_string();
    let added = entry("amie", 50).to_string();
    assert_eq!(
        after,
        format!(r#"{{"claudeAiOauth": {account},"mcpOAuth":{{"other|y":{other},"linear|abc":{renewed},"amie|x":{added}}} }}"#)
    );

    let bare = store.save(signin(Provider::Claude, Kind::ClaudeHome, "c@example.com")).unwrap();
    let item_c = item_of(&store, &bare);
    items.lock().unwrap().insert(item_c.clone(), format!(r#"{{"claudeAiOauth":{account}}}"#));
    store.environment(&bare).unwrap();
    let after = items.lock().unwrap()[&item_c].clone();
    assert!(after.starts_with(&format!(r#"{{"claudeAiOauth":{account},"mcpOAuth":{{"#)), "{after}");
    let parsed: serde_json::Value = serde_json::from_str(&after).unwrap();
    assert_eq!(parsed["mcpOAuth"].as_object().unwrap().len(), 3, "linear and amie from a, the other from b");
}

/// Whether Claude runs in a folder is told from the processes' environments: any with CLAUDE_CONFIG_DIR set to it.
#[test]
fn a_process_started_in_a_claude_folder_is_seen() {
    let folder = temp_dir("signins-in-use").join("claude-homes").join("abc");
    assert!(!folder_in_use(&folder));
    let home = temp_dir("signins-in-use-home");
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_zerod"))
        .args(["mcp", "--home", &home.join("zerod").to_string_lossy(), "--socket", &home.join("none.sock").to_string_lossy()])
        .env("HOME", &home)
        .env("CLAUDE_CONFIG_DIR", &folder)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(300));
    let seen = folder_in_use(&folder);
    let other = folder_in_use(&folder.with_file_name("ab"));
    let _ = child.kill();
    let _ = child.wait();
    assert!(seen, "a process with CLAUDE_CONFIG_DIR set to it");
    assert!(!other, "a folder whose path starts the same isn't it");
}

/// A folder's item goes to the Keychain on a line of `security -i` (about 4 KB), never a command line: what doesn't fit
/// on it is left for the folder's next start. The servers used last (their sign-ins expiring last, as Claude Code
/// renews one as it uses it) go first.
#[test]
fn a_folders_item_takes_the_servers_used_last_that_fit_and_the_rest_wait() {
    let home = temp_dir("signins-mcp-partial");
    let store = SignIns::open(&home);
    store.set_claude_dir(home.join("dot-claude"));
    let items = keychain(&store);
    let a = store.save(signin(Provider::Claude, Kind::ClaudeHome, "a@example.com")).unwrap();
    let b = store.save(signin(Provider::Claude, Kind::ClaudeHome, "b@example.com")).unwrap();
    let (item_a, item_b) = (item_of(&store, &a), item_of(&store, &b));
    let big = |name: &str, expires: i64| serde_json::json!({"serverName": name, "accessToken": "t".repeat(1500), "refreshToken": "r", "expiresAt": expires});
    let signed_in =
        serde_json::json!({"mcpOAuth": {"old|1": big("old", 100), "newest|2": big("newest", 300), "middle|3": big("middle", 200)}});
    items.lock().unwrap().insert(item_a, signed_in.to_string());
    items.lock().unwrap().insert(item_b.clone(), serde_json::json!({"claudeAiOauth": {"accessToken": "b-account"}}).to_string());

    store.environment(&b).unwrap();
    let written = items.lock().unwrap()[&item_b].clone();
    assert!(zerod::mcp_servers::fits_keychain(&item_b.0, &item_b.1, &written), "it fits a line of security -i");
    let b_now: serde_json::Value = serde_json::from_str(&written).unwrap();
    let names: std::collections::BTreeSet<&str> = b_now["mcpOAuth"].as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(names, ["middle|3", "newest|2"].into(), "the two used last; the oldest waits");
    assert_eq!(b_now["claudeAiOauth"]["accessToken"], "b-account");
}

/// Turns were counted from when Zero started counting them; those before are in the tasks' transcripts (their CLIs'
/// own words, each line with when zerod heard it). Counted from there once, under each task's CLI (which account each
/// ran as wasn't kept): finished turns only, and only those before the first one counted, so none counts twice.
#[test]
fn turns_from_before_counting_began_are_counted_from_the_transcripts_once() {
    let home = temp_dir("signins-earlier-turns");
    let task = |kind: &str, id: &str, provider: &str, lines: &[serde_json::Value]| {
        let dir = home.join(kind).join(id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("meta.json"), serde_json::json!({"id": id, "provider": provider, "cwd": "/"}).to_string()).unwrap();
        let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
        std::fs::write(dir.join("transcript.jsonl"), text).unwrap();
    };
    let hour = 3_600_000i64;
    let at = |h: i64| 1_000 * hour + h * hour + 5;
    let done = |h: i64| serde_json::json!({"at": at(h), "in": {"type": "result", "subtype": "success", "is_error": false}});
    task(
        "archive",
        "a1",
        "claude",
        &[
            serde_json::json!({"at": at(0), "out": {"type": "user"}}),
            done(0),
            done(0),
            serde_json::json!({"at": at(1), "in": {"type": "result", "subtype": "error_during_execution", "is_error": true}}),
            done(30),
        ],
    );
    task(
        "sessions",
        "s1",
        "codex",
        &[
            serde_json::json!({"at": at(2), "in": {"method": "turn/completed", "params": {"turn": {"status": "completed"}}}}),
            serde_json::json!({"at": at(2), "in": {"method": "turn/completed", "params": {"turn": {"status": "interrupted"}}}}),
        ],
    );
    task(
        "sessions",
        "s2",
        "opencode",
        &[
            serde_json::json!({"at": at(3), "in": {"jsonrpc": "2.0", "id": 4, "result": {"stopReason": "end_turn"}}}),
            serde_json::json!({"at": at(3), "in": {"jsonrpc": "2.0", "id": 5, "result": {"stopReason": "cancelled"}}}),
        ],
    );
    let store = SignIns::open(&home);
    store.record_turn("acct", at(20) / 1000);

    store.count_earlier_turns(&[home.join("sessions"), home.join("archive")]);
    let activity = store.activity();
    assert_eq!(activity["claude"], [(1_000, 2)].into(), "the finished ones, before counting began; the one after was counted live");
    assert_eq!(activity["codex"], [(1_002, 1)].into());
    assert_eq!(activity["opencode"], [(1_003, 1)].into());
    assert_eq!(activity["acct"], [(1_020, 1)].into(), "what was counted stays as it was");

    store.count_earlier_turns(&[home.join("sessions"), home.join("archive")]);
    assert_eq!(SignIns::open(&home).activity()["claude"], [(1_000, 2)].into(), "once: kept, and not counted again");
}
