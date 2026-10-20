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
    /// What the agent said back to `text`, once it has finished its turn; nil when the adapter cannot tell.
    func reply(from agent: AgentIdentity, to text: String) async -> String?
    /// What the runtime calls the agent now, when that is more than the tool's generic name.
    func displayName(for agent: AgentIdentity) async -> String?
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
    func reply(from agent: AgentIdentity, to text: String) async -> String? { nil }
    func displayName(for agent: AgentIdentity) async -> String? { nil }
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
        var arguments: [String: Any] = ["process_id": processID, "input": text, "submit": true]
        if let project = agent.soloProjectID { arguments["project_id"] = project }
        _ = try await resultText(of: call(tool: "send_input", arguments: arguments))
    }

    /// Solo renames a session after its first task ("Ready word reply"); the tool's own name is not a label.
    public func displayName(for agent: AgentIdentity) async -> String? {
        guard let processID = agent.soloProcessID else { return nil }
        var arguments: [String: Any] = ["process_id": processID]
        if let project = agent.soloProjectID { arguments["project_id"] = project }
        guard let status = try? await resultJSON(of: call(tool: "get_process_status", arguments: arguments)) as? [String: Any],
              let name = status["name"] as? String, !name.isEmpty else { return nil }
        return ["claude", "codex", "agent", "claude code"].contains(name.lowercased()) ? nil : name
    }

    /// Solo reports only busy or idle, so the reply is read off the agent's screen: wait for it to start
    /// working and then go idle, then take the last thing it said after the echo of our message.
    public func reply(from agent: AgentIdentity, to text: String) async -> String? {
        guard let processID = agent.soloProcessID else { return nil }
        var arguments: [String: Any] = ["process_id": processID]
        if let project = agent.soloProjectID { arguments["project_id"] = project }
        // Every 2 s, up to 15 minutes; each check is one helper process. Idle is not enough on its own (it may
        // still be the idleness from before our message landed), so the screen is read whenever the agent is
        // idle and the loop only ends once a reply after the echo of our message is there.
        for _ in 0..<450 {
            try? await Task.sleep(for: .seconds(2))
            guard let status = try? await resultJSON(of: call(tool: "get_process_status", arguments: arguments)) as? [String: Any],
                  let state = status["agent_state"] as? [String: Any] else { continue }
            if (status["status"] as? String) == "Exited" { NSLog("zero: reply watch for \(agent.name): process exited"); return nil }
            guard state["idle"] as? Bool == true, (state["idle_seconds"] as? Double ?? 0) >= 1.5 else { continue }
            var output = arguments
            output["lines"] = 200
            let screen = (try? await resultText(of: call(tool: "get_process_output", arguments: output))) ?? ""
            if let reply = Self.lastReply(in: screen, after: text) {
                NSLog("zero: reply from \(agent.name): \(reply.prefix(80))")
                return reply
            }
        }
        NSLog("zero: reply watch for \(agent.name) timed out")
        return nil
    }

    /// The agent's last spoken block on a rendered Claude Code or Codex screen, after the echo of `prompt`:
    /// a block starts at a "⏺"/"●" line, tool calls (followed by "⎿", or named like `Bash(`) are skipped, and the
    /// turn ends at the "· done" line or the next prompt. ponytail: screen scraping; Solo has no message API.
    public static func lastReply(in screen: String, after prompt: String) -> String? {
        let lines = screen.components(separatedBy: "\n")
        let needle = String(prompt.prefix(40))
        var start = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The echo is the prompt glyph followed by our text; a later prompt that merely contains it is not.
            if let first = trimmed.first, "❯〉›>".contains(first),
               trimmed.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix(needle) { start = index + 1 }
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
                let raw = (model["display_name"] as? String) ?? slug
                let window = (model["context_window"] as? Int).map { $0 >= 1_000_000 ? "\($0 / 1_000_000)M tokens" : "\($0 / 1000)K tokens" }
                let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { level -> SpawnChoice? in
                    guard let effort = level["effort"] as? String else { return nil }
                    return SpawnChoice(id: effort, name: effort.capitalized, detail: level["description"] as? String)
                }
                return SpawnChoice(id: slug, name: Self.codexDisplayName(raw), detail: model["description"] as? String,
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
        if let level = settings["reasoning"], !level.isEmpty {
            if model?.provider == "Anthropic" { extra += ["--effort", level] }
            else if runtime.name.lowercased().contains("codex") { extra += ["-c", "model_reasoning_effort=\"\(level)\""] }
        }
        if !extra.isEmpty { arguments["extra_args"] = extra }
        // An exited agent of this tool already in the project is started again rather than adding another tab.
        // ponytail: a restart reruns the command it was created with, its own model and effort, not the ones
        // picked now; send "/model" after start if that matters.
        let created: [String: Any]
        if let exited = try await exitedAgent(in: projectID, running: runtime.detail), let id = exited["id"] as? Int {
            _ = try await resultText(of: call(tool: "start_process", arguments: ["process_id": id, "project_id": projectID]))
            created = ["process_id": id, "name": exited["name"] ?? "agent"]
        } else {
            created = try await resultJSON(of: call(tool: "spawn_agent", arguments: arguments)) as? [String: Any] ?? [:]
        }
        guard let processID = created["process_id"] as? Int else { throw AdapterError("Solo did not return a process id") }
        // Solo calls every Claude process "Claude", and Zero keys agents by name: a closed "Claude" would hide
        // the next one. Named like the CLI's agents instead: claude-119.
        let base = ((created["name"] as? String) ?? "agent").lowercased().replacingOccurrences(of: " ", with: "-")
        let name = "\(base)-\(processID)"
        let identity = AgentIdentity(name: name, host: ProcessInfo.processInfo.hostName, soloProcessID: processID, soloProjectID: projectID)
        // A prompt typed before the agent sits at its own input is lost, so wait: first for idle, then for any
        // start-up dialog (Claude Code's "trust this folder", for one) to be answered in Solo. Up to 90 s.
        var ready = false
        for second in 0..<90 {
            try await Task.sleep(for: .seconds(1))
            // Solo wants the project on every call: without it, "No project selected" after a successful spawn.
            let status = try await resultJSON(of: call(tool: "get_process_status", arguments: ["process_id": processID, "project_id": projectID])) as? [String: Any]
            let idle = (status?["agent_state"] as? [String: Any])?["idle"] as? Bool == true
            guard idle || second >= 20 else { continue }
            let screen = try await resultText(of: call(tool: "get_process_output", arguments: ["process_id": processID, "project_id": projectID, "lines": 15]))
            let dialog = ["Enter to confirm", "trust this folder", "Esc to cancel"].contains { screen.contains($0) }
            if !dialog { ready = true; break }
        }
        guard ready else {
            throw AdapterError("\(name) started, but it is waiting at a dialog in Solo. Answer it there, then message the agent.")
        }
        try await send(prompt, to: identity)
        return identity
    }

    /// The first exited agent process in the project whose command is the tool's (`command` is the tool's
    /// command line, such as "claude"; nil matches any agent).
    private func exitedAgent(in projectID: Int, running command: String?) async throws -> [String: Any]? {
        let processes = try await resultJSON(of: call(tool: "list_processes", arguments: ["project_id": projectID])) as? [[String: Any]] ?? []
        let executable = command?.split(separator: " ").first.map(String.init)
        return processes.first { process in
            // "Exited" ended on its own, "Stopped" was stopped in Solo; either one is free to start again.
            guard (process["kind"] as? String) == "agent", ["Exited", "Stopped"].contains((process["status"] as? String) ?? "") else { return false }
            guard let executable else { return true }
            return ((process["command"] as? String) ?? "").split(separator: " ").first.map(String.init) == executable
        }
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

extension SoloAdapter {
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
