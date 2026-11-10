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
            let window = NSWindow(contentViewController: host)
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
        NSApp.activate(ignoringOtherApps: true)
        workspaceWindow?.makeKeyAndOrderFront(nil)
    }

    /// An agent from the docked bar: one of zerod's sessions opens as its task (a worker under its lead); any other
    /// (Solo's, Rex's, a terminal's) as a page with its conversation with you.
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
