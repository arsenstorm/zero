import AppKit
import SwiftUI
import ZeroCore

/// Whether zerod starts at login as Zero's LaunchAgent: on unless the user switched it off in Login Items, where it's
/// switched back on (macOS lets only the user do that). Read again as Zero comes back from System Settings.
struct ZerodAgentRow: View {
    @State private var state = ZerodAgent.state

    var body: some View {
        SettingRow(title: "Start Zero's daemon at login", detail: detail) {
            switch state {
            case .on: StatePill(text: "On", color: .green)
            case .off: RowButton(title: "Login Items") { ZerodAgent.openLoginItems() }
            case .unavailable: StatePill(text: "Not in this build", color: .secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state = ZerodAgent.state
        }
    }

    private var detail: String {
        switch state {
        case .on: "It runs your agents from login, with or without the app open, and starts again if it stops."
        case .off:
            "Off in Login Items: the daemon starts when Zero opens, not at login, and not without the app. Switch Zero back on there."
        case .unavailable: "This build can't add it to Login Items: the daemon starts when Zero opens."
        }
    }
}
