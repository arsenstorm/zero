import AppKit
import UserNotifications
import ZeroCore

/// Tasks' notifications and sounds, from the board as it changes (ZeroCore's TaskAlerts says what's worth one).
/// Looking at the task: its sound only. Elsewhere in Zero: a sound for what needs you or is in trouble, the sidebar
/// for the rest. Away from Zero: a notification with its sound. One notification per task, replaced by its next,
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

    init(navigation: Navigation, settings: Settings, windowShown: @escaping () -> Bool, open: @escaping (String) -> Void) {
        self.navigation = navigation
        self.settings = settings
        self.windowShown = windowShown
        self.open = open
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted { Log.write("notifications not allowed: \(error.map { "\($0)" } ?? "turned off")") }
        }
        watchPlace()
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.looked() } }
        }
    }

    func board(_ rows: [BoardRow]) {
        NSApp.dockTile.badgeLabel = TaskAlerts.needingYou(rows).nonZero.map(String.init)
        guard let last else { self.last = rows; return }
        self.last = rows
        let (alerts, cleared) = TaskAlerts.changes(from: last, to: rows, announced: &announced)
        if !cleared.isEmpty { center.removeDeliveredNotifications(withIdentifiers: cleared); Phones.shared.clear(cleared) }
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
        if NSApp.isActive {
            if settings.notificationSounds { NSSound(named: "Glass")?.play() }
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
        let inZero = NSApp.isActive && windowShown()
        if inZero {
            let looking = navigation.place == .task(alert.session)
            let sound = settings.sound(for: alert.state)
            if settings.notificationSounds && !sound.isEmpty && (looking || alert.kind != .finished) { NSSound(named: sound)?.play() }
            return
        }
        // Away from Zero on the Mac: the phones hear too.
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
