import Foundation
import Observation
import UserNotifications
import WatchConnectivity
import WidgetKit

/// The watch's copy of what the phone sends (WatchState), kept in the Keychain for the complications, and what's
/// tapped here sent to the phone to do (WatchBridge there), which wakes the iPhone app if it has to.
@MainActor @Observable final class WatchModel: NSObject {
    static let shared = WatchModel()
    private(set) var state = WatchState.load()
    /// What last failed, said for a few seconds.
    var trouble: String?

    private var started = false
    /// Once, as the app starts or Siri runs one of its intents.
    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
        UNUserNotificationCenter.current().delegate = self
        Task { await answerable(state) }
    }

    /// The phone's notifications, mirrored here, answerable here too: the asks' buttons and the task's Reply registered as
    /// the phone registers them (AskActions), what's tapped done through the phone.
    private func answerable(_ state: WatchState) async {
        let reply = UNTextInputNotificationAction(
            identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Reply to this task")
        await AskActions.register(UNNotificationCategory(identifier: "task", actions: [reply], intentIdentifiers: [], options: []))
        for ask in state.asks { await AskActions.register(AskActions.category(kind: ask.kind, options: ask.options)) }
    }

    fileprivate func take(_ info: [String: Any]) {
        guard let data = info["state"] as? Data, let new = try? JSONDecoder().decode(WatchState.self, from: data), new != state else {
            return
        }
        state = new
        new.save()
        WidgetCenter.shared.reloadAllTimelines()
        Task { await answerable(new) }
    }

    /// Asked of the phone: its answer, or nil with `trouble` said.
    @discardableResult func ask(_ message: [String: Any]) async -> [String: Any]? {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            // Not in reach: done once it is, if it's something to do (not a question).
            if !["refresh", "last", "projects"].contains(message["op"] as? String ?? "") {
                session.transferUserInfo(message)
                return [:]
            }
            say("Your iPhone isn't in reach")
            return nil
        }
        nonisolated(unsafe) let message = message
        let reply: [String: Any]? = await withCheckedContinuation { done in
            session.sendMessage(
                message,
                replyHandler: {
                    nonisolated(unsafe) let r = $0; done.resume(returning: r)
                }
            ) { _ in
                done.resume(returning: nil)
            }
        }
        guard let reply else { say("Your iPhone didn't answer"); return nil }
        if let error = reply["error"] as? String { say(error); return nil }
        return reply
    }

    func refresh() async { if let reply = await ask(["op": "refresh"]) { take(reply) } }

    private func say(_ words: String) {
        trouble = words
        Task {
            try? await Task.sleep(for: .seconds(4))
            if trouble == words { trouble = nil }
        }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        nonisolated(unsafe) let context = session.receivedApplicationContext
        Task { @MainActor in self.take(context) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        nonisolated(unsafe) let context = context
        Task { @MainActor in self.take(context) }
    }
    /// The complications' figures, sent on their own budget.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        nonisolated(unsafe) let info = userInfo
        Task { @MainActor in self.take(info) }
    }
}

extension WatchModel: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        let id = response.notification.request.identifier
        var message: [String: Any]
        if let ask = response.notification.request.content.userInfo["ask"] as? String {
            if action == AskActions.reply {
                message = ["op": "reply", "ask": ask, "text": text]
            } else if action.hasPrefix(AskActions.option), let index = Int(action.dropFirst(AskActions.option.count)) {
                message =
                    response is UNTextInputNotificationResponse
                    ? ["op": "answer", "ask": ask, "option": index, "text": text] : ["op": "choose", "ask": ask, "option": index]
            } else {
                return
            }
        } else if action == "reply" {
            message = ["op": "send", "session": id, "text": text]
        } else {
            return
        }
        if (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return }
        nonisolated(unsafe) let sent = message
        await MainActor.run { _ = Task { await WatchModel.shared.ask(sent) } }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    { [.banner, .sound, .list] }
}
