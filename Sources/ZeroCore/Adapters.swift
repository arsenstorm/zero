import Foundation

/// Something an adapter can start an agent in (a project), with (a runtime), or as (a model): a name for the
/// chip, a detail line for the picker, and an icon resource name the app may know.
public struct SpawnChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String?
    public let icon: String?
    /// Who provides it ("Anthropic", "OpenAI", "Solo"): the small line under a name in the picker.
    public let provider: String?
    /// For a model: its context window as text, and the reasoning levels it can be started at.
    public let context: String?
    public let levels: [SpawnChoice]
    public let defaultLevel: String?
    public init(id: String, name: String, detail: String? = nil, icon: String? = nil, provider: String? = nil,
                context: String? = nil, levels: [SpawnChoice] = [], defaultLevel: String? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.icon = icon; self.provider = provider
        self.context = context; self.levels = levels; self.defaultLevel = defaultLevel
    }
}

/// A way to deliver Arsen's words into an agent's session, and optionally to start a new one. Solo is the
/// first; a Hyperfocus or bench adapter would implement the same calls.
public protocol AgentAdapter: Sendable {
    var name: String { get }
    func canReach(_ agent: AgentIdentity) -> Bool
    func send(_ text: String, to agent: AgentIdentity) async throws
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
    /// `settings`: per-model configuration Arsen picked, such as ["reasoning": "high"].
    func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws -> AgentIdentity
}

public extension AgentAdapter {
    var canSpawn: Bool { false }
    func spawnTargets() async throws -> [SpawnChoice] { [] }
    func spawnRuntimes() async throws -> [SpawnChoice] { [] }
    func spawnModels(for runtime: SpawnChoice) -> [SpawnChoice] { [] }
    func spawnNote(for runtime: SpawnChoice) -> String? { nil }
    func refreshModels() async -> Bool { false }
    func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws -> AgentIdentity {
        throw AdapterError("\(name) cannot start agents")
    }
}

public struct AdapterError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// Talks to the running Solo app through its bundled MCP stdio helper: one helper per message, three
/// JSON-RPC lines (initialize, initialized, tools/call send_input), then it exits.
public struct SoloAdapter: AgentAdapter {
    public let name = "solo"
    public var helper = "/Applications/Solo.app/Contents/MacOS/mcp"
    public var timeout: TimeInterval = 10

    public init() {}

    public func canReach(_ agent: AgentIdentity) -> Bool {
        agent.soloProcessID != nil && FileManager.default.isExecutableFile(atPath: helper)
    }

    public func send(_ text: String, to agent: AgentIdentity) async throws {
        guard let processID = agent.soloProcessID else { throw AdapterError("\(agent.name) has no Solo process id") }
        _ = try await resultText(of: call(tool: "send_input", arguments: ["process_id": processID, "input": text, "submit": true]))
    }

    public var canSpawn: Bool { FileManager.default.isExecutableFile(atPath: helper) }

    public func refreshModels() async -> Bool { await ClaudeModels.refresh() }

    public func spawnTargets() async throws -> [SpawnChoice] {
        let rows = try await resultJSON(of: call(tool: "list_projects", arguments: [:])) as? [[String: Any]] ?? []
        let home = NSHomeDirectory()
        return rows.compactMap { row in
            guard let id = row["id"] as? Int else { return nil }
            let path = (row["path"] as? String)?.replacingOccurrences(of: home, with: "~")
            return SpawnChoice(id: String(id), name: (row["display_name"] as? String) ?? (row["name"] as? String) ?? "Project \(id)",
                               detail: path, icon: "solo", provider: "Solo")
        }
    }

    public func spawnRuntimes() async throws -> [SpawnChoice] {
        let rows = try await resultJSON(of: call(tool: "list_agent_tools", arguments: [:])) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? Int, (row["enabled"] as? Bool) != false else { return nil }
            let name = (row["name"] as? String) ?? "Tool \(id)"
            let claude = name.lowercased().contains("claude"), codex = name.lowercased().contains("codex")
            return SpawnChoice(id: String(id), name: name, detail: row["command"] as? String,
                               icon: claude ? "claude" : codex ? "openai" : nil, provider: claude ? "Anthropic" : codex ? "OpenAI" : nil)
        }
    }

    /// Claude Code takes `--model`. The choices are what its own picker offers the active account: the built-in
    /// aliases, plus the account-specific options Claude Code caches in ~/.claude.json after use. A model an
    /// account gained (Mythos, say) shows up here once that account has been used in Claude Code.
    /// Codex's ids are not known here, so it offers none.
    public func spawnModels(for runtime: SpawnChoice) -> [SpawnChoice] {
        let name = runtime.name.lowercased()
        if name.contains("claude") { return claudeModels() }
        if name.contains("codex") { return codexModels() }
        return []
    }

    /// Claude Code's picker for the active account: the built-in aliases, then the account's cached options with
    /// their own descriptions ("Fable 5.1 · Most capable…"), whose first part names the model precisely.
    /// Claude's list comes from Anthropic's models endpoint for the active Claude Code account (see ClaudeModels),
    /// merged with Claude Code's local option cache. Never a list typed here.
    private func claudeModels() -> [SpawnChoice] { ClaudeModels.cached() }

    /// Codex's own catalogue for the signed-in account, from its cache: listed models in its order.
    private func codexModels() -> [SpawnChoice] {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: cache), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { (($0["priority"] as? Int) ?? 99) < (($1["priority"] as? Int) ?? 99) }
            .compactMap { model in
                guard let slug = model["slug"] as? String else { return nil }
                let window = (model["context_window"] as? Int).map { $0 >= 1_000_000 ? "\($0 / 1_000_000)M tokens" : "\($0 / 1000)K tokens" }
                let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { level -> SpawnChoice? in
                    guard let effort = level["effort"] as? String else { return nil }
                    return SpawnChoice(id: effort, name: effort.capitalized, detail: level["description"] as? String)
                }
                return SpawnChoice(id: slug, name: (model["display_name"] as? String) ?? slug, detail: model["description"] as? String,
                                   icon: "openai", provider: "OpenAI", context: window, levels: levels,
                                   defaultLevel: model["default_reasoning_level"] as? String)
            }
    }

    /// The Claude account the new agent will run under, from the account switcher's record when present.
    public func spawnNote(for runtime: SpawnChoice) -> String? {
        guard runtime.name.lowercased().contains("claude") else { return nil }
        let switcher = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-switcher/accounts.json")
        if let data = try? Data(contentsOf: switcher), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accounts = json["accounts"] as? [[String: Any]],
           let active = accounts.first(where: { $0["active"] as? Bool == true }), let email = active["email"] as? String {
            return email
        }
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: config), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let account = json["oauthAccount"] as? [String: Any] { return account["emailAddress"] as? String }
        return nil
    }

    /// Spawns the agent in the project, waits until it is idle at its prompt, then types the first message.
    public func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws -> AgentIdentity {
        guard let projectID = Int(target.id), let toolID = Int(runtime.id) else { throw AdapterError("Bad Solo ids") }
        var arguments: [String: Any] = ["project_id": projectID, "agent_tool_id": toolID, "include_agent_instructions": false]
        var extra: [String] = []
        if let model, !model.id.isEmpty { extra += ["--model", model.id] }
        if runtime.name.lowercased().contains("codex"), let level = settings["reasoning"], !level.isEmpty {
            extra += ["-c", "model_reasoning_effort=\"\(level)\""]
        }
        if !extra.isEmpty { arguments["extra_args"] = extra }
        let created = try await resultJSON(of: call(tool: "spawn_agent", arguments: arguments)) as? [String: Any] ?? [:]
        guard let processID = created["process_id"] as? Int else { throw AdapterError("Solo did not return a process id") }
        let name = (created["name"] as? String) ?? "agent-\(processID)"
        let identity = AgentIdentity(name: name, host: ProcessInfo.processInfo.hostName, soloProcessID: processID)
        // A prompt typed before the agent sits at its own input is lost, so wait: first for idle, then for any
        // start-up dialog (Claude Code's "trust this folder", for one) to be answered in Solo. Up to 90 s.
        var ready = false
        for second in 0..<90 {
            try await Task.sleep(for: .seconds(1))
            let status = try await resultJSON(of: call(tool: "get_process_status", arguments: ["process_id": processID])) as? [String: Any]
            let idle = (status?["agent_state"] as? [String: Any])?["idle"] as? Bool == true
            guard idle || second >= 20 else { continue }
            let screen = try await resultText(of: call(tool: "get_process_output", arguments: ["process_id": processID, "lines": 15]))
            let dialog = ["Enter to confirm", "trust this folder", "Esc to cancel"].contains { screen.contains($0) }
            if !dialog { ready = true; break }
        }
        guard ready else {
            throw AdapterError("\(name) started, but it is waiting at a dialog in Solo. Answer it there, then message the agent.")
        }
        try await send(prompt, to: identity)
        return identity
    }

    private func resultText(of result: [String: Any]) throws -> String {
        let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        if let isError = result["isError"] as? Bool, isError { throw AdapterError(content.isEmpty ? "Solo refused the call" : content) }
        return content
    }

    private func resultJSON(of result: [String: Any]) throws -> Any {
        let raw = try resultText(of: result)
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? [:]
    }

    // ponytail: a fresh helper per call keeps this stateless; pool one helper if messages ever get chatty.
    private func call(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try callBlocking(tool: tool, arguments: arguments)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func callBlocking(tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SOLO_PROCESS_ID") // Zero speaks as itself, not as whichever agent launched it
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel(); if process.isRunning { process.terminate() } }

        func write(_ object: [String: Any]) throws {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8))
        }
        try write(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "zero", "version": "0.1"]]])
        try write(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try write(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw AdapterError("Solo's MCP helper closed without answering") }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["id"] as? Int == 2 else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw AdapterError(error["message"] as? String ?? "Solo returned an error")
                }
                return message["result"] as? [String: Any] ?? [:]
            }
        }
    }
}
