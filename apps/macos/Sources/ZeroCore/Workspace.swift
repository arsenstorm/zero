import Foundation
import Observation

/// The app's side of zerod's sessions: a live copy of them for the workspace window, and the requests the window makes.
/// zerod itself brings their approvals and questions into the inbox (crates/zerod/src/bridge.rs).
/// One task's whole conversation, observed on its own: a word streamed into it redraws the views showing this task,
/// not every view that lists tasks.
@MainActor @Observable
public final class LiveConversation {
    public fileprivate(set) var conversation: Conversation
    /// Its items not loaded, before those that are.
    public fileprivate(set) var earlier: Int
    init(_ conversation: Conversation, earlier: Int) { self.conversation = conversation; self.earlier = earlier }
}

@MainActor @Observable
public final class Workspace {
    /// zerod's sessions as its protocol keeps them (snapshots, then changes in order). Views read the roster and each
    /// task's live object instead, so a change redraws only what it touches.
    @ObservationIgnored private var mirror = ZerodMirror()
    /// Each task without its conversation (its first message of yours kept, for its name): what lists, the sidebar and
    /// the title bar need. It changes when a task's name, state or usage does, not with every word streamed.
    public private(set) var roster: [String: Conversation] = [:]
    public private(set) var order: [String] = []
    @ObservationIgnored private var lives: [String: LiveConversation] = [:]
    public private(set) var connected = false
    /// Why the last request failed, for the window to show.
    public var lastError: String?

    /// GitHub and Linear: their settings and views, and what each view showed last ("github/<view>"), or why not.
    public private(set) var integrations: IntegrationState? { didSet { if integrations?.slack != oldValue?.slack { Slack.shared.apply(integrations?.slack) } } }
    public private(set) var items: [String: [IntegrationItem]] = [:]
    public private(set) var itemErrors: [String: String] = [:]
    /// Bumped whenever zerod says a scratchpad changed: what shows pads reads them again.
    public private(set) var padsVersion = 0
    /// The scratchpads and their folders, as zerod last listed them.
    public private(set) var pads: [PadSummary] = []
    public private(set) var padFolders: [String] = []
    /// The loops (named instructions, zerod's loops.rs), as zerod last listed them; bumped when one changes.
    public private(set) var loopsVersion = 0
    public private(set) var loops: [ZerodLink.Loop] = []
    /// What sessions follow (pull requests, issues, threads; zerod's following.rs), as zerod last listed them; bumped
    /// when a follow is made, taken back, or read again.
    public private(set) var followingVersion = 0
    public private(set) var followed: [ZerodLink.Followed] = []
    /// The user's workspaces (zerod's workspaces.rs), Zero first, and the one the window shows. Every workspace's
    /// tasks run alike; this only says which are shown.
    public private(set) var workspaces: [ZerodLink.Workspace] = [ZerodLink.Workspace(id: "zero", name: "Zero")]
    public private(set) var workspacesVersion = 0
    public var current: String = UserDefaults.standard.string(forKey: "currentWorkspace") ?? "zero" {
        didSet { UserDefaults.standard.set(current, forKey: "currentWorkspace") }
    }
    public var currentWorkspace: ZerodLink.Workspace { workspaces.first { $0.id == current } ?? workspaces[0] }

    /// Views being fetched again, while what they last showed stays up.
    public private(set) var refreshing: Set<String> = []

    /// Every task at once (crates/zerod/src/board.rs), while the window shows it, Replied rows settled (below).
    public private(set) var board: [BoardRow] = []
    private var rawBoard: [BoardRow] = []

    /// A task that replied stays Replied until the user has looked at it, and settles to Idle this long after: an answer
    /// read a while ago is nothing new, one not yet read is, however long ago it came.
    public static let settleAfter: TimeInterval = 5 * 60
    /// The latest answer of each task the user looked at, and when; kept across launches.
    @ObservationIgnored private var seen: [String: (answer: String, at: Date)] = Workspace.loadSeen()

    /// The user is looking at this task now: its latest answer is seen.
    public func markSeen(_ id: String) {
        guard let answer = latestAnswer(id) else { return }
        if let kept = seen[id], kept.answer == answer { return }
        seen[id] = (answer, Date())
        Self.saveSeen(seen)
        resettle()
    }

    /// The settled rows again: a minute on, a seen answer may have settled.
    func resettle() {
        let rows = rawBoard.map { row in
            var row = row
            row.state = Self.settled(row.state, session: row.session, answer: latestAnswer(row.session), seen: seen, now: Date())
            return row
        }
        if rows != board {
            for row in rows where board.first(where: { $0.session == row.session })?.state != row.state {
                Log.write("task \(row.session) \(row.state.rawValue): \(row.task)")
            }
            board = rows
        }
    }

    nonisolated static func settled(_ state: BoardRow.State, session: String, answer: String?, seen: [String: (answer: String, at: Date)], now: Date) -> BoardRow.State {
        guard state == .answered, let kept = seen[session], kept.answer == answer, now.timeIntervalSince(kept.at) >= settleAfter else { return state }
        return .idle
    }

    private func latestAnswer(_ id: String) -> String? {
        (lives[id]?.conversation ?? roster[id])?.items.last { if case .agent(_, true) = $0.kind { true } else { false } }?.id
    }

    private static let seenKey = "seenAnswers"
    private static func loadSeen() -> [String: (answer: String, at: Date)] {
        let stored = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: [String: Any]] ?? [:]
        return stored.compactMapValues { entry in
            guard let answer = entry["answer"] as? String, let at = entry["at"] as? Double else { return nil }
            return (answer, Date(timeIntervalSince1970: at))
        }
    }
    private static func saveSeen(_ seen: [String: (answer: String, at: Date)]) {
        UserDefaults.standard.set(seen.mapValues { ["answer": $0.answer, "at": $0.at.timeIntervalSince1970] as [String: Any] }, forKey: seenKey)
    }

    public var conversations: [Conversation] { order.compactMap { roster[$0] } }
    /// A task as the roster has it: everything but its conversation.
    public func conversation(_ id: String) -> Conversation? { roster[id] }

    /// A task's whole conversation, observed on its own.
    public func live(_ id: String) -> LiveConversation? {
        if let kept = lives[id] { return kept }
        guard let conversation = mirror.conversations[id] else { return nil }
        let live = LiveConversation(conversation, earlier: mirror.earlier[id] ?? 0)
        lives[id] = live
        return live
    }

    /// The roster entry and the live object brought up to the mirror for one task.
    private func sync(_ id: String) {
        guard let full = mirror.conversations[id] else {
            roster[id] = nil
            order.removeAll { $0 == id }
            lives[id] = nil
            return
        }
        if !order.contains(id) { order = mirror.order.filter { mirror.conversations[$0] != nil } }
        // Its first message of yours (its name) and its latest answer (how its last turn ended: its state).
        var light = full
        let first = full.items.first { if case .user = $0.kind { true } else { false } } ?? roster[id]?.items.first { if case .user = $0.kind { true } else { false } }
        // Only once its turn has ended, so words streaming into it don't change the roster; nor does the turn's diff.
        let isAnswer = { (item: ConversationItem) in if case .agent(_, true) = item.kind { true } else { false } }
        let answer = full.turn == nil ? full.items.last(where: isAnswer) : roster[id]?.items.last(where: isAnswer)
        light.items = [first, answer].compactMap { $0 }
        light.diff = nil
        light.seq = 0
        if roster[id] != light { roster[id] = light }
        if let live = lives[id] {
            live.conversation = full
            let earlier = mirror.earlier[id] ?? 0
            if live.earlier != earlier { live.earlier = earlier }
        }
    }

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
        // A seen answer settles with time, not with an event: look again each minute.
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.resettle()
            }
        }
    }

    // The connection.

    /// Starts zerod if it isn't running, follows its sessions, and connects again whenever the connection drops.
    public func connect() async {
        while true {
            if link == nil, await ZerodLink.ensureRunning(), let fresh = try? ZerodLink() {
                fresh.onMessage = { [weak self] message in Task { @MainActor in self?.receive(message) } }
                fresh.onFeed = { [weak self] feed in
                    Task { @MainActor in
                        switch feed {
                        case let .board(rows): if let self, self.rawBoard != rows { self.rawBoard = rows; self.resettle() }
                        case .pads: self?.padsVersion += 1
                        case .loops: self?.loopsVersion += 1
                        case .following: self?.followingVersion += 1
                        case .workspaces: self?.workspacesVersion += 1; Task { await self?.loadWorkspaces() }
                        }
                    }
                }
                fresh.onClose = { [weak self] in Task { @MainActor in self?.link = nil; self?.connected = false; Log.write("zerod connection closed") } }
                link = fresh
                if (try? await fresh.subscribe()) != nil { connected = true; await loadWorkspaces(); await loadIntegrations() }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func receive(_ message: ZerodMirror.Message) {
        if !mirror.receive(message) { onBehind() }
        switch message {
        case let .session(conversation): sync(conversation.id)
        case let .change(event): soon(event.session)
        case let .earlier(session, _): sync(session)
        }
    }

    /// Tasks changed since the views last caught up.
    @ObservationIgnored private var stale: Set<String> = []
    @ObservationIgnored private var catchingUp = false

    /// The views catch up with a task at most about 30 times a second: an answer streams in at 80 words a second,
    /// and drawing each one fell behind, so the text showed up halfway through. The mirror has every change at once.
    private func soon(_ id: String) {
        stale.insert(id)
        guard !catchingUp else { return }
        catchingUp = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(33))
            catchingUp = false
            let ids = stale
            stale = []
            ids.forEach(sync)
        }
    }

    // What the window asks of zerod.

    /// An issue's (or pull request's) task, started from its view's template if it has none; the view is fetched
    /// again so its row shows the task.
    public func startTask(_ integration: String, view: String, item: IntegrationItem) async -> StartedTask? {
        let started = await attempt { try await $0.startTask(integration, view: view, item: item) }
        if started != nil { await refreshView(integration, view: view); await refreshBoard() }
        return started
    }

    /// A task's own pads (Tasks/<ticket>), which the scratchpads leave out.
    public func taskPads(_ ticket: String) async -> [PadSummary] {
        (try? await link?.pad("list", ["folder": "Tasks/\(ticket)"], as: PadList.self))?.pads ?? []
    }

    /// Puts a task away with its workers; the board drops them at once, the mirror as zerod says each is gone.
    public func archive(_ id: String) async {
        var team = [id]
        var i = 0
        while i < team.count { let lead = team[i]; team += conversations.filter { $0.parent == lead }.map(\.id); i += 1 }
        for member in team.reversed() { _ = await attempt { try await $0.archive(session: member) } }
        await refreshBoard()
    }

    /// How many of a session's items aren't loaded, before those that are.
    public func earlier(_ session: String) -> Int { lives[session]?.earlier ?? mirror.earlier[session] ?? 0 }

    /// The page of a session's items before those loaded; with `from`, every one from that message on.
    public func loadEarlier(_ session: String, from: String? = nil) async {
        guard let link, earlier(session) > 0 else { return }
        let first = mirror.conversations[session]?.items.first?.id
        guard let page = try? await link.items(session: session, before: first, from: from) else { return }
        mirror.prepend(session, items: page, remaining: max(0, earlier(session) - page.count))
        sync(session)
    }

    /// Back to its latest items, as a snapshot has them: the rest is fetched again when it's wanted.
    public func trim(_ session: String) {
        mirror.trim(session, keep: 40)
        sync(session)
    }

    /// Words waiting in a task's composer when it opens: the message a branch was made from.
    public var pendingDrafts: [String: String] = [:]

    public func rewindPreview(_ session: String, message: String) async -> RewindPreview? {
        try? await link?.rewindPreview(session: session, message: message)
    }

    public func rewind(_ session: String, message: String, conversation: Bool, code: Bool) async -> Rewound? {
        await attempt { try await $0.rewind(session: session, message: message, conversation: conversation, code: code) }
    }

    public func branch(_ session: String, message: String) async -> Rewound? {
        let branched = await attempt { try await $0.branch(session: session, message: message) }
        if let id = branched?.session { pendingDrafts[id] = branched?.text }
        return branched
    }

    /// Each task's outline (your messages and their answers, for the page's rail) as last fetched: a page opens with
    /// its rail in place and the fresh outline replaces it only if it differs.
    public private(set) var outlines: [String: [OutlineMark]] = [:]

    @discardableResult
    public func outline(_ session: String) async -> [OutlineMark] {
        guard let marks = try? await link?.outline(session: session) else { return outlines[session] ?? [] }
        if outlines[session] != marks { outlines[session] = marks }
        return marks
    }

    public func loadLoops() async {
        guard let list = try? await link?.loops() else { return }
        if list != loops { loops = list }
    }

    public func readLoop(_ name: String) async -> ZerodLink.Loop? { try? await link?.loop(name) }

    /// Saved, or why not (a name that isn't one, a child that leads back to it).
    public func saveLoop(_ name: String, description: String, body: String) async -> String? {
        guard let link else { return "Zero's daemon isn't running" }
        do { _ = try await link.saveLoop(name, description: description, body: body); await loadLoops(); return nil } catch { return error.localizedDescription }
    }

    public func loadWorkspaces() async {
        guard let list = try? await link?.workspaces(), !list.isEmpty else { return }
        if list != workspaces { workspaces = list }
        if !list.contains(where: { $0.id == current }) { current = "zero" }
    }

    /// Saves a workspace (an empty id makes one); the error to show, or nil.
    @discardableResult public func saveWorkspace(_ workspace: ZerodLink.Workspace) async -> String? {
        do {
            guard let link else { return "Zero's daemon isn't running" }
            let saved = try await link.saveWorkspace(workspace)
            await loadWorkspaces()
            if workspace.id.isEmpty { current = saved.id }
            return nil
        } catch { return error.localizedDescription }
    }

    public func deleteWorkspace(_ id: String) async {
        _ = await attempt { try await $0.deleteWorkspace(id) }
        await loadWorkspaces()
    }

    /// Puts a task in a workspace (nil: its folder's).
    public func place(_ session: String, in workspace: String?) async {
        _ = await attempt { try await $0.placeInWorkspace(session: session, workspace: workspace) }
    }

    /// Which workspace a conversation is in, as zerod works it out: put somewhere, that; else the longest of a
    /// workspace's folders that contains its folder; else Zero.
    public func workspace(of conversation: Conversation) -> String {
        if let placed = conversation.workspace, workspaces.contains(where: { $0.id == placed }) { return placed }
        let cwd = conversation.cwd.hasSuffix("/") ? String(conversation.cwd.dropLast()) : conversation.cwd
        let owning = workspaces.flatMap { w in w.folders.map { ($0, w.id) } }
            .filter { folder, _ in cwd == folder || cwd.hasPrefix(folder + "/") }
            .max { $0.0.count < $1.0.count }
        return owning?.1 ?? "zero"
    }

    // Zero for Chrome.

    /// Puts the native host's manifest where Chrome reads it; the extension's folder, to load in Chrome.
    public func browserSetup() async -> String? { await attempt { try await $0.browserSetup().extension } }
    /// The Chromes connected to Zero, by name.
    public func browsers() async -> [String] { ((try? await link?.browsers()) ?? []).map(\.name) }
    public func blockedSites() async -> [String] { (try? await link?.browserSettings()) ?? [] }
    public func saveBlockedSites(_ sites: [String]) async { _ = await attempt { try await $0.saveBrowserSettings(blocked: sites) } }

    public func loadFollowing() async {
        guard let list = try? await link?.following() else { return }
        if list != followed { followed = list }
    }

    public func unfollow(session: String, topic: String) async {
        _ = await attempt { try await $0.unfollow(session: session, topics: [topic]) }
        await loadFollowing()
    }

    public func deleteLoop(_ name: String) async {
        _ = await attempt { try await $0.deleteLoop(name) }
        await loadLoops()
    }

    public func loadPads() async {
        guard let list = try? await link?.pad("list", [:], as: PadList.self) else { return }
        if list.pads != pads { pads = list.pads }
        if list.folders != padFolders { padFolders = list.folders }
    }

    public func readPad(_ id: String) async -> Pad? { try? await link?.pad("read", ["pad": id], as: Pad.self) }

    /// The text written, if nobody has changed the pad since `revision`; the error says so if they have.
    public func writePad(_ id: String, content: String, revision: String?) async throws -> Pad {
        guard let link else { throw ZerodError(message: "Zero's daemon isn't running") }
        var args: [String: Any] = ["pad": id, "content": content]
        if let revision { args["revision"] = revision }
        return try await link.pad("write", args, as: Pad.self)
    }

    public func createPad(in folder: String) async -> Pad? {
        let pad = await attempt { try await $0.pad("create", ["folder": folder, "title": "Untitled"], as: Pad.self) }
        await loadPads()
        return pad
    }

    /// A pad with something in it already (a message saved from a task).
    public func createPad(title: String, folder: String, content: String) async -> Pad? {
        let pad = await attempt { try await $0.pad("create", ["title": title, "folder": folder, "content": content], as: Pad.self) }
        await loadPads()
        return pad
    }

    @discardableResult
    /// Names a task: the sidebar's label for it, keeping what it is for.
    public func rename(_ id: String, to label: String, ticket: String?) async {
        _ = await attempt { try await $0.label(session: id, label: label, ticket: ticket) }
        await refreshBoard()
    }

    public func renamePad(_ id: String, to title: String) async -> Pad? {
        let pad = await attempt { try await $0.pad("rename", ["pad": id, "title": title], as: Pad.self) }
        await loadPads()
        return pad
    }

    public func movePad(_ id: String, to folder: String) async {
        _ = await attempt { try await $0.pad("move", ["pad": id, "folder": folder], as: Pad.self) }
        await loadPads()
    }

    public func deletePad(_ id: String) async {
        _ = await attempt { try await $0.pad("delete", ["pad": id], as: [String: Bool].self) }
        await loadPads()
    }

    public func makePadFolder(_ folder: String) async {
        _ = await attempt { try await $0.pad("folder", ["folder": folder], as: [String: [String]].self) }
        await loadPads()
    }

    public func loadIntegrations() async {
        guard let state = try? await link?.integrations() else { return }
        if state != integrations { integrations = state }
        // A Slack token the app kept itself (before zerod held the connection) goes to zerod once.
        if state.slack == nil, !handedSlackOver, let token = Slack.shared.legacyToken() {
            handedSlackOver = true
            if await connectSlack(token: token) == nil { Slack.shared.forgetLegacyToken() }
        }
    }
    @ObservationIgnored private var handedSlackOver = false

    /// Connects Slack with a user token of Zero's app; the error to show, or nil.
    public func connectSlack(token: String) async -> String? {
        do {
            guard let link else { return "Zero's daemon isn't running" }
            integrations = try await link.connectSlack(token: token)
            return nil
        } catch { return error.localizedDescription }
    }

    public func disconnectSlack() async {
        if let state = await attempt({ try await $0.disconnectSlack() }) { integrations = state }
    }

    /// Slack's channels again, hourly while Zero runs.
    public func keepSlackFresh() {
        Task { while true { try? await Task.sleep(for: .seconds(3600)); if integrations?.slack != nil, let state = try? await link?.refreshSlack() { integrations = state } } }
    }

    public func setIntegration(_ integration: String, enabled: Bool) async {
        if let state = await attempt({ try await $0.setIntegration(integration, enabled: enabled) }) { integrations = state }
    }

    public func saveView(_ integration: String, view: some Encodable & Sendable) async {
        if let state = await attempt({ try await $0.saveView(integration, view: view) }) { integrations = state }
    }

    public func orderViews(_ integration: String, ids: [String]) async {
        if let state = await attempt({ try await $0.orderViews(integration, ids: ids) }) { integrations = state }
    }

    public func deleteView(_ integration: String, view: String) async {
        if let state = await attempt({ try await $0.deleteView(integration, view: view) }) { integrations = state }
    }

    public func refreshView(_ integration: String, view: String) async {
        let key = "\(integration)/\(view)"
        guard let link else { return }
        // Stale while it revalidates: what the view last showed (kept by zerod), then the fresh rows.
        if items[key] == nil, let kept = try? await link.cachedItems(integration, view: view) { items[key] = kept }
        refreshing.insert(key)
        defer { refreshing.remove(key) }
        do {
            let rows = try await link.viewItems(integration, view: view)
            if rows != items[key] { items[key] = rows }
            itemErrors[key] = nil
        } catch {
            itemErrors[key] = error.localizedDescription
        }
    }

    /// Linear's sign-in page; zerod finishes the connection when it comes back.
    /// Linear's teams and their own states, for picking a view's; nil until Linear is connected.
    public private(set) var linearTeams: [LinearTeam]?

    /// What zerod last heard of Linear's teams, then what Linear says now.
    public func loadLinearTeams() async {
        if linearTeams == nil, let kept = try? await link?.linearTeams(cached: true) { linearTeams = kept }
        if let fresh = try? await link?.linearTeams() { linearTeams = fresh }
    }

    public func connectLinear() async -> URL? { await attempt { try await $0.connectLinear() } }

    public func disconnectLinear() async {
        if let state = await attempt({ try await $0.disconnectLinear() }) { integrations = state }
    }

    public func refreshBoard() async {
        guard let rows = try? await link?.board() else { return }
        if rows != rawBoard { rawBoard = rows; resettle() }
    }

    public func start(provider: Provider, cwd: String, prompt: String, images: [String] = [], model: String?, effort: String?, permissions: Permissions = .auto,
                      workspace: String? = nil) async -> String? {
        await attempt { try await $0.start(provider: provider, cwd: cwd, prompt: prompt, images: images, model: model, effort: effort, permissions: permissions, workspace: workspace) }
    }

    public func send(_ session: String, text: String, images: [String] = [], model: String? = nil, effort: String? = nil) async {
        _ = await attempt { try await $0.send(session: session, text: text, images: images, model: model, effort: effort) }
    }

    public func queue(_ session: String, text: String, images: [String] = []) async { _ = await attempt { try await $0.queue(session: session, text: text, images: images) } }
    public func unqueue(_ session: String, item: String) async -> Bool { await attempt { try await $0.unqueue(session: session, item: item) } != nil }
    public func release(_ session: String) async { _ = await attempt { try await $0.release(session: session) } }
    public func interrupt(_ session: String) async { _ = await attempt { try await $0.interrupt(session: session) } }
    public func stop(_ session: String) async { _ = await attempt { try await $0.stop(session: session) } }
    public func resume(_ session: String) async { _ = await attempt { try await $0.resume(session: session) } }

    public func openTerminal(_ session: String) async { _ = await attempt { try await $0.openTerminal(session: session) } }
    public func closeTerminal(_ session: String) async { _ = await attempt { try await $0.closeTerminal(session: session) } }

    /// Moves the task to another provider; true once it's there.
    public func setPermissions(_ session: String, _ permissions: Permissions) async {
        _ = await attempt { try await $0.setPermissions(session: session, permissions) }
    }

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
        guard let link else { lastError = "Zero's daemon isn't running"; Log.write("request with zerod not running"); return nil }
        do {
            let result = try await request(link)
            lastError = nil
            return result
        } catch {
            lastError = error.localizedDescription
            Log.write("zerod refused: " + (lastError ?? ""))
            return nil
        }
    }

    /// The name the user or its lead gave it, else the session's title, else what it was asked first, else the
    /// provider and its folder.
    public static func label(of conversation: Conversation) -> String {
        if let label = conversation.label, !label.isEmpty { return label }
        if let title = conversation.title, !title.isEmpty { return title }
        for item in conversation.items {
            if case let .user(text, _) = item.kind, let gist = Store.gist(of: text) { return gist }
        }
        return "\(conversation.provider.title) in \((conversation.cwd as NSString).lastPathComponent)"
    }
}
