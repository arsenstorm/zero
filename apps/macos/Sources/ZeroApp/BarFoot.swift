import AppKit
import SwiftUI

/// The bar's settings button, in the hollow of its foot. Resting, only a thin arc of it shows, facing the hollow; with
/// the pointer on the bar the arc thickens inward and wraps round into the full button. Its outer edge never moves,
/// so the gap to the bar stays even all the way (the hollow's radius is the button's plus that gap).
struct BarFoot: View {
    /// The pointer is on the bar: the button comes out.
    var barHovered: Bool
    /// The inbox's panel is open beside the bar: the button stays in.
    var away = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 32

    /// Settings › Inbox and bar, as the bar's "Customise bar…" opens it.
    static func customise() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        app.navigation.settingsPage = SettingsView.Page.inbox.rawValue
        app.openSettings()
    }

    var body: some View {
        let open: CGFloat = !away && (barHovered || hovered) ? 1 : 0
        ZStack {
            // Reduce Motion: the arc and the button cross-fade instead of morphing.
            if reduceMotion {
                seed(0).opacity(1 - open)
                seed(1).opacity(open)
            } else {
                seed(open)
            }
            NucleoIcon("gear", size: 15)
                .foregroundStyle(hovered ? .primary : .secondary)
                .scaleEffect(reduceMotion ? 1 : 0.8 + 0.2 * open)
                .opacity(open)
        }
        .frame(width: Self.size, height: Self.size)
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.2), value: open)
        .contentShape(Circle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: Self.customise)
        .tip("Customise bar")
        .accessibilityElement()
        .accessibilityLabel("Customise bar")
        .accessibilityAddTraits(.isButton)
    }

    private func seed(_ open: CGFloat) -> some View {
        BarSeed(open: open).fill(Theme.pill).overlay(BarSeed(open: open).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// The button's outline as a ring: at 0 a 100° arc, 3 pt thick, along its edge facing the hollow (up and towards the
/// screen edge); at 1 the whole disc. The ring's outer radius stays put while it widens inward and its ends wrap round.
struct BarSeed: Shape {
    var open: CGFloat

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2, thin: CGFloat = 3
        let width = thin + (radius - thin) * open
        let half = 50 + 130 * open // degrees either side of the arc's middle, up and right
        var arc = Path()
        arc.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: radius - width / 2,
            startAngle: .degrees(-45 - half), endAngle: .degrees(-45 + half), clockwise: false)
        // Normalised: the round caps overlap once the ends meet, and the border would trace the seams.
        return arc.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round)).normalized(eoFill: false)
    }
}
