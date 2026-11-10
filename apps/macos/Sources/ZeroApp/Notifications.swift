import AudioToolbox
import AppKit
import UserNotifications
import ZeroCore

/// Tasks' notifications and sounds, from the board as it changes (ZeroCore's TaskAlerts says what's worth one).
/// Looking at the task: its sound only. Elsewhere in Zero: a sound for what needs you or is in trouble, the sidebar
/// for the rest, and the phones if it still stands five minutes on. Away from Zero, or from the Mac (idle, locked,
/// asleep): a notification with its sound, on the phones too. One notification per task, replaced by its next,
/// and taken away once you've looked at the task or it has moved on, so none is left to clear by hand.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let navigation: Navigation
    private let settings: Settings
    /// Whether the workspace window is up where the user can see it.
    private let windowShown: () -> Bool
    private let open: (String) -> Void
    /// The board last heard: none yet, so what tasks are in at launch isn't announced.
    private var last: [BoardRow]?
    /// What each task was last announced as: it isn't announced again when a turn Zero started leaves it as it was.
    private var announced: [String: String] = [:]
    /// The asks notified (not a task's), by notification id, and whose: their agent's page clears them.
    private var asks: [String: String] = [:]
    /// Alerts only sounded (the user was at the Mac), by task: those still standing a few minutes on go to the phone.
    private var held: [String: (alert: TaskAlert, at: Date)] = [:]
    /// The screen locked or asleep: nobody at the Mac, whatever is in front.
    private var screenOff = false

    init(navigation: Navigation, settings: Settings, windowShown: @escaping () -> Bool, open: @escaping (String) -> Void) {
        self.navigation = navigation
        self.settings = settings
        self.windowShown = windowShown
        self.open = open
        super.init()
        center.delegate = self
        // Registered ahead, off the main thread: the first registered when it played cost 100 ms there.
        Chime.warm([BoardRow.State.needsYou, .trouble, .done].map(settings.sound(for:)) + ["Glass"])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted { Log.write("notifications not allowed: \(error.map { "\($0)" } ?? "turned off")") }
        }
        watchPlace()
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.looked() } }
        }
        watchScreen()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.catchUp() } }
    }

    /// At the Mac in Zero: it's in front with its window up, the screen awake and unlocked, and the keyboard or mouse
    /// touched in the last two minutes. In front with nobody there is away: the phones hear.
    private var present: Bool { NSApp.isActive && windowShown() && atMac }
    /// Someone at the Mac: the screen awake and unlocked, an input in the last two minutes, and the Mac touched since
    /// the phone was (on the phone instead, with the task still open on the Mac, the news goes to the phone).
    private var atMac: Bool { !screenOff && Self.idle < 120 && PhoneUse.last < Date().addingTimeInterval(-Self.idle) }

    /// Seconds since the user last touched the keyboard, mouse or trackpad.
    private static var idle: TimeInterval { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) }

    private func watchScreen() {
        let off: (Bool) -> (Notification) -> Void = { value in { [weak self] _ in MainActor.assumeIsolated { self?.screenOff = value } } }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: off(true))
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: off(false))
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: off(true))
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: off(false))
    }

    /// What was only sounded and still stands, five minutes on, goes to the phones (and the Mac's notifications).
    private func catchUp() {
        guard !held.isEmpty, let rows = last else { return }
        let front: String? = if case let .task(id) = navigation.place, NSApp.isActive, windowShown(), atMac { id } else { nil }
        let now = Date()
        for alert in TaskAlerts.due(held, rows: rows, now: now, front: front, lastInput: now.addingTimeInterval(-Self.idle)) {
            held[alert.session] = nil
            notifyAway(alert)
        }
        held = held.filter { now.timeIntervalSince($0.value.at) < 600 }
    }

    func board(_ rows: [BoardRow]) {
        NSApp.dockTile.badgeLabel = TaskAlerts.needingYou(rows).nonZero.map(String.init)
        guard let last else { self.last = rows; return }
        self.last = rows
        let (alerts, cleared) = TaskAlerts.changes(from: last, to: rows, announced: &announced)
        if !cleared.isEmpty { center.removeDeliveredNotifications(withIdentifiers: cleared); Phones.shared.clear(cleared); for id in cleared { held[id] = nil } }
        for alert in alerts where wanted(alert.kind) { announce(alert) }
    }

    private func wanted(_ kind: AlertKind) -> Bool {
        switch kind {
        case .needsYou: settings.notifyNeedsYou
        case .trouble: settings.notifyTrouble
        case .finished: settings.notifyFinished
        }
    }

    /// An agent's ask outside Zero's tasks (a terminal's, a permission it wants). In Zero (its window or the control bar
    /// in front), a sound; away, a notification on the Mac and the phones.
    func ask(_ ask: Ask, agent: String) {
        guard settings.notifyNeedsYou else { return }
        if NSApp.isActive && atMac {
            if settings.notificationSounds { Chime.play("Glass") }
            return
        }
        let alert = TaskAlerts.ask(ask, agent: agent)
        asks[alert.session] = ask.agent.name
        announce(alert)
    }

    /// Answered, withdrawn, expired or gone: its notification goes.
    func askEnded(_ id: String) {
        let key = TaskAlerts.askPrefix + id
        guard asks.removeValue(forKey: key) != nil else { return }
        clear([key])
    }

    /// The inbox, or the control bar, looked at: every ask's notification goes; an agent's page, that agent's.
    func lookedAtAsks(of agent: String? = nil) {
        let keys = asks.filter { agent == nil || $0.value == agent }.map(\.key)
        guard !keys.isEmpty else { return }
        for key in keys { asks[key] = nil }
        clear(keys)
    }

    /// Off the Mac and the phones.
    func clear(_ ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        Phones.shared.clear(ids)
    }

    private func announce(_ alert: TaskAlert) {
        if present {
            let looking = navigation.place == .task(alert.session)
            let sound = settings.sound(for: alert.state)
            if settings.notificationSounds && !sound.isEmpty && (looking || alert.kind != .finished) { Chime.play(sound) }
            held[alert.session] = (alert, Date())
            return
        }
        notifyAway(alert)
    }

    /// Away from the Mac (or not in Zero): a notification on it, and on the phones.
    private func notifyAway(_ alert: TaskAlert) {
        held[alert.session] = nil
        Phones.shared.push(alert, sound: settings.notificationSounds ? settings.sound(for: alert.state) : "")
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        // The notification's own sound, so Focus and the system's settings for Zero quiet it as they do any app's.
        let sound = settings.sound(for: alert.state)
        if settings.notificationSounds && !sound.isEmpty { content.sound = UNNotificationSound(named: UNNotificationSoundName(sound + ".aiff")) }
        center.add(UNNotificationRequest(identifier: alert.session, content: content, trigger: nil))
    }

    /// The task in front of the user has been seen: its notification goes.
    private func looked() {
        guard NSApp.isActive, windowShown() else { return }
        switch navigation.place {
        case let .task(id): clear([id])
        case .inbox: lookedAtAsks()
        case let .agent(name): lookedAtAsks(of: name)
        default: break
        }
    }

    private func watchPlace() {
        withObservationTracking { _ = navigation.place } onChange: { [weak self] in
            Task { @MainActor in self?.looked(); self?.watchPlace() }
        }
    }

    // Shown even while Zero is the active app (its control bar can be, with the window away).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Clicked: the task, opened.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run { open(id) }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// A short alert sound by name (the system's, or one in a Sounds folder), as NSSound names them. Played through the
/// system's sound service, which doesn't wait: NSSound loaded the file and opened audio on the main thread, 130 ms
/// each time, and the window froze while a question's card slid in. Each is registered once.
@MainActor enum Chime {
    private static var ids: [String: SystemSoundID] = [:]

    static func play(_ name: String) {
        if let id = ids[name] ?? register(name) { ids[name] = id; AudioServicesPlaySystemSound(id) }
    }

    static func warm(_ names: [String]) {
        for name in Set(names) where !name.isEmpty && ids[name] == nil {
            Task.detached(priority: .utility) {
                guard let id = register(name) else { return }
                await MainActor.run { if ids[name] == nil { ids[name] = id } }
            }
        }
    }

    private nonisolated static func register(_ name: String) -> SystemSoundID? {
        let folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
                       URL(fileURLWithPath: "/Library/Sounds"), URL(fileURLWithPath: "/System/Library/Sounds")]
        let found = folders.lazy.flatMap { folder in ["aiff", "aif", "wav", "caf"].map { folder.appendingPathComponent(name).appendingPathExtension($0) } }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? Bundle.main.url(forResource: name, withExtension: "aiff")
        var id: SystemSoundID = 0
        guard let found, AudioServicesCreateSystemSoundID(found as CFURL, &id) == noErr else { return nil }
        return id
    }
}
