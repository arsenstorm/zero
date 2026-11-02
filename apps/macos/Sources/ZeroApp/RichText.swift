import AppKit
import SwiftUI
import ZeroCore

// An answer laid out as one native text view, so a selection runs across its paragraphs, lists and code, with room
// between lines as Codex's answers have: Markdown's blocks become paragraph styles, and what Text can't draw (the
// rounded pill behind inline code, a code block's panel, a quote's bar, a rule) is drawn behind the text.

extension NSAttributedString.Key {
    static let zeroCode = NSAttributedString.Key("zeroCode")
    static let zeroCodeBlock = NSAttributedString.Key("zeroCodeBlock")
    static let zeroQuote = NSAttributedString.Key("zeroQuote")
    static let zeroRule = NSAttributedString.Key("zeroRule")
    /// A token of the composer's in the words (@loop, /skill): its yellow pill, in the token's own colour.
    static let zeroToken = NSAttributedString.Key("zeroToken")
    /// What a token opens when clicked (a loop); not a link, which the view would colour as one.
    static let zeroOpens = NSAttributedString.Key("zeroOpens")
}

enum RichMarkdown {
    static let codeFill = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.055) }
    static let blockFill = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04) }
    static let quoteBar = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.15) }

    private static let rendered: NSCache<NSString, NSAttributedString> = { let cache = NSCache<NSString, NSAttributedString>(); cache.countLimit = 500; return cache }()

    /// The text as rendered before, or rendered now and kept: a message that hasn't changed isn't parsed and styled
    /// again each time its view is drawn. The same rendering is the same object, which the view checks for.
    static func cached(_ text: String, size: CGFloat, compact: Bool, repo: String?, yours: Bool = false, render: () -> NSAttributedString) -> NSAttributedString {
        let key = "\(size)|\(compact)|\(yours)|\(repo ?? "")|\(text)" as NSString
        if let kept = rendered.object(forKey: key) { return kept }
        let made = render()
        rendered.setObject(made, forKey: key)
        return made
    }

    /// The text as rendered before, if it has been.
    static func kept(_ text: String, size: CGFloat, compact: Bool, repo: String?, yours: Bool = false) -> NSAttributedString? {
        rendered.object(forKey: "\(size)|\(compact)|\(yours)|\(repo ?? "")|\(text)" as NSString)
    }

    private static let renderedBlocks: NSCache<NSString, NSAttributedString> = { let cache = NSCache<NSString, NSAttributedString>(); cache.countLimit = 4000; return cache }()

    /// The blocks as one attributed text; `inline` reads what's inside a line (bold, code, links). With a `key` (what
    /// the inline links depend on), each top-level block is kept once rendered: an answer still streaming grows by
    /// its last block, and only that one is parsed and styled again.
    /// `growing`: the text is still arriving, and its last block isn't kept (it's different next frame; kept, every
    /// frame's would push out blocks the page needs).
    static func render(_ blocks: [MarkdownBlock], size: CGFloat, inline: (String) -> AttributedString, key: String? = nil, growing: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let key {
            for (index, block) in blocks.enumerated() {
                if growing && index == blocks.count - 1 {
                    let piece = NSMutableAttributedString()
                    append([block], depth: 0, into: piece, size: size, inline: inline)
                    out.append(piece)
                    continue
                }
                let name = "\(key)|\(size)|\(String(describing: block))" as NSString
                if let kept = renderedBlocks.object(forKey: name) { out.append(kept); continue }
                let piece = NSMutableAttributedString()
                append([block], depth: 0, into: piece, size: size, inline: inline)
                renderedBlocks.setObject(piece, forKey: name)
                out.append(piece)
            }
        } else {
            append(blocks, depth: 0, into: out, size: size, inline: inline)
        }
        // No space after the last paragraph: the view ends where the text does.
        if out.length > 0, out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// The same text quieter, for a preview beside the page: headings at the text's own size, code without its pill,
    /// less room between lines and paragraphs.
    static func compact(_ text: NSAttributedString, size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont, font.pointSize > size + 0.1, !font.fontDescriptor.symbolicTraits.contains(.monoSpace) else { return }
            out.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: range)
        }
        out.removeAttribute(.zeroCode, range: whole)
        out.removeAttribute(.kern, range: whole)
        out.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.lineSpacing = round(size * 0.28)
            style.paragraphSpacing = min(style.paragraphSpacing, round(size * 0.5))
            style.paragraphSpacingBefore = 0
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return out
    }

    private static let indentStep: CGFloat = 20

    private static func style(size: CGFloat, indent: CGFloat = 0, first: CGFloat? = nil, after: CGFloat, before: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        // About 1.5 lines from baseline to baseline, as the web's text has.
        style.lineSpacing = round(size * 0.42)
        style.headIndent = indent
        style.firstLineHeadIndent = first ?? indent
        style.paragraphSpacing = after
        style.paragraphSpacingBefore = before
        return style
    }

    private static func append(_ blocks: [MarkdownBlock], depth: Int, into out: NSMutableAttributedString, size: CGFloat, inline: (String) -> AttributedString, tight: Bool = false) {
        let indent = CGFloat(depth) * indentStep
        let gap = tight ? round(size * 0.35) : round(size * 0.8)
        for block in blocks {
            switch block {
            case let .heading(level, text):
                let font = NSFont.systemFont(ofSize: size + [5, 3, 1.5, 0.5, 0, 0][min(level, 6) - 1], weight: .semibold)
                out.append(line(inline(text), font: font, style: style(size: size, indent: indent, after: round(size * 0.4), before: level <= 2 ? round(size * 0.6) : 0)))
            case let .paragraph(text):
                out.append(line(inline(text), font: .systemFont(ofSize: size), style: style(size: size, indent: indent, after: gap)))
            case let .list(ordered, start, items):
                for (index, item) in items.enumerated() {
                    let marker = ordered ? "\(start + index)." : "•"
                    let text = NSMutableAttributedString(string: marker + "\t", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor])
                    text.append(styled(inline(item.text), font: .systemFont(ofSize: size)))
                    let hang = indent + indentStep
                    let paragraph = style(size: size, indent: hang, first: indent + (ordered ? 0 : 4), after: index == items.count - 1 && item.children.isEmpty ? gap : round(size * 0.3))
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: hang)]
                    paragraph.defaultTabInterval = indentStep
                    text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
                    text.append(NSAttributedString(string: "\n"))
                    out.append(text)
                    if !item.children.isEmpty { append(item.children, depth: depth + 1, into: out, size: size, inline: inline, tight: index < items.count - 1) }
                }
            case let .code(code):
                // One paragraph however many lines (line separators within), so its panel is one shape.
                let text = NSMutableAttributedString(string: code.replacingOccurrences(of: "\n", with: "\u{2028}"),
                                                     attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular), .foregroundColor: NSColor.labelColor])
                let paragraph = style(size: size - 1.5, indent: indent + 12, after: gap + 8, before: 8)
                paragraph.tailIndent = -12
                text.addAttributes([.paragraphStyle: paragraph, .zeroCodeBlock: true], range: NSRange(location: 0, length: text.length))
                text.append(NSAttributedString(string: "\n"))
                out.append(text)
            case let .quote(text):
                let quoted = line(inline(text), font: .systemFont(ofSize: size), style: style(size: size, indent: indent + 14, after: gap), color: .secondaryLabelColor)
                quoted.addAttribute(.zeroQuote, value: true, range: NSRange(location: 0, length: quoted.length - 1))
                out.append(quoted)
            case let .table(rows):
                out.append(table(rows, size: size, indent: indent, after: gap, inline: inline))
            case .rule:
                let rule = NSMutableAttributedString(string: " \n", attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: style(size: size, indent: indent, after: gap)])
                rule.addAttribute(.zeroRule, value: true, range: NSRange(location: 0, length: 1))
                out.append(rule)
            }
        }
    }

    private static func line(_ text: AttributedString, font: NSFont, style: NSParagraphStyle, color: NSColor = .labelColor) -> NSMutableAttributedString {
        let out = styled(text, font: font, color: color)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: font]))
        return out
    }

    /// What Markdown says inside a line, as AppKit attributes: bold and italic in the font, code in a pill, links.
    private static func styled(_ text: AttributedString, font: NSFont, color: NSColor = .labelColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in text.runs {
            let piece = String(text[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty { attributes[.font] = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.88, weight: .regular)
                attributes[.zeroCode] = true
            }
            if let link = run.link, link.scheme == "zero", link.host == "loop" || link.host == "skill" {
                attributes[.font] = NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
                attributes[.foregroundColor] = TokenTextView.tokenText
                attributes[.zeroToken] = true
                if link.host == "loop" { attributes[.zeroOpens] = link; attributes[.cursor] = NSCursor.pointingHand }
                let added = NSMutableAttributedString(string: piece, attributes: attributes)
                if out.length > 0 { out.addAttribute(.kern, value: 6, range: NSRange(location: out.length - 1, length: 1)) }
                if added.length > 0 { added.addAttribute(.kern, value: 6, range: NSRange(location: added.length - 1, length: 1)) }
                out.append(added)
                continue
            }
            if let link = run.link { attributes[.link] = link }
            // An image's token (ImageToken.linked): its pill, which opens the image.
            if let link = run.link, link.isFileURL, let number = ImageToken.number(inLabel: piece) {
                let token = NSMutableAttributedString(attributedString: ImageToken.attachment(number, font: font))
                token.addAttribute(.link, value: link, range: NSRange(location: 0, length: 1))
                out.append(token)
                continue
            }
            let added = NSMutableAttributedString(string: piece, attributes: attributes)
            // Room for the pill on either side of code: a little space after what comes before it, and after its last letter.
            if intent.contains(.code), added.length > 0 {
                if out.length > 0 { out.addAttribute(.kern, value: 6, range: NSRange(location: out.length - 1, length: 1)) }
                added.addAttribute(.kern, value: 6, range: NSRange(location: added.length - 1, length: 1))
            }
            out.append(added)
        }
        return out
    }

    private static func table(_ rows: [[String]], size: CGFloat, indent: CGFloat, after: CGFloat, inline: (String) -> AttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let columns = rows.map(\.count).max() ?? 0
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(r == 0 ? 1 : 0, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(.separatorColor)
                let paragraph = style(size: size, after: 0)
                paragraph.textBlocks = [block]
                let font = NSFont.systemFont(ofSize: size, weight: r == 0 ? .semibold : .regular)
                let cell = styled(inline(c < row.count ? row[c] : ""), font: font)
                cell.append(NSAttributedString(string: "\n"))
                cell.addAttributes([.paragraphStyle: paragraph], range: NSRange(location: 0, length: cell.length))
                out.append(cell)
            }
        }
        // Room after the table, on an empty paragraph of its own.
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: style(size: 4, after: after)]))
        return out
    }
}

/// Draws what the attributes ask for behind the text: rounded pills for inline code, a panel for a code block, a bar for
/// a quote, a hairline for a rule.
final class RichLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.zeroCodeBlock, in: characters) { value, range, _ in
            guard value != nil else { return }
            let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let left = (style?.headIndent ?? 12) - 12 + container.lineFragmentPadding
            let panel = NSRect(x: origin.x + left, y: origin.y + rect.minY - 8, width: container.size.width - left - container.lineFragmentPadding, height: rect.height + 16)
            RichMarkdown.blockFill.setFill()
            NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).fill()
        }
        for (key, fill) in [(NSAttributedString.Key.zeroCode, RichMarkdown.codeFill), (.zeroToken, TokenTextView.tokenFill)] {
        storage.enumerateAttribute(key, in: characters) { value, range, _ in
            guard value != nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var glyph = glyphs.location
            // A pill per line the code runs over, hugging its glyphs: from above their tops to below their descenders.
            while glyph < NSMaxRange(glyphs) {
                var line = NSRange()
                let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
                let segment = NSIntersectionRange(glyphs, line)
                guard segment.length > 0 else { break }
                let bounds = boundingRect(forGlyphRange: segment, in: container)
                let baseline = fragment.minY + location(forGlyphAt: segment.location).y
                let top = baseline - font.ascender - 2, bottom = baseline - font.descender + 2
                // Its last letter's kerning (6) is in the bounds: 4 of it inside the pill, 2 clear of what follows.
                let pill = NSRect(x: origin.x + bounds.minX - 4, y: origin.y + top, width: bounds.width + 2, height: bottom - top)
                fill.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
                glyph = NSMaxRange(segment)
            }
        }
        }
        storage.enumerateAttribute(.zeroQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            RichMarkdown.quoteBar.setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.x + container.lineFragmentPadding + (style?.headIndent ?? 14) - 14, y: origin.y + rect.minY, width: 3, height: rect.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        storage.enumerateAttribute(.zeroRule, in: characters) { value, range, _ in
            guard value != nil else { return }
            let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            NSColor.separatorColor.setFill()
            NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y + rect.midY, width: container.size.width - 2 * container.lineFragmentPadding, height: 1).fill()
        }
    }
}

/// The text view: selectable, not editable, as tall as its text at the width it's given.
final class RichTextView: NSTextView {
    convenience init() {
        let storage = NSTextStorage()
        let layout = RichLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        // The room either side for what's drawn past the text (below) is the lines' own padding, inside the text's
        // area: AppKit draws backgrounds only within it, and an inset outside cut off a pill that starts a line.
        container.lineFragmentPadding = Self.bleed
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        // Room either side for what's drawn past the text: an inline code's pill reaches 4 pt before its first letter,
        // and a pill that starts a line would otherwise lose its left edge to the view's. RichText takes the room back.
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
    }

    /// How far the view reaches past its text on each side.
    static let bleed: CGFloat = 6

    /// Set: a click anywhere but on a link is this.
    var onClick: (() -> Void)?

    /// The text it shows (the rendering's own object), and its height at the width last asked.
    var shown: NSAttributedString?
    private var measured: (width: CGFloat, height: CGFloat, used: CGFloat)?

    func show(_ text: NSAttributedString) {
        guard text !== shown else { return }
        shown = text
        measured = nil
        textStorage?.setAttributedString(text)
    }

    /// Its height at `width`, laid out once per text and width: SwiftUI asks several times a layout.
    func height(at width: CGFloat) -> CGFloat { size(at: width).height }

    /// Its size laid out at `width`: that tall, and as wide as its widest line (a short message's bubble hugs it).
    func size(at width: CGFloat) -> CGSize {
        if let measured, measured.width == width { return CGSize(width: measured.used, height: measured.height) }
        guard let container = textContainer, let layout = layoutManager else { return .zero }
        if container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // A code block last: its panel reaches 8 pt under the text (RichLayoutManager), so the view does too.
        let below: CGFloat = (textStorage.map { $0.length > 0 && $0.attribute(.zeroCodeBlock, at: $0.length - 1, effectiveRange: nil) != nil } ?? false) ? 8 : 0
        measured = (width, ceil(used.height) + below, min(width, ceil(used.width)))
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height) + below)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }

    /// On whole pixels: text drawn at a fractional position is resampled, and blurs.
    override func setFrameOrigin(_ origin: NSPoint) {
        let scale = window?.backingScaleFactor ?? 2
        super.setFrameOrigin(NSPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale))
    }

    /// Scrolling goes to the conversation around it, not to a text view with nothing to scroll.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    /// A click on an image's pill opens the image; on a loop's pill, the loop.
    override func mouseDown(with event: NSEvent) {
        if let hit = ImageToken.hit(event, in: self), let link = textStorage?.attribute(.link, at: hit.index, effectiveRange: nil) as? URL {
            ImageViewer.shared.show(link.path, among: imagePaths)
            return
        }
        if let index = characterIndex(under: event), let url = textStorage?.attribute(.zeroOpens, at: index, effectiveRange: nil) as? URL {
            NSApp.sendAction(#selector(AppDelegate.openZeroURL(_:)), to: nil, from: url)
            return
        }
        if let onClick, characterIndex(under: event).flatMap({ textStorage?.attribute(.link, at: $0, effectiveRange: nil) }) == nil {
            onClick()
            return
        }
        super.mouseDown(with: event)
    }

    /// The scroll wheel's button opens what's under it too: a link, a loop's pill, an image's.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let index = characterIndex(under: event) else { return super.otherMouseDown(with: event) }
        if let url = textStorage?.attribute(.zeroOpens, at: index, effectiveRange: nil) as? URL { NSApp.sendAction(#selector(AppDelegate.openZeroURL(_:)), to: nil, from: url); return }
        guard let link = textStorage?.attribute(.link, at: index, effectiveRange: nil) else { return super.otherMouseDown(with: event) }
        let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return }
        if url.isFileURL, textStorage?.attribute(.attachment, at: index, effectiveRange: nil) != nil { ImageViewer.shared.show(url.path, among: imagePaths) } else { NSWorkspace.shared.open(url) }
    }

    /// Every image the message's pills open, in order: what the viewer moves between.
    private var imagePaths: [String] {
        guard let storage = textStorage else { return [] }
        var paths: [String] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard (value as? NSTextAttachment)?.attachmentCell is ImageToken.Cell, let link = storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL, link.isFileURL else { return }
            if !paths.contains(link.path) { paths.append(link.path) }
        }
        return paths
    }

    /// The character under the pointer, when it is on one's glyph.
    private func characterIndex(under event: NSEvent) -> Int? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let inText = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: inText, in: container)
        guard glyph < manager.numberOfGlyphs, manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(inText) else { return nil }
        return manager.characterIndexForGlyph(at: glyph)
    }
}

/// Markdown in a RichTextView, for SwiftUI: its text where the words around it are, the view's bleed past them on
/// each side.
struct RichText: View {
    let text: NSAttributedString
    var hugs = false
    /// A click that isn't on a link (a scratchpad's block, to edit it): the click is this, not a selection.
    var onClick: (() -> Void)? = nil
    var body: some View { RichTextBox(text: text, hugs: hugs, onClick: onClick).padding(.horizontal, -RichTextView.bleed) }
}

private struct RichTextBox: NSViewRepresentable {
    let text: NSAttributedString
    var hugs = false
    var onClick: (() -> Void)?

    /// Views that left the page, kept for the next page: one that showed this very text comes back with its layout
    /// already measured, so a task switched back to draws without laying its words out again. A text view is the
    /// dear part of a message row to make; the words are cached already (RichMarkdown).
    @MainActor enum Pool {
        private static var free: [RichTextView] = []
        private static let limit = 400

        static func take(_ text: NSAttributedString) -> RichTextView {
            if let index = free.lastIndex(where: { $0.shown === text }) { return free.remove(at: index) }
            return free.popLast() ?? RichTextView()
        }

        static func give(_ view: RichTextView) {
            view.removeFromSuperview()
            free.append(view)
            if free.count > limit { free.removeFirst(free.count - limit) }
        }
    }

    func makeNSView(context: Context) -> RichTextView { Pool.take(text) }

    static func dismantleNSView(_ view: RichTextView, coordinator: ()) { Pool.give(view) }

    func updateNSView(_ view: RichTextView, context: Context) {
        view.show(text)
        view.onClick = onClick
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RichTextView, context: Context) -> CGSize? {
        // The width given includes the bleed either side; the text is laid out in what's between.
        let bleed = RichTextView.bleed * 2
        let width = proposal.width.map { min($0, 10_000) } ?? 560 + bleed
        view.show(text)
        let text = view.size(at: max(1, width))
        // As wide as its text, when it hugs (a message of yours); else the width it's given.
        return CGSize(width: hugs ? min(width, text.width) : width, height: text.height)
    }
}
