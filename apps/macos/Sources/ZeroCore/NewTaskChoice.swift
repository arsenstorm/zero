import Foundation

/// What New task was last set to run each CLI on, its model, effort and advisor: it opens with them for that CLI next
/// time. Nothing kept yet: Claude's Opus with Fable as its advisor, another CLI's first model; "" kept, the CLI's first
/// model at its own effort, with no advisor.
public enum NewTaskChoice {
    private static let key = "newTaskModels"

    public static func kept(for provider: Provider, in defaults: UserDefaults = .standard) -> (
        model: String, effort: String, advisor: String
    ) {
        guard let kept = defaults.dictionary(forKey: key)?[provider.rawValue] as? [String: String] else {
            return provider == .claude ? ("opus", "", "fable") : ("", "", "")
        }
        return (kept["model"] ?? "", kept["effort"] ?? "", kept["advisor"] ?? "")
    }

    public static func keep(
        _ provider: Provider, model: String, effort: String, advisor: String = "", in defaults: UserDefaults = .standard
    ) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[provider.rawValue] = ["model": model, "effort": effort, "advisor": advisor]
        defaults.set(all, forKey: key)
    }

    private static let permissionsKey = "newTaskPermissions"

    /// The permissions last picked for the CLI: Auto at first, or when what was kept isn't one Zero has any more.
    public static func permissions(for provider: Provider, in defaults: UserDefaults = .standard) -> Permissions {
        (defaults.dictionary(forKey: permissionsKey)?[provider.rawValue] as? String).flatMap(Permissions.init(rawValue:)) ?? .auto
    }

    public static func keep(_ provider: Provider, permissions: Permissions, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: permissionsKey) ?? [:]
        all[provider.rawValue] = permissions.rawValue
        defaults.set(all, forKey: permissionsKey)
    }
}
