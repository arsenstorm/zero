import CryptoKit
import Foundation
import Security

// What the app and its extensions (the notification service, the share sheet) all read: the pairing, in a Keychain
// group they share.

/// What the phone keeps: its key and the Mac it's paired with (the QR code's relay, Mac id and key), in the Keychain.
struct Pairing: Codable {
    var relay: String
    var mac: String
    var macKey: Data
    var key: Data
    /// The invite's code until the Mac has taken it: then nil, paired.
    var code: String?

    static func load() -> Pairing? { Keychain.read("pairing").flatMap { try? JSONDecoder().decode(Pairing.self, from: $0) } }
    func save() { if let data = try? JSONEncoder().encode(self) { Keychain.write("pairing", data) } }
    static func forget() { Keychain.delete("pairing") }

    init(invite: Tunnel.Invite) {
        relay = invite.relay; mac = invite.mac; macKey = invite.key; code = invite.code
        key = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }
}

enum Keychain {
    static let service = "dev.zero.phone"
    // Written to the first of the targets' keychain-access-groups, shared by the app and its extensions.
    static func read(_ account: String) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    static func write(_ account: String, _ data: Data) {
        delete(account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}
