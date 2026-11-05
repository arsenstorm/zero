import AppKit
import SwiftUI
import ZeroCore

// A scratchpad edited as Markdown, straight through, styled as it's typed (MarkdownStyle). Its tables are the exception:
// each is a grid of cells to type in, with buttons for rows and columns, so the pipes behind it never show. The pad is
// cut into runs of text and tables (ZeroCore's PadBlocks); joined they are the file, byte for byte.

struct PadDocument: View {
    @Binding var text: String
    /// A section to show: its heading's line.
    @Binding var scrollToLine: Int?
    /// The link to the section a line is in, and to the pad: for the text's menu.
    let sectionLink: (Int) -> (link: String, title: String)?
    let padLink: (link: String, title: String)
    /// The pad cut into text and tables; until the first time, cut as it's first drawn (not after, in a second pass).
    @State private var kept: [Part]?
    private var parts: [Part] { kept ?? Self.group(text) }
    /// Where a section's line is now, in the part that has it.
    @State private var showing: (part: Int, line: Int)?

    enum Part: Equatable {
        /// Text, and the line breaks after it that set off the table that follows: those aren't the text's to delete,
        /// or the text would run into the table's first row and the table be lost.
        case text(String, gap: String)
        /// A table's Markdown, and the text around it that is the table's (blank lines before the first, the gap after).
        case table(lead: String, body: String, gap: String)
        var markdown: String {
            switch self {
            case let .text(text, gap): text + gap
            case let .table(lead, body, gap): lead + body + gap
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PadToolbar()
                .onAppear { if kept == nil { kept = Self.group(text) } }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            pages
        }
        // Changed elsewhere (an agent, through zerod): cut again from the new text.
        .onChange(of: text) { _, now in if now != parts.map(\.markdown).joined() { regroup() } }
    }

    private var pages: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Group {
                            switch part {
                            case let .text(words, gap):
                                PadTextField(text: Binding(get: { words }, set: { set(index, .text($0, gap: gap)) }),
                                             firstLine: firstLine(of: index), isLast: index == parts.count - 1, placeholder: parts.count == 1 ? "Write in Markdown…" : "",
                                             showLine: showing?.part == index ? showing?.line : nil,
                                             sectionLink: sectionLink, padLink: padLink, done: regroup)
                            case let .table(lead, body, gap):
                                TableGrid(markdown: Binding(get: { body }, set: { set(index, .table(lead: lead, body: $0, gap: gap)) }))
                                    .padding(.vertical, 10)
                            }
                        }
                        .id(index)
                    }
                    // Below the end: a click writes on from there.
                    Color.clear.frame(height: 160).contentShape(Rectangle()).onTapGesture { focusEnd() }
                }
                .padding(.vertical, 8)
            }
            .thinScrollbar(remember: "pad")
            .scrollIndicators(.never)
            .onChange(of: scrollToLine) { _, line in
                guard let line else { return }
                scrollToLine = nil
                let part = part(atLine: line)
                reader.scrollTo(part, anchor: .top)
                showing = (part, line - firstLine(of: part) + 1)
            }
        }
    }

    private func set(_ index: Int, _ part: Part) {
        var all = parts
        guard all.indices.contains(index) else { return }
        all[index] = part
        kept = all
        text = all.map(\.markdown).joined()
    }

    /// The text and tables again from the pad: after a change from elsewhere, and when the text being written is left
    /// (a table typed into it becomes a grid then, not under the caret).
    private func regroup() {
        let made = Self.group(text)
        if made != kept { kept = made }
    }

    private static func group(_ text: String) -> [Part] {
        var made: [Part] = []
        for block in PadBlocks.split(text) {
            if block.kind == .table, !PadBlocks.cells(block.body).isEmpty {
                // The text before it gives up its last line breaks: they're what keeps the table a table.
                if case let .text(before, _)? = made.last {
                    let words = String(before.reversed().drop { $0 == "\n" }.reversed())
                    made[made.count - 1] = .text(words, gap: String(before.dropFirst(words.count)))
                }
                made.append(.table(lead: block.lead, body: block.body, gap: block.gap))
            } else if case let .text(before, gap)? = made.last {
                made[made.count - 1] = .text(before + gap + block.text, gap: "")
            } else {
                made.append(.text(block.text, gap: ""))
            }
        }
        // Text to write in after a last table, and in an empty pad.
        if made.isEmpty || { if case .table = made.last! { true } else { false } }() { made.append(.text("", gap: "")) }
        return made
    }

    private func focusEnd() {
        NotificationCenter.default.post(name: PadTextField.focusLast, object: nil)
    }

    /// The pad's line a part starts on, from 1.
    private func firstLine(of index: Int) -> Int {
        parts.prefix(index).map { $0.markdown.filter { $0 == "\n" }.count }.reduce(1, +)
    }

    private func part(atLine line: Int) -> Int {
        parts.indices.last { firstLine(of: $0) <= line } ?? 0
    }
}

/// Markdown written as it is: as tall as its text, styled as typed, a task's box ticked with a click, a pasted image kept
/// beside the pads and linked.
private struct PadTextField: NSViewRepresentable {
    @Binding var text: String
    /// The pad's line this text starts on: a section's link is found by it.
    let firstLine: Int
    /// The last text of the pad: a click below the end writes on in it.
    let isLast: Bool
    let placeholder: String
    /// A line of this text to bring into view, from 1.
    let showLine: Int?
    let sectionLink: (Int) -> (link: String, title: String)?
    let padLink: (link: String, title: String)
    /// The text was left: the pad is cut into text and tables again.
    let done: () -> Void

    static let focusLast = Notification.Name("PadTextField.focusLast")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FieldView {
        let view = FieldView()
        view.textContainer?.replaceLayoutManager(RichLayoutManager())
        view.layoutManager?.delegate = context.coordinator
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = MarkdownStyle.body
        view.typingAttributes = MarkdownStyle.base
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.string = text
        view.placeholder = placeholder
        view.structured = { [weak coordinator = context.coordinator] in coordinator?.parent.done() }
        view.pasted = { [weak view] image in
            guard let view, let path = PadImages.keep(image) else { return }
            view.insertText("![](\(path))", replacementRange: view.selectedRange())
        }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: Self.focusLast, object: nil, queue: .main) { [weak view] _ in
            // Only the last text of the pad takes it: the one with nothing after it in the page.
            guard let view, context.coordinator.parent.isLast else { return }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        return view
    }

    static func dismantleNSView(_ view: FieldView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    func updateNSView(_ view: FieldView, context: Context) {
        context.coordinator.parent = self
        view.placeholder = placeholder
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if let line = showLine, context.coordinator.shown != line {
            context.coordinator.shown = line
            DispatchQueue.main.async { view.show(line: line) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: FieldView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 600)
        guard let container = view.textContainer, let manager = view.layoutManager else { return nil }
        if container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        manager.ensureLayout(for: container)
        let height = max(manager.usedRect(for: container).height, MarkdownStyle.body.boundingRectForFont.height + 5)
        return CGSize(width: width, height: ceil(height) + 4)
    }

    final class FieldView: NSTextView {
        var pasted: ((NSImage) -> Void)?
        /// A table or the like was put in: the pad is cut into text and tables again, so it shows as a grid.
        var structured: (() -> Void)?
        var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }

        override func paste(_ sender: Any?) {
            let board = NSPasteboard.general
            if board.string(forType: .string) == nil, let image = NSImage(pasteboard: board) { pasted?(image); return }
            super.paste(sender)
        }

        /// The page scrolls, not the text.
        override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

        // Formatting, from the toolbar (through the responder chain) and the keyboard.

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let action: Selector? = switch (flags, key) {
            case ([.command], "b"): #selector(zeroBold(_:))
            case ([.command], "i"): #selector(zeroItalic(_:))
            case ([.command], "e"): #selector(zeroCode(_:))
            case ([.command], "k"): #selector(zeroLink(_:))
            case ([.command, .shift], "x"): #selector(zeroStrike(_:))
            case ([.command, .option], "1"): #selector(zeroHeading1(_:))
            case ([.command, .option], "2"): #selector(zeroHeading2(_:))
            case ([.command, .option], "3"): #selector(zeroHeading3(_:))
            case ([.command, .shift], "7"), ([.command, .shift], "&"): #selector(zeroNumbers(_:))
            case ([.command, .shift], "8"), ([.command, .shift], "*"): #selector(zeroBullets(_:))
            case ([.command, .shift], "9"), ([.command, .shift], "("): #selector(zeroChecklist(_:))
            default: nil
            }
            guard let action else { return super.performKeyEquivalent(with: event) }
            perform(action, with: nil)
            return true
        }

        @objc func zeroBold(_ sender: Any?) { wrap("**") }
        @objc func zeroItalic(_ sender: Any?) { wrap("_") }
        @objc func zeroStrike(_ sender: Any?) { wrap("~~") }
        @objc func zeroCode(_ sender: Any?) { wrap("`") }
        @objc func zeroHeading1(_ sender: Any?) { prefix { _ in "# " } }
        @objc func zeroHeading2(_ sender: Any?) { prefix { _ in "## " } }
        @objc func zeroHeading3(_ sender: Any?) { prefix { _ in "### " } }
        @objc func zeroBullets(_ sender: Any?) { prefix { _ in "- " } }
        @objc func zeroNumbers(_ sender: Any?) { prefix { "\($0 + 1). " } }
        @objc func zeroChecklist(_ sender: Any?) { prefix { _ in "- [ ] " } }
        @objc func zeroQuote(_ sender: Any?) { prefix { _ in "> " } }

        @objc func zeroLink(_ sender: Any?) {
            let range = selectedRange()
            let words = (string as NSString).substring(with: range)
            let link = "[\(words.isEmpty ? "text" : words)](https://)"
            // The address selected, to type over: the words were already there.
            let address = (link as NSString).range(of: "https://")
            replace(range, with: link, select: words.isEmpty ? NSRange(location: range.location + 1, length: 4) : NSRange(location: range.location + address.location, length: address.length))
        }

        @objc func zeroCodeBlock(_ sender: Any?) {
            let lines = (string as NSString).lineRange(for: selectedRange())
            var words = (string as NSString).substring(with: lines)
            let ends = words.hasSuffix("\n")
            if ends { words.removeLast() }
            replace(lines, with: "```\n" + words + "\n```" + (ends ? "\n" : ""), select: NSRange(location: lines.location + 4, length: (words as NSString).length))
        }

        @objc func zeroTable(_ sender: Any?) {
            insertBlock("| Column | Column |\n|---|---|\n|  |  |")
            structured?()
        }

        @objc func zeroDivider(_ sender: Any?) { insertBlock("---") }

        /// A block of its own after the line the caret is on, set off by blank lines.
        private func insertBlock(_ block: String) {
            let text = string as NSString
            let line = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
            let at = NSMaxRange(line)
            let before = at == 0 ? "" : (text.substring(to: at).hasSuffix("\n") ? "\n" : "\n\n")
            let piece = before + block + "\n\n"
            replace(NSRange(location: at, length: 0), with: piece, select: NSRange(location: at + (piece as NSString).length, length: 0))
        }

        /// Marks around the selection: put there, or taken off when they're there already.
        private func wrap(_ mark: String) {
            let text = string as NSString
            let range = selectedRange()
            let length = (mark as NSString).length
            let before = range.location >= length ? text.substring(with: NSRange(location: range.location - length, length: length)) : ""
            let after = NSMaxRange(range) + length <= text.length ? text.substring(with: NSRange(location: NSMaxRange(range), length: length)) : ""
            if before == mark && after == mark {
                replace(NSRange(location: range.location - length, length: range.length + 2 * length), with: text.substring(with: range),
                        select: NSRange(location: range.location - length, length: range.length))
            } else {
                replace(range, with: mark + text.substring(with: range) + mark, select: NSRange(location: range.location + length, length: range.length))
            }
        }

        /// Each selected line starts with the prefix (a heading's, a list's, a quote's), in place of any other; taken
        /// off when every line has it already.
        private func prefix(_ make: (Int) -> String) {
            let text = string as NSString
            let lines = text.lineRange(for: selectedRange())
            let block = text.substring(with: lines)
            var rows = block.components(separatedBy: "\n")
            let trailing = rows.last == ""
            if trailing { rows.removeLast() }
            let existing = #"^(#{1,6} |> |\s*(?:[-*+]|\d+[.)]) (?:\[[ xX]\] )?)"#
            let all = rows.enumerated().allSatisfy { $0.element.hasPrefix(make($0.offset)) }
            let changed = rows.enumerated().map { index, row in
                let bare = row.replacingOccurrences(of: existing, with: "", options: .regularExpression)
                return all ? bare : make(index) + bare
            }
            let out = changed.joined(separator: "\n") + (trailing ? "\n" : "")
            replace(lines, with: out, select: NSRange(location: lines.location + (out as NSString).length - (trailing ? 1 : 0), length: 0))
        }

        private func replace(_ range: NSRange, with words: String, select: NSRange) {
            guard shouldChangeText(in: range, replacementString: words) else { return }
            textStorage?.replaceCharacters(in: range, with: words)
            didChangeText()
            setSelectedRange(select)
        }

        /// A click on a task's box ("- [ ]") ticks it, undoably, as a checkbox would.
        override func mouseDown(with event: NSEvent) {
            if let box = box(at: event) {
                let ticked = (string as NSString).substring(with: box) == "[ ]" ? "[x]" : "[ ]"
                if shouldChangeText(in: box, replacementString: ticked) {
                    textStorage?.replaceCharacters(in: box, with: ticked)
                    didChangeText()
                }
                return
            }
            super.mouseDown(with: event)
        }

        private func box(at event: NSEvent) -> NSRange? {
            guard let manager = layoutManager, let container = textContainer else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            let index = manager.characterIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            let text = string as NSString
            guard index < text.length else { return nil }
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            guard let found = try? NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+(\[[ xX]\])"#).firstMatch(in: string, range: line) else { return nil }
            let box = found.range(at: 1)
            return NSLocationInRange(index, NSRange(location: box.location, length: box.length + 1)) ? box : nil
        }

        func show(line: Int) {
            let text = string as NSString
            var location = 0
            for _ in 1..<max(1, line) where location < text.length { location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0))) }
            let range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            guard let manager = layoutManager, let container = textContainer else { return }
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            scrollToVisible(NSRect(x: 0, y: rect.minY, width: 1, height: visibleRect.height * 0.8))
            showFindIndicator(for: range)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty, !placeholder.isEmpty {
                (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: [.font: MarkdownStyle.body, .foregroundColor: NSColor.tertiaryLabelColor])
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSLayoutManagerDelegate {
        var parent: PadTextField
        var observer: NSObjectProtocol?
        var shown: Int?
        init(_ parent: PadTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textDidEndEditing(_ notification: Notification) {
            if let view = notification.object as? NSTextView { reveal(view, around: nil) }
            parent.done()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, view.window?.firstResponder === view else { return }
            reveal(view, around: view.selectedRange())
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing edited: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
            guard edited.contains(.editedCharacters) else { return }
            MarkdownStyle.apply(to: storage)
            // The marks hidden again but on the line being written (the selection's change redraws them).
            hide(in: storage, showing: storage.layoutManagers.first?.firstTextView.flatMap { view in
                view.window?.firstResponder === view ? (storage.string as NSString).lineRange(for: NSRange(location: min(range.location, storage.length), length: 0)) : nil
            })
        }

        // Marks are shown on the lines the selection is on and hidden elsewhere: the text reads as written, not as
        // Markdown, but what's being edited shows all of itself.

        private func hide(in storage: NSTextStorage, showing lines: NSRange?) {
            let whole = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.zeroHidden, range: whole)
            storage.enumerateAttribute(.zeroMark, in: whole) { value, range, _ in
                guard value != nil else { return }
                if let lines, NSIntersectionRange(range, lines).length > 0 || NSLocationInRange(range.location, lines) { return }
                storage.addAttribute(.zeroHidden, value: true, range: range)
            }
        }

        private func reveal(_ view: NSTextView, around selection: NSRange?) {
            guard let storage = view.textStorage, let manager = view.layoutManager else { return }
            let text = storage.string as NSString
            let lines = selection.map { text.lineRange(for: NSRange(location: min($0.location, text.length), length: min($0.length, text.length - min($0.location, text.length)))) }
            guard lines != shownLines else { return }
            shownLines = lines
            storage.beginEditing()
            hide(in: storage, showing: lines)
            storage.endEditing()
            let whole = NSRange(location: 0, length: storage.length)
            manager.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
            manager.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
        }
        private var shownLines: NSRange??

        /// A hidden mark's glyphs are kept but not drawn and given no width, as control characters are: a null glyph
        /// would drop out of its line's measure, and the line would move when the mark came back.
        func layoutManager(_ manager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange range: NSRange) -> Int {
            guard let storage = manager.textStorage, range.length > 0 else { return 0 }
            // Most runs hide nothing: one look over their characters says so, before any glyph is looked at alone.
            let first = characterIndexes[0], last = characterIndexes[range.length - 1]
            let characters = NSRange(location: first, length: min(last + 1, storage.length) - first)
            var any = false
            if characters.length > 0 {
                storage.enumerateAttribute(.zeroHidden, in: characters) { value, _, stop in if value != nil { any = true; stop.pointee = true } }
            }
            guard any else { return 0 }
            let hidden = (0..<range.length).map { characterIndexes[$0] < storage.length && storage.attribute(.zeroHidden, at: characterIndexes[$0], effectiveRange: nil) != nil }
            let changed = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: range.length)
            defer { changed.deallocate() }
            for i in 0..<range.length { changed[i] = hidden[i] ? .controlCharacter : properties[i] }
            manager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
            return range.length
        }

        func layoutManager(_ manager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
            guard let storage = manager.textStorage, index < storage.length, storage.attribute(.zeroHidden, at: index, effectiveRange: nil) != nil else { return action }
            return .zeroAdvancement
        }

        func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            NSWorkspace.shared.open(url)
            return true
        }

        /// Return in a list starts the next item with its marker; on an empty item, the list ends there.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let text = view.string as NSString
            let caret = view.selectedRange()
            let line = text.lineRange(for: NSRange(location: caret.location, length: 0))
            let before = text.substring(with: NSRange(location: line.location, length: caret.location - line.location))
            guard caret.length == 0, let marker = before.range(of: #"^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) else { return false }
            if before[marker.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                view.insertText("", replacementRange: NSRange(location: line.location, length: caret.location - line.location))
                return true
            }
            view.insertText("\n" + next(String(before[marker])), replacementRange: caret)
            return true
        }

        /// The marker the next item starts with: the same bullet, the next number, an empty box.
        private func next(_ marker: String) -> String {
            let indent = String(marker.prefix { $0 == " " || $0 == "\t" })
            let bare = marker.trimmingCharacters(in: .whitespaces)
            if let number = Int(bare.prefix { $0.isNumber }) { return indent + "\(number + 1)" + String(bare.drop { $0.isNumber }.prefix(1)) + " " }
            return indent + String(bare.prefix(1)) + (bare.contains("[") ? " [ ] " : " ")
        }

        /// Right-click: a link to the section here, and to the pad.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let line = parent.firstLine + (view.string as NSString).substring(to: min(charIndex, (view.string as NSString).length)).filter { $0 == "\n" }.count
            var items: [NSMenuItem] = []
            if let section = parent.sectionLink(line) {
                items.append(MarkdownEditor.LinkItem(title: "Copy link to “\(section.title)”", link: section.link, label: section.title))
            }
            items.append(MarkdownEditor.LinkItem(title: "Copy link to scratchpad", link: parent.padLink.link, label: parent.padLink.title))
            for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
            menu.insertItem(.separator(), at: items.count)
            return menu
        }
    }
}

/// The formatting bar over a pad: each button acts on the text being written, through the responder chain, as its
/// shortcut does.
private struct PadToolbar: View {
    typealias Field = PadTextField.FieldView

    var body: some View {
        HStack(spacing: 2) {
            button("text-bold", "Bold", "⌘B", #selector(Field.zeroBold(_:)))
            button("text-italic", "Italic", "⌘I", #selector(Field.zeroItalic(_:)))
            button("text-strikethrough", "Strikethrough", "⇧⌘X", #selector(Field.zeroStrike(_:)))
            button("code", "Code", "⌘E", #selector(Field.zeroCode(_:)))
            button("link", "Link", "⌘K", #selector(Field.zeroLink(_:)))
            divider
            button("heading-1", "Heading", "⌥⌘1", #selector(Field.zeroHeading1(_:)))
            button("heading-2", "Subheading", "⌥⌘2", #selector(Field.zeroHeading2(_:)))
            button("heading-3", "Small heading", "⌥⌘3", #selector(Field.zeroHeading3(_:)))
            divider
            button("unordered-list", "Bulleted list", "⇧⌘8", #selector(Field.zeroBullets(_:)))
            button("ordered-list", "Numbered list", "⇧⌘7", #selector(Field.zeroNumbers(_:)))
            button("checkbox-checked", "Checklist", "⇧⌘9", #selector(Field.zeroChecklist(_:)))
            button("quote", "Quote", nil, #selector(Field.zeroQuote(_:)))
            divider
            button("square-code", "Code block", nil, #selector(Field.zeroCodeBlock(_:)))
            button("table", "Table", nil, #selector(Field.zeroTable(_:)))
            button("minus", "Divider", nil, #selector(Field.zeroDivider(_:)))
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var divider: some View { Rectangle().fill(Theme.stroke).frame(width: 1, height: 16).padding(.horizontal, 5) }

    private func button(_ icon: String, _ name: String, _ shortcut: String?, _ action: Selector) -> some View {
        Button { NSApp.sendAction(action, to: nil, from: nil) } label: {
            NucleoIcon(icon, size: 15).foregroundStyle(.secondary).frame(width: 28, height: 28)
        }
        .buttonStyle(Hovering())
        .tip(name, shortcut: shortcut)
    }
}

/// A table as cells to type in; rows and columns added with buttons, taken out from a cell's menu.
private struct TableGrid: View {
    @Binding var markdown: String
    @State private var hovered = false

    var body: some View {
        let rows = PadBlocks.cells(markdown)
        let width = rows.map(\.count).max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(0..<width, id: \.self) { c in
                                CellField(value: c < rows[r].count ? rows[r][c] : "", header: r == 0) { value in
                                    change { rows in
                                        while rows[r].count <= c { rows[r].append("") }
                                        rows[r][c] = value.replacingOccurrences(of: "\n", with: " ")
                                    }
                                }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .frame(minWidth: 90, maxWidth: 280, alignment: .leading)
                                    .background(r == 0 ? Theme.fieldTab : Color.clear)
                                    .overlay(alignment: .trailing) { if c < width - 1 { Rectangle().fill(Theme.stroke).frame(width: 1) } }
                                    .overlay(alignment: .bottom) { if r < rows.count - 1 { Rectangle().fill(Theme.stroke).frame(height: 1) } }
                                    .contextMenu {
                                        Button("Add row below") { change { $0.insert(Array(repeating: "", count: width), at: r + 1) } }
                                        Button("Add column after") { change { rows in for i in rows.indices { rows[i].insert(i == 0 ? "Column" : "", at: min(c + 1, rows[i].count)) } } }
                                        Divider()
                                        if r > 0 { Button("Delete row") { change { $0.remove(at: r) } } }
                                        if width > 1 { Button("Delete column") { change { rows in for i in rows.indices where c < rows[i].count { rows[i].remove(at: c) } } } }
                                    }
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            }
            HStack(spacing: 14) {
                Button { change { $0.append(Array(repeating: "", count: width)) } } label: { NucleoLabel("Add row", icon: "plus", size: 12) }
                Button { change { rows in for i in rows.indices { rows[i].append(i == 0 ? "Column" : "") } } } label: { NucleoLabel("Add column", icon: "plus", size: 12) }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            // Always laid out, shown on hover: nothing moves as the pointer passes.
            .opacity(hovered ? 1 : 0)
        }
        .onHover { hovered = $0 }
    }

    private func change(_ edit: (inout [[String]]) -> Void) {
        var rows = PadBlocks.cells(markdown)
        edit(&rows)
        markdown = PadBlocks.table(rows, divider: PadBlocks.divider(of: markdown))
    }
}

/// A cell being typed in keeps what's typed (a space at its end too), though the table's Markdown trims its cells.
private struct CellField: View {
    let value: String
    let header: Bool
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 13.5, weight: header ? .semibold : .regular))
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, now in if !focused { draft = now } }
            .onChange(of: draft) { _, now in if now.trimmingCharacters(in: .whitespaces) != value { commit(now) } }
    }
}

/// Images pasted into a pad: kept in the pads' own hidden folder, linked by their path.
enum PadImages {
    static func keep(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let folder = Paths.dir.appendingPathComponent("scratchpads/.assets")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased() + ".png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return file.path
    }
}
