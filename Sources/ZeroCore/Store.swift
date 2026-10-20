import Foundation
import Observation

/// All asks, oldest first, with their state machine:
/// waiting → pending (2 s take-back window) → answered | declined, or → running → answered for `run`.
/// waiting → expired on timeout. Every final transition is appended to the JSONL log.
@MainActor @Observable
public final class Store {
    public private(set) var asks: [Ask] = []

    @ObservationIgnored public var takeBackDelay: TimeInterval = 2
    /// Used when an ask arrives without its own expiry (the CLI sends expiresAt == createdAt then).
    @ObservationIgnored public var defaultTTL: TimeInterval = 3600
    @ObservationIgnored public var onCreate: ((Ask) -> Void)?
    @ObservationIgnored public var onChange: ((Ask) -> Void)?
    @ObservationIgnored public var onOutput: ((Ask, String) -> Void)?

    /// Agents whose session is not running, by the adapters' last look (every few seconds from the app).
    public private(set) var offline: Set<String> = []

    public func refreshLiveness() async {
        var identities: [String: AgentIdentity] = [:]
        for ask in asks where ask.state != .expired { identities[ask.agent.name] = ask.agent }
        var gone: Set<String> = []
        for adapter in adapters { gone.formUnion(await adapter.offline(among: Array(identities.values))) }
        if gone != offline { offline = gone }
        // Titles arrive on their own schedule; with the session known this is a local file read.
        for identity in identities.values where identity.session != nil { await relabel(identity) }
    }

    /// Agents whose terminal screen is open in Zero (after a slash command), with the latest rendering.
    public private(set) var screens: [String: String] = [:]
    @ObservationIgnored private var screenPolls: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var processes: [String: Process] = [:]
    @ObservationIgnored private let logURL: URL?
    @ObservationIgnored public let adapters: [AgentAdapter]

    public init(logURL: URL? = Paths.log, adapters: [AgentAdapter] = [SoloAdapter()]) {
        self.logURL = logURL
        self.adapters = adapters
        load()
    }

    public func identity(of agent: String) -> AgentIdentity? { asks.last { $0.agent.name == agent }?.agent }

    /// The name to show for an agent: Arsen's own name for it, else the runtime's label, else the key.
    public func displayName(of agent: String) -> String { names[agent] ?? identity(of: agent)?.label ?? agent }

    /// Names Arsen gave agents; they win over the runtime's labels, which change as a session's title does.
    public private(set) var names: [String: String] = UserDefaults.standard.dictionary(forKey: "agentNames") as? [String: String] ?? [:]

    /// Gives the agent a name of Arsen's; an empty one goes back to the runtime's label.
    public func rename(_ agent: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[agent] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(names, forKey: "agentNames")
    }

    /// True when some adapter can deliver text into this agent's session.
    public func canMessage(_ agent: String) -> Bool {
        guard let identity = identity(of: agent) else { return false }
        return adapters.contains { $0.canReach(identity) }
    }

    public var spawners: [AgentAdapter] { adapters.filter(\.canSpawn) }

    /// Starts a new agent through an adapter and records the first prompt in its timeline, so it appears in
    /// the bar at once with what Arsen asked of it.
    /// `started` gets the provisional agent's name at once: it is in the bar with a blue dot and the prompt
    /// before Solo has answered, then rebound to the real identity.
    public func spawn(prompt: String, adapter: AgentAdapter, target: SpawnChoice, runtime: SpawnChoice, model: SpawnChoice?,
                      settings: [String: String] = [:], started: (String) -> Void = { _ in }) async throws -> AgentIdentity {
        let provisional = AgentIdentity(name: "starting-" + Ask.newID(), host: ProcessInfo.processInfo.hostName, label: "Starting \(runtime.name)…")
        var item = Ask(kind: .message, title: "Message", body: prompt, agent: provisional)
        item.status = "starting"
        let message = create(item)
        started(provisional.name)
        do {
            var identity = try await adapter.spawn(prompt: prompt, target: target, runtime: runtime, model: model, settings: settings)
            // The gist of the prompt names it until the runtime has titled the session itself.
            identity.label = Self.gist(of: prompt) ?? "\(runtime.name) \(identity.soloProcessID.map(String.init) ?? "")".trimmingCharacters(in: .whitespaces)
            rebind(provisional.name, to: identity)
            update(message.id) { $0.status = "sent" }
            if let sent = ask(message.id) { log(sent) }
            watchReply(from: identity, to: prompt, via: adapter)
            Task { [weak self] in
                // The session id makes the agent resumable and titled; it exists once the first prompt is taken.
                guard let session = await adapter.session(for: identity, firstPrompt: prompt), let self else { return }
                var known = identity
                known.session = session
                rebind(identity.name, to: known)
                await relabel(known)
            }
            return identity
        } catch {
            // Gone from everywhere: expired items never show, and the log's last line for it says so.
            update(message.id) { $0.state = .expired; $0.answeredAt = Date() }
            if let gone = ask(message.id) { log(gone) }
            throw error
        }
    }

    /// The first line of a prompt, cut to five words, as an agent's label; nil when it is too short to name anything.
    nonisolated public static func gist(of prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(["'"])) }.filter { !$0.isEmpty }
        guard words.count >= 3 else { return nil }
        let kept = words.prefix(5).joined(separator: " ")
        return kept.prefix(1).uppercased() + kept.dropFirst() + (words.count > 5 ? "…" : "")
    }

    /// Moves everything recorded under a provisional agent to the identity the adapter reported.
    private func rebind(_ provisional: String, to identity: AgentIdentity) {
        for i in asks.indices where asks[i].agent.name == provisional {
            asks[i].agent = identity
            log(asks[i])
            onChange?(asks[i])
        }
    }

    /// Takes the runtime's current name for the agent as its label (logged on its latest item, which is the
    /// one `identity(of:)` reads back after a relaunch).
    public func relabel(_ identity: AgentIdentity) async {
        guard let adapter = adapters.first(where: { $0.canReach(identity) }),
              let label = await adapter.displayName(for: identity), label != self.identity(of: identity.name)?.label else { return }
        for i in asks.indices where asks[i].agent.name == identity.name { asks[i].agent.label = label }
        if let last = asks.last(where: { $0.agent.name == identity.name }) { log(last) }
    }

    public func switchModel(of agent: String, to model: SpawnChoice?, level: String?) async throws {
        guard let identity = identity(of: agent), let adapter = adapters.first(where: { $0.canReach(identity) }) else { throw AdapterError("No way to reach \(agent)") }
        try await adapter.switchModel(of: identity, to: model, level: level)
    }

    /// Shows the agent's terminal in Zero and keeps it fresh every second until closed.
    public func openScreen(of agent: String) {
        guard let identity = identity(of: agent), let adapter = adapters.first(where: { $0.canReach(identity) }) else { return }
        screenPolls[agent]?.cancel()
        screens[agent] = screens[agent] ?? ""
        screenPolls[agent] = Task { [weak self] in
            while !Task.isCancelled {
                if let screen = await adapter.screen(of: identity), let self, screens[agent] != nil { screens[agent] = screen }
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
        guard let identity = identity(of: agent), let adapter = adapters.first(where: { $0.canReach(identity) }) else { return }
        Task { [weak self] in
            if let screen = try? await adapter.press(bytes, on: identity), let self, screens[agent] != nil { screens[agent] = screen }
        }
    }

    /// The agent's answer to something Arsen sent comes back as a note from it, so the exchange reads in Zero.
    private func watchReply(from identity: AgentIdentity, to text: String, via adapter: AgentAdapter) {
        Task { [weak self] in
            guard let reply = await adapter.reply(from: identity, to: text), let self else { return }
            var note = Ask(kind: .note, title: "Replied", body: reply, agent: identity, ttl: 7 * 86400)
            note.status = "done"
            _ = create(note)
            // Solo titles the session a little after its first answer, so look once now and once later.
            await relabel(identity)
            try? await Task.sleep(for: .seconds(30))
            await relabel(identity)
        }
    }

    /// Sends Arsen's text into the agent's session and records it in the timeline as sent or failed.
    /// Delivers Arsen's words to the agent's session, starting it again first when it is not running. The
    /// message joins the timeline only once it has arrived; a failure throws and leaves nothing behind.
    public func message(_ text: String, to agent: String) async throws {
        guard var identity = identity(of: agent) else { throw AdapterError("Zero doesn't know \(agent)") }
        guard let adapter = adapters.first(where: { $0.canReach(identity) }) else { throw AdapterError("No way to reach \(agent)") }
        // An agent from before sessions were recorded: its session is the one that began with its first prompt.
        if identity.session == nil,
           let first = asks.first(where: { $0.agent.name == agent && $0.kind == .message })?.body,
           let session = await adapter.findSession(for: identity, firstPrompt: first) {
            identity.session = session
            rebind(agent, to: identity)
        }
        let connected = try await adapter.connect(identity)
        if connected != identity { rebind(agent, to: connected); identity = connected }
        offline.remove(agent)
        try await adapter.send(text, to: identity)
        var item = Ask(kind: .message, title: "Message", body: text, agent: identity)
        item.status = "sent"
        _ = create(item)
        // A slash command opens something in the agent's terminal, so that screen comes to Zero; a message
        // gets an answer, which is read back when it lands.
        if ClaudeCommands.isBuiltIn(text) { openScreen(of: agent) } else { watchReply(from: identity, to: text, via: adapter) }
    }

    public func ask(_ id: String) -> Ask? { asks.first { $0.id == id } }
    public var open: [Ask] { asks.filter { !$0.state.isFinal } }

    /// `keepID` keeps the caller's id (a drop client names its own files by it) unless it is already taken.
    public func create(_ incoming: Ask, keepID: Bool = false) -> Ask {
        var ask = incoming
        if !keepID || incoming.id.isEmpty || asks.contains(where: { $0.id == incoming.id }) { ask.id = Ask.newID() }
        ask.state = .waiting
        let requested = incoming.expiresAt.timeIntervalSince(incoming.createdAt)
        let ttl = requested > 0 ? requested : defaultTTL
        ask.createdAt = Date()
        ask.expiresAt = ask.createdAt.addingTimeInterval(ttl)
        if ask.kind == .note || ask.kind == .message {
            ask.state = .answered
            ask.answeredAt = ask.createdAt
        }
        // What Zero has learned about the agent (its process, session, label) carries into every later item,
        // whether it was made from an older copy of the identity or came from the CLI with a bare name.
        // An agent Zero started is "claude-120" to Zero but calls the CLI as "solo-120": same process, same agent.
        if identity(of: ask.agent.name) == nil, let pid = ask.agent.soloProcessID,
           let owner = asks.last(where: { $0.agent.soloProcessID == pid })?.agent.name {
            ask.agent.name = owner
        }
        if let known = identity(of: ask.agent.name) {
            ask.agent.soloProcessID = ask.agent.soloProcessID ?? known.soloProcessID
            ask.agent.soloProjectID = ask.agent.soloProjectID ?? known.soloProjectID
            ask.agent.session = ask.agent.session ?? known.session
            ask.agent.label = ask.agent.label ?? known.label
        }
        asks.append(ask)
        log(ask)
        onCreate?(ask)
        guard ask.kind != .note, ask.kind != .message else { return ask }
        let id = ask.id
        timers["expire-" + id] = Task {
            try? await Task.sleep(for: .seconds(ttl))
            guard !Task.isCancelled else { return }
            self.expire(id)
        }
        return ask
    }

    /// Picks option `index` (0-based). The second option of approve/run means decline.
    public func choose(_ id: String, option index: Int) {
        guard let ask = ask(id), ask.state == .waiting, index < ask.options.count else { return }
        stage(id, answer: ask.options[index], declined: declines(ask, index), choice: index)
    }

    /// Picks a text option and supplies the text: the answer reads "label: text", or just the label if empty.
    public func answer(_ id: String, option index: Int, text: String) {
        guard let ask = ask(id), ask.state == .waiting, index < ask.options.count else { return }
        let label = ask.options[index].trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stage(id, answer: trimmed.isEmpty ? label : "\(label): \(trimmed)", declined: declines(ask, index), choice: index)
    }

    /// For approve and run, every option after the first is a decline, with or without a reason.
    private func declines(_ ask: Ask, _ index: Int) -> Bool { (ask.kind == .approve || ask.kind == .run) && index >= 1 }

    /// Typed reply. On a run card, text can only be a decline reason.
    public func reply(_ id: String, text: String) {
        guard let ask = ask(id), ask.state == .waiting else { return }
        stage(id, answer: text, declined: ask.kind == .run)
    }

    @discardableResult
    public func takeBack(_ id: String) -> Bool {
        guard let ask = ask(id), ask.state == .pending else { return false }
        timers[id]?.cancel()
        timers[id] = nil
        update(id) { $0.state = .waiting; $0.answer = nil; $0.choice = nil }
        return true
    }

    public func dismiss(_ id: String) {
        guard let ask = ask(id), ask.state.isFinal else { return }
        asks.removeAll { $0.id == id }
    }

    public func cancelRun(_ id: String) { processes[id]?.terminate() }

    /// Arsen closed the agent: a closing note goes in its timeline, so its dot leaves and the close survives
    /// a relaunch. Anything the agent says afterwards reopens it.
    public func closeAgent(_ name: String) {
        guard let last = asks.last(where: { $0.agent.name == name }) else { return }
        var note = Ask(kind: .note, title: "Closed", body: "Closed by Arsen", agent: last.agent)
        note.status = "closed"
        _ = create(note)
    }

    public func appendOutput(_ id: String, _ chunk: String) {
        guard let i = asks.firstIndex(where: { $0.id == id }) else { return }
        asks[i].output += chunk
        onOutput?(asks[i], chunk)
    }

    private func stage(_ id: String, answer: String, declined: Bool, choice: Int? = nil) {
        update(id) { $0.state = .pending; $0.answer = answer; $0.choice = choice }
        timers[id] = Task {
            try? await Task.sleep(for: .seconds(takeBackDelay))
            guard !Task.isCancelled else { return }
            self.commit(id, declined: declined)
        }
    }

    private func commit(_ id: String, declined: Bool) {
        timers[id] = nil
        guard let ask = ask(id), ask.state == .pending else { return }
        if declined { finish(id, state: .declined) } else if ask.kind == .run { run(ask) } else { finish(id, state: .answered) }
    }

    private func expire(_ id: String) {
        guard let ask = ask(id), ask.state == .waiting else { return }
        finish(id, state: .expired)
    }

    private func finish(_ id: String, state: AskState, exitCode: Int32? = nil) {
        timers["expire-" + id]?.cancel()
        timers["expire-" + id] = nil
        update(id) {
            $0.state = state
            $0.answeredAt = Date()
            if let exitCode { $0.exitCode = exitCode }
        }
        if let ask = ask(id) { log(ask) }
    }

    private func update(_ id: String, _ change: (inout Ask) -> Void) {
        guard let i = asks.firstIndex(where: { $0.id == id }) else { return }
        change(&asks[i])
        onChange?(asks[i])
    }

    // ponytail: zsh -lic so rbenv/PATH from .zshrc apply; no pty, so anything that insists on a tty fails. Add a pty if a command needs one.
    private func run(_ ask: Ask) {
        let id = ask.id
        update(id) { $0.state = .running }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", ask.command ?? ""]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["ZERO_ASK_ID"] = id
        process.environment = env
        if let cwd = ask.cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.appendOutput(id, text) }
        }
        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let status = proc.terminationStatus
            Task { @MainActor in
                if !rest.isEmpty { self.appendOutput(id, String(decoding: rest, as: UTF8.self)) }
                self.processes[id] = nil
                self.finish(id, state: .answered, exitCode: status)
            }
        }
        do {
            try process.run()
            processes[id] = process
        } catch {
            appendOutput(id, "zero: \(error.localizedDescription)\n")
            finish(id, state: .answered, exitCode: 127)
        }
    }

    private func log(_ ask: Ask) {
        guard let url = logURL, let data = try? jsonEncoder.encode(ask) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    /// Replays the log: latest line per id wins; anything left open when the app last quit is expired now.
    private func load() {
        guard let url = logURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var byID: [String: Ask] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") {
            guard let ask = try? jsonDecoder.decode(Ask.self, from: Data(line.utf8)) else { continue }
            if byID[ask.id] == nil { order.append(ask.id) }
            byID[ask.id] = ask
        }
        // Keep the last day, plus each agent's latest item so its dot and state come back after a relaunch.
        let cutoff = Date().addingTimeInterval(-86400)
        let all = order.compactMap { byID[$0] }
        var latestPerAgent: [String: String] = [:]
        for ask in all { latestPerAgent[ask.agent.name] = ask.id }
        asks = all.compactMap { ask in
            var ask = ask
            if !ask.state.isFinal {
                ask.state = .expired
                ask.answeredAt = Date()
                log(ask)
                return ask
            }
            let recent = (ask.answeredAt ?? ask.createdAt) > cutoff
            return recent || latestPerAgent[ask.agent.name] == ask.id ? ask : nil
        }
    }
}
