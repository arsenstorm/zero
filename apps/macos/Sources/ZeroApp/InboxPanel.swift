import AppKit
import SwiftUI
import ZeroCore

/// The bar and the inbox's panel beside it: placing them, opening, peeking and closing the inbox, and its keyboard.
extension AppDelegate {
    func makePanel(size: NSSize, content: NSView) -> Panel {
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = content
        return panel
    }

    func makePanels() {
        pillHosting = FirstMouseHostingView(rootView: AnyView(PillView(
            controller: inbox, settings: settings, workspace: workspace,
            openInbox: { [weak self] in self?.pin(agent: nil) },
            selectAgent: { [weak self] name in self?.pin(agent: name) },
            moveHere: { [weak self] in self?.pinnedDisplay = nil; self?.layout() },
            peek: { [weak self] agent in self?.peek(agent) },
            openNewAgent: { [weak self] in self?.pinNewAgent() },
            peekNewAgent: { [weak self] in self?.peekNewAgent() })))
        // Tall and transparent so the bar can morph inside it; the transparent rest is click-through.
        // Without clearing sizingOptions the hosting view shrinks the window to its content, top edge fixed.
        pillHosting.sizingOptions = []
        pill = makePanel(size: NSSize(width: 44, height: 600), content: pillHosting)
        pill.acceptsMouseMovedEvents = true
        let inboxView = NSHostingView(rootView: InboxView(controller: inbox)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing))
        inboxView.sizingOptions = []
        inboxPanel = makePanel(size: NSSize(width: 380, height: 600), content: inboxView)
        inboxPanel.acceptsMouseMovedEvents = true
        inboxPanel.allowsTextFocus = { [weak self] in
            guard let self else { return true }
            return inbox.focusedReply != nil || inbox.dictatingFor != nil
        }
        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() }
        pill.orderFrontRegardless()
    }

    /// Panels stay on one screen (the one under the pointer when first shown, or chosen via "Move Zero to this
    /// screen") unless "Follow active screen" is on, in which case they go to the screen under the pointer.
    func layout() {
        let mouse = NSEvent.mouseLocation
        let pinned = NSScreen.screens.first { $0.displayID == pinnedDisplay }
        let underMouse = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen = settings.followActiveScreen ? underMouse : (pinned ?? underMouse) else { return }
        pinnedDisplay = screen.displayID
        let frame = screen.frame
        let visible = screen.visibleFrame
        let pillFrame = NSRect(x: frame.maxX - 44, y: frame.midY - 300, width: 44, height: 600)
        pill.setFrame(pillFrame, display: true)
        // The inbox is centred on the pill: symmetric above and below it, within the visible screen.
        let half = min(pillFrame.midY - visible.minY, visible.maxY - pillFrame.midY) - 8
        inboxPanel.setFrame(NSRect(x: frame.maxX - 380 - 56, y: pillFrame.midY - half, width: 380, height: half * 2), display: true)
    }

    /// Instant on purpose: the inbox is the most-used surface, and motion there would only slow it down.
    func open(byIntent: Bool) {
        layout()
        notifier?.lookedAtAsks()
        inbox.ensureSelection()
        openedByIntent = byIntent
        inbox.pinned = byIntent
        pointerWasInside = false
        if byIntent { inboxPanel.makeKeyAndOrderFront(nil) } else { inboxPanel.orderFrontRegardless() }
        inbox.requestScroll()
    }

    /// The panel takes keys without making Zero the active app, but dictation and clipboard tools (Raycast,
    /// macOS dictation) type or paste into the active app. While the user types in the inbox, Zero is that app.
    func activateForTyping() {
        guard !NSApp.isActive else { return }
        returnTo = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        keyboardFront = NSRunningApplication.current
        inboxPanel.makeKey()
    }

    func hideInbox() {
        inboxPanel.orderOut(nil)
        keyboardFront = nil
        inbox.newAgentOpen = false
        if let app = returnTo, NSApp.isActive, workspaceWindow?.isVisible != true, onboardingWindow?.isVisible != true {
            app.activate()
        }
        returnTo = nil
        inbox.agentFilter = nil
        openedByIntent = false
        inbox.pinned = false
        // Answered cards are dropped now, while hidden, so the next open starts clean on its first frame.
        inbox.inboxOpenedAt = Date()
    }

    /// A click on a pill control pins the inbox open on that view; the same click again unpins and closes it.
    func pin(agent: String?) {
        if navigation.barDocked { agent.map(openAgent) ?? inWindow(.inbox); return }
        if openedByIntent && inboxPanel.isVisible && inbox.agentFilter == agent && !inbox.newAgentOpen { hideInbox(); return }
        inbox.show(agent: agent)
        open(byIntent: true)
    }

    /// The bar's control under the pointer opens its view: each control's slot spans the bar's width and meets
    /// its neighbours, so the pointer never has to find the dot itself.
    private func hoverBar(at mouse: NSPoint) {
        guard pill.isVisible, pill.frame.contains(mouse), NSEvent.pressedMouseButtons == 0 else { inbox.barHover = nil; return }
        let local = pill.convertPoint(fromScreen: mouse)
        let point = CGPoint(x: local.x, y: pill.frame.height - local.y) // SwiftUI's global space runs top down
        // Among the controls shown now, the one whose slot is nearest: slots meet, so a point on their seam is in two.
        let shown = Set([InboxController.inboxSlot, InboxController.newSlot] + inbox.barOrder)
        let under = inbox.barSlots.filter { shown.contains($0.key) && $0.value.insetBy(dx: -8, dy: -1).contains(point) }
            .min { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }?.key
        guard let under, under != inbox.barHover else { if under == nil { inbox.barHover = nil }; return }
        inbox.barHover = under
        switch under {
        case InboxController.inboxSlot: peek(nil)
        case InboxController.newSlot: peekNewAgent()
        default: peek(under)
        }
    }

    /// The bar's + button: the new-agent composer, pinned open with the keyboard; again closes it.
    private func pinNewAgent() {
        if navigation.barDocked { inWindow(.home); return }
        if openedByIntent && inboxPanel.isVisible && inbox.newAgentOpen { hideInbox(); return }
        inbox.showNewAgent()
        open(byIntent: true)
        inbox.focusedReply = InboxController.newAgentKey
    }

    private func peekNewAgent() {
        inbox.showNewAgent()
        if !inboxPanel.isVisible { open(byIntent: false) }
        if !openedByIntent { syncKeyboard() }
    }

    /// Hovering a pill control peeks the inbox (open asks, or one agent). It takes the keyboard while open so 1, 2, 3
    /// answer straight away; the keyboard goes back to the previous window the moment the inbox closes.
    private func peek(_ agent: String?) {
        inbox.show(agent: agent)
        if !inboxPanel.isVisible { open(byIntent: false) }
        if !openedByIntent { syncKeyboard() }
    }

    /// The inbox takes the keyboard only when there is something to type into (or it was opened on purpose).
    /// It keeps it until it closes: handing it back mid-hover meant hiding and re-showing the panel, a visible flash.
    private func syncKeyboard() {
        guard inbox.takesKeys || openedByIntent, !inboxPanel.isKeyWindow else { return }
        // Another app came forward since the inbox took the keyboard (Raycast, Spotlight, a click elsewhere):
        // taking it back would close that app's window, so leave it until the inbox opens again.
        let front = NSWorkspace.shared.frontmostApplication
        if let owner = keyboardFront, front != owner, front != NSRunningApplication.current { return }
        keyboardFront = front
        inboxPanel.makeKey()
    }

    /// Entering the cards gives them the keyboard. While the inbox is open, the whole strip from its left edge to
    /// the screen edge is a safe zone (pill, gap, and the way up or down to the cards), so only moving left past
    /// the cards, or to another screen, closes it.
    func trackPointer() {
        let mouse = NSEvent.mouseLocation
        hoverBar(at: mouse)
        // "Follow the active screen": move whenever the pointer is on a different display than Zero.
        if settings.followActiveScreen, let here = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           here.displayID != pinnedDisplay {
            layout()
            placeBar()
        }
        guard inboxPanel.isVisible else { return }
        let onScreen = inboxPanel.screen?.frame.contains(mouse) ?? false
        let inSafeZone = onScreen && mouse.x >= inboxPanel.frame.minX
        if inSafeZone {
            // Pinned: the keyboard is taken only by a deliberate act (the pin click, a click into the inbox), never
            // by the pointer drifting back; otherwise typing elsewhere gets stolen mid-sentence.
            if !openedByIntent { syncKeyboard() }
        } else if inbox.dictatingFor == nil, !openedByIntent, inbox.selector == nil {
            // An open selector keeps the inbox up wherever the pointer goes; a click elsewhere closes it.
            hideInbox()
        }
    }
}
