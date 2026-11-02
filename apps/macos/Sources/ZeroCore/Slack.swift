import Foundation

/// The Slack workspace Zero is connected to, as zerod keeps it (integrations.rs: a user token of Zero's own Slack app,
/// made from the manifest below, in zerod's slack.json). Zero knows the team's id and its channels' ids, which is what
/// Slack's app opens by: "#channel" and Slack's own links in messages then open in Slack itself; and agents follow its
/// threads and channels (following.rs). This is the app's copy, kept in UserDefaults so links resolve before zerod
/// has answered.
@MainActor @Observable
public final class Slack {
    public struct Team: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var domain: String
    }

    /// As zerod sends it in the integrations' state.
    public struct State: Codable, Sendable, Equatable {
        public var team: Team
        public var channels: [String: String]
    }

    public static let shared = Slack()
    public private(set) var team: Team?
    /// Channel ids by name.
    public private(set) var channels: [String: String]

    private static let legacyService = "Zero Slack"
    private static let teamKey = "slackTeamInfo"
    private static let channelsKey = "slackChannels"

    init() {
        team = UserDefaults.standard.data(forKey: Self.teamKey).flatMap { try? JSONDecoder().decode(Team.self, from: $0) }
        channels = UserDefaults.standard.dictionary(forKey: Self.channelsKey) as? [String: String] ?? [:]
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
    public func apply(_ state: State?) {
        team = state?.team
        channels = state?.channels ?? [:]
        UserDefaults.standard.set(state.flatMap { try? JSONEncoder().encode($0.team) }, forKey: Self.teamKey)
        UserDefaults.standard.set(state?.channels, forKey: Self.channelsKey)
    }

    /// The token the app itself kept before zerod held the connection (Zero before 2026-10-31): handed to zerod once,
    /// then forgotten here.
    #if os(macOS)
    public func legacyToken() -> String? { Keychain.loadString(service: Self.legacyService, account: "token") }
    public func forgetLegacyToken() { Keychain.saveString(nil, service: Self.legacyService, account: "token") }
    #endif
}
