import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Images sent with a message, as Codex has them: pasted (⌘V), dropped on the composer or picked with its +, shown as
// tiles above what you're writing, sent with it, and shown with your message after. Each is kept as a file of Zero's
// (~/.zero/attachments), since a pasted screenshot's own file is often a temporary one.

enum Attachments {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zero/attachments")

    /// An image kept as Zero's own PNG.
    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return write(png, extension: "png")
    }

    /// An image file copied in, its type kept.
    static func copy(_ file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return write(data, extension: file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased())
    }

    private static func write(_ data: Data, extension ext: String) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension(ext)
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static func isImage(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }

    /// What a paste would attach: image files copied in Finder, else an image on the clipboard with no words beside it.
    /// Nil leaves the paste to the text field.
    static func fromPasteboard(_ board: NSPasteboard = .general) -> [URL]? {
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty,
           files.allSatisfy(isImage) {
            return files.compactMap(copy)
        }
        if board.string(forType: .string) == nil, let image = NSImage(pasteboard: board) { return save(image).map { [$0] } }
        return nil
    }

    /// The images a drop brings: files, or image data.
    static func fromDrop(_ providers: [NSItemProvider], added: @escaping @MainActor ([URL]) -> Void) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL, isImage(url), let copied = copy(url) else { return }
                    Task { @MainActor in added([copied]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage, let saved = save(image) else { return }
                    Task { @MainActor in added([saved]) }
                }
            }
        }
    }

    /// Images picked in an open panel.
    @MainActor static func pick() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls.compactMap(copy) : []
    }
}

/// An image as a square tile, cropped to fill; a click opens it in Zero (`tap` does something else instead); a right
/// click offers Preview and its folder. With `remove`, an × shows on hover.
struct Thumbnail: View {
    private static let decoded: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 200; return cache }()

    /// The image decoded once, small: about twice the tile's size for a Retina screen, not the whole screenshot on
    /// every redraw.
    static func image(_ path: String, side: CGFloat) -> NSImage? {
        let key = "\(side)|\(path)" as NSString
        if let kept = decoded.object(forKey: key) { return kept }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: side * 2 * 2, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let small = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        decoded.setObject(small, forKey: key)
        return small
    }

    let path: String
    var side: CGFloat = 72
    /// The images it's one of (a message's), to move between once opened.
    var among: [String] = []
    /// What a click does instead of opening the image.
    var tap: (() -> Void)?
    var remove: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        Button { if let tap { tap() } else { ImageViewer.shared.show(path, among: among) } } label: {
            Group {
                if let image = Thumbnail.image(path, side: side) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    NucleoIcon("file", size: 18).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.chip)
                }
            }
            .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu { ImageActions(path: path) }
        .overlay(alignment: .topTrailing) {
            if let remove, hovered {
                Button(action: remove) {
                    NucleoIcon("xmark", size: 9).foregroundStyle(Theme.onKnob).frame(width: 18, height: 18).background(Theme.knob, in: Circle())
                }
                .buttonStyle(.plain).padding(5).tip("Remove")
            }
        }
        .onHover { hovered = $0 }
        .tip((path as NSString).lastPathComponent)
    }
}

/// "[Image #n]" in a message: what attaching an image leaves in the words at the caret, so the agent knows which image
/// a sentence is about (the token goes to it as written; zerod puts the image right after it). Drawn as a pill, "🖼️
/// Image n", in the composer and in the sent message; a click opens the image.
enum ImageToken {
    private static let pattern = try! NSRegularExpression(pattern: "\\[Image #(\\d+)\\]")
    private static let label = try! NSRegularExpression(pattern: "^Image #(\\d+)$")

    static func text(_ number: Int) -> String { "[Image #\(number)]" }

    /// Each token in the text, with its number.
    static func find(in text: String) -> [(range: NSRange, number: Int)] {
        let whole = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: whole.length)).map { ($0.range, Int(whole.substring(with: $0.range(at: 1))) ?? 0) }
    }

    /// The number a link's words name ("Image #2"), if they do.
    static func number(inLabel label: String) -> Int? {
        guard let match = Self.label.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length)) else { return nil }
        return Int((label as NSString).substring(with: match.range(at: 1)))
    }

    /// The text and images as sent: the images whose token is in the words, numbered 1… in their order, the rest left
    /// out (an attached image whose pill was deleted; its tokens stay deletable and undoable until then).
    static func compact(_ text: String, images: [String]) -> (text: String, images: [String]) {
        let kept = Set(find(in: text).map(\.number)).filter { images.indices.contains($0 - 1) }.sorted()
        let renumbered = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset + 1) })
        let out = NSMutableString(string: text)
        for token in find(in: text).reversed() {
            if let number = renumbered[token.number] { out.replaceCharacters(in: token.range, with: Self.text(number)) }
        }
        return (out as String, kept.map { images[$0 - 1] })
    }

    /// The text with each token a Markdown link to its image, for a sent message: the renderer draws the pill.
    static func linked(_ text: String, images: [String]) -> String {
        let out = NSMutableString(string: text)
        for token in find(in: text).reversed() where images.indices.contains(token.number - 1) {
            out.replaceCharacters(in: token.range, with: "[Image #\(token.number)](\(URL(fileURLWithPath: images[token.number - 1]).absoluteString))")
        }
        return out as String
    }

    /// The pill, as one character of the text, on the line's baseline like a word.
    static func attachment(_ number: Int, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = Cell(number: number, font: font)
        let token = NSMutableAttributedString(attachment: attachment)
        token.addAttributes([.font: font, .cursor: NSCursor.pointingHand], range: NSRange(location: 0, length: 1))
        return token
    }

    /// The pill under the pointer, and where it is in the text: for a click on it.
    static func hit(_ event: NSEvent, in view: NSTextView) -> (cell: Cell, index: Int)? {
        guard let manager = view.layoutManager, let container = view.textContainer, let storage = view.textStorage else { return nil }
        let point = view.convert(event.locationInWindow, from: nil)
        let inText = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: inText, in: container)
        guard glyph < manager.numberOfGlyphs, manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(inText) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard let cell = (storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? Cell else { return nil }
        return (cell, index)
    }

    final class Cell: NSTextAttachmentCell {
        let number: Int
        let textFont: NSFont
        private static let inset: CGFloat = 4

        init(number: Int, font: NSFont) {
            self.number = number
            self.textFont = font
            super.init(textCell: "")
        }
        required init(coder: NSCoder) { fatalError("not kept") }

        /// The text's size, a step heavier than the words around it.
        private var words: NSAttributedString {
            NSAttributedString(string: "\u{1F5BC}\u{FE0F} Image \(number)",
                               attributes: [.font: NSFont.systemFont(ofSize: textFont.pointSize, weight: .medium), .foregroundColor: TokenTextView.tokenText])
        }

        override func cellSize() -> NSSize {
            NSSize(width: Self.inset * 2 + ceil(words.size().width) + 1, height: ceil(textFont.ascender - textFont.descender) + 1)
        }

        /// Its bottom half a point under the line's descent, as the composer's pills sit.
        override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: textFont.descender - 0.5) }

        /// The text view opens the image itself (a click is a click, not a drag of the cell).
        override func wantsToTrackMouse() -> Bool { false }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
            TokenTextView.tokenFill.setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: 4, yRadius: 4).fill()
            let words = self.words
            words.draw(at: NSPoint(x: cellFrame.minX + Self.inset, y: cellFrame.midY - words.size().height / 2))
        }
    }
}

/// An image opened in Zero: over the whole window, title bar and toolbar included (it's added above the window's own
/// frame, where a view in the page couldn't reach), as large as fits, until a click outside it or Esc.
@MainActor final class ImageViewer {
    static let shared = ImageViewer()
    private var host: NSView?

    /// `among`: the images this one is one of (a message's); ← → and a trackpad swipe move between them.
    func show(_ path: String, among: [String] = []) {
        close()
        guard let window = NSApp.keyWindow, let frame = window.contentView?.superview else { return }
        let paths = among.contains(path) ? among : [path]
        let view = NSHostingView(rootView: ImageLightbox(paths: paths, index: paths.firstIndex(of: path) ?? 0))
        view.frame = frame.bounds
        view.autoresizingMask = [.width, .height]
        frame.addSubview(view, positioned: .above, relativeTo: nil)
        host = view
    }

    func close() {
        host?.removeFromSuperview()
        host = nil
    }
}

/// Where an image's file can go from Zero: Preview, or its folder.
struct ImageActions: View {
    let path: String
    var body: some View {
        Button("Open with Preview") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
}

struct ImageLightbox: View {
    let paths: [String]
    @State var index: Int
    @State private var monitor: Any?
    /// One step per swipe: how far the trackpad has gone this gesture, and whether it has stepped already.
    @State private var swiped: CGFloat = 0
    @State private var stepped = false

    private var path: String { paths[index] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).contentShape(Rectangle()).onTapGesture { ImageViewer.shared.close() }
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    .padding(48)
                    .contextMenu { ImageActions(path: path) }
                    .id(path)
            }
            if paths.count > 1 {
                Text("\(index + 1) of \(paths.count)").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.45), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 18)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .swipe]) { event in
                switch event.type {
                case .keyDown:
                    switch event.keyCode {
                    case 53: ImageViewer.shared.close(); return nil
                    case 123, 126: step(-1); return nil // ← ↑
                    case 124, 125: step(1); return nil // → ↓
                    default: return event
                    }
                case .swipe:
                    if event.deltaX != 0 { step(event.deltaX > 0 ? -1 : 1) }
                    return nil
                case .scrollWheel:
                    // A trackpad swipe: one step per gesture, once it has gone far enough either way.
                    if event.phase == .began { swiped = 0; stepped = false }
                    if event.momentumPhase == [] && !stepped {
                        swiped += event.scrollingDeltaX
                        if abs(swiped) > 40 { stepped = true; step(swiped > 0 ? -1 : 1) }
                    }
                    return nil
                default: return event
                }
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    private func step(_ by: Int) {
        guard paths.count > 1 else { return }
        index = (index + by + paths.count) % paths.count
    }
}
