// Renders Zero's icons from Resources/logo/logo.svg, the filled cube: the app icon (AppIcon.icns), Slack's icon
// (slack.png), the logo on plain white (plain.png), the menu bar template (menubar.png, menubar@2x.png) and the marks the app draws itself (mark.svg,
// mark-small.svg). Run from apps/macos: swift scripts/icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = try! String(contentsOf: root.appendingPathComponent("Resources/logo/logo.svg"), encoding: .utf8)

/// The logo in a colour: one filled shape, its weight its own, the same at every size.
func logo(color: String) -> String { svg.replacingOccurrences(of: "fill=\"#000000\"", with: "fill=\"\(color)\"") }

func image(_ source: String) -> NSImage { NSImage(data: Data(source.utf8))! }

func bitmap(_ size: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

/// Drawn at four times the size and scaled down (supersampled): thin strokes at an angle come out even, where drawing
/// at the size itself leaves them ragged.
func png(_ size: Int, _ draw: (CGRect) -> Void) -> Data {
    let over = 4
    let big = bitmap(size * over)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: big)
    draw(CGRect(x: 0, y: 0, width: size * over, height: size * over))
    NSGraphicsContext.restoreGraphicsState()
    let rep = bitmap(size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let image = NSImage(size: NSSize(width: size * over, height: size * over))
    image.addRepresentation(big)
    image.draw(in: CGRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Fits the 1342 × 1284 drawing into `box`, centred.
func drawLogo(_ img: NSImage, in box: CGRect) {
    let scale = min(box.width / 1342, box.height / 1284)
    let size = CGSize(width: 1342 * scale, height: 1284 * scale)
    img.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
}

/// The cube itself (the drawing has margins of its own: the shape spans 193–1150 × 61–1115) fitted into `box`, so the
/// icon's glyph is sized by what is seen, as the Dock's other icons are.
func drawCube(_ img: NSImage, in box: CGRect) {
    let content = CGRect(x: 193, y: 61, width: 957, height: 1054)
    let scale = min(box.width / content.width, box.height / content.height)
    let size = CGSize(width: 1342 * scale, height: 1284 * scale)
    // The drawing's centre sits where the cube's centre should: the box's.
    let origin = CGPoint(x: box.midX - (content.midX) * scale, y: box.midY - (1284 - content.midY) * scale)
    img.draw(in: CGRect(origin: origin, size: size))
}

// App icon: Apple's grid (an 824-unit rounded square on a 1024 canvas), white to soft grey, the cube in near-black.
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let iconLogo = image(logo(color: "#1d1d1f"))
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for s in scales {
        let px = points * s
        let data = png(px) { canvas in
            let k = canvas.width / 1024
            let plate = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
            let shape = NSBezierPath(roundedRect: plate, xRadius: 185 * k, yRadius: 185 * k)
            NSGraphicsContext.saveGraphicsState()
            if px >= 128 {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(white: 0, alpha: 0.18); shadow.shadowBlurRadius = 18 * k; shadow.shadowOffset = NSSize(width: 0, height: -6 * k)
                shadow.set()
            }
            NSColor.white.setFill(); shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: .white, ending: NSColor(white: 0.93, alpha: 1))!.draw(in: shape, angle: -90)
            NSColor(white: 0, alpha: 0.08).setStroke(); shape.lineWidth = max(1, 2 * k); shape.stroke()
            drawCube(iconLogo, in: plate.insetBy(dx: 100 * k, dy: 100 * k))
        }
        let name = s == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run(); iconutil.waitUntilExit()

// Slack's icon for Zero's app there: full bleed (Slack rounds it itself), the same plate and cube, 1024 px.
try! png(1024) { canvas in
    let shape = NSBezierPath(rect: canvas)
    NSGradient(starting: .white, ending: NSColor(white: 0.93, alpha: 1))!.draw(in: shape, angle: -90)
    drawCube(iconLogo, in: canvas.insetBy(dx: canvas.width * 0.2, dy: canvas.width * 0.2)) // drawn at 4×: the margin a fifth of it
}.write(to: root.appendingPathComponent("Resources/logo/slack.png"))

// The logo on a plain background: solid white, nothing else, full bleed, 1024 px.
try! png(1024) { canvas in
    NSColor.white.setFill(); canvas.fill()
    drawCube(iconLogo, in: canvas.insetBy(dx: canvas.width * 0.2, dy: canvas.width * 0.2)) // drawn at 4×: the margin a fifth of it
}.write(to: root.appendingPathComponent("Resources/logo/plain.png"))

// Menu bar: a template (black on clear, macOS tints it), 18 pt.
let bar = image(logo(color: "#000000"))
for (name, px) in [("menubar.png", 18), ("menubar@2x.png", 36)] {
    try! png(px) { drawLogo(bar, in: $0.insetBy(dx: CGFloat(px) / 18, dy: CGFloat(px) / 18)) }.write(to: root.appendingPathComponent("Resources/logo/\(name)"))
}

// The marks the app draws (onboarding), black for template images: the logo, at any size alike.
for name in ["mark.svg", "mark-small.svg"] {
    try! logo(color: "#000000").write(to: root.appendingPathComponent("Resources/logo/\(name)"), atomically: true, encoding: .utf8)
}
print("icons written")
