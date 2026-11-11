// The disk image's background: Zero's mark, very large and very faint, as an underlay cropped by the window's edges,
// and a curved arrow from Zero to the Applications folder. Writes background.png and background@2x.png beside this file
// (dmgbuild makes the Retina TIFF from the pair). Run: swift apps/macos/dmg/background.swift
import AppKit

let width = 640.0, height = 400.0
// White, as Finder's title bar is, so the window reads as one surface under it (a grey ground made the title bar a
// band of its own); the name as faint on it as the footer's is on its own ground.
let ground = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let ink = CGColor(srgbRed: 0xf1 / 255.0, green: 0xf1 / 255.0, blue: 0xf1 / 255.0, alpha: 1)
let arrow = CGColor(srgbRed: 0xb4 / 255.0, green: 0xb4 / 255.0, blue: 0xb4 / 255.0, alpha: 1)
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let svg = try String(contentsOf: here.appendingPathComponent("../Resources/logo/mark-small.svg"), encoding: .utf8)

// The mark's path: only M, L and Z, in the viewBox's units (y down).
func mark() -> (path: CGPath, box: CGRect) {
    let box = svg.firstMatch(of: #/viewBox="([\d.\s-]+)"/#).map { $0.1.split(separator: " ").compactMap { Double($0) } } ?? []
    let d = svg.firstMatch(of: #/ d="([^"]+)"/#).map { String($0.1) } ?? ""
    let path = CGMutablePath()
    let tokens = d.split(separator: " ")
    var i = 0
    while i < tokens.count {
        let token = tokens[i]
        if token == "Z" { path.closeSubpath(); i += 1; continue }
        let point = CGPoint(x: Double(token.dropFirst())!, y: Double(tokens[i + 1])!)
        if token.hasPrefix("M") { path.move(to: point) } else { path.addLine(to: point) }
        i += 2
    }
    return (path, CGRect(x: box[0], y: box[1], width: box[2], height: box[3]))
}

func render(scale: Double, to file: String) throws {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(ground)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // The mark alone, far larger than the window and offset to its lower left, cropped by the edges: an underlay the
    // icons sit over, not a picture of its own.
    let (path, box) = mark()
    let markHeight = height * 1.35, markScale = markHeight / box.height
    context.saveGState()
    context.translateBy(x: -width * 0.22, y: markHeight - height * 0.5)
    context.scaleBy(x: markScale, y: -markScale)
    context.translateBy(x: -box.minX, y: -box.minY)
    context.addPath(path)
    context.setFillColor(ink)
    context.fillPath(using: .evenOdd)
    context.restoreGState()

    // What to do, over the icons (at x 200 and 440, y 210 from the top): the words, and under them a curved arrow from
    // above Zero to above the Applications folder, arching up, its head pointing down into the folder.
    // Rounded, as a friendly line is; what to drag and where in darker, semibold type.
    func rounded(_ weight: NSFont.Weight) -> NSFont {
        let plain = NSFont.systemFont(ofSize: 17, weight: weight)
        return plain.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 17) } ?? plain
    }
    let soft: [NSAttributedString.Key: Any] = [.font: rounded(.medium), .foregroundColor: NSColor(white: 0.6, alpha: 1)]
    let named: [NSAttributedString.Key: Any] = [.font: rounded(.semibold), .foregroundColor: NSColor(white: 0.25, alpha: 1)]
    let words = NSMutableAttributedString(string: "Drag ", attributes: soft)
    words.append(NSAttributedString(string: "Zero", attributes: named))
    words.append(NSAttributedString(string: " into ", attributes: soft))
    words.append(NSAttributedString(string: "Applications", attributes: named))
    let line = CTLineCreateWithAttributedString(words)
    let wordsWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.textPosition = CGPoint(x: (width - wordsWidth) / 2, y: height - 62)
    CTLineDraw(line, context)
    let start = CGPoint(x: 222, y: height - 132), end = CGPoint(x: 420, y: height - 132)
    let control = CGPoint(x: 321, y: height - 52)
    context.setStrokeColor(arrow)
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: start)
    context.addQuadCurve(to: end, control: control)
    context.strokePath()
    // The head along the curve's direction at its end (from the control point).
    let angle = atan2(end.y - control.y, end.x - control.x), spread = 0.5, length = 13.0
    context.move(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
    context.addLine(to: end)
    context.addLine(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
    context.strokePath()

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = NSSize(width: width, height: height) // 144 dpi for @2x, as tiffutil -cathidpicheck wants
    try rep.representation(using: .png, properties: [:])!.write(to: here.appendingPathComponent(file))
}

try render(scale: 1, to: "background.png")
try render(scale: 2, to: "background@2x.png")
