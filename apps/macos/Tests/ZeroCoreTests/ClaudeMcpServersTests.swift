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

/// Manage in Zero: one of Claude Code's own servers as Zero's form starts it, under the same name (so the sign-in
/// Claude Code keeps for it is still its own), its values kept apart for the Keychain rather than in Zero's file.
@Test func aClaudeServerBecomesOneOfZerosWithItsValuesForTheKeychain() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let state: [String: Any] = [
        "mcpServers": [
            "paper": ["type": "stdio", "command": "paper", "args": ["mcp"], "env": ["PAPER_KEY": "k"]],
            "testing": ["type": "http", "url": "https://mcp.example.com", "headers": ["Authorization": "Bearer t"]],
        ]
    ]
    try JSONSerialization.data(withJSONObject: state).write(to: home.appendingPathComponent(".claude.json"))
    let servers = ClaudeMcpServers.list(home: home, config: home)
    let paper = try #require(servers.first { $0.name == "paper" })
    #expect(paper.zeros.name == "paper" && paper.zeros.command == "paper" && paper.zeros.args == ["mcp"] && paper.zeros.url == nil)
    #expect(paper.zeros.env.map(\.name) == ["PAPER_KEY"] && paper.zeros.env[0].from == .keychain && paper.zeros.env[0].value == nil)
    #expect(paper.values == ["PAPER_KEY": "k"])
    let testing = try #require(servers.first { $0.name == "testing" })
    #expect(testing.zeros.url == "https://mcp.example.com" && testing.zeros.command == nil)
    #expect(testing.zeros.headers.map(\.name) == ["Authorization"] && testing.values == ["Authorization": "Bearer t"])
}
