import Foundation
import Observation

/// The app's copy of zerod's inbox (crates/zerod/src/inbox.rs): every ask, oldest first, kept current from zerod's
/// events, and what the inbox window does to them sent back as requests. The state machine, the log, runs and delivery
/// are zerod's; what the user picks shows at once and zerod's own account of it follows.
@MainActor @Observable
public final class Store {
    public private(set) var asks: [Ask] = []
    /// Agents whose session is not running, by zerod's last look.
    public private(set) var offline: Set<String> = []
    /// Agents zerod can type into.
    public private(set) var reachable: Set<String> = []
    public private(set) var connected = false

    @ObservationIgnored public var onCreate: ((Ask) -> Void)?
    @ObservationIgnored public var onChange: ((Ask) -> Void)?
    @ObservationIgnored public var onOutput: ((Ask, String) -> Void)?
    @ObservationIgnored public var onRemove: ((String) -> Void)?

    /// Agents whose terminal screen is open in Zero (after a slash command), with the latest rendering.
    public private(set) var screens: [String: String] = [:]
    @ObservationIgnored private var screenPolls: [String: Task<Void, Never>] = [:]
    /// Where agents start and what they can run as, for the composer and the model picker.
    @ObservationIgnored public let adapters: [AgentAdapter]
    @ObservationIgnored private var link: ZerodLink?
    @ObservationIgnored private var settings: (takeBack: Double, ttl: Int, patterns: [String])?

    /// `asks` to start from, for previews; a connected store gets zerod's.
    public init(asks: [Ask] = [], adapters: [AgentAdapter] = [ZerodSpawner(), SoloAdapter(), HostAdapter(), RexAdapter()]) {
        self.asks = asks
        self.adapters = adapters
    }

    // The connection.

    /// Starts zerod if it isn't running, follows its inbox, and connects again whenever the connection drops.
    public func connect() async {
        while true {
            if link == nil, await ZerodLink.ensureRunning(), let fresh = try? ZerodLink() {
                fresh.onInbox = { [weak self] message in Task { @MainActor in self?.receive(message) } }
                fresh.onClose = { [weak self] in Task { @MainActor in self?.link = nil; self?.connected = false } }
                link = fresh
                if let settings { try? await fresh.configure(takeBack: settings.takeBack, ttl: settings.ttl, patterns: settings.patterns) }
                if (try? await fresh.followInbox()) != nil { connected = true }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func receive(_ message: ZerodLink.InboxMessage) {
        switch message {
        case let .asks(all, offline, reachable):
            asks = all
            (self.offline, self.reachable) = (offline, reachable)
        case let .ask(ask):
            if let i = asks.firstIndex(where: { $0.id == ask.id }) {
                asks[i] = ask
            } else {
                asks.append(ask)
                onCreate?(ask)
            }
            onChange?(ask)
        case let .output(id, chunk):
            guard let i = asks.firstIndex(where: { $0.id == id }) else { return }
            asks[i].output += chunk
            onOutput?(asks[i], chunk)
        case let .removed(id):
            asks.removeAll { $0.id == id }
            onRemove?(id)
        case let .agents(offline, reachable):
            if offline != self.offline { self.offline = offline }
            if reachable != self.reachable { self.reachable = reachable }
        }
    }

    /// The take-back window and default expiry (seconds), and the drop folders' patterns; sent again on every connect.
    public func configure(takeBack: Double, ttl: Int, patterns: [String]) {
        settings = (takeBack, ttl, patterns)
        request { try await $0.configure(takeBack: takeBack, ttl: ttl, patterns: patterns) }
    }

    /// A request with nothing to wait for; a failure is only logged.
    private func request(_ body: @escaping (ZerodLink) async throws -> Void) {
        guard let link else { return Log.write("zerod isn't connected") }
        Task {
            do { try await body(link) } catch { Log.write("zerod refused: \(error.localizedDescription)") }
        }
    }

    private func linked() throws -> ZerodLink {
        guard let link else { throw AdapterError("Zero's daemon isn't running") }
        return link
    }

    // Agents.

    public func identity(of agent: String) -> AgentIdentity? { asks.last { $0.agent.name == agent }?.agent }

    /// Zero's own tasks as the workspace knows them now, by their agent name ("zerod-<id>"): the task's name, and what
    /// it runs on ("Opus 5.5"). The inbox's own record of them is only the label they asked under.
    @ObservationIgnored public var zeroTask: ((String) -> (name: String, runs: String)?)?

    /// Compiled once: the control bar names every dot on every redraw.
    private static let processName = try! NSRegularExpression(pattern: #"^(solo|claude|shell)-\d+$"#)

    /// The name to show for an agent: the user's own name for it, else the task's name (Zero's own), else the
    /// runtime's label, else the key.
    public func displayName(of agent: String) -> String {
        if let name = names[agent] { return name }
        if let task = zeroTask?(agent) { return task.name }
        let identity = identity(of: agent)
        if let label = identity?.label { return label }
        // A process number means nothing to the user; until the session's title is known, say where it works.
        if Self.processName.firstMatch(in: agent, range: NSRange(location: 0, length: (agent as NSString).length)) != nil,
           let folder = identity?.cwd.map({ ($0 as NSString).lastPathComponent }), !folder.isEmpty {
            return "Claude in \(folder)"
        }
        return agent
    }

    /// Names the user gave agents; they win over the runtime's labels, which change as a session's title does.
    public private(set) var names: [String: String] = UserDefaults.standard.dictionary(forKey: "agentNames") as? [String: String] ?? [:]

    /// Gives the agent a name of the user's; an empty one goes back to the runtime's label.
    public func rename(_ agent: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[agent] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(names, forKey: "agentNames")
    }

    /// True when zerod can deliver text into this agent's session.
    public func canMessage(_ agent: String) -> Bool { reachable.contains(agent) }

    /// True when removing the agent would also stop a process: Zero can reach it and it is running.
    public func canStop(_ name: String) -> Bool { reachable.contains(name) && !offline.contains(name) }

    public var spawners: [AgentAdapter] { adapters.filter(\.canSpawn) }

    /// Starts a new agent through an adapter and puts the first prompt in its timeline, so it is in the bar at once
    /// with what the user asked of it.
    public func spawn(prompt: String, adapter: AgentAdapter, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?,
                      settings: [String: String] = [:], started: (String) -> Void = { _ in }) async throws -> AgentIdentity {
        let link = try linked()
        var identity = try await adapter.spawn(prompt: prompt, target: target, runtime: runtime, model: model, settings: settings)
        identity.label = identity.label ?? Self.gist(of: prompt)
        var item = Ask(kind: .message, title: "Message", body: prompt, agent: identity)
        item.status = "sent"
        receive(.ask(try await link.create(item)))
        started(identity.name)
        return identity
    }

    /// The first line of a prompt, cut to five words, as an agent's label; nil when it is too short to name anything.
    nonisolated public static func gist(of prompt: String) -> String? { TaskName.gist(of: prompt) }

    public func switchModel(of agent: String, to model: SpawnChoice?, level: String?) async throws {
        try await linked().switchModel(of: agent, model: model?.id, effort: level)
    }

    /// Delivers the user's words to the agent's session, starting it again first when it is not running. The message
    /// joins the timeline once it has arrived; a failure throws and leaves nothing behind.
    public func message(_ text: String, to agent: String) async throws {
        try await linked().message(text, to: agent)
        // A slash command opens something in the agent's terminal, so that screen comes to Zero.
        if ClaudeCommands.isBuiltIn(text) { openScreen(of: agent) }
    }

    /// Shows the agent's terminal in Zero and keeps it fresh every second until closed.
    public func openScreen(of agent: String) {
        screenPolls[agent]?.cancel()
        screens[agent] = screens[agent] ?? ""
        screenPolls[agent] = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let link, let screen = try? await link.screen(of: agent), screens[agent] != nil { screens[agent] = screen }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func closeScreen(of agent: String) {
        screenPolls[agent]?.cancel()
        screenPolls[agent] = nil
        screens[agent] = nil
    }

    /// Keys into the agent's terminal; the screen updates from what comes straight back.
    public func press(_ bytes: [UInt8], on agent: String) {
        guard let link else { return }
        Task { [weak self] in
            if let screen = try? await link.press(bytes, on: agent), let self, screens[agent] != nil { screens[agent] = screen }
        }
    }

    /// Takes the agent out of the bar and, unless its process is already gone, stops it, keeping its session.
    public func closeAgent(_ name: String, stop: Bool = true) { request { try await $0.close(agent: name, stop: stop) } }

    // Asks.

    public func ask(_ id: String) -> Ask? { asks.first { $0.id == id } }
    public var open: [Ask] { asks.filter { !$0.state.isFinal } }

    /// `keepID` keeps the caller's id unless it is already taken.
    public func create(_ ask: Ask, keepID: Bool = false) {
        request { [weak self] link in
            let made = try await link.create(ask, keep: keepID)
            await MainActor.run { self?.receive(.ask(made)) }
        }
    }

    /// Picks option `index` (0-based).
    public func choose(_ id: String, option index: Int) {
        guard let ask = ask(id), ask.state == .waiting, index < ask.options.count else { return }
        stage(id, answer: ask.options[index], choice: index)
        request { try await $0.choose(id, option: index) }
    }

    /// Picks a text option and supplies the text: the answer reads "label: text", or just the label if empty.
    public func answer(_ id: String, option index: Int, text: String) {
        guard let ask = ask(id), ask.state == .waiting, index < ask.options.count else { return }
        let label = ask.options[index].trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stage(id, answer: trimmed.isEmpty ? label : "\(label): \(trimmed)", choice: index)
        request { try await $0.answer(id, option: index, text: text) }
    }

    /// Typed reply. On a run card, text can only be a decline reason.
    public func reply(_ id: String, text: String) {
        guard let ask = ask(id), ask.state == .waiting else { return }
        stage(id, answer: text, choice: nil)
        request { try await $0.reply(id, text: text) }
    }

    @discardableResult
    public func takeBack(_ id: String) -> Bool {
        guard let ask = ask(id), ask.state == .pending else { return false }
        update(id) { $0.state = .waiting; $0.answer = nil; $0.choice = nil }
        request { _ = try await $0.takeBack(id) }
        return true
    }

    public func dismiss(_ id: String) {
        guard let ask = ask(id), ask.state.isFinal else { return }
        asks.removeAll { $0.id == id }
        request { try await $0.dismiss(id) }
    }

    public func cancelRun(_ id: String) { request { try await $0.cancelRun(id) } }

    /// Takes back an open ask: the user answered it some other way. Nobody is told.
    public func withdraw(_ id: String, reason: String?) { request { try await $0.withdraw(id, reason: reason) } }

    /// Types an answer again into the session of an agent that asked with --async, after a failed delivery.
    public func deliverAnswer(_ id: String) { request { try await $0.deliver(id) } }

    /// Shown pending at once, as zerod will report it.
    private func stage(_ id: String, answer: String, choice: Int?) {
        update(id) { $0.state = .pending; $0.answer = answer; $0.choice = choice }
    }

    private func update(_ id: String, _ change: (inout Ask) -> Void) {
        guard let i = asks.firstIndex(where: { $0.id == id }) else { return }
        change(&asks[i])
        onChange?(asks[i])
    }
}

/// Starts agents as zerod sessions: in one of Zero's folders, as Claude Code, Codex or OpenCode. zerod runs them with
/// the CLI's own sign-in; Zero never handles provider credentials.
public struct ZerodSpawner: AgentAdapter {
    public let name = "Zero"
    public init() {}

    public func canReach(_ agent: AgentIdentity) -> Bool { agent.runtime == "zerod" }
    public func send(_ text: String, to agent: AgentIdentity) async throws { throw AdapterError("zerod delivers to its own sessions") }

    public var canSpawn: Bool { true }

    public func spawnTargets() async throws -> [SpawnChoice] {
        let home = NSHomeDirectory()
        return Projects.folders.map { path in
            SpawnChoice(id: path, name: Projects.name(of: path), detail: path.replacingOccurrences(of: home, with: "~"), icon: "folder", provider: name)
        }
    }

    public func spawnRuntimes() async throws -> [SpawnChoice] {
        [(Provider.claude, "Claude", "claude", "Anthropic"), (.codex, "Codex", "openai", "OpenAI"), (.opencode, "OpenCode", "opencode", "OpenCode")]
            .filter { AgentCommand.onPath($0.0.rawValue) }
            .map { SpawnChoice(id: "zerod:" + $0.0.rawValue, name: $0.1, detail: $0.0.rawValue, icon: $0.2, provider: $0.3) }
    }

    public func spawnModels(for runtime: SpawnChoice) -> [SpawnChoice] { SoloAdapter().spawnModels(for: runtime) }
    public func refreshModels() async -> Bool { await SoloAdapter().refreshModels() }

    public func spawn(prompt: String, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?, settings: [String: String]) async throws -> AgentIdentity {
        guard let provider = Provider(rawValue: String(runtime.id.dropFirst("zerod:".count))) else { throw AdapterError("zerod can't run \(runtime.name)") }
        let link = try ZerodLink()
        defer { link.close() }
        let session = try await link.start(provider: provider, cwd: target.id, prompt: prompt, model: model.flatMap { $0.id.isEmpty ? nil : $0.id },
                                           effort: settings["reasoning"].flatMap { $0.isEmpty ? nil : $0 })
        var identity = AgentIdentity(name: "zerod-" + session, host: AgentIdentity.thisHost, cwd: target.id)
        identity.runtime = "zerod"
        identity.ref = session
        return identity
    }
}
