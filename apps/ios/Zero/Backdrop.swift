import MetalKit
import SwiftUI
import UIKit

/// ZeroCore's dithered backdrop on the phone. It comes in once, its dots arriving in a sweep, then holds still: nothing
/// is drawn again until its size or appearance changes.
struct DitherBackdrop: UIViewRepresentable {
    /// Coming in (its dots sweeping in), or there already (drawn whole at once).
    var animated = true
    /// Read so a change of appearance draws it again, on the new background.
    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = true
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) { view.setNeedsDisplay() }

    func makeCoordinator() -> Renderer { Renderer(animated: animated) }

    final class Renderer: NSObject, MTKViewDelegate {
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var failed = false
        private var started: CFTimeInterval?
        private let animated: Bool
        init(animated: Bool) { self.animated = animated }
        private let duration: CFTimeInterval = 2.4

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

        func draw(in view: MTKView) {
            guard let device = view.device, prepare(device, view.colorPixelFormat), let pipeline, let queue,
                let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
            else { return }
            let now = CACurrentMediaTime()
            if started == nil { started = now }
            let t = UIAccessibility.isReduceMotionEnabled || !animated ? 1 : min(1, (now - started!) / duration)
            let traits = view.traitCollection
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor.systemBackground.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            var uniforms = Dither.Uniforms(
                size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                cell: 3 * Float(view.contentScaleFactor), dark: traits.userInterfaceStyle == .dark,
                ground: SIMD4(Float(r), Float(g), Float(b), 1), reveal: Float(t * t * (3 - 2 * t)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Dither.Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
            // In: from here on it's drawn only when asked (a new size or appearance).
            if t >= 1 && !view.isPaused {
                view.isPaused = true
                view.enableSetNeedsDisplay = true
            }
        }

        private func prepare(_ device: MTLDevice, _ format: MTLPixelFormat) -> Bool {
            if pipeline != nil { return true }
            if failed { return false }
            do {
                let library = try device.makeLibrary(source: Dither.shader, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "dither_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "dither_fragment")
                descriptor.colorAttachments[0].pixelFormat = format
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                queue = device.makeCommandQueue()
                return true
            } catch {
                failed = true
                return false
            }
        }
    }
}

/// The inbox with nothing in it: its words straight away, the backdrop coming in behind them. Over the list, letting touches through so
/// pulling to refresh still works.
struct EmptyInbox: View {
    /// The inbox is the page shown, nothing open over it.
    let shown: Bool
    /// An arrival not yet seen: the inbox has just emptied (or the app has just opened on it). It plays once, as the
    /// inbox comes into view with the app open, then never again until the inbox fills and empties once more:
    /// leaving the app and coming back, or another page and back, shows it already there.
    @Binding var pending: Bool
    @Environment(\.scenePhase) private var phase
    /// Each play a new arrival from its start; none yet, the backdrop drawn whole.
    @State private var plays = 0

    var body: some View {
        ZStack {
            // Waiting to be seen: nothing drawn, so it's not spent where it can't be.
            if !pending || plays > 0 { Arrival(animated: plays > 0).id(plays).allowsHitTesting(false) }
        }
        .onChange(of: pending && shown && phase == .active, initial: true) { _, now in
            guard now else { return }
            pending = false
            plays += 1
        }
    }

    private struct Arrival: View {
        var animated = true
        @State private var shown = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            ZStack {
                DitherBackdrop(animated: animated).ignoresSafeArea()
                // A third of the way down, on the sky above the glow, not in the middle where the planet's edge runs.
                VStack(spacing: 0) {
                    Spacer()
                    ContentUnavailableView {
                        Label {
                            Text("You're all caught up")
                        } icon: {
                            Image("inbox-glyph").resizable().frame(width: 28, height: 28)
                        }
                    } description: {
                        Text("Asks, steps for you and unread replies show here.")
                            .foregroundStyle(scheme == .dark ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    // Over the dots, the words need an edge of their own.
                    .foregroundStyle(scheme == .dark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .modifier(Halo(color: scheme == .dark ? .black : .white, strength: scheme == .dark ? 0.25 : 1))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : 8)
                    Spacer()
                    Spacer()
                }
            }
            .onAppear {
                if animated { withAnimation(.easeOut(duration: 0.35).delay(reduceMotion ? 0 : 0.1)) { shown = true } } else { shown = true }
            }
        }
    }
}

/// A halo of the page's own colour around words over the dots. One shadow is only as strong as the thin strokes casting
/// it, so it all but vanished; each shadow here falls on the last, wider every time, and together they clear the dots
/// close around the letters and fade out beyond.
/// Lighter on the dark page (`strength`), where the white words already stand off the dots and a full black halo
/// read as a heavy shadow.
struct Halo: ViewModifier {
    let color: Color
    var strength: Double = 1
    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(strength), radius: 1)
            .shadow(color: color.opacity(strength), radius: 2)
            .shadow(color: color.opacity(strength), radius: 4)
            .shadow(color: color.opacity(strength), radius: 8)
            .shadow(color: color.opacity(0.8 * strength), radius: 16)
    }
}
