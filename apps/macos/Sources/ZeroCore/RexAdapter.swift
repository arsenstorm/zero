import Foundation

/// Agents in Rex (Superlogical's Rex: a server that keeps terminals running whether or not anything is looking at
/// them), each in a Rex session of its own. Optional: Zero starts agents in Rex only when Rex is turned on in
/// Settings → Integrations; otherwise in its own terminals (HostAdapter). Everything goes through the `rex` CLI:
/// `new` starts the agent's terminal, `send`/`send-key` type into it, `capture` reads its screen,
/// `block call … process` says whether its program still runs, and a missing block (exit 3) means it was closed.
public struct RexAdapter: TerminalAdapter {
    public let name = "Rex"
    let runtime = "rex"

    public init() {}

    /// Whether new agents start in Rex rather than in Zero's own terminals.
    public static let enabledKey = "rexEnabled"
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) && executable != nil }

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

    // MARK: The terminal

    func type(_ text: String, into ref: String) async -> Bool { await Self.rex(["send", "-b", ref, text]).status == 0 }

    func write(_ bytes: [UInt8], to ref: String) async {
        let keys: [[UInt8]: String] = [TerminalKey.enter: "enter", TerminalKey.escape: "escape", TerminalKey.backspace: "backspace",
                                       TerminalKey.ctrlC: "ctrl+c", TerminalKey.up: "up", TerminalKey.down: "down",
                                       TerminalKey.right: "right", TerminalKey.left: "left"]
        if let key = keys[bytes] { _ = await Self.rex(["send-key", "-b", ref, key]) }
        else { _ = await Self.rex(["send", "-b", ref, String(decoding: bytes, as: UTF8.self)]) }
    }

    func capture(_ ref: String) async -> String? {
        let result = await Self.rex(["capture", "-b", ref, "--trim"])
        return result.status == 0 ? result.output : nil
    }

    func state(of ref: String) async -> TerminalState {
        let result = await Self.rex(["block", "call", "-b", ref, "process"])
        switch result.status {
        case 0:
            guard let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return .unknown }
            // Running: the terminal has a child process ("last_exit" is null). Exited: no child, an exit recorded.
            return json["child"] is [String: Any] ? .running : .exited
        case 3: return .missing
        default: return .unknown
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

    /// The agent's terminal if its program runs; otherwise Claude Code again in the same Rex session, resuming the
    /// conversation, and the old terminal closed.
    public func connect(_ agent: AgentIdentity) async throws -> AgentIdentity {
        guard let block = agent.ref else { throw AdapterError("\(agent.name) has no Rex terminal") }
        let now = await state(of: block)
        if case .running = now { return agent }
        if case .unknown = now { throw AdapterError("Rex isn't running") }
        guard let cwd = agent.cwd else { throw AdapterError("\(agent.label ?? agent.name)'s session is gone") }
        let command = try AgentCommand.resume(agent)
        var where_: [String] = ["run", "--json", "--keep-open", "--cwd", cwd]
        if let group = agent.refGroup { where_ += ["-s", group] }
        let created = await Self.rex(where_ + ["--"] + command)
        guard created.status == 0, let newBlock = Self.blockID(in: created.output) else {
            throw AdapterError("Rex couldn't start \(agent.label ?? agent.name) again")
        }
        if case .exited = now { _ = await Self.rex(["block", "close", block]) }
        var resumed = agent
        resumed.ref = newBlock
        try await waitUntilReady(newBlock, name: agent.label ?? agent.name)
        return resumed
    }

    // MARK: Starting agents

    public var canSpawn: Bool { Self.enabled }

    /// A Rex session of its own, named after the task, with Claude Code (or Codex) in its one terminal, started with
    /// the model and effort picked; once it sits at its prompt, the first message.
    public func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws -> AgentIdentity {
        let command = AgentCommand.build(runtime: runtime, model: model, settings: settings)
        let created = await Self.rex(["new", AgentCommand.label(for: prompt), "--json", "--keep-open", "--cwd", target.id, "--"] + command)
        guard created.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(created.output.utf8)) as? [String: Any],
              let session = json["session_id"] as? String, let block = Self.blockID(in: created.output) else {
            throw AdapterError(created.status == 4 ? "Rex isn't running" : "Rex couldn't start the agent")
        }
        var identity = AgentIdentity(name: "claude-" + String(block.suffix(6)), host: ProcessInfo.processInfo.hostName, cwd: target.id)
        identity.runtime = self.runtime
        identity.ref = block
        identity.refGroup = session
        identity.launch = command
        try await waitUntilReady(block, name: identity.name)
        try await send(prompt, to: identity)
        return identity
    }

    static func blockID(in output: String) -> String? {
        output.range(of: #"block:[0-9a-f-]{36}"#, options: .regularExpression).map { String(output[$0]) }
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
