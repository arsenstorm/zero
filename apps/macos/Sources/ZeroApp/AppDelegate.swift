import AppKit
import Carbon.HIToolbox
import SwiftUI
import ZeroCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    lazy var inbox = InboxController(store: store)
    var pill: Panel!
    var inboxPanel: Panel!
    private var hotKey: EventHotKeyRef?
    private var statusItem: NSStatusItem!
    private var updateItem: NSMenuItem?
    var selectorPanel: Panel?
    /// The two panels menus open in and their views, kept between them and taken in turn (SelectorPanel.selectorWindow).
    var selectorHosts: [(panel: Panel, view: FirstMouseHostingView<AnyView>)] = []
    /// The menu just closed, still on screen until the end of this turn: one opened by the same click takes its place
    /// first (hideSelector, presentSelector).
    var selectorLeaving: Panel?
    var selectorMonitors: [Any] = []
    /// The window the open selector gives the keys back to, when it isn't the inbox.
    var selectorReturn: NSWindow?
    /// zerod's sessions and their approvals; made once the store's other change handlers are in place.
    var workspace: Workspace!
    var workspaceWindow: NSWindow?
    var notifier: Notifier?
    /// Waiting to reopen the window until you come to Zero (another app was full screen when it started).
    private var restoreWatch: NSObjectProtocol?
    private var spaceWatch: NSObjectProtocol?
    let navigation = Navigation(restoring: true)
    let settings = Settings()
    var pinnedDisplay: CGDirectDisplayID?
    var pillHosting: FirstMouseHostingView<AnyView>!
    /// Opened by ⌥Space, a notification or a click in the pill: stays until Esc, or until the pointer has come in and left.
    var openedByIntent = false
    var pointerWasInside = false
    /// The pointer where it was last seen, to tell a way from the bar towards the inbox from leaving it.
    var lastPointer: NSPoint?
    /// A peeked inbox the pointer has left, closing in a moment unless the pointer comes back.
    var closingInbox: Task<Void, Never>?
    var onboardingWindow: NSWindow?
    private var responderWatch: NSKeyValueObservation?
    /// The app that was in front before Zero took it for typing; it comes back when the inbox closes.
    var returnTo: NSRunningApplication?
    /// The app in front when the inbox last took the keyboard.
    var keyboardFront: NSRunningApplication?
    private var hotKeyHandlerInstalled = false
    /// Shown instead of everything else while Zero runs from outside Applications (MoveToApplications).
    private var moveWindow: NSWindow?
    private var launchedAtLogin = false

    /// A zero:// link, clicked anywhere: a pad (at its section), a loop, a Later item, a task.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard moveWindow == nil else { return }
        if let url = urls.first(where: { $0.scheme == "zero" }) { openZeroURL(url) }
    }

    /// What a zero:// link (or a path) clicked in Zero or anywhere opens.
    @objc func openZeroURL(_ url: URL) {
        if url.isFileURL { OpenTarget.open(path: url.path); return }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch url.host {
        case "loop": navigation.place = name.isEmpty ? .loops : .loop(name)
        case "later": navigation.place = name.isEmpty ? .later : .laterItem(name)
        case "task": openTask(url)
        case "pad":
            guard let (id, section) = PadLinks.parse(url) else { return }
            navigation.place = .pad(id)
            navigation.padSection = section
        default: return
        }
        openWorkspace()
    }

    /// zero://task/<id>, at a passage with #<anchor> (a heading's, an item's), from an ask with ?ask=<id>; within the
    /// task open, "#<anchor>" alone.
    private func openTask(_ url: URL) {
        var current: String?
        if case let .task(id) = navigation.place { current = navigation.worker ?? id }
        guard let (task, anchor) = TaskLinks.parse(url, current: current) else { return }
        if task != current { navigation.place = .task(task) }
        guard let anchor else { return }
        let ask = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ask" }?.value
        workspace?.reveal = Reveal(task: task, anchor: anchor, ask: ask)
    }

    /// Back from a passage an ask was about to the ask, in the inbox.
    @objc func backToAsk(_ id: NSString) {
        inbox.select(id as String)
        open(byIntent: true)
    }

    // Opening Zero again, from the Dock or Finder, opens the workspace.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let moveWindow { moveWindow.makeKeyAndOrderFront(nil); return false }
        openWorkspace()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        BrowserKeys.visible = { [navigation] in
            guard navigation.pane, case let .task(lead) = navigation.place else { return nil }
            return lead
        }
        FieldEditorStyle.start()
        if !DevBuild.on, let app = MoveToApplications.needed() {
            moveWindow = MoveToApplications(source: app).window()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            moveWindow?.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Task { await CustomModels.shared.load() }
        ClaudeModels.refresh()
        HealthMonitor.shared.start()
        // Before connecting: launchd starts zerod, rather than the app (ZerodLink.ensureRunning).
        if !DevBuild.on { ZerodAgent.register() }
        connectStore()
        connectWorkspace()
        connectInbox()
        makePanels()
        if DevBuild.on {
            showWorkspace(activating: false)
        } else {
            if launchedToRestore() { restoreWorkspace() } else { openWorkspace() }
            activateForTypingInInbox()
            makeStatusItem()
            Updater.shared.watch()
        }
        applySettings()
        settings.onChange = { [weak self] in self?.applySettings() }
        if !DevBuild.on { registerHotKey() }
        monitorEvents()
        watchFloating()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.updateDock() }
        }
        if !DevBuild.on, !UserDefaults.standard.bool(forKey: "onboarded") { openOnboarding() }
        #if ZERO_DEV
            if CommandLine.arguments.contains("--e2e") { DevE2E.run(self) }
        #endif
    }

    /// The asks' store: an ask arriving sounds, one ending takes back its notification.
    private func connectStore() {
        store.onCreate = { [weak self] ask in self?.arrived(ask) }
        store.onChange = { [weak self] ask in if ask.state.isFinal { self?.notifier?.askEnded(ask.id) } }
        store.onRemove = { [weak self] id in self?.notifier?.askEnded(id) }
        Task { [store] in await store.connect() }
    }

    /// zerod's sessions, their notifications, and the phones that see them.
    private func connectWorkspace() {
        workspace = Workspace()
        workspace.onLink = { link in Desktop.shared.attach(link) }
        // A worker opened by its id, however (a link, a card, a report), shows on its lead's page, as the sidebar opens it;
        // a worker's worker has no row there, and keeps its own page.
        navigation.leadOf = { [weak workspace] id in
            guard let workspace, let parent = workspace.conversation(id)?.parent, workspace.conversation(parent)?.parent == nil
            else { return nil }
            return parent
        }
        inbox.workspace = workspace
        // The control bar names Zero's own tasks as the window does. Their names only, read on their own (not the
        // roster, which changes with every task's state); what they run on is the composer's (ComposerCard.zeroRuns).
        store.zeroTask = { [weak workspace] agent in
            guard agent.hasPrefix("zerod-"), let name = workspace?.names[String(agent.dropFirst("zerod-".count))] else { return nil }
            return (name, "")
        }
        let notifier = makeNotifier()
        self.notifier = notifier
        workspace.onBoard = { [weak notifier] rows in notifier?.board(rows) }
        Phones.shared.mcpServers = { [weak self] in await self?.mcpServersForPhones() ?? [] }
        // Zero Dev pairs no phones: the relay and the tunnel's keys are the user's Zero's.
        if !DevBuild.on { Phones.shared.start() }
        Task { [workspace] in await workspace?.connect() }
        workspace?.keepSlackFresh()
    }

    /// The MCP servers as the phones list them: their names, what they run, their workspaces, on or off.
    private func mcpServersForPhones() async -> [[String: Any]] {
        guard let workspace else { return [] }
        await workspace.loadMcpServers()
        let names = Dictionary(workspace.workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return workspace.mcpServers.map { server in
            [
                "name": server.name, "runs": server.url ?? ([server.command ?? ""] + server.args).joined(separator: " "),
                "workspaces": server.workspaces.map { names[$0] ?? $0 }, "enabled": server.enabled,
            ] as [String: Any]
        }
    }

    private func makeNotifier() -> Notifier {
        Notifier(
            navigation: navigation, settings: settings,
            windowShown: { [weak self] in
                guard let window = self?.workspaceWindow else { return false }
                return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            },
            open: { [weak self] id in
                guard let self else { return }
                navigation.place = .task(id)
                navigation.worker = nil
                openWorkspace()
                NSApp.activate()
            },
            ask: { [store] id in store.ask(id) })
    }

    private func connectInbox() {
        inbox.hide = { [weak self] in self?.hideInbox() }
        inbox.onTyping = { [weak self] typing in if typing { self?.activateForTyping() } }
        inbox.presentSelector = { [weak self] anchor in self?.showSelector(anchorInInbox: anchor) }
        inbox.dismissSelector = { [weak self] in self?.hideSelector() }
    }

    /// Opened by the user (the Dock, Finder, Spotlight, `open`), Zero opens its window. Reopened by an install or an
    /// update (install.sh passes --restore), or at login, it comes back as it was.
    private func launchedToRestore() -> Bool { CommandLine.arguments.contains("--restore") || launchedAtLogin }

    /// The launch's open event is gone by applicationDidFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin =
            event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Back where you were: the window, if it was open when Zero last quit. Not over someone's full-screen app (a film,
    /// while Zero updates): a window made then opens in that app's Space, on top of it. It waits for you to come
    /// to Zero, or to go to a Space no full-screen app fills (your desktop, say), and opens there.
    private func restoreWorkspace() {
        guard UserDefaults.standard.bool(forKey: "workspaceOpen") else { return }
        guard Self.anotherAppFillsTheScreen() else { openWorkspace(); return }
        restoreWatch = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreOnceActive() }
        }
        spaceWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // A moment for the Space's windows to be on screen before looking at them.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let self, !Self.anotherAppFillsTheScreen() else { return }
                    self.restoreOnceActive(activating: false)
                }
            }
        }
    }

    /// Once: the first time you come to Zero, or to a Space it can open in, it opens where you were; after that, as
    /// you leave it. From a Space change, without taking the keyboard from what you went there for.
    private func restoreOnceActive(activating: Bool = true) {
        if let watch = restoreWatch { NotificationCenter.default.removeObserver(watch); restoreWatch = nil }
        if let watch = spaceWatch { NSWorkspace.shared.notificationCenter.removeObserver(watch); spaceWatch = nil }
        if workspaceWindow == nil { showWorkspace(activating: activating) }
    }

    /// Whatever put it there (a click, picking "Something else…", a key), a text box in the inbox holding the
    /// keyboard makes Zero the active app, so dictation and paste tools that target the active app land in it.
    private func activateForTypingInInbox() {
        responderWatch = inboxPanel.observe(\.firstResponder, options: [.new]) { [weak self] panel, _ in
            MainActor.assumeIsolated {
                guard panel.firstResponder is NSTextView else { return }
                self?.activateForTyping()
            }
        }
    }

    private func monitorEvents() {

        // The pointer: following the active screen, the inbox's safe zone, and closing a peeked inbox. Followed as it
        // moves, over other apps and Zero's own windows, rather than looked at ten times a second: a still pointer costs
        // nothing.
        let follow: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.trackPointer() } }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: follow)
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            follow(event); return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === inboxPanel else { return event }
            return inbox.handle(event) ? nil : event
        }
        // ⌘1 to ⌘9 pick the side panel's tabs while it has the keyboard, ahead of the sidebar's tasks (BrowserKeys).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === workspaceWindow,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit)
            else { return event }
            return BrowserKeys.select(digit, in: keyWorkspace) ? nil : event
        }
        // A click in the side panel gives it the keyboard; one elsewhere takes it away (BrowserKeys).
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if event.window === self?.workspaceWindow { BrowserKeys.clicked(event) }
            return event
        }
        // The mouse's side buttons go back and forward through the workspace window, as in a browser: as buttons 4 and
        // 5, or as the swipe Logitech's driver sends for them (and a trackpad's swipe between pages), as Safari takes it.
        // Over the side panel's page, they go back and forward in the page instead (BrowserKeys).
        NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { [weak self] event in
            guard let self, event.window === workspaceWindow else { return event }
            let step: Int
            switch event.type {
            case .otherMouseDown where event.buttonNumber == 3: step = -1
            case .otherMouseDown where event.buttonNumber == 4: step = 1
            case .swipe where event.deltaX > 0: step = -1
            case .swipe where event.deltaX < 0: step = 1
            default: return event
            }
            if !BrowserKeys.go(step, under: event) { if step < 0 { navigation.goBack() } else { navigation.goForward() } }
            return nil
        }
        // A trackpad's two-finger swipe between pages (PageSwipe), when the user swipes with two fingers (System
        // Settings › Trackpad); a mouse's wheel has no gesture and is left alone.
        var swipe = PageSwipe()
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === workspaceWindow, event.phase != [] || event.momentumPhase != [] else { return event }
            let began = event.phase == .began
            let free = began && NSEvent.isSwipeTrackingFromScrollEventsEnabled && !scrollsSideways(under: event)
            let fingers = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            guard
                let step = swipe.scroll(
                    began: began, momentum: event.momentumPhase != [], fingers: fingers, dy: event.scrollingDeltaY, free: free)
            else { return event }
            if step < 0 { navigation.goBack() } else if step > 0 { navigation.goForward() }
            return nil
        }
    }

    /// Something under the pointer scrolls sideways, and keeps a sideways gesture: a scroll view wider inside than out
    /// (a command's output, a diff), or the side panel's page, whose own scrolling Zero can't see. Found by the views'
    /// frames, not a hit test, which a SwiftUI window answers with its hosting view.
    private func scrollsSideways(under event: NSEvent) -> Bool {
        func scrolls(_ view: NSView) -> Bool {
            guard !view.isHidden, view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return false }
            if let scroll = view as? NSScrollView, let inside = scroll.documentView,
                inside.frame.width > scroll.contentView.bounds.width + 1
            {
                return true
            }
            return view.subviews.contains(where: scrolls)
        }
        return BrowserKeys.onPage(event) || event.window?.contentView.map(scrolls) == true
    }

    /// Zero is in the Dock while one of its windows (onboarding, the workspace) is open, or always without the bar (its
    /// badge and icon are then the way back); otherwise it is a menu bar app with its bar.
    private func updateDock() {
        let windowOpen = [onboardingWindow, workspaceWindow].contains { $0?.isVisible == true }
        let policy: NSApplication.ActivationPolicy = windowOpen || !settings.showBar ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    @objc func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                settings: settings, tryIt: { [weak self] in self?.sendSampleAsk() },
                finish: { [weak self] in
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    self?.onboardingWindow?.close()
                })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 600))
            window.center()
            onboardingWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    /// The ask an agent would send, so the first card answered is a real one; the inbox opens on it.
    private func sendSampleAsk() {
        let zero = AgentIdentity(name: "zero", host: AgentIdentity.thisHost, label: "Zero")
        store.create(
            Ask(
                kind: .approve, title: "Onboarding", body: "Zero is set up. Finish onboarding?",
                options: ["Yes", "No", "Suggest something else…"], agent: zero, ttl: 600))
        pin(agent: nil)
    }

    private func applySettings() {
        store.configure(takeBack: settings.takeBackSeconds, ttl: settings.defaultTTLMinutes * 60)
        inbox.suggestFiles = settings.suggestFiles
        if hotKey != nil { registerHotKey() }
        placeBar()
        showBar()
        updateDock()
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let mark = NSImage(named: "menubar")
        mark?.isTemplate = true
        mark?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = mark
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Zero", action: #selector(openWorkspace), keyEquivalent: "0")
        menu.addItem(.separator())
        updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(showUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        // Not #selector(openSettings): macOS gives an item with a settings action a gear, which none of the menu's
        // other items have.
        menu.addItem(withTitle: "Settings…", action: #selector(showConfiguration), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Zero", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Settings › General's About, where an update is checked for and installed.
    @objc private func showUpdates() {
        navigation.openSettings(SettingsView.Page.general.rawValue, section: "about")
        openWorkspace()
        if Updater.shared.available == nil { Task { await Updater.shared.check() } }
    }

    @objc private func showConfiguration() { openSettings() }

    @objc func goBack() { navigation.goBack() }

    @objc func goForward() { navigation.goForward() }

    /// The task's side panel, opened or closed (⌥⌘B), as the title bar's right button does.
    @objc func togglePanel() { navigation.pane.toggle() }

    /// ⌘W: the side panel's tab when the panel has the keyboard (BrowserKeys), else the window, as before.
    @objc func closeTabOrWindow(_ sender: Any?) {
        if !BrowserKeys.close(in: keyWorkspace) { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: sender) }
    }

    /// ⌘Z: the side panel's tab last closed when the panel has the keyboard outside text, else the text's undo.
    @objc func undoOrReopenTab(_ sender: Any?) {
        if !BrowserKeys.undo(in: keyWorkspace) { NSApp.sendAction(Selector(("undo:")), to: nil, from: sender) }
    }

    @objc func reopenTab() { _ = BrowserKeys.reopen(in: keyWorkspace) }

    @objc func newTab() { _ = BrowserKeys.newTab(in: keyWorkspace) }

    /// ⌘P: the side panel's page, printed.
    @objc func printPage() { _ = BrowserKeys.print(in: keyWorkspace) }

    /// The workspace window when it's key: the side panel's keys are its alone, never the bar's or another window's.
    private var keyWorkspace: NSWindow? { workspaceWindow.flatMap { $0.isKeyWindow ? $0 : nil } }

    /// Settings live in the workspace window.
    @objc func openSettings() {
        navigation.place = .settings
        openWorkspace()
    }

    /// Zero shows no menu bar, but ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z reach a text box only through menu items with those
    /// keys: without this, paste did nothing in the composer.
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit Zero", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(app)
        // ⌘W closes the window and leaves Zero in the menu bar; ⌘Q quits Zero, and zerod keeps the agents running.
        // With the side panel's keyboard, ⌘W closes its tab and ⌘Z reopens it (BrowserKeys).
        let file = NSMenuItem()
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newTab), keyEquivalent: "t")
        // Shifted as AppKit matches them: the capital letter (a lowercase one with a Shift mask never matches ⌘⇧T).
        file.submenu?.addItem(withTitle: "Reopen Closed Tab", action: #selector(AppDelegate.reopenTab), keyEquivalent: "T")
        file.submenu?.addItem(withTitle: "Close Window", action: #selector(AppDelegate.closeTabOrWindow), keyEquivalent: "w")
        file.submenu?.addItem(.separator())
        file.submenu?.addItem(withTitle: "Print…", action: #selector(AppDelegate.printPage), keyEquivalent: "p")
        main.addItem(file)
        let edit = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: #selector(AppDelegate.undoOrReopenTab), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = menu
        main.addItem(edit)
        // Reaches the delegate through the responder chain.
        let go = NSMenuItem()
        go.submenu = NSMenu(title: "Go")
        go.submenu?.addItem(withTitle: "Back", action: #selector(AppDelegate.goBack), keyEquivalent: "[")
        go.submenu?.addItem(withTitle: "Forward", action: #selector(AppDelegate.goForward), keyEquivalent: "]")
        main.addItem(go)
        let view = NSMenuItem()
        view.submenu = NSMenu(title: "View")
        view.submenu?.addItem(withTitle: "Side Panel", action: #selector(AppDelegate.togglePanel), keyEquivalent: "b")
            .keyEquivalentModifierMask = [.command, .option]
        main.addItem(view)
        return main
    }

    /// A new ask is announced by a sound and the bar's orange dot, not a banner: the card is already in the inbox,
    /// and a banner on top of it said the same thing twice (and on whichever screen macOS chose).
    private func arrived(_ ask: Ask) {
        guard ask.kind != .note, ask.kind != .message else { return }
        layout()
        // A task's ask sounds with its task's notification (Notifications.swift), once the board has it.
        if let id = ask.session, workspace?.conversations.contains(where: { $0.id == id }) == true { return }
        notifier?.ask(ask, agent: store.displayName(of: ask.agent.name))
    }

    private func registerHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if !hotKeyHandlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else { return noErr }
                    Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue().open(byIntent: true)
                    return noErr
                }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
            hotKeyHandlerInstalled = true
        }
        let id = EventHotKeyID(signature: 0x5A45524F, id: 1) // "ZERO"
        RegisterEventHotKey(UInt32(settings.hotKeyCode), UInt32(settings.hotKeyModifiers), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The menu bar's menu names an update once there is one.
    func menuWillOpen(_ menu: NSMenu) {
        updateItem?.title = Updater.shared.available.map { "Update to Zero \($0.version)…" } ?? "Check for Updates…"
    }
}
