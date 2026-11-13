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

/// The editor of every text field in Zero's windows while it's edited or selected (SwiftUI's TextField and selectable
/// Text are both NSTextFields): Zero's grey selection, as the conversation's, and a caret in the text's colour, not
/// the system accent. Kept so: a field sets its editor's selection colours back to the system's as it starts editing.
final class FieldEditor: NSTextView {
    override var selectedTextAttributes: [NSAttributedString.Key: Any] {
        get { super.selectedTextAttributes }
        set { super.selectedTextAttributes = [.backgroundColor: Theme.selection] }
    }
    static func make() -> FieldEditor {
        let editor = FieldEditor()
        editor.isFieldEditor = true
        editor.selectedTextAttributes = [:]
        editor.insertionPointColor = .textColor
        return editor
    }
}

/// A window with Zero's field editor (one per window: an editor is in one window's views at a time).
final class ZeroWindow: NSWindow {
    private lazy var editor = FieldEditor.make()
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? { editor }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    private lazy var editor = FieldEditor.make()
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? { editor }
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
