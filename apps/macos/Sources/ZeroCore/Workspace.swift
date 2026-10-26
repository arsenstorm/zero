import Foundation
import Observation

/// The app's side of zerod: a live copy of its sessions for the workspace window, the requests the window makes,
/// and every approval brought into the inbox as a permission ask. Answered in the inbox or in the window, zerod
/// hears it once; settled anywhere else (another client, the session going offline), the ask is withdrawn.
@MainActor @Observable
public final class Workspace {
    public private(set) var mirror = ZerodMirror()
    public private(set) var connected = false
    /// Why the last request failed, for the window to show.
    public var lastError: String?

    public var conversations: [Conversation] { mirror.order.compactMap { mirror.conversations[$0] } }
    public func conversation(_ id: String) -> Conversation? { mirror.conversations[id] }

    /// Each provider's limits as last reported, from the session that heard last (zerod's own rule).
    public var usage: [(Provider, Usage)] {
        var latest: [(Provider, Usage)] = []
        for conversation in conversations {
            guard let usage = conversation.usage else { continue }
            latest.removeAll { $0.0 == conversation.provider }
            latest.append((conversation.provider, usage))
        }
        return latest
    }

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var link: ZerodLink?
    /// "session/approval" → the ask showing it.
    @ObservationIgnored private var asked: [String: String] = [:]

    /// zerod's side, through the link unless a test says otherwise.
    @ObservationIgnored var onDecide: (String, String, String) async throws -> Void = { _, _, _ in }
    @ObservationIgnored var onAnswer: (String, String, [String: [String]]) async throws -> Void = { _, _, _ in }
    /// Answers given in the inbox to the fields of an open question, until every field has one: "session/question" → field → answer.
    @ObservationIgnored private var collected: [String: [String: [String]]] = [:]
    @ObservationIgnored var onSend: (String, String) async throws -> Void = { _, _ in }
    @ObservationIgnored var onBehind: () -> Void = {}

    /// Chains onto the store's change handler: create it after anything that sets that handler outright.
    public init(store: Store) {
        self.store = store
        let earlier = store.onChange
        store.onChange = { [weak self] ask in
            earlier?(ask)
            self?.answered(ask)
        }
        onDecide = { [weak self] session, approval, choice in try await self?.link?.decide(session: session, approval: approval, choice: choice) }
        onAnswer = { [weak self] session, question, answers in try await self?.link?.answer(session: session, question: question, answers: answers) }
        onSend = { [weak self] session, text in try await self?.link?.send(session: session, text: text) }
        onBehind = { [weak self] in Task { try? await self?.link?.subscribe() } }
    }

    // The connection.

    /// Starts zerod if it isn't running, follows its sessions, and connects again whenever the connection drops.
    public func connect() async {
        while true {
            if link == nil, await ZerodLink.ensureRunning(), let fresh = try? ZerodLink() {
                fresh.onMessage = { [weak self] message in Task { @MainActor in self?.receive(message) } }
                fresh.onClose = { [weak self] in Task { @MainActor in self?.link = nil; self?.connected = false } }
                link = fresh
                if (try? await fresh.subscribe()) != nil { connected = true }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func receive(_ message: ZerodMirror.Message) {
        if !mirror.receive(message) { onBehind() }
        syncAsks()
        syncDots()
    }

    // What the window asks of zerod.

    public func start(provider: Provider, cwd: String, prompt: String, model: String?, effort: String?, permissions: Permissions = .auto) async -> String? {
        await attempt { try await $0.start(provider: provider, cwd: cwd, prompt: prompt, model: model, effort: effort, permissions: permissions) }
    }

    public func send(_ session: String, text: String, model: String? = nil, effort: String? = nil) async {
        _ = await attempt { try await $0.send(session: session, text: text, model: model, effort: effort) }
    }

    public func interrupt(_ session: String) async { _ = await attempt { try await $0.interrupt(session: session) } }
    public func stop(_ session: String) async { _ = await attempt { try await $0.stop(session: session) } }
    public func resume(_ session: String) async { _ = await attempt { try await $0.resume(session: session) } }

    /// Answered in the window, every field at once.
    public func answer(_ session: String, question: String, answers: [String: [String]]) async {
        _ = await attempt { try await $0.answer(session: session, question: question, answers: answers) }
    }

    /// Answered in the window: the inbox's ask goes once zerod reports the approval settled.
    public func decide(_ session: String, approval: String, choice: String) async {
        _ = await attempt { try await $0.decide(session: session, approval: approval, choice: choice) }
    }

    private func attempt<T>(_ request: (ZerodLink) async throws -> T) async -> T? {
        guard let link else { lastError = "Zero's daemon isn't running"; return nil }
        do {
            let result = try await request(link)
            lastError = nil
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // Approvals in the inbox.

    /// An ask for every open approval and every field of an open question, found again among the store's asks after
    /// a relaunch; withdrawn once what it asks is no longer open.
    private func syncAsks() {
        var open: Set<String> = []
        for conversation in conversations {
            for question in conversation.questions {
                for field in question.fields {
                    let request = question.id + "#" + field.id
                    let key = conversation.id + "/" + request
                    open.insert(key)
                    guard asked[key] == nil else { continue }
                    if let existing = store.asks.last(where: { $0.agent.ref == conversation.id && $0.request == request && !$0.state.isFinal }) {
                        asked[key] = existing.id
                    } else if field.secret {
                        // The inbox keeps every answer in its log; a secret is asked for in the workspace window instead.
                        var note = Ask(kind: .note, title: "Secret", body: "\(field.question) Answer it in Zero's workspace window.", agent: Self.agent(of: conversation))
                        note.status = "blocked"
                        _ = store.create(note)
                        asked[key] = ""
                    } else {
                        asked[key] = store.create(Self.ask(for: field, of: question, in: conversation)).id
                    }
                }
            }
            for approval in conversation.approvals {
                let key = conversation.id + "/" + approval.id
                open.insert(key)
                guard asked[key] == nil else { continue }
                if let existing = store.asks.last(where: { $0.agent.ref == conversation.id && $0.request == approval.id && !$0.state.isFinal }) {
                    asked[key] = existing.id
                } else {
                    asked[key] = store.create(Self.ask(for: approval, in: conversation)).id
                }
            }
        }
        for (key, id) in asked where !open.contains(key) {
            asked[key] = nil
            if !id.isEmpty { store.withdraw(id, reason: "Settled in zerod") }
        }
        collected = collected.filter { key, _ in open.contains { $0.hasPrefix(key + "#") } }
    }

    /// The bar shows a dot per agent from its latest note: each session posts one when its attention changes. A
    /// session waiting on Arsen already has its asks; an offline one leaves the bar until it works again.
    private func syncDots() {
        for conversation in conversations {
            let agent = Self.agent(of: conversation)
            let latest = store.asks.last { $0.agent.name == agent.name && $0.kind != .message }
            let dot: (String?, String)? = switch conversation.attention {
            case .working: (nil, "Working")
            case .done: ("done", "Answered")
            case .stuck: ("blocked", conversation.stalled ?? "Stuck")
            case .failed, .limited: ("blocked", conversation.failure?.message ?? (conversation.usage?.limited == true ? "Usage limit reached" : "Failed"))
            case .offline: ("closed", "Offline")
            case .needsYou, .idle, .starting: nil
            }
            guard let (status, body) = dot else { continue }
            if latest?.kind == .note, latest?.status == status, status != "blocked" || latest?.body == body { continue }
            if latest == nil, status == "closed" { continue }
            var note = Ask(kind: .note, title: Self.label(of: conversation), body: body, agent: agent)
            note.status = status
            _ = store.create(note)
        }
    }

    /// The identity the inbox and the bar know a session by.
    static func agent(of conversation: Conversation) -> AgentIdentity {
        var agent = AgentIdentity(name: "zerod-" + conversation.id, host: ProcessInfo.processInfo.hostName, cwd: conversation.cwd,
                                  label: label(of: conversation))
        agent.runtime = "zerod"
        agent.ref = conversation.id
        return agent
    }

    /// One field of a question as an inbox ask: its options, then "Something else…" where the agent takes free text.
    static func ask(for field: Field, of question: Question, in conversation: Conversation) -> Ask {
        var options = field.options.map(\.label)
        if field.other || options.isEmpty { options.append("Something else…") }
        let kind: AskKind = field.options.isEmpty ? .question : .choice
        var ask = Ask(kind: kind, title: field.question, options: kind == .question ? [] : options, agent: agent(of: conversation), ttl: 86400)
        let described = field.options.compactMap { option in option.description.map { "\(option.label): \($0)" } }
        if !described.isEmpty { ask.detail = described.joined(separator: "\n") }
        ask.request = question.id + "#" + field.id
        return ask
    }

    /// How an approval reads in the inbox: the provider's choices as its options, in its order.
    static func ask(for approval: Approval, in conversation: Conversation) -> Ask {
        let agent = agent(of: conversation)
        let files = approval.changes.map(\.path).joined(separator: "\n")
        var ask = Ask(kind: .permission, title: approval.title, body: approval.reason ?? "", options: approval.choices.map(\.label),
                      command: approval.command ?? (files.isEmpty ? nil : files), cwd: approval.cwd ?? conversation.cwd, agent: agent, ttl: 86400)
        ask.request = approval.id
        return ask
    }

    /// The name the user or its lead gave it, else the session's title, else what it was asked first, else the
    /// provider and its folder.
    public static func label(of conversation: Conversation) -> String {
        if let label = conversation.label, !label.isEmpty { return label }
        if let title = conversation.title, !title.isEmpty { return title }
        for item in conversation.items {
            if case let .user(text) = item.kind, let gist = Store.gist(of: text) { return gist }
        }
        return "\(conversation.provider.title) in \((conversation.cwd as NSString).lastPathComponent)"
    }

    /// One field answered in the inbox; the agent hears once every field of its question has an answer.
    private func answeredField(_ ask: Ask, session: String, request: String) {
        let parts = request.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, asked.removeValue(forKey: session + "/" + request) != nil,
              let question = conversation(session)?.questions.first(where: { $0.id == parts[0] }),
              let field = question.fields.first(where: { $0.id == parts[1] }) else { return }
        let labels = field.options.map(\.label)
        let words: String? = {
            guard let answer = ask.answer else { return nil }
            if let choice = ask.choice, labels.indices.contains(choice) { return labels[choice] }
            // "Something else…" answers "Something else: their words"; a typed reply is the words alone.
            if let range = answer.range(of: "Something else: ") { return String(answer[range.upperBound...]) }
            return answer
        }()
        guard let words, !words.isEmpty else { return }
        let key = session + "/" + question.id
        collected[key, default: [:]][field.id] = [words]
        guard let answers = collected[key], question.fields.allSatisfy({ answers[$0.id] != nil }) else { return }
        collected[key] = nil
        let send = onAnswer
        Task { [weak self] in
            do { try await send(session, question.id, answers) } catch { self?.lastError = error.localizedDescription }
        }
    }

    /// An ask of ours was answered in the inbox: its option is the provider's choice. A typed reply denies, and the
    /// words go to the agent, so it knows what to do instead.
    private func answered(_ ask: Ask) {
        guard ask.agent.runtime == "zerod", let session = ask.agent.ref, let request = ask.request,
              [.answered, .declined].contains(ask.state), ask.status != "withdrawn" else { return }
        if request.contains("#") { return answeredField(ask, session: session, request: request) }
        let key = session + "/" + request
        guard asked.removeValue(forKey: key) != nil, let approval = conversation(session)?.approvals.first(where: { $0.id == request }) else { return }
        let typed = ask.choice == nil ? ask.answer : nil
        guard let choice = ask.choice.flatMap({ approval.choices.indices.contains($0) ? approval.choices[$0] : nil })
                ?? approval.choices.first(where: { $0.kind == .deny }) ?? approval.choices.first(where: { $0.kind == .stop }) else { return }
        let (decide, send) = (onDecide, onSend)
        Task { [weak self] in
            do {
                try await decide(session, request, choice.id)
                if let typed, !typed.isEmpty { try await send(session, typed) }
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }
}
