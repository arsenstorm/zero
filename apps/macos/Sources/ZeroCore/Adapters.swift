import Foundation

/// Something an adapter can start an agent in (a project), with (a runtime), or as (a model): a name for the
/// chip, a detail line for the picker, and an icon resource name the app may know.
public struct SpawnChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String?
    public let icon: String?
    /// Who provides it ("Anthropic", "OpenAI"): the small line under a name in the picker.
    public let provider: String?
    /// For a model: its context window as text, and the reasoning levels it can be started at.
    public let context: String?
    public let levels: [SpawnChoice]
    public let defaultLevel: String?
    public init(
        id: String, name: String, detail: String? = nil, icon: String? = nil, provider: String? = nil,
        context: String? = nil, levels: [SpawnChoice] = [], defaultLevel: String? = nil
    ) {
        self.id = id; self.name = name; self.detail = detail; self.icon = icon; self.provider = provider
        self.context = context; self.levels = levels; self.defaultLevel = defaultLevel
    }
}

/// A way to deliver the user's words into an agent's session, and optionally to start a new one: zerod's sessions,
/// Zero's own terminals.
public protocol AgentAdapter: Sendable {
    var name: String { get }
    func canReach(_ agent: AgentIdentity) -> Bool
    func send(_ text: String, to agent: AgentIdentity) async throws
    /// What the agent said back to `text`, once it has finished its turn; nil when the adapter cannot tell.
    func reply(from agent: AgentIdentity, to text: String) async -> String?
    /// What the runtime calls the agent now, when that is more than the tool's generic name.
    func displayName(for agent: AgentIdentity) async -> String?
    /// The runtime's session id for an agent that was just given `firstPrompt`, once it exists.
    func session(for agent: AgentIdentity, firstPrompt: String) async -> String?
    /// The same, looked up once without waiting for it to appear.
    func findSession(for agent: AgentIdentity, firstPrompt: String) async -> String?
    /// The agent's rendered screen, for slash commands whose pickers live in its terminal.
    func screen(of agent: AgentIdentity) async -> String?
    /// Raw keys into the agent's terminal (arrows, Enter, Esc, a digit); returns the screen just after.
    func press(_ bytes: [UInt8], on agent: AgentIdentity) async throws -> String?
    /// Changes the model (and effort) of a running agent, where its runtime has a command for that.
    /// Either may be nil: only what changed is sent.
    func switchModel(of agent: AgentIdentity, to model: SpawnChoice?, level: String?) async throws
    /// Names of the given agents whose session is not running right now.
    func offline(among agents: [AgentIdentity]) async -> Set<String>
    /// Of `agents`, those whose process is gone from the runtime altogether (closed, not just stopped).
    func gone(among agents: [AgentIdentity]) async -> Set<String>
    /// Stops the agent's process, keeping its session so a message can resume it.
    func stop(_ agent: AgentIdentity) async
    /// The identity to deliver to now: the agent's session running somewhere, started again if it is not
    /// (with its conversation when the runtime can resume one). Its process may differ from the one passed in.
    func connect(_ agent: AgentIdentity) async throws -> AgentIdentity
    /// Starting agents: where they can run, what runs them, and the start itself. Default: not supported.
    var canSpawn: Bool { get }
    func spawnTargets() async throws -> [SpawnChoice]
    func spawnRuntimes() async throws -> [SpawnChoice]
    /// Models the runtime can be started with; empty means the runtime's default only.
    func spawnModels(for runtime: SpawnChoice) -> [SpawnChoice]
    /// One line of context for the start, such as the account the runtime will use.
    func spawnNote(for runtime: SpawnChoice) -> String?
    /// Refreshes anything the model lists come from; returns true when a list changed.
    func refreshModels() async -> Bool
    /// `settings`: per-model configuration the user picked, such as ["reasoning": "high"].
    func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws
        -> AgentIdentity
}

extension AgentAdapter {
    /// Typing into a half-written prompt would join the user's words and Zero's into one message: waits for an
    /// empty input, for up to 45 s, then gives up so the delivery shows as failed and can be retried.
    func waitForEmptyInput(of agent: AgentIdentity) async throws {
        for attempt in 0..<23 {
            guard let screen = await screen(of: agent), let draft = ClaudeScreen.draft(in: screen), !draft.isEmpty else { break }
            if attempt == 22 { throw AdapterError("\(agent.label ?? agent.name)'s terminal has a half-typed prompt") }
            try await Task.sleep(for: .seconds(2))
        }
    }
}

public extension AgentAdapter {
    func reply(from agent: AgentIdentity, to text: String) async -> String? { nil }
    func displayName(for agent: AgentIdentity) async -> String? { nil }
    func session(for agent: AgentIdentity, firstPrompt: String) async -> String? { nil }
    func findSession(for agent: AgentIdentity, firstPrompt: String) async -> String? { nil }
    func screen(of agent: AgentIdentity) async -> String? { nil }
    func press(_ bytes: [UInt8], on agent: AgentIdentity) async throws -> String? { nil }
    func switchModel(of agent: AgentIdentity, to model: SpawnChoice?, level: String?) async throws {
        throw AdapterError("\(name) cannot change \(agent.name)'s model")
    }
    func offline(among agents: [AgentIdentity]) async -> Set<String> { [] }
    func gone(among agents: [AgentIdentity]) async -> Set<String> { [] }
    func stop(_ agent: AgentIdentity) async {}
    func connect(_ agent: AgentIdentity) async throws -> AgentIdentity { agent }
    var canSpawn: Bool { false }
    func spawnTargets() async throws -> [SpawnChoice] { [] }
    func spawnRuntimes() async throws -> [SpawnChoice] { [] }
    func spawnModels(for runtime: SpawnChoice) -> [SpawnChoice] { [] }
    func spawnNote(for runtime: SpawnChoice) -> String? { nil }
    func refreshModels() async -> Bool { false }
    func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws
        -> AgentIdentity
    {
        throw AdapterError("\(name) cannot start agents")
    }
}

public struct AdapterError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// Claude Code's rendered screen, as Zero reads it in an agent's terminal.
enum ClaudeScreen {
    /// What sits in Claude Code's input box on a rendered screen: the "❯" line between its two rules. nil when
    /// no input box is in view; empty when the box is empty or shows only its placeholder hint.
    static func draft(in screen: String) -> String? {
        let lines = screen.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }),
            index > 0, lines[index - 1].contains("────")
        else { return nil }
        let text = lines[index].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("Try \"") ? "" : text
    }

    /// The agent's last spoken block on a rendered Claude Code or Codex screen, after the echo of `prompt`:
    /// a block starts at a "⏺"/"●" line, tool calls (followed by "⎿", or named like `Bash(`) are skipped, and the
    /// turn ends at the "· done" line or the next prompt. ponytail: screen scraping; a terminal has no message API.
    static func lastReply(in screen: String, after prompt: String) -> String? {
        // Zero's ending line ("[zero: done]") is for the stop check, not for the user.
        let lines = screen.components(separatedBy: "\n")
            .filter { $0.range(of: #"^\s*(⏺|●)?\s*\[zero: [a-z]+( [A-Za-z0-9]+)?\]\s*$"#, options: .regularExpression) == nil }
        let needle = String(prompt.prefix(40))
        var start = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The echo is the prompt glyph followed by our text; a later prompt that merely contains it is not.
            if let first = trimmed.first, "❯〉›>".contains(first),
                trimmed.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix(needle)
            {
                start = index + 1
            }
        }
        guard start > 0 else { return nil } // no echo of our message yet: nothing after it can be the reply
        var blocks: [[String]] = []
        var current: [String]?
        for line in lines[start...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("· done") || "❯〉›─".contains(trimmed.first ?? " ") { break }
            if trimmed.hasPrefix("⏺") || trimmed.hasPrefix("●") {
                if let block = current { blocks.append(block) }
                current = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
            } else if trimmed.hasPrefix("⎿") {
                current = nil // the block above was a tool call
            } else if current != nil {
                current?.append(line.hasPrefix("  ") ? String(line.dropFirst(2)) : line)
            }
        }
        if let block = current { blocks.append(block) }
        let spoken = blocks.filter { block in
            guard let first = block.first else { return false }
            return first.range(of: "^[A-Z][A-Za-z]*\\(", options: .regularExpression) == nil
        }
        guard let last = spoken.last else { return nil }
        let text = last.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.isEmpty ? nil : text
    }
}

/// The models a new or running agent can be started with or switched to, and the account it will run as.
public enum AgentModels {
    /// Nothing to fetch: Claude's list is Claude Code's own (ClaudeModels), read locally each time.
    public static func refresh() async -> Bool { false }

    /// Claude Code takes `--model`. The choices are what its own picker offers the active account: the built-in
    /// aliases, plus the account-specific options Claude Code caches in ~/.claude.json after use. A model an
    /// account gained (Mythos, say) shows up here once that account has been used in Claude Code.
    /// Codex's ids are not known here, so it offers none.
    public static func spawnModels(for runtime: SpawnChoice) -> [SpawnChoice] {
        let name = runtime.name.lowercased()
        if name.contains("claude") { return claudeModels() }
        if name.contains("codex") { return codexModels() }
        return []
    }

    /// Claude Code's picker for the active account: the built-in aliases, then the account's cached options with
    /// their own descriptions ("Fable 5.1 · Most capable…"), whose first part names the model precisely.
    /// Claude's list is Claude Code's aliases and its local option cache (see ClaudeModels): never a call to Anthropic.
    private static func claudeModels() -> [SpawnChoice] { ClaudeModels.cached() }

    /// Codex's own catalogue for the signed-in account, from its cache: listed models in its order.
    private static func codexModels() -> [SpawnChoice] {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: cache), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else { return [] }
        return
            models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { (($0["priority"] as? Int) ?? 99) < (($1["priority"] as? Int) ?? 99) }
            .compactMap { model in
                guard let slug = model["slug"] as? String else { return nil }
                let raw = (model["display_name"] as? String) ?? slug
                let window = (model["context_window"] as? Int).map {
                    $0 >= 1_000_000 ? "\($0 / 1_000_000)M tokens" : "\($0 / 1000)K tokens"
                }
                let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { level -> SpawnChoice? in
                    guard let effort = level["effort"] as? String else { return nil }
                    return SpawnChoice(id: effort, name: effort.capitalized, detail: level["description"] as? String)
                }
                return SpawnChoice(
                    id: slug, name: codexDisplayName(raw), detail: model["description"] as? String,
                    icon: "openai", provider: "OpenAI", context: window, levels: levels,
                    defaultLevel: model["default_reasoning_level"] as? String)
            }
    }

    /// The Claude account the new agent will run under, from the account switcher's record when present.
    public static func spawnNote(for runtime: SpawnChoice) -> String? {
        guard runtime.name.lowercased().contains("claude") else { return nil }
        let switcher = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-switcher/accounts.json")
        if let data = try? Data(contentsOf: switcher), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accounts = json["accounts"] as? [[String: Any]],
            let active = accounts.first(where: { $0["active"] as? Bool == true }), let email = active["email"] as? String
        {
            return email
        }
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: config), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = json["oauthAccount"] as? [String: Any]
        {
            return account["emailAddress"] as? String
        }
        return nil
    }

    /// "GPT-5.6-Luna" reads "Luna 5.6", "GPT-6.1-Sol" reads "Sol 6.1", "GPT-5.5" reads "GPT 5.5"; anything not
    /// starting with GPT ("Daybreak Blue") is left as it is.
    static func codexDisplayName(_ name: String) -> String {
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0].uppercased() == "GPT" else { return name }
        let version = parts[1]
        let codename = parts.dropFirst(2).joined(separator: " ")
        return codename.isEmpty ? "GPT \(version)" : "\(codename) \(version)"
    }
}
