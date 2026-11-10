import AppKit
import GhosttyVt

/// A terminal drawn from Ghostty's engine (libghostty-vt), the same one zero-host keeps each program's screen with:
/// the program's output goes in through `feed`, Ghostty's render state says what to draw, and keys, the mouse and
/// pastes go out through Ghostty's own encoders to `input`. The engine's replies to the program are left out: zero-host's
/// terminal already answers them.
final class GhosttyView: NSView {
    /// Bytes for the program: keys, mouse reports, pastes.
    var input: (Data) -> Void = { _ in }
    /// The program is Claude Code, which keeps its own mouse selection and copies it on Ctrl+C (so ⌘C right after a
    /// drag asks it to; without a selection Ctrl+C interrupts it, so only then), and reads an image off the clipboard on
    /// Ctrl+V (so ⌘V with only an image there sends that).
    var claudeCode = false
    /// The grid's size changed to fit the view.
    var resized: (_ columns: Int, _ rows: Int) -> Void = { _, _ in }

    private var terminal: GhosttyTerminal?
    private var state: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var cells: GhosttyRenderStateRowCells?
    private var keys: GhosttyKeyEncoder?
    private var mouse: GhosttyMouseEncoder?
    private var images: GhosttyRenderStateImageIterator?
    /// Images decoded for drawing, by Kitty image id, with the generation of their pixels.
    private var decoded: [UInt32: (generation: UInt64, image: NSImage)] = [:]
    private var placements: UInt64 = 0
    /// What the input method is composing (a dead key's accent, Japanese before it's chosen): drawn at the cursor, sent
    /// once it's settled. While a key is being interpreted, the text it settles on is gathered here.
    private var marked = NSAttributedString()
    private var settled: [String]?
    private var cursorRect = CGRect.zero
    /// Where the cursor was at the last refresh: moving it over unchanged cells (typing a space) dirties no row.
    private var lastCursor: (x: UInt16, y: UInt16, visible: Bool)?

    private let font = TerminalFont.regular
    private lazy var faces: [Face: NSFont] = [
        Face(): font, Face(bold: true): TerminalFont.styled(bold: true, italic: false),
        Face(italic: true): TerminalFont.styled(bold: false, italic: true),
        Face(bold: true, italic: true): TerminalFont.styled(bold: true, italic: true),
    ]
    private lazy var advance = ("M" as NSString).size(withAttributes: [.font: font]).width
    private lazy var cell = CGSize(width: ceil(advance), height: ceil(font.ascender - font.descender + font.leading))
    private let padding: CGFloat = 4
    private(set) var columns = 80
    private(set) var rows = 24
    /// The last mouse action was a drag the program took, so it holds a selection of its own.
    private var programSelected = false
    /// Where a selection drag started, in the viewport's cells.
    private var anchor: (x: UInt16, y: UInt16)?
    private var focused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        ghostty_terminal_new(nil, &terminal, UInt16(columns), UInt16(rows))
        ghostty_render_state_new(nil, &state)
        ghostty_render_state_row_iterator_new(nil, &rowIterator)
        ghostty_render_state_row_cells_new(nil, &cells)
        ghostty_key_encoder_new(nil, &keys)
        ghostty_mouse_encoder_new(nil, &mouse)
        ghostty_render_state_image_iterator_new(nil, &images)
        registerForDraggedTypes([.fileURL])
        clipsToBounds = true
        // Images programs show with the Kitty graphics protocol, up to 64 MB of them.
        var limit: UInt64 = 64 << 20
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit)
        // A program copying (OSC 52, as Claude Code does with what you select in it) puts it on the Mac's clipboard.
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let copied: GhosttyTerminalClipboardWriteFn = { _, _, write in
            guard let write else { return }
            var result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
            if write.pointee.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD {
                let contents = UnsafeBufferPointer(start: write.pointee.contents, count: write.pointee.contents_len)
                let text = contents.first {
                    $0.mime.len == 0
                        || String(decoding: UnsafeBufferPointer(start: $0.mime.ptr, count: $0.mime.len), as: UTF8.self).hasPrefix(
                            "text/plain")
                }
                NSPasteboard.general.clearContents()
                if let text, let bytes = text.data.ptr {
                    NSPasteboard.general.setString(
                        String(decoding: UnsafeBufferPointer(start: bytes, count: text.data.len), as: UTF8.self), forType: .string)
                }
                result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
            }
            var reply = GhosttyClipboardWriteReply(size: MemoryLayout<GhosttyClipboardWriteReply>.size, result: result, remember: false)
            write.pointee.reply(write, &reply)
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(copied, to: UnsafeRawPointer.self))
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        ghostty_render_state_row_cells_free(cells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(state)
        ghostty_key_encoder_free(keys)
        ghostty_mouse_encoder_free(mouse)
        ghostty_render_state_image_iterator_free(images)
        ghostty_terminal_free(terminal)
    }

    func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }
        refresh()
    }

    /// Brings the render state up to date and asks AppKit to redraw only the rows that changed (everything when the
    /// engine says so, or `full`).
    private func refresh(full: Bool = false) {
        guard ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS else { return }
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var generation: UInt64 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION, &generation)
        if full || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || generation != placements {
            placements = generation
            needsDisplay = true
        } else if dirty == GHOSTTY_RENDER_STATE_DIRTY_PARTIAL {
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
            var y: UInt16 = 0
            while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) { redraw(row: y) }
        }
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        let now = cursor.viewport_has_value ? (cursor.viewport_x, cursor.viewport_y, cursor.visible) : nil
        if let was = lastCursor, now.map({ $0 != was }) ?? true { redraw(row: was.y) }
        if let now, lastCursor.map({ $0 != now }) ?? true { redraw(row: now.1) }
        lastCursor = now.map { (x: $0.0, y: $0.1, visible: $0.2) }
        ghostty_render_state_clean(state)
    }

    private func redraw(row y: UInt16) {
        setNeedsDisplay(CGRect(x: 0, y: padding + CGFloat(y) * cell.height, width: bounds.width, height: cell.height))
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { focused = true; refresh(full: true); return true }
    override func resignFirstResponder() -> Bool { focused = false; refresh(full: true); return true }

    // Size: as many cells as fit.

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let fit = (max(2, Int((size.width - padding * 2) / cell.width)), max(2, Int((size.height - padding * 2) / cell.height)))
        guard fit != (columns, rows) else { return }
        (columns, rows) = fit
        ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), UInt32(cell.width), UInt32(cell.height))
        resized(columns, rows)
        refresh(full: true)
    }

    // Colours: the window's own, so the terminal reads as part of the page.

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        refresh(full: true)
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var background = rgb(Theme.cardColor), foreground = rgb(.labelColor)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        }
    }

    // Drawing.

    override func draw(_ dirtyRect: NSRect) {
        // The render state was brought up to date by refresh(); this draws the rows AppKit asks for.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // No thickening, as Ghostty draws by default (its font-thicken is off): macOS would draw the strokes heavier.
        context.setShouldSmoothFonts(false)
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        let background = color(colors.background), foreground = color(colors.foreground)
        context.setFillColor(background.cgColor)
        context.fill(dirtyRect)
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        let selection = NSColor.selectedTextBackgroundColor
        // ponytail: images under the text go under every cell's background too; a pass of backgrounds first if a
        // program puts an image under coloured cells.
        drawImages(above: false)

        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        var y = 0
        while ghostty_render_state_row_iterator_next(rowIterator) {
            let top = padding + CGFloat(y) * cell.height
            guard dirtyRect.intersects(CGRect(x: 0, y: top, width: bounds.width, height: cell.height)) else { y += 1; continue }
            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
            var run = Run()
            var x = 0
            while ghostty_render_state_row_cells_next(cells) {
                defer { x += 1 }
                var raw: GhosttyCell = 0
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                var wide = GHOSTTY_CELL_WIDE_NARROW
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }
                let span = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                var selected = false
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected)
                var fg = foreground, bg: NSColor?
                var value = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &value) == GHOSTTY_SUCCESS {
                    fg = color(value)
                }
                if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &value) == GHOSTTY_SUCCESS {
                    bg = color(value)
                }
                if style.inverse { (fg, bg) = (bg ?? background, fg) }
                if style.faint { fg = fg.withAlphaComponent(0.6) }
                let rect = CGRect(x: padding + CGFloat(x) * cell.width, y: top, width: cell.width * CGFloat(span), height: cell.height)
                if selected {
                    context.setFillColor(selection.cgColor); context.fill(rect)
                } else if let bg {
                    context.setFillColor(bg.cgColor); context.fill(rect)
                }
                let text = style.invisible ? " " : grapheme()
                let isCursor = cursor.visible && cursor.viewport_has_value && Int(cursor.viewport_x) == x && Int(cursor.viewport_y) == y
                // Block elements (▀ ▐ ▛ ░ …) as exact rectangles, as terminals draw them: a font's glyphs leave seams.
                if let parts = text.unicodeScalars.count == 1 ? Self.block(text.unicodeScalars.first!.value) : nil {
                    draw(run, top: top)
                    for (unit, alpha) in parts {
                        let x0 = round(rect.minX + unit.minX * rect.width), x1 = round(rect.minX + unit.maxX * rect.width)
                        let y0 = round(rect.minY + unit.minY * rect.height), y1 = round(rect.minY + unit.maxY * rect.height)
                        context.setFillColor(fg.withAlphaComponent(fg.alphaComponent * alpha).cgColor)
                        context.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                    }
                    if isCursor {
                        cursorRect = rect
                        drawCursor(
                            cursor, rect: rect, text: " ", look: Look(color: fg, face: Face(), underline: false, strike: false),
                            colors: colors, background: background, context: context)
                    }
                    run = Run(start: x + span, look: run.look)
                    continue
                }
                let look = Look(
                    color: fg, face: Face(bold: style.bold, italic: style.italic), underline: style.underline != 0,
                    strike: style.strikethrough)
                // Wide cells and the cursor's cell are drawn on their own; the rest in runs of the same look.
                if span == 2 || isCursor || look != run.look {
                    draw(run, top: top)
                    run = Run(start: x, look: look)
                }
                run.text += text
                if isCursor {
                    cursorRect = rect
                    draw(run, top: top)
                    drawCursor(cursor, rect: rect, text: text, look: look, colors: colors, background: background, context: context)
                    run = Run(start: x + 1, look: look)
                } else if span == 2 {
                    draw(run, top: top)
                    run = Run(start: x + 2, look: look)
                }
            }
            draw(run, top: top)
            y += 1
        }
        drawImages(above: true)
        if marked.length > 0 { drawMarked(background: background) }
    }

    /// The images placed on screen in one layer group: under the text, or over it.
    private func drawImages(above: Bool) {
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &images)
        var graphics: GhosttyKittyGraphics?
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics)
        while ghostty_render_state_image_iterator_next(images) {
            var kind = GhosttyImageProtocol(0), layer = GhosttyRenderStateImageLayer(0)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL, &kind)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER, &layer)
            guard kind == GHOSTTY_IMAGE_PROTOCOL_KITTY, (layer == GHOSTTY_RENDER_STATE_IMAGE_LAYER_ABOVE_TEXT) == above else { continue }
            var id: UInt32 = 0, generation: UInt64 = 0, column: Int32 = 0, row: Int32 = 0
            var dx: UInt32 = 0, dy: UInt32 = 0, width: UInt32 = 0, height: UInt32 = 0, sx: UInt32 = 0, sy: UInt32 = 0, sw: UInt32 = 0,
                sh: UInt32 = 0
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID, &id)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION, &generation)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL, &column)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW, &row)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X, &dx)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y, &dy)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH, &width)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT, &height)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X, &sx)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y, &sy)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH, &sw)
            ghostty_render_state_image_get(images, GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT, &sh)
            guard let picture = image(id, generation: generation, in: graphics) else { continue }
            // The engine counts a cell as cell.width × cell.height pixels, which are points here.
            let rect = CGRect(
                x: padding + CGFloat(column) * cell.width + CGFloat(dx), y: padding + CGFloat(row) * cell.height + CGFloat(dy),
                width: CGFloat(width), height: CGFloat(height))
            picture.draw(
                in: rect, from: CGRect(x: CGFloat(sx), y: picture.size.height - CGFloat(sy + sh), width: CGFloat(sw), height: CGFloat(sh)),
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The image's pixels as an NSImage, decoded once per generation.
    private func image(_ id: UInt32, generation: UInt64, in graphics: GhosttyKittyGraphics?) -> NSImage? {
        if let cached = decoded[id], cached.generation == generation { return cached.image }
        guard let graphics, let source = ghostty_kitty_graphics_image(graphics, id) else { return nil }
        var width: UInt32 = 0, height: UInt32 = 0, format = GhosttyKittyImageFormat(0), length = 0
        var pointer: UnsafePointer<UInt8>?
        ghostty_kitty_graphics_image_get(source, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
        ghostty_kitty_graphics_image_get(source, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
        ghostty_kitty_graphics_image_get(source, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        ghostty_kitty_graphics_image_get(source, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &pointer)
        ghostty_kitty_graphics_image_get(source, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length)
        guard let pointer, length > 0, width > 0, height > 0 else { return nil }
        let data = Data(bytes: pointer, count: length)
        let picture: NSImage?
        if format == GHOSTTY_KITTY_IMAGE_FORMAT_PNG {
            picture = NSImage(data: data)
        } else {
            let (channels, info, space): (Int, CGImageAlphaInfo, CGColorSpace) =
                switch format {
                case GHOSTTY_KITTY_IMAGE_FORMAT_RGB: (3, .none, CGColorSpaceCreateDeviceRGB())
                case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY: (1, .none, CGColorSpaceCreateDeviceGray())
                case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA: (2, .last, CGColorSpaceCreateDeviceGray())
                default: (4, .last, CGColorSpaceCreateDeviceRGB())
                }
            picture = CGDataProvider(data: data as CFData).flatMap {
                CGImage(
                    width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                    bytesPerRow: Int(width) * channels,
                    space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: $0, decode: nil, shouldInterpolate: true,
                    intent: .defaultIntent)
            }.map { NSImage(cgImage: $0, size: NSSize(width: Int(width), height: Int(height))) }
        }
        decoded[id] = picture.map { (generation, $0) }
        return picture
    }

    /// What the input method is composing, at the cursor, underlined, over what's there.
    private func drawMarked(background: NSColor) {
        let text = marked.string as NSString
        let width = CGFloat(max(1, text.length)) * cell.width
        let rect = CGRect(x: cursorRect.minX, y: cursorRect.minY, width: width, height: cell.height)
        background.setFill()
        rect.fill()
        text.draw(
            at: CGPoint(x: rect.minX, y: rect.minY + 1),
            withAttributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue, .kern: cell.width - advance,
            ])
    }

    /// The current cell's characters, a space if it's empty.
    private func grapheme() -> String {
        var length: UInt32 = 0
        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
        guard length > 0 else { return " " }
        var points = [UInt32](repeating: 0, count: Int(length))
        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &points)
        var text = ""
        for point in points { if let scalar = Unicode.Scalar(point) { text.unicodeScalars.append(scalar) } }
        return text
    }

    private func draw(_ run: Run, top: CGFloat) {
        guard !run.text.isEmpty, run.text.contains(where: { $0 != " " }) || run.look.underline || run.look.strike else { return }
        // Each character spaced to exactly one cell, so a run ends where the grid says it does.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: faces[run.look.face] ?? font, .foregroundColor: run.look.color, .kern: cell.width - advance,
        ]
        if run.look.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.look.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        (run.text as NSString).draw(at: CGPoint(x: padding + CGFloat(run.start) * cell.width, y: top + 1), withAttributes: attributes)
    }

    private func drawCursor(
        _ cursor: GhosttyRenderStateCursor, rect: CGRect, text: String, look: Look, colors: GhosttyRenderStateColors,
        background: NSColor, context: CGContext
    ) {
        let tint = colors.cursor_has_value ? color(colors.cursor) : look.color
        context.setFillColor(tint.cgColor)
        context.setStrokeColor(tint.cgColor)
        switch cursor.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: context.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        default:
            guard focused && cursor.visual_style != GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW else {
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5), width: 1)
                return
            }
            context.fill(rect)
            var inverted = look
            inverted.color = background
            draw(Run(start: Int((rect.minX - padding) / cell.width), look: inverted, text: text), top: rect.minY)
        }
    }

    // Keys: Ghostty's encoder, set to the modes the program asked for (cursor keys, Kitty keyboard, …).

    /// A key goes to the input method first (macOS's text input): text it settles on is sent as the key's text, a key
    /// it keeps while composing sends nothing, and anything else (Return, arrows, Ctrl+C) goes through the encoder as is.
    override func keyDown(with event: NSEvent) {
        let action = event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS
        let composing = marked.length > 0
        settled = []
        defer { settled = nil }
        interpretKeyEvents([event])
        if let texts = settled, !texts.isEmpty {
            programSelected = false
            for text in texts {
                // Composed (a dead key's é, ⌥P's π, an input method's choice): the text itself, which the encoder's key
                // protocols would otherwise turn back into the key it came from.
                if composing || text != (event.charactersIgnoringModifiers ?? "") {
                    scrollToBottom()
                    input(Data(text.utf8))
                    continue
                }
                press(
                    ghosttyKeys[event.keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED, mods: Self.mods(event.modifierFlags), action: action,
                    text: text,
                    unshifted: event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first)
            }
        } else if !composing && marked.length == 0 {
            send(event, action: action)
        }
    }
    override func keyUp(with event: NSEvent) { send(event, action: GHOSTTY_KEY_ACTION_RELEASE) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "c": copy(nil); return true
        case "v": paste(nil); return true
        case "a": selectAll(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func send(_ event: NSEvent, action: GhosttyKeyAction) {
        if action != GHOSTTY_KEY_ACTION_RELEASE { programSelected = false }
        let text = action == GHOSTTY_KEY_ACTION_RELEASE ? "" : (event.characters ?? "")
        press(
            ghosttyKeys[event.keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED, mods: Self.mods(event.modifierFlags), action: action, text: text,
            unshifted: event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first)
    }

    /// One key through Ghostty's encoder, in the modes the program asked for, to the program.
    private func press(_ physical: GhosttyKey, mods: GhosttyMods, action: GhosttyKeyAction, text: String, unshifted: Unicode.Scalar?) {
        var key: GhosttyKeyEvent?
        ghostty_key_event_new(nil, &key)
        defer { ghostty_key_event_free(key) }
        ghostty_key_event_set_action(key, action)
        ghostty_key_event_set_key(key, physical)
        ghostty_key_event_set_mods(key, mods)
        // Text a key makes on its own (not a control character): shift and option made it, so they're spent on it.
        if let first = text.unicodeScalars.first, first.value >= 0x20, !(0xF700...0xF8FF).contains(first.value) {
            ghostty_key_event_set_consumed_mods(key, mods & GhosttyMods(GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_ALT))
            text.utf8CString.withUnsafeBufferPointer { ghostty_key_event_set_utf8(key, $0.baseAddress, $0.count - 1) }
        }
        if let unshifted { ghostty_key_event_set_unshifted_codepoint(key, unshifted.value) }
        ghostty_key_encoder_setopt_from_terminal(keys, terminal)
        var buffer = [CChar](repeating: 0, count: 128)
        var written = 0
        guard ghostty_key_encoder_encode(keys, key, &buffer, buffer.count, &written) == GHOSTTY_SUCCESS, written > 0 else { return }
        if action != GHOSTTY_KEY_ACTION_RELEASE { scrollToBottom() }
        input(Data(buffer[0..<written].map { UInt8(bitPattern: $0) }))
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: Int32 = 0
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS_LOCK }
        return GhosttyMods(mods)
    }

    // Copy and paste.

    /// What was selected, as text, when it was selected: a program redrawing its screen (as Claude Code does all the
    /// time) takes the engine's selection away before you get to copy it.
    private var selectedText: String?

    /// Zero's own selection (Shift+drag) if there is one; else, right after you selected in a program that copies on
    /// Ctrl+C, it's asked to copy (it puts the text on the clipboard itself, through OSC 52 or on its own).
    @objc func copy(_ sender: Any?) {
        if let text = selectionText() ?? selectedText, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else if claudeCode && programSelected {
            for action in [GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_ACTION_RELEASE] {
                press(GHOSTTY_KEY_C, mods: GhosttyMods(GHOSTTY_MODS_CTRL), action: action, text: "", unshifted: "c")
            }
        }
    }

    private func selectionText(_ selection: UnsafePointer<GhosttySelection>? = nil) -> String? {
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true
        options.unwrap = true
        options.selection = selection
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let result = ghostty_terminal_selection_format_alloc(terminal, nil, options, &pointer, &length)
        guard result == GHOSTTY_SUCCESS, let pointer else { return nil }
        defer { ghostty_free(nil, pointer, length) }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    /// Makes `selection` the engine's, and keeps its text; nil clears it.
    private func select(_ selection: GhosttySelection?) {
        if var selection {
            selectedText = selectionText(&selection)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        } else {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            selectedText = nil
        }
        refresh(full: true)
    }

    /// Files as their paths (an image's path is how Claude Code takes an image by drag and drop), then text, then, for
    /// Claude Code, an image alone on the clipboard: Ctrl+V, on which it reads it from there.
    @objc func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            pasteText(files.map { Self.escaped($0.path) }.joined(separator: " "))
        } else if let text = board.string(forType: .string), !text.isEmpty {
            pasteText(text)
        } else if claudeCode, board.availableType(from: [.png, .tiff]) != nil {
            for action in [GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_ACTION_RELEASE] {
                press(GHOSTTY_KEY_V, mods: GhosttyMods(GHOSTTY_MODS_CTRL), action: action, text: "", unshifted: "v")
            }
        }
    }

    /// A path as a shell reads it back, its specials escaped as terminals paste them.
    static func escaped(_ path: String) -> String {
        path.map { " \\()[]{}'\"&;$!*?<>|#~`".contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    private func pasteText(_ text: String) {
        var data = Array(text.utf8CString.dropLast())
        var buffer = [CChar](repeating: 0, count: data.count + 64)
        var written = 0
        guard ghostty_paste_encode(&data, data.count, mode(2004), &buffer, buffer.count, &written) == GHOSTTY_SUCCESS else { return }
        scrollToBottom()
        input(Data(buffer[0..<written].map { UInt8(bitPattern: $0) }))
    }

    // Files dropped on the terminal paste their paths.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !files.isEmpty
        else { return false }
        window?.makeFirstResponder(self)
        pasteText(files.map { Self.escaped($0.path) }.joined(separator: " "))
        return true
    }

    override func selectAll(_ sender: Any?) {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        if ghostty_terminal_select_all(terminal, &selection) == GHOSTTY_SUCCESS { select(selection) }
    }

    // The mouse: reported to the program when it asked for it, otherwise it selects; the wheel scrolls back.

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        programSelected = false
        if report(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT) { return }
        let at = place(event)
        anchor = at
        if event.clickCount == 2, let ref = ref(at) {
            var options = GhosttyTerminalSelectWordOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
            options.ref = ref
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            if ghostty_terminal_select_word(terminal, &options, &selection) == GHOSTTY_SUCCESS { select(selection) }
            anchor = nil
        } else {
            select(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if report(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_LEFT) { programSelected = true; return }
        guard let anchor, let start = ref(anchor), let end = ref(place(event)) else { return }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = start
        selection.end = end
        select(selection)
    }

    override func mouseUp(with event: NSEvent) {
        _ = report(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_LEFT)
        anchor = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cell.height : event.scrollingDeltaY
        guard abs(lines) >= 0.5 else { return }
        if tracking {
            let button = lines > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
            for _ in 0..<min(Int(abs(lines).rounded()), 5) { _ = report(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: button) }
            return
        }
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        scroll.value.delta = -Int(lines.rounded())
        ghostty_terminal_scroll_viewport(terminal, scroll)
        refresh(full: true)
    }

    /// True when the program wants mouse reports.
    private var tracking: Bool {
        var on = false
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &on) == GHOSTTY_SUCCESS && on
    }

    /// Reports the event to the program if it asked for mouse reports (shift held keeps the mouse for selecting).
    private func report(_ event: NSEvent, action: GhosttyMouseAction, button: GhosttyMouseButton) -> Bool {
        guard tracking, !event.modifierFlags.contains(.shift) else { return false }
        ghostty_mouse_encoder_setopt_from_terminal(mouse, terminal)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(bounds.width)
        size.screen_height = UInt32(bounds.height)
        size.cell_width = UInt32(cell.width)
        size.cell_height = UInt32(cell.height)
        size.padding_left = UInt32(padding)
        size.padding_top = UInt32(padding)
        ghostty_mouse_encoder_setopt(mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var mouseEvent: GhosttyMouseEvent?
        ghostty_mouse_event_new(nil, &mouseEvent)
        defer { ghostty_mouse_event_free(mouseEvent) }
        ghostty_mouse_event_set_action(mouseEvent, action)
        ghostty_mouse_event_set_button(mouseEvent, button)
        ghostty_mouse_event_set_mods(mouseEvent, Self.mods(event.modifierFlags))
        let point = convert(event.locationInWindow, from: nil)
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(point.x), y: Float(point.y)))
        var buffer = [CChar](repeating: 0, count: 64)
        var written = 0
        if ghostty_mouse_encoder_encode(mouse, mouseEvent, &buffer, buffer.count, &written) == GHOSTTY_SUCCESS, written > 0 {
            input(Data(buffer[0..<written].map { UInt8(bitPattern: $0) }))
        }
        return true
    }

    /// The viewport cell under the event.
    private func place(_ event: NSEvent) -> (x: UInt16, y: UInt16) {
        let point = convert(event.locationInWindow, from: nil)
        let x = min(max(0, Int((point.x - padding) / cell.width)), columns - 1)
        let y = min(max(0, Int((point.y - padding) / cell.height)), rows - 1)
        return (UInt16(x), UInt16(y))
    }

    private func ref(_ at: (x: UInt16, y: UInt16)) -> GhosttyGridRef? {
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: at.x, y: UInt32(at.y))
        return ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private func scrollToBottom() {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, scroll)
        refresh()
    }

    private func mode(_ number: UInt16) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, false), value: false)
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS && config.value
    }

    /// The parts of a cell a block element fills (in fractions of the cell) and how opaque they are; nil for others.
    static func block(_ point: UInt32) -> [(CGRect, CGFloat)]? {
        let ul = CGRect(x: 0, y: 0, width: 0.5, height: 0.5), ur = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let ll = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), lr = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let solid: (CGRect) -> (CGRect, CGFloat) = { ($0, 1) }
        switch point {
        case 0x2580: return [solid(CGRect(x: 0, y: 0, width: 1, height: 0.5))]
        case 0x2581...0x2588: let h = CGFloat(point - 0x2580) / 8; return [solid(CGRect(x: 0, y: 1 - h, width: 1, height: h))]
        case 0x2589...0x258F: let w = CGFloat(0x2590 - point) / 8; return [solid(CGRect(x: 0, y: 0, width: w, height: 1))]
        case 0x2590: return [solid(CGRect(x: 0.5, y: 0, width: 0.5, height: 1))]
        case 0x2591...0x2593: return [(CGRect(x: 0, y: 0, width: 1, height: 1), CGFloat(point - 0x2590) / 4)]
        case 0x2594: return [solid(CGRect(x: 0, y: 0, width: 1, height: 0.125))]
        case 0x2595: return [solid(CGRect(x: 0.875, y: 0, width: 0.125, height: 1))]
        case 0x2596: return [solid(ll)]
        case 0x2597: return [solid(lr)]
        case 0x2598: return [solid(ul)]
        case 0x2599: return [ul, ll, lr].map(solid)
        case 0x259A: return [ul, lr].map(solid)
        case 0x259B: return [ul, ur, ll].map(solid)
        case 0x259C: return [ul, ur, lr].map(solid)
        case 0x259D: return [solid(ur)]
        case 0x259E: return [ur, ll].map(solid)
        case 0x259F: return [ur, ll, lr].map(solid)
        default: return nil
        }
    }

    private struct Face: Hashable { var bold = false; var italic = false }
    private struct Look: Equatable { var color: NSColor; var face: Face; var underline: Bool; var strike: Bool }
    private struct Run {
        var start = 0
        var look = Look(color: .labelColor, face: Face(), underline: false, strike: false)
        var text = ""
    }

    private func color(_ rgb: GhosttyColorRgb) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
    private func rgb(_ color: NSColor) -> GhosttyColorRgb {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return GhosttyColorRgb(r: UInt8(c.redComponent * 255), g: UInt8(c.greenComponent * 255), b: UInt8(c.blueComponent * 255))
    }
}

/// macOS's text input: the input method composes into `marked`, then settles on text.
extension GhosttyView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        // Typed: the key sends it. Otherwise (the emoji picker, dictation) it goes to the program as it is.
        if settled != nil { settled?.append(text) } else if !text.isEmpty { input(Data(text.utf8)) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        setNeedsDisplay(
            cursorRect.insetBy(dx: -1, dy: 0).union(
                CGRect(x: cursorRect.minX, y: cursorRect.minY, width: bounds.width, height: cell.height)))
    }

    func unmarkText() {
        guard marked.length > 0 else { return }
        marked = NSAttributedString()
        refresh(full: true)
    }

    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange {
        marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the input method shows its candidates: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect, to: nil))
    }

    /// Commands the input method maps keys to (moveLeft:, insertNewline:) are the encoder's to send; nothing here, no beep.
    override func doCommand(by selector: Selector) {}
}

/// The terminal font: your Ghostty config's font-family and font-size when you have one (so terminals look as they do
/// in Ghostty), else the system's monospaced font.
enum TerminalFont {
    static let regular = styled(bold: false, italic: false)

    static func styled(bold: Bool, italic: Bool) -> NSFont {
        let traits: NSFontTraitMask = [bold ? .boldFontMask : [], italic ? .italicFontMask : []]
        if let family = config.family,
            let font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: config.size)
        {
            return font
        }
        let system = NSFont.monospacedSystemFont(ofSize: config.size, weight: bold ? .bold : .regular)
        return italic ? NSFontManager.shared.convert(system, toHaveTrait: .italicFontMask) : system
    }

    /// The last font-family and font-size in Ghostty's config files, in the order Ghostty reads them.
    static let config: (family: String?, size: CGFloat) = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var family: String?, size: CGFloat = 13
        for file in [
            ".config/ghostty/config", ".config/ghostty/config.ghostty", "Library/Application Support/com.mitchellh.ghostty/config",
            "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ] {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if parts[0] == "font-family", !value.isEmpty { family = value }
                if parts[0] == "font-size", let number = Double(value) { size = CGFloat(number) }
            }
        }
        return (family, size)
    }()
}
