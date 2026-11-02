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
    private(set) var status = Status.unpaired
    private(set) var rows: [BoardRow] = []
    private(set) var asks: [Ask] = []
    /// How the Mac's sidebar arranges tasks: its sort, its dragged order and the workspace it shows.
    private(set) var sidebar = (sort: BoardRow.Sort.state, order: "", workspace: "zero")
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
    @ObservationIgnored private var pairing = Pairing.load()
    /// Where Apple's push reaches this phone: told to the Mac each time the tunnel opens.
    @ObservationIgnored private var pushToken: String?
    /// The tasks open, as the navigation stack shows them: a tapped notification puts its task here.
    var path: [String] = []
    enum Place: Hashable { case tasks, later, record }
    var tab = Place.tasks

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

    /// Connects, unless connected or connecting already: on launch, coming back to the foreground, after a drop.
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

    /// Words put in a task's composer from elsewhere (Siri's draft): taken by the composer when it shows.
    var drafts: [String: String] = [:]

    /// The MCP servers tasks are given, as the Mac lists them for a phone: name, how it runs, where; no values.
    func mcpServers() async -> [[String: Any]] { (try? await link?.call("mcpServers")) as? [[String: Any]] ?? [] }

    /// The Mac's project folders, as New task offers them.
    func projects() async -> [String] { (try? await link?.call("projects")) as? [String] ?? [] }

    /// A task started on the Mac, in the workspace shown here: its session.
    func start(_ prompt: String, in folder: String, with provider: Provider, model: String?, effort: String?) async throws -> String {
        guard let link else { throw ZerodError(message: "Not connected to your Mac") }
        return try await link.start(provider: provider, cwd: folder, prompt: prompt, model: model, effort: effort, workspace: sidebar.workspace)
    }

    func pause(_ sessions: [String] = []) async -> [String] { (try? await link?.pause(sessions: sessions)) ?? [] }
    func unpause(_ sessions: [String] = []) async -> [String] { (try? await link?.unpause(sessions: sessions)) ?? [] }

    /// Back in front: the connection checked, as iOS can let it die while the app was away without saying so (zerod
    /// restarting meanwhile, the network changing), which left the app showing what it had then; made again if it's
    /// gone; the task open fetched again either way.
    func wake() async {
        guard paired else { return }
        guard let link else { connect(); return }
        let answered = Answered()
        Task { if (try? await link.call("board")) != nil { answered.yes = true } }
        for _ in 0..<40 where !answered.yes { try? await Task.sleep(for: .milliseconds(100)) }
        guard self.link === link else { return }
        if answered.yes {
            for id in path { await load(id, again: true) }
        } else {
            Log.write("phone: the connection went quiet while away; connecting again")
            link.close()
            self.link = nil
            connect()
        }
    }
    private final class Answered: @unchecked Sendable { var yes = false }

    func connect() {
        guard let pairing, link == nil else { return }
        status = .connecting
        guard let lines = try? TunnelLines(pairing: pairing) else { status = .offline("The relay's address is wrong"); return }
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
                    self.rows = rows
                    ZeroIndex.update(rows)
                    await self.arrange()
                    await self.name(rows)
                case .later: await self.loadLater()
                // The Mac's workspace changed, or the workspaces did: the list follows it.
                case .workspaces:
                    await self.loadWorkspaces()
                    await self.arrange(now: true)
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
                self.status = .offline("Can't reach your Mac: Zero needs to be running there")
            }
        }
        Task {
            do {
                await arrange(now: true)
                await loadWorkspaces()
                await loadLater()
                try await link.subscribeLazily()
                // The tasks it has copies of may have moved on while it was away: the one open, fetched again.
                for id in path { await load(id, again: true) }
                try await link.followInbox()
                if let pushToken { _ = try? await link.call("pushToken", ["token": pushToken]) }
                status = .connected
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
        case let .asks(all, _, _): asks = all
        case let .ask(ask):
            if let index = asks.firstIndex(where: { $0.id == ask.id }) { asks[index] = ask } else { asks.append(ask) }
        case let .removed(id): asks.removeAll { $0.id == id }
        case .output, .agents: break
        }
    }

    /// The tasks as the Mac's sidebar lists them.
    var tasks: [BoardRow] { BoardRow.sorted(rows.filter { $0.workspace == sidebar.workspace }, by: sidebar.sort, order: sidebar.order) }

    /// The Mac's arrangement again: asked with a board, as dragging or sorting there doesn't move the board; at most
    /// every few seconds, as a board comes up to four times a second while tasks work.
    @ObservationIgnored private var arranged = Date.distantPast
    private func arrange(now: Bool = false) async {
        guard now || Date().timeIntervalSince(arranged) > 5 else { return }
        arranged = Date()
        guard let got = try? await link?.call("sidebar", [:]) as? [String: String] else { return }
        sidebar = (BoardRow.Sort(rawValue: got["sort"] ?? "") ?? .state, got["order"] ?? "", got["workspace"] ?? "zero")
    }

    /// Each worker's name, as the Mac's sidebar has it: asked of zerod when the board shows a worker not named yet.
    private(set) var names: [String: String] = [:]
    private func name(_ rows: [BoardRow]) async {
        guard rows.flatMap({ $0.team ?? [] }).contains(where: { names[$0.session] == nil }),
              let all = try? await link?.list() else { return }
        names = Dictionary(all.map { ($0.id, TaskName.of($0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// The user's workspaces, as zerod has them; the one shown is the Mac's (`sidebar.workspace`) unless chosen here.
    private(set) var workspaces: [ZerodLink.Workspace] = []

    func loadWorkspaces() async {
        if let all = try? await link?.workspaces(), all != workspaces { workspaces = all }
    }

    /// Shown here at once, and on the Mac too: the two show the same workspace.
    func switchWorkspace(_ id: String) {
        guard id != sidebar.workspace else { return }
        sidebar.workspace = id
        path = []
        Task { _ = try? await link?.call("setWorkspace", ["workspace": id]) }
    }

    var currentWorkspace: ZerodLink.Workspace? { workspaces.first { $0.id == sidebar.workspace } }

    /// The asks waiting on the user, oldest first.
    var waiting: [Ask] { asks.filter { $0.state == .waiting && $0.kind != .note && $0.kind != .message && $0.sameAs == nil }.sorted { $0.createdAt < $1.createdAt } }

    func conversation(_ id: String) -> Conversation? { lives[id]?.conversation }

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
        guard again || mirror.conversations[id] == nil, let (conversation, earlier) = try? await link?.recent(session: id) else { return }
        mirror.receive(.session(conversation))
        mirror.receive(.earlier(session: id, count: earlier))
        sync(id)
    }

    func send(_ text: String, to session: String) async {
        try? await link?.send(session: session, text: text)
    }

    func choose(_ ask: Ask, option: Int) async { try? await link?.choose(ask.id, option: option) }
    func answer(_ ask: Ask, option: Int, text: String) async { try? await link?.answer(ask.id, option: option, text: text) }
    func reply(_ ask: Ask, text: String) async { try? await link?.reply(ask.id, text: text) }
    func deliver(_ ask: Ask) async { try? await link?.deliver(ask.id) }
    func decide(session: String, approval: String, choice: String) async { try? await link?.decide(session: session, approval: approval, choice: choice) }
    func answer(session: String, question: String, answers: [String: [String]]) async {
        try? await link?.answer(session: session, question: question, answers: answers)
    }

    /// Images sent to a task: each kept on the Mac (its "upload"), then the message naming them.
    func send(_ text: String, images: [Data], to session: String, model: String? = nil, effort: String? = nil) async throws {
        guard let link else { throw ZerodError(message: "Not connected to your Mac") }
        try await link.send(session: session, text: text, images: upload(images, through: link), model: model, effort: effort)
    }

    /// For after the task's current turn: queued behind what's waiting, as the Mac's Return while it works.
    func queue(_ text: String, images: [Data], to session: String) async throws {
        guard let link else { throw ZerodError(message: "Not connected to your Mac") }
        try await link.queue(session: session, text: text, images: upload(images, through: link))
    }

    private func upload(_ images: [Data], through link: ZerodLink) async throws -> [String] {
        var paths: [String] = []
        for (index, image) in images.enumerated() {
            if let path = try await link.call("upload", ["name": "photo-\(index + 1).jpg", "data": image.base64EncodedString()]) as? String { paths.append(path) }
        }
        return paths
    }

    func unqueue(_ session: String, item: String) async -> Bool { (try? await link?.unqueue(session: session, item: item)) != nil }
    /// A queued message sent now, mid-turn, its images as they were kept on the Mac.
    func steer(_ session: String, item: Queued) async {
        guard await unqueue(session, item: item.id) else { return }
        try? await link?.send(session: session, text: item.text, images: item.images ?? [])
    }
    func release(_ session: String) async { try? await link?.release(session: session) }
    func interrupt(_ session: String) async { try? await link?.interrupt(session: session) }
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
        guard let all = try? await link?.call("models", ["provider": provider.rawValue]) as? [[String: Any]] else { return [] }
        return all.compactMap { model in
            guard let id = model["id"] as? String, let name = model["name"] as? String else { return nil }
            let levels = (model["levels"] as? [[String: String]] ?? []).compactMap { level in level["id"].flatMap { id in level["name"].map { (id, $0) } } }
            let text = { (key: String) in (model[key] as? String) ?? "" }
            return ModelChoice(id: id, name: name, levels: levels, defaultLevel: text("defaultLevel").isEmpty ? nil : text("defaultLevel"),
                               detail: text("detail"), context: text("context"), provider: text("provider"), icon: text("icon"))
        }
    }

    /// What's saved for later, without artifacts.
    private(set) var later: [ZerodLink.LaterItem] = []

    func loadLater() async {
        if let items = try? await link?.laterItems() { later = items }
    }

    func laterItem(_ id: String) async -> ZerodLink.LaterItem? { try? await link?.laterItem(id) }

    func editLater(_ id: String, _ fields: [String: Any]) async {
        try? await link?.editLater(id, fields)
        await loadLater()
    }

    /// The task's agent asked to save what it has for later; it writes the note and the artifact.
    func askToSaveForLater(_ session: String) async {
        try? await link?.notify(session: session, text: LaterAsk.text(), from: "zero")
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
    @ObservationIgnored private let images: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 150; return c }()
    func image(_ path: String, side: Int) async -> UIImage? {
        let key = "\(side)|\(path)" as NSString
        if let kept = images.object(forKey: key) { return kept }
        guard let encoded = try? await link?.call("image", ["path": path, "side": side]) as? String,
              let data = Data(base64Encoded: encoded), let image = UIImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// How many of a task's items came before those loaded.
    func earlier(_ session: String) -> Int { lives[session]?.earlier ?? 0 }

    /// The page of a task's items before those loaded.
    func loadEarlier(_ session: String) async {
        guard earlier(session) > 0, let page = try? await link?.items(session: session, before: mirror.conversations[session]?.items.first?.id) else { return }
        mirror.prepend(session, items: page, remaining: max(0, earlier(session) - page.count))
        sync(session)
    }
}
