import Foundation

/// Agents in Zero's own terminals, kept by zero-host (Sources/ZeroHost), which runs on its own so they keep
/// running when Zero quits. Zero starts agents here unless Rex is turned on.
public struct HostAdapter: TerminalAdapter {
    public let name = "Zero"
    let runtime = "zero"

    public init() {}

    func type(_ text: String, into ref: String) async -> Bool {
        await HostLink.call(HostLink.Request(op: "write", id: ref, text: text))?.ok == true
    }

    func write(_ bytes: [UInt8], to ref: String) async {
        _ = await HostLink.call(HostLink.Request(op: "write", id: ref, bytes: bytes))
    }

    func capture(_ ref: String) async -> String? {
        await HostLink.call(HostLink.Request(op: "screen", id: ref))?.screen
    }

    func state(of ref: String) async -> TerminalState {
        guard let response = await HostLink.call(HostLink.Request(op: "state", id: ref)) else { return .unknown }
        guard let terminal = response.terminal else { return .missing }
        return terminal.running ? .running : .exited
    }

    /// Shows the agent's terminal in the Mac's terminal app, through `zero attach` in a .command file it opens.
    public static func reveal(_ ref: String) {
        let file = Paths.dir.appendingPathComponent("attach-\(ref.suffix(6)).command")
        let cli = URL(fileURLWithPath: HostLink.executable).deletingLastPathComponent().appendingPathComponent("zero-cli").path
        try? "#!/bin/sh\nclear\nexec '\(cli)' attach \(ref)\n".write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o755)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [file.path])
    }

    /// The agent's terminal if its program runs; otherwise a new one resuming the conversation, the old one closed.
    public func connect(_ agent: AgentIdentity) async throws -> AgentIdentity {
        guard let ref = agent.ref else { throw AdapterError("\(agent.name) has no terminal") }
        let now = await state(of: ref)
        if case .running = now { return agent }
        guard let cwd = agent.cwd else { throw AdapterError("\(agent.label ?? agent.name)'s session is gone") }
        let (command, launch) = try AgentCommand.resume(agent)
        defer { if let launch { AgentLaunch.scrub(launch) } }
        let terminal = try await start(command, in: cwd, label: agent.label ?? agent.name)
        if case .exited = now { _ = await HostLink.call(HostLink.Request(op: "close", id: ref)) }
        var resumed = agent
        resumed.ref = terminal
        try await waitUntilReady(terminal, name: agent.label ?? agent.name)
        return resumed
    }

    public var canSpawn: Bool { !RexAdapter.enabled }

    /// A terminal of its own with Claude Code (or Codex), started with the model, effort and account picked; once
    /// it sits at its prompt, the first message.
    public func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws -> AgentIdentity {
        let (command, launch, account) = try AgentCommand.build(runtime: runtime, model: model, settings: settings)
        defer { if let launch { AgentLaunch.scrub(launch) } }
        let terminal = try await start(command, in: target.id, label: AgentCommand.label(for: prompt))
        var identity = AgentIdentity(name: "claude-" + String(terminal.suffix(6)), host: ProcessInfo.processInfo.hostName, cwd: target.id)
        identity.runtime = self.runtime
        identity.ref = terminal
        identity.launch = command
        identity.account = account
        try await waitUntilReady(terminal, name: identity.name)
        try await send(prompt, to: identity)
        return identity
    }

    private func start(_ command: [String], in cwd: String, label: String) async throws -> String {
        guard await HostLink.ensureRunning() else { throw AdapterError("Zero's terminal host didn't start") }
        let response = await HostLink.call(HostLink.Request(op: "spawn", cwd: cwd, argv: command, label: label))
        guard let terminal = response?.terminal?.id else { throw AdapterError(response?.error ?? "Zero couldn't start the agent") }
        return terminal
    }
}
