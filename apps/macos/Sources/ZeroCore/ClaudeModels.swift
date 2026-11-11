import Foundation

/// The models Claude Code offers, as its own picker does, with no call to Anthropic: Zero never calls a provider's
/// service itself, nor uses a sign-in for anything but handing it to its CLI. Claude Code's aliases for the latest of
/// each family (`claude --help`: "an alias for the latest model (e.g. 'fable', 'opus', or 'sonnet')"), which it
/// resolves itself, so nothing here goes stale; then the options Claude Code caches for the signed-in account in
/// ~/.claude.json (the `[1m]` variants and anything else it was offered), with their own names and descriptions.
public enum ClaudeModels {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Claude Code's aliases, most capable first.
    static let aliases = ["fable", "opus", "sonnet", "haiku"]

    public static func cached() -> [SpawnChoice] { choices(used: used(), typed: used(in: .standard, typed: true), extras: localExtras()) }

    /// Each family's alias, named by the newest version of it a task has run ("Opus 5.5"; the family alone until one
    /// has); Claude Code's cached extras; then every version run or typed, newest first, each staying on that version
    /// (the one an alias runs now not listed twice, unless typed). Only what tasks ran names a family: a typed name
    /// says nothing of what the alias runs.
    static func choices(used: [String], typed: [String] = [], extras: [SpawnChoice]) -> [SpawnChoice] {
        let full = { (id: String) in id.hasSuffix("[1m]") ? String(id.dropLast(4)) : id }
        var current: [String: String] = [:]
        var choices = aliases.map { family -> SpawnChoice in
            let newest = used.map(full).filter { $0.contains(family) }.min { rank(ModelNames.readable($0)) < rank(ModelNames.readable($1)) }
            if let newest { current[family] = newest }
            let follows = "Follows the latest \(family.capitalized)."
            return SpawnChoice(
                id: family, name: newest.map(ModelNames.readable) ?? family.capitalized,
                detail: describe(family).map { $0 + " " + follows } ?? follows, icon: "claude", provider: "Anthropic", levels: levels,
                defaultLevel: "high")
        }
        for extra in extras where !choices.contains(where: { $0.id == extra.id }) { choices.append(extra) }
        let ran = used.filter { !current.values.contains($0) }
        let pinned = (ran + typed.filter { !ran.contains($0) }).filter { id in !choices.contains { $0.id == id } }
            .sorted { rank(ModelNames.readable($0)) < rank(ModelNames.readable($1)) }
        for id in pinned {
            let long = id.hasSuffix("[1m]")
            choices.append(
                SpawnChoice(
                    id: id, name: ModelNames.readable(id), detail: "Stays on this version · \(id)", icon: "claude", provider: "Anthropic",
                    context: long ? "1M tokens" : nil, levels: levels, defaultLevel: "high"))
        }
        return choices
    }

    /// The row a task running `id` is on: the one with that id (a version picked or typed), else an alias named by that
    /// version ("Opus 5.5" for claude-opus-5-5: started on the alias, it runs what the alias runs now).
    public static func row(for id: String, in choices: [SpawnChoice]) -> String {
        if choices.contains(where: { $0.id == id }) { return id }
        let name = ModelNames.readable(id)
        return choices.first { !$0.id.hasPrefix("claude-") && $0.name == name }?.id ?? id
    }

    /// Full model ids Claude Code has run (zerod's `model` for a task, once Claude reports it) or the user typed in the
    /// picker: kept on this Mac, so a version stays pickable after its tasks are gone.
    private static let usedKey = "claudeModelsUsed"
    private static let usedLock = NSLock()
    nonisolated(unsafe) private static var known: Set<String>?

    public static func used(in defaults: UserDefaults = .standard, typed: Bool = false) -> [String] {
        defaults.stringArray(forKey: typed ? typedKey : usedKey) ?? []
    }
    private static let typedKey = "claudeModelsTyped"

    /// A model to list from now on: a task's resolved model, or (`typed`) one typed in the picker. Claude Code's aliases
    /// are already rows of their own.
    public static func remember(_ id: String, typed: Bool = false, in defaults: UserDefaults = .standard) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !aliases.contains(id.lowercased()) else { return }
        usedLock.lock(); defer { usedLock.unlock() }
        // Asked of every task's every change: an id already known costs a set lookup, no read or write.
        let cached = defaults == .standard && !typed
        if cached, known?.contains(id) == true { return }
        var list = used(in: defaults, typed: typed)
        if !list.contains(id) { list.append(id); defaults.set(list, forKey: typed ? typedKey : usedKey) }
        if cached { known = Set(list) }
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

    /// Claude Code's config, parsed again only once the file has changed: it's large (100 KB and more), and the control
    /// bar's every redraw named its tasks' models through it, a parse or two a dot.
    private static func claudeConfig() -> [String: Any]? {
        let url = home.appendingPathComponent(".claude.json")
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        configLock.lock(); defer { configLock.unlock() }
        if let parsed, parsed.stamp == stamp { return parsed.json }
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        parsed = (stamp, json)
        return json
    }
    private static let configLock = NSLock()
    nonisolated(unsafe) private static var parsed: (stamp: Date, json: [String: Any])?

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
            return SpawnChoice(
                id: value, name: shortName(title) + (long ? " (1M)" : ""), detail: detail, icon: "claude",
                provider: "Anthropic", context: long ? "1M tokens" : nil, levels: levels, defaultLevel: "high")
        }
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
