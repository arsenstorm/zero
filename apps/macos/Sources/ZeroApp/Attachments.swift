import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZeroCore

// Images sent with a message, as Codex has them: pasted (⌘V), dropped on the composer or picked with its +, shown as
// tiles above what you're writing, sent with it, and shown with your message after. Each is kept as a file of Zero's
// (~/.zero/attachments), since a pasted screenshot's own file is often a temporary one.

enum Attachments {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zero/attachments")

    /// An image kept as Zero's own PNG.
    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return write(png, extension: "png")
    }

    /// An image or video file copied in, its type kept: Zero's own, so a message's attachment is there to open (and for
    /// its agent to read) after the original is moved or deleted. A copy-on-write clone on APFS: instant, whatever
    /// the size, and no room taken until either changes.
    static func copy(_ file: URL) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension(
            file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased())
        return (try? FileManager.default.copyItem(at: file, to: kept)) != nil ? kept : nil
    }

    private static func write(_ data: Data, extension ext: String) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension(ext)
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static func isImage(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    static func isVideo(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true }

    /// A video attached, as an agent will get it: a few stills through it, cut as it's attached (so sending waits on
    /// nothing), with its length and size. By the video's path.
    struct Video { let images: [String]; let times: [Double]; let info: VideoFrames.Info }
    /// Observed: a video's tile shows its first still once it's cut.
    @MainActor @Observable final class Cut { static let shared = Cut(); var videos: [String: Video] = [:] }
    @MainActor static var videos: [String: Video] {
        get { Cut.shared.videos }
        set { Cut.shared.videos = newValue }
    }

    @MainActor static func prepare(_ video: URL, most: Int = 6) {
        guard videos[video.path] == nil else { return }
        Task { @MainActor in
            guard let info = try? await VideoFrames.info(of: video), info.seconds > 0 else { return }
            let times = VideoFrames.spread(min(most, max(1, Int(info.seconds.rounded(.up)))), over: info.seconds)
            let frames =
                (try? await VideoFrames.frames(of: video, at: times, into: folder.appendingPathComponent(UUID().uuidString.lowercased())))
                ?? []
            videos[video.path] = Video(images: frames.map(\.path), times: frames.map(\.at), info: info)
        }
    }

    /// Its first still, for its tile.
    @MainActor static func poster(_ video: URL) -> String? { videos[video.path]?.images.first }

    /// What a paste would attach: image files copied in Finder, else an image on the clipboard with no words beside it.
    /// Nil leaves the paste to the text field.
    static func fromPasteboard(_ board: NSPasteboard = .general) -> [URL]? {
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty,
            files.allSatisfy({ isImage($0) || isVideo($0) })
        {
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
                    guard let url, url.isFileURL else { return }
                    guard isImage(url) || isVideo(url), let copied = copy(url) else { return }
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
    private static let decoded: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 200; return cache
    }()

    /// The image decoded once, small: about twice the tile's size for a Retina screen, not the whole screenshot on
    /// every redraw.
    static func image(_ path: String, side: CGFloat) -> NSImage? {
        let key = "\(side)|\(path)" as NSString
        if let kept = decoded.object(forKey: key) { return kept }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: side * 2 * 2, kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { return nil }
        let small = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        decoded.setObject(small, forKey: key)
        return small
    }

    /// Its size fitted: `height` tall and up to 1.6 times as wide, kept to its proportions, no larger than its pixels
    /// at 2x (the decoded copy's are its own up to four times the box).
    static func fitted(_ pixels: CGSize?, height: CGFloat) -> CGSize {
        guard let pixels, pixels.width > 0, pixels.height > 0 else { return CGSize(width: height, height: height) }
        let scale = min(height * 1.6 / pixels.width, height / pixels.height, 0.5)
        return CGSize(width: round(pixels.width * scale), height: round(pixels.height * scale))
    }

    let path: String
    var side: CGFloat = 72
    /// To its own proportions, `side` tall and up to 1.6 times as wide at most (never larger than it is), rather than
    /// a square crop: a message's image, read in place.
    var fit = false
    /// The images it's one of (a message's), to move between once opened.
    var among: [String] = []
    /// What a click does instead of opening the image.
    var tap: (() -> Void)?
    var remove: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        let image = Thumbnail.image(path, side: fit ? side * 1.6 : side)
        let size = fit ? Self.fitted(image?.size, height: side) : CGSize(width: side, height: side)
        Button {
            if let tap { tap() } else { ImageViewer.shared.show(path, among: among) }
        } label: {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    NucleoIcon("file", size: 18).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity).background(
                        Theme.chip)
                }
            }
            .frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .zeroContextMenu("image-\(path)") { imageActions(path) }
        .overlay(alignment: .topTrailing) {
            if let remove, hovered {
                Button(action: remove) {
                    NucleoIcon("xmark", size: 9).foregroundStyle(Theme.onKnob).frame(width: 18, height: 18).background(
                        Theme.knob, in: Circle())
                }
                .buttonStyle(.plain).padding(5).tip("Remove")
            }
        }
        .onHover { hovered = $0 }
        .tip((path as NSString).lastPathComponent)
    }
}

/// "[Image #n]" in a message: what attaching an image leaves in the words at the caret, so the agent knows which image
/// a sentence is about (the token goes to it as written; zerod puts the image right after it). Drawn as a pill, Nucleo's
/// image and "Image n", in the composer and in the sent message; a click opens the image.
enum ImageToken {
    private static let pattern = try! NSRegularExpression(pattern: "\\[(Image|Video) #(\\d+)\\]")
    private static let label = try! NSRegularExpression(pattern: "^(Image|Video) #(\\d+)$")

    static func text(_ number: Int, video: Bool = false) -> String { "[\(video ? "Video" : "Image") #\(number)]" }

    /// Each token in the text, with its number.
    static func find(in text: String) -> [(range: NSRange, number: Int, video: Bool)] {
        let whole = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: whole.length))
            .map { ($0.range, Int(whole.substring(with: $0.range(at: 2))) ?? 0, whole.substring(with: $0.range(at: 1)) == "Video") }
    }

    /// The number a link's words name ("Image #2"), if they do.
    static func number(inLabel label: String) -> (number: Int, video: Bool)? {
        guard let match = Self.label.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length)),
            let number = Int((label as NSString).substring(with: match.range(at: 2)))
        else { return nil }
        return (number, (label as NSString).substring(with: match.range(at: 1)) == "Video")
    }

    /// The text and images as sent: the images whose token is in the words, numbered 1… in their order, the rest left
    /// out (an attached image whose pill was deleted; its tokens stay deletable and undoable until then).
    static func compact(_ text: String, images: [String]) -> (text: String, images: [String]) {
        let kept = Set(find(in: text).map(\.number)).filter { images.indices.contains($0 - 1) }.sorted()
        let renumbered = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset + 1) })
        let out = NSMutableString(string: text)
        for token in find(in: text).reversed() {
            if let number = renumbered[token.number] { out.replaceCharacters(in: token.range, with: Self.text(number, video: token.video)) }
        }
        return (out as String, kept.map { images[$0 - 1] })
    }

    /// What's sent: compacted, then its videos as an agent can take them.
    @MainActor static func outgoing(_ text: String, images: [String]) -> (text: String, images: [String]) {
        let (text, attached) = compact(text, images: images)
        return withVideos(text, attachments: attached)
    }

    /// The text and attachments as an agent gets them: a video isn't something its CLI takes, so its token becomes
    /// "[Video #n]" (numbered among the videos), the stills cut from it join the images, and a line after the words
    /// says where it is, what the stills are, and that `zero video` cuts more. Images are numbered among the images.
    @MainActor static func withVideos(_ text: String, attachments: [String]) -> (text: String, images: [String]) {
        guard attachments.contains(where: { Attachments.isVideo(URL(fileURLWithPath: $0)) }) else { return (text, attachments) }
        var images: [String] = [], number: [Int: Int] = [:], videos: [(path: String, index: Int)] = []
        for (i, path) in attachments.enumerated() {
            if Attachments.isVideo(URL(fileURLWithPath: path)) {
                videos.append((path, videos.count + 1)); number[i + 1] = videos.count
            } else {
                images.append(path); number[i + 1] = images.count
            }
        }
        let out = NSMutableString(string: text)
        for token in find(in: text).reversed() {
            if let n = number[token.number] {
                out.replaceCharacters(
                    in: token.range, with: Self.text(n, video: Attachments.isVideo(URL(fileURLWithPath: attachments[token.number - 1]))))
            }
        }
        for video in videos {
            var line = "[Video #\(video.index): \(video.path)"
            if let cut = Attachments.videos[video.path] {
                line += ", \(VideoFrames.stamp(cut.info.seconds)) long, \(cut.info.width)×\(cut.info.height). Stills from it: "
                line += zip(cut.images, cut.times).map { path, at in
                    images.append(path); return "\(Self.text(images.count)) at \(VideoFrames.stamp(at))"
                }.joined(separator: ", ")
            }
            line += ". It's a video: cut the frames you need with `zero video \"\(video.path)\"`.]"
            out.append("\n\n" + line)
        }
        return (out as String, images)
    }

    private static let videoLine = try! NSRegularExpression(
        pattern: "\\n*\\[Video #(\\d+): (.+?)(?:, \\d+:\\d|\\. It's a video)[^\\n]*\\]$", options: [.anchorsMatchLines])

    /// What a sent message shows as its tiles: each video once (its first still, a play mark, the video itself on a
    /// click), not the stills cut from it for the agent; the images as they are.
    static func tiles(_ text: String, images: [String]) -> [(path: String, video: String?)] {
        let whole = text as NSString
        var stills = Set<Int>(), videos: [(path: String, video: String?)] = []
        for match in videoLine.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            let line = whole.substring(with: match.range)
            let numbers = find(in: line).filter { !$0.video }.map(\.number)
            stills.formUnion(numbers)
            let poster = numbers.first.flatMap { images.indices.contains($0 - 1) ? images[$0 - 1] : nil }
            videos.append((poster ?? "", whole.substring(with: match.range(at: 2))))
        }
        return videos + images.enumerated().filter { !stills.contains($0.offset + 1) }.map { ($0.element, nil) }
    }

    /// The text with each token a Markdown link to its image or video, for a sent message: the renderer draws the
    /// pill. A video's line for the agent (withVideos) isn't shown: its pill is.
    static func linked(_ text: String, images: [String]) -> String {
        let whole = text as NSString
        var videos: [Int: String] = [:]
        for match in videoLine.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            videos[Int(whole.substring(with: match.range(at: 1))) ?? 0] = whole.substring(with: match.range(at: 2))
        }
        let out = NSMutableString(
            string: videoLine.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: whole.length), withTemplate: ""))
        for token in find(in: out as String).reversed() {
            let path = token.video ? videos[token.number] : (images.indices.contains(token.number - 1) ? images[token.number - 1] : nil)
            guard let path else { continue }
            out.replaceCharacters(
                in: token.range, with: "[\(token.video ? "Video" : "Image") #\(token.number)](\(URL(fileURLWithPath: path).absoluteString))"
            )
        }
        return out as String
    }

    /// The pill, as one character of the text, on the line's baseline like a word.
    static func attachment(_ number: Int, font: NSFont, video: Bool = false) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = Cell(number: number, font: font, video: video)
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
        guard glyph < manager.numberOfGlyphs,
            manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(inText)
        else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard let cell = (storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? Cell
        else { return nil }
        return (cell, index)
    }

    final class Cell: NSTextAttachmentCell {
        let number: Int
        let textFont: NSFont
        let video: Bool
        private static let inset: CGFloat = 4

        init(number: Int, font: NSFont, video: Bool = false) {
            self.number = number
            self.textFont = font
            self.video = video
            super.init(textCell: "")
        }
        required init(coder: NSCoder) { fatalError("not kept") }

        private static let icon: CGFloat = 12
        private static let gap: CGFloat = 4
        /// Neutral, as the chips are: an image isn't a warning or a find (the skills' yellow read as one).
        private static let fill = NSColor(name: nil) {
            NSColor.labelColor.withAlphaComponent($0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.12 : 0.07)
        }

        /// The text's size, a step heavier than the words around it.
        private var words: NSAttributedString {
            NSAttributedString(
                string: video ? "Video \(number)" : "Image \(number)",
                attributes: [.font: NSFont.systemFont(ofSize: textFont.pointSize, weight: .medium), .foregroundColor: NSColor.labelColor])
        }

        override func cellSize() -> NSSize {
            NSSize(
                width: Self.inset * 2 + Self.icon + Self.gap + ceil(words.size().width) + 1,
                height: ceil(textFont.ascender - textFont.descender) + 1)
        }

        /// Its bottom half a point under the line's descent, as the composer's pills sit.
        override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: textFont.descender - 0.5) }

        /// The text view opens the image itself (a click is a click, not a drag of the cell).
        override func wantsToTrackMouse() -> Bool { false }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
            Self.fill.setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: 4, yRadius: 4).fill()
            // Nucleo's image (a video's play mark), in the words' quieter colour: a template, tinted here.
            if let mark = Nucleo.image(video ? "media-play" : "image", fill: video ? "glyph" : "outline", size: Self.icon) {
                let tinted = NSImage(size: mark.size, flipped: false) { rect in
                    mark.draw(in: rect)
                    NSColor.secondaryLabelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(
                    in: NSRect(x: cellFrame.minX + Self.inset, y: cellFrame.midY - Self.icon / 2, width: Self.icon, height: Self.icon),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let words = self.words
            words.draw(at: NSPoint(x: cellFrame.minX + Self.inset + Self.icon + Self.gap, y: cellFrame.midY - words.size().height / 2))
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
@MainActor func imageActions(_ path: String) -> [[MenuItem]] {
    [
        [
            MenuItem("Open with Preview", "image") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) },
            MenuItem("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
        ]
    ]
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
                    .zeroContextMenu("image-\(path)") { imageActions(path) }
                    .id(path)
            }
            if paths.count > 1 {
                Text("\(index + 1) of \(paths.count)").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(
                    .white.opacity(0.85)
                )
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
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        }
    }

    private func step(_ by: Int) {
        guard paths.count > 1 else { return }
        index = (index + by + paths.count) % paths.count
    }
}
