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
