import AppIntents
import CryptoKit
import UserNotifications

/// A push's real words, opened here: the Mac seals them for this phone (Tunnel.seal), so Apple carries only "A task
/// has news".
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler done: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return done(request.content) }
        if let sealed = (content.userInfo["zero"] as? String).flatMap({ Data(base64Encoded: $0) }), let pairing = Pairing.load(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pairing.key),
           let plain = try? Tunnel.open(sealed, with: key, from: pairing.macKey),
           let note = try? JSONDecoder().decode([String: String].self, from: plain) {
            content.title = note["title"] ?? content.title
            content.body = note["body"] ?? content.body
        }
        // A task's (not an ask's, whose card is answered in the inbox): Reply, a text field on the notification itself,
        // going to the task (the app's AppDelegate). An ask's identifier starts "ask-" (TaskAlerts.askPrefix).
        if !request.identifier.hasPrefix("ask-") { content.categoryIdentifier = "task" }
        // The task's latest word, as the message this notification is (its identifier is the task's session): "reply…"
        // to it with Siri, from AirPods or the lock screen, goes to the task. The app resolves it (Siri.swift).
        content.appEntityIdentifiers = [EntityIdentifier(for: ZeroMessage.self, identifier: request.identifier + "/latest")]
        done(content)
    }
}

/// The app's message entity, by name only: what a notification's identifier names. Its query is the app's.
struct ZeroMessage: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Message"
    static let defaultQuery = Query()
    var id: String
    var displayRepresentation: DisplayRepresentation { "Message" }
    struct Query: EntityQuery { func entities(for identifiers: [String]) async throws -> [ZeroMessage] { [] } }
}
