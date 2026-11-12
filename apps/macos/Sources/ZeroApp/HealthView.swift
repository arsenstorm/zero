import AppKit
import SwiftUI
import ZeroCore

/// Settings › Health: each of Zero's own checks (HealthMonitor), its state as a pill, what it found, and its fix.
struct HealthPage: View {
    @State private var busy = false

    var body: some View {
        let monitor = HealthMonitor.shared
        SettingsSection(
            title: "Checks",
            accessory: AnyView(GhostButton(title: "Check now", icon: "arrow-rotate-clockwise") { run { await monitor.check() } })
        ) {
            Rows {
                ForEach(monitor.checks) { check in
                    SettingRow(title: check.title, detail: check.detail) {
                        HStack(spacing: 10) {
                            if let fix = check.fix { button(fix) }
                            StatePill(text: Self.label(check.state), color: Self.color(check.state))
                        }
                    }
                }
            }
        }
        .task { await monitor.check() }
    }

    @ViewBuilder private func button(_ fix: HealthCheck.Fix) -> some View {
        let monitor = HealthMonitor.shared
        switch fix {
        case .restartZerod:
            Button("Restart zerod") { run { await monitor.restartZerod() } }.disabled(busy)
                .tip("Running agents pause between steps, then carry on under a zerod Zero starts")
        case .startZerod: Button("Start zerod") { run { await monitor.startZerod() } }.disabled(busy)
        case .openReport(let url):
            Button("Open report") {
                NSWorkspace.shared.open(url)
                run { await monitor.markSeen() }
            }
        case .dismiss: Button("Dismiss") { run { await monitor.markSeen() } }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work(); busy = false
        }
    }

    static func label(_ state: HealthCheck.State) -> String {
        switch state {
        case .ok: "OK"
        case .warning: "Look"
        case .failing: "Failing"
        case .unknown: "Unknown"
        }
    }

    static func color(_ state: HealthCheck.State) -> Color {
        switch state {
        case .ok: .green
        case .warning: .orange
        case .failing: .red
        case .unknown: .secondary
        }
    }
}
