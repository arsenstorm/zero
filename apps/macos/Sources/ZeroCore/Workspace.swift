import Foundation
import Observation

/// The app's side of zerod's sessions: a live copy of them for the workspace window, and the requests the window makes.
/// zerod itself brings their approvals and questions into the inbox (crates/zerod/src/bridge.rs).
@MainActor @Observable
public final class Workspace {
    public private(set) var mirror = ZerodMirror()
    public private(set) var connected = false
    /// Why the last request failed, for the window to show.
    public var lastError: String?

    /// Every task at once (crates/zerod/src/board.rs), while the window shows it.
    public private(set) var board: [BoardRow] = []

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

    @ObservationIgnored private var link: ZerodLink?
    /// Asks for fresh snapshots, unless a test says otherwise.
    @ObservationIgnored var onBehind: () -> Void = {}

    public init() {
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
    }

    // What the window asks of zerod.

    public func refreshBoard() async {
        guard let rows = try? await link?.board() else { return }
        if rows != board { board = rows }
    }

    public func start(provider: Provider, cwd: String, prompt: String, model: String?, effort: String?, permissions: Permissions = .auto) async -> String? {
        await attempt { try await $0.start(provider: provider, cwd: cwd, prompt: prompt, model: model, effort: effort, permissions: permissions) }
    }

    public func send(_ session: String, text: String, model: String? = nil, effort: String? = nil) async {
        _ = await attempt { try await $0.send(session: session, text: text, model: model, effort: effort) }
    }

    public func interrupt(_ session: String) async { _ = await attempt { try await $0.interrupt(session: session) } }
    public func stop(_ session: String) async { _ = await attempt { try await $0.stop(session: session) } }
    public func resume(_ session: String) async { _ = await attempt { try await $0.resume(session: session) } }

    /// Moves the task to another provider; true once it's there.
    public func switchProvider(_ session: String, to provider: Provider, model: String? = nil, effort: String? = nil) async -> Bool {
        await attempt { try await $0.switchProvider(session: session, to: provider, model: model, effort: effort) } != nil
    }

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
}
