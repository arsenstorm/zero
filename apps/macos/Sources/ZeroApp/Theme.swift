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

extension View {
    /// A floating surface's shadow (a menu, a hover card, a popover), Linear's three soft ones (0 6 18 at 2%, 0 3 9 at
    /// 4%, 0 1 1 at 4%; a SwiftUI radius is half CSS's blur). Dialogs keep their own, deeper one. Put
    /// `compositingGroup()` before it on a stack.
    func floatingShadow(_ on: Bool = true) -> some View {
        shadow(color: .black.opacity(on ? 0.02 : 0), radius: 9, y: 6)
            .shadow(color: .black.opacity(on ? 0.04 : 0), radius: 4.5, y: 3)
            .shadow(color: .black.opacity(on ? 0.04 : 0), radius: 0.5, y: 1)
    }
}

/// The line between rows: `Theme.stroke`, 1 pt, opaque (the system's `Divider()` is translucent, so it reads darker
/// over a hovered row's fill than beside it).
struct Hairline: View {
    var color = Theme.stroke
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

/// Surfaces for both appearances, resolved by AppKit at draw time so the system setting applies live.
enum Theme {
    static func dynamicColor(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    private static func dynamic(dark: NSColor, light: NSColor) -> Color { Color(nsColor: dynamicColor(dark: dark, light: light)) }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }
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
    /// A ticked checkbox: the knob's black in light; in dark a grey, as solid white was glaring on the dark card.
    static let checkOn = dynamic(dark: NSColor(white: 0.36, alpha: 1), light: .black)
    static let checkMark = dynamic(dark: NSColor(white: 0.95, alpha: 1), light: .white)
    /// Code on a card, in a command's box or an answer's block alike: a step darker than the card in both appearances.
    static let codeColor = dynamicColor(dark: NSColor(white: 0, alpha: 0.35), light: NSColor(white: 0, alpha: 0.05))
    static let code = Color(nsColor: codeColor)
    /// Inline code's chip and a quote's bar, inside an answer's prose.
    static let inlineCode = dynamicColor(dark: NSColor(white: 1, alpha: 0.09), light: NSColor(white: 0, alpha: 0.055))
    static let quoteBar = dynamicColor(dark: NSColor(white: 1, alpha: 0.2), light: NSColor(white: 0, alpha: 0.15))
    /// A pane's head or a box of arguments on a card: the faintest tint, under code's.
    static let tint = Color.primary.opacity(0.03)
    /// Selected text, everywhere text is (Codex's): a neutral grey, the same whether the window is active or not, that
    /// light text stays readable on in dark mode and dark text in light. The caret is the text's own colour.
    static let selection = dynamicColor(dark: NSColor(white: 0.36, alpha: 1), light: NSColor(white: 0.82, alpha: 1))
    /// A link inside text: the conversation's colour, in every pad, card and notice.
    static let linkColor = NSColor.linkColor
    static let link = Color(nsColor: linkColor)
    /// The thin scrollbar's thumb: rgb(161 161 170 / 70%) light, rgb(113 113 122 / 70%) dark, the site's zinc.
    static let thumb = dynamic(
        dark: NSColor(srgbRed: 113 / 255, green: 113 / 255, blue: 122 / 255, alpha: 0.7),
        light: NSColor(srgbRed: 161 / 255, green: 161 / 255, blue: 170 / 255, alpha: 0.7))
    /// A diff's removed lines; its added ones are `done`'s green.
    static let removed = dynamic(dark: rgb(1.0, 0.48, 0.45), light: rgb(0.78, 0.16, 0.16))
    /// A token in the composer ("/word", "@path"): amber words on an amber chip.
    static let tokenText = dynamicColor(dark: rgb(0.98, 0.84, 0.40), light: rgb(0.55, 0.38, 0.0))
    static let tokenFill = dynamicColor(dark: rgb(0.36, 0.29, 0.06), light: rgb(0.99, 0.93, 0.62))
    /// A caution callout's three tones, light and dark: the shell around it, the panel its words sit on, the ink. Rose
    /// for a failure, amber for trouble that may pass.
    static let rose = (
        shell: dynamic(dark: rgb(0.24, 0.03, 0.10), light: rgb(1.0, 0.894, 0.902)),
        panel: dynamic(dark: rgb(0.40, 0.06, 0.18), light: rgb(1.0, 0.945, 0.949)),
        ink: dynamic(dark: rgb(1.0, 0.894, 0.902), light: rgb(0.30, 0.02, 0.10))
    )
    static let amber = (
        shell: dynamic(dark: rgb(0.26, 0.14, 0.02), light: rgb(1.0, 0.925, 0.835)),
        panel: dynamic(dark: rgb(0.40, 0.22, 0.04), light: rgb(1.0, 0.957, 0.902)),
        ink: dynamic(dark: rgb(1.0, 0.925, 0.835), light: rgb(0.36, 0.18, 0.0))
    )
    static let pill = dynamic(dark: NSColor(white: 0, alpha: 0.9), light: NSColor(white: 1, alpha: 0.96))
    // Opaque, so a border is one colour along its length whatever sits behind each segment.
    // Light strokes sit a step above the key-cap grey (L 0.92 against 0.91): an outline, not a frame.
    static let strokeColor = dynamicColor(dark: NSColor(white: 0.24, alpha: 1), light: NSColor(white: 0.89, alpha: 1))
    static let stroke = Color(nsColor: strokeColor)
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
        case .waiting: return .secondary
        // Done: purple, as GitHub shows a merged pull request.
        case .done: return .purple
        case .working: return .blue
        case .closed, .offline: return .secondary
        }
    }
}

/// Reduce Motion, one rule for the whole app: fades stay, movement and scale go. A fade is animated as it is, with no
/// check; what moves or grows goes through here.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Something arriving (a card joining the inbox's stack, the stack making room, an onboarding page): Emil's strong
    /// ease-out, mostly there in the first frames.
    static let enter = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.22)
    /// An animation that moves or scales something (a scroll, a slide, a reorder): none under Reduce Motion.
    static func animation(_ animation: Animation) -> Animation? { reduced ? nil : animation }
    /// An entrance or exit that moves or scales: only its fade under Reduce Motion.
    static func transition(_ transition: AnyTransition) -> AnyTransition { reduced ? .opacity : transition }
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
