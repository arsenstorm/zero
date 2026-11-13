import Foundation
import Security

/// What the watch shows: the iPhone app sends it (WatchConnectivity's application context, WatchBridge) and the watch
/// keeps it in the Keychain for its complications. Plain values only: the watch compiles none of ZeroCore.
struct WatchState: Codable, Equatable {
    /// A task as the phone's Tasks list has it: its state (BoardRow.State's raw value) and what it says under its name.
    struct Task: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var state: String
        var line: String?
    }

    /// An ask waiting on the user: its task's name, and what answering it takes (its options; none, a reply).
    struct Ask: Codable, Equatable, Identifiable {
        var id: String
        var from: String
        var title: String
        var detail: String?
        var kind: String
        var options: [String]
    }

    /// An account's use, as the Mac's rings show it: the week's share and the 5 hours' (only where its plan has them),
    /// each until it resets (Unix seconds), and whether it's at its limit until then.
    struct Account: Codable, Equatable, Identifiable {
        var id: String
        var cli: String
        var label: String
        var week: Double?
        var weekResets: Int?
        var five: Double?
        var fiveResets: Int?
        var limitedUntil: Int?

        /// A window's share while it hasn't reset (UsageShown.used).
        static func used(_ share: Double?, resets: Int?, now: Date = Date()) -> Double? {
            share.map { (resets ?? Int.max) > Int(now.timeIntervalSince1970) ? min(1, $0) : 0 }
        }
        func weekUsed(_ now: Date = Date()) -> Double {
            if let limitedUntil, limitedUntil > Int(now.timeIntervalSince1970) { return 1 }
            return Self.used(week, resets: weekResets, now: now) ?? 0
        }
        func fiveUsed(_ now: Date = Date()) -> Double? { Self.used(five, resets: fiveResets, now: now) }
        var fullest: Double { max(weekUsed(), fiveUsed() ?? 0) }
    }

    var tasks: [Task] = []
    var asks: [Ask] = []
    var accounts: [Account] = []
    /// When the phone last heard the Mac; nil, it can't reach it.
    var heard: Date?

    var needingYou: Int { max(asks.count, tasks.filter { $0.state == "needsYou" }.count) }
    var inTrouble: Int { tasks.filter { ["trouble", "blocked"].contains($0.state) }.count }

    /// Shared by the watch app and its complications, in the Keychain group they share (an app group needs a
    /// provisioning profile of its own).
    static func load() -> WatchState {
        var found: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.zero.watch", kSecAttrAccount as String: "state",
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return WatchState() }
        return (try? JSONDecoder().decode(WatchState.self, from: data)) ?? WatchState()
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.zero.watch", kSecAttrAccount as String: "state",
        ]
        if SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var added = item
            added[kSecValueData as String] = data
            added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(added as CFDictionary, nil)
        }
    }
}
