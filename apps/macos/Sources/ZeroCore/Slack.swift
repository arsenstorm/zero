import Foundation

/// The Slack workspaces Zero is connected to, as zerod keeps them (integrations.rs: a user token of Zero's own Slack app
/// each, made from the manifest below, in zerod's slack.json). Zero knows each team's id and its channels' ids, which is
/// what Slack's app opens by: "#channel" and Slack's own links in messages then open in Slack itself; and agents follow
/// their threads and channels (following.rs). This is the app's copy, kept in UserDefaults so links resolve before
/// zerod has answered.
@MainActor @Observable
public final class Slack {
    public struct Team: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var domain: String
    }

    /// One workspace, as zerod sends it in the integrations' state: its team, and its channels' ids by name.
    public struct State: Codable, Sendable, Equatable {
        public var team: Team
        public var channels: [String: String]
    }

    public static let shared = Slack()
    /// Every workspace connected, in the order connected.
    public private(set) var teams: [State]

    private static let key = "slackTeams"

    init() {
        teams = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([State].self, from: $0) } ?? []
    }

    /// Slack's page for creating Zero's app, its manifest filled in: a name and read-only scopes (channels and their
    /// names; history and people's names, for following threads).
    public nonisolated static var createAppURL: URL {
        let manifest: [String: Any] = [
            "display_information": ["name": "Zero", "description": "Lets Zero open channels and threads in Slack, and agents follow them.", "background_color": "#1d1c1d"],
            "oauth_config": ["scopes": ["user": ["channels:read", "groups:read", "channels:history", "groups:history", "users:read"]]],
            "settings": ["org_deploy_enabled": false, "socket_mode_enabled": false, "token_rotation_enabled": false],
        ]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return URL(string: "https://api.slack.com/apps?new_app=1&manifest_json=" + (json.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))!
    }

    /// What zerod says now.
    public func apply(_ teams: [State]) {
        self.teams = teams
        UserDefaults.standard.set(try? JSONEncoder().encode(teams), forKey: Self.key)
    }
}
