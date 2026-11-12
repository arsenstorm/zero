import AppKit
import Observation
import SwiftUI
import ZeroCore

extension View {
    /// Card chrome: surface, radius and the hairline that separates it from the desktop.
    func card() -> some View {
        background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    /// Soft edges: content dissolves into the top and bottom over these heights instead of being sliced by them.
    /// `under`: a strip at the foot where nothing shows (under a composer lying over the content).
    func softEdges(top: CGFloat, bottom: CGFloat, under: CGFloat = 0) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
                Color.clear.frame(height: under)
            }
        }
    }
}

/// Surfaces for both appearances, resolved by AppKit at draw time so the system setting applies live.
enum Theme {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static let cardColor = NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.11, alpha: 1) : .white
    }
    static let card = Color(nsColor: cardColor)
    /// A row under the pointer, a step under the sidebar's grey; the rail's active and hovered tiles.
    static let hover = dynamic(dark: NSColor(white: 0.20, alpha: 1), light: NSColor(white: 0.945, alpha: 1))
    /// A table row under the pointer: lighter than the body, so it never reads as the headings' grey.
    static let rowHover = dynamic(dark: NSColor(white: 0.21, alpha: 1), light: NSColor(white: 1, alpha: 1))
    static let railSelected = dynamic(dark: NSColor(white: 0.24, alpha: 1), light: NSColor(white: 0.84, alpha: 1))
    static let railHover = dynamic(dark: NSColor(white: 0.15, alpha: 1), light: NSColor(white: 0.885, alpha: 1))
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
    /// The sidebars' blueprint heading as drafting paper: dark ink on the panels' neutral-200 (neutral-800 with light
    /// ink in dark mode), so it reads as a surface of its own rather than a faded black.
    static let blueprint = dynamic(dark: hex(0x262626), light: hex(0xe5e5e5))
    static let onBlueprint = dynamic(dark: hex(0xfafafa), light: hex(0x0a0a0a))
    /// The workspace window's own grey, under its panel: the outer rail.
    static let rail = dynamic(dark: NSColor(white: 0.07, alpha: 1), light: NSColor(white: 0.925, alpha: 1))
    /// A row's fill on frosted glass (the new task page's composer): see-through, so it takes the tint under it.
    static let frostFill = Color.primary.opacity(0.07)
    static let row = dynamic(dark: NSColor(white: 0.16, alpha: 1), light: NSColor(white: 0.94, alpha: 1))
    /// The rail's grey as a tint over the window's blur: the desktop shows through, softly.
    static let railTint = dynamic(dark: NSColor(white: 0.07, alpha: 0.55), light: NSColor(white: 0.925, alpha: 0.6))
    /// The composer's well: in light mode only a breath under the card, so it reads as a field, not a slab.
    static let composer = dynamic(dark: NSColor(white: 0.16, alpha: 1), light: NSColor(white: 0.975, alpha: 1))
    /// The composer's pills: one step under its light well rather than the key caps' heavier grey.
    static let chip = dynamic(dark: NSColor(white: 0.22, alpha: 1), light: NSColor(white: 0.93, alpha: 1))
    /// The workspace's composer, as Codex's: a white card on a hairline, its project tab a flat grey behind it, and a
    /// grey send button until there's something to send.
    static let field = dynamic(dark: NSColor(white: 0.17, alpha: 1), light: .white)
    static let fieldEdge = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.07))
    static let fieldTab = dynamic(dark: NSColor(white: 0.13, alpha: 1), light: NSColor(white: 0.955, alpha: 1))
    static let sendIdle = dynamic(dark: NSColor(white: 0.36, alpha: 1), light: NSColor(white: 0.56, alpha: 1))
    /// "Done" in a pill: the system green reads pale as small text on its own light fill; this one has weight.
    static let done = dynamic(
        dark: NSColor(red: 0.40, green: 0.82, blue: 0.50, alpha: 1), light: NSColor(red: 0.09, green: 0.50, blue: 0.22, alpha: 1))
    /// An answer's row: a tint over whatever it sits on (a card, a question's panel), so it reads as a button on both.
    static let choice = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.05))
    /// Its number's key cap: a tint over the row's, a step past it on any surface.
    static let choiceCap = dynamic(dark: NSColor(white: 1, alpha: 0.1), light: NSColor(white: 0, alpha: 0.08))
    static let keycap = dynamic(dark: NSColor(white: 0.22, alpha: 1), light: NSColor(white: 0.88, alpha: 1))
    /// A fully solid knob; `.primary` is a translucent label colour.
    static let knob = dynamic(dark: .white, light: .black)
    /// Text on a solid `knob` surface (the user's message bubbles).
    static let onKnob = dynamic(dark: .black, light: .white)
    static let code = dynamic(dark: NSColor(white: 0, alpha: 0.35), light: NSColor(white: 0, alpha: 0.05))
    static let pill = dynamic(dark: NSColor(white: 0, alpha: 0.9), light: NSColor(white: 1, alpha: 0.96))
    // Opaque, so a border is one colour along its length whatever sits behind each segment.
    // Light strokes sit a step above the key-cap grey (L 0.92 against 0.91): an outline, not a frame.
    static let hairline = dynamic(dark: NSColor(white: 0.30, alpha: 1), light: NSColor(white: 0.88, alpha: 1))
    static let stroke = dynamic(dark: NSColor(white: 0.24, alpha: 1), light: NSColor(white: 0.89, alpha: 1))
    /// Menus, as Linear draws its (dark measured from its pixels; light read from its page's styles: lch 100 under an
    /// lch 90.55 edge, lch 97.3 between groups).
    static let menu = dynamic(dark: NSColor(srgbRed: 33 / 255, green: 33 / 255, blue: 34 / 255, alpha: 1), light: .white)
    static let menuStroke = dynamic(
        dark: NSColor(srgbRed: 51 / 255, green: 52 / 255, blue: 54 / 255, alpha: 1),
        light: NSColor(srgbRed: 228 / 255, green: 228 / 255, blue: 228 / 255, alpha: 1))
    static let menuLine = dynamic(
        dark: NSColor(srgbRed: 41 / 255, green: 42 / 255, blue: 45 / 255, alpha: 1),
        light: NSColor(srgbRed: 247 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1))
    /// The row under the pointer (light lch 95), its words and icon the strongest (lch 10).
    static let menuHover = dynamic(
        dark: NSColor(srgbRed: 50 / 255, green: 50 / 255, blue: 52 / 255, alpha: 1),
        light: NSColor(srgbRed: 241 / 255, green: 241 / 255, blue: 241 / 255, alpha: 1))
    /// A row's words (light lch 20) and its icon (lch 40), as Linear's.
    static let menuText = dynamic(
        dark: NSColor(srgbRed: 229 / 255, green: 230 / 255, blue: 233 / 255, alpha: 1),
        light: NSColor(srgbRed: 47 / 255, green: 47 / 255, blue: 49 / 255, alpha: 1))
    static let menuIcon = dynamic(
        dark: NSColor(srgbRed: 156 / 255, green: 157 / 255, blue: 160 / 255, alpha: 1),
        light: NSColor(srgbRed: 91 / 255, green: 92 / 255, blue: 94 / 255, alpha: 1))
    static let menuHot = dynamic(dark: .white, light: NSColor(srgbRed: 27 / 255, green: 27 / 255, blue: 27 / 255, alpha: 1))
    static let selectedStroke = dynamic(dark: NSColor(white: 0.45, alpha: 1), light: NSColor(white: 0.70, alpha: 1))
    /// Key cap fills for a chosen option: deeper in dark mode so the white digit keeps its contrast.
    static let greenCap = dynamic(dark: NSColor(red: 0.16, green: 0.55, blue: 0.27, alpha: 1), light: NSColor.systemGreen)
    static let orangeCap = dynamic(dark: NSColor(red: 0.78, green: 0.45, blue: 0.08, alpha: 1), light: NSColor.systemOrange)
    static let redCap = dynamic(dark: NSColor(red: 0.75, green: 0.22, blue: 0.20, alpha: 1), light: NSColor.systemRed)
    /// Pastel surfaces for a chosen option: delivered (mint), still sendable or on its way (apricot), and
    /// not delivered (rose).
    static let greenRow = dynamic(
        dark: NSColor(red: 0.13, green: 0.25, blue: 0.16, alpha: 1), light: NSColor(red: 0.87, green: 0.96, blue: 0.89, alpha: 1))
    static let orangeRow = dynamic(
        dark: NSColor(red: 0.30, green: 0.22, blue: 0.12, alpha: 1), light: NSColor(red: 0.99, green: 0.93, blue: 0.85, alpha: 1))
    /// A done question's own shades, one hue (the Done state's purple, 292°) from its surface to its ink, picked as
    /// Refactoring UI builds an alert's: the purple faded over grey instead went muddy, a lavender-grey.
    private static func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> NSColor {
        let v = l + s * min(l, 1 - l)
        return NSColor(colorSpace: .sRGB, hue: h / 360, saturation: v == 0 ? 0 : 2 * (1 - l / v), brightness: v, alpha: 1)
    }
    static let doneSurface = dynamic(dark: hsl(292, 0.45, 0.14), light: hsl(292, 1, 0.985))
    static let doneShell = dynamic(dark: hsl(292, 0.55, 0.11), light: hsl(292, 0.70, 0.95))
    static let doneRow = dynamic(dark: hsl(292, 0.50, 0.21), light: hsl(292, 0.85, 0.945))
    static let doneCap = dynamic(dark: hsl(292, 0.55, 0.32), light: hsl(292, 0.75, 0.89))
    /// Its ink: the Done state's own purple, its icon's.
    static let doneInk = Color(nsColor: .systemPurple)
    /// Quiet words on its surface: its hue, not grey (grey on a colour reads dull).
    static let doneMuted = dynamic(dark: hsl(292, 0.55, 0.75), light: hsl(292, 0.30, 0.48))
    static let redRow = dynamic(
        dark: NSColor(red: 0.32, green: 0.14, blue: 0.14, alpha: 1), light: NSColor(red: 0.99, green: 0.89, blue: 0.89, alpha: 1))
}

/// 45s, 31m, 2h, 3d.
func shortAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

/// What an agent's dot says, in the board's colours: blue it needs you, orange it's in trouble, teal it's over to you,
/// grey it waits on someone else, purple it's done, blue it is working. Closed means the user shut it: no dot until it
/// speaks again.
enum AgentStatus {
    case needsYou, trouble, blocked, handed, waiting, done, working, closed, offline

    static func of(_ asks: [Ask]) -> AgentStatus {
        if asks.contains(where: { $0.state == .waiting || $0.state == .pending }) { return .needsYou }
        guard let last = asks.last(where: { $0.kind != .message }) else { return .working }
        switch last.status {
        case "blocked", "waiting": return .waiting
        case "done", "merged", "completed": return .done
        case "closed": return .closed
        default: return .working
        }
    }

    var color: Color {
        switch self {
        case .needsYou: return .blue
        case .trouble: return .orange
        case .blocked: return .red
        case .handed: return .teal
        case .waiting: return .gray
        // Done: purple, as GitHub shows a merged pull request.
        case .done: return .purple
        case .working: return .blue
        case .closed, .offline: return .gray
        }
    }
}

/// An arc turning once a second; a plain dot under Reduce Motion. Turned by Core Animation, on the render server:
/// drawn by SwiftUI from the clock, every spinner on screen had the whole window laid out again each frame, the
/// conversation with it, for as long as any task worked (a third of a core, and the Mac's battery). An AppKit view in a
/// row that SwiftUI moves with an animation goes straight to where the row ends up, not with it, for that moment.
struct Spinner: View {
    var color: Color = .blue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion { Circle().fill(color) } else { SpinnerLayer(color: NSColor(color)) }
    }
}

private struct SpinnerLayer: NSViewRepresentable {
    let color: NSColor
    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }
    func updateNSView(_ view: SpinnerView, context: Context) { view.color = color }
}

final class SpinnerView: NSView {
    var color: NSColor = .systemBlue { didSet { recolor() } }
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeStart = 0.15
        layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pointer events pass through, so the gestures on the dot or row underneath keep working.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        fit()
    }

    /// The arc drawn to the view's size, on every resize too: a new row is laid out at no size first, and given its
    /// size without another layout pass, which left its arc at none.
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        fit()
    }

    private func fit() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        CATransaction.commit()
        recolor()
        spin()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { fit() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); recolor() }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance { arc.strokeColor = color.cgColor }
    }

    /// One turn a second, clockwise, forever; added again whenever the view comes back on screen, as Core Animation
    /// drops animations from layers that leave the hierarchy.
    private func spin() {
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        // 30 frames a second, as the turn's pulse (PulseLayer): forever on while any task works, at 60 or a ProMotion
        // display's 120 it kept the window server compositing the window and the control bar for a turn that reads the
        // same.
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        arc.add(turn, forKey: "spin")
    }
}
