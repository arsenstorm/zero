import AppKit
import SwiftUI

/// A round button in one of the bar's hollows, where its curves meet the screen edge: the inbox in the top one, the
/// settings in the bottom one. In, only a thin arc of it shows, facing the bar; out, the arc thickens inward and wraps
/// round into the full button. Its outer edge never moves, so the gap to the bar stays even all the way (the hollow's
/// radius is the button's plus that gap). With something waiting, the arc is the waiting colour, fading to the
/// button's own as it comes out.
struct BarKnob<Label: View>: View {
    /// In the top hollow (the arc faces down towards the bar) rather than the bottom one.
    var top = false
    /// Out as the full button; the pointer on it brings it out too, unless it's only passing over (`passing`).
    var out: Bool
    /// The pointer is on its way across into the open panel: being under it doesn't bring the button out.
    var passing = false
    /// Something waiting: the arc in the waiting colour.
    var waiting = false
    /// Bumped as something new comes in: the arc brightens once.
    var pulse = 0
    @ViewBuilder var label: (_ hovered: Bool) -> Label
    @State private var hovered = false
    /// How far out it is, eased by the button itself (see `.onChange` below).
    @State private var open: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let target = out || hovered && !passing, tint: CGFloat = waiting ? 1 : 0
        ZStack {
            if reduceMotion {
                // Reduce Motion: the arc and the button cross-fade, and the icon only fades.
                seed(0, tint: tint).opacity(1 - open)
                seed(1, tint: tint).opacity(open)
                label(hovered).opacity(open)
            } else {
                seed(open, tint: tint)
                    .keyframeAnimator(initialValue: 0.0, trigger: pulse) {
                        $0.modifier(Glow(glow: $1))
                    } keyframes: { _ in
                        LinearKeyframe(1, duration: 0.1, timingCurve: .easeOut)
                        LinearKeyframe(0, duration: 0.5, timingCurve: .easeOut)
                    }
                label(hovered).modifier(CarriedIcon(open: open, top: top))
            }
        }
        .frame(width: barKnob, height: barKnob)
        // One eased progress drives the ring and the icon together: ease-out-cubic, 220 ms out, 150 ms back in. Its own
        // animation, not an implicit one: what moves it often comes with a cut (the pane switching to an agent's as the
        // pointer leaves the inbox's zone), whose transaction would snap it.
        .onChange(of: target, initial: true) { was, now in
            let curve: Animation =
                reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.33, 1, 0.68, 1, duration: now ? 0.22 : 0.15)
            withAnimation(was == now ? nil : curve) { open = now ? 1 : 0 }
        }
        .animation(.easeOut(duration: 0.2), value: waiting)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    /// The arc (or ring, or button) on the bar's surface, the waiting colour laid over it by `tint`, all of it on the
    /// arc and none of it on the button, and the bar's hairline round it (blue while waiting, fading with it).
    private func seed(_ open: CGFloat, tint: CGFloat) -> some View {
        let shape = BarSeed(open: open, top: top), blue = AgentStatus.needsYou.color.opacity(tint * (1 - open))
        // The blue inside the surface's own cut, not a shape filled over it: a filled shape draws as a vector shape
        // layer, its edges harder and thinner on screen than the masked surface's; in the same cut it's the settings
        // arc exactly, in blue. Its border the same way, a colour cut to the outline: grey, or blue while waiting.
        let waiting = tint * (1 - open)
        return BarSurface(shape: shape, colour: blue)
            .overlay(Outline.drawn(Theme.stroke.opacity(1 - waiting), round: shape))
            .overlay(Outline.drawn(AgentStatus.needsYou.color.opacity(waiting), round: shape))
    }
}

/// A shape's 1 pt outline as a shape of its own, so a colour cut to it draws as the surfaces do (a stroke would be a
/// vector shape layer, harder on screen). The colour runs a point past the shape's frame, as the outline does there;
/// the shape is drawn in the frame itself (`margin`).
struct Outline<S: Shape>: Shape {
    var base: S
    var margin: CGFloat = 1
    var animatableData: S.AnimatableData {
        get { base.animatableData }
        set { base.animatableData = newValue }
    }
    func path(in rect: CGRect) -> Path {
        base.path(in: rect.insetBy(dx: margin, dy: margin)).strokedPath(StrokeStyle(lineWidth: 1))
    }

    static func drawn(_ colour: Color, round shape: S) -> some View {
        // Cut in the colour's own frame (a point past the shape's on each side), then let out by that point.
        colour.clipShape(Outline(base: shape)).padding(-1)
    }
}

/// The waiting arc's brightening as something new comes in: lighter, with a glow of its colour round it.
struct Glow: ViewModifier {
    var glow: CGFloat

    func body(content: Content) -> some View {
        content.brightness(0.2 * glow).shadow(color: AgentStatus.needsYou.color.opacity(0.7 * glow), radius: 3.5 * glow)
    }
}

/// The icon carried by the ring's progress: it fades in over the first half, grows from 0.8, and drifts 5 pt in from
/// the arc's side (towards the bar and the screen edge) to the centre, inside the hole all the way.
private struct CarriedIcon: ViewModifier, Animatable {
    var open: CGFloat
    let top: Bool

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func body(content: Content) -> some View {
        let drift = 5 / CGFloat(2).squareRoot() * (1 - open)
        content
            .scaleEffect(0.8 + 0.2 * open)
            .offset(x: drift, y: top ? drift : -drift)
            .opacity(min(1, open / 0.5))
    }
}

/// A bar button's diameter: a slot's width, so the hollow's radius (half the bar's width) leaves a 6 pt gap round it.
let barKnob: CGFloat = 32

/// Settings › Control bar, as the bar's settings button and its "Customise bar…" open it.
@MainActor func customiseBar() {
    guard let app = NSApp.delegate as? AppDelegate else { return }
    app.navigation.settingsPage = SettingsView.Page.bar.rawValue
    app.openSettings()
}

/// The button's outline as a ring: at 0 a 100° arc, 3 pt thick, along its edge facing the hollow (towards the bar and
/// the screen edge); at 1 the whole disc. The ring's outer radius stays put while it widens inward and its ends wrap round.
struct BarSeed: Shape {
    var open: CGFloat
    var top = false

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // From the same progress as the icon: the arc's ends close the ring by 0.6 while its stroke thickens inward
        // evenly from 0.1 on, so once closed the hole stays centred and round, shrinking to nothing at 1.
        let sweep = min(1, max(0, open / 0.6)), fill = min(1, max(0, (open - 0.1) / 0.9))
        let radius = min(rect.width, rect.height) / 2, thin: CGFloat = 3
        let width = thin + (radius - thin) * fill
        let half = 50 + 130 * sweep // degrees either side of the arc's middle, towards the bar and the edge
        let middle: Double = top ? 45 : -45
        var arc = Path()
        arc.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: radius - width / 2,
            startAngle: .degrees(middle - half), endAngle: .degrees(middle + half), clockwise: false)
        // Normalised: the round caps overlap once the ends meet, and the border would trace the seams.
        return arc.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round)).normalized(eoFill: false)
    }
}

/// The bar with nothing in its body, joining its two buttons: the hollows round the buttons (their radius plus the
/// 6 pt gap) curve in from the screen edge and meet in a low rounded bump, a small join rather than a lobe. The
/// buttons' centres are at the top and bottom of `rect`, a button's radius in.
struct BarPeak: Shape {
    /// The space between the two buttons: the join's length along the screen edge is this plus a button's width.
    static let gap: CGFloat = 12
    /// The bump's rounding, a circle touching both hollows on the screen's side of the buttons' axis. Its height comes
    /// from this alone (the hollows keep their gap): 2.5 pt stands it about 13.7 pt off the edge, 6 pt only 10.7.
    var tip: CGFloat = 2.5
    /// Its outline alone, open at its base (the screen's edge), as the bar's border.
    var open = false

    func path(in rect: CGRect) -> Path {
        let hollow = barKnob / 2 + 6, edge = rect.maxX, axis = rect.midX
        let top = CGPoint(x: axis, y: rect.minY + barKnob / 2), bottom = CGPoint(x: axis, y: rect.maxY - barKnob / 2)
        // The tip's circle touches both hollows: (x - axis)² + half² = (hollow + tip)², on the screen's side.
        let half = (bottom.y - top.y) / 2
        let peak = CGPoint(x: axis + max(0, (hollow + tip) * (hollow + tip) - half * half).squareRoot(), y: top.y + half)
        func angle(_ from: CGPoint, _ to: CGPoint) -> Angle { .radians(atan2(to.y - from.y, to.x - from.x)) }
        var path = Path()
        path.move(to: CGPoint(x: edge + (open ? 0 : 1), y: top.y))
        path.addLine(to: CGPoint(x: edge, y: top.y))
        path.addArc(center: top, radius: hollow, startAngle: .degrees(0), endAngle: angle(top, peak), clockwise: false)
        path.addArc(center: peak, radius: tip, startAngle: angle(peak, top), endAngle: angle(peak, bottom), clockwise: true)
        path.addArc(center: bottom, radius: hollow, startAngle: angle(bottom, peak), endAngle: .degrees(0), clockwise: false)
        guard !open else { return path }
        path.addLine(to: CGPoint(x: edge + 1, y: bottom.y))
        path.closeSubpath()
        return path
    }
}

/// The bar's surface, made as the window's outer rail's: the sidebar's material blurring what's behind, under a tint
/// (`Theme.barTint`) that keeps the rail's grey on a plain desktop but lets more of the wallpaper's colour through.
/// The material is shaped by its own mask image (`BarBlur`), never cut by a layer mask: cut that way
/// (SwiftUI's clip on it), it stops blurring what's behind and falls back to a flat grey, darker than the rail's.
/// Always active: the bar's panel is never the key window, and with the rail's follow-the-window state its blur would
/// always be the inactive one.
struct BarSurface<S: Shape>: View {
    let shape: S
    /// A colour over the surface, in the same cut (the waiting arc's blue).
    var colour: Color = .clear

    var body: some View {
        ZStack {
            BarBlur(shape: shape)
            Theme.barTint.clipShape(shape)
            colour.clipShape(shape)
        }
    }
}

/// The sidebar's material behind the window, shaped to `shape` by its mask image, redrawn as the view's size changes
/// and as the shape animates (a knob coming out), frame by frame.
private struct BarBlur<S: Shape>: NSViewRepresentable, Animatable {
    var shape: S

    var animatableData: S.AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    func makeNSView(context: Context) -> ShapedBlur {
        let view = ShapedBlur()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: ShapedBlur, context: Context) {
        let shape = shape
        view.outline = { shape.path(in: $0) }
        view.reshape()
    }
}

/// An effect view shaped by a mask image of its outline at its current size (top-left origin, as SwiftUI's).
final class ShapedBlur: NSVisualEffectView {
    var outline: (CGRect) -> Path = { Path($0) }

    override func layout() {
        super.layout()
        reshape()
    }

    func reshape() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let path = outline(CGRect(origin: .zero, size: size)).cgPath
        maskImage = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path).fill()
            return true
        }
    }
}
