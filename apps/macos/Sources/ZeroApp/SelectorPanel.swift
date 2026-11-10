import AppKit
import SwiftUI
import ZeroCore

/// The selector's panel, over the inbox or the workspace window.
extension AppDelegate {
    /// The selector is a panel of its own, so it can reach past the inbox's edges: the 240 pt list aligned with the
    /// chip and the 224 pt preview to its left, above the chip when there is room, otherwise below.
    func showSelector(anchorInInbox anchor: CGRect) {
        guard let selector = inbox.selector else { return }
        presentSelector(selector, chip: anchor, in: inboxPanel, centredOn: inboxPanel.frame)
    }

    /// The selector over any window, hung off the chip at `anchor` (its SwiftUI global frame in the window's
    /// content); the two-pane model selector centred on `centredOn`, else on the chip. With `returning`, that window
    /// gets the keys back when it closes (the workspace's composers).
    func presentSelector(
        _ selector: SelectorState, chip anchor: CGRect, in window: NSWindow, centredOn: NSRect? = nil, returning: NSWindow? = nil
    ) {
        guard let content = window.contentView else { return }
        hideSelector(keepState: true)
        selectorReturn = returning
        // SwiftUI's global frame is in the window's content, top-left origin; AppKit wants bottom-left.
        let appKit = NSRect(x: anchor.minX, y: content.bounds.height - anchor.maxY, width: anchor.width, height: anchor.height)
        let chip = window.convertToScreen(appKit)
        // A fixed, transparent strip below the chip (above it only when there is no room). The card inside is
        // anchored to the chip's edge, so a tab change grows or shrinks it from the far edge in the same frame,
        // with no window resizing and nothing moving underneath.
        let screen = window.screen?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let roomBelow = chip.minY - 6 - screen.minY
        let roomAbove = screen.maxY - chip.maxY - 6
        let opensBelow = roomBelow >= 240 || roomBelow >= roomAbove
        // Whole points: a fraction left the window between pixels, and the card's hairline at its top edge went when
        // a hover redrew part of it.
        let size = NSSize(width: SelectorView.width(selector.kind), height: min(480, opensBelow ? roomBelow : roomAbove).rounded(.down))
        // Projects hang off their chip; the two-pane model selector is centred on the inbox, overhanging it equally.
        let left = selector.kind == .runtime ? (centredOn ?? chip).midX - size.width / 2 : chip.minX
        let x = max(screen.minX + 8, min(left, screen.maxX - size.width - 8)).rounded()
        let y = (opensBelow ? chip.minY - 6 - size.height : chip.maxY + 6).rounded()
        let view = FirstMouseHostingView(
            rootView: AnyView(
                SelectorView(state: selector)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: opensBelow ? .top : .bottom)))
        view.sizingOptions = []
        // The animated layer is a plain container's, not the hosting view's: AppKit resets a hosting view's layer
        // geometry whenever SwiftUI lays out, which stutters a transform on it.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let panel = makePanel(size: size, content: container)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        container.layer?.opacity = 0 // invisible until the animation starts; the window's own alpha stays 1
        panel.makeKeyAndOrderFront(nil)
        panel.layoutIfNeeded() // the heavy first layout happens now, invisible, not inside the animation
        selectorPanel = panel
        selectorAnchor = CGPoint(x: chip.midX - x, y: opensBelow ? size.height : 0)
        DispatchQueue.main.async { [weak self, weak panel] in
            // One turn later the first frame is committed; the animation then has nothing to wait on.
            guard let self, let panel, selectorPanel === panel else { return }
            Self.animateSelector(panel, anchor: selectorAnchor, opening: true)
        }
        // A click anywhere but the card closes it: in another app (global), in Zero's other windows, or in the
        // strip's empty part (local).
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak selector] _ in
                selector?.close()
            })
        {
            selectorMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown,
            handler: { [weak self, weak selector] event in
                guard let self, let panel = selectorPanel else { return event }
                let y = event.locationInWindow.y, card = selector?.cardHeight ?? 0
                let inCard = opensBelow ? y >= panel.frame.height - card : y <= card
                if event.window !== panel || !inCard { selector?.close() }
                return event
            })
        {
            selectorMonitors.append(local)
        }
    }

    func hideSelector(keepState: Bool = false) {
        selectorMonitors.forEach { NSEvent.removeMonitor($0) }
        selectorMonitors.removeAll()
        if let panel = selectorPanel {
            Self.animateSelector(panel, anchor: selectorAnchor, opening: false) { panel.orderOut(nil) }
        }
        selectorPanel = nil
        guard !keepState else { return }
        if let back = selectorReturn { back.makeKey() } else if openedByIntent || inbox.takesKeys { inboxPanel.makeKey() }
        selectorReturn = nil
    }

    /// Emil's popover: fade with a scale from 0.95 at the trigger, ease-out in, faster ease-in out. (No nudge
    /// toward the trigger: the card sits flush with the strip's edge there, so a nudge pushed it out of the
    /// window and its top border vanished for the first frames.)
    /// faster ease-in out. One Core Animation group on the content layer, so both run on the render server in
    /// step; a window-alpha fade is an AppKit timer animation and starts a frame late.
    private static func animateSelector(_ panel: NSWindow, anchor: CGPoint, opening: Bool, completion: (() -> Void)? = nil) {
        guard let layer = panel.contentView?.layer else { completion?(); return }
        // AppKit gives a view's layer an anchor point of (0, 0), so the pivot is measured from the bottom-left,
        // not the centre (verified; measuring from the centre put the pivot half a width to the left).
        var small = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        small = CATransform3DScale(small, 0.95, 0.95, 1)
        small = CATransform3DTranslate(small, -anchor.x, -anchor.y, 0)
        let (from, to) = opening ? (small, CATransform3DIdentity) : (CATransform3DIdentity, small)
        let duration = opening ? 0.12 : 0.08
        let curve = opening ? CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1) : CAMediaTimingFunction(name: .easeIn)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = from
        scale.toValue = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opening ? 0 : 1
        fade.toValue = opening ? 1 : 0
        // The children need the duration too: a group's duration only clips them, and a child without its own
        // runs Core Animation's default 0.25 s, so at 0.1 s it was cut off part-way and snapped to the end.
        for child in [scale, fade] { child.duration = duration; child.timingFunction = curve }
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        layer.add(group, forKey: "selector")
        layer.transform = to
        layer.opacity = opening ? 1 : 0
        CATransaction.commit()
    }
}
