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

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var link: ZerodLink?
    /// "session/approval" → the ask showing it.
    @ObservationIgnored private var asked: [String: String] = [:]

    /// zerod's side, through the link unless a test says otherwise.
    @ObservationIgnored var onDecide: (String, String, String) async throws -> Void = { _, _, _ in }
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
    }

    // What the window asks of zerod.

    public func start(provider: Provider, cwd: String, prompt: String, model: String?, effort: String?) async -> String? {
        await attempt { try await $0.start(provider: provider, cwd: cwd, prompt: prompt, model: model, effort: effort) }
    }

    public func send(_ session: String, text: String, model: String? = nil, effort: String? = nil) async {
        _ = await attempt { try await $0.send(session: session, text: text, model: model, effort: effort) }
    }

    public func interrupt(_ session: String) async { _ = await attempt { try await $0.interrupt(session: session) } }
    public func stop(_ session: String) async { _ = await attempt { try await $0.stop(session: session) } }
    public func resume(_ session: String) async { _ = await attempt { try await $0.resume(session: session) } }

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

    /// An ask for every open approval, found again among the store's asks after a relaunch; withdrawn once its
    /// approval is no longer open.
    private func syncAsks() {
        var open: Set<String> = []
        for conversation in conversations {
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
            store.withdraw(id, reason: "Settled in zerod")
        }
    }

    /// How an approval reads in the inbox: the provider's choices as its options, in its order.
    static func ask(for approval: Approval, in conversation: Conversation) -> Ask {
        var agent = AgentIdentity(name: "zerod-" + conversation.id, host: ProcessInfo.processInfo.hostName, cwd: conversation.cwd,
                                  label: label(of: conversation))
        agent.runtime = "zerod"
        agent.ref = conversation.id
        let files = approval.changes.map(\.path).joined(separator: "\n")
        var ask = Ask(kind: .permission, title: approval.title, body: approval.reason ?? "", options: approval.choices.map(\.label),
                      command: approval.command ?? (files.isEmpty ? nil : files), cwd: approval.cwd ?? conversation.cwd, agent: agent, ttl: 86400)
        ask.request = approval.id
        return ask
    }

    /// The session's title, else what it was asked first, else the provider and its folder.
    public static func label(of conversation: Conversation) -> String {
        if let title = conversation.title, !title.isEmpty { return title }
        for item in conversation.items {
            if case let .user(text) = item.kind, let gist = Store.gist(of: text) { return gist }
        }
        return "\(conversation.provider.title) in \((conversation.cwd as NSString).lastPathComponent)"
    }

    /// An ask of ours was answered in the inbox: its option is the provider's choice. A typed reply denies, and the
    /// words go to the agent, so it knows what to do instead.
    private func answered(_ ask: Ask) {
        guard ask.agent.runtime == "zerod", let session = ask.agent.ref, let request = ask.request,
              [.answered, .declined].contains(ask.state), ask.status != "withdrawn" else { return }
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
