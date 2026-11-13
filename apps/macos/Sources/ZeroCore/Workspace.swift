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
    /// And after them: jumped back through it (the rail), what's newer comes as it's scrolled down to.
    public fileprivate(set) var later = 0
    init(_ conversation: Conversation, earlier: Int) { self.conversation = conversation; self.earlier = earlier }
}

/// One task as its page needs it, observed on its own: its roster entry and its board row, set only when they change,
/// so another task changing doesn't redraw this one's page (each page read the whole roster and board, and redrew with
/// any change to either).
@MainActor @Observable
public final class TaskEntry {
    /// As the roster has it (without its conversation).
    public fileprivate(set) var conversation: Conversation?
    /// Its row on the board: a lead's, its workers in it.
    public fileprivate(set) var row: BoardRow?
    init(_ conversation: Conversation?, row: BoardRow?) { self.conversation = conversation; self.row = row }
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
    /// Each task's name (Workspace.label), on its own: what shows another task by name (a worker's report in a
    /// conversation) redraws when a name changes, not with every change to the roster.
    public private(set) var names: [String: String] = [:]
    @ObservationIgnored private var lives: [String: LiveConversation] = [:]
    @ObservationIgnored private var entries: [String: TaskEntry] = [:]
    public private(set) var connected = false
    /// Why the last request failed, for the window to show.
    public var lastError: String?
    /// The task the user asked to archive, waiting on their confirmation.
    public var archiving: String?

    /// Who GitHub, Linear and Slack are connected as, and what makes their references in messages links.
    public private(set) var integrations: IntegrationState? {
        didSet {
            if integrations?.slack != oldValue?.slack { Slack.shared.apply(integrations?.slack ?? []) }
            LinearTeams.known = integrations?.linearTeams ?? [:]
        }
    }
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
        didSet {
            UserDefaults.standard.set(current, forKey: "currentWorkspace")
        }
    }
    public var currentWorkspace: ZerodLink.Workspace { workspaces.first { $0.id == current } ?? workspaces[0] }

    /// What each running task's processes use (zerod's uses.rs), by session; a parked task isn't in it.
    public private(set) var uses: [String: TaskUses] = [:]

    /// What tasks left running (zerod's left.rs), by session, archived tasks' too; one with nothing left isn't in it.
    public private(set) var left: [String: LeftRunning] = [:]

    /// Every task at once (crates/zerod/src/board.rs), while the window shows it.
    public private(set) var board: [BoardRow] = []
    var rawBoard: [BoardRow] = []

    /// Told each board as it changes, for the app's notifications.
    @ObservationIgnored public var onBoard: (([BoardRow]) -> Void)?

    /// The latest answer of each task the user looked at, as last told to zerod (which greys Replied to read, on every
    /// client): told when it's opened, and when the user does something in it (click, scroll, type).
    @ObservationIgnored private var told: [String: String] = [:]

    /// The user is looking at this task now: its latest answer is seen, as zerod is told.
    public func markSeen(_ id: String) {
        guard let answer = latestAnswer(id), told[id] != answer, let link else { return }
        told[id] = answer
        Task { try? await link.seen(session: id, answer: answer) }
    }

    func resettle() {
        let rows = rawBoard
        if rows != board {
            for row in rows where board.first(where: { $0.session == row.session })?.state != row.state {
                Log.write("task \(row.session) \(row.state.rawValue): \(row.task)")
            }
            board = rows
            for (id, entry) in entries {
                let row = rows.first { $0.session == id }
                if entry.row != row { entry.row = row }
            }
            onBoard?(rows)
        }
    }

    private func latestAnswer(_ id: String) -> String? {
        (lives[id]?.conversation ?? roster[id])?.items.last { if case .agent(_, true) = $0.kind { true } else { false } }?.id
    }

    public var conversations: [Conversation] { order.compactMap { roster[$0] } }
    /// A task as the roster has it: everything but its conversation.
    public func conversation(_ id: String) -> Conversation? { roster[id] }

    /// A task's roster entry and board row, observed on their own; made on demand, kept up to date from then on.
    public func entry(_ id: String) -> TaskEntry {
        if let kept = entries[id] { return kept }
        let entry = TaskEntry(roster[id], row: board.first { $0.session == id })
        entries[id] = entry
        return entry
    }

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
            // Only a real change: an assignment, even of what's there, redraws every view reading it.
            if roster[id] != nil { roster[id] = nil }
            if let entry = entries[id], entry.conversation != nil { entry.conversation = nil }
            if names[id] != nil { names[id] = nil }
            if order.contains(id) { order.removeAll { $0 == id } }
            lives[id] = nil
            return
        }
        if !order.contains(id) { order = mirror.order.filter { mirror.conversations[$0] != nil } }
        // The version Claude Code ran it on ("claude-opus-5-5", from its first event): the picker's names and choices.
        if full.provider == .claude, let model = full.model, model.hasPrefix("claude-") { ClaudeModels.remember(model) }
        // Its first message of yours (its name) and its latest answer (how its last turn ended: its state).
        var light = full
        let first =
            full.items.first { if case .user = $0.kind { true } else { false } }
            ?? roster[id]?.items.first { if case .user = $0.kind { true } else { false } }
        // Only once its turn has ended, so words streaming into it don't change the roster; nor does the turn's diff.
        let isAnswer = { (item: ConversationItem) in if case .agent(_, true) = item.kind { true } else { false } }
        // A window short of the end has an old answer last: the one already known stays.
        let windowed = (mirror.later[id] ?? 0) > 0
        let answer = full.turn == nil && !windowed ? full.items.last(where: isAnswer) : roster[id]?.items.last(where: isAnswer)
        light.items = [first, answer].compactMap { $0 }
        light.diff = nil
        light.seq = 0
        if roster[id] != light { roster[id] = light }
        if let entry = entries[id], entry.conversation != light { entry.conversation = light }
        let name = Self.label(of: light)
        if names[id] != name { names[id] = name }
        if let live = lives[id] {
            // Only a real change: an assignment redraws the conversation, the same session sent again included.
            show(id, in: live)
        }
    }

    /// A conversation redrawn at most every `redrawEvery`: an agent at work sends 30 changes a second (a word, a step,
    /// its status), and each redrew every message in it, frames dropped as you scrolled. What comes in between waits,
    /// and the latest is shown once the time is up.
    @ObservationIgnored private var shownAt: [String: Date] = [:]
    @ObservationIgnored private var showing: Set<String> = []
    static let redrawEvery: TimeInterval = 0.1

    /// A task's conversation on screen or not: a page kept behind the one shown, or in a closed or covered window, isn't
    /// redrawn as its agent works (each change laid out the whole conversation again, unseen); it catches up as it shows.
    /// Counted by task, not kept on its live object: that object is made again when it's dropped (the mirror without
    /// the task a moment, as zerod reconnects), and one made hidden under a page still showing was never shown again
    /// (an answer sent while it stayed "Starting…"). Each view showing it counts once, so one going (a page made
    /// again) doesn't hide it from another.
    public func watch(_ id: String, _ on: Bool) {
        watchers[id] = max(0, watchers[id, default: 0] + (on ? 1 : -1))
        if watchers[id] == 0 { watchers[id] = nil }
        if on, let live = lives[id] { bringUp(id, live) }
    }
    @ObservationIgnored private var watchers: [String: Int] = [:]
    private func watched(_ id: String) -> Bool { watchers[id] != nil }

    private func show(_ id: String, in live: LiveConversation) {
        guard watched(id) else { return }
        let since = Date().timeIntervalSince(shownAt[id] ?? .distantPast)
        guard since < Self.redrawEvery else { bringUp(id, live); return }
        guard showing.insert(id).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.redrawEvery - since) { [weak self] in
            guard let self else { return }
            showing.remove(id)
            if let live = lives[id], watched(id) { bringUp(id, live) }
        }
    }

    /// The live object brought up to the mirror: its items with the counts around them, together.
    private func bringUp(_ id: String, _ live: LiveConversation) {
        guard let full = mirror.conversations[id] else { return }
        let earlier = mirror.earlier[id] ?? 0, later = mirror.later[id] ?? 0
        guard live.conversation != full || live.earlier != earlier || live.later != later else { return }
        shownAt[id] = Date()
        if live.conversation != full { live.conversation = full }
        if live.earlier != earlier { live.earlier = earlier }
        if live.later != later { live.later = later }
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
                        case let .board(rows):
                            guard let self, self.rawBoard != rows else { break }
                            self.rawBoard = rows
                            // What zerod now shows needs no echo.
                            for row in rows where self.queuing[row.session]?.isEmpty == false {
                                self.queuing[row.session]?.removeAll { echo in (row.queued ?? []).contains { $0.text == echo.text } }
                            }
                            self.resettle()
                        case .pads: self?.padsVersion += 1
                        case .loops: self?.loopsVersion += 1
                        case .later: Task { await self?.loadLater() }
                        case .following: self?.followingVersion += 1
                        case .workspaces: self?.workspacesVersion += 1; Task { await self?.loadWorkspaces() }
                        case .signins: Task { await self?.loadSignIns() }
                        case .restarting: self?.followUpdate()
                        case .clear: break
                        case let .uses(tasks): if self?.uses != tasks { self?.uses = tasks }
                        case let .left(tasks): if self?.left != tasks { self?.left = tasks }
                        }
                    }
                }
                fresh.onClose = { [weak self] in
                    Task { @MainActor in
                        self?.link = nil; self?.connected = false; Log.write("zerod connection closed")
                        self?.closed?.resume(); self?.closed = nil
                    }
                }
                link = fresh
                if (try? await fresh.subscribe()) != nil {
                    connected = true
                    updating = nil
                    // Opened while zerod restarts (an install reopens the app first): said straight away.
                    if (try? await fresh.restartStatus())?.restarting == true { followUpdate() }
                    await loadWorkspaces(); await loadIntegrations()
                    Task { await refreshLinearTeams() }
                }
            }
            // Without one, looked for again soon: zerod back from a restart is picked up within a moment. With one,
            // nothing to do until it closes (a 2 s poll woke the app forever).
            if link == nil {
                try? await Task.sleep(for: .milliseconds(300))
            } else {
                await withCheckedContinuation { continuation in
                    if link == nil { continuation.resume() } else { closed = continuation }
                }
            }
        }
    }
    @ObservationIgnored private var closed: CheckedContinuation<Void, Never>?

    func receive(_ message: ZerodMirror.Message) {
        if !mirror.receive(message) { onBehind() }
        switch message {
        case let .session(conversation): sync(conversation.id)
        case let .change(event):
            if case .delta = event.change { soon(event.session, words: true) } else { soon(event.session) }
        case let .earlier(session, _): sync(session)
        }
    }

    /// Tasks changed since the views last caught up.
    @ObservationIgnored private var stale: Set<String> = []
    @ObservationIgnored private var catchingUp = false
    /// Something other than more words came since: caught up with at the shorter wait.
    @ObservationIgnored private var urgent = false

    /// The views catch up with a task at most about 30 times a second: an answer streams in at 80 words a second,
    /// and drawing each one fell behind, so the text showed up halfway through. The mirror has every change at once.
    private func soon(_ id: String, words: Bool = false) {
        stale.insert(id)
        if !words { urgent = true }
        guard !catchingUp else { return }
        catchingUp = true
        Task { @MainActor in
            // A tenth of a second: an answer arriving word by word is read out a couple of seconds behind (Playback),
            // and each sync redraws its conversation; at 33 ms that was up to 30 times a second.
            try? await Task.sleep(for: .milliseconds(100))
            // Only more words since (an answer, a command's output): up to 300 ms, three syncs a second instead of
            // ten, as reading runs seconds behind them. Anything else (a step, a status, an ask) cuts the wait short.
            var waited = 100
            while !urgent, waited < 300 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 50
            }
            urgent = false
            catchingUp = false
            let ids = stale
            stale = []
            ids.forEach(sync)
        }
    }

    // What the window asks of zerod.

    /// Puts a task away with its workers (zerod takes them with it, so they come back with it); the board drops them
    /// at once, the mirror as zerod says each is gone.
    /// Everyone under a lead, however deep: what goes with it when it's archived.
    public func team(of id: String) -> [Conversation] {
        var team: [Conversation] = [], leads = [id]
        while let lead = leads.popLast() {
            let under = conversations.filter { $0.parent == lead }
            team += under
            leads += under.map(\.id)
        }
        return team
    }

    /// Tasks put away from here: the board drops one before the list of sessions does, and in between it would show
    /// under Earlier for a moment (the sidebar shifting twice).
    public private(set) var putAway: Set<String> = []

    public func archive(_ id: String) async {
        putAway.insert(id)
        _ = await attempt { try await $0.archive(session: id) }
        await refreshBoard()
    }

    /// Stops what a task left running: the things named, else all of it. They leave the list at once.
    public func stopLeft(_ id: String, things: [String]? = nil) async {
        if var task = left[id] {
            let kept = task.things.filter { thing in things.map { !$0.contains(thing.id) } ?? false }
            task = LeftRunning(task: task.task, archived: task.archived, settled: task.settled, things: kept)
            left[id] = kept.isEmpty ? nil : task
        }
        _ = await attempt { try await $0.stopLeft(session: id, things: things) }
    }

    /// The tasks archived, newest first, each with how many workers went with it.
    public func archived() async -> [ZerodLink.Archived] { await attempt { try await $0.archived() } ?? [] }

    /// A task back from the archive, with the workers that went with it.
    public func unarchive(_ id: String) async {
        putAway.remove(id)
        _ = await attempt { try await $0.unarchive(session: id) }
        await refreshBoard()
    }

    /// Tasks saved for later, whole: in Later, not in the sidebar, until resumed.
    public var savedForLater: Set<String> { Set(later.filter { !$0.done }.compactMap(\.resume)) }

    public func saveForLater(_ id: String) async {
        putAway.insert(id)
        _ = await attempt { try await $0.saveForLater(session: id) }
        await loadLater()
        putAway.remove(id)
        await refreshBoard()
    }

    /// A task saved for later back in the sidebar, off hold: its session.
    public func resumeLater(_ item: String) async -> String? {
        let session = await attempt { try await $0.resumeLater(item) } ?? nil
        await loadLater()
        await refreshBoard()
        return session
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
        if (mirror.later[session] ?? 0) > 0 { Task { await loadLatest(session) }; return }
        mirror.trim(session, keep: 40)
        sync(session)
    }

    /// A page from a message (the rail's jump, a place gone back to), in place of what's loaded: not every item from
    /// there to the end, which a long conversation would have to lay out whole.
    public func jump(_ session: String, to item: String) async {
        guard let page = try? await link?.window(session: session, from: item, limit: 60), !page.items.isEmpty else { return }
        mirror.window(session, items: page.items, earlier: page.earlier, later: page.later)
        sync(session)
    }

    /// A passage to show (an ask's About, a #link, zero://task/<id>#anchor): its task's page goes to it.
    public var reveal: Reveal?

    /// The item a link names: one loaded by its id, else zerod finds the heading (or an item not loaded).
    public func item(_ session: String, anchor: String) async -> String? {
        if mirror.conversations[session]?.items.contains(where: { $0.id == anchor }) == true { return anchor }
        return try? await link?.anchor(session: session, anchor: anchor).item
    }

    /// The page after what's loaded, when the window stops short of the end.
    public func loadNewer(_ session: String) async {
        guard (mirror.later[session] ?? 0) > 0, let last = mirror.conversations[session]?.items.last?.id,
            let page = try? await link?.window(session: session, after: last, limit: 60)
        else { return }
        mirror.append(session, items: page.items, later: page.later)
        sync(session)
    }

    /// The latest page again, as a snapshot has it: back to the end from a window.
    public func loadLatest(_ session: String) async {
        guard (mirror.later[session] ?? 0) > 0, let page = try? await link?.window(session: session, limit: 40) else { return }
        mirror.window(session, items: page.items, earlier: page.earlier, later: page.later)
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

    public func unrewind(_ session: String, undo: String?, conversation: Bool) async -> Bool {
        await attempt { try await $0.unrewind(session: session, undo: undo, conversation: conversation) } != nil
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
        guard var marks = try? await link?.outline(session: session) else { return outlines[session] ?? [] }
        // The rail shows each answer without its ending line: taken off once here, not on every redraw.
        for i in marks.indices { marks[i].answer = marks[i].answer.map { ZeroEnding.split($0).0 } }
        if outlines[session] != marks { outlines[session] = marks }
        return marks
    }

    /// What's saved for later, without artifacts, as zerod last listed it.
    public private(set) var later: [ZerodLink.LaterItem] = []

    public func loadLater() async {
        guard let list = try? await link?.laterItems() else { return }
        if list != later { later = list }
    }

    public func laterItem(_ id: String, version: Int? = nil) async -> ZerodLink.LaterItem? {
        try? await link?.laterItem(id, version: version)
    }

    public func editLater(_ id: String, _ fields: [String: Any]) async {
        _ = await attempt { try await $0.editLater(id, fields) }
        await loadLater()
    }

    /// One the user writes: their note, and anything behind it. Its id.
    public func saveLater(note: String, artifact: String) async -> String? {
        let saved = await attempt { try await $0.later("save", ["note": note, "artifact": artifact]) } as? [String: Any]
        await loadLater()
        return saved?["id"] as? String
    }

    public func deleteLater(_ id: String) async {
        _ = await attempt { try await $0.later("delete", ["item": id]) }
        await loadLater()
    }

    /// MCP servers set up in Zero, as zerod last listed them.
    public private(set) var mcpServers: [ZerodLink.McpServer] = []

    public func loadMcpServers() async {
        if let list = try? await link?.mcpServers(), list != mcpServers { mcpServers = list }
    }

    /// Saved with its Keychain values put in the Keychain (`secrets`, by name), never in zerod's file; an error to show.
    public func saveMcpServer(_ server: ZerodLink.McpServer, secrets: [String: String]) async -> String? {
        guard let link = await linked() else { return "Zero's daemon isn't running" }
        do {
            let saved = try await link.saveMcpServer(server)
            for (name, value) in secrets where !value.isEmpty {
                Keychain.saveString(value, service: ZerodLink.McpServer.keychain, account: saved.id + "." + name)
            }
            await loadMcpServers()
            return nil
        } catch { return error.localizedDescription }
    }

    /// Claude Code's sign-in page for one of its own servers (`cwd`: a project's), or nil with lastError said.
    public func mcpSignIn(_ server: String, cwd: String?) async -> URL? {
        await attempt { try await $0.mcpSignIn(server, cwd: cwd) } ?? nil
    }

    /// Gone, with the values it kept in the Keychain.
    public func deleteMcpServer(_ server: ZerodLink.McpServer) async {
        _ = await attempt { try await $0.deleteMcpServer(server.id) }
        for value in server.env + server.headers where value.from == .keychain {
            Keychain.saveString(nil, service: ZerodLink.McpServer.keychain, account: server.id + "." + value.name)
        }
        await loadMcpServers()
    }

    public func loadLoops() async {
        guard let list = try? await link?.loops() else { return }
        if list != loops { loops = list }
    }

    public func readLoop(_ name: String) async -> ZerodLink.Loop? { try? await link?.loop(name) }

    /// Saved, or why not (a name that isn't one, a child that leads back to it).
    public func saveLoop(_ name: String, description: String, body: String) async -> String? {
        guard let link = await linked() else { return "Zero's daemon isn't running" }
        do { _ = try await link.saveLoop(name, description: description, body: body); await loadLoops(); return nil } catch {
            return error.localizedDescription
        }
    }

    public func loadWorkspaces() async {
        guard let list = try? await link?.workspaces(), !list.isEmpty else { return }
        if list != workspaces { workspaces = list }
        if !list.contains(where: { $0.id == current }) { current = "zero" }
    }

    /// Saves a workspace (an empty id makes one); the error to show, or nil.
    @discardableResult public func saveWorkspace(_ workspace: ZerodLink.Workspace) async -> String? {
        do {
            guard let link = await linked() else { return "Zero's daemon isn't running" }
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

    /// Puts a task in a workspace (nil: Zero).
    public func place(_ session: String, in workspace: String?) async {
        _ = await attempt { try await $0.placeInWorkspace(session: session, workspace: workspace) }
    }

    /// Marks a task done, waiting or blocked: the user's word, where its agent can't know (the last of it was theirs).
    public func setStatus(_ session: String, _ state: String) async {
        _ = await attempt { try await $0.setStatus(session: session, state: state) }
    }

    /// Which workspace a conversation is in, as zerod works it out: put somewhere, that; else Zero.
    public func workspace(of conversation: Conversation) -> String {
        if let placed = conversation.workspace, workspaces.contains(where: { $0.id == placed }) { return placed }
        return "zero"
    }

    // Zero for Chrome.

    /// Puts the native host's manifest where Chrome reads it; the extension's folder, to load in Chrome.
    public func browserSetup() async -> String? { await attempt { try await $0.browserSetup().extension } }
    /// The Chromes connected to Zero, by name.
    public func browsers() async -> [String] { ((try? await link?.browsers()) ?? []).map(\.name) }
    /// Tries Safari's automation windows; an error to show.
    public func checkSafari() async -> String? {
        guard let link = await linked() else { return "Zero's daemon isn't running" }
        do { try await link.checkSafari(); return nil } catch { return error.localizedDescription }
    }

    /// Opens Firefox under Zero's remote control; an error to show.
    public func openFirefox() async -> String? {
        guard let link = await linked() else { return "Zero's daemon isn't running" }
        do { try await link.openFirefox(); return nil } catch { return error.localizedDescription }
    }
    public func blockedSites() async -> [String] { (try? await link?.browserSettings()) ?? [] }
    public func saveBlockedSites(_ sites: [String]) async { _ = await attempt { try await $0.saveBrowserSettings(blocked: sites) } }
    public func replacesDialogs() async -> Bool { (try? await link?.browserDialogs()) ?? false }
    public func replaceDialogs(_ on: Bool) async { _ = await attempt { try await $0.saveBrowserDialogs(on) } }

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

    public func readPad(_ id: String) async -> Pad? {
        let read = try? await link?.pad("read", ["pad": id], as: Pad.self)
        if let read { padCache[id] = read }
        return read
    }

    /// Each pad as last read or written here: a pad opened again shows at once, then catches up with zerod.
    @ObservationIgnored private var padCache: [String: Pad] = [:]
    public func cachedPad(_ id: String) -> Pad? { padCache[id] }

    /// Read ahead of opening (the pointer is on its row): the click finds it here.
    public func prefetchPad(_ id: String) {
        guard padCache[id] == nil else { return }
        Task { _ = await readPad(id) }
    }

    /// The text written, if nobody has changed the pad since `revision`; the error says so if they have.
    public func writePad(_ id: String, content: String, revision: String?) async throws -> Pad {
        guard let link = await linked() else { throw ZerodError(message: "Zero's daemon isn't running") }
        var args: [String: Any] = ["pad": id, "content": content]
        if let revision { args["revision"] = revision }
        let written = try await link.pad("write", args, as: Pad.self)
        padCache[id] = written
        return written
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
    }

    /// Connects Slack with a user token of Zero's app; the error to show, or nil.
    public func connectSlack(token: String) async -> String? {
        do {
            guard let link = await linked() else { return "Zero's daemon isn't running" }
            integrations = try await link.connectSlack(token: token)
            return nil
        } catch { return error.localizedDescription }
    }

    public func disconnectSlack(team: String) async {
        if let state = await attempt({ try await $0.disconnectSlack(team: team) }) { integrations = state }
    }

    /// Slack's channels again, hourly while Zero runs.
    public func keepSlackFresh() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(3600));
                if !(integrations?.slack ?? []).isEmpty, let state = try? await link?.refreshSlack() { integrations = state }
            }
        }
    }

    /// Linear's teams again, so issue ids of a team made since link too.
    public func refreshLinearTeams() async {
        guard integrations?.linear != nil, let state = try? await link?.linearTeams() else { return }
        integrations = state
    }

    public func connectLinear() async -> URL? { await attempt { try await $0.connectLinear() } }

    public func disconnectLinear() async {
        if let state = await attempt({ try await $0.disconnectLinear() }) { integrations = state }
    }

    public func refreshBoard() async {
        guard let rows = try? await link?.board() else { return }
        if rows != rawBoard { rawBoard = rows; resettle() }
    }

    public func start(
        provider: Provider, cwd: String, prompt: String, images: [String] = [], model: String?, effort: String?,
        permissions: Permissions = .auto,
        workspace: String? = nil
    ) async -> String? {
        await attempt {
            try await $0.start(
                provider: provider, cwd: cwd, prompt: prompt, images: images, model: model, effort: effort, permissions: permissions,
                workspace: workspace)
        }
    }

    /// Whether it went (or is queued): false, and the words are for the box again.
    @discardableResult
    public func send(_ session: String, text: String, images: [String] = [], model: String? = nil, effort: String? = nil) async -> Bool {
        // Shown at once, while its agent starts (a parked one takes seconds): the conversation's own takes its place.
        let echo = Sending(text: text, images: images)
        sending[session, default: []].append(echo)
        let sent =
            await attempt { try await $0.send(session: session, text: text, images: images, model: model, effort: effort, id: echo.id) }
            != nil
        settle(echo, in: session, sent: sent)
        return sent
    }

    /// A queued message sent now, into the turn under way: in the conversation and out of the queue at once, then taken
    /// off zerod's queue and sent. Back in the queue, and out of the conversation, if it can't be.
    @discardableResult
    public func steer(_ session: String, item: Queued) async -> Bool {
        let echo = Sending(text: item.text, images: item.images ?? [])
        sending[session, default: []].append(echo)
        steering.insert(item.id)
        guard await unqueue(session, item: item.id) else {
            steering.remove(item.id)
            settle(echo, in: session, sent: false)
            return false
        }
        let sent =
            await attempt {
                try await $0.send(session: session, text: item.text, images: item.images ?? [], model: nil, effort: nil, id: echo.id)
            } != nil
        settle(echo, in: session, sent: sent)
        // Out of the queue once zerod's board has had a moment to drop it too.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3)); self?.steering.remove(item.id)
        }
        return sent
    }

    /// A message's echo once it's sent: kept until the conversation has its own (Sending.merge stops showing it then),
    /// which comes a moment after the send's answer; removing it with the answer showed neither for a few frames. Gone
    /// at once when it wasn't sent.
    private func settle(_ echo: Sending, in session: String, sent: Bool) {
        guard sent else { sending[session]?.removeAll { $0.id == echo.id }; return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.sending[session]?.removeAll { $0.id == echo.id }
        }
    }

    /// Queued messages being steered into the turn: out of the strip from the click.
    private var steering: Set<String> = []

    /// Messages sent from here that their conversation doesn't have yet, by session.
    public private(set) var sending: [String: [Sending]] = [:]

    /// Messages queued here that zerod's board doesn't show yet, by session: shown at once, so queueing never waits on
    /// the board's next round.
    public private(set) var queuing: [String: [Queued]] = [:]

    /// A task's queue as the strip shows it: zerod's, then what was queued here since (zerod's entry takes its id).
    public func queued(_ session: String, board: [Queued]) -> [Queued] {
        let echoes = (queuing[session] ?? []).filter { echo in !board.contains { $0.id == echo.id } }
        return (board + echoes).filter { !steering.contains($0.id) }
    }

    /// `id`: the one the strip already shows it by; zerod's queue entry, and its item once sent on, take it.
    public func queue(_ session: String, text: String, images: [String] = [], id: String = "queuing-\(UUID().uuidString)") async {
        let echo = Queued(id: id, text: text, images: images.isEmpty ? nil : images)
        queuing[session, default: []].append(echo)
        // While Zero restarts for an update it can't take it: kept (its echo stays in the queue) and sent once Zero is
        // back, for up to five minutes. Refused for a reason of its own, it says why and goes.
        for _ in 0..<300 {
            if let link = await linked() {
                do { _ = try await link.queue(session: session, text: text, images: images, id: id); break } catch {
                    if updating == nil { lastError = error.localizedDescription; break }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // Once the board has had a moment to show it, the echo goes either way: shown by zerod, or refused.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.queuing[session]?.removeAll { $0.id == echo.id }
        }
    }
    /// Takes a queued message back; false, quietly, when zerod has sent it on already (as a turn ended while its last
    /// words still played): the strip shows it as on its way a moment later, which says it.
    public func unqueue(_ session: String, item: String) async -> Bool {
        guard let link = await linked() else { return false }
        return (try? await link.unqueue(session: session, item: item)) != nil
    }
    public func release(_ session: String) async { _ = await attempt { try await $0.release(session: session) } }
    public func introduce(_ session: String, to other: String) async {
        _ = await attempt { try await $0.introduce(session: session, to: other) }
    }
    public func interrupt(_ session: String) async { _ = await attempt { try await $0.interrupt(session: session) } }
    public func stop(_ session: String) async { _ = await attempt { try await $0.stop(session: session) } }
    public func resume(_ session: String) async { _ = await attempt { try await $0.resume(session: session) } }

    /// Being written to while its agent has stopped (parked after a while idle): its agent started in the background,
    /// at most once a minute, so the message doesn't wait for it to start. Never for a task the user has paused.
    public func warm(_ session: String) {
        guard roster[session]?.status == .offline, !isPaused(session), Date().timeIntervalSince(warmed[session] ?? .distantPast) > 60 else {
            return
        }
        warmed[session] = Date()
        Task { _ = try? await link?.resume(session: session) }
    }
    @ObservationIgnored private var warmed: [String: Date] = [:]
    /// On hold with their workers, and off it: a working one wraps up first (zerod gives it five minutes).
    public func pause(_ sessions: [String]) async { _ = await attempt { try await $0.pause(sessions: sessions) } }
    public func unpause(_ sessions: [String]) async { _ = await attempt { try await $0.unpause(sessions: sessions) } }
    /// Ends a task's command that looks stuck (its item); zerod tells the agent why, and it carries on.
    public func stopCommand(_ session: String, item: String) async {
        _ = await attempt { try await $0.stopCommand(session: session, item: item) }
    }
    /// A task (a lead, or a worker on its lead's row) the user put on hold.
    public func isPaused(_ session: String) -> Bool {
        board.contains {
            $0.session == session ? $0.ownState == .paused : $0.team?.contains { $0.session == session && $0.state == .paused } == true
        }
    }

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

    /// The connection, waited for a moment when there's none: zerod restarting for an update is gone for a few
    /// seconds, and what's sent then goes once it's back rather than failing.
    private func linked(within seconds: Double = 15) async -> ZerodLink? {
        let deadline = Date().addingTimeInterval(seconds)
        while link == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return link
    }

    /// zerod restarting for an update, from the moment it says so until the new one is connected: what it waits for
    /// (turns finishing a command, at most `most` seconds), then that it's starting.
    public struct Updating: Equatable {
        public var since = Date()
        public var waiting: [ZerodLink.RestartStatus.Waiting] = []
        public var most = 120
        /// The old zerod has gone: the new one is starting.
        public var starting = false
    }
    public private(set) var updating: Updating?

    /// Follows a restart: what it waits for, asked every second while the old zerod answers.
    func followUpdate() {
        guard updating == nil else { return }
        updating = Updating()
        Task { [weak self] in
            while let self, self.updating != nil {
                if let link = self.link, let status = try? await link.restartStatus() {
                    self.updating?.waiting = status.waiting
                    self.updating?.most = status.most
                } else {
                    self.updating?.starting = true
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func attempt<T>(_ request: (ZerodLink) async throws -> T) async -> T? {
        guard let link = await linked() else {
            lastError = updating != nil ? "Zero is restarting for an update: try again in a moment" : "Zero's daemon isn't running";
            Log.write("request with zerod not running"); return nil
        }
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

    // Sign-ins: zerod keeps what each is; the app puts its value in the Keychain, so it never crosses zerod's socket.

    public private(set) var signins: [ZerodLink.SignIn] = []
    /// Each CLI's default sign-in, by the CLI's name.
    public private(set) var signinDefaults: [String: String] = [:]

    /// Each sign-in's usage as its CLI last reported it, by id: what zerod chooses accounts by.
    public private(set) var signinUsage: [String: Usage] = [:]
    /// The models each sign-in's provider refused it (no access), by id: zerod doesn't choose it for them.
    public private(set) var signinRefused: [String: [String]] = [:]

    public func loadSignIns() async {
        guard let (list, defaults, usage, refused) = try? await link?.signIns() else { return }
        if refused != signinRefused { signinRefused = refused }
        if list != signins { signins = list }
        if defaults != signinDefaults { signinDefaults = defaults }
        if usage != signinUsage { signinUsage = usage }
    }

    /// Each account's finished turns by the hour (Unix hours): its activity graph's.
    public func accountActivity() async -> [String: [Int: Int]] { (try? await link?.accountActivity()) ?? [:] }

    /// Each account's usage asked of its CLI, rather than as its tasks last heard it.
    public func readUsage() async { try? await link?.readUsage() }

    /// A token or key kept: zerod gives it an id, its value goes in the Keychain under it. An error to show, or nil.
    public func addSignIn(_ signin: ZerodLink.SignIn, secret: String) async -> String? {
        guard let link = await linked() else { return "Zero's daemon isn't running" }
        do {
            let saved = try await link.saveSignIn(signin)
            Keychain.saveString(secret, service: ZerodLink.signInKeychain, account: saved.id)
            guard Keychain.loadString(service: ZerodLink.signInKeychain, account: saved.id) != nil else {
                try? await link.deleteSignIn(saved.id)
                return "Couldn't keep it in the Keychain"
            }
            await loadSignIns()
            return nil
        } catch { return error.localizedDescription }
    }

    /// Its name, which the user gives when its CLI can't say whose it is (a Claude token doesn't).
    public func renameSignIn(_ signin: ZerodLink.SignIn, to label: String) async {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != signin.label else { return }
        var renamed = signin
        renamed.label = label
        _ = await attempt { try await $0.saveSignIn(renamed) }
        await loadSignIns()
    }

    public func removeSignIn(_ signin: ZerodLink.SignIn) async {
        _ = await attempt { try await $0.deleteSignIn(signin.id) }
        Keychain.saveString(nil, service: ZerodLink.signInKeychain, account: signin.id)
        await loadSignIns()
    }

    /// A Codex account, signed in by Codex itself: its ChatGPT page to open (none for a key), or why not.
    public func signInCodex(label: String?, apiKey: String?) async -> (page: URL?, error: String?) {
        guard let link = await linked() else { return (nil, "Zero's daemon isn't running") }
        do {
            let (_, page) = try await link.codexSignIn(label: label, apiKey: apiKey)
            await loadSignIns()
            return (page, nil)
        } catch { return (nil, error.localizedDescription) }
    }

    /// The name the user or its lead gave it, else the session's title, else what it was asked first, else the
    /// provider and its folder.
    public static func label(of conversation: Conversation) -> String { TaskName.of(conversation) }
}
