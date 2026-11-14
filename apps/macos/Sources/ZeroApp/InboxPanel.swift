import AppKit
import SwiftUI
import ZeroCore

/// The bar and the inbox's panel beside it: placing them, opening, peeking and closing the inbox, and its keyboard.
extension AppDelegate {
    func makePanel(size: NSSize, content: NSView) -> Panel {
        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        pillHosting = FirstMouseHostingView(
            rootView: AnyView(
                PillView(
                    controller: inbox, settings: settings, workspace: workspace,
                    openInbox: { [weak self] in self?.pin(agent: nil) },
                    selectAgent: { [weak self] name in self?.pin(agent: name) },
                    moveHere: { [weak self] in
                        self?.pinnedDisplay = nil; self?.layout()
                    },
                    peek: { [weak self] agent in self?.peek(agent) },
                    openWorkspaces: { [weak self] in self?.pinWorkspaces() })))
        // Tall and transparent so the bar can morph inside it; the transparent rest is click-through.
        // Without clearing sizingOptions the hosting view shrinks the window to its content, top edge fixed.
        pillHosting.sizingOptions = []
        pill = makePanel(size: NSSize(width: 44, height: 600), content: pillHosting)
        pill.acceptsMouseMovedEvents = true
        let inboxView = NSHostingView(
            rootView: InboxView(controller: inbox)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing))
        inboxView.sizingOptions = []
        inboxPanel = makePanel(size: NSSize(width: 380, height: 600), content: inboxView)
        inboxPanel.acceptsMouseMovedEvents = true
        inboxPanel.allowsTextFocus = { [weak self] in
            guard let self else { return true }
            return inbox.focusedReply != nil
        }
        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.layout()
        }
    }

    /// The bar on screen, or put away with its panel, as Settings says; shown at once when switched back on.
    func showBar() {
        guard settings.showBar else {
            pill.orderOut(nil)
            if inboxPanel.isVisible { hideInbox() }
            return
        }
        if !pill.isVisible { pill.orderFrontRegardless() }
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
        // Without the bar, the window's inbox (the hotkey, a way back to an ask).
        guard settings.showBar else { inWindow(.inbox); return }
        layout()
        notifier?.lookedAtAsks()
        inbox.ensureSelection()
        openedByIntent = byIntent
        inbox.pinned = byIntent
        pointerWasInside = false
        if byIntent { inboxPanel.makeKeyAndOrderFront(nil) } else { inboxPanel.orderFrontRegardless() }
        inbox.panelOpen = true
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
        inbox.panelOpen = false
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
        if navigation.barDocked || !settings.showBar { agent.map(openAgent) ?? inWindow(.inbox); return }
        if openedByIntent && inboxPanel.isVisible && inbox.agentFilter == agent && !inbox.newAgentOpen { hideInbox(); return }
        inbox.show(agent: agent)
        open(byIntent: true)
    }

    /// The bar's control under the pointer opens its view: each control's slot spans the bar's width and meets
    /// its neighbours, so the pointer never has to find the dot itself.
    private func hoverBar(at mouse: NSPoint) {
        guard pill.isVisible, pill.frame.contains(mouse), NSEvent.pressedMouseButtons == 0 else { inbox.barHover = nil; return }
        // On the way into the open panel, what the pointer crosses doesn't take over (aimAtPanel).
        guard !inbox.barAiming else { return }
        let local = pill.convertPoint(fromScreen: mouse)
        let point = CGPoint(x: local.x, y: pill.frame.height - local.y) // SwiftUI's global space runs top down
        // Among the controls shown now, the one whose slot is nearest: slots meet, so a point on their seam is in two.
        let shown = Set(
            [InboxController.inboxSlot, InboxController.newSlot, InboxController.workspacesSlot, InboxController.settingsSlot]
                + inbox.barOrder)
        let under = inbox.barSlots.filter { shown.contains($0.key) && $0.value.insetBy(dx: -8, dy: -1).contains(point) }
            .min { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }?.key
        guard let under, under != inbox.barHover else { if under == nil { inbox.barHover = nil }; return }
        inbox.barHover = under
        switch under {
        case InboxController.inboxSlot: peek(nil)
        case InboxController.newSlot: peekNewAgent()
        case InboxController.workspacesSlot: peekWorkspaces()
        // Down to the bar's settings: a peeked inbox goes (one opened by a click stays).
        case InboxController.settingsSlot: if !openedByIntent && inboxPanel.isVisible { hideInbox() }
        default: peek(under)
        }
    }

    /// The bar's workspace control: the workspaces, in the inbox's pane, pinned open; again closes it. Hovered, a peek.
    private func pinWorkspaces() {
        if openedByIntent && inboxPanel.isVisible && inbox.workspacesOpen { hideInbox(); return }
        inbox.showWorkspaces()
        open(byIntent: true)
    }

    private func peekWorkspaces() {
        inbox.showWorkspaces()
        if !inboxPanel.isVisible { open(byIntent: false) }
        if !openedByIntent { syncKeyboard() }
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

    /// Entering the cards gives them the keyboard. A peeked inbox stays open while the pointer is on the bar or the
    /// cards' surface, or on its way from one to the other (MenuAim's triangle towards the surface); anywhere else,
    /// up the screen edge or away, it closes a moment later unless the pointer comes back.
    func trackPointer() {
        let mouse = NSEvent.mouseLocation
        let from = lastPointer
        lastPointer = mouse
        aimAtPanel(mouse, from: from)
        hoverBar(at: mouse)
        // "Follow the active screen": move whenever the pointer is on a different display than Zero.
        if settings.followActiveScreen, let here = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
            here.displayID != pinnedDisplay
        {
            layout()
            placeBar()
        }
        guard inboxPanel.isVisible else { return }
        if inboxHolds(mouse, from: from) {
            closingInbox?.cancel()
            closingInbox = nil
            // Pinned: the keyboard is taken only by a deliberate act (the pin click, a click into the inbox), never
            // by the pointer drifting back; otherwise typing elsewhere gets stolen mid-sentence.
            if !openedByIntent { syncKeyboard() }
        } else if !openedByIntent, inbox.selector == nil, closingInbox == nil {
            // An open selector keeps the inbox up wherever the pointer goes; a click elsewhere closes it.
            closingInbox = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                closingInbox = nil
                if !openedByIntent, inbox.selector == nil, !inboxHolds(NSEvent.mouseLocation, from: nil) { hideInbox() }
            }
        }
    }

    /// The pointer keeps the inbox: on the bar's drawn part or the cards' surface, or heading from `from` into it.
    private func inboxHolds(_ mouse: NSPoint, from: NSPoint?) -> Bool {
        guard inboxPanel.screen?.frame.contains(mouse) ?? false else { return false }
        let bar = NSRect(x: pill.frame.minX, y: pill.frame.midY - inbox.barHeight / 2, width: pill.frame.width, height: inbox.barHeight)
        return MenuAim.holds(mouse, from: from, bar: bar, panel: inboxSurface)
    }

    /// The cards' surface on screen.
    private var inboxSurface: NSRect {
        let s = inbox.surfaceFrame, panel = inboxPanel.frame
        return NSRect(x: panel.minX + s.minX, y: panel.maxY - s.maxY, width: s.width, height: s.height).intersection(panel)
    }

    /// On the bar with the panel open, a step heading into the cards (MenuAim's triangle) passes over the bar: the
    /// controls and buttons it crosses stay as they are (`barAiming`). Out of the triangle, or resting 150 ms (as
    /// Amazon's menus wait), the control under the pointer takes over.
    private func aimAtPanel(_ mouse: NSPoint, from: NSPoint?) {
        let aiming = inboxPanel.isVisible && pill.frame.contains(mouse) && MenuAim.passing(mouse, from: from, panel: inboxSurface)
        if inbox.barAiming != aiming { inbox.barAiming = aiming }
        guard aiming else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, lastPointer == mouse, inbox.barAiming else { return }
            inbox.barAiming = false
            hoverBar(at: mouse)
        }
    }
}
