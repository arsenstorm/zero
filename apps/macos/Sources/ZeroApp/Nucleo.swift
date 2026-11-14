import AppKit
import SwiftUI
import ZeroCore

/// The app's icons, bundled in Resources/icons as `<label>-<fill>.svg` and drawn as templates so they take the colour
/// around them as SF Symbols do. Official builds bundle Nucleo's (the ui family, on its 18 px grid, from the private
/// zero-private repo); builds without it bundle the closest Lucide icon under the same name (scripts/lucide.txt).
enum Nucleo {
    private static var images: [String: NSImage] = [:]

    /// Which set the build bundled (the Makefile writes it into Info.plist): "Nucleo" or "Lucide".
    static let set = Bundle.main.object(forInfoDictionaryKey: "ZeroIcons") as? String ?? "Lucide"

    /// The icon's file; a fill that wasn't exported (Lucide has outlines only) falls back to the outline.
    static func url(_ label: String, fill: String = "outline") -> URL? {
        Bundle.main.url(forResource: "\(label)-\(fill)", withExtension: "svg", subdirectory: "icons")
            ?? Bundle.main.url(forResource: "\(label)-outline", withExtension: "svg", subdirectory: "icons")
    }

    /// `stroke`: the outline's width on an 18 point grid (menus draw theirs heavier, as Linear's are). Without one,
    /// outlines draw at 1 on 18: CoreSVG doesn't read Nucleo's `var(--nucleo-stroke-width, 1.5)` and falls back to 1,
    /// and scripts/lucide.sh saves Lucide's at 1.333 on their 24.
    static func image(_ label: String, fill: String = "outline", size: CGFloat = 16, stroke: CGFloat? = nil) -> NSImage? {
        let name = "\(label)-\(fill)"
        let key = stroke.map { "\(name)@\($0)" } ?? name
        // The file looked up only on a miss: every menu row draws its icon again on each hover.
        let image = images[key] ?? url(label, fill: fill).flatMap { load($0, stroke: stroke) }
        if image == nil { Log.write("icon missing: \(name)") }
        image?.isTemplate = true
        images[key] = image
        let sized = image?.copy() as? NSImage
        sized?.size = NSSize(width: size, height: size)
        return sized
    }

    private static func load(_ file: URL, stroke: CGFloat?) -> NSImage? {
        guard let stroke else { return NSImage(contentsOf: file) }
        guard let svg = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        // Scaled to the icon's own grid (Lucide's is 24), so either set draws the same weight. Nucleo's glyphs keep
        // their 0s.
        let grid = svg.firstMatch(of: #/viewBox="0 0 ([\d.]+)/#).flatMap { Double($0.1) } ?? 18
        let heavier = svg.replacing(#/stroke-width="(?:var\(--nucleo-stroke-width, 1\.5\)|[\d.]*[1-9][\d.]*)"/#) { _ in
            "stroke-width=\"\(stroke * grid / 18)\""
        }
        return NSImage(data: Data(heavier.utf8))
    }
}

struct NucleoIcon: View {
    let label: String
    var fill = "outline"
    var size: CGFloat = 16
    var stroke: CGFloat? = nil

    /// `label` may carry its fill after a colon ("key:glyph"), for icons named in strings.
    init(_ label: String, fill: String = "outline", size: CGFloat = 16, stroke: CGFloat? = nil) {
        let parts = label.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        self.label = parts.first ?? ""; self.fill = parts.count > 1 ? parts[1] : fill; self.size = size; self.stroke = stroke
    }

    var body: some View {
        if let image = Nucleo.image(label, fill: fill, size: size, stroke: stroke) {
            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// One of Nucleo's pixel icons (ZeroCore's AgentIcons), at its own size: its 24 px grid on 12 pt, drawn once into a
/// 24 px bitmap and shown without smoothing, so each of its pixels is one of the screen's wherever the row lands (drawn
/// as a vector, it fell between them and blurred). In a row's 14 pt slot. Builds with Lucide draw its fallback as any
/// icon.
struct PixelIcon: View {
    let label: String
    var height: CGFloat = 16
    private static var bitmaps: [String: NSImage] = [:]

    init(_ label: String, height: CGFloat = 16) { self.label = label; self.height = height }

    var body: some View {
        Group {
            if Nucleo.set == "Nucleo", let image = Self.bitmap(label) {
                Image(nsImage: image).renderingMode(.template).interpolation(.none).resizable().frame(width: 12, height: 12)
            } else {
                NucleoIcon(label, size: 14)
            }
        }
        .frame(width: 14, height: height)
    }

    private static func bitmap(_ label: String) -> NSImage? {
        if let image = bitmaps[label] { return image }
        guard let svg = Nucleo.url(label).flatMap(NSImage.init(contentsOf:)),
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: 24, height: 24)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        context?.shouldAntialias = false
        NSGraphicsContext.current = context
        svg.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.addRepresentation(rep)
        image.isTemplate = true
        bitmaps[label] = image
        return image
    }
}

/// A label with a Nucleo icon in place of an SF Symbol.
struct NucleoLabel: View {
    let text: String
    let icon: String
    var fill = "outline"
    var size: CGFloat = 14

    init(_ text: String, icon: String, fill: String = "outline", size: CGFloat = 14) {
        self.text = text; self.icon = icon; self.fill = fill; self.size = size
    }

    var body: some View {
        HStack(spacing: 6) {
            NucleoIcon(icon, fill: fill, size: size); Text(text)
        }
    }
}
