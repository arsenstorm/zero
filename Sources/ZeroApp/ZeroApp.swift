import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UserNotifications
import ZeroCore

@main
enum ZeroMain {
    static func main() {
        if CommandLine.arguments.contains("--claude-models") {
            let semaphore = DispatchSemaphore(value: 0)
            Task { _ = await ClaudeModels.refresh(); semaphore.signal() }
            semaphore.wait()
            print("source:", ClaudeModels.status.source, ClaudeModels.status.error.map { "(\($0))" } ?? "")
            for choice in ClaudeModels.cached() { print(choice.id, "—", choice.name, "—", choice.detail ?? "") }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-pill"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Preview.renderPill(to: CommandLine.arguments[i + 1]) }
            return
        }
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.run()
    }
}

/// Everything configurable, persisted in UserDefaults and shown in the Settings window.
@MainActor @Observable
final class Settings {
    private let defaults = UserDefaults.standard

    var followActiveScreen: Bool { didSet { defaults.set(followActiveScreen, forKey: "followActiveScreen") } }
    /// Agent names in the order Arsen dragged them into; agents not listed follow in first-seen order.
    var agentOrder: [String] { didSet { defaults.set(agentOrder, forKey: "agentOrder") } }
    /// Minutes before an ask that arrives without its own expiry is marked expired.
    var defaultTTLMinutes: Int { didSet { defaults.set(defaultTTLMinutes, forKey: "defaultTTLMinutes"); onChange?() } }
    /// Seconds in which Esc can take an answer back.
    var takeBackSeconds: Double { didSet { defaults.set(takeBackSeconds, forKey: "takeBackSeconds"); onChange?() } }
    /// The talk hotkey: a virtual key code and Carbon modifier flags, plus how to print it.
    var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: "hotKeyCode"); onChange?() } }
    var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: "hotKeyModifiers"); onChange?() } }
    var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: "hotKeyLabel") } }
    /// After an answer turns green, move on to the next waiting card a few seconds later.
    var autoAdvance: Bool { didSet { defaults.set(autoAdvance, forKey: "autoAdvance"); onChange?() } }
    /// Folder patterns Zero watches for asks as files (globs, ~ allowed).
    var dropPatterns: [String] { didSet { defaults.set(dropPatterns, forKey: "dropPatterns"); onChange?() } }
    /// Microphone for dictation, as a CoreAudio device UID; nil follows the system default.
    var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID"); onChange?() } }
    @ObservationIgnored var onChange: (() -> Void)?

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    init() {
        followActiveScreen = defaults.bool(forKey: "followActiveScreen")
        agentOrder = defaults.stringArray(forKey: "agentOrder") ?? []
        defaultTTLMinutes = defaults.object(forKey: "defaultTTLMinutes") as? Int ?? 60
        takeBackSeconds = defaults.object(forKey: "takeBackSeconds") as? Double ?? 2
        hotKeyCode = defaults.object(forKey: "hotKeyCode") as? Int ?? kVK_Space
        hotKeyModifiers = defaults.object(forKey: "hotKeyModifiers") as? Int ?? optionKey
        hotKeyLabel = defaults.string(forKey: "hotKeyLabel") ?? "⌥ Space"
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        autoAdvance = defaults.object(forKey: "autoAdvance") as? Bool ?? true
        dropPatterns = defaults.stringArray(forKey: "dropPatterns") ?? []
    }

    func sorted(_ names: [String]) -> [String] {
        names.sorted { (agentOrder.firstIndex(of: $0) ?? .max, names.firstIndex(of: $0)!) < (agentOrder.firstIndex(of: $1) ?? .max, names.firstIndex(of: $1)!) }
    }

    func move(_ name: String, before target: String, shown: [String]) {
        var order = shown.filter { $0 != name }
        guard let index = order.firstIndex(of: target) else { return }
        order.insert(name, at: index)
        agentOrder = order
    }
}

/// The bar is never the key window, so without this its first mouse-down would only be used to focus it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// AppKit hands a new key window's focus to its first text field. The inbox only takes text focus when asked:
    /// a click in the field, or the controller arming it (R, Enter, "/", dictation). Otherwise 1, 2, 3 stay shortcuts.
    var allowsTextFocus: () -> Bool = { true }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView, !allowsTextFocus(), NSApp.currentEvent?.type != .leftMouseDown { return false }
        return super.makeFirstResponder(responder)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = Store()
    private lazy var server = Server(store: store)
    private lazy var drops = DropWatcher(store: store)
    private lazy var inbox = InboxController(store: store)
    private var pill: Panel!
    private var inboxPanel: Panel!
    private var hotKey: EventHotKeyRef?
    private var statusItem: NSStatusItem!
    private var selectorPanel: Panel?
    private var selectorMonitors: [Any] = []
    private var settingsWindow: NSWindow?
    private let settings = Settings()
    private var pinnedDisplay: CGDirectDisplayID?
    private var pillHosting: FirstMouseHostingView<AnyView>!
    /// Opened by ⌥Space, a notification or a click in the pill: stays until Esc, or until the pointer has come in and left.
    private var openedByIntent = false
    private var pointerWasInside = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do { try server.start() } catch { NSLog("zero: server failed: \(error)") }
        let serverChanged = store.onChange
        store.onChange = { [weak self] ask in serverChanged?(ask); self?.drops.changed(ask) }
        store.onCreate = { [weak self] ask in self?.arrived(ask) }
        inbox.hide = { [weak self] in self?.hideInbox() }
        inbox.presentSelector = { [weak self] anchor in self?.showSelector(anchorInInbox: anchor) }
        inbox.dismissSelector = { [weak self] in self?.hideSelector() }
        makePanels()
        makeStatusItem()
        applySettings()
        settings.onChange = { [weak self] in self?.applySettings() }
        registerHotKey()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === inboxPanel else { return event }
            return inbox.handle(event) ? nil : event
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func applySettings() {
        drops.start(patterns: settings.dropPatterns)
        inbox.autoAdvance = settings.autoAdvance
        inbox.dictation.deviceUID = settings.inputDeviceUID
        store.takeBackDelay = settings.takeBackSeconds
        store.defaultTTL = TimeInterval(settings.defaultTTLMinutes * 60)
        if hotKey != nil { registerHotKey() }
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "0.circle", accessibilityDescription: "Zero")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Zero", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    @objc private func openLog() { NSWorkspace.shared.open(Paths.log) }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, store: store, inbox: inbox)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Zero Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 520, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The selector is a panel of its own, so it can reach past the inbox's edges: the 240 pt list aligned with the
    /// chip and the 224 pt preview to its left, above the chip when there is room, otherwise below.
    private func showSelector(anchorInInbox anchor: CGRect) {
        guard let selector = inbox.selector, let content = inboxPanel.contentView else { return }
        hideSelector(keepState: true)
        // SwiftUI's global frame is in the window's content, top-left origin; AppKit wants bottom-left.
        let appKit = NSRect(x: anchor.minX, y: content.bounds.height - anchor.maxY, width: anchor.width, height: anchor.height)
        let chip = inboxPanel.convertToScreen(appKit)
        // A fixed, transparent strip above the chip (below it only when there is no room). The card inside is
        // anchored to the chip's edge, so a tab change grows or shrinks it from the far edge in the same frame,
        // with no window resizing and nothing moving underneath.
        let roomAbove = (inboxPanel.screen.map { chip.minY - 6 - $0.visibleFrame.minY } ?? 480)
        let opensAbove = roomAbove >= 240
        let height = min(480, opensAbove ? roomAbove : (inboxPanel.screen.map { $0.visibleFrame.maxY - chip.maxY - 6 } ?? 480))
        let size = NSSize(width: SelectorView.width, height: height)
        var x = chip.minX
        let y = opensAbove ? chip.minY - 6 - size.height : chip.maxY + 6
        if let screen = inboxPanel.screen { x = min(x, screen.visibleFrame.maxX - size.width - 8) }
        let view = FirstMouseHostingView(rootView: AnyView(SelectorView(controller: inbox, state: selector)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: opensAbove ? .bottom : .top)))
        view.sizingOptions = []
        let panel = makePanel(size: size, content: view)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        selectorPanel = panel
        // A click anywhere but the card closes it: in another app (global), in Zero's other windows, or in the
        // strip's empty part (local).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.inbox.closeSelector()
        }) { selectorMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self, weak selector] event in
            guard let self, let panel = selectorPanel else { return event }
            let y = event.locationInWindow.y, card = selector?.cardHeight ?? 0
            let inCard = opensAbove ? y <= card : y >= panel.frame.height - card
            if event.window !== panel || !inCard { inbox.closeSelector() }
            return event
        }) { selectorMonitors.append(local) }
    }

    private func hideSelector(keepState: Bool = false) {
        selectorMonitors.forEach { NSEvent.removeMonitor($0) }
        selectorMonitors.removeAll()
        selectorPanel?.orderOut(nil)
        selectorPanel = nil
        if !keepState, openedByIntent || inbox.takesKeys { inboxPanel.makeKey() }
    }

    private func makePanel(size: NSSize, content: NSView) -> Panel {
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

    private func makePanels() {
        pillHosting = FirstMouseHostingView(rootView: AnyView(PillView(
            controller: inbox, settings: settings,
            openInbox: { [weak self] in self?.pin(agent: nil) },
            selectAgent: { [weak self] name in self?.pin(agent: name) },
            moveHere: { [weak self] in self?.pinnedDisplay = nil; self?.layout() },
            peek: { [weak self] agent in self?.peek(agent) })))
        // Tall and transparent so the bar can morph inside it; the transparent rest is click-through.
        // Without clearing sizingOptions the hosting view shrinks the window to its content, top edge fixed.
        pillHosting.sizingOptions = []
        pill = makePanel(size: NSSize(width: 44, height: 600), content: pillHosting)
        pill.acceptsMouseMovedEvents = true
        let inboxView = NSHostingView(rootView: InboxView(controller: inbox)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing))
        inboxView.sizingOptions = []
        inboxPanel = makePanel(size: NSSize(width: 380, height: 600), content: inboxView)
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
    private func layout() {
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
    private func open(byIntent: Bool) {
        layout()
        inbox.ensureSelection()
        openedByIntent = byIntent
        inbox.pinned = byIntent
        pointerWasInside = false
        if byIntent { inboxPanel.makeKeyAndOrderFront(nil) } else { inboxPanel.orderFrontRegardless() }
        inbox.requestScroll()
    }

    private func hideInbox() {
        inboxPanel.orderOut(nil)
        inbox.agentFilter = nil
        openedByIntent = false
        inbox.pinned = false
        // Answered cards are dropped now, while hidden, so the next open starts clean on its first frame.
        inbox.inboxOpenedAt = Date()
    }

    /// A click on a pill control pins the inbox open on that view; the same click again unpins and closes it.
    private func pin(agent: String?) {
        if openedByIntent && inboxPanel.isVisible && inbox.agentFilter == agent { hideInbox(); return }
        inbox.show(agent: agent)
        open(byIntent: true)
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
        inboxPanel.makeKey()
    }

    /// Entering the cards gives them the keyboard. While the inbox is open, the whole strip from its left edge to
    /// the screen edge is a safe zone (pill, gap, and the way up or down to the cards), so only moving left past
    /// the cards, or to another screen, closes it.
    private func trackPointer() {
        let mouse = NSEvent.mouseLocation
        // "Follow the active screen": move whenever the pointer is on a different display than Zero.
        if settings.followActiveScreen, let here = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           here.displayID != pinnedDisplay {
            layout()
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

    /// ⌥Space: open the inbox on the oldest waiting ask and start listening.
    private func talk() {
        open(byIntent: true)
        if inbox.dictatingFor == nil { inbox.startDictation() } else { inbox.stopDictation() }
    }

    private func arrived(_ ask: Ask) {
        guard ask.kind != .note else { return }
        layout()
        let content = UNMutableNotificationContent()
        content.title = ask.agent.name
        content.subtitle = ask.kind == .run ? "wants to run a command" : "needs your answer"
        content.body = ask.title
        content.sound = .default
        content.userInfo = ["id": ask.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ask.id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let id = response.notification.request.content.userInfo["id"] as? String { inbox.select(id) }
        open(byIntent: true)
    }

    private var hotKeyHandlerInstalled = false

    private func registerHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if !hotKeyHandlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue().talk()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
            hotKeyHandlerInstalled = true
        }
        let id = EventHotKeyID(signature: 0x5A45524F, id: 1) // "ZERO"
        RegisterEventHotKey(UInt32(settings.hotKeyCode), UInt32(settings.hotKeyModifiers), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}

/// `Zero --render-pill DIR` writes pill-{resting,hovered,selected}.png and card.png at 4x for pixel checks.
@MainActor
enum Preview {
    static func renderPill(to dir: String) {
        let store = Store(logURL: nil)
        let codex = AgentIdentity(name: "codex-12", host: "mac")
        let lead = AgentIdentity(name: "app-lead", host: "mac")
        _ = store.create(Ask(kind: .note, title: "Update", body: "Scaffolded the checkout page; installing the Stripe SDK next", agent: codex))
        _ = store.create(Ask(kind: .choice, title: "Stripe checkout", body: "Allow this command?", options: ["Yes", "Yes, and don't ask again", "No, and tell Codex what to do differently…"],
                             command: "npm install stripe", agent: codex))
        _ = store.create(Ask(kind: .run, title: "Production read: Source.count", options: ["Run", "Reject", "Suggest something else…"],
                             command: "bin/production console <<< 'puts Source.count'", cwd: "/Users/arsen/x", agent: lead))
        store.takeBackDelay = 0.05
        let pending = store.create(Ask(kind: .choice, title: "Deploy", body: "Deploy to staging now?", options: ["Yes", "Not yet…"], agent: lead))
        store.choose(pending.id, option: 0)
        let done = store.create(Ask(kind: .choice, title: "Lint", body: "Fix the 3 lint warnings too?", options: ["Yes", "Leave them"], agent: codex))
        store.choose(done.id, option: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        store.takeBackDelay = 60
        let pendingAgain = store.create(Ask(kind: .choice, title: "Deploy", body: "Deploy to staging now?", options: ["Yes", "Not yet…"], agent: lead))
        store.choose(pendingAgain.id, option: 0)
        let controller = InboxController(store: store)
        let settings = Settings()
        func write(_ view: some View, _ name: String) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 4
            guard let cg = renderer.cgImage else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let pill = { PillView(controller: controller, settings: settings, openInbox: {}, selectAgent: { _ in }, moveHere: {}, previewHovered: $0) }
        write(pill(nil), "pill-resting.png")
        controller.agentFilter = "app-lead"
        controller.pinned = true
        write(pill(nil), "pill-selected.png")
        controller.pinned = false
        controller.agentFilter = nil
        write(CardStack(controller: controller).padding(12).background(Color(white: 0.5)), "cards.png")
        // The answer states on their own, with nothing else open, so nothing is dimmed.
        let states = Store(logURL: nil)
        states.takeBackDelay = 0.05
        let answered = states.create(Ask(kind: .choice, title: "Lint", body: "Fix the 3 lint warnings too?", options: ["Yes", "Leave them"], agent: codex))
        states.choose(answered.id, option: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        states.takeBackDelay = 60
        let sending = states.create(Ask(kind: .choice, title: "Deploy", body: "Deploy to staging now?", options: ["Yes", "Not yet…"], agent: lead))
        states.choose(sending.id, option: 0)
        write(CardStack(controller: InboxController(store: states)).padding(12).background(Color(white: 0.5)), "states.png")
        // A run before and after completion, to compare the terminal's height with the options' space.
        let runs = Store(logURL: nil)
        runs.takeBackDelay = 0.05
        let finished = runs.create(Ask(kind: .run, title: "Production read", options: ["Run", "Reject", "Suggest something else…"],
                                       command: "echo one; echo two", cwd: "/tmp", agent: lead))
        runs.choose(finished.id, option: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        _ = runs.create(Ask(kind: .run, title: "Production read", options: ["Run", "Reject", "Suggest something else…"],
                            command: "echo one; echo two", cwd: "/tmp", agent: lead))
        write(CardStack(controller: InboxController(store: runs)).padding(12).background(Color(white: 0.5)), "runs.png")
        // The empty inbox: "All quiet." and the new-agent composer, with example choices.
        let empty = InboxController(store: Store(logURL: nil))
        empty.spawnTargets = [SpawnChoice(id: "10", name: "Acme"), SpawnChoice(id: "13", name: "zero")]
        empty.spawnRuntimes = [SpawnChoice(id: "6", name: "Claude"), SpawnChoice(id: "7", name: "Codex")]
        empty.spawnTarget = "10"; empty.spawnRuntime = "6"
        write(ComposerPreview(controller: empty).padding(12).background(Color(white: 0.5)), "composer.png")
    }
}

private struct ComposerPreview: View {
    @Bindable var controller: InboxController
    @FocusState private var focus: String?
    var body: some View {
        NewAgentCard(controller: controller, focus: $focus, quiet: true).frame(width: 380)
    }
}

private struct CardStack: View {
    @Bindable var controller: InboxController
    @FocusState private var focus: String?
    var body: some View {
        VStack(spacing: 10) {
            ForEach(controller.store.asks.reversed()) { ask in CardView(ask: ask, controller: controller, focus: $focus) }
        }
        .frame(width: 380)
    }
}
