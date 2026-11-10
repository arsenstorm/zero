import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import ZeroCore

@main
enum ZeroMain {
    static func main() {
        if CommandLine.arguments.contains("--claude-models") {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                _ = await ClaudeModels.refresh(); semaphore.signal()
            }
            semaphore.wait()
            print("source:", ClaudeModels.status.source, ClaudeModels.status.error.map { "(\($0))" } ?? "")
            for choice in ClaudeModels.cached() { print(choice.id, "—", choice.name, "—", choice.detail ?? "") }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-text"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Preview.renderText(to: CommandLine.arguments[i + 1]) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-pill"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Preview.renderPill(to: CommandLine.arguments[i + 1]) }
            return
        }
        // Text drawn as the web draws it (-webkit-font-smoothing: antialiased): macOS's font smoothing thickens every
        // stroke, which reads heavy next to the thin, crisp text people know from Codex and ChatGPT. Zero's own
        // setting only, before AppKit draws anything.
        UserDefaults.standard.set(0, forKey: "AppleFontSmoothing")
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.run()
    }
}

/// The bar is never the key window, so without this its first mouse-down would only be used to focus it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// AppKit hands a new key window's focus to its first text field. The inbox only takes text focus when asked:
    /// a click in the field, or the controller arming it (R, Enter, "/", dictation). Otherwise 1, 2, 3 stay shortcuts.
    var allowsTextFocus: () -> Bool = { true }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView, !allowsTextFocus(), NSApp.currentEvent?.type != .leftMouseDown { return false }
        return super.makeFirstResponder(responder)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}
