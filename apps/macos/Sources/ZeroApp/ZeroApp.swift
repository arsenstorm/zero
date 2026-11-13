import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import ZeroCore

@main
enum ZeroMain {
    static func main() {
        if CommandLine.arguments.contains("--claude-models") {
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

/// Zero's grey selection and a caret in the text's colour in every SwiftUI TextField and selectable Text (both edit
/// in their window's field editor), not the system accent. A field sets its editor's colours back to the system's
/// each time it takes focus, so they're set again whenever an editor becomes first responder. SwiftUI's own editor,
/// styled, never subclassed or replaced: SwiftUI force-casts it to its private class (a custom one aborted Zero on
/// every launch on macOS 27.2.1).
enum FieldEditorStyle {
    private static var key = 0

    static func start() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, objc_getAssociatedObject(window, &key) == nil else { return }
            // Kept by the window, so it lives as long as the window does.
            let observation = window.observe(\.firstResponder, options: [.initial]) { window, _ in
                guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
                editor.selectedTextAttributes = [.backgroundColor: Theme.selection]
                editor.insertionPointColor = .textColor
            }
            objc_setAssociatedObject(window, &key, observation, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

final class Panel: NSPanel {
    /// Off for a menu over a window: taking the keys would turn that window's toggles and selections inactive grey.
    var keyable = true
    override var canBecomeKey: Bool { keyable }
    /// AppKit hands a new key window's focus to its first text field. The inbox only takes text focus when asked:
    /// a click in the field, or the controller arming it (R, Enter, "/"). Otherwise 1, 2, 3 stay shortcuts.
    var allowsTextFocus: () -> Bool = { true }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView, !allowsTextFocus(), NSApp.currentEvent?.type != .leftMouseDown { return false }
        return super.makeFirstResponder(responder)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}
