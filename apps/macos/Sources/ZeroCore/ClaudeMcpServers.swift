import Foundation

/// Claude Code's own MCP servers, as its config has them (`claude mcp add`'s user scope, and each project's local scope),
/// with whether Claude Code last found one needing a sign-in (its mcp-needs-auth-cache.json, which it clears once one
/// signs in). Read from its files alone: Zero never calls a server itself.
public enum ClaudeMcpServers {
    /// The CLI whose config it's in.
    public enum Cli: String, Codable, Sendable {
        case claude, codex
        public var title: String { self == .claude ? "Claude Code" : "Codex" }
    }

    public struct Server: Identifiable, Equatable, Sendable {
        public var id: String { cli.rawValue + ":" + (project ?? "") + "/" + name }
        public let name: String
        /// Its URL, or its command and arguments.
        public let detail: String
        /// The project it's in, for one of a project's own; nil for the user's.
        public let project: String?
        public let needsSignIn: Bool
        public var cli = Cli.claude
        /// A local server's command, arguments and environment (values held only to hand them to Zero: never shown).
        public var command: String?
        public var args: [String] = []
        public var env: [String: String] = [:]
        /// Whether Zero can take it over as it is: a local server with nothing Zero's list can't say (a folder of
        /// its own, variables passed through from the CLI's environment).
        public var movable = false
    }

    public static func list(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        config: URL = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    ) -> [Server] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
            let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let cache =
            (try? Data(contentsOf: config.appendingPathComponent("mcp-needs-auth-cache.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func servers(_ entries: Any?, project: String?) -> [Server] {
            ((entries as? [String: Any]) ?? [:]).sorted { $0.key < $1.key }.map { name, value in
                let entry = value as? [String: Any] ?? [:]
                let detail =
                    (entry["url"] as? String)
                    ?? ([entry["command"] as? String ?? ""] + (entry["args"] as? [String] ?? [])).joined(separator: " ")
                let command = entry["command"] as? String
                return Server(
                    name: name, detail: detail, project: project, needsSignIn: cache[name] != nil, command: command,
                    args: entry["args"] as? [String] ?? [], env: entry["env"] as? [String: String] ?? [:],
                    movable: command != nil && entry["url"] == nil)
            }
        }
        let projects = (state["projects"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
        return servers(state["mcpServers"], project: nil)
            + projects.flatMap { path, project in servers((project as? [String: Any])?["mcpServers"], project: path) }
    }
}
