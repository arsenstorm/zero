import SwiftUI
import UIKit

/// The Mac's spinner (ZeroApp's Spinner): an arc turning once a second, driven by Core Animation so a busy main thread
/// can't stall it; a plain dot under Reduce Motion.
struct Spinner: View {
    var color: Color = .blue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion { Circle().fill(color) } else { SpinnerLayer(color: UIColor(color)) }
    }
}

private struct SpinnerLayer: UIViewRepresentable {
    let color: UIColor
    func makeUIView(context: Context) -> SpinnerView { SpinnerView() }
    func updateUIView(_ view: SpinnerView, context: Context) { view.color = color }
}

final class SpinnerView: UIView {
    var color: UIColor = .systemBlue { didSet { arc.strokeColor = color.resolvedColor(with: traitCollection).cgColor } }
    private let arc = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        arc.fillColor = nil
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeStart = 0.15
        layer.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        arc.strokeColor = color.resolvedColor(with: traitCollection).cgColor
        spin()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); spin() }

    /// One turn a second, clockwise; added again when the view comes back on screen, as Core Animation drops it.
    private func spin() {
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: "spin")
    }
}
