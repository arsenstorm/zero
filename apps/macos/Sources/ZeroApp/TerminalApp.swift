import AppKit
import SwiftUI
import ZeroCore

/// The user's terminal app (Settings › Agents › Terminal app): where a task opens on its CLI's own resume and where a
/// run's output is followed. zerod keeps the setting and resolves it (unset, its default); the app reads it from there.
@MainActor @Observable
final class TerminalApp {
    static let shared = TerminalApp()
    /// The ones Zero knows, by name and bundle id.
    static let known = [
        ("Ghostty", "com.mitchellh.ghostty"), ("Terminal", "com.apple.Terminal"), ("iTerm", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"),
    ]
    static var installed: [String] { known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }.map(\.0) }

    /// The app as zerod resolves it: its name, or an .app's path. Until zerod answers, its default as it picks it.
    private(set) var app = installed.contains("Ghostty") ? "Ghostty" : "Terminal"
    /// Unset in Settings: zerod's default.
    private(set) var isDefault = true
    @ObservationIgnored private let link = try? ZerodLink()

    private init() { Task { await refresh() } }

    func refresh() async {
        guard let (app, isDefault) = try? await link?.terminal() else { return }
        (self.app, self.isDefault) = (app, isDefault)
    }

    func set(_ app: String) {
        (self.app, isDefault) = (app, false)
        Task { try? await link?.setTerminal(app) }
    }

    /// What the action's called after: "Ghostty".
    var name: String { Self.name(app) }
    var icon: Image? { Self.icon(app) }

    static func name(_ app: String) -> String { ((app as NSString).lastPathComponent as NSString).deletingPathExtension }

    @ObservationIgnored private static var icons: [String: Image] = [:]
    /// The app's own icon, as Finder shows it; nil where it isn't found.
    static func icon(_ app: String) -> Image? {
        if let kept = icons[app] { return kept }
        let bundle = known.first { $0.0 == app }?.1
        let url =
            app.hasSuffix(".app")
            ? URL(fileURLWithPath: app)
            : bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                ?? URL(fileURLWithPath: "/Applications/\(app).app")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let image = Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        icons[app] = image
        return image
    }

    /// A run's output in the terminal app, from its start and as it comes.
    static func follow(_ log: URL, title: String) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("zero-follow-\(UUID().uuidString.prefix(8)).command")
        let body = "#!/bin/zsh\nrm -f \"$0\"\nprintf '\\e]0;%s\\a' \(quoted(title))\nexec tail -n +1 -f \(quoted(log.path))\n"
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        chmod(script.path, 0o700)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: openArguments(shared.app, script: script.path))
    }

    /// As zerod opens a task's script (daemon/terminals.rs): Ghostty asks before running a script opened with it, so it's
    /// given the script as its command, in a window of its own that quits once the script ends.
    static func openArguments(_ app: String, script: String) -> [String] {
        let name = app.hasSuffix(".app") ? String(app.dropLast(4)) : app
        return name.hasSuffix("Ghostty")
            ? ["-na", app, "--args", "--quit-after-last-window-closed=true", "-e", script] : ["-a", app, script]
    }

    /// A new window of the terminal app in a folder, the task left as it is. Ghostty, as for a script, in a window of
    /// its own.
    static func openFolder(_ path: String) {
        let app = shared.app
        let name = app.hasSuffix(".app") ? String(app.dropLast(4)) : app
        let arguments =
            name.hasSuffix("Ghostty")
            ? ["-na", app, "--args", "--quit-after-last-window-closed=true", "--working-directory=\(path)"] : ["-a", app, path]
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: arguments)
    }

    private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Which terminal app tasks open in, each with its own icon: the ones installed, the app chosen before, or another
/// .app. Unset, zerod's default shows as "Ghostty (default)".
struct TerminalAppPicker: View {
    private var terminal = TerminalApp.shared

    var body: some View {
        let installed = TerminalApp.installed
        let names = installed + (installed.contains(terminal.app) ? [] : [terminal.app])
        SettingChoice(
            id: "terminalApp",
            choices: [
                names.map { (title: TerminalApp.name($0) + ($0 == terminal.app && terminal.isDefault ? " (default)" : ""), value: $0) },
                [(title: "Other app…", value: "")],
            ],
            selection: Binding(
                get: { terminal.app },
                set: { picked in
                    guard let app = picked.isEmpty ? Self.otherApp() : picked else { return }
                    terminal.set(app)
                }),
            icon: { $0.isEmpty ? nil : TerminalApp.icon($0) }
        )
        .task { await terminal.refresh() }
    }

    /// Another terminal app, chosen from Applications: its path.
    private static func otherApp() -> String? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
