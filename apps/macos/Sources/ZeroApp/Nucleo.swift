import AppKit
import SwiftUI

/// Nucleo icons (the ui family, on its 18 px grid) bundled in Resources/nucleo as `<label>-<fill>.svg`, drawn as
/// templates so they take the colour around them as SF Symbols do. Exported from the local Nucleo install by label.
enum Nucleo {
    private static var images: [String: NSImage] = [:]

    static func image(_ label: String, fill: String = "outline", size: CGFloat = 16) -> NSImage? {
        let name = "\(label)-\(fill)"
        let image = images[name] ?? Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "nucleo").flatMap(NSImage.init(contentsOf:))
        image?.isTemplate = true
        images[name] = image
        let sized = image?.copy() as? NSImage
        sized?.size = NSSize(width: size, height: size)
        return sized
    }
}

struct NucleoIcon: View {
    let label: String
    var fill = "outline"
    var size: CGFloat = 16

    /// `label` may carry its fill after a colon ("key:glyph"), for icons named in strings.
    init(_ label: String, fill: String = "outline", size: CGFloat = 16) {
        let parts = label.split(separator: ":", maxSplits: 1).map(String.init)
        self.label = parts[0]; self.fill = parts.count > 1 ? parts[1] : fill; self.size = size
    }

    var body: some View {
        if let image = Nucleo.image(label, fill: fill, size: size) {
            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// A label with a Nucleo icon in place of an SF Symbol.
struct NucleoLabel: View {
    let text: String
    let icon: String
    var fill = "outline"
    var size: CGFloat = 14

    init(_ text: String, icon: String, fill: String = "outline", size: CGFloat = 14) { self.text = text; self.icon = icon; self.fill = fill; self.size = size }

    var body: some View {
        HStack(spacing: 6) { NucleoIcon(icon, fill: fill, size: size); Text(text) }
    }
}
