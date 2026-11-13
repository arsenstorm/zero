import AppKit
import SwiftUI

/// A round button in one of the bar's hollows, where its curves meet the screen edge: the inbox in the top one, the
/// settings in the bottom one. In, only a thin arc of it shows, facing the bar; out, the arc thickens inward and wraps
/// round into the full button. Its outer edge never moves, so the gap to the bar stays even all the way (the hollow's
/// radius is the button's plus that gap).
struct BarKnob<Label: View>: View {
    /// In the top hollow (the arc faces down towards the bar) rather than the bottom one.
    var top = false
    /// Out as the full button; the pointer on it brings it out too.
    var out: Bool
    @ViewBuilder var label: (_ hovered: Bool) -> Label
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open: CGFloat = out || hovered ? 1 : 0
        ZStack {
            if reduceMotion {
                // Reduce Motion: the arc and the button cross-fade, and the icon only fades.
                seed(0).opacity(1 - open)
                seed(1).opacity(open)
                label(hovered).opacity(open)
            } else {
                seed(open)
                label(hovered).modifier(CarriedIcon(open: open, top: top))
            }
        }
        .frame(width: barKnob, height: barKnob)
        // One eased progress drives the ring and the icon together: ease-out-cubic, 220 ms out, 150 ms back in.
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.33, 1, 0.68, 1, duration: open == 1 ? 0.22 : 0.15),
            value: open
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func seed(_ open: CGFloat) -> some View {
        BarSeed(open: open, top: top).fill(Theme.pill)
            .overlay(BarSeed(open: open, top: top).stroke(Theme.stroke, lineWidth: 1))
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
    /// The bump's rounding, a circle touching both hollows on the screen's side of the buttons' axis.
    var tip: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let hollow = barKnob / 2 + 6, edge = rect.maxX, axis = rect.midX
        let top = CGPoint(x: axis, y: rect.minY + barKnob / 2), bottom = CGPoint(x: axis, y: rect.maxY - barKnob / 2)
        // The tip's circle touches both hollows: (x - axis)² + half² = (hollow + tip)², on the screen's side.
        let half = (bottom.y - top.y) / 2
        let peak = CGPoint(x: axis + max(0, (hollow + tip) * (hollow + tip) - half * half).squareRoot(), y: top.y + half)
        func angle(_ from: CGPoint, _ to: CGPoint) -> Angle { .radians(atan2(to.y - from.y, to.x - from.x)) }
        var path = Path()
        path.move(to: CGPoint(x: edge + 1, y: top.y))
        path.addLine(to: CGPoint(x: edge, y: top.y))
        path.addArc(center: top, radius: hollow, startAngle: .degrees(0), endAngle: angle(top, peak), clockwise: false)
        path.addArc(center: peak, radius: tip, startAngle: angle(peak, top), endAngle: angle(peak, bottom), clockwise: true)
        path.addArc(center: bottom, radius: hollow, startAngle: angle(bottom, peak), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: edge + 1, y: bottom.y))
        path.closeSubpath()
        return path
    }
}
