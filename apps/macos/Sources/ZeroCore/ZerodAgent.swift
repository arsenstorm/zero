#if os(macOS)
    import Foundation
    import ServiceManagement

    /// zerod as the LaunchAgent in Zero.app's Contents/Library/LaunchAgents (crates/zerod/src/launchd.rs): launchd starts
    /// it at login, outside any app's process tree, and again after a crash. Off in Login Items, or in a build that
    /// can't register it, the app starts zerod itself as before.
    public enum ZerodAgent {
        public static let label = "com.arsen.zero.zerod"
        private static var service: SMAppService { .agent(plistName: "\(label).plist") }

        public enum State: Sendable { case on, off, unavailable }

        public static var state: State {
            switch service.status {
            case .enabled: .on
            case .requiresApproval: .off
            default: .unavailable
            }
        }

        /// Registered as the installed app opens, unless the user switched it off in Login Items (requiresApproval).
        /// Never registered, an agent reads notFound, not notRegistered. Only from /Applications: a registration
        /// points launchd at the bundle that made it.
        public static func register() {
            guard Bundle.main.bundlePath.hasPrefix("/Applications/"), [.notRegistered, .notFound].contains(service.status) else { return }
            do {
                try service.register()
                Log.write("zerod: registered as a LaunchAgent")
            } catch {
                Log.write("zerod: couldn't register as a LaunchAgent: \(error)")
            }
        }

        public static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

        /// Has launchd start the agent's zerod if it isn't running; false when there's no agent to start.
        static func kickstart() -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }
#endif
