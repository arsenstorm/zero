import Foundation
import Observation
import UIKit
import UserNotifications

/// The phone's copy of zerod: the board, the inbox's asks and the sessions' conversations, kept as zerod pushes them
/// through the tunnel, as the Mac app's Workspace keeps them through the socket.
@MainActor @Observable final class PhoneModel {
    /// The one copy: the app's, and Siri's when it runs an action with the app in the background.
    static let shared = PhoneModel()

    enum Status: Equatable { case unpaired, connecting, connected, offline(String) }
    private(set) var status = Status.unpaired {
        // The ways being tried settle with it: in when connected, missed when not.
        didSet {
            if status != oldValue { settleBanner() }
            for i in routes.indices where routes[i].state == .trying {
                switch status {
                case .connected: routes[i].state = .connected
                case .offline: routes[i].state = .missed; routes[i].detail = "No answer"
                default: break
                }
            }
        }
    }
    /// The way to the Mac this connection takes, and how it's going: the relay.
    private(set) var routes: [Route] = []
    /// Not reaching the Mac just now.
    var offline: Bool { if case .offline = status { true } else { false } }

    /// What the banner at the top says, steadied: the connection flips between connecting and not on each try (a
    /// restart of the Mac's zerod is a dozen of them), and said as it went, the banner flickered between its two
    /// messages. Nothing for a drop under a second; "Reconnecting" from then; "Can't reach" only after ten seconds of
    /// not connecting; each shown a second and a half at least.
    enum Banner: Equatable { case reconnecting, unreachable }
    private(set) var banner: Banner?
    @ObservationIgnored private var lostAt: Date?
    @ObservationIgnored private var bannerSince = Date.distantPast
    @ObservationIgnored private var bannerCheck: Task<Void, Never>?

    private func settleBanner() {
        let now = Date()
        if status == .connected || status == .unpaired { lostAt = nil } else if lostAt == nil { lostAt = now }
        var want: Banner?
        var next: TimeInterval?
        if let lostAt {
            let gone = now.timeIntervalSince(lostAt)
            if gone < 1 {
                next = 1 - gone
            } else if gone < 10 {
                want = .reconnecting; next = 10 - gone
            } else {
                want = .unreachable
            }
        }
        let held = now.timeIntervalSince(bannerSince)
        if want != banner, banner != nil, held < 1.5 {
            want = banner
            next = min(next ?? .infinity, 1.5 - held)
        }
        if want != banner { banner = want; bannerSince = now }
        bannerCheck?.cancel()
        if let next {
            bannerCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(next))
                if !Task.isCancelled { self?.settleBanner() }
            }
        }
    }
    struct Route: Equatable, Identifiable {
        enum State { case waiting, trying, connected, missed }
        let id: String
        var state: State
        var detail: String
    }
    private(set) var rows: [BoardRow] = []
    private(set) var asks: [Ask] = []
    /// How the Mac's sidebar arranges tasks: its sort and its dragged order.
    private(set) var sidebar = (sort: BoardRow.Sort.state, order: "")
    /// The workspace shown here: the phone's own, not the Mac's, so each can be on its own work.
    private(set) var workspace = UserDefaults.standard.string(forKey: "workspace") ?? "zero" {
        didSet {
            UserDefaults.standard.set(workspace, forKey: "workspace")
            Keychain.write("workspace", Data(workspace.utf8))
        }
    }
    /// zerod's sessions as they come; views read `lives`, one observed object a task, so a change to one task redraws
    /// that task's page alone, not every page reading the mirror.
    @ObservationIgnored private var mirror = ZerodMirror()
    private(set) var lives: [String: Live] = [:]

    @MainActor @Observable final class Live {
        var conversation: Conversation
        var earlier: Int
        init(_ conversation: Conversation, earlier: Int) { self.conversation = conversation; self.earlier = earlier }
    }
    @ObservationIgnored private var link: ZerodLink?
    /// Read for which Mac, and when it was last seen.
    private(set) var pairing = Pairing.load()
    /// Where Apple's push reaches this phone: told to the Mac each time the tunnel opens.
    @ObservationIgnored private var pushToken: String?
    /// The tasks open, as the navigation stack shows them: a tapped notification puts its task here.
    var path: [String] = []
    /// The tabs: Inbox, Tasks and Later, then ⋯ for the rest (recording). The app opens on the inbox.
    enum Place: Hashable { case tasks, inbox, later, record, settings }
    var tab = Place.inbox
    /// The empty inbox's arrival, owed once each time the inbox empties (and as the app opens): EmptyInbox plays it
    /// as it comes into view, then not again until the inbox fills and empties once more.
    var arrivalPending = true

    init() {
        #if DEBUG
            // A simulator has no camera, and can't be tapped from a script: its pairing link, given at launch.
            if let link = ProcessInfo.processInfo.environment["ZERO_PAIR"], Tunnel.Invite(link: link) != nil {
                Pairing.forget()
                _ = pair(link)
                return
            }
        #endif
        // Kept again, now into the Keychain group the extensions share (the app's own group before them).
        pairing?.save()
        if pairing != nil { connect() }
    }

    /// Notifications allowed, then this phone's push token asked of Apple (it comes to the app delegate).
    func askForPush() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() } }
        }
    }

    func setPushToken(_ token: String) {
        pushToken = token
        if status == .connected { Task { _ = try? await link?.call("pushToken", ["token": token]) } }
    }

    var paired: Bool { pairing != nil }

    func pair(_ link: String) -> Bool {
        guard let invite = Tunnel.Invite(link: link) else { return false }
        let fresh = Pairing(invite: invite)
        fresh.save()
        pairing = fresh
        connect()
        return true
    }

    func unpair() {
        link?.close()
        Pairing.forget()
        pairing = nil
        status = .unpaired
    }

    /// Connected to the Mac, waiting up to `seconds` for it (Siri may have woken the app for an action): whether it is.
    func ready(within seconds: Double = 12) async -> Bool {
        guard paired else { return false }
        connect()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if status == .connected, !rows.isEmpty { return true }
            if case .offline = status { connect() }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return status == .connected
    }

    /// The link for a request, waited for a few seconds while it's (re)connecting: one made in a drop's gap (the Mac's
    /// app restarting, the network changing) goes once it's back, rather than failing at once and leaving the page
    /// empty (a model list, a task's history).
    private func linked() async -> ZerodLink? {
        if status == .connected, let link { return link }
        guard await ready(within: 8) else { return nil }
        return link
    }

    /// Words put in a task's composer from elsewhere (Siri's draft): taken by the composer when it shows.
    var drafts: [String: String] = [:]

    /// The accounts with their use, as the Mac's rail shows them, the most used first (the watch's rings).
    func usage() async -> [(ZerodLink.SignIn, Usage)] {
        guard let got = try? await linked()?.signIns() else { return [] }
        return UsageShown.accounts(signins: got.list, usage: got.usage, now: Int(Date().timeIntervalSince1970))
    }

    /// The Mac's project folders, as New task offers them.
    func projects() async -> [String] { (try? await linked()?.call("projects")) as? [String] ?? [] }

    /// A task started on the Mac, in the workspace shown here: its session.
    func start(
        _ prompt: String, in folder: String, with provider: Provider, model: String?, effort: String?, permissions: Permissions = .auto
    ) async throws -> String {
        guard let link = await linked() else { throw ZerodError(message: "Not connected to your Mac") }
        return try await link.start(
            provider: provider, cwd: folder, prompt: prompt, model: model, effort: effort, permissions: permissions, workspace: workspace)
    }

    /// What the agent may do without asking; between turns, as the agent starts again with it.
    /// A model for the task: mid-turn, zerod keeps it for the next turn (as the Mac's chip does); between turns, now.
    func switchModel(_ session: String, provider: Provider, model: String, effort: String?) async {
        try? await linked()?.switchProvider(session: session, to: provider, model: model, effort: effort)
    }
    func setPermissions(_ session: String, _ permissions: Permissions) async {
        try? await linked()?.setPermissions(session: session, permissions)
    }

    func pause(_ sessions: [String] = []) async -> [String] { (try? await linked()?.pause(sessions: sessions)) ?? [] }
    func unpause(_ sessions: [String] = []) async -> [String] { (try? await linked()?.unpause(sessions: sessions)) ?? [] }
    /// A task's name (its ticket kept as it was).
    func rename(_ session: String, to name: String) async {
        try? await linked()?.label(session: session, label: name, ticket: row(session)?.ticket)
        names[session] = name
    }
    /// Put away with its workers, as the Mac's Archive.
    func archive(_ session: String) async {
        if path.contains(session) { path = [] }
        try? await linked()?.archive(session: session)
    }

    /// Back in front: the connection checked, as iOS can let it die while the app was away without saying so (zerod
    /// restarting meanwhile, the network changing), which left the app showing what it had then; made again if it's
    /// gone; the task open fetched again either way.
    func wake() async {
        guard paired else { return }
        // Back in front: how long it was out while the app was away isn't how long it's failed to connect.
        if lostAt != nil { lostAt = Date(); settleBanner() }
        guard let link else { connect(); return }
        let answered = Answered()
        Task { if (try? await link.call("board")) != nil { answered.yes = true } }
        for _ in 0..<40 where !answered.yes { try? await Task.sleep(for: .milliseconds(100)) }
        guard self.link === link else { return }
        if answered.yes {
            for id in path { await load(id, again: true) }
            // Back in front: what's shown checked against how things are now.
            tidyShown()
        } else {
            Log.write("phone: the connection went quiet while away; connecting again")
            link.close()
            self.link = nil
            connect()
        }
    }
    private final class Answered: @unchecked Sendable { var yes = false }

    /// Tries in a row that didn't connect: the next waits longer (Views' reconnect), from half a second up to four.
    @ObservationIgnored var retries = 0
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    /// While the app is in front, a small request every 25 s, there and back: no answer in 10 s and the connection is
    /// dead without having said so (the network changed under it), so it's dropped and made again. Any answer counts.
    /// A request, not a WebSocket ping: the relay's hibernating sockets aren't sure to answer those.
    private func beat(_ link: ZerodLink) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled, self.link === link else { return }
                guard UIApplication.shared.applicationState == .active else { continue }
                let answered = Answered()
                Task {
                    _ = try? await link.call("hello"); answered.yes = true
                }
                for _ in 0..<100 where !answered.yes { try? await Task.sleep(for: .milliseconds(100)) }
                guard self.link === link, !answered.yes else { continue }
                Log.write("phone: no answer for 10 s; connecting again")
                link.close()
                self.link = nil
                self.status = .offline("Reconnecting to your Mac")
            }
        }
    }

    /// Connects, unless connected or connecting already: on launch, coming back to the foreground, after a drop.
    func connect() {
        guard let pairing, link == nil, !connecting else { return }
        connecting = true
        status = .connecting
        Task {
            let lines = await lines(for: pairing)
            connecting = false
            guard let lines else { status = .offline("The relay's address is wrong"); return }
            start(lines)
        }
    }
    @ObservationIgnored private var connecting = false

    /// The way to the Mac: the relay.
    private func lines(for pairing: Pairing) async -> TunnelLines? {
        routes = [Route(id: "Relay", state: .trying, detail: "Connecting")]
        return try? TunnelLines(pairing: pairing)
    }

    private func start(_ lines: TunnelLines) {
        lines.onHeard = { [weak self] in
            Task { @MainActor in
                guard let self, var kept = self.pairing, kept.code != nil else { return }
                // The Mac took the code: paired for good.
                kept.code = nil
                kept.save()
                self.pairing = kept
            }
        }
        let link = ZerodLink(connection: lines)
        self.link = link
        modelsKept = [:]
        link.onFeed = { [weak self] feed in
            Task { @MainActor in
                guard let self else { return }
                switch feed {
                case .board(let rows):
                    let before = self.rows
                    self.rows = rows
                    self.tidy(after: before)
                    ZeroIndex.update(rows)
                    await self.arrange()
                    await self.name(rows)
                case .later: await self.loadLater()
                // Seen on the Mac: off here too, now (the quiet push for it may never come).
                case .clear(let ids): UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
                // The workspaces changed (one added, renamed, removed): the picker follows.
                case .workspaces: await self.loadWorkspaces()
                default: break
                }
            }
        }
        link.onMessage = { [weak self] message in Task { @MainActor in self?.receive(message) } }
        link.onInbox = { [weak self] message in Task { @MainActor in self?.inbox(message) } }
        link.onClose = { [weak self] in
            Task { @MainActor in
                guard let self, self.link === link else { return }
                self.link = nil
                self.status = .offline("Can't reach \(self.pairing?.name ?? "your Mac"). Zero needs to be open there.")
            }
        }
        Task {
            do {
                // Answered through the tunnel: connected, the badge gone; the rest loads behind it. (Marked only once
                // all of it had come, one request after another over the relay, the badge stayed seconds longer.)
                if await arrange(now: true), self.link === link { status = .connected; retries = 0 }
                await loadWorkspaces()
                await loadLater()
                try await link.subscribeLazily()
                // The tasks it has copies of may have moved on while it was away: the one open, fetched again.
                for id in path { await load(id, again: true) }
                try await link.followInbox()
                if let pushToken { _ = try? await link.call("pushToken", ["token": pushToken]) }
                status = .connected
                retries = 0
                beat(link)
                // The terminal app its tasks open in, for "In Ghostty" (as the Mac's pill says it).
                if let app = try? await link.terminal().app {
                    terminalName = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
                }
                // The Mac's name, and that it was seen now.
                if var kept = pairing {
                    if let name = try? await link.call("name") as? String { kept.name = name }
                    kept.seen = .now
                    kept.save()
                    pairing = kept
                }
            } catch {
                // Dropped, so pulling to refresh (or coming back to the app) connects again.
                link.close()
                if self.link === link { self.link = nil }
                status = .offline((error as? ZerodError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func inbox(_ message: ZerodLink.InboxMessage) {
        switch message {
        case let .asks(all, _, _): asks = all; asksKnown = true
        case let .ask(ask):
            if let index = asks.firstIndex(where: { $0.id == ask.id }) { asks[index] = ask } else { asks.append(ask) }
        case let .removed(id): asks.removeAll { $0.id == id }
        case .output, .agents: break
        }
    }

    /// Notifications for what no longer needs the user (an answer seen, a task moved on, an ask answered) taken off
    /// the phone itself, whether or not the Mac's quiet push for them came: iOS rations those, and drops them for an app
    /// closed. On each new board, the tasks that moved on; on the first since connecting, every notification shown.
    private func tidy(after before: [BoardRow]) {
        let center = UNUserNotificationCenter.current()
        if !before.isEmpty {
            let cleared = TaskAlerts.changes(from: before, to: rows).cleared
            if !cleared.isEmpty { center.removeDeliveredNotifications(withIdentifiers: cleared) }
            return
        }
        tidyShown()
    }

    /// Every notification shown, against the board (and the asks, once they've come): those for nothing that needs
    /// the user now are taken off. Never without a board: an empty one would take them all.
    private func tidyShown() {
        guard !rows.isEmpty else { return }
        let (rows, asks, asksKnown) = (rows, asks, asksKnown)
        Task {
            let center = UNUserNotificationCenter.current()
            let shown = await center.deliveredNotifications().map(\.request.identifier)
            let stale = shown.filter { id in
                if id.hasPrefix(TaskAlerts.askPrefix) {
                    return asksKnown && !asks.contains { TaskAlerts.askPrefix + $0.id == id && $0.state == .waiting }
                }
                return rows.first { $0.session == id }.flatMap(TaskAlerts.standing) == nil
            }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }
    @ObservationIgnored private var asksKnown = false

    /// The tasks as the Mac's sidebar lists them.
    var tasks: [BoardRow] { BoardRow.sorted(rows.filter { $0.workspace == workspace }, by: sidebar.sort, order: sidebar.order) }

    /// The Mac's arrangement again: asked with a board, as dragging or sorting there doesn't move the board; at most
    /// every few seconds, as a board comes up to four times a second while tasks work.
    @ObservationIgnored private var arranged = Date.distantPast
    /// Whether the Mac answered.
    @discardableResult private func arrange(now: Bool = false) async -> Bool {
        guard now || Date().timeIntervalSince(arranged) > 5 else { return false }
        arranged = Date()
        guard let got = try? await link?.call("sidebar", [:]) as? [String: String] else { return false }
        sidebar = (BoardRow.Sort(rawValue: got["sort"] ?? "") ?? .state, got["order"] ?? "")
        return true
    }

    /// Each worker's name, as the Mac's sidebar has it: asked of zerod when the board shows a worker not named yet.
    private(set) var names: [String: String] = [:]
    private func name(_ rows: [BoardRow]) async {
        guard rows.flatMap({ $0.team ?? [] }).contains(where: { names[$0.session] == nil }),
            let all = try? await link?.list()
        else { return }
        names = Dictionary(all.map { ($0.id, TaskName.of($0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// The user's workspaces, as zerod has them.
    private(set) var workspaces: [ZerodLink.Workspace] = []

    func loadWorkspaces() async {
        if let all = try? await link?.workspaces(), all != workspaces { workspaces = all }
        // The one shown here deleted: Zero's.
        if !workspaces.isEmpty, !workspaces.contains(where: { $0.id == workspace }) { workspace = "zero" }
    }

    /// Shown here; the Mac stays on its own.
    func switchWorkspace(_ id: String) {
        guard id != workspace else { return }
        workspace = id
        path = []
    }

    var currentWorkspace: ZerodLink.Workspace? { workspaces.first { $0.id == workspace } }

    /// A task of another workspace opened (a notification, Siri): the list goes to its workspace, the task kept open.
    func follow(_ session: String) {
        if let home = row(session)?.workspace, home != workspace { workspace = home }
    }

    /// The asks waiting on the user, oldest first.
    var waiting: [Ask] {
        asks.filter { ($0.state == .waiting || $0.state == .pending) && $0.isForYou }.sorted { $0.createdAt < $1.createdAt }
    }

    func conversation(_ id: String) -> Conversation? { lives[id]?.conversation }

    /// The terminal app the Mac opens tasks in, by its name: "In Ghostty" on a task open there.
    private(set) var terminalName = "Terminal"

    #if DEBUG
        /// A conversation of the UI tests' own, as if zerod had sent it (TaskTestPage).
        func showForTests(_ conversation: Conversation, earlier: Int = 0) {
            _ = mirror.receive(.session(conversation))
            _ = mirror.receive(.earlier(session: conversation.id, count: earlier))
            sync(conversation.id)
        }
        /// A message of the user's that zerod sends on by itself (one queued), with no lift.
        func addedForTests(_ text: String, to session: String) {
            guard var conversation = mirror.conversations[session] else { return }
            conversation.items.append(
                ConversationItem(
                    id: "added-" + UUID().uuidString, turn: nil, kind: .user(text: text, images: []), status: .done,
                    at: Int(Date().timeIntervalSince1970 * 1000)))
            showForTests(conversation)
        }
    #endif

    private func receive(_ message: ZerodMirror.Message) {
        let kept = mirror.receive(message)
        switch message {
        case let .session(conversation): sync(conversation.id)
        case let .earlier(session, _): sync(session)
        case let .change(event) where kept: soon(event.session)
        // Fallen behind on a task it holds (a change skipped): its latest fetched again, rather than left stale.
        case let .change(event): if lives[event.session] != nil { Task { await load(event.session, again: true) } }
        }
    }

    /// A streaming answer changes many times a second: its page is brought up to date once a tenth of a second, not
    /// for every piece, so a long conversation isn't drawn again for each word.
    @ObservationIgnored private var pending: Set<String> = []
    private func soon(_ id: String) {
        guard pending.insert(id).inserted else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            pending.remove(id)
            sync(id)
        }
    }

    /// The task's observed copy brought up to the mirror.
    private func sync(_ id: String) {
        guard let conversation = mirror.conversations[id] else { lives[id] = nil; return }
        let earlier = mirror.earlier[id] ?? 0
        if let live = lives[id] {
            live.conversation = conversation
            if live.earlier != earlier { live.earlier = earlier }
        } else {
            lives[id] = Live(conversation, earlier: earlier)
        }
    }

    /// A task opened: its latest items fetched, unless they're here already (it moved since connecting).
    func load(_ id: String, again: Bool = false) async {
        guard again || mirror.conversations[id] == nil, let (conversation, earlier) = try? await linked()?.recent(session: id) else {
            return
        }
        mirror.receive(.session(conversation))
        mirror.receive(.earlier(session: id, count: earlier))
        sync(id)
    }

    func send(_ text: String, to session: String) async {
        try? await linked()?.send(session: session, text: text)
    }

    func choose(_ ask: Ask, option: Int) async {
        acted(ask, option: option, text: nil)
        if answeredForTests(ask, option: option, text: nil) { return }
        try? await linked()?.choose(ask.id, option: option)
    }
    func answer(_ ask: Ask, option: Int, text: String) async {
        acted(ask, option: option, text: text)
        if answeredForTests(ask, option: option, text: text) { return }
        try? await linked()?.answer(ask.id, option: option, text: text)
    }
    func reply(_ ask: Ask, text: String) async {
        acted(ask, option: nil, text: text)
        if answeredForTests(ask, option: nil, text: text) { return }
        try? await linked()?.reply(ask.id, text: text)
    }

    /// An ask answered in words (Siri, the watch): what it was answered with; nil when the words answer none of its
    /// options (Ask.spoken).
    func answer(_ ask: Ask, saying said: String) async -> String? {
        switch ask.spoken(said) {
        case let .option(index): await choose(ask, option: index); return ask.options[index]
        case let .words(index, text): await answer(ask, option: index, text: text); return text
        case let .reply(text): await reply(ask, text: text); return text
        case nil: return nil
        }
    }

    /// The user's answers to a task's asks, counted by task: what comes of one (the agent told, its reply) is the user
    /// acting in that task, as a message sent is, and its page lifts it (TaskView).
    private(set) var acted: [String: Int] = [:]
    private func acted(_ ask: Ask, option: Int?, text: String?) {
        if let session = ask.session { acted[session, default: 0] += 1 }
    }

    #if DEBUG
        /// zerod's side of a message sent from the UI tests' task (no Mac): its copy of the message, keeping the id
        /// `send` gave it as `sent` (as zerod does), then the agent's long reply, which reads out.
        private func sentForTests(_ text: String, to session: String, id: String) async -> Bool {
            guard session.hasPrefix("test-"), var conversation = mirror.conversations[session] else { return false }
            try? await Task.sleep(for: .milliseconds(500))
            let at = Int(Date().timeIntervalSince1970 * 1000)
            conversation.items.append(
                ConversationItem(id: "sent-" + id, turn: nil, kind: .user(text: text, images: []), status: .done, at: at, sent: id))
            conversation.status = .working
            showForTests(conversation)
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                var lines = (1...14).map { "Line \($0) of a long reply, read out a word at a time, long enough to wrap on the phone." }
                // A wide table in the middle, read out row by row, cut off at the page's edge.
                lines.insert(
                    "| Step | What it does | Where it runs | What's left to check |\n|---|---|---|---|\n"
                        + "| One | Reads the conversation | On the phone | Nothing |\n| Two | Lifts the message sent | In the page's scroll | The room |\n"
                        + "| Three | Follows the keyboard | Every frame | The curve |", at: 3)
                conversation.items.append(
                    ConversationItem(
                        id: "reply-" + id, turn: nil, kind: .agent(text: lines.joined(separator: "\n\n"), finalAnswer: true), status: .done,
                        at: at + 1300))
                conversation.status = .idle
                showForTests(conversation)
            }
            return true
        }

        /// zerod's side of a message queued from the UI tests' task: held a moment, then sent on (into the
        /// conversation) as the turn it waited for ends.
        private func queuedForTests(_ text: String, to session: String) async -> Bool {
            guard session.hasPrefix("test-"), var conversation = mirror.conversations[session] else { return false }
            try? await Task.sleep(for: .milliseconds(1500))
            conversation.items.append(
                ConversationItem(
                    id: "queued-sent-" + UUID().uuidString, turn: nil, kind: .user(text: text, images: []), status: .done,
                    at: Int(Date().timeIntervalSince1970 * 1000)))
            conversation.status = .idle
            showForTests(conversation)
            return true
        }

        /// An ask of the UI tests' own (TaskTestPage), on its task.
        func showForTests(_ ask: Ask) { asks.append(ask) }

        /// Answered with no Mac (the UI tests' task): the ask answered, then what zerod and the agent would send.
        private func answeredForTests(_ ask: Ask, option: Int?, text: String?) -> Bool {
            guard let session = ask.session, session.hasPrefix("test-"), var conversation = mirror.conversations[session] else {
                return false
            }
            if let index = asks.firstIndex(where: { $0.id == ask.id }) {
                asks[index].state = .answered
                asks[index].choice = option
                asks[index].answer = text ?? option.map { ask.options[$0] }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                let at = Int(Date().timeIntervalSince1970 * 1000)
                conversation.items.append(
                    ConversationItem(
                        id: "answered-" + ask.id, turn: nil,
                        kind: .user(
                            text:
                                "<!-- from: zero -->\nThe user answered your ask \(ask.id) (\"\(ask.title)\"): \(option.map { ask.options[$0] } ?? text ?? "")",
                            images: []),
                        status: .done, at: at))
                conversation.items.append(
                    ConversationItem(
                        id: "reply-" + ask.id, turn: nil, kind: .agent(text: "Thanks, going on with that.", finalAnswer: true),
                        status: .done, at: at + 500))
                showForTests(conversation)
            }
            return true
        }
    #else
        private func answeredForTests(_ ask: Ask, option: Int?, text: String?) -> Bool { false }
        private func sentForTests(_ text: String, to session: String, id: String) async -> Bool { false }
        private func queuedForTests(_ text: String, to session: String) async -> Bool { false }
    #endif
    func deliver(_ ask: Ask) async { try? await linked()?.deliver(ask.id) }
    /// An answer taken back in the moment before it goes (the Mac's take-back window): the ask waits again.
    func takeBack(_ ask: Ask) async { _ = try? await linked()?.takeBack(ask.id) }
    func decide(session: String, approval: String, choice: String) async {
        acted[session, default: 0] += 1
        try? await linked()?.decide(session: session, approval: approval, choice: choice)
    }
    func answer(session: String, question: String, answers: [String: [String]]) async {
        acted[session, default: 0] += 1
        try? await linked()?.answer(session: session, question: question, answers: answers)
    }

    /// Images sent to a task: each kept on the Mac (its "upload"), then the message naming them.
    func send(_ text: String, images: [Data], videos: [URL] = [], to session: String, model: String? = nil, effort: String? = nil)
        async throws
    {
        // Shown at once, while its videos upload and its agent starts: the conversation's own takes its place, known
        // by this one's id (zerod keeps it as `sent`). Without it, zerod's copy was a new message to Playback, and the
        // bubble was gone for a beat (measured: 117 ms) between the two.
        let echo = Sending(text: text, images: [])
        sending[session, default: []].append(echo)
        defer { sending[session]?.removeAll { $0.id == echo.id } }
        if await sentForTests(text, to: session, id: echo.id) { return }
        guard let link = await linked() else { throw ZerodError(message: "Not connected to your Mac") }
        let text = try await withVideos(text, videos, through: link)
        try await link.send(session: session, text: text, images: upload(images, through: link), model: model, effort: effort, id: echo.id)
    }

    /// Messages sent from here that their conversation doesn't have yet, by session.
    private(set) var sending: [String: [Sending]] = [:]
    /// Messages queued from here that the task's row doesn't list yet, by session.
    private(set) var queuing: [String: [Queued]] = [:]

    /// For after the task's current turn: queued behind what's waiting, as the Mac's Return while it works.
    func queue(_ text: String, images: [Data], videos: [URL] = [], to session: String) async throws {
        // In the queue's strip at once, until zerod's row has it (by the same id): nothing showed it for 200 ms.
        let id = "queued-" + UUID().uuidString
        queuing[session, default: []].append(Queued(id: id, text: text, images: nil))
        defer { queuing[session]?.removeAll { $0.id == id } }
        if await queuedForTests(text, to: session) { return }
        guard let link = await linked() else { throw ZerodError(message: "Not connected to your Mac") }
        let text = try await withVideos(text, videos, through: link)
        try await link.queue(session: session, text: text, images: upload(images, through: link), id: id)
    }

    /// Videos sent to a task, as the Mac's composer sends them (Attachments.withVideos): each kept on the Mac, and a
    /// line after the words saying where it is and that `zero video` cuts its frames (an agent's CLI doesn't take a video).
    private func withVideos(_ text: String, _ videos: [URL], through link: ZerodLink) async throws -> String {
        var out = text
        for (index, video) in videos.enumerated() {
            let data = try Data(contentsOf: video)
            let name = "video-\(index + 1)." + (video.pathExtension.isEmpty ? "mov" : video.pathExtension)
            guard let path = try await link.call("upload", ["name": name, "data": data.base64EncodedString()]) as? String else { continue }
            out += "\n\n[Video #\(index + 1): \(path). It's a video: cut the frames you need with `zero video \"\(path)\"`.]"
            try? FileManager.default.removeItem(at: video)
        }
        return out
    }

    private func upload(_ images: [Data], through link: ZerodLink) async throws -> [String] {
        var paths: [String] = []
        for (index, image) in images.enumerated() {
            if let path = try await link.call("upload", ["name": "photo-\(index + 1).jpg", "data": image.base64EncodedString()]) as? String
            {
                paths.append(path)
            }
        }
        return paths
    }

    /// Being written to while its agent has stopped: started in the background, at most once a minute, so the message
    /// doesn't wait for it. Never for a task the user has paused.
    func warm(_ session: String) {
        guard let row = row(session), !row.online, row.ownState != .paused, Date().timeIntervalSince(warmed[session] ?? .distantPast) > 60
        else { return }
        warmed[session] = Date()
        Task { try? await linked()?.resume(session: session) }
    }
    @ObservationIgnored private var warmed: [String: Date] = [:]

    func unqueue(_ session: String, item: String) async -> Bool { (try? await linked()?.unqueue(session: session, item: item)) != nil }
    /// A queued message sent now, mid-turn, its images as they were kept on the Mac.
    func steer(_ session: String, item: Queued) async {
        guard await unqueue(session, item: item.id) else { return }
        try? await linked()?.send(session: session, text: item.text, images: item.images ?? [])
    }
    func release(_ session: String) async { try? await linked()?.release(session: session) }
    func interrupt(_ session: String) async { try? await linked()?.interrupt(session: session) }
    /// A task's row on the board: a lead's own, or a worker's from its lead's team.
    func row(_ session: String) -> BoardRow? { rows.first { $0.session == session } ?? rows.lazy.compactMap { $0.member(session) }.first }

    /// A model a task can be switched to, and the reasoning levels it takes.
    struct ModelChoice: Identifiable {
        var id: String
        var name: String
        var levels: [(id: String, name: String)]
        var defaultLevel: String?
        /// What it's for, its context window, who makes it, and its logo's name (claude, openai), as the Mac's selector.
        var detail = ""
        var context = ""
        var provider = ""
        var icon = ""
    }

    /// A provider's models, as the Mac's selector offers them: asked once a connection.
    @ObservationIgnored private var modelsKept: [Provider: [ModelChoice]] = [:]
    func models(_ provider: Provider) async -> [ModelChoice] {
        if let kept = modelsKept[provider] { return kept }
        let found = await fetchModels(provider)
        if !found.isEmpty { modelsKept[provider] = found }
        return found
    }

    private func fetchModels(_ provider: Provider) async -> [ModelChoice] {
        guard let all = try? await linked()?.call("models", ["provider": provider.rawValue]) as? [[String: Any]] else { return [] }
        return all.compactMap { model in
            guard let id = model["id"] as? String, let name = model["name"] as? String else { return nil }
            let levels = (model["levels"] as? [[String: String]] ?? []).compactMap { level in
                level["id"].flatMap { id in level["name"].map { (id, $0) } }
            }
            let text = { (key: String) in (model[key] as? String) ?? "" }
            return ModelChoice(
                id: id, name: name, levels: levels, defaultLevel: text("defaultLevel").isEmpty ? nil : text("defaultLevel"),
                detail: text("detail"), context: text("context"), provider: text("provider"), icon: text("icon"))
        }
    }

    /// What's saved for later, without artifacts.
    private(set) var later: [ZerodLink.LaterItem] = []

    func loadLater() async {
        if let items = try? await link?.laterItems() { later = items }
    }

    func laterItem(_ id: String) async -> ZerodLink.LaterItem? { try? await linked()?.laterItem(id) }

    func editLater(_ id: String, _ fields: [String: Any]) async {
        try? await linked()?.editLater(id, fields)
        await loadLater()
    }

    /// The whole task saved for later, as the Mac's: off the board and on hold, with its workers, until resumed.
    func saveForLater(_ session: String) async {
        if path.contains(session) { path = [] }
        try? await linked()?.saveForLater(session: session)
        await loadLater()
    }

    /// A task saved for later back among the tasks, off hold: its session.
    func resumeLater(_ item: String) async -> String? {
        let session = (try? await linked()?.resumeLater(item)) ?? nil
        await loadLater()
        return session
    }

    /// The user is reading this task: its latest reply is seen, on every client (zerod settles Replied a while on).
    func markSeen(_ session: String) {
        guard let link else { return }
        Task {
            try? await link.seen(session: session)
            // Its notification goes from the Mac too, as one looked at there goes from here.
            _ = try? await link.call("looked", ["session": session])
        }
    }

    /// An image in a message, from the Mac, no bigger than `side` pixels: kept once fetched.
    @ObservationIgnored private let images: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>(); c.countLimit = 150; return c
    }()
    func image(_ path: String, side: Int) async -> UIImage? {
        let key = "\(side)|\(path)" as NSString
        if let kept = images.object(forKey: key) { return kept }
        guard let encoded = try? await linked()?.call("image", ["path": path, "side": side]) as? String,
            let data = Data(base64Encoded: encoded), let image = UIImage(data: data)
        else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// How many of a task's items came before those loaded.
    func earlier(_ session: String) -> Int { lives[session]?.earlier ?? 0 }

    /// The page of a task's items before those loaded.
    func loadEarlier(_ session: String) async {
        guard earlier(session) > 0,
            let page = try? await linked()?.items(session: session, before: mirror.conversations[session]?.items.first?.id)
        else { return }
        mirror.prepend(session, items: page, remaining: max(0, earlier(session) - page.count))
        sync(session)
    }
}
