import Foundation
import Observation
import WatchConnectivity

/// The watch's way to the Mac: the phone sends it what it shows (WatchState) as the board, the asks or the accounts'
/// use change, and does what's tapped on it (answer, message, pause, stop, start) as the phone's own pages do. The
/// watch never reaches the relay itself.
@MainActor final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    private let model = PhoneModel.shared
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var sent: WatchState?
    private var accounts: [WatchState.Account] = []
    private var accountsRead = Date.distantPast
    private var soon: Task<Void, Never>?

    func start() {
        guard let session else { return }
        session.delegate = self
        session.activate()
        watch()
    }

    /// Sent again whenever what it's made of changes: once a second at most, as a board comes four times a second.
    private func watch() {
        withObservationTracking {
            _ = model.rows; _ = model.asks; _ = model.status
        } onChange: {
            Task { @MainActor in
                self.watch()
                self.later()
            }
        }
    }

    private func later() {
        guard soon == nil else { return }
        soon = Task {
            try? await Task.sleep(for: .seconds(1))
            await readAccounts()
            soon = nil
            send()
        }
    }

    /// Woken for it (a push came, the watch asked): connected first, then sent.
    func refresh() async {
        guard let session, session.isPaired, session.isWatchAppInstalled else { return }
        _ = await model.ready(within: 8)
        await readAccounts(force: true)
        send()
    }

    private func readAccounts(force: Bool = false) async {
        guard force || Date().timeIntervalSince(accountsRead) > 300 else { return }
        accountsRead = Date()
        let now = Date()
        accounts = await model.usage().map { signin, usage in
            let window = { (name: String) in usage.windows.first { $0.name == name } }
            return WatchState.Account(
                id: signin.id, cli: signin.cli.rawValue, label: signin.label, week: window("7 days")?.used,
                weekResets: window("7 days")?.resetsAt, five: window("5 hours")?.used, fiveResets: window("5 hours")?.resetsAt,
                limitedUntil: UsageShown.limited(usage, now: Int(now.timeIntervalSince1970)) ? (usage.resetsAt ?? Int.max) : nil)
        }
    }

    var state: WatchState {
        let tasks = model.rows.map { row in
            WatchState.Task(
                id: row.session, name: row.task, state: row.ownState.rawValue,
                line: (row.needs ?? row.now).map { TaskAlerts.plain($0, limit: 160) })
        }
        let asks = model.waiting.map { ask in
            WatchState.Ask(
                id: ask.id, from: ask.session.flatMap { model.row($0)?.task } ?? ask.agent.label ?? ask.agent.name,
                title: TaskAlerts.plain(ask.title, limit: 300),
                detail: [ask.detail, ask.body, ask.command].compactMap { $0 }.first { !$0.isEmpty }.map {
                    TaskAlerts.plain($0, limit: 400)
                },
                kind: ask.kind.rawValue, options: ask.options)
        }
        return WatchState(tasks: tasks, asks: asks, accounts: accounts, heard: model.status == .connected ? Date() : sent?.heard)
    }

    private func send() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let state = state
        var compared = state
        compared.heard = sent?.heard
        guard compared != sent, let data = try? JSONEncoder().encode(state) else { return }
        let counts = { (s: WatchState?) in [s?.needingYou ?? 0, s?.inTrouble ?? 0] }
        // The complications' figures changed: sent at once, from their own (daily) budget.
        if session.isComplicationEnabled, counts(state) != counts(sent), session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(["state": data])
        }
        try? session.updateApplicationContext(["state": data])
        sent = state
    }

    /// What the watch asked for, done: its answer.
    private func handle(_ message: [String: Any]) async -> [String: Any] {
        let text = message["text"] as? String ?? ""
        let session = message["session"] as? String ?? ""
        guard await model.ready(within: 10) else { return ["error": "Can't reach your Mac"] }
        let ask = (message["ask"] as? String).flatMap { id in model.asks.first { $0.id == id } }
        switch message["op"] as? String {
        case "refresh":
            // Answered with it too: the watch's Siri reads it at once.
            await readAccounts(force: true)
            sent = nil
            send()
            return (try? JSONEncoder().encode(state)).map { ["state": $0] } ?? [:]
        case "choose":
            guard let ask, let option = message["option"] as? Int else { return ["error": "That ask was answered"] }
            await model.choose(ask, option: option)
        case "answer":
            guard let ask, let option = message["option"] as? Int else { return ["error": "That ask was answered"] }
            await model.answer(ask, option: option, text: text)
        case "reply":
            guard let ask else { return ["error": "That ask was answered"] }
            await model.reply(ask, text: text)
        case "say":
            // Said to Siri on the watch: the option it names, or its words.
            guard let ask else { return ["error": "That ask was answered"] }
            guard let said = await model.answer(ask, saying: text) else {
                return ["error": "Say one of: " + ask.options.joined(separator: ", ")]
            }
            return ["said": said]
        case "send":
            // Queued, as a notification's reply: at once between turns, after the turn while it works.
            do { try await model.queue(text, images: [], to: session) } catch { return ["error": "Not sent"] }
        case "pause": _ = await model.pause([session])
        case "resume": _ = await model.unpause([session])
        case "stop": await model.interrupt(session)
        case "last": return ["text": await lastAnswer(session)]
        case "projects": return ["projects": await model.projects()]
        case "start":
            let folder = message["folder"] as? String ?? ""
            let provider = Provider(rawValue: UserDefaults.standard.string(forKey: "newTaskProvider") ?? "") ?? .claude
            do {
                return ["session": try await model.start(text, in: folder, with: provider, model: nil, effort: nil)]
            } catch { return ["error": "Couldn't start it"] }
        default: return ["error": "Unknown"]
        }
        return [:]
    }

    /// A task's latest answer, as its notification would say it, a few lines long.
    private func lastAnswer(_ session: String) async -> String {
        await model.load(session, again: true)
        let answer = model.conversation(session)?.items.reversed().lazy.compactMap { item -> String? in
            if case let .agent(text, true) = item.kind { return ZeroEnding.split(text).0 }
            return nil
        }.first
        return answer.map { TaskAlerts.plain($0, limit: 600) } ?? ""
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.send() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.sent = nil; self.send()
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in reply(await self.handle(message)) }
    }

    /// Sent while the phone couldn't be reached: done now, nobody waiting for the answer.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        nonisolated(unsafe) let message = userInfo
        Task { @MainActor in _ = await self.handle(message) }
    }
}
