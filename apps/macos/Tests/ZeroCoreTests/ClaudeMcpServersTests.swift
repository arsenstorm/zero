import Foundation
import Testing
@testable import ZeroCore

@Test func claudeCodesOwnServersAreReadFromItsConfigWithTheirSignInState() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-mcp-\(UUID().uuidString)")
    let config = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let state: [String: Any] = [
        "mcpServers": [
            "paper": ["type": "stdio", "command": "/Users/a/.paper/bin/paper", "args": ["mcp"]],
            "betterstack": ["type": "http", "url": "https://mcp.betterstack.com"],
        ],
        "projects": ["/work/app": ["mcpServers": ["linear": ["type": "http", "url": "https://mcp.linear.app/mcp"]]]],
    ]
    try JSONSerialization.data(withJSONObject: state).write(to: home.appendingPathComponent(".claude.json"))
    try Data(#"{"betterstack":{"timestamp":1794408954249}}"#.utf8).write(to: config.appendingPathComponent("mcp-needs-auth-cache.json"))

    let servers = ClaudeMcpServers.list(home: home, config: config)
    #expect(servers.map(\.name) == ["betterstack", "paper", "linear"], "the user's, by name, then each project's")
    #expect(servers[0].detail == "https://mcp.betterstack.com" && servers[0].needsSignIn && servers[0].project == nil)
    #expect(servers[1].detail == "/Users/a/.paper/bin/paper mcp" && !servers[1].needsSignIn)
    #expect(servers[2].project == "/work/app" && !servers[2].needsSignIn)
    #expect(ClaudeMcpServers.list(home: home.appendingPathComponent("none"), config: config).isEmpty)
}

/// "Manage in Zero": a CLI's local server becomes Zero's, same command, arguments and environment, started when
/// first used, its values in the Keychain or Zero's file; the CLI's own command takes it out of its config at the scope
/// it was in, and gives it back there.
@Test func aCliServerMovesIntoZeroAndBack() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let state: [String: Any] = [
        "mcpServers": [
            "icons": ["type": "stdio", "command": "npx", "args": ["-y", "icons-mcp"], "env": ["ICONS_KEY": "k1"]],
            "remote": ["type": "http", "url": "https://example.com/mcp"],
        ],
        "projects": ["/work/app": ["mcpServers": ["db": ["command": "db-mcp", "args": []]]]],
    ]
    try JSONSerialization.data(withJSONObject: state).write(to: home.appendingPathComponent(".claude.json"))
    let servers = ClaudeMcpServers.list(home: home, config: home)
    let icons = try #require(servers.first { $0.name == "icons" })
    let db = try #require(servers.first { $0.name == "db" })
    #expect(icons.movable && db.movable && !(servers.first { $0.name == "remote" }?.movable ?? true))
    #expect(icons.command == "npx" && icons.args == ["-y", "icons-mcp"] && icons.env == ["ICONS_KEY": "k1"])

    let (kept, secrets) = McpHandOver.server(for: icons, inFile: false)
    #expect(kept.name == "icons" && kept.command == "npx" && kept.args == ["-y", "icons-mcp"] && kept.lazy && kept.workspaces.isEmpty)
    #expect(kept.env == [.init(name: "ICONS_KEY", value: nil, from: .keychain)] && secrets == ["ICONS_KEY": "k1"])
    let (inFile, none) = McpHandOver.server(for: icons, inFile: true)
    #expect(inFile.env == [.init(name: "ICONS_KEY", value: "k1", from: .file)] && none.isEmpty)

    #expect(McpHandOver.removal(icons) == (["claude", "mcp", "remove", "icons", "-s", "user"], nil))
    #expect(McpHandOver.removal(db) == (["claude", "mcp", "remove", "db", "-s", "local"], "/work/app"))
    let back = McpHandOver.giveBack(kept, values: ["ICONS_KEY": "k1"], to: .init(cli: .claude, project: nil))
    #expect(back.argv[0..<4] == ["claude", "mcp", "add-json", "icons"] && back.argv.suffix(2) == ["-s", "user"])
    let json = try JSONSerialization.jsonObject(with: Data(back.argv[4].utf8)) as? [String: Any]
    #expect(json?["command"] as? String == "npx" && json?["args"] as? [String] == ["-y", "icons-mcp"])
    #expect(json?["env"] as? [String: String] == ["ICONS_KEY": "k1"] && json?["type"] as? String == "stdio")
    #expect(McpHandOver.giveBack(kept, values: [:], to: .init(cli: .claude, project: "/work/app")).cwd == "/work/app")
}

/// Codex's: those in its config.toml (not its plugins'), movable when Zero's list can say all of it.
@Test func codexsOwnServersComeFromItsConfigAndGoBackThroughIt() throws {
    let config = """
        model = "x"
        [mcp_servers.solo]
        command = "solo"
        [mcp_servers."node repl"]
        command = "node"
        [mcp_servers."node repl".env]
        A = "1"
        [mcp_servers.web]
        url = "https://example.com/mcp"
        """
    let listed = """
        [{"name":"plugin","transport":{"type":"stdio","command":"p","args":[],"env":null,"env_vars":[],"cwd":"/x"}},
         {"name":"solo","transport":{"type":"stdio","command":"solo","args":["mcp"],"env":{"K":"v"},"env_vars":[],"cwd":null}},
         {"name":"node repl","transport":{"type":"stdio","command":"node","args":[],"env":{"A":"1"},"env_vars":["PATH"],"cwd":null}},
         {"name":"web","transport":{"type":"streamable_http","url":"https://example.com/mcp"}}]
        """
    let servers = CodexMcpServers.parse(Data(listed.utf8), config: config)
    #expect(servers.map(\.name) == ["node repl", "solo", "web"])
    #expect(servers.map(\.movable) == [false, true, false], "variables passed through, or a URL, aren't Zero's to say")
    let solo = servers[1]
    #expect(solo.cli == .codex && solo.detail == "solo mcp" && solo.env == ["K": "v"])
    #expect(McpHandOver.removal(solo) == (["codex", "mcp", "remove", "solo"], nil))
    let (kept, _) = McpHandOver.server(for: solo, inFile: true)
    #expect(
        McpHandOver.giveBack(kept, values: ["K": "v"], to: .init(cli: .codex, project: nil)).argv
            == ["codex", "mcp", "add", "solo", "--env", "K=v", "--", "solo", "mcp"])
}
