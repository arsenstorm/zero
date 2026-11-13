import AppKit
import SwiftUI

/// The word being typed at the caret when it starts with "/" or "@": what to suggest for, and where it sits.
struct MentionTrigger: Equatable {
    let symbol: Character
    /// What is typed before the caret, which is what suggestions match.
    let query: String
    let range: NSRange
    /// The whole word, past the caret too: a pick replaces all of it, so "/a|rsenstorm" becomes "/animations".
    let word: NSRange
}

enum ComposeKey { case up, down, accept, dismiss }

/// Edits made to the field from outside it (an attached image's token, a thumbnail's ×), through the view itself, so
/// they undo and redo as typing does.
@MainActor final class ComposeHandle {
    weak var view: TokenTextView?

    /// Words put in at the caret, a space on each side where the words around need one; the field focused after.
    func insert(_ text: String) {
        guard let view else { return }
        let whole = view.string as NSString
        let at = view.selectedRange()
        let before = whole.substring(to: at.location), after = whole.substring(from: NSMaxRange(at))
        let piece =
            (before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n") ? "" : " ") + text
            + (after.hasPrefix(" ") || after.hasPrefix("\n") ? "" : " ")
        view.insertText(piece, replacementRange: at)
        view.window?.makeFirstResponder(view)
    }

    /// An image's pills taken out of the words, each with the space after it.
    func remove(_ number: Int) {
        guard let view, let storage = view.textStorage else { return }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? ImageToken.Cell, cell.number == number else { return }
            var range = range
            if NSMaxRange(range) < storage.length, (storage.string as NSString).character(at: NSMaxRange(range)) == 32 { range.length += 1 }
            ranges.append(range)
        }
        for range in ranges.reversed() where view.shouldChangeText(in: range, replacementString: "") {
            view.replaceCharacters(in: range, with: "")
            view.didChangeText()
        }
    }
}

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
    /// ⌘⏎, when it means something other than Return (sending now where Return queues).
    var onCommandSubmit: (() -> Void)?
    var onTrigger: (MentionTrigger?) -> Void = { _ in }
    /// Keys for the suggestion list; returns true when it took the key.
    var onKey: (ComposeKey) -> Bool = { _ in false }
    /// "@paths" are tokens only while file suggestions are on.
    var highlightFiles = false
    /// A click on an image's pill: which image (counting from 1).
    var onImage: (Int) -> Void = { _ in }
    /// Images and videos dropped on the words: attached, as a drop on the composer is (the field alone writes their
    /// paths). Nil, the field's own way.
    var onAttach: (([URL]) -> Void)?
    /// Whether such files are being dragged over the words: the composer shows its drop state for them as for a drag
    /// over the rest of it (the field takes the drag from SwiftUI's onDrop there).
    var onDropping: (Bool) -> Void = { _ in }
    /// For edits from outside the view (ComposeHandle).
    var handle: ComposeHandle?
    /// Scrolled inside: whether there's more above, and more below, for a fade at that edge.
    var onEdges: (Bool, Bool) -> Void = { _, _ in }

    /// The messages' size, so what's typed reads as what's sent.
    static let font = NSFont.systemFont(ofSize: 14.5)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposeScroll()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        let view = TokenTextView()
        view.keepTokensWhole()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = Self.font
        view.textColor = .labelColor
        view.textContainerInset = TokenTextView.inset // room for a token's pill at the edges
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
        handle?.view = view
        // Scrolled inside (past eight lines): which edges have more beyond them.
        scroll.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
            [weak scroll] _ in
            if let scroll { coordinator.edges(scroll) }
        }
        // Grown or shrunk (a paste): the edges again once the new size is laid out, not from the old one.
        scroll.contentView.postsFrameChangedNotifications = true
        view.postsFrameChangedNotifications = true
        for watched in [scroll.contentView as NSView, view] {
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: watched, queue: .main) {
                [weak scroll] _ in
                if let scroll { coordinator.edges(scroll) }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? TokenTextView else { return }
        handle?.view = view
        view.placeholder = placeholder
        view.isEditable = editable
        if view.highlightFiles != highlightFiles { view.highlightFiles = highlightFiles; context.coordinator.restyle(view) }
        view.textColor = editable ? .labelColor : .secondaryLabelColor
        if context.coordinator.decode(view) != text {
            view.string = text
            context.coordinator.restyle(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        if let caret {
            view.setSelectedRange(NSRange(location: min(Coordinator.stored(caret, in: text), (view.string as NSString).length), length: 0))
            DispatchQueue.main.async { onCaretApplied() }
        }
        if let window = view.window {
            if focused, window.firstResponder !== view {
                window.makeFirstResponder(view)
            } else if !focused, window.firstResponder === view {
                window.makeFirstResponder(nil)
            }
        }
        context.coordinator.edges(scroll)
    }

    /// Two lines at least, eight at most; past that the text scrolls inside. Measured in SwiftUI's own layout pass,
    /// at the width it's given: the height follows the text in the same frame, typed or set from outside (emptied as
    /// it's sent), not a run loop later.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView, let manager = view.layoutManager, let container = view.textContainer
        else { return nil }
        let width = proposal.width ?? scroll.frame.width
        let wrap = width - TokenTextView.inset.width * 2
        // Laid out at the width asked about, then given back the view's own: SwiftUI may ask about others first.
        let own = container.size.width
        if wrap > 0, wrap.isFinite, wrap != own { container.size.width = wrap }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        if container.size.width != own { container.size.width = own }
        let lines = Self.lineHeight
        return CGSize(width: width, height: (min(max(used, lines * 2), lines * 8) + TokenTextView.inset.height * 2).rounded(.up))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeField
        private var edges = (top: false, bottom: false)
        init(_ parent: ComposeField) { self.parent = parent }

        /// More above or below what's shown, when that changes.
        func edges(_ scroll: NSScrollView) {
            let clip = scroll.contentView.bounds
            let document = scroll.documentView?.frame ?? .zero
            let now = (top: clip.minY > 1, bottom: document.maxY - clip.maxY > 1)
            guard now != edges else { return }
            edges = now
            let onEdges = parent.onEdges
            DispatchQueue.main.async { onEdges(now.top, now.bottom) }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? TokenTextView else { return }
            parent.text = decode(view)
            restyle(view)
            view.enclosingScrollView?.invalidateIntrinsicContentSize() // measured again (sizeThatFits)
            report(view)
            if let scroll = view.enclosingScrollView { DispatchQueue.main.async { self.edges(scroll) } }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? TokenTextView else { return }
            report(view)
        }

        // An image's token is "[Image #n]" in the text and one character, its pill, in the view.

        /// The view's text with each pill as its token.
        func decode(_ view: NSTextView) -> String {
            guard let storage = view.textStorage else { return view.string }
            let out = NSMutableString(string: storage.string)
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: [.reverse]) {
                value, range, _ in
                guard let cell = (value as? NSTextAttachment)?.attachmentCell as? ImageToken.Cell else { return }
                out.replaceCharacters(in: range, with: ImageToken.text(cell.number, video: cell.video))
            }
            return out as String
        }

        /// A place in the text as a place in the view: each token before it is one character there.
        static func stored(_ offset: Int, in text: String) -> Int {
            ImageToken.find(in: text).filter { NSMaxRange($0.range) <= offset }.reduce(offset) { $0 - ($1.range.length - 1) }
        }

        /// A place in the view as a place in the text.
        func written(_ offset: Int, in view: NSTextView) -> Int {
            guard let storage = view.textStorage else { return offset }
            var out = offset
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: min(offset, storage.length))) { value, _, _ in
                if let cell = (value as? NSTextAttachment)?.attachmentCell as? ImageToken.Cell {
                    out += (ImageToken.text(cell.number, video: cell.video) as NSString).length - 1
                }
            }
            return out
        }

        /// ⌘⏎: send now (steer, while the agent works) where ⏎ would queue. With ⌘ held the key never reaches
        /// insertNewline: it comes as a key equivalent, which the text view hands here.
        func commandSubmit() {
            if parent.onKey(.accept) { return }
            if let now = parent.onCommandSubmit { now() } else { parent.onSubmit() }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.accept)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.dismiss)
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onKey(.accept) { return true }
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.command), let now = parent.onCommandSubmit { now(); return true }
                if !flags.intersection([.shift, .option]).isEmpty {
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
            while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)),
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
            { start -= 1 }
            guard start < caret.location else { return nil }
            let word = text.substring(with: NSRange(location: start, length: caret.location - start))
            guard let symbol = word.first, symbol == "/" || symbol == "@" else { return nil }
            var end = caret.location
            while end < text.length, let scalar = UnicodeScalar(text.character(at: end)),
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
            { end += 1 }
            // Its places as they are in the text (an image's pill before it is its whole token there).
            let (from, to, last) = (written(start, in: view), written(caret.location, in: view), written(end, in: view))
            return MentionTrigger(
                symbol: symbol, query: String(word.dropFirst()), range: NSRange(location: from, length: to - from),
                word: NSRange(location: from, length: last - from))
        }

        /// Tokens in semibold dark yellow; their rounded yellow pills are drawn by the view behind the text. An image's
        /// token typed or set as text becomes its pill.
        func restyle(_ view: NSTextView) {
            guard let storage = view.textStorage, let view = view as? TokenTextView else { return }
            // Each token written out ("[Image #1]") becomes its one-character pill: the caret keeps its place among the
            // words, rather than wherever the shorter text leaves it (the end, when there's text after it).
            let tokens = ImageToken.find(in: storage.string)
            let caret = view.selectedRange()
            let shift = tokens.filter { NSMaxRange($0.range) <= caret.location }.reduce(0) { $0 + $1.range.length - 1 }
            storage.beginEditing()
            for token in tokens.reversed() {
                storage.replaceCharacters(
                    in: token.range, with: ImageToken.attachment(token.number, font: ComposeField.font, video: token.video))
            }
            let all = NSRange(location: 0, length: storage.length)
            storage.addAttributes(
                [.font: ComposeField.font, .foregroundColor: view.isEditable ? NSColor.labelColor : NSColor.secondaryLabelColor], range: all
            )
            view.tokenRanges = view.tokens()
            for range in view.tokenRanges {
                storage.addAttributes([.font: TokenTextView.tokenFont, .foregroundColor: TokenTextView.tokenText], range: range)
            }
            storage.endEditing()
            if !tokens.isEmpty { view.setSelectedRange(NSRange(location: max(0, min(caret.location - shift, storage.length)), length: 0)) }
            view.needsDisplay = true
        }
    }
}

/// The field's scroll view, never left scrolled past its text. Grown to fit, the clip view kept the scroll it had
/// while the text was taller than the old height (a new line scrolls the caret into view first), and hid the first line.
final class ComposeScroll: NSScrollView {
    override func tile() {
        super.tile()
        settle()
    }

    /// No further down than the text's foot: at the top whenever it all fits.
    func settle() {
        let clip = contentView.bounds
        let top = max(0, min(clip.minY, (documentView?.frame.height ?? 0) - clip.height))
        guard top != clip.minY else { return }
        contentView.scroll(to: NSPoint(x: clip.minX, y: top))
        reflectScrolledClipView(contentView)
    }
}

final class TokenTextView: NSTextView {
    weak var coordinator: ComposeField.Coordinator?

    /// Shrunk (its text emptied or replaced): the scroll kept within it at once.
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        (enclosingScrollView as? ComposeScroll)?.settle()
    }

    private func isCommandReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    // ⌘⏎ comes as a key equivalent first; when nothing in the window takes it as one, as a key down to the first
    // responder. Either way it's ours.
    /// Image and video files dropped here, when the field attaches them (onAttach).
    private func attachable(_ info: NSDraggingInfo) -> [URL]? {
        guard coordinator?.parent.onAttach != nil,
            let files = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !files.isEmpty, files.allSatisfy({ Attachments.isImage($0) || Attachments.isVideo($0) })
        else { return nil }
        return files
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard attachable(sender) != nil else { return super.draggingEntered(sender) }
        coordinator?.parent.onDropping(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        attachable(sender) != nil ? .copy : super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        coordinator?.parent.onDropping(false)
        super.draggingExited(sender)
    }

    /// Copied off the main thread (a clone on the same volume is instant; from another disk, a video's copy isn't), so
    /// the composer never waits on it.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let files = attachable(sender), let attach = coordinator?.parent.onAttach else { return super.performDragOperation(sender) }
        coordinator?.parent.onDropping(false)
        Task { @MainActor in attach(await Task.detached { files.compactMap(Attachments.copy) }.value) }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCommandReturn(event), let coordinator { coordinator.commandSubmit(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isCommandReturn(event), let coordinator { coordinator.commandSubmit(); return }
        super.keyDown(with: event)
    }
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var highlightFiles = false
    var tokenRanges: [NSRange] = []

    /// A token moves to the next line whole rather than breaking after its "/" (a place text may wrap): a pill split
    /// over two lines read as two.
    private var breaks: TokenBreaks?
    func keepTokensWhole() {
        breaks = TokenBreaks { [weak self] index in self?.tokenRanges.contains { $0.location < index && index < NSMaxRange($0) } ?? false }
        layoutManager?.delegate = breaks
    }

    static let inset = NSSize(width: 3, height: 1)
    static let tokenFont = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    static let tokenText = dynamic(
        dark: NSColor(red: 0.98, green: 0.84, blue: 0.40, alpha: 1), light: NSColor(red: 0.55, green: 0.38, blue: 0.0, alpha: 1))
    static let tokenFill = dynamic(
        dark: NSColor(red: 0.36, green: 0.29, blue: 0.06, alpha: 1), light: NSColor(red: 0.99, green: 0.93, blue: 0.62, alpha: 1))

    /// "/word", "@loop" for a loop that exists, and "@path" when files are on, at the start of the text or after
    /// whitespace. "@someone" that names no loop is plain words.
    static func tokens(in text: String, files: Bool = true, loops: [String] = []) -> [NSRange] {
        let pattern = files ? "(?<![^\\s])[/@][^\\s]+" : "(?<![^\\s])(?:/[^\\s]+|@[a-z0-9-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range).filter { range in
            files || !ns.substring(with: range).hasPrefix("@") || loops.contains(ns.substring(with: range).dropFirst().description)
        }
    }

    func tokens() -> [NSRange] { Self.tokens(in: string, files: highlightFiles, loops: LoopNames.known) }

    /// Each token sits on a yellow pill, 2 pt wider than its text on each side, rounded, one per line it spans.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let manager = layoutManager, let container = textContainer else { return }
        Self.tokenFill.setFill()
        for range in tokenRanges {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // A pill per line it's on, hugging its own letters there: a line's enclosing rect runs on to the line's end.
            var glyph = glyphs.location
            while glyph < NSMaxRange(glyphs) {
                var line = NSRange()
                manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
                let segment = NSIntersectionRange(glyphs, line)
                guard segment.length > 0 else { break }
                let box = manager.boundingRect(forGlyphRange: segment, in: container)
                let pill = box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -2, dy: -0.5)
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                glyph = NSMaxRange(segment)
            }
        }
    }

    /// A finished token (one with a space after it) goes in one backspace, from its end or from after its space.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        let text = string as NSString
        if caret.length == 0, caret.location > 0,
            let token = tokens().first(where: { range in
                let end = NSMaxRange(range)
                let finished = end < text.length && text.character(at: end) == 32
                return finished && (caret.location == end || caret.location == end + 1)
            })
        {
            let removal = NSRange(
                location: token.location, length: caret.location - token.location + (caret.location == NSMaxRange(token) ? 1 : 0))
            if shouldChangeText(in: removal, replacementString: "") {
                replaceCharacters(in: removal, with: "")
                didChangeText()
            }
            return
        }
        super.deleteBackward(sender)
    }

    /// A click on an image's pill opens the image.
    override func mouseDown(with event: NSEvent) {
        if let hit = ImageToken.hit(event, in: self) { coordinator?.parent.onImage(hit.cell.number); return }
        super.mouseDown(with: event)
    }

    /// ⌘⌫ at the start of a line (an empty one, say) takes the line break before it, so it climbs line by line.
    override func deleteToBeginningOfLine(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, caret.location > 0, (string as NSString).character(at: caret.location - 1) == 10 {
            deleteBackward(sender)
            return
        }
        super.deleteToBeginningOfLine(sender)
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
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y),
            withAttributes: [.font: ComposeField.font, .foregroundColor: NSColor.placeholderTextColor])
    }
}

/// Keeps a token ("/skill", "@loop") on one line: no line break inside one, so it moves to the next line whole.
final class TokenBreaks: NSObject, NSLayoutManagerDelegate {
    private let inside: (Int) -> Bool
    init(inside: @escaping (Int) -> Bool) { self.inside = inside }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        !inside(charIndex)
    }
}
