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
    /// An image an agent shows (`![…](/path)`), by its file: a click opens it in the image viewer.
    static let zeroPicture = NSAttributedString.Key("zeroPicture")
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
    /// A code block as its monospaced lines alone, at the text's own indent: for a bubble, which is already its
    /// background. Its lines still copy as lines.
    static func flat(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.zeroCodeBlock, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value != nil else { return }
            out.removeAttribute(.zeroCodeBlock, range: range)
            guard let style = (out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.headIndent = max(0, style.headIndent - 12)
            style.firstLineHeadIndent = max(0, style.firstLineHeadIndent - 12)
            style.tailIndent = 0
            style.paragraphSpacingBefore = 0
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return out
    }

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
                    // A bullet larger than the text's own "•" (a speck beside it), lowered to sit on the line's middle
                    // as it was: a font scales up from the baseline.
                    if !ordered {
                        text.addAttributes([.font: NSFont.systemFont(ofSize: round(size * 1.4)), .baselineOffset: -round(size * 0.14)], range: NSRange(location: 0, length: 1))
                    }
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
            case let .image(path, alt):
                out.append(picture(path, alt: alt, size: size, indent: indent, after: gap))
            case .rule:
                let rule = NSMutableAttributedString(string: " \n", attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: style(size: size, indent: indent, after: gap)])
                rule.addAttribute(.zeroRule, value: true, range: NSRange(location: 0, length: 1))
                out.append(rule)
            }
        }
    }

    /// An image an agent shows: the file itself, no wider than an answer's column reads, kept to its proportions; its
    /// words when it can't be read.
    private static func picture(_ path: String, alt: String, size: CGFloat, indent: CGFloat, after: CGFloat) -> NSAttributedString {
        let paragraph = style(size: size, indent: indent, after: after)
        guard let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 else {
            return line(AttributedString(alt.isEmpty ? path : alt), font: .systemFont(ofSize: size), style: paragraph, color: .secondaryLabelColor)
        }
        let scale = min(1, 560 / image.size.width, 420 / image.size.height)
        image.size = NSSize(width: round(image.size.width * scale), height: round(image.size.height * scale))
        // Drawn through a cell of its own, as the image pills are: answers are laid out by TextKit 1, which keeps an
        // attachment's `image` but draws nothing for it.
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        let out = NSMutableAttributedString(attachment: attachment)
        out.append(NSAttributedString(string: "\n"))
        out.addAttributes([.paragraphStyle: paragraph, .toolTip: alt], range: NSRange(location: 0, length: out.length))
        out.addAttributes([.zeroPicture: path, .cursor: NSCursor.pointingHand], range: NSRange(location: 0, length: 1))
        return out
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
            if let link = run.link, link.isFileURL, let named = ImageToken.number(inLabel: piece) {
                let token = NSMutableAttributedString(attributedString: ImageToken.attachment(named.number, font: font, video: named.video))
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
    /// A code block's panel: 12 pt either side of its text, 8 pt above and below; where the copy button goes too.
    static func panel(for range: NSRange, storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer, origin: NSPoint) -> NSRect {
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let left = (style?.headIndent ?? 12) - 12 + container.lineFragmentPadding
        return NSRect(x: origin.x + left, y: origin.y + rect.minY - 8, width: container.size.width - left - container.lineFragmentPadding, height: rect.height + 16)
    }

    /// The selection's highlight on each line as wide as what's selected on it, and as tall as the line (not the room
    /// after a paragraph): AppKit's ran to the text's right edge on lines that wrap and through the gap between items,
    /// whitespace that isn't there.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let container = textContainers.first else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        // A selection carried across messages is one: each shows it as the active one does, not greyed.
        // (Known by what's filled, its own selection, not by colour: the inactive one AppKit hands over isn't the
        // system's named one.)
        // One colour, Codex's: a neutral grey, whether the window is active or the selection is carried across
        // messages (AppKit greys an inactive one, and its accent blue read heavy over a whole answer).
        let color = Self.selection
        // Set to fill with: AppKit sets its own before asking, and fills with what's set, not with what it's given.
        color.setFill()
        // Each of AppKit's rects on its own (it draws a selection in pieces), and each line it covers (one rect can span
        // the lines selected whole): a band per line, over the selected words alone (not the line's end after its
        // last word, not a newline's room to the edge) and a body line tall, so a line with a bullet (its glyph
        // larger) is no taller, and the room after a paragraph gets none.
        let selected = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let text = textStorage?.string as NSString?
        var placed: [NSRect] = []
        for i in 0..<rectCount {
            let rect = rectArray[i]
            let local = rect.offsetBy(dx: -drawnAt.x, dy: -drawnAt.y)
            let covered = glyphRange(forBoundingRect: local, in: container)
            enumerateLineFragments(forGlyphRange: covered) { fragment, used, _, lineGlyphs, _ in
                var picked = NSIntersectionRange(lineGlyphs, selected)
                // Its trailing spaces and newline off: they're no words, and a newline's box runs to the edge.
                while picked.length > 0, let text, case let c = text.character(at: self.characterIndexForGlyph(at: NSMaxRange(picked) - 1)),
                      let scalar = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) { picked.length -= 1 }
                guard picked.length > 0, used.minY < local.maxY, used.maxY > local.minY else { return }
                let words = self.boundingRect(forGlyphRange: picked, in: container)
                let style = self.textStorage?.attribute(.paragraphStyle, at: self.characterIndexForGlyph(at: picked.location), effectiveRange: nil) as? NSParagraphStyle
                // Around its words, from their baseline: their tallest ascender above and deepest descender below (a
                // bullet, larger and raised, left out), and half the line spacing either side, so one line's band meets
                // the next's, and a paragraph's last line, or the text's, is as tall as any other. Laid on each line's
                // room instead, AppKit's room after a paragraph (there, but not at the text's end) and code's taller
                // font put bands low or high.
                let lineChars = self.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                var ascent: CGFloat = 0, descent: CGFloat = 0
                self.textStorage?.enumerateAttributes(in: lineChars) { attributes, _, _ in
                    guard let face = attributes[.font] as? NSFont, (attributes[.baselineOffset] as? CGFloat ?? 0) == 0 else { return }
                    ascent = max(ascent, face.ascender); descent = max(descent, -face.descender)
                }
                let spacing = style?.lineSpacing ?? 0
                let baseline = fragment.minY + self.location(forGlyphAt: NSMaxRange(picked) - 1).y
                let minY = ascent > 0 ? baseline - ascent - spacing / 2 : used.minY
                let maxY = ascent > 0 ? baseline + descent + spacing / 2 : used.maxY
                let minX = words.minX, maxX = words.maxX
                guard maxX - minX > 0.5, maxY > minY else { return }
                placed.append(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).offsetBy(dx: self.drawnAt.x, dy: self.drawnAt.y))
            }
        }
        guard !placed.isEmpty else { return }
        placed.withUnsafeBufferPointer { super.fillBackgroundRectArray($0.baseAddress!, count: $0.count, forCharacterRange: charRange, color: color) }
    }
    /// The selection's grey: light text stays readable on it in dark mode, dark text in light.
    static let selection = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.36, alpha: 1) : NSColor(white: 0.82, alpha: 1) }

    /// Where the text is being drawn (drawBackground's origin): AppKit's rects are in the view, the layout's in the
    /// container.
    private var drawnAt = NSPoint.zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawnAt = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.zeroCodeBlock, in: characters) { value, range, _ in
            guard value != nil else { return }
            let panel = Self.panel(for: range, storage: storage, manager: self, container: container, origin: origin)
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
    /// Its layout manager's delegate, kept here (a layout manager doesn't keep its delegate).
    private var breaks: TokenBreaks?
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
        // A token of yours ("/skill") on one line, whole, as the composer keeps it.
        breaks = TokenBreaks { [weak storage] index in
            guard let storage, index > 0, index < storage.length else { return false }
            return storage.attribute(.zeroToken, at: index - 1, effectiveRange: nil) != nil && storage.attribute(.zeroToken, at: index, effectiveRange: nil) != nil
        }
        layout.delegate = breaks
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

    /// A selection made: a Reply chip just above where it starts, its words quoted into the composer.
    var onReply: ((String) -> Void)?
    private var replyChip: NSView?

    /// The message a selection was started in (its anchor), and the others a drag (or Select All) took in with it:
    /// a conversation's messages are each a view of their own, and a selection is one view's, so Zero carries it
    /// across them. One selection at a time: started in one message, any other's goes.
    private static weak var selecting: RichTextView?
    private static var extended: [Weak] = []
    private struct Weak { weak var view: RichTextView? }
    /// Every text view in a window: a conversation's are those under the same scroll view (RichTextView.peers).
    private static let all = NSHashTable<RichTextView>.weakObjects()
    /// Set while Zero sets this view's selection itself (carrying one across), so it isn't taken as the user's.
    private var carried = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.all.add(self) } else { Self.all.remove(self); if Self.selecting === self { Self.selecting = nil } }
    }

    /// This conversation's messages, top to bottom.
    private func peers() -> [RichTextView] {
        let scroll = enclosingScrollView
        // On screen: a page kept behind the one shown has its messages in the window too, not to be taken in unseen.
        return Self.all.allObjects.filter { $0.window === window && $0.enclosingScrollView === scroll && $0.superview != nil
            && ($0 === self || (!$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty)) }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// A click anywhere in the app but a message's words (the composer, the sidebar, the page around them): what's
    /// selected goes, as in one page of text, rather than staying highlighted.
    private static var clickWatch: Any?
    private static func watchClicks() {
        guard clickWatch == nil else { return }
        clickWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            var view = event.window?.contentView?.hitTest(event.locationInWindow)
            while let found = view, !(found is RichTextView) { view = found.superview }
            if view == nil {
                MainActor.assumeIsolated {
                    selecting?.deselect()
                    clearExtended(except: nil)
                    selecting = nil
                }
            }
            return event
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let had = selectedRanges.contains { $0.rangeValue.length > 0 }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // All of it drawn again, when there's a selection to draw or one that went: AppKit redraws only the pieces it
        // would have filled, and the bands go a little past them. Not for the empty one a new text sets (every frame
        // of a reply fading in), which made each frame lay the whole text out again.
        if had || ranges.contains(where: { $0.rangeValue.length > 0 }) { needsDisplay = true }
        guard !carried else { return }
        if ranges.contains(where: { $0.rangeValue.length > 0 }) { Self.watchClicks() }
        // Being made, the chip goes (it would answer what was selected before), and the selection is carried into
        // the messages the pointer has gone to; made, the chip is placed above where it starts.
        if stillSelecting { Self.hideReplies(); extend() } else { Self.placeReplies() }
    }

    override func mouseDown(with event: NSEvent) {
        // A click in another message: the selection that was elsewhere goes.
        if Self.selecting !== self { Self.selecting?.deselect() }
        Self.clearExtended(except: self)
        Self.selecting = self
        clickedRest(event)
    }

    /// Select All: the whole conversation.
    override func selectAll(_ sender: Any?) {
        Self.selecting?.deselect()
        Self.clearExtended(except: nil)
        Self.selecting = self
        super.selectAll(sender)
        for view in peers() where view !== self {
            view.carry(NSRange(location: 0, length: view.textStorage?.length ?? 0))
            Self.extended.append(Weak(view: view))
        }
        Self.placeReplies()
    }

    /// Copied, every message's selected words, in order.
    @objc override func copy(_ sender: Any?) {
        let words = Self.selectedWords()
        guard Self.selecting === self, !Self.extended.isEmpty, !words.isEmpty else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(words, forType: .string)
    }

    private func carry(_ range: NSRange) {
        carried = true
        setSelectedRange(range)
        carried = false
    }

    private func deselect() {
        carry(NSRange(location: selectedRange().location, length: 0))
        hideReply()
    }

    private static func clearExtended(except keep: RichTextView?) {
        for view in extended.compactMap(\.view) where view !== keep { view.deselect() }
        extended = []
    }

    /// Dragged past this message: the messages between taken in whole, the one under the pointer to the pointer.
    private func extend() {
        guard Self.selecting === self, let window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        let views = peers()
        guard let mine = views.firstIndex(where: { $0 === self }) else { return }
        // The message under the pointer, or the last above it (between two, the one it has passed).
        let target = views.firstIndex { let f = $0.convert($0.bounds, to: nil); return point.y >= f.minY && point.y <= f.maxY }
            ?? views.lastIndex { $0.convert($0.bounds, to: nil).minY >= point.y } ?? mine
        var taken: [Weak] = []
        for (index, view) in views.enumerated() where view !== self {
            let length = view.textStorage?.length ?? 0
            var range: NSRange?
            if target > mine, index > mine, index <= target {
                range = index < target ? NSRange(location: 0, length: length)
                    : NSRange(location: 0, length: view.characterIndexForInsertion(at: view.convert(point, from: nil)))
            } else if target < mine, index < mine, index >= target {
                let from = index > target ? 0 : view.characterIndexForInsertion(at: view.convert(point, from: nil))
                range = NSRange(location: from, length: length - from)
            }
            if let range, range.length > 0 {
                view.carry(range)
                taken.append(Weak(view: view))
            } else if view.selectedRange().length > 0 {
                view.carry(NSRange(location: 0, length: 0))
            }
        }
        Self.extended = taken
    }

    /// The selected words of the selection's messages, top to bottom.
    private static func selectedWords() -> String {
        guard let anchor = selecting else { return "" }
        let views = ([anchor] + extended.compactMap(\.view)).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        return views.compactMap { view -> String? in
            guard let storage = view.textStorage, view.selectedRange().length > 0 else { return nil }
            return storage.attributedSubstring(from: view.selectedRange()).string.replacingOccurrences(of: "\u{2028}", with: "\n")
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hideReplies() {
        selecting?.hideReply()
        for view in extended.compactMap(\.view) { view.hideReply() }
    }

    /// The chip above where the selection starts, in its topmost message, for all of it.
    private static func placeReplies() {
        hideReplies()
        guard let anchor = selecting else { return }
        let views = ([anchor] + extended.compactMap(\.view)).filter { $0.selectedRange().length > 0 }
        guard let top = views.max(by: { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }) else { return }
        top.placeReply(words: selectedWords())
    }

    private func hideReply() { replyChip?.removeFromSuperview(); replyChip = nil }

    private func placeReply(words: String) {
        hideReply()
        guard let onReply, let layout = layoutManager, let container = textContainer else { return }
        let range = selectedRange()
        guard !words.isEmpty, range.length > 0 else { return }
        // Where it starts: its first line's part.
        var firstLine = NSRange()
        let start = layout.glyphIndexForCharacter(at: range.location)
        layout.lineFragmentRect(forGlyphAt: start, effectiveRange: &firstLine)
        let onFirst = NSIntersectionRange(firstLine, layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
        let rect = layout.boundingRect(forGlyphRange: onFirst, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let chip = NSHostingView(rootView: ReplyChip { [weak self] in onReply(words); self?.hideReply() })
        let size = chip.fittingSize
        chip.frame = NSRect(x: min(max(0, rect.minX), max(0, bounds.width - size.width)), y: rect.minY - size.height - 4, width: size.width, height: size.height)
        // No room above it in this text (a step's words, the step before close above): beside where the selection
        // ends, or under it, not over what's above.
        if chip.frame.minY < -6 {
            var lastLine = NSRange()
            layout.lineFragmentRect(forGlyphAt: max(start, layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1)), effectiveRange: &lastLine)
            let onLast = NSIntersectionRange(lastLine, layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
            let end = layout.boundingRect(forGlyphRange: onLast, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            chip.frame.origin = end.maxX + 8 + size.width <= bounds.width
                ? NSPoint(x: end.maxX + 8, y: end.midY - size.height / 2)
                : NSPoint(x: min(max(0, end.minX), max(0, bounds.width - size.width)), y: end.maxY + 4)
        }
        addSubview(chip)
        replyChip = chip
    }

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
        hovered = nil
        hideReply()
    }

    // Copying: a code block's lines are joined by line separators (one paragraph, one panel); copied, they're newlines.

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return false }
        let picked = NSMutableAttributedString()
        for range in selectedRanges.map(\.rangeValue) where range.length > 0 { picked.append(storage.attributedSubstring(from: range)) }
        guard picked.length > 0 else { return false }
        picked.mutableString.replaceOccurrences(of: "\u{2028}", with: "\n", options: [], range: NSRange(location: 0, length: picked.length))
        pboard.clearContents()
        if let rtf = try? picked.data(from: NSRange(location: 0, length: picked.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pboard.setData(rtf, forType: .rtf)
        }
        return pboard.setString(picked.string, forType: .string)
    }

    /// The code block under the pointer, and the button on its corner that copies it whole.
    private var hovered: NSRange? { didSet { if hovered != oldValue { placeCopy() } } }
    private lazy var copyButton: NSButton = {
        let button = NSButton(image: Nucleo.image("copy", size: 14) ?? NSImage(), target: self, action: #selector(copyBlock))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Copy"
        button.frame.size = NSSize(width: 26, height: 26)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = RichMarkdown.blockFill.cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.separatorColor.cgColor
        button.isHidden = true
        addSubview(button)
        return button
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["code"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: ["code": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hovered = codePanels().first { $0.panel.contains(point) }?.range
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = nil
    }

    /// Each code block's range and its panel in the view, as RichLayoutManager draws it.
    private func codePanels() -> [(range: NSRange, panel: NSRect)] {
        // Worked out once per text and width: the pointer moving over a message asked for them on every move.
        if let kept = panelsKept, kept.text === shown, kept.width == bounds.width { return kept.panels }
        let panels = findPanels()
        panelsKept = (shown, bounds.width, panels)
        return panels
    }
    private var panelsKept: (text: NSAttributedString?, width: CGFloat, panels: [(range: NSRange, panel: NSRect)])?

    private func findPanels() -> [(range: NSRange, panel: NSRect)] {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer, storage.length > 0 else { return [] }
        var panels: [(NSRange, NSRect)] = []
        storage.enumerateAttribute(.zeroCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            panels.append((range, RichLayoutManager.panel(for: range, storage: storage, manager: manager, container: container, origin: textContainerOrigin)))
        }
        return panels
    }

    private func placeCopy() {
        guard let hovered, let panel = codePanels().first(where: { $0.range == hovered })?.panel else { copyButton.isHidden = true; return }
        copyButton.image = Nucleo.image("copy", size: 14)
        // Its top-right corner, inside it (the view is flipped: y grows down).
        copyButton.frame.origin = NSPoint(x: panel.maxX - copyButton.frame.width - 6, y: panel.minY + 6)
        copyButton.isHidden = false
    }

    @objc private func copyBlock() {
        guard let hovered, let storage = textStorage else { return }
        let code = storage.attributedSubstring(from: hovered).string.replacingOccurrences(of: "\u{2028}", with: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.hasSuffix("\n") ? String(code.dropLast()) : code, forType: .string)
        // A tick for a moment says it did.
        copyButton.image = Nucleo.image("check", size: 14)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.image = Nucleo.image("copy", size: 14) }
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
        // As wide as its widest line of text: the used rect as a whole can come to the container's whole width once
        // the view has been laid out (its extra line, for an insertion point), which made a short message's bubble
        // stretch across the page.
        var widest: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, line, _, _, _ in widest = max(widest, line.maxX) }
        // A code block last: its panel reaches 8 pt under the text (RichLayoutManager), so the view does too.
        let below: CGFloat = (textStorage.map { $0.length > 0 && $0.attribute(.zeroCodeBlock, at: $0.length - 1, effectiveRange: nil) != nil } ?? false) ? 8 : 0
        measured = (width, ceil(used.height) + above + below, min(width, ceil(widest)))
        return CGSize(width: min(width, ceil(widest)), height: ceil(used.height) + above + below)
    }

    /// A code block first: its panel reaches 8 pt above the text (RichLayoutManager), and a view draws nothing above
    /// its top, so the text starts 8 pt down and the panel has its top.
    private var above: CGFloat {
        (textStorage.map { $0.length > 0 && $0.attribute(.zeroCodeBlock, at: 0, effectiveRange: nil) != nil } ?? false) ? 8 : 0
    }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y + above)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }

    /// Laid out at the width it's given, whatever it was last measured at: SwiftUI measures a cell at its narrowest
    /// too (a table's), and that measure left as the layout drew the words a letter a line, over the rows below.
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if let container = textContainer, size.width > 0, container.size.width != size.width { _ = self.size(at: size.width) }
    }

    /// On whole pixels: text drawn at a fractional position is resampled, and blurs.
    override func setFrameOrigin(_ origin: NSPoint) {
        let scale = window?.backingScaleFactor ?? 2
        super.setFrameOrigin(NSPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale))
    }

    /// Scrolling goes to the conversation around it, not to a text view with nothing to scroll.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    /// A click on an image's pill opens the image; on a loop's pill, the loop.
    private func clickedRest(_ event: NSEvent) {
        if let hit = ImageToken.hit(event, in: self), let link = textStorage?.attribute(.link, at: hit.index, effectiveRange: nil) as? URL {
            if hit.cell.video { NSWorkspace.shared.open(link); return }
            ImageViewer.shared.show(link.path, among: imagePaths)
            return
        }
        // An image an agent shows: opened in the viewer, with the message's other images to go through.
        if let index = characterIndex(under: event), let path = textStorage?.attribute(.zeroPicture, at: index, effectiveRange: nil) as? String {
            ImageViewer.shared.show(path, among: imagePaths)
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
            if let picture = storage.attribute(.zeroPicture, at: range.location, effectiveRange: nil) as? String {
                if !paths.contains(picture) { paths.append(picture) }
                return
            }
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
        view.onReply = context.environment.replyToSelection
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

/// Above a selection in a conversation: answer what's selected.
private struct ReplyChip: View {
    let reply: () -> Void
    var body: some View {
        Button(action: reply) {
            HStack(spacing: 5) {
                NucleoIcon("arrow-turn-up-2", size: 12).scaleEffect(x: -1, y: 1)
                Text("Reply").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip("Reply to what's selected")
    }
}

extension EnvironmentValues {
    /// In a conversation: what's selected in its words, quoted into its composer.
    @Entry var replyToSelection: ((String) -> Void)? = nil
}

