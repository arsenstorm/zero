import SwiftUI

/// The conversation's mask round what's docked at its foot (the composer, the queue's strip, the question card). Each
/// surface hides a column of the page: from its text's start to the same inset from its right, from its top down to
/// the window's foot, wholly. Down the column the page fades out over the surface's `fade` (eased, from its top: for
/// what's docked, as it does beside it; under its edge to its text for the composer), and beside it over `beside`
/// (into the margins, which stay readable further out), eased in over the same `fade` so it wraps the corners; where the two meet they multiply, so
/// the corners round off. The margins beside them fade out from the highest one's top (the card, else the strip, else
/// the composer) to the window's foot. SwiftUI-only, so it renders on its own (a check outside the app).
enum FadeMask {
    struct Surface {
        var frame: CGRect
        /// Its text's inset from its frame's sides: where the hidden column starts and ends.
        var inset: CGFloat
        /// Where the page fades out, from its top: readable at the first, hidden at the second.
        var fade: ClosedRange<CGFloat> = 0...16
        /// How much it hides: less as it fades out (a card answered), so the page comes back with it.
        var strength: CGFloat = 1
    }

    /// How far into the margin beside a surface the page fades.
    static let beside: CGFloat = 28

    /// The page shown (black) less each surface's column, its fades eased.
    static func draw(_ context: inout GraphicsContext, size: CGSize, surfaces: [Surface]) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        context.blendMode = .destinationOut
        let shown = surfaces.filter { $0.frame.height > 0 && $0.frame.width > $0.inset * 2 && $0.strength > 0 }
        for surface in shown {
            let top = surface.frame.minY + surface.fade.lowerBound
            let fade = surface.fade.upperBound - surface.fade.lowerBound
            // From `beside` out in the margin to the column (its text's inset under the surface): eased in.
            let region = CGRect(
                x: surface.frame.minX - beside, y: top, width: surface.frame.width + beside * 2, height: size.height - top)
            // How hidden, across (1 in the column, eased to 0 in the margins) times down (eased in over its fade).
            let side = (beside + surface.inset) / region.width
            let across = ramp(from: 0, to: side) + ramp(from: 1 - side, to: 1, falling: true)
            let down = ramp(from: 0, to: fade / region.height)
            var context = context
            context.opacity = surface.strength
            context.drawLayer { layer in
                layer.fill(
                    Path(region),
                    with: .linearGradient(
                        Gradient(stops: across), startPoint: CGPoint(x: region.minX, y: 0), endPoint: CGPoint(x: region.maxX, y: 0)))
                layer.blendMode = .destinationIn
                // A point past the first fill on every side: on its edge (a fraction of a pixel, as frames are), the
                // part of the edge pixel it didn't cover kept the first fill whole, a hairline along the band's top.
                layer.fill(
                    Path(region.insetBy(dx: -1, dy: -1)),
                    with: .linearGradient(
                        Gradient(stops: down), startPoint: CGPoint(x: 0, y: region.minY), endPoint: CGPoint(x: 0, y: region.maxY)))
            }
        }
        // The margins beside what's docked: readable where the highest one's fade starts, gone by the window's foot. One
        // fading out moves that start back down to the next one's as it goes.
        let start = { (surface: Surface) in surface.frame.minY + surface.fade.lowerBound }
        let whole = shown.filter { $0.strength >= 1 }.map(start).min() ?? size.height
        let top = shown.filter { $0.strength < 1 }.reduce(whole) { top, surface in min(top, top + (start(surface) - top) * surface.strength)
        }
        if top < size.height {
            context.fill(
                Path(CGRect(x: 0, y: top, width: size.width, height: size.height - top)),
                with: .linearGradient(
                    Gradient(stops: ramp(from: 0, to: 1)), startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: size.height)))
        }
    }

    /// Black's alpha rising (or falling) on smoothstep between two places in a gradient, held either side.
    private static func ramp(from start: CGFloat, to end: CGFloat, falling: Bool = false) -> [Gradient.Stop] {
        (0...8).map { step in
            let t = Double(step) / 8
            let eased = t * t * (3 - 2 * t)
            return Gradient.Stop(color: .black.opacity(falling ? 1 - eased : eased), location: start + (end - start) * t)
        }
    }
}
