import Foundation

/// An agent in a terminal Zero types into and reads, wherever that terminal lives: Zero's own host (HostAdapter)
/// or Rex. Each says how to type, read the screen and tell whether the program runs; the rest is shared here.
protocol TerminalAdapter: AgentAdapter {
    /// The agent's runtime as recorded on its identity ("zero", "rex").
    var runtime: String { get }
    func type(_ text: String, into ref: String) async -> Bool
    func write(_ bytes: [UInt8], to ref: String) async
    func capture(_ ref: String) async -> String?
    func state(of ref: String) async -> TerminalState
}

/// An agent's terminal as it is now: running, its program exited, gone, or its host can't be reached.
enum TerminalState { case running, exited, missing, unknown }

enum TerminalKey {
    static let enter: [UInt8] = [13], escape: [UInt8] = [27], backspace: [UInt8] = [127], ctrlC: [UInt8] = [3]
    static let up: [UInt8] = [27, 91, 65], down: [UInt8] = [27, 91, 66], right: [UInt8] = [27, 91, 67], left: [UInt8] = [27, 91, 68]
}

extension TerminalAdapter {
    public func canReach(_ agent: AgentIdentity) -> Bool { agent.runtime == runtime && agent.ref != nil }

    public func send(_ text: String, to agent: AgentIdentity) async throws {
        guard let ref = agent.ref else { throw AdapterError("\(agent.name) has no terminal") }
        try await waitForEmptyInput(of: agent)
        guard await type(text, into: ref) else { throw AdapterError("\(name) couldn't type into \(agent.label ?? agent.name)") }
        try await Task.sleep(for: .milliseconds(150))
        await write(TerminalKey.enter, to: ref)
    }

    public func screen(of agent: AgentIdentity) async -> String? {
        guard let ref = agent.ref else { return nil }
        return await capture(ref)
    }

    public func press(_ bytes: [UInt8], on agent: AgentIdentity) async throws -> String? {
        guard let ref = agent.ref else { throw AdapterError("\(agent.name) has no terminal") }
        await write(bytes, to: ref)
        try? await Task.sleep(for: .milliseconds(350))
        return await capture(ref)
    }

    /// The reply is read off the screen, as for Solo: once the agent is no longer working (Claude Code shows
    /// "esc to interrupt" while it is) and a reply follows the echo of our message.
    public func reply(from agent: AgentIdentity, to text: String) async -> String? {
        for _ in 0..<450 {
            try? await Task.sleep(for: .seconds(2))
            guard let screen = await screen(of: agent) else { return nil }
            if screen.contains("esc to interrupt") { continue }
            if let reply = SoloAdapter.lastReply(in: screen, after: text) { return reply }
        }
        return nil
    }

    public func displayName(for agent: AgentIdentity) async -> String? {
        guard let session = agent.session, let cwd = agent.cwd else { return nil }
        return ClaudeSessions.title(of: session, cwd: cwd)
    }

    public func session(for agent: AgentIdentity, firstPrompt: String) async -> String? {
        guard let cwd = agent.cwd else { return nil }
        for _ in 0..<15 {
            if let id = ClaudeSessions.find(prompt: firstPrompt, cwd: cwd) { return id }
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    public func findSession(for agent: AgentIdentity, firstPrompt: String) async -> String? {
        agent.cwd.flatMap { ClaudeSessions.find(prompt: firstPrompt, cwd: $0) }
    }

    public func switchModel(of agent: AgentIdentity, to model: SpawnChoice?, level: String?) async throws {
        if let model {
            guard model.provider == "Anthropic" else { throw AdapterError("Only a Claude agent can change model while running") }
            try await send("/model \(model.id)", to: agent)
        }
        if let level, !level.isEmpty {
            if model != nil { try await Task.sleep(for: .milliseconds(1500)) }
            try await send("/effort \(level)", to: agent)
        }
    }

    /// Running unless its program has exited (the terminal stays, so the session can be resumed in it).
    public func offline(among agents: [AgentIdentity]) async -> Set<String> {
        var result: Set<String> = []
        for agent in agents where canReach(agent) {
            if case .exited = await state(of: agent.ref!) { result.insert(agent.name) }
        }
        return result
    }

    /// Closed: its terminal no longer exists. A host that can't be reached says nothing either way.
    public func gone(among agents: [AgentIdentity]) async -> Set<String> {
        var result: Set<String> = []
        for agent in agents where canReach(agent) {
            if case .missing = await state(of: agent.ref!) { result.insert(agent.name) }
        }
        return result
    }

    /// Ends Claude Code (twice ⌃C), keeping the terminal and the session, so a message resumes it.
    public func stop(_ agent: AgentIdentity) async {
        guard let ref = agent.ref else { return }
        await write(TerminalKey.ctrlC, to: ref)
        try? await Task.sleep(for: .milliseconds(400))
        await write(TerminalKey.ctrlC, to: ref)
    }

    public func spawnTargets() async throws -> [SpawnChoice] {
        let home = NSHomeDirectory()
        return Projects.folders.map { path in
            SpawnChoice(id: path, name: (path as NSString).lastPathComponent, detail: path.replacingOccurrences(of: home, with: "~"),
                        icon: "folder", provider: name)
        }
    }

    public func spawnRuntimes() async throws -> [SpawnChoice] {
        var runtimes = [SpawnChoice(id: "\(runtime):claude", name: "Claude", detail: "claude", icon: "claude", provider: "Anthropic")]
        if AgentCommand.onPath("codex") {
            runtimes.append(SpawnChoice(id: "\(runtime):codex", name: "Codex", detail: "codex", icon: "openai", provider: "OpenAI"))
        }
        return runtimes
    }

    public func refreshModels() async -> Bool { await SoloAdapter().refreshModels() }
    public func spawnModels(for runtime: SpawnChoice) -> [SpawnChoice] { SoloAdapter().spawnModels(for: runtime) }
    public func spawnNote(for runtime: SpawnChoice) -> String? { SoloAdapter().spawnNote(for: runtime) }

    /// Claude Code's input box is drawn once it is ready. A folder it hasn't been trusted in asks first: these are
    /// folders the user added to Zero themselves, so "Yes, I trust this folder" is chosen (its cursor can start on
    /// "No, exit"). Up to 90 s.
    func waitUntilReady(_ ref: String, name agent: String) async throws {
        for _ in 0..<90 {
            try await Task.sleep(for: .seconds(1))
            let text = await capture(ref) ?? ""
            if text.contains("Yes, I trust this folder") {
                let chosen = text.components(separatedBy: "\n").first { $0.contains("❯") && $0.contains("trust this folder") }
                await write(chosen == nil ? TerminalKey.down : TerminalKey.enter, to: ref)
                continue
            }
            if SoloAdapter.draft(in: text) != nil { return }
        }
        throw AdapterError("\(agent) didn't reach its prompt in \(name)")
    }
}

/// The folders Zero's own agents may start in, from Settings → Projects.
public enum Projects {
    public static let key = "zeroProjects"
    public static var folders: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
}

/// The command line a terminal-hosted agent starts with.
enum AgentCommand {
    /// `claude` or `codex` with the model and effort picked.
    static func build(runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) -> [String] {
        let claude = runtime.id.hasSuffix(":claude")
        var command = [claude ? "claude" : "codex"]
        if let model, !model.id.isEmpty { command += [claude ? "--model" : "-m", model.id] }
        if claude { command += ["--settings", #"{"env":{"ZERO_MANAGED":"1"}}"#] }
        if let level = settings["reasoning"], !level.isEmpty {
            command += claude ? ["--effort", level] : ["-c", "model_reasoning_effort=\"\(level)\""]
        }
        return command
    }

    /// The command to start the agent again, resuming its session.
    static func resume(_ agent: AgentIdentity) throws -> [String] {
        guard let session = agent.session, var command = agent.launch else { throw AdapterError("\(agent.label ?? agent.name)'s session is gone") }
        if let i = command.firstIndex(of: "--resume"), i + 1 < command.count { command.removeSubrange(i...(i + 1)) }
        return command + ["--resume", session]
    }

    /// The session's name: the start of the task.
    static func label(for prompt: String) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return words.count > 48 ? String(words.prefix(48)) + "…" : (words.isEmpty ? "Zero agent" : words)
    }

    static func onPath(_ program: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(program)") }
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/\(program)")
            || FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.local/bin/\(program)")
    }
}
