import AppKit
import SwiftUI

/// The word being typed at the caret when it starts with "/" or "@": what to suggest for, and where it sits.
struct MentionTrigger: Equatable {
    let symbol: Character
    let query: String
    let range: NSRange
}

enum ComposeKey { case up, down, accept, dismiss }

/// The composer's text: a text view rather than a TextField, so commands and files typed or picked show as
/// highlighted tokens, a backspace takes a whole finished token, and arrows, Tab and Return can drive the
/// suggestion list while it is open. Return sends; Shift- or Option-Return starts a new line.
struct ComposeField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focused: Bool
    let editable: Bool
    /// Where the caret goes after an insertion made outside the view; cleared through `onCaretApplied`.
    let caret: Int?
    var onCaretApplied: () -> Void = {}
    var onFocus: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onTrigger: (MentionTrigger?) -> Void = { _ in }
    /// Keys for the suggestion list; returns true when it took the key.
    var onKey: (ComposeKey) -> Bool = { _ in false }
    @Binding var height: CGFloat

    static let font = NSFont.systemFont(ofSize: 13)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        let view = TokenTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = Self.font
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? TokenTextView else { return }
        view.placeholder = placeholder
        view.isEditable = editable
        view.textColor = editable ? .labelColor : .secondaryLabelColor
        if view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.restyle(view)
        }
        if let caret {
            view.setSelectedRange(NSRange(location: min(caret, (view.string as NSString).length), length: 0))
            DispatchQueue.main.async { onCaretApplied() }
        }
        if let window = view.window {
            if focused, window.firstResponder !== view { window.makeFirstResponder(view) }
            else if !focused, window.firstResponder === view { window.makeFirstResponder(nil) }
        }
        context.coordinator.measure(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeField
        init(_ parent: ComposeField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? TokenTextView else { return }
            parent.text = view.string
            restyle(view)
            measure(view)
            report(view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? TokenTextView else { return }
            report(view)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.accept)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.dismiss)
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onKey(.accept) { return true }
                if let flags = NSApp.currentEvent?.modifierFlags, !flags.intersection([.shift, .option]).isEmpty {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            default: return false
            }
        }

        /// The token at the caret, if the word under it starts with "/" or "@".
        func report(_ view: NSTextView) {
            let trigger = trigger(in: view)
            let onTrigger = parent.onTrigger
            DispatchQueue.main.async { onTrigger(trigger) } // never from inside a SwiftUI update
        }

        private func trigger(in view: NSTextView) -> MentionTrigger? {
            let caret = view.selectedRange()
            guard caret.length == 0 else { return nil }
            let text = view.string as NSString
            var start = caret.location
            while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { start -= 1 }
            guard start < caret.location else { return nil }
            let word = text.substring(with: NSRange(location: start, length: caret.location - start))
            guard let symbol = word.first, symbol == "/" || symbol == "@" else { return nil }
            return MentionTrigger(symbol: symbol, query: String(word.dropFirst()), range: NSRange(location: start, length: caret.location - start))
        }

        /// Tokens ("/commit", "@Sources/x.swift") in the accent colour on a faint tint.
        func restyle(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: ComposeField.font, .foregroundColor: view.isEditable ? NSColor.labelColor : NSColor.secondaryLabelColor], range: all)
            for range in TokenTextView.tokens(in: view.string) {
                storage.addAttributes([
                    .foregroundColor: NSColor.controlAccentColor,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12),
                ], range: range)
            }
            storage.endEditing()
        }

        /// Two lines at least, eight at most; past that the text scrolls inside.
        func measure(_ view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let lines = ComposeField.lineHeight
            let height = min(max(used, lines * 2), lines * 8).rounded(.up)
            if abs(parent.height - height) > 0.5 { DispatchQueue.main.async { self.parent.height = height } }
        }
    }
}

final class TokenTextView: NSTextView {
    weak var coordinator: ComposeField.Coordinator?
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }

    /// "/word" or "@path" at the start of the text or after whitespace.
    static func tokens(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: "(?<![^\\s])[/@][^\\s]+") else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// A finished token (one with a space after it) goes in one backspace, from its end or from after its space.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        let text = string as NSString
        if caret.length == 0, caret.location > 0,
           let token = Self.tokens(in: string).first(where: { range in
               let end = NSMaxRange(range)
               let finished = end < text.length && text.character(at: end) == 32
               return finished && (caret.location == end || caret.location == end + 1)
           }) {
            let removal = NSRange(location: token.location, length: caret.location - token.location + (caret.location == NSMaxRange(token) ? 1 : 0))
            if shouldChangeText(in: removal, replacementString: "") {
                replaceCharacters(in: removal, with: "")
                didChangeText()
            }
            return
        }
        super.deleteBackward(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let onFocus = coordinator?.parent.onFocus { DispatchQueue.main.async { onFocus(true) } }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let onFocus = coordinator?.parent.onFocus { DispatchQueue.main.async { onFocus(false) } }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y),
                                       withAttributes: [.font: ComposeField.font, .foregroundColor: NSColor.placeholderTextColor])
    }
}
