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
        // Another menu open until this very click (closed by it, or just now): this one takes its place as it is, as
        // Linear's do, with no animation.
        let switching = selectorLeaving != nil
        // The tip of the control that opened it goes, and none shows outside the menu while it's open (TipPanel.show).
        TipPanel.shared.hideAny()
        TaskPeek.shared.close() // a task's card too, as a tip (and none shows while it's open: TaskPeek.hover)
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
        // The strip and room around it for the card's shadow (none for the runtime selector, which has none).
        let pad = SelectorView.shadowRoom(selector.kind)
        let strip = NSSize(width: SelectorView.width(selector), height: min(480, opensBelow ? roomBelow : roomAbove).rounded(.down))
        // And room to its right for a row's own menu, when a row has one.
        let room = SelectorView.submenuRoom(selector)
        let size = NSSize(width: strip.width + room + 2 * pad, height: strip.height + 2 * pad)
        // Projects hang off their chip; the two-pane model selector is centred on the inbox, overhanging it equally.
        // An anchor as wide as a menu is the menu's own place (beside a button, its right edge on the button's): a menu
        // wider than that grows to the left from it. A narrower one (the pointer) hangs the menu off its left.
        let left =
            selector.kind == .runtime
            ? (centredOn ?? chip).midX - strip.width / 2
            : selector.kind == .menu && chip.width >= SelectorView.width(.menu) ? chip.maxX - strip.width : chip.minX
        // No room on the right for a row's own menu: it opens on the left, and the card stays where it hangs.
        selector.submenuLeading = room > 0 && left + strip.width + room + 8 > screen.maxX
        let x =
            selector.submenuLeading
            ? (max(screen.minX + 8 + room, min(left, screen.maxX - strip.width - 8)) - room).rounded() - pad
            : max(screen.minX + 8, min(left, screen.maxX - strip.width - room - 8)).rounded() - pad
        let y = (opensBelow ? chip.minY - 6 - strip.height : chip.maxY + 6).rounded() - pad
        let root = AnyView(
            SelectorView(state: selector)
                .frame(
                    maxWidth: .infinity, maxHeight: .infinity,
                    alignment: selector.submenuLeading
                        ? (opensBelow ? .topTrailing : .bottomTrailing) : (opensBelow ? .topLeading : .bottomLeading)
                ).padding(pad)
                .id(ObjectIdentifier(selector))) // a new menu's own state (its focus, its first highlight), not the last one's
        let panel = selectorWindow(root)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        // Drawn and handed to the window server while still out of sight: ordered in, it shows this menu at once, never
        // the last one's picture at the new place.
        panel.layoutIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        panel.makeKeyAndOrderFront(nil)
        // The last menu goes only now, in the same instant as this one shows: no frame without a menu, none with two
        // (measured with the window server's list every millisecond).
        if let leaving = selectorLeaving, leaving !== panel { leaving.orderOut(nil) }
        selectorLeaving = nil
        selectorPanel = panel
        // At the pointer (a right click), it's there at once, as a Mac's are; off a button, a quick ease out of it,
        // scaled from the chip's point (bottom-left origin).
        if chip.width > 1, !switching {
            Self.animateSelector(panel, anchor: CGPoint(x: chip.midX - x, y: opensBelow ? size.height - pad : pad))
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
        // A right click elsewhere closes it too; on something with a menu of its own, that one opens in its place.
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self, weak selector] event in
                guard let self, let panel = selectorPanel else { return event }
                // On the card or its open submenu (their frames top left origin, as SwiftUI gives them).
                let at = CGPoint(x: event.locationInWindow.x, y: panel.frame.height - event.locationInWindow.y)
                let inCard = selector.map { $0.cardFrame.contains(at) || $0.submenuFrame?.contains(at) == true } ?? false
                if event.window !== panel || !inCard { selector?.close() }
                return event
            })
        {
            selectorMonitors.append(local)
        }
        if selector.kind == .menu, NSEvent.pressedMouseButtons & 0b10 != 0 { followRightDrag(selector) }
    }

    /// A menu opened by a right click still held: as the pointer moves with the button down (which hover doesn't
    /// follow: the drag belongs to the window it started in), the row under it is highlighted, and letting go on one
    /// picks it, as a Mac's and Linear's menus do. Let go where it opened (a plain right click), it stays open.
    private func followRightDrag(_ selector: SelectorState) {
        final class Moved { var far = false }
        let start = NSEvent.mouseLocation, moved = Moved()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDragged, .rightMouseUp]) { [weak self, weak selector] event in
            guard let self, let panel = selectorPanel, let selector else { return event }
            let screen = NSEvent.mouseLocation
            if hypot(screen.x - start.x, screen.y - start.y) > 4 { moved.far = true }
            let point = panel.convertPoint(fromScreen: screen)
            let top = CGPoint(x: point.x, y: panel.frame.height - point.y)
            // The menu's rows, and those of the submenu open beside it (only that one: others' frames are stale).
            let rows = selector.sections.flatMap(\.rows)
            let open = rows.first { $0.id == selector.submenu }?.children ?? []
            let row = (rows + open).first { selector.rowFrames[$0.id]?.contains(top) == true }
            if event.type == .rightMouseDragged {
                if let row, selector.highlighted != row.id { selector.highlighted = row.id }
                // Onto a row of the menu itself: its own menu opens, any other closes.
                if let row, rows.contains(where: { $0.id == row.id }) {
                    let submenu = row.children.isEmpty ? nil : row.id
                    if selector.submenu != submenu { selector.submenu = submenu }
                }
            } else if moved.far, let row, row.children.isEmpty {
                row.pick()
                selector.close()
            }
            return event
        }
        if let monitor { selectorMonitors.append(monitor) }
    }

    func hideSelector(keepState: Bool = false) {
        selectorMonitors.forEach { NSEvent.removeMonitor($0) }
        selectorMonitors.removeAll()
        // Gone with no exit, at the end of this turn: a menu the same click opens shows in its place first
        // (presentSelector); else it's taken away before the next frame is drawn.
        if let panel = selectorPanel {
            selectorLeaving = panel
            DispatchQueue.main.async { [weak self] in
                guard let self, let leaving = selectorLeaving else { return }
                leaving.orderOut(nil)
                selectorLeaving = nil
            }
        }
        selectorPanel = nil
        guard !keepState else { return }
        if let back = selectorReturn { back.makeKey() } else if openedByIntent || inbox.takesKeys { inboxPanel.makeKey() }
        selectorReturn = nil
    }

    /// The panel a menu opens in: of the two, made once each, the one out of sight, so a switch draws the new menu
    /// before the old one goes; only their content changes.
    private func selectorWindow(_ root: AnyView) -> Panel {
        if let host = selectorHosts.first(where: { !$0.panel.isVisible }) ?? (selectorHosts.count == 2 ? selectorHosts.first : nil) {
            host.view.rootView = root
            return host.panel
        }
        let view = FirstMouseHostingView(rootView: root)
        view.sizingOptions = []
        // The animated layer is a plain container's, not the hosting view's: AppKit resets a hosting view's layer
        // geometry whenever SwiftUI lays out, which stutters a transform on it.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.wantsLayer = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let panel = makePanel(size: container.frame.size, content: container)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // AppKit's own window animation off: by default a panel zooms in as it's ordered in and fades and drifts out
        // over ~70 ms as it's ordered out, a ghost of the menu where it was.
        panel.animationBehavior = .none
        selectorHosts.append((panel, view))
        return panel
    }

    /// Emil's popover, short: a fade with a scale from 0.97 at the trigger, 100 ms of a strong ease-out, so it's
    /// mostly there in the first frames. One Core Animation group on the content layer, so both run on the render
    /// server in step. Only the fade with Reduce Motion (Motion).
    private static func animateSelector(_ panel: NSWindow, anchor: CGPoint) {
        guard let layer = panel.contentView?.layer else { return }
        // AppKit gives a view's layer an anchor point of (0, 0), so the pivot is measured from the bottom-left,
        // not the centre (verified; measuring from the centre put the pivot half a width to the left).
        var small = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        small = CATransform3DScale(small, 0.97, 0.97, 1)
        small = CATransform3DTranslate(small, -anchor.x, -anchor.y, 0)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = small
        scale.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        // The children need the duration too: a group's duration only clips them, and a child without its own
        // runs Core Animation's default 0.25 s, so it was cut off part-way and snapped to the end.
        let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        let parts = Motion.reduced ? [fade] : [scale, fade]
        for child in parts { child.duration = 0.1; child.timingFunction = curve }
        let group = CAAnimationGroup()
        group.animations = parts
        group.duration = 0.1
        layer.add(group, forKey: "selector")
    }
}
