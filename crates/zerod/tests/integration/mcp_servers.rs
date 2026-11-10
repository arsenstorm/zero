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
