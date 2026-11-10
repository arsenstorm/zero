import AppKit
import SwiftUI

extension View {
    /// Zero's own tooltip, in place of `.help`: SwiftUI's never showed in Zero's windows and panels, and is slow when it
    /// does. Codex's: a dark pill above the view (under it where the screen ends), with the view's shortcut as a key
    /// beside the words. Shown after a short rest, at once when moving on from another; gone when the pointer leaves
    /// or clicks. An empty text shows nothing.
    func tip(_ text: String, shortcut: String? = nil) -> some View { modifier(Tipped(text: text, shortcut: shortcut)) }
}

/// The pointer on the view as SwiftUI sees it (its hover goes to what's on top, not to what's under a card or panel
/// drawn over it), and the view's frame in AppKit's terms, for where the tip goes.
private struct Tipped: ViewModifier {
    let text: String
    let shortcut: String?
    @State private var anchor = Anchor()
    final class Anchor { weak var view: TipView? }

    func body(content: Content) -> some View {
        content
            .background(TipAnchor(text: text, shortcut: shortcut, anchor: anchor))
            .onHover { [anchor] inside in if inside { anchor.view?.enter() } else { anchor.view?.leave() } }
    }
}

private struct TipAnchor: NSViewRepresentable {
    let text: String
    let shortcut: String?
    let anchor: Tipped.Anchor
    func makeNSView(context: Context) -> TipView { let view = TipView(); anchor.view = view; return view }
    func updateNSView(_ view: TipView, context: Context) { anchor.view = view; view.shortcut = shortcut; view.text = text }
    static func dismantleNSView(_ view: TipView, coordinator: ()) { view.leave() }
}

/// The view's frame, where the tip goes; told of the pointer by SwiftUI's hover. A tracking area saw the pointer
/// whatever was drawn over the view, and showed its tip under a card or panel that has none of its own. Takes no clicks.
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

    func enter() {
        guard !text.isEmpty, let window else { return }
        // Under Zero's dialog, a tip behind it stays hidden (the dialog is drawn in another layer of the window).
        let at = window.mouseLocationOutsideOfEventStream
        if let height = window.contentView?.bounds.height, !Dialogs.shared.allowsTip(at: CGPoint(x: at.x, y: height - at.y)) { return }
        pending?.cancel()
        let wait = TipPanel.shared.recently ? 0 : 600
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self, self.window != nil, !self.text.isEmpty else { return }
            TipPanel.shared.show(self.text, shortcut: self.shortcut, over: self)
        }
    }

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
        // Zero's window's tips while Zero is in front only: its views see the pointer through another app's window over
        // them, and a tip floats over every app. The control bar's panels (used from other apps) keep theirs.
        guard NSApp.isActive || window is NSPanel else { return }
        watchApp()
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
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) {
                [weak self] event in
                if let owner = self?.owner { self?.hide(from: owner) }
                return event
            }
        }
    }

    /// Zero going behind another app: its tip goes, as the pointer leaving would have taken it (switched away with the
    /// pointer still, it stayed over the other app).
    private var appWatch: Any?
    private func watchApp() {
        guard appWatch == nil else { return }
        appWatch = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            _ in
            MainActor.assumeIsolated {
                guard let owner = TipPanel.shared.owner, !(owner.window is NSPanel) else { return }
                TipPanel.shared.hide(from: owner)
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
            Int(
                (words.boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
                    attributes: [.font: font]
                ).height / font.boundingRectForFont.height).rounded())
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
