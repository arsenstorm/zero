//! A new task's name, from its first message, by a small model through its own CLI (Zero calls no provider itself).

#[test]
fn a_new_task_is_named_by_a_small_model_through_its_own_cli_with_nothing_of_the_users_setup() {
    let argv = zerod::naming::command("fix the login bug; keep the old cookie name");
    let args = &argv[4..];
    assert_eq!(&args[..2], ["claude", "-p"]);
    let at = |flag: &str| args.iter().position(|a| a == flag).map(|i| args[i + 1].as_str());
    assert_eq!(at("--model"), Some("haiku"));
    assert_eq!(at("--setting-sources"), Some(""), "no settings, so no hooks or plugins");
    assert!(args.iter().any(|a| a == "--strict-mcp-config") && args.iter().any(|a| a == "--no-session-persistence"));
    assert_eq!(at("--tools"), Some(""), "words only");
    let prompt = args.last().unwrap();
    assert!(prompt.contains("fix the login bug; keep the old cookie name"), "the user's words as an argument, never through the shell");
}

#[test]
fn a_models_reply_becomes_a_short_name_or_none() {
    use zerod::naming::clean;
    assert_eq!(clean("Fix login cookie bug\n").as_deref(), Some("Fix login cookie bug"));
    assert_eq!(clean("\"Review Zero's restart handoff.\"").as_deref(), Some("Review Zero's restart handoff"));
    assert_eq!(clean("Name: Ship the usage columns").as_deref(), Some("Ship the usage columns"));
    assert_eq!(clean(""), None);
    assert_eq!(
        clean("I can't name this task without more information about what it involves and where it runs."),
        None,
        "a sentence is no name"
    );
}
