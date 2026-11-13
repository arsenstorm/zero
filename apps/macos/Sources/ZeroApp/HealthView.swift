import AppKit
import SwiftUI
import ZeroCore

/// The foot of Settings › General: the version and its update, Zero's own checks, and what's there to look into: the
/// daemon when it doesn't start at login, which icons this build draws, the log, the welcome. About and Health are
/// ids links scroll to.
struct AboutSections: View {
    let settings: Settings
    let showOnboarding: () -> Void

    var body: some View {
        Sections {
            SettingsSection(title: "About") {
                Rows {
                    UpdateRow()
                    if settings.zerodAgent != .on { ZerodAgentRow(state: settings.zerodAgent) }
                    // The one difference between an official build and one from source, shown so no one wonders.
                    SettingRow(
                        title: Nucleo.set == "Nucleo" ? "Icons: Nucleo" : "Icons: Lucide (open-source build)",
                        detail: Nucleo.set == "Nucleo"
                            ? "Official builds draw Nucleo's licensed icons."
                            : "Built from source, Zero draws Lucide's icons in place of Nucleo's. Nothing else differs."
                    ) { EmptyView() }
                }
            }
            .id("about")
            HealthPage().id("health")
            SettingsSection(title: "Help") {
                Rows {
                    SettingRow(
                        title: "Show log",
                        detail: "What Zero did and when: " + Log.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    ) {
                        RowButton(title: "Show log") { NSWorkspace.shared.open(Log.file) }
                    }
                    SettingRow(title: "Show welcome again", detail: "The welcome screens, as at first launch.") {
                        RowButton(title: "Open", action: showOnboarding)
                    }
                }
            }
        }
    }
}

/// Zero's own checks (HealthMonitor): each one's state as a pill, what it found, and its fix.
private struct HealthPage: View {
    @State private var busy = false

    var body: some View {
        let monitor = HealthMonitor.shared
        SettingsSection(
            title: "Health",
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
            RowButton(title: "Restart zerod", enabled: !busy) { run { await monitor.restartZerod() } }
                .tip("Running agents pause between steps, then carry on under a zerod Zero starts")
        case .startZerod: RowButton(title: "Start zerod", enabled: !busy) { run { await monitor.startZerod() } }
        case .openReport(let url):
            RowButton(title: "Open report") {
                NSWorkspace.shared.open(url)
                run { await monitor.markSeen() }
            }
        case .dismiss: RowButton(title: "Dismiss") { run { await monitor.markSeen() } }
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
        case .info: "Past"
        case .warning: "Look"
        case .failing: "Failing"
        case .unknown: "Unknown"
        }
    }

    static func color(_ state: HealthCheck.State) -> Color {
        switch state {
        case .ok: Theme.done
        case .info: .secondary
        case .warning: .orange
        case .failing: .red
        case .unknown: .secondary
        }
    }
}
