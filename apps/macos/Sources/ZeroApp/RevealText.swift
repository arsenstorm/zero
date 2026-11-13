import AppKit
import Observation
import SwiftUI
import ZeroCore

/// An answer read out word by word with the words faded in by Core Animation, not redrawn: its text is styled and laid
/// out as it arrives (a few times a second), hidden by a mask, and each tick of playback only adds the newly read
/// words' shapes to the mask with a fade the render server runs. Drawn the old way (StreamingText), every tick restyled
/// the answer's end, laid it out again, and had SwiftUI measure the page: half a core while an answer streamed.
/// The default; `defaults write com.arsen.zero gpuReveal -bool false` goes back to the old way.
struct RevealText: View {
    let readout: Readout
    let text: String
    let cwd: String
    /// Bumped as the shown part gets taller (a new line): only then is SwiftUI asked to measure it again.
    @State private var grew = RevealGrowth()

    static var on: Bool { UserDefaults.standard.object(forKey: "gpuReveal") as? Bool ?? true }

    var body: some View {
        RevealBox(
            readout: readout, text: text,
            links: MarkdownText.links(cwd: cwd, yours: false),
            grew: grew, generation: grew.count
        )
        .padding(.horizontal, -RichTextView.bleed)
    }
}

@Observable final class RevealGrowth { var count = 0 }

private struct RevealBox: NSViewRepresentable {
    let readout: Readout
    let text: String
    let links: MarkdownText.Links
    let grew: RevealGrowth
    /// Changes with each growth, so SwiftUI measures the view again (sizeThatFits).
    let generation: Int

    func makeNSView(context: Context) -> RevealView { RevealView(readout: readout, grew: grew) }

    func updateNSView(_ view: RevealView, context: Context) { view.show(text, links: links) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RevealView, context: Context) -> CGSize? {
        let width = proposal.width.map { min($0, 10_000) } ?? 560 + RichTextView.bleed * 2
        view.show(text, links: links)
        return CGSize(width: width, height: view.shownHeight(at: max(1, width)))
    }

    static func dismantleNSView(_ view: RevealView, coordinator: ()) { view.stop() }
}

final class RevealView: NSView {
    private let readout: Readout
    private let grew: RevealGrowth
    private let text = RichTextView()
    /// Over the text: the page's colour where its words aren't shown yet. Covers fade out as words are read (each over
    /// just its words, a few lines at most), and the view's own height, down to the line being read, hides what's
    /// below. A mask over the whole answer instead cost the window server a pass over all of it each frame: the taller
    /// the answer, the fewer frames.
    private let covers = CALayer()
    /// The rest of the line being read, from its next word on (cover()).
    private var rest: [CALayer] = []
    /// Covers done with, kept in `covers` hidden for the next ones: each tick then changes layers' frames, not the
    /// tree. Removed and made anew (five or six a tick), the render server re-linked its copy of the tree 30 times a
    /// second.
    private var spare: [CALayer] = []
    /// Runs of words fading in: their characters (in the styled text), their covers, when their fade ends.
    private var fading: [(range: NSRange, layers: [CALayer], ends: CFTimeInterval)] = []
    private var source = ""
    /// Its characters, counted once per styling (counting them each tick was a walk of the whole answer).
    private var sourceCount = 0
    /// The deepest the shown part has reached at this width: never less (in a table, the next cell's first line is
    /// higher than the last line of the cell before it, and the answer shrank and jumped back).
    private var deepest: CGFloat = 0
    private let over = CoverView()
    /// Arrived since, not styled yet: reading is far enough from the end of what's laid out (show).
    private var pending: String?
    private var styledAt = CFAbsoluteTimeGetCurrent()
    private var links: MarkdownText.Links?
    /// Where what's read of the source ends in the styled text, worked out once per styling.
    private var marks = RevealMarks(source: "", styled: "")
    /// Characters of the styled text shown.
    private var shown = 0
    /// The source's characters read when last looked.
    private var read = -1
    /// Styled anew since: looked at again, whatever was read.
    private var restyled = false
    private var width: CGFloat = 0
    private var reported: CGFloat = -1
    private var stopped = false

    init(readout: Readout, grew: RevealGrowth) {
        self.readout = readout
        self.grew = grew
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(text)
        // Grown a line at a time: only the new line drawn (layout()). AppKit's default drew the whole answer shown again
        // at every new line, and the window server took it whole.
        text.layerContentsRedrawPolicy = .onSetNeedsDisplay
        text.layerContentsPlacement = .topLeft
        over.layer = covers
        over.wantsLayer = true
        addSubview(over)
        paint()
        follow()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func stop() { stopped = true }

    /// How close reading may come to the end of what's laid out before arrivals are styled at once: under a second's
    /// reading at the steady pace (Playback.pace). Reading runs about 480 characters behind arrivals (Playback.lag), so
    /// at 600 nearly every arrival was styled at once.
    private static let ahead = 200

    /// Each tick that reads more words: looked at once it's done (Observation says so before the change lands).
    private func follow() {
        withObservationTracking {
            _ = readout.shown
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.advance()
                    self.follow()
                }
            }
        }
    }

    /// The answer as it has arrived, styled and laid out in full: only its shown part is uncovered.
    func show(_ source: String, links: MarkdownText.Links) {
        guard source != self.source || self.links == nil else { return }
        // Words arrive up to 30 times a second, and reading runs a couple of seconds behind them: what has arrived is
        // styled and laid out again only as reading nears the end of what's laid out, or every half a second.
        // `read`, not the readout's: this runs in SwiftUI's update, where reading the readout would have SwiftUI update
        // this view with every tick.
        if self.links != nil, source.hasPrefix(self.source), sourceCount - max(read, 0) > Self.ahead,
            CFAbsoluteTimeGetCurrent() - styledAt < 0.5
        {
            pending = source
            return
        }
        pending = nil
        styledAt = CFAbsoluteTimeGetCurrent()
        self.source = source
        sourceCount = source.count
        self.links = links
        let styled = MarkdownText.renderGrowing(source, size: 14.5, links: links)
        text.show(styled, fading: false)
        marks = RevealMarks(source: ZeroEnding.split(source).0, styled: styled.string)
        // Made anew (the turn ended and its words moved into their own row, a task opened): as far as reading has got,
        // at once. Left to the next tick, it showed nothing for two frames and the page fell in and jumped.
        let made = read < 0
        if made { read = readout.readSoFar }
        // Where reading is in the text as styled now: styled again, what was read can come out shorter (a table or a
        // link taking shape), and the place kept from before was ahead of reading, the words after it shown early.
        shown = min(styled.length, marks.styled(through: max(read, 0)))
        if made { carryOn(styled.length) }
        // Not `read` reset: whether the next words fade is told by where reading was (a reset read as nothing fading,
        // and the words after each styling showed at once, bright among those still fading in).
        restyled = true
        if width > 0 { _ = text.size(at: width) }
        reshape()
        // After this update, not in it (see above).
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.advance() } }
    }

    func shownHeight(at width: CGFloat) -> CGFloat {
        if width != self.width {
            self.width = width
            deepest = 0
            _ = text.size(at: width)
            reshape()
        }
        reported = depth()
        return reported
    }

    /// How tall the shown part is: down to the line being read, never less than it's been; all of it once all of it is
    /// shown, as the finished text measures it (a code block's panel past its last line, a last paragraph's spacing).
    private func depth() -> CGFloat {
        guard let storage = text.textStorage, storage.length > 0 else { return 0 }
        // Kept as the deepest too: more words after a pause in the stream don't take the page back up.
        let reached = shown >= storage.length && width > 0 ? text.size(at: width).height : height(through: shown)
        deepest = max(deepest, reached)
        return deepest
    }

    override func layout() {
        super.layout()
        let old = text.frame
        text.frame = bounds
        over.frame = bounds
        // Taller: the strip below what was there. Another width (laid out anew) or shorter: all of it.
        if bounds.width == old.width, bounds.height >= old.height {
            if bounds.height > old.height {
                text.setNeedsDisplay(NSRect(x: 0, y: old.height, width: bounds.width, height: bounds.height - old.height))
            }
        } else {
            text.needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
        // Its colours are the appearance's: drawn again (only what it's told to redraw is, see init).
        text.needsDisplay = true
    }

    /// In a window, its appearance is the window's (dark or light) from here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }

    /// The page's colour and a code block's panel's (light or dark), for the covers over each.
    private var page = CGColor(gray: 0, alpha: 1)
    private var panel = CGColor(gray: 0, alpha: 1)
    private var panelFill = CGColor(gray: 0, alpha: 0)

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            page = Theme.cardColor.cgColor
            // Over a panel, the page with the panel's see-through fill on it (covers(_:)).
            panel = page
            panelFill = Theme.codeColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in rest + spare + fading.flatMap(\.layers) {
            layer.backgroundColor = page
            layer.sublayers?.forEach { $0.backgroundColor = panelFill }
        }
        CATransaction.commit()
    }

    /// A cover over a code block's panel: in the panel's colour.
    private static let onPanel = "panel"

    /// Covers over these pieces: in the panel's colour where they're over a code block's panel, else the page's.
    private func covers(_ pieces: [(rect: CGRect, panel: ClosedRange<CGFloat>?)]) -> [CALayer] {
        // One kept from before, or a new one in the tree: never animated from where it was (a cover sliding into
        // place would show words early).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        return pieces.flatMap { piece -> [CALayer] in
            var parts: [(CGRect, Bool)] = [(piece.rect, false)]
            if let panel = piece.panel {
                let rect = piece.rect
                parts = [
                    (CGRect(x: rect.minX, y: rect.minY, width: min(rect.maxX, panel.lowerBound) - rect.minX, height: rect.height), false),
                    (
                        CGRect(
                            x: max(rect.minX, panel.lowerBound), y: rect.minY,
                            width: min(rect.maxX, panel.upperBound) - max(rect.minX, panel.lowerBound), height: rect.height), true
                    ),
                    (
                        CGRect(
                            x: max(rect.minX, panel.upperBound), y: rect.minY, width: rect.maxX - max(rect.minX, panel.upperBound),
                            height: rect.height), false
                    ),
                ]
            }
            // size.width: CGRect.width is never negative, and parts that came out negative (a piece not reaching past a
            // panel's edge) passed, covering the panel beside the words in the page's colour: lighter strips.
            return parts.filter { $0.0.size.width > 0 }.map { rect, onPanel in
                let layer =
                    spare.popLast()
                    ?? {
                        let made = CALayer(); covers.addSublayer(made); return made
                    }()
                layer.isHidden = false
                layer.opacity = 1
                layer.frame = rect
                layer.name = onPanel ? Self.onPanel : nil
                layer.backgroundColor = onPanel ? panel : page
                // Over a panel, as the panel is drawn: the page, its see-through fill over it (one colour worked out to
                // match came out a shade off). Off a panel, a kept cover's fill is hidden, not removed.
                let fill = layer.sublayers?.first
                if onPanel {
                    let fill =
                        fill
                        ?? {
                            let made = CALayer(); layer.addSublayer(made); return made
                        }()
                    fill.isHidden = false
                    fill.frame = layer.bounds
                    fill.backgroundColor = panelFill
                } else {
                    fill?.isHidden = true
                }
                return layer
            }
        }
    }

    /// A cover done with: hidden, kept for the next.
    private func park(_ layer: CALayer) {
        layer.isHidden = true
        layer.removeAllAnimations()
        spare.append(layer)
    }

    /// The words playback has read since: their covers fade out on the render server.
    private func advance() {
        guard let links, let storage = text.textStorage else { return }
        let read = readout.shown
        guard read != self.read || restyled else { return }
        restyled = false
        if let pending, sourceCount - read <= Self.ahead {
            show(pending, links: links)
            return
        }
        // Faded in only when playback fades it in (read out as it streams): an answer shown whole (a finished task
        // opened, the page jumped to) is there at once, as the old way had it.
        let fades = readout.alpha(max(self.read, 0)) < 1
        self.read = read
        // Where the read part of the source ends in the styled text, by its words (Markdown's marks aren't in the styled
        // text, and a list's bullets are only there): styling the read part again for it, each tick, was most of a tick.
        let to = min(storage.length, marks.styled(through: read))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if to > shown, !fades {
            shown = to
        } else if to > shown {
            fade(NSRange(location: shown, length: to - shown), gone: 0)
            shown = to
        }
        cover()
        settle()
        CATransaction.commit()
        // Taller now (a new line read into): SwiftUI measures it again, once per new height, after the update this may
        // be part of (show is called from SwiftUI's).
        let height = depth()
        if width > 0, height != reported {
            reported = height
            DispatchQueue.main.async { [grew] in MainActor.assumeIsolated { grew.count += 1 } }
        }
    }

    /// Made with words still fading in (the turn ended and they moved into their own row, or the answer began a tick
    /// before this view did): their fades carried on from where they are, not dropped, which showed them at once.
    private func carryOn(_ length: Int) {
        let now = Date()
        let runs = readout.fadingSoFar.filter { now.timeIntervalSince($0.since) < Playback.fade }
        guard let first = runs.first else { return }
        shown = min(length, marks.styled(through: first.at))
        for (index, run) in runs.enumerated() {
            let end = index + 1 < runs.count ? runs[index + 1].at : read
            let from = min(length, marks.styled(through: run.at)), to = min(length, marks.styled(through: end))
            if to > from { fade(NSRange(location: from, length: to - from), gone: now.timeIntervalSince(run.since)) }
            shown = max(shown, to)
        }
    }

    /// A run of words fading in, `gone` seconds into its fade already: its covers fade out on the render server.
    private func fade(_ range: NSRange, gone: CFTimeInterval) {
        let layers = covers(pieces(range))
        let now = CACurrentMediaTime()
        for layer in layers {
            layer.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = Playback.fade
            fade.beginTime = now - gone
            fade.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            layer.add(fade, forKey: "fade")
        }
        fading.append((range, layers, now + Playback.fade - gone))
    }

    /// Covers done fading go.
    private func settle() {
        let now = CACurrentMediaTime()
        for run in fading where run.ends <= now { run.layers.forEach(park) }
        fading.removeAll { $0.ends <= now }
    }

    /// Every cover again, for a new width or text laid out anew: a fading run's covers made anew, carrying on its fade.
    private func reshape() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in fading.indices {
            let old = fading[index].layers
            let layers = covers(pieces(fading[index].range))
            for layer in layers {
                layer.opacity = 0
                if let fade = old.first?.animation(forKey: "fade") { layer.add(fade, forKey: "fade") }
            }
            old.forEach(park)
            fading[index].layers = layers
        }
        cover()
        CATransaction.commit()
    }

    /// What isn't read yet within the view's height covered, from the next word on: the rest of the line being read,
    /// and in a table the cells after it in the row (side by side, a cell's lines can run below the line being read).
    /// The view ends at the line being read, hiding what's below.
    private func cover() {
        rest.forEach(park)
        rest = []
        guard let layout = text.layoutManager, let container = text.textContainer, let storage = text.textStorage, shown > 0,
            shown < storage.length
        else { return }
        let height = depth() - text.textContainerOrigin.y
        let visible = layout.glyphRange(forBoundingRect: CGRect(x: 0, y: 0, width: container.size.width, height: height), in: container)
        let start = layout.glyphIndexForCharacter(at: shown)
        guard NSMaxRange(visible) > start else { return }
        let characters = layout.characterRange(
            forGlyphRange: NSRange(location: start, length: NSMaxRange(visible) - start), actualGlyphRange: nil)
        // And all below the text being read, to the view's foot: the room after it, where the next block (a code
        // block's panel) can start, stays hidden until that block is read.
        let depth = depth()
        let origin = text.textContainerOrigin
        let reading = layout.lineFragmentUsedRect(forGlyphAt: start, effectiveRange: nil)
        let before = layout.lineFragmentUsedRect(forGlyphAt: max(0, start - 1), effectiveRange: nil)
        let foot = (reading.minY + origin.y < depth ? reading.maxY : before.maxY) + origin.y
        // Not in a table: the cells beside the one being read can run below it, read already (cells(after:through:)).
        let inTable =
            !((storage.attribute(.paragraphStyle, at: shown, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty ?? true)
        let below = inTable ? CGRect.zero : CGRect(x: 0, y: foot, width: max(bounds.width, width), height: max(0, depth - foot))
        // The panel below is the one the reading line is on (by its first character, as in pieces(_:)).
        var readingLine = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: start, effectiveRange: &readingLine)
        let belowPanel = panel(at: layout.characterIndexForGlyph(at: readingLine.location))
        rest = covers(pieces(characters) + cells(after: shown, through: NSMaxRange(characters)) + [(below, belowPanel)])
    }

    /// A table's cells not yet read, by their own rectangles (side by side, one cell's lines run below the line being
    /// read): one not started covered whole; the one being read below its line being read (the rest of that line is
    /// the line's own cover).
    private func cells(after shown: Int, through end: Int) -> [(rect: CGRect, panel: ClosedRange<CGFloat>?)] {
        guard let layout = text.layoutManager, let storage = text.textStorage, shown < storage.length else { return [] }
        // From the start of the paragraph being read: the cell it's in.
        let from = (storage.string as NSString).paragraphRange(for: NSRange(location: shown, length: 0)).location
        let origin = text.textContainerOrigin
        var rects: [(rect: CGRect, panel: ClosedRange<CGFloat>?)] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: from, length: max(0, min(end, storage.length) - from))) {
            value, run, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }
            let cell = (storage.string as NSString).paragraphRange(for: run)
            let glyphs = layout.glyphRange(forCharacterRange: cell, actualCharacterRange: nil)
            var rect = layout.boundsRect(for: block, glyphRange: glyphs)
            if cell.location < shown {
                guard NSMaxRange(cell) > shown else { return }
                let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: shown), effectiveRange: nil)
                rect = CGRect(x: rect.minX, y: line.maxY, width: rect.width, height: max(0, rect.maxY - line.maxY))
            }
            rects.append((rect.offsetBy(dx: origin.x, dy: origin.y), nil))
        }
        return rects
    }

    /// Where a code block's panel runs across, when the character is in one (RichLayoutManager.panel).
    private func panel(at character: Int) -> ClosedRange<CGFloat>? {
        guard let storage = text.textStorage, let container = text.textContainer, character < storage.length,
            storage.attribute(.zeroCodeBlock, at: character, effectiveRange: nil) != nil
        else { return nil }
        let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle
        let left = text.textContainerOrigin.x + (style?.headIndent ?? 12) - 12 + container.lineFragmentPadding
        return left...(text.textContainerOrigin.x + container.size.width - container.lineFragmentPadding)
    }

    /// The lines a run of characters covers: from its first letter to the right edge, whole lines between, and its last
    /// line to its last letter, each its line's full height (the first from the view's top: a code block's panel
    /// starts above its text); with the panel each is on, if any.
    private func pieces(_ range: NSRange) -> [(rect: CGRect, panel: ClosedRange<CGFloat>?)] {
        guard range.length > 0, let layout = text.layoutManager, let container = text.textContainer else { return [] }
        var pieces: [(rect: CGRect, panel: ClosedRange<CGFloat>?)] = []
        let origin = text.textContainerOrigin
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let right = max(bounds.width, width)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { line, used, _, lineGlyphs, _ in
            let first = max(glyphs.location, lineGlyphs.location)
            let last = min(NSMaxRange(glyphs), NSMaxRange(lineGlyphs))
            guard last > first else { return }
            // A whole line from its fragment's edges: a table's cells are fragments side by side, and covering from the
            // page's edge hid the cells before it, already read.
            let from = first == lineGlyphs.location ? line.minX : line.minX + layout.location(forGlyphAt: first).x
            let to =
                last == NSMaxRange(lineGlyphs)
                ? (line.maxX >= container.size.width - 1 ? right - origin.x : line.maxX)
                : line.minX + layout.location(forGlyphAt: last).x
            let top = line.minY == 0 ? 0 : line.minY + origin.y
            // Down to its text's foot, not the room after the line: a code block's panel starts in that room, above its
            // first line, and words read on the line before showed a strip of the panel under them.
            let rect = CGRect(x: from + origin.x, y: top, width: max(0, to - from), height: used.maxY + origin.y - top)
            // The panel the line is on, by the line's first character: a run starting at the newline that ends a code
            // block is on the block's last line, and the newline isn't code.
            pieces.append((rect, self.panel(at: layout.characterIndexForGlyph(at: lineGlyphs.location))))
            // An inline code pill starts 2 pt above its line (RichLayoutManager): the strip above its words covered too,
            // or the pill's top edge showed before they were read.
            if let storage = self.text.textStorage {
                let characters = layout.characterRange(forGlyphRange: NSRange(location: first, length: last - first), actualGlyphRange: nil)
                storage.enumerateAttribute(.zeroCode, in: characters) { value, run, _ in
                    guard value != nil else { return }
                    let glyphs = layout.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
                    let a = line.minX + layout.location(forGlyphAt: glyphs.location).x - 5
                    let b =
                        NSMaxRange(glyphs) < NSMaxRange(lineGlyphs)
                        ? line.minX + layout.location(forGlyphAt: NSMaxRange(glyphs)).x : line.maxX
                    pieces.append((CGRect(x: a + origin.x, y: top - 3, width: max(0, b - a), height: 3), nil))
                }
            }
        }
        return pieces
    }

    /// How tall the text is down to the line its `count`th character is on.
    private func height(through count: Int) -> CGFloat {
        guard count > 0, let layout = text.layoutManager, let storage = text.textStorage, storage.length > 0 else { return 0 }
        let glyph = layout.glyphIndexForCharacter(at: min(count, storage.length) - 1)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return ceil(line.maxY + text.textContainerOrigin.y)
    }
}

/// Hosts the covers: flipped, so they're placed from the top as the text's lines are, and never what a click hits.
private final class CoverView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
