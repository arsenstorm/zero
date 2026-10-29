import Foundation
import Observation

/// Where the workspace window is, and where it has been: back and forward (the mouse's side buttons, ⌘[ and ⌘])
/// retrace it. The app moves it too (Settings… in the menu opens the window on Settings).
@MainActor @Observable
public final class Navigation {
    public enum Place: Hashable, Sendable { case home, inbox, board, task(String), agent(String), settings, integrations, integration(String), pads, pad(String) }

    public var place = Place.home {
        didSet {
            if place != oldValue { worker = nil }
            if place != oldValue && !travelling { behind.append(oldValue); ahead.removeAll() }
            UserDefaults.standard.set(place.key, forKey: "place")
        }
    }
    /// On a task's page: the worker shown instead of its lead.
    public var worker: String? {
        didSet { UserDefaults.standard.set(worker, forKey: "placeWorker") }
    }


    /// The control bar works with this window: what it opens opens here, not in its own panel.
    public var barDocked = false
    /// On a scratchpad: the section a link pointed at, to scroll to once.
    public var padSection: String?
    /// Past the splash: the window shows its places, and the toolbar its arrows.
    public var ready = false
    /// The pane on a task's right, open or not, as it was last left.
    public var pane = UserDefaults.standard.object(forKey: "taskPane") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pane, forKey: "taskPane") }
    }
    @ObservationIgnored private var behind: [Place] = []
    @ObservationIgnored private var ahead: [Place] = []
    public var canGoBack: Bool { !behind.isEmpty }
    public var canGoForward: Bool { !ahead.isEmpty }
    @ObservationIgnored private var travelling = false

    /// With `restoring`, where the window was last (and the worker shown there), so Zero opens there again after a
    /// quit or an update.
    public init(restoring: Bool = false) {
        guard restoring else { return }
        place = UserDefaults.standard.string(forKey: "place").flatMap(Place.init(key:)) ?? .home
        worker = UserDefaults.standard.string(forKey: "placeWorker")
    }

    public func goBack() {
        guard let last = behind.popLast() else { return }
        ahead.append(place)
        travel(to: last)
    }

    public func goForward() {
        guard let next = ahead.popLast() else { return }
        behind.append(place)
        travel(to: next)
    }

    private func travel(to place: Place) {
        travelling = true
        self.place = place
        travelling = false
    }
}

public extension Navigation.Place {
    /// The place as a word to keep: "task:<id>", "inbox", and so on.
    var key: String {
        switch self {
        case .home: "home"
        case .inbox: "inbox"
        case .board: "board"
        case let .task(id): "task:" + id
        case let .agent(name): "agent:" + name
        case .settings: "settings"
        case .integrations: "integrations"
        case let .integration(name): "integration:" + name
        case .pads: "pads"
        case let .pad(id): "pad:" + id
        }
    }

    init?(key: String) {
        let (kind, value) = key.firstIndex(of: ":").map { (String(key[..<$0]), String(key[key.index(after: $0)...])) } ?? (key, "")
        switch kind {
        case "home": self = .home
        case "inbox": self = .inbox
        case "board": self = .board
        case "task": self = .task(value)
        case "agent": self = .agent(value)
        case "settings": self = .settings
        case "integrations": self = .integrations
        case "integration": self = .integration(value)
        case "pads": self = .pads
        case "pad": self = .pad(value)
        default: return nil
        }
    }
}
