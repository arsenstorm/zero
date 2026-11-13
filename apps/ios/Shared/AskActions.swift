import CryptoKit
import Foundation
import UserNotifications

/// An ask's notification made answerable where it shows (the lock screen, the watch it's mirrored to): its options as
/// its buttons, an option ending "…" (or an ask with none) a text field, dictated or typed. iOS fixes a notification's
/// buttons by its category, so each set of options is a category of its own, registered by the Notify extension as the
/// push comes; the app answers what's tapped (AppDelegate).
enum AskActions {
    static let prefix = "ask."
    static let option = "option."
    static let reply = "ask.reply"

    /// The category for these options (the same options, the same category).
    static func category(kind: String, options: [String]) -> UNNotificationCategory {
        let digest = SHA256.hash(data: Data((kind + "\u{0}" + options.joined(separator: "\u{0}")).utf8))
        let id = prefix + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        // Running a command or allowing an agent's: only by someone who can unlock the phone (or wears the watch).
        let guarded: UNNotificationActionOptions = ["run", "approve", "permission"].contains(kind) ? .authenticationRequired : []
        let actions: [UNNotificationAction] =
            options.isEmpty
            ? [
                UNTextInputNotificationAction(
                    identifier: reply, title: "Reply", options: guarded, textInputButtonTitle: "Send",
                    textInputPlaceholder: "Your answer")
            ]
            // iOS shows four at most.
            : options.prefix(4).enumerated().map { index, label in
                let id = option + String(index)
                if label.hasSuffix("…") || label.hasSuffix("...") {
                    return UNTextInputNotificationAction(
                        identifier: id, title: label, options: guarded, textInputButtonTitle: "Send",
                        textInputPlaceholder: "Your answer")
                }
                let no = label.hasPrefix("Deny") || label == "No" || label.hasPrefix("Reject")
                return UNNotificationAction(identifier: id, title: label, options: no ? guarded.union(.destructive) : guarded)
            }
        return UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
    }

    /// Registered beside those there already (the task's Reply, other asks'): the 40 latest asks' kept.
    static func register(_ category: UNNotificationCategory) async {
        let center = UNUserNotificationCenter.current()
        var all = await center.notificationCategories()
        guard !all.contains(where: { $0.identifier == category.identifier }) else { return }
        let asks = all.filter { $0.identifier.hasPrefix(prefix) }
        if asks.count >= 40 { all.subtract(asks.prefix(asks.count - 39)) }
        all.insert(category)
        center.setNotificationCategories(all)
    }
}
