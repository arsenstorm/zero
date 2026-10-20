import Foundation
import Security

/// The models the active Claude Code account can use, from Anthropic's models endpoint, asked with Claude Code's
/// own sign-in (its Keychain credential; macOS asks once before Zero may read it). Cached per account, so an
/// account switch shows its list at once and refreshes in the background. Claude Code's local option cache
/// (the `[1m]` variants and anything else the account was offered) is merged in.
public enum ClaudeModels {
    public struct Status: Sendable { public let source: String; public let error: String? }
    public private(set) static var status = Status(source: "not loaded", error: nil)

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The account Claude Code is signed in as, from its config; nil when signed out.
    public static func accountID() -> String? {
        guard let json = claudeConfig(), let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["accountUuid"] as? String
    }

    /// What we know right now, without touching the network.
    /// True once the models endpoint has answered for the signed-in account.
    public static var hasCache: Bool { accountID().flatMap { UserDefaults.standard.data(forKey: "claudeModels." + $0) } != nil }

    public static func cached() -> [SpawnChoice] {
        let fromAPI = (accountID().flatMap { UserDefaults.standard.data(forKey: "claudeModels." + $0) })
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        var choices = fromAPI.map { SpawnChoice(id: $0.id, name: shortName($0.name), detail: describe($0.id), icon: "claude", provider: "Anthropic",
                                                levels: levels, defaultLevel: "high") }
        for extra in localExtras() where !choices.contains(where: { $0.id == extra.id }) { choices.append(extra) }
        return choices.sorted { rank($0.name) < rank($1.name) }
    }

    /// Claude Code's `--effort` levels; it defaults to high.
    static let levels = ["low", "medium", "high", "xhigh", "max"].map { SpawnChoice(id: $0, name: $0) }

    /// Newest version first; within one, Mythos, Fable, Opus, Sonnet, Haiku, then the rest.
    static func rank(_ name: String) -> (Double, Int, String) {
        let families = ["mythos", "fable", "opus", "sonnet", "haiku"]
        let lower = name.lowercased()
        let family = families.firstIndex { lower.contains($0) } ?? families.count
        let version = Double(lower.split(separator: " ").first { Double($0) != nil } ?? "") ?? 0
        return (-version, family, name)
    }

    /// Fetches the account's models and caches them. Returns true when the list changed.
    @discardableResult
    public static func refresh() async -> Bool {
        guard let account = accountID() else { status = Status(source: "Claude Code is signed out", error: nil); return false }
        guard let token = accessToken() else {
            status = Status(source: "Claude Code's local cache", error: "Zero was not allowed to read Claude Code's sign-in from the Keychain")
            return false
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let body = String(decoding: data.prefix(200), as: UTF8.self)
                status = Status(source: "Claude Code's local cache", error: "models endpoint answered \(code): \(body)")
                return false
            }
            let list = try JSONDecoder().decode(Listing.self, from: data)
            let entries = list.data
                .filter { $0.id.hasPrefix("claude-") }
                .sorted { ($0.created_at ?? "") > ($1.created_at ?? "") }
                .map { Entry(id: $0.id, name: $0.display_name ?? $0.id) }
            let encoded = try JSONEncoder().encode(entries)
            let changed = UserDefaults.standard.data(forKey: "claudeModels." + account) != encoded
            UserDefaults.standard.set(encoded, forKey: "claudeModels." + account)
            status = Status(source: "Anthropic models endpoint for this account", error: nil)
            return changed
        } catch {
            status = Status(source: "Claude Code's local cache", error: error.localizedDescription)
            return false
        }
    }

    // MARK: - Pieces

    private struct Listing: Decodable { let data: [Model] }
    private struct Model: Decodable { let id: String; let display_name: String?; let created_at: String? }
    private struct Entry: Codable { let id: String; let name: String }

    private static func claudeConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Claude Code's cached picker extras for the account, with their own descriptions.
    private static func localExtras() -> [SpawnChoice] {
        guard let extra = claudeConfig()?["additionalModelOptionsCache"] as? [[String: Any]] else { return [] }
        return extra.compactMap { option in
            guard let value = option["value"] as? String else { return nil }
            let label = (option["label"] as? String) ?? value
            let description = (option["description"] as? String) ?? ""
            let parts = description.components(separatedBy: " · ")
            let title = parts.first.map { $0.hasPrefix(label) ? $0 : label } ?? label
            let detail = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : (description.isEmpty ? nil : description)
            // The 1M-context variant shares its name with the base model; say so in the row, not a badge.
            let long = value.hasSuffix("[1m]")
            return SpawnChoice(id: value, name: shortName(title) + (long ? " (1M)" : ""), detail: detail, icon: "claude",
                               provider: "Anthropic", context: long ? "1M tokens" : nil, levels: levels, defaultLevel: "high")
        }
    }

    /// Claude Code's sign-in, as Claude Code stores it. Returns nil when the item is missing or access is refused.
    private static func accessToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Claude Code-credentials",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    /// "Claude Haiku 5.5" reads "Haiku 5.5": the provider is the tab, so the name need not repeat it.
    private static func shortName(_ name: String) -> String {
        name.hasPrefix("Claude ") ? String(name.dropFirst(7)) : name
    }

    /// One line per family, so a bare id still reads like Codex's rows do.
    private static func describe(_ id: String) -> String? {
        if id.contains("mythos") { return "The most capable Claude, without Fable's dual-use safeguards." }
        if id.contains("fable") { return "Most capable for your hardest and longest-running tasks." }
        if id.contains("opus") { return "Strong reasoning for complex, multi-step work." }
        if id.contains("sonnet") { return "Balanced speed and capability for everyday coding." }
        if id.contains("haiku") { return "Fastest and cheapest, for simple tasks." }
        return nil
    }
}
