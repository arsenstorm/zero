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

/// An image as a square tile, cropped to fill; a click opens it. With `remove`, an × shows on hover.
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
    var remove: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
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
        .overlay(alignment: .topTrailing) {
            if let remove, hovered {
                Button(action: remove) {
                    NucleoIcon("xmark", size: 9).foregroundStyle(Theme.onKnob).frame(width: 18, height: 18).background(Theme.knob, in: Circle())
                }
                .buttonStyle(.plain).padding(5).help("Remove")
            }
        }
        .onHover { hovered = $0 }
        .help((path as NSString).lastPathComponent)
    }
}
