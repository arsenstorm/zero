import Foundation

/// What New task was last set to run each CLI on, its model and effort: it opens with them for that CLI next time.
/// Nothing kept yet (or "" kept), the CLI's first model at its own effort.
public enum NewTaskChoice {
    private static let key = "newTaskModels"

    public static func kept(for provider: Provider, in defaults: UserDefaults = .standard) -> (model: String, effort: String) {
        let kept = defaults.dictionary(forKey: key)?[provider.rawValue] as? [String: String] ?? [:]
        return (kept["model"] ?? "", kept["effort"] ?? "")
    }

    public static func keep(_ provider: Provider, model: String, effort: String, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[provider.rawValue] = ["model": model, "effort": effort]
        defaults.set(all, forKey: key)
    }
}
