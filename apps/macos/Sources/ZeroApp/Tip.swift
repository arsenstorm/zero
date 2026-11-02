import AppKit
import SwiftUI

extension View {
    /// Zero's own tooltip, in place of `.help`: SwiftUI's never showed in Zero's windows and panels, and is slow when it
    /// does. Codex's: a dark pill above the view (under it where the screen ends), with the view's shortcut as a key
    /// beside the words. Shown after a short rest, at once when moving on from another; gone when the pointer leaves
    /// or clicks. An empty text shows nothing.
    func tip(_ text: String, shortcut: String? = nil) -> some View { background(TipAnchor(text: text, shortcut: shortcut)) }
}

private struct TipAnchor: NSViewRepresentable {
    let text: String
    let shortcut: String?
    func makeNSView(context: Context) -> TipView { TipView() }
    func updateNSView(_ view: TipView, context: Context) { view.shortcut = shortcut; view.text = text }
    static func dismantleNSView(_ view: TipView, coordinator: ()) { view.leave() }
}

/// The view's frame, followed by a tracking area: tracking areas see the pointer whatever is drawn over them, so the
/// view takes no clicks of its own.
final class TipView: NSView {
    var text = "" {
        didSet {
            guard text != oldValue, TipPanel.shared.owner === self else { return }
            if text.isEmpty { leave() } else { TipPanel.shared.show(text, shortcut: shortcut, over: self) }
        }
    }
    var shortcut: String?
    private var pending: Task<Void, Never>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !text.isEmpty else { return }
        pending?.cancel()
        let wait = TipPanel.shared.recently ? 0 : 600
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self, self.window != nil, !self.text.isEmpty else { return }
            TipPanel.shared.show(self.text, shortcut: self.shortcut, over: self)
        }
    }

    override func mouseExited(with event: NSEvent) { leave() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { leave() }
    }

    func leave() {
        pending?.cancel()
        pending = nil
        TipPanel.shared.hide(from: self)
    }
}

/// The one tip on screen: a panel of its own, so no scroll view or rounded window clips it, and it shows over the
/// control bar's panels as over the window.
@MainActor final class TipPanel {
    static let shared = TipPanel()
    private(set) weak var owner: NSView?
    private var hiddenAt = Date.distantPast
    private var monitor: Any?
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }()

    /// A tip showing, or one just gone: the next shows at once, as moving along a row of buttons.
    var recently: Bool { panel.isVisible || Date().timeIntervalSince(hiddenAt) < 0.4 }

    func show(_ text: String, shortcut: String?, over view: NSView) {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        owner = view
        let host = NSHostingController(rootView: TipLabel(text: text, shortcut: shortcut))
        // At most 280 points of text to a line, the rest wrapped.
        // Its words wrapped at 300 points, as many lines as they need: never cut short.
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 2000))
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let room = screen.visibleFrame
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 6)
        if origin.y + size.height > room.maxY { origin.y = anchor.minY - size.height - 6 }
        origin.x = min(max(origin.x, room.minX + 4), room.maxX - size.width - 4)
        panel.contentView = host.view
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if monitor == nil {
            // A click or a scroll moves on from what the tip was about.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
                if let owner = self?.owner { self?.hide(from: owner) }
                return event
            }
        }
    }

    func hide(from view: NSView) {
        guard owner === view else { return }
        owner = nil
        panel.orderOut(nil)
        hiddenAt = Date()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

/// Codex's tooltip: light words on a dark pill in either appearance, and the shortcut, if any, on a key of its own.
private struct TipLabel: View {
    let text: String
    let shortcut: String?
    /// As wide as its words on one line, at most 300 points. Past that it wraps, its lines balanced: the narrowest width
    /// that keeps as few lines, so they come out alike and the tip holds no empty room beside the shorter one.
    private var width: CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5)
        let words = text as NSString
        let one = ceil(words.size(withAttributes: [.font: font]).width) + 1
        guard one > 300 else { return one }
        let lines = { (width: CGFloat) in
            Int((words.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
                                    attributes: [.font: font]).height / font.boundingRectForFont.height).rounded())
        }
        let most = lines(300)
        var (low, high) = (CGFloat(80), CGFloat(300))
        while high - low > 1 { let mid = (low + high) / 2; if lines(mid) > most { low = mid } else { high = mid } }
        return ceil(high) + 1
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12.5)).foregroundStyle(.white)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(width: width)
            if let shortcut {
                Text(shortcut).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        // Concentric: the key's 5 inside a 4 point inset at its height.
        .padding(.leading, 10).padding(.trailing, shortcut == nil ? 10 : 4).padding(.vertical, shortcut == nil ? 6 : 4)
        .background(Color(nsColor: NSColor(white: 0.17, alpha: 1)), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.08)))
    }
}
