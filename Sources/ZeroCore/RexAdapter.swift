import Foundation

/// Agents Zero hosts itself, each in a Rex session of its own (Superlogical's Rex: a server that keeps terminals
/// running whether or not anything is looking at them). Everything goes through the `rex` CLI: `new` starts the
/// agent's terminal, `send`/`send-key` type into it, `capture` reads its screen, `block call … process` says
/// whether its program still runs, and a missing block (exit 3) means it was closed. Its folders are the projects
/// added in Zero's Settings.
public struct RexAdapter: AgentAdapter {
    public let name = "Rex"
    /// Reused for what doesn't depend on where an agent runs: model lists, the account note, reading replies.
    private let solo = SoloAdapter()

    public init() {}

    /// The folders agents may start in, from Settings.
    public static let projectsKey = "zeroProjects"
    public static var projects: [String] { UserDefaults.standard.stringArray(forKey: projectsKey) ?? [] }

    /// `rex` from Rex's own server, which the app keeps current; else one on the PATH.
    public static var executable: String? {
        let bundled = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let path = "\(dir)/rex"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: Reaching an agent

    public func canReach(_ agent: AgentIdentity) -> Bool { agent.runtime == "rex" && agent.ref != nil && Self.executable != nil }

    public func send(_ text: String, to agent: AgentIdentity) async throws {
        guard let block = agent.ref else { throw AdapterError("\(agent.name) has no Rex terminal") }
        // Typing into a half-written prompt would join Arsen's words and Zero's: wait for an empty input first.
        for attempt in 0..<23 {
            guard let screen = await screen(of: agent), let draft = SoloAdapter.draft(in: screen), !draft.isEmpty else { break }
            if attempt == 22 { throw AdapterError("Arsen is typing in \(agent.label ?? agent.name)'s terminal") }
            try await Task.sleep(for: .seconds(2))
        }
        guard await Self.rex(["send", "-b", block, text]).status == 0 else { throw AdapterError("Rex couldn't type into \(agent.label ?? agent.name)") }
        try await Task.sleep(for: .milliseconds(150))
        _ = await Self.rex(["send-key", "-b", block, "enter"])
    }

    public func screen(of agent: AgentIdentity) async -> String? {
        guard let block = agent.ref else { return nil }
        let result = await Self.rex(["capture", "-b", block, "--trim"])
        return result.status == 0 ? result.output : nil
    }

    public func press(_ bytes: [UInt8], on agent: AgentIdentity) async throws -> String? {
        guard let block = agent.ref else { throw AdapterError("\(agent.name) has no Rex terminal") }
        let keys: [[UInt8]: String] = [[13]: "enter", [27]: "escape", [127]: "backspace", [3]: "ctrl+c",
                                       [27, 91, 65]: "up", [27, 91, 66]: "down", [27, 91, 67]: "right", [27, 91, 68]: "left"]
        if let key = keys[bytes] { _ = await Self.rex(["send-key", "-b", block, key]) }
        else { _ = await Self.rex(["send", "-b", block, String(decoding: bytes, as: UTF8.self)]) }
        try? await Task.sleep(for: .milliseconds(350))
        return await screen(of: agent)
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

    /// Shows the agent's terminal in the Rex app: opens the app, then focuses the agent's terminal there.
    public static func reveal(_ agent: AgentIdentity) async {
        _ = await Task.detached {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-b", "com.superlogical.rex"]
            try? open.run()
            open.waitUntilExit()
        }.value
        guard let block = agent.ref else { return }
        try? await Task.sleep(for: .milliseconds(600))
        _ = await rex(["focus", "-b", block])
    }

    // MARK: Liveness

    /// Running in Rex unless its program has exited (the terminal stays, so the session can be resumed in it).
    public func offline(among agents: [AgentIdentity]) async -> Set<String> {
        var result: Set<String> = []
        for agent in agents where canReach(agent) {
            if case .exited = await Self.state(of: agent.ref!) { result.insert(agent.name) }
        }
        return result
    }

    /// Closed in Rex: its terminal no longer exists. A server that can't be reached says nothing either way.
    public func gone(among agents: [AgentIdentity]) async -> Set<String> {
        var result: Set<String> = []
        for agent in agents where canReach(agent) {
            if case .missing = await Self.state(of: agent.ref!) { result.insert(agent.name) }
        }
        return result
    }

    /// Ends Claude Code (twice ⌃C), keeping the terminal and the session, so a message resumes it.
    public func stop(_ agent: AgentIdentity) async {
        guard let block = agent.ref else { return }
        _ = await Self.rex(["send-key", "-b", block, "ctrl+c"])
        try? await Task.sleep(for: .milliseconds(400))
        _ = await Self.rex(["send-key", "-b", block, "ctrl+c"])
    }

    /// The agent's terminal as it is now: running, its program exited, or gone (or Rex unreachable).
    enum TerminalState { case running, exited, missing, unknown }

    static func state(of block: String) async -> TerminalState {
        let result = await rex(["block", "call", "-b", block, "process"])
        switch result.status {
        case 0:
            guard let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return .unknown }
            // Running: the terminal has a child process ("last_exit" is null). Exited: no child, an exit recorded.
            return json["child"] is [String: Any] ? .running : .exited
        case 3: return .missing
        default: return .unknown
        }
    }

    /// The agent's terminal if its program runs; otherwise Claude Code again in the same Rex session, resuming the
    /// conversation, and the old terminal closed.
    public func connect(_ agent: AgentIdentity) async throws -> AgentIdentity {
        guard let block = agent.ref else { throw AdapterError("\(agent.name) has no Rex terminal") }
        let now = await Self.state(of: block)
        if case .running = now { return agent }
        if case .unknown = now { throw AdapterError("Rex isn't running") }
        guard let session = agent.session, let cwd = agent.cwd, var command = agent.launch else {
            throw AdapterError("\(agent.label ?? agent.name)'s session is gone")
        }
        if let i = command.firstIndex(of: "--resume"), i + 1 < command.count { command.removeSubrange(i...(i + 1)) }
        let launch = agent.account.flatMap { account in AgentLaunch.file(in: command).flatMap { AgentLaunch.arm(account, at: $0) } }
        defer { if let launch { AgentLaunch.scrub(launch) } }
        var where_: [String] = ["run", "--json", "--keep-open", "--cwd", cwd]
        if let group = agent.refGroup { where_ += ["-s", group] }
        let created = await Self.rex(where_ + ["--"] + command + ["--resume", session])
        guard created.status == 0, let newBlock = Self.blockID(in: created.output) else {
            throw AdapterError("Rex couldn't start \(agent.label ?? agent.name) again")
        }
        if case .exited = now { _ = await Self.rex(["block", "close", block]) }
        var resumed = agent
        resumed.ref = newBlock
        try await Self.waitUntilReady(newBlock, name: agent.label ?? agent.name)
        return resumed
    }

    // MARK: Starting agents

    public var canSpawn: Bool { Self.executable != nil }

    public func refreshModels() async -> Bool { await solo.refreshModels() }

    public func spawnTargets() async throws -> [SpawnChoice] {
        let home = NSHomeDirectory()
        return Self.projects.map { path in
            SpawnChoice(id: path, name: (path as NSString).lastPathComponent, detail: path.replacingOccurrences(of: home, with: "~"),
                        icon: "folder", provider: "Rex")
        }
    }

    public func spawnRuntimes() async throws -> [SpawnChoice] {
        var runtimes = [SpawnChoice(id: "rex:claude", name: "Claude", detail: "claude", icon: "claude", provider: "Anthropic")]
        if Self.onPath("codex") { runtimes.append(SpawnChoice(id: "rex:codex", name: "Codex", detail: "codex", icon: "openai", provider: "OpenAI")) }
        return runtimes
    }

    public func spawnModels(for runtime: SpawnChoice) -> [SpawnChoice] { solo.spawnModels(for: runtime) }
    public func spawnNote(for runtime: SpawnChoice) -> String? { solo.spawnNote(for: runtime) }

    /// A Rex session of its own, named after the task, with Claude Code (or Codex) in its one terminal, started with
    /// the model, effort and account picked; once it sits at its prompt, the first message.
    public func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws -> AgentIdentity {
        let claude = runtime.id == "rex:claude"
        var command = [claude ? "claude" : "codex"]
        if let model, !model.id.isEmpty { command += [claude ? "--model" : "-m", model.id] }
        let account = settings["account"].flatMap { $0.isEmpty ? nil : $0 }
        var launch: String?
        if claude {
            if let account {
                guard let file = AgentLaunch.arm(account) else { throw AdapterError("\(account) isn't set up for single agents in Settings") }
                launch = file
                command += ["--settings", file]
            } else {
                command += ["--settings", #"{"env":{"ZERO_MANAGED":"1"}}"#]
            }
        }
        if let level = settings["reasoning"], !level.isEmpty {
            command += claude ? ["--effort", level] : ["-c", "model_reasoning_effort=\"\(level)\""]
        }
        defer { if let launch { AgentLaunch.scrub(launch) } }
        let created = await Self.rex(["new", Self.label(for: prompt), "--json", "--keep-open", "--cwd", target.id, "--"] + command)
        guard created.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(created.output.utf8)) as? [String: Any],
              let session = json["session_id"] as? String, let block = Self.blockID(in: created.output) else {
            throw AdapterError(created.status == 4 ? "Rex isn't running" : "Rex couldn't start the agent")
        }
        var identity = AgentIdentity(name: "claude-" + String(block.suffix(6)), host: ProcessInfo.processInfo.hostName, cwd: target.id)
        identity.runtime = "rex"
        identity.ref = block
        identity.refGroup = session
        identity.launch = command
        identity.account = account
        try await Self.waitUntilReady(block, name: identity.name)
        try await send(prompt, to: identity)
        return identity
    }

    /// The session's name in Rex: the start of the task, as Rex's own agent hook names sessions after their task.
    static func label(for prompt: String) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return words.count > 48 ? String(words.prefix(48)) + "…" : (words.isEmpty ? "Zero agent" : words)
    }

    /// Claude Code's input box is drawn once it is ready. A folder it hasn't been trusted in asks first: these are
    /// folders Arsen added to Zero himself, so "Yes, I trust this folder" is chosen. Up to 90 s.
    static func waitUntilReady(_ block: String, name: String) async throws {
        for _ in 0..<90 {
            try await Task.sleep(for: .seconds(1))
            let screen = await rex(["capture", "-b", block, "--trim"]).output
            if screen.contains("Yes, I trust this folder") {
                // Its cursor can start on "No, exit": move it to the yes before confirming.
                let chosen = screen.components(separatedBy: "\n").first { $0.contains("❯") && $0.contains("trust this folder") }
                _ = await rex(["send-key", "-b", block, chosen == nil ? "down" : "enter"])
                continue
            }
            if SoloAdapter.draft(in: screen) != nil { return }
        }
        throw AdapterError("\(name) didn't reach its prompt in Rex")
    }

    static func blockID(in output: String) -> String? {
        output.range(of: #"block:[0-9a-f-]{36}"#, options: .regularExpression).map { String(output[$0]) }
    }

    private static func onPath(_ program: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(program)") }
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/\(program)")
            || FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.local/bin/\(program)")
    }

    /// One `rex` call: its exit status (0 ok, 3 not found, 4 server unreachable) and what it printed.
    static func rex(_ arguments: [String]) async -> (status: Int32, output: String) {
        guard let executable else { return (127, "") }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (127, "") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
