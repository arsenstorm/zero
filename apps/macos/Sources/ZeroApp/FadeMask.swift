import SwiftUI

/// The conversation's mask round what's docked at its foot (the composer, the queue's strip, the question card). Each
/// surface hides a column of the page: from its text's start to the same inset from its right, from just above its top
/// down to the window's foot, wholly. Above the column the page fades out over `above`, beside it over `beside` (into
/// the margins, which stay readable further out), both eased; where the two meet they multiply, so the corners round
/// off. SwiftUI-only, so it renders on its own (a check outside the app).
enum FadeMask {
    struct Surface {
        var frame: CGRect
        /// Its text's inset from its frame's sides: where the hidden column starts and ends.
        var inset: CGFloat
    }

    /// How far above a column the page starts fading, and how far into the margin beside its surface.
    static let above: CGFloat = 48
    static let beside: CGFloat = 28
    /// The column is hidden from this far above its surface's top.
    static let lead: CGFloat = 8

    /// The page shown (black) less each surface's column, its fades eased.
    static func draw(_ context: inout GraphicsContext, size: CGSize, surfaces: [Surface]) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        context.blendMode = .destinationOut
        for surface in surfaces where surface.frame.height > 0 && surface.frame.width > surface.inset * 2 {
            let top = surface.frame.minY - lead
            // From `beside` out in the margin to the column (its text's inset under the surface): eased in.
            let region = CGRect(
                x: surface.frame.minX - beside, y: top - above, width: surface.frame.width + beside * 2, height: size.height - top + above)
            // How hidden, across (1 in the column, eased to 0 in the margins) times down (eased in above it).
            let side = (beside + surface.inset) / region.width
            let across = ramp(from: 0, to: side) + ramp(from: 1 - side, to: 1, falling: true)
            let down = ramp(from: 0, to: above / region.height)
            context.drawLayer { layer in
                layer.fill(
                    Path(region),
                    with: .linearGradient(
                        Gradient(stops: across), startPoint: CGPoint(x: region.minX, y: 0), endPoint: CGPoint(x: region.maxX, y: 0)))
                layer.blendMode = .destinationIn
                layer.fill(
                    Path(region),
                    with: .linearGradient(
                        Gradient(stops: down), startPoint: CGPoint(x: 0, y: region.minY), endPoint: CGPoint(x: 0, y: region.maxY)))
            }
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
