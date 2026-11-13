import Foundation

/// Claude Code's own MCP servers, as its config has them (`claude mcp add`'s user scope, and each project's local scope),
/// with whether Claude Code last found one needing a sign-in (its mcp-needs-auth-cache.json, which it clears once one
/// signs in). Read from its files alone: Zero never calls a server itself.
public enum ClaudeMcpServers {
    public struct Server: Identifiable, Equatable, Sendable {
        public var id: String { (project ?? "") + "/" + name }
        public let name: String
        /// Its URL, or its command and arguments.
        public let detail: String
        /// The project it's in, for one of a project's own; nil for the user's.
        public let project: String?
        public let needsSignIn: Bool
        /// It as one of Zero's (Manage in Zero): its name, how it runs, and its values' names, to be kept in the
        /// Keychain; `values` has what they are.
        public let zeros: ZerodLink.McpServer
        public let values: [String: String]
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
                let env = entry["env"] as? [String: String] ?? [:], headers = entry["headers"] as? [String: String] ?? [:]
                let named = { (values: [String: String]) in values.keys.sorted().map { ZerodLink.McpServer.Value(name: $0) } }
                let zeros = ZerodLink.McpServer(
                    name: name, command: entry["command"] as? String, args: entry["args"] as? [String] ?? [], url: entry["url"] as? String,
                    env: named(env), headers: named(headers))
                return Server(
                    name: name, detail: detail, project: project, needsSignIn: cache[name] != nil, zeros: zeros,
                    values: env.merging(headers) { a, _ in a })
            }
        }
        let projects = (state["projects"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
        return servers(state["mcpServers"], project: nil)
            + projects.flatMap { path, project in servers((project as? [String: Any])?["mcpServers"], project: path) }
    }
}
