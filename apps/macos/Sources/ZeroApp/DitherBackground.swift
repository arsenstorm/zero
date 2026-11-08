import AppKit
import MetalKit
import SwiftUI
import ZeroCore

/// The new task page's backdrop (ZeroCore's Dither), drawn by the GPU only when laid out or resized, never per frame.
struct DitherBackground: NSViewRepresentable {
    /// Where to frost, in the window (SwiftUI's global space, from its top left): the composer over it, drawn as the
    /// dots blur to; none, zero. Turned into the view's own place when drawn, by AppKit: worked out against a second
    /// measurement of the backdrop's frame, it came out 50 pt high (the backdrop reaching under the window's top).
    var frostInWindow = CGRect.zero
    /// Read so a change of appearance draws it again, on the new page colour.
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.frost = frostInWindow
        view.needsDisplay = true
    }

    func makeCoordinator() -> Renderer { Renderer() }

    final class Renderer: NSObject, MTKViewDelegate {
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var failed = false
        var frost = CGRect.zero

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            guard let device = view.device, prepare(device, view.colorPixelFormat), let pipeline, let queue,
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            let scale = Float(view.window?.backingScaleFactor ?? 2)
            let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // The composer's frost: its card's corners (26), fading back to dots over 4 pt beyond it. From the window's
            // top-left space to its content view's (flipped or not), into this view's, then from its top left.
            var frost = CGRect.zero
            if self.frost.width > 0, let content = view.window?.contentView {
                let top = content.isFlipped ? self.frost.minY : content.bounds.height - self.frost.maxY
                let inWindow = NSRect(x: self.frost.minX, y: top, width: self.frost.width, height: self.frost.height)
                let mine = view.convert(content.convert(inWindow, to: nil), from: nil)
                frost = CGRect(x: mine.minX, y: view.isFlipped ? mine.minY : view.bounds.height - mine.maxY, width: mine.width, height: mine.height)
            }
            var uniforms = Dither.Uniforms(size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)), cell: 3 * scale,
                                           dark: dark, ground: Theme.cardColor.resolved(in: view.effectiveAppearance),
                                           frost: SIMD4(Float(frost.minX), Float(frost.minY), Float(frost.width), Float(frost.height)) * scale,
                                           frostRadius: 26 * scale, feather: 4 * scale)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Dither.Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
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

private extension NSColor {
    /// The colour as the appearance gives it, as the shader's RGBA.
    func resolved(in appearance: NSAppearance) -> SIMD4<Float> {
        var rgba = SIMD4<Float>(0, 0, 0, 1)
        appearance.performAsCurrentDrawingAppearance {
            let c = usingColorSpace(.sRGB) ?? self
            rgba = SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
        }
        return rgba
    }
}
