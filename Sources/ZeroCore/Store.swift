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

    /// The name to show for an agent: the runtime's label when it has one, else the key.
    public func displayName(of agent: String) -> String { identity(of: agent)?.label ?? agent }

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
            // Solo's own session titles are not in its API, so the label is the gist of what Arsen asked.
            identity.label = Self.gist(of: prompt) ?? "\(runtime.name) \(identity.soloProcessID.map(String.init) ?? "")".trimmingCharacters(in: .whitespaces)
            rebind(provisional.name, to: identity)
            update(message.id) { $0.status = "sent" }
            if let sent = ask(message.id) { log(sent) }
            watchReply(from: identity, to: prompt, via: adapter)
            Task { await relabel(identity) }
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
    public func message(_ text: String, to agent: String) async {
        guard let identity = identity(of: agent) else { return }
        var item = Ask(kind: .message, title: "Message", body: text, agent: identity)
        item.status = "sending"
        let created = create(item)
        do {
            guard let adapter = adapters.first(where: { $0.canReach(identity) }) else { throw AdapterError("No way to reach \(agent)") }
            try await adapter.send(text, to: identity)
            update(created.id) { $0.status = "sent" }
            watchReply(from: identity, to: text, via: adapter)
        } catch {
            update(created.id) { $0.status = "failed: \(error.localizedDescription)" }
        }
        if let final = ask(created.id) { log(final) }
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
