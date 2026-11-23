//! MCP servers set up once in Zero and given to every task's CLI as it starts: each for every workspace, or only the
//! workspaces it's put in; a secret from the Keychain, the server's own command, or Zero's file.

use crate::common::temp_dir;
use zerod::mcp_servers::*;

fn server(name: &str, workspaces: &[&str]) -> McpServer {
    McpServer {
        id: String::new(),
        name: name.into(),
        command: Some("cve-mcp".into()),
        args: vec!["--stdio".into()],
        url: None,
        env: vec![],
        headers: vec![],
        workspaces: workspaces.iter().map(|w| w.to_string()).collect(),
        enabled: true,
        lazy: false,
    }
}

#[test]
fn servers_are_kept_and_each_workspace_gets_its_own_and_everyones() {
    let home = temp_dir("mcp-servers");
    let servers = McpServers::open(&home);
    let everywhere = servers.save(server("Docs", &[])).unwrap();
    let cve = servers.save(server("CVE lookup", &["cybersecurity"])).unwrap();
    assert_eq!((everywhere.id.as_str(), cve.id.as_str()), ("docs", "cve-lookup"));
    let mut off = server("Off", &[]);
    off.enabled = false;
    servers.save(off).unwrap();
    let names = |ws: &str| servers.for_workspace(ws).into_iter().map(|s| s.name).collect::<Vec<_>>();
    assert_eq!(names("cybersecurity"), ["Docs", "CVE lookup"]);
    assert_eq!(names("zero"), ["Docs"], "a workspace's server isn't anyone else's; one turned off is no one's");
    assert_eq!(
        servers.save(McpServer { command: None, url: None, ..server("Nothing", &[]) }).unwrap_err(),
        "A server runs a command or is at a URL"
    );
    assert_eq!(servers.save(server("  ", &[])).unwrap_err(), "A server needs a name");
    servers.delete("docs").unwrap();
    assert_eq!(
        McpServers::open(&home).list().iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
        ["cve-lookup", "off"],
        "kept across restarts"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(home.join("mcp-servers.json")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "values may be secrets: only the user reads the file");
    }
}

#[test]
fn a_secret_comes_from_where_it_is_kept() {
    let servers = McpServers::open(&temp_dir("mcp-secrets"));
    let mut cve = server("CVE lookup", &[]);
    cve.env = vec![
        Value { name: "API_KEY".into(), value: None, from: Source::Keychain },
        Value { name: "REGION".into(), value: Some("eu".into()), from: Source::File },
        Value { name: "TOKEN".into(), value: None, from: Source::Command },
    ];
    let saved = servers.save(cve).unwrap();
    // The Keychain's item for it, read when a session starts; the file's value as kept; the command's, nothing here.
    let resolved = saved.resolve(&|service, account| (service == KEYCHAIN && account == "cve-lookup.API_KEY").then(|| "k-123".to_string()));
    assert_eq!(resolved.env, [("API_KEY".to_string(), "k-123".to_string()), ("REGION".into(), "eu".into())]);
    let missing = saved.resolve(&|_, _| None);
    assert_eq!(missing.env, [("REGION".to_string(), "eu".to_string())], "a Keychain value not there yet: left out, not an empty string");
    // A Keychain value is never written to the file.
    let mut leaky = saved.clone();
    leaky.env[0].value = Some("typed".into());
    let kept = servers.save(leaky).unwrap();
    assert_eq!(kept.env[0].value, None);
}

fn resolved() -> Vec<Resolved> {
    vec![
        Resolved {
            id: "cve-lookup".into(),
            name: "CVE lookup".into(),
            command: Some("cve-mcp".into()),
            args: vec!["--stdio".into()],
            url: None,
            env: vec![("API_KEY".into(), "k-123".into())],
            headers: vec![],
        },
        Resolved {
            id: "docs".into(),
            name: "Docs".into(),
            command: None,
            args: vec![],
            url: Some("https://docs.example/mcp".into()),
            env: vec![],
            headers: vec![("Authorization".into(), "Bearer t".into())],
        },
    ]
}

#[test]
fn claude_is_given_them_on_its_command_line_with_the_values_in_its_environment() {
    let (config, env) = zerod::claude::mcp_config(&resolved()).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&config).unwrap();
    assert_eq!(parsed["mcpServers"]["cve-lookup"]["command"], "cve-mcp");
    assert_eq!(parsed["mcpServers"]["cve-lookup"]["env"]["API_KEY"], "${ZERO_MCP_CVE_LOOKUP_API_KEY}", "a reference, not the secret");
    assert_eq!(parsed["mcpServers"]["docs"]["type"], "http");
    assert_eq!(parsed["mcpServers"]["docs"]["headers"]["Authorization"], "${ZERO_MCP_DOCS_AUTHORIZATION}");
    assert!(!config.contains("k-123") && !config.contains("Bearer t"), "no value on the command line");
    assert_eq!(
        env,
        [("ZERO_MCP_CVE_LOOKUP_API_KEY".to_string(), "k-123".to_string()), ("ZERO_MCP_DOCS_AUTHORIZATION".into(), "Bearer t".into())]
    );
    assert!(zerod::claude::mcp_config(&[]).is_none());
}

#[test]
fn codex_and_opencode_are_given_them_with_their_thread() {
    let codex = zerod::codex::mcp_config(&resolved());
    assert_eq!(codex["mcp_servers.cve-lookup"]["command"], "cve-mcp");
    assert_eq!(codex["mcp_servers.cve-lookup"]["env"]["API_KEY"], "k-123", "over stdin, not the command line");
    assert_eq!(codex["mcp_servers.docs"]["url"], "https://docs.example/mcp");
    assert_eq!(codex["mcp_servers.docs"]["http_headers"]["Authorization"], "Bearer t");
    let acp = zerod::acp::mcp_servers(&resolved());
    assert_eq!(
        acp[0],
        serde_json::json!({"name": "cve-lookup", "command": "cve-mcp", "args": ["--stdio"], "env": [{"name": "API_KEY", "value": "k-123"}]})
    );
    assert_eq!(
        acp[1],
        serde_json::json!({"type": "http", "name": "docs", "url": "https://docs.example/mcp", "headers": [{"name": "Authorization", "value": "Bearer t"}]})
    );
}

#[test]
fn a_server_that_starts_when_first_used_is_given_as_zerods_stand_in_for_it() {
    let lazy = McpServer { lazy: true, ..server("Icons", &[]) }.resolve(&|_, _| None);
    assert_eq!(lazy.command.as_deref(), std::env::current_exe().ok().as_deref().and_then(|p| p.to_str()));
    assert_eq!(lazy.args, ["mcp", "lazy", "cve-mcp", "--stdio"]);
    // A remote one has nothing to start.
    let remote =
        McpServer { lazy: true, command: None, args: vec![], url: Some("https://mcp.example/mcp".into()), ..server("Remote", &[]) };
    assert_eq!(remote.resolve(&|_, _| None).url.as_deref(), Some("https://mcp.example/mcp"));
    // Kept as set, and read as off from a file written before there was the setting.
    let old: McpServer = serde_json::from_str(r#"{"id": "a", "name": "A", "command": "x"}"#).unwrap();
    assert!(!old.lazy);
    assert_eq!(serde_json::to_value(McpServer { lazy: true, ..server("Icons", &[]) }).unwrap()["lazy"], true);
}

#[test]
fn what_a_cli_is_told_of_a_servers_values_is_kept_without_them() {
    use serde_json::json;
    let codex = json!({"id": 3, "method": "thread/start", "params": {"cwd": "/p", "config": zerod::codex::mcp_config(&resolved())}});
    let kept = redacted(&codex).expect("a thread's servers carry values");
    assert_eq!(kept["params"]["config"]["mcp_servers.cve-lookup"]["env"]["API_KEY"], HIDDEN);
    assert_eq!(kept["params"]["config"]["mcp_servers.docs"]["http_headers"]["Authorization"], HIDDEN);
    assert_eq!(kept["params"]["config"]["mcp_servers.docs"]["url"], "https://docs.example/mcp", "only the values");
    assert_eq!(kept["id"], 3);
    let acp =
        json!({"id": 1, "method": "session/resume", "params": {"sessionId": "s", "mcpServers": zerod::acp::mcp_servers(&resolved())}});
    let kept = redacted(&acp).unwrap();
    assert_eq!(kept["params"]["mcpServers"][0]["env"][0], json!({"name": "API_KEY", "value": HIDDEN}));
    assert_eq!(kept["params"]["mcpServers"][1]["headers"][0], json!({"name": "Authorization", "value": HIDDEN}));
    let claude = json!({"type": "control_request", "request_id": "r", "request": {"subtype": "mcp_set_servers", "servers":
        {"docs": {"type": "http", "url": "https://docs.example/mcp", "headers": {"Authorization": "Bearer t"}}}}});
    assert_eq!(redacted(&claude).unwrap()["request"]["servers"]["docs"]["headers"]["Authorization"], HIDDEN);
    // Claude's status of its servers says a remote one's headers back.
    let status = json!({"type": "control_response", "response": {"subtype": "success", "request_id": "z1", "response": {"mcpServers": [
        {"name": "docs", "status": "connected", "config": {"type": "http", "url": "https://docs.example/mcp", "headers": {"Authorization": "Bearer t"}}}]}}});
    assert_eq!(redacted(&status).unwrap()["response"]["response"]["mcpServers"][0]["config"]["headers"]["Authorization"], HIDDEN);
    for plain in [
        json!({"id": 4, "method": "turn/start", "params": {"input": [{"type": "text", "text": "env: API_KEY=k-123"}]}}),
        json!({"id": 5, "method": "thread/start", "params": {"cwd": "/p"}}),
        json!({"type": "user", "message": {"role": "user", "content": "hi"}}),
    ] {
        assert!(redacted(&plain).is_none(), "nothing to take out of {plain}");
    }
}

#[test]
fn a_server_changed_is_no_longer_taken_for_one_that_needs_signing_in_by_any_claude_home() {
    // Claude Code skips an HTTP server it found wanting a sign-in in the last 15 minutes, by its name alone: the
    // flag for the server as it was mustn't hide it as it is now. The homes share the user's file through a link.
    let home = temp_dir("mcp-needs-auth");
    let shared = home.join("dot-claude");
    std::fs::create_dir_all(&shared).unwrap();
    std::fs::write(shared.join("mcp-needs-auth-cache.json"), r#"{"paper": {"timestamp": 1}, "amie": {"timestamp": 2}}"#).unwrap();
    let homes = home.join("claude-homes");
    for (name, own) in [("a", false), ("b", false), ("c", true)] {
        std::fs::create_dir_all(homes.join(name)).unwrap();
        let file = homes.join(name).join("mcp-needs-auth-cache.json");
        if own {
            std::fs::write(&file, r#"{"paper": {"timestamp": 3}}"#).unwrap();
        } else {
            std::os::unix::fs::symlink(shared.join("mcp-needs-auth-cache.json"), &file).unwrap();
        }
    }
    std::fs::create_dir_all(homes.join("d")).unwrap();
    clear_needs_auth(&homes, "paper");
    let read = |path: std::path::PathBuf| -> serde_json::Value { serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap() };
    assert_eq!(read(shared.join("mcp-needs-auth-cache.json")), serde_json::json!({"amie": {"timestamp": 2}}), "the rest kept");
    assert_eq!(read(homes.join("c").join("mcp-needs-auth-cache.json")), serde_json::json!({}));
    assert!(
        std::fs::symlink_metadata(homes.join("a").join("mcp-needs-auth-cache.json")).unwrap().file_type().is_symlink(),
        "still the user's"
    );
    assert!(!homes.join("d").join("mcp-needs-auth-cache.json").exists(), "none made where there was none");
}

#[test]
fn a_tasks_own_remote_server_is_zeros_to_sign_in_to_only_when_its_plain_http_under_its_own_name() {
    let listed = |name: &str, scope: &str, config: serde_json::Value| serde_json::json!({"name": name, "status": "needs-auth", "scope": scope, "config": config});
    let http = serde_json::json!({"type": "http", "url": "https://amie.example/mcp"});
    let user = adoptable(&listed("amie", "user", http.clone()), "work").expect("the user's own");
    assert_eq!((user.name.as_str(), user.url.as_deref(), user.workspaces.len()), ("amie", Some("https://amie.example/mcp"), 0));
    assert_eq!(
        adoptable(&listed("linear-server", "local", http.clone()), "work").unwrap().workspaces,
        ["work"],
        "a project's: its workspace's alone"
    );
    let url = "https://amie.example/mcp";
    for (name, scope, config) in [
        ("amie", "user", serde_json::json!({"type": "sse", "url": url})),
        ("amie", "user", serde_json::json!({"type": "http", "url": url, "headers": {"Authorization": "Bearer x"}})),
        ("amie", "user", serde_json::json!({"type": "http", "url": url, "headersHelper": "get-token"})),
        ("amie", "user", serde_json::json!({"type": "http", "url": url, "oauth": {"clientId": "c"}})),
        ("amie", "user", serde_json::json!({"type": "stdio", "command": "amie"})),
        ("amie", "dynamic", http.clone()),
        ("amie", "claudeai", http.clone()),
        ("Amie", "user", http.clone()),
        ("my_server", "user", http.clone()),
    ] {
        assert!(adoptable(&listed(name, scope, config.clone()), "work").is_none(), "{name} {scope} {config}");
    }
}
