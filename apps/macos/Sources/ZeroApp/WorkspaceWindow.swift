import AppKit
import SwiftUI
import ZeroCore

/// The workspace window, and the bar docked in it.
extension AppDelegate {
    /// The workspace window's frame as last placed, in screen points.
    private static let frameKey = "workspaceFrame"

    /// Another app's window covers a whole screen, menu bar and all: it's in full screen there.
    static func anotherAppFillsTheScreen() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        let screens = NSScreen.screens.map(\.frame.size)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) != me, (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { return false }
            return screens.contains { $0.width == bounds["Width"] && $0.height == bounds["Height"] }
        }
    }

    @objc func openWorkspace() { showWorkspace(activating: true) }

    /// Shown without `activating`: in front where you are, not taking the keyboard from what you're in.
    func showWorkspace(activating: Bool) {
        if workspaceWindow == nil {
            let view = WorkspaceView(workspace: workspace, navigation: navigation, inbox: inbox) { [unowned self] in
                SettingsView(
                    settings: settings, store: store, inbox: inbox, workspace: workspace, navigation: navigation,
                    showOnboarding: { [weak self] in self?.openOnboarding() })
            }
            let host = NSHostingController(rootView: view)
            host.sizingOptions = []
            #if ZERO_DEV
                let window: NSWindow = DevWindow(contentViewController: host)
            #else
                let window = NSWindow(contentViewController: host)
            #endif
            window.title = "Zero"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // A compact toolbar, as Codex has: it sets the window's buttons in from the corner and carries back and
            // forward beside them.
            let toolbar = NSToolbar(identifier: "Workspace")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.titlebarSeparatorStyle = .none
            window.setContentSize(NSSize(width: 1100, height: 720))
            // The window no narrower than its view lays out (WorkspaceView's 980 × 600): with sizing left to the window
            // (sizingOptions), it could be dragged or tiled narrower, and the view, still 980 wide, was cut off at both
            // sides.
            window.contentMinSize = NSSize(width: 980, height: 600)
            window.isReleasedWhenClosed = false
            // Where it was last time, on whichever screen, at whatever size; centred only the first time ever. Zero's
            // own record, not AppKit's autosave: that one matches the saved screen's shape to the screens at launch,
            // and on a mismatch (a second display's menu bar or Dock still settling) moves the window to the main
            // screen and saves that in its place.
            let saved = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString)
            if var saved, !saved.isEmpty, NSScreen.screens.contains(where: { $0.frame.intersects(saved) }) {
                // Kept from when it could be narrower: no smaller than it may be now.
                let least = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
                saved.size = NSSize(width: max(saved.width, least.width), height: max(saved.height, least.height))
                window.setFrame(saved, display: false)
            } else {
                window.center()
            }
            for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    guard let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
                    UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
                }
            }
            window.acceptsMouseMovedEvents = true
            workspaceWindow = window
            // Filling the screen (or leaving it), the bar moves into the window or back out to the screen's edge.
            let changes: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
                NSWindow.willCloseNotification,
            ]
            // On screen or not (closed, minimised, covered): conversations behind it stop being redrawn meanwhile.
            for name in [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
            ] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [navigation, weak window] note in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        // The window you're in is on screen, whatever the last occlusion notice said (one missed, waking
                        // from a locked screen, left it off screen with every conversation in it unchanged).
                        let shown =
                            note.name != NSWindow.willCloseNotification && window.isVisible && !window.isMiniaturized
                            && (window.occlusionState.contains(.visible) || window.isKeyWindow)
                        if navigation.windowShown != shown { navigation.windowShown = shown }
                    }
                }
            }
            // Closed by you, it stays closed next launch; open when Zero quits (an update, a crash), it opens again.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                UserDefaults.standard.set(false, forKey: "workspaceOpen")
            }
            for name in changes {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // After a close has happened, not while it's under way.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.placeBar() } }
                }
            }
            // Wherever the window goes (moved, resized, minimised, closed, covered, brought forward), the bar joins its
            // right rail strip or lets go of it (`trackBarJoin`): as it moves during a drag, after a close.
            for name in changes + [
                NSWindow.didMoveNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
            ] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        // Moved or resized: at once, in the same pass as the window. Closing: let go first.
                        if note.name == NSWindow.willCloseNotification { self?.letGoOfWindow() }
                        if [NSWindow.didMoveNotification, NSWindow.didResizeNotification].contains(note.name) { self?.trackBarJoin() }
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackBarJoin() } }
                    }
                }
            }
            // Going to the Dock takes its children along: the bar lets go before it does.
            NotificationCenter.default.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.letGoOfWindow() }
            }
        }
        NSApp.setActivationPolicy(.regular)
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            workspaceWindow?.makeKeyAndOrderFront(nil)
        } else {
            workspaceWindow?.orderFront(nil)
        }
        UserDefaults.standard.set(true, forKey: "workspaceOpen")
        placeBar()
    }

    /// The bar works with the window when it fills its screen (zoomed or full screen), or as Settings says: it stays the
    /// same bar, held to the screen's edge (so nothing moves as the window does), and peeks its panel on hover as ever,
    /// but a click opens in the window.
    /// Closed or minimised, the window gives the bar back its panel.
    func placeBar() {
        guard pill != nil else { return }
        let shown = workspaceWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let fills: Bool = {
            guard shown, let window = workspaceWindow, let screen = window.screen else { return false }
            if window.styleMask.contains(.fullScreen) { return true }
            let visible = screen.visibleFrame
            return abs(window.frame.width - visible.width) < 4 && abs(window.frame.height - visible.height) < 4
        }()
        // Following the active screen, the bar leaves the window for another screen the pointer is on (a full-screen
        // window's included), and comes back with it.
        let mouse = NSEvent.mouseLocation
        let elsewhere =
            settings.followActiveScreen && NSScreen.screens.first { $0.frame.contains(mouse) }.map { $0 != workspaceWindow?.screen } == true
        let wanted =
            switch settings.barDock {
            case .auto: fills;
            case .always: shown;
            case .never: false
            }
        let docked = wanted && !elsewhere
        guard docked != navigation.barDocked else { return }
        navigation.barDocked = docked
        if docked { hideInbox() }
    }

    /// Docked, a click on the bar opens its place in the window, brought forward; hovering still peeks the panel, as
    /// the bar always has, and the click puts the peek away.
    func inWindow(_ place: Navigation.Place) {
        hideInbox()
        navigation.place = place
        openWorkspace()
    }

    /// The bar's join to Zero's window (`InboxController.barJoin`): with the window's right edge at the bar's screen
    /// edge, and the window on screen beside the whole bar, the bar's panel moves 4 pt in, its base on the window's
    /// right rail strip (WorkspaceView's 4 pt between its page and its edge), and grows out of it.
    ///
    /// Joined, the panel is the window's child: the window server moves the two together, in the same frame, so a
    /// drag or a snap never parts them (the bar following the window's move notices was always a frame or more late,
    /// a gap opening between them as the window moved). Only its height, the screen's, is put back on a vertical move,
    /// and its place on a live resize from the window's right edge (which moves that edge, not the child). Dragged 12
    /// pt away it lets go, back to the screen's edge on the bar's curve.
    ///
    /// The bar's screen is the one `layout` chose (`pinnedDisplay`), never the panel's own: joined, the panel goes
    /// wherever the window takes it, and would hold the bar to the window's screen.
    func trackBarJoin(eased: Bool = true) {
        let chosen = NSScreen.screens.first { $0.displayID == pinnedDisplay }
        guard let screen = chosen ?? pill.screen ?? NSScreen.main else { return }
        let join: CGFloat = {
            guard settings.showBar, pill.isVisible, let window = workspaceWindow, window.isVisible, !window.isMiniaturized,
                window.occlusionState.contains(.visible), window.screen == screen
            else { return 0 }
            let bar = barRect
            guard window.frame.minY <= bar.minY, window.frame.maxY >= bar.maxY else { return 0 }
            return BarEdge.join(away: screen.frame.maxX - window.frame.maxX)
        }()
        if join > 0, let window = workspaceWindow {
            let joining = pill.parent !== window
            if joining { window.addChildWindow(pill, ordered: .above) }
            // Arriving on its own (a snap, the window opened there), it eases in; dragged there, it's already there.
            placeBarPanel(
                x: window.frame.maxX - BarEdge.strip - InboxController.pillWidth, on: screen,
                eased: eased && joining && NSEvent.pressedMouseButtons == 0)
        } else {
            // Let go on another screen than the bar's (taken there by the window): back a moment later
            // (`letGoDelay`), at once rather than across the screens.
            if letGoOfWindow(), pill.screen != screen {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.letGoDelay) { [weak self] in self?.trackBarJoin(eased: false) }
            } else {
                placeBarPanel(x: screen.frame.maxX - InboxController.pillWidth, on: screen, eased: eased && pill.screen == screen)
            }
        }
        // Not eased (a screen change), the bar's own animation on its join doesn't slide it to its new place either.
        if inbox.barJoin != join { withTransaction(.still(!eased)) { inbox.barJoin = join } }
    }

    /// The bar's panel no longer the window's child: before the window closes or goes to the Dock, which would take
    /// its children with it.
    /// Whether it was the window's child.
    @discardableResult func letGoOfWindow() -> Bool {
        guard let parent = pill.parent else { return false }
        parent.removeChildWindow(pill)
        // A child takes its parent's level and keeps it once let go: without this the bar sinks behind other windows.
        pill.level = .floating
        return true
    }

    /// How long the bar's panel waits after letting go of the window before it moves to another display: moved there
    /// at once, the window server never draws it there (in Zero, even after a CATransaction.flush()). 20 and 30 ms
    /// were enough in tests; the next turn of the main loop wasn't, always.
    /// ponytail: a fixed wait, not an event; if the bar ever goes missing on another screen again, look here first.
    static let letGoDelay = 0.03

    /// The bar's panel at `x`, as tall as its screen: on the bar's curve (220 ms in, 150 ms out), or at once.
    private func placeBarPanel(x: CGFloat, on screen: NSScreen, eased: Bool) {
        let target = NSRect(x: x, y: screen.frame.minY, width: InboxController.pillWidth, height: screen.frame.height)
        guard pill.frame != target else { return }
        guard eased, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            pill.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = x < pill.frame.minX ? 0.22 : 0.15
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
            pill.animator().setFrame(target, display: true)
        }
    }

    /// An agent from the docked bar: one of zerod's sessions opens as its task (a worker under its lead); any other
    /// (a terminal's) as a page with its conversation with you.
    func openAgent(_ name: String) {
        guard let identity = inbox.store.identity(of: name), identity.runtime == "zerod", let session = identity.ref,
            let task = workspace.conversation(session)
        else {
            inWindow(.agent(name))
            return
        }
        if let lead = task.parent, workspace.conversation(lead) != nil {
            inWindow(.task(lead))
            navigation.worker = session
        } else {
            inWindow(.task(session))
        }
    }
}

extension Transaction {
    /// A change drawn at once when `still`, past any `.animation` on the views it reaches; otherwise as they say.
    static func still(_ still: Bool) -> Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = still
        return transaction
    }
}

#if ZERO_DEV
    /// Zero Dev's workspace window: key to Zero Dev itself while its harness drives it (DevE2E), so what goes by the
    /// key window is tested with Zero Dev never the active app. The window server's key window stays the user's.
    final class DevWindow: NSWindow {
        static var driven = false
        override var isKeyWindow: Bool { Self.driven || super.isKeyWindow }

        /// Off every display (`--e2e`): nothing of Zero Dev's shows on the user's screen while it's tested. Every way
        /// AppKit places a window is held away, and the window can't be dragged: a click posted in its title bar starts
        /// the window server's own drag, which follows the user's real pointer and calls none of these (it put the
        /// window on the user's second display). Whatever still moves it is put back at once and reported (`sighted`).
        static let offscreen = CommandLine.arguments.contains("--e2e")
        static var away: NSPoint {
            let all = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
            return NSPoint(x: all.maxX + 4000, y: all.maxY + 4000)
        }
        /// Told how, the moment the window was found on a display (DevE2E fails the run's check there).
        static var sighted: ((String) -> Void)?

        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            Self.offscreen ? NSRect(origin: Self.away, size: frameRect.size) : super.constrainFrameRect(frameRect, to: screen)
        }
        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            _ = Self.watching
            stay()
            super.setFrame(Self.offscreen ? NSRect(origin: Self.away, size: frameRect.size) : frameRect, display: flag)
        }
        override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
            _ = Self.watching
            super.setFrame(Self.offscreen ? NSRect(origin: Self.away, size: frameRect.size) : frameRect, display: flag, animate: false)
        }
        override func setFrameOrigin(_ point: NSPoint) {
            _ = Self.watching
            stay()
            super.setFrameOrigin(Self.offscreen ? Self.away : point)
        }
        override func setFrameTopLeftPoint(_ point: NSPoint) {
            Self.offscreen ? setFrameOrigin(Self.away) : super.setFrameTopLeftPoint(point)
        }
        override func cascadeTopLeft(from point: NSPoint) -> NSPoint {
            guard Self.offscreen else { return super.cascadeTopLeft(from: point) }
            setFrameOrigin(Self.away)
            return point
        }
        override func center() { Self.offscreen ? setFrameOrigin(Self.away) : super.center() }
        override func zoom(_ sender: Any?) { if !Self.offscreen { super.zoom(sender) } }
        override func toggleFullScreen(_ sender: Any?) { if !Self.offscreen { super.toggleFullScreen(sender) } }
        override func performDrag(with event: NSEvent) { if !Self.offscreen { super.performDrag(with: event) } }
        override var isMovable: Bool {
            get { !Self.offscreen && super.isMovable }
            set { super.isMovable = newValue }
        }
        override var isMovableByWindowBackground: Bool {
            get { !Self.offscreen && super.isMovableByWindowBackground }
            set { super.isMovableByWindowBackground = newValue }
        }
        override var tabbingMode: NSWindow.TabbingMode {
            get { Self.offscreen ? .disallowed : super.tabbingMode }
            set { super.tabbingMode = newValue }
        }
        /// Stationary: Mission Control and App Exposé leave it where it is, off every display. They show any other
        /// window of the Space as a thumbnail on the user's screen, off-screen or not.
        override var collectionBehavior: NSWindow.CollectionBehavior {
            get { super.collectionBehavior }
            set {
                super.collectionBehavior =
                    Self.offscreen ? newValue.subtracting([.managed, .transient]).union([.stationary, .ignoresCycle]) : newValue
            }
        }
        override var isRestorable: Bool {
            get { !Self.offscreen && super.isRestorable }
            set { super.isRestorable = newValue }
        }

        /// Put back off every display if it's on one, with why.
        private func stay() {
            if Self.offscreen && !collectionBehavior.contains(.stationary) { collectionBehavior = collectionBehavior }
        }

        func putBack(_ why: String) {
            stay()
            guard Self.offscreen, isVisible || isMiniaturized, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else {
                return
            }
            let was = frame
            super.setFrameOrigin(Self.away)
            Self.sighted?("\(why) at \(was)")
        }

        /// Moves the window server makes (a drag, a display added or rearranged, a space) and AppKit's own: each checked.
        private static let watching: Void = {
            guard offscreen else { return }
            let moves: [Notification.Name] = [
                NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
            ]
            for name in moves {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated { (note.object as? DevWindow)?.putBack(name.rawValue) }
                }
            }
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main)
            {
                _ in
                MainActor.assumeIsolated {
                    for case let window as DevWindow in NSApp.windows { window.putBack("the displays changed") }
                }
            }
        }()
    }
#endif
