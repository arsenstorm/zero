import Foundation

/// The models Claude Code offers, as its own `/model` picker does, with no call to Anthropic: Zero never calls a
/// provider's service itself, nor uses a sign-in for anything but handing it to its CLI. zerod asks Claude Code itself
/// (`initialize`, as the account new tasks start as) and the list is kept here (`listed`); until it's in, Claude
/// Code's aliases for the latest of each family (`claude --help`: "an alias for the latest model"), which it resolves
/// itself. Then the options Claude Code caches for the signed-in account in ~/.claude.json (the `[1m]` variants), and
/// every version a task ran or the user typed.
public enum ClaudeModels {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Claude Code's aliases, most capable first.
    static let aliases = ["fable", "opus", "sonnet", "haiku"]

    public static func cached() -> [SpawnChoice] {
        choices(used: used(), typed: used(in: .standard, typed: true), extras: localExtras(), listed: listed())
    }

    /// A model as Claude Code's `initialize` lists it.
    struct Listed: Codable, Equatable {
        var value: String
        var resolvedModel: String?
        var displayName: String?
        var description: String?
        var supportedEffortLevels: [String]?
    }

    private static let listedKey = "claudeModelsListed"
    static func listed(in defaults: UserDefaults = .standard) -> [Listed] {
        defaults.data(forKey: listedKey).flatMap { try? JSONDecoder().decode([Listed].self, from: $0) } ?? []
    }

    /// Claude Code's list asked of zerod again, at most every ten minutes (zerod keeps it an hour), sooner after a
    /// failed ask (zerod not up yet): the picker shows it from its next opening.
    public static func refresh() {
        refreshLock.lock(); defer { refreshLock.unlock() }
        guard asked.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        asked = Date()
        Task.detached {
            guard let link = try? ZerodLink(), let list = try? await link.call("claudeModels") as? [[String: Any]], !list.isEmpty,
                let data = try? JSONSerialization.data(withJSONObject: list)
            else {
                refreshLock.withLock { asked = nil }
                return
            }
            UserDefaults.standard.set(data, forKey: listedKey)
        }
    }
    private static let refreshLock = NSLock()
    nonisolated(unsafe) private static var asked: Date?

    /// Claude Code's own list when it's in: its aliases in its order (the one its default runs marked), Claude Code's
    /// cached extras, then every version it lists, ran or was typed, newest first. Before it's in: each family's alias,
    /// named by the newest version of it a task has run ("Opus 5.5"; the family alone until one has), the extras, then
    /// the versions run or typed. The version an alias runs now isn't listed twice, unless typed. Only what tasks ran
    /// names a family: a typed name says nothing of what the alias runs.
    static func choices(used: [String], typed: [String] = [], extras: [SpawnChoice], listed: [Listed] = []) -> [SpawnChoice] {
        let full = { (id: String) in id.hasSuffix("[1m]") ? String(id.dropLast(4)) : id }
        var current: [String: String] = [:]
        var choices: [SpawnChoice]
        var offered: [String: Listed] = [:]
        let named = listed.filter { aliases.contains($0.value) }
        if !named.isEmpty {
            // Claude Code's default ("default", resolved to a version): the first alias that runs it says so.
            let fallback = listed.first { $0.value == "default" }?.resolvedModel
            let marked = named.first { $0.resolvedModel != nil && $0.resolvedModel == fallback }?.value
            choices = named.map { model in
                if let resolved = model.resolvedModel { current[model.value] = resolved }
                let parts = [
                    model.value == marked ? "Claude Code's default." : nil,
                    model.description.flatMap { $0.isEmpty ? nil : $0.hasSuffix(".") ? $0 : $0 + "." },
                    "Follows the latest \(model.value.capitalized).",
                ]
                return listedRow(
                    model, name: model.displayName ?? model.value.capitalized, detail: parts.compactMap { $0 }.joined(separator: " "))
            }
            for model in listed where model.value.hasPrefix("claude-") { offered[model.value] = model }
        } else {
            choices = aliases.map { family -> SpawnChoice in
                let newest = used.map(full).filter { $0.contains(family) }.min {
                    rank(ModelNames.readable($0)) < rank(ModelNames.readable($1))
                }
                if let newest { current[family] = newest }
                let follows = "Follows the latest \(family.capitalized)."
                return SpawnChoice(
                    id: family, name: newest.map(ModelNames.readable) ?? family.capitalized,
                    detail: describe(family).map { $0 + " " + follows } ?? follows, icon: "claude", provider: "Anthropic", levels: levels,
                    defaultLevel: "high")
            }
        }
        for extra in extras where !choices.contains(where: { $0.id == extra.id }) { choices.append(extra) }
        let ran = (Array(offered.keys) + used).filter { !current.values.contains($0) }
        let pinned = Set(ran + typed).filter { id in !choices.contains { $0.id == id } }
            .sorted { a, b in
                let (x, y) = (
                    rank(offered[a]?.displayName ?? ModelNames.readable(a)), rank(offered[b]?.displayName ?? ModelNames.readable(b))
                )
                return (x.0, x.1, x.2, a) < (y.0, y.1, y.2, b)
            }
        for id in pinned {
            if let model = offered[id] {
                let said = model.description.flatMap { $0.isEmpty ? nil : $0 } ?? describe(id)
                let detail = [said, id].compactMap { $0 }.joined(separator: " · ")
                choices.append(listedRow(model, name: model.displayName ?? ModelNames.readable(id), detail: detail))
                continue
            }
            let long = id.hasSuffix("[1m]")
            choices.append(
                SpawnChoice(
                    id: id, name: ModelNames.readable(id), detail: "Stays on this version · \(id)", icon: "claude", provider: "Anthropic",
                    context: long ? "1M tokens" : nil, levels: levels, defaultLevel: "high"))
        }
        return choices
    }

    /// A model Claude Code listed, with the effort levels it says it takes (none for one without effort, Haiku 4.5's).
    private static func listedRow(_ model: Listed, name: String, detail: String) -> SpawnChoice {
        let efforts = model.supportedEffortLevels ?? []
        return SpawnChoice(
            id: model.value, name: name, detail: detail, icon: "claude", provider: "Anthropic",
            levels: efforts.map { SpawnChoice(id: $0, name: $0) }, defaultLevel: efforts.contains("high") ? "high" : nil)
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
