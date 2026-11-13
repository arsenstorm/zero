import Foundation
import Observation

/// Where the workspace window is, and where it has been: back and forward (the mouse's side buttons, ⌘[ and ⌘])
/// retrace it. The app moves it too (Settings… in the menu opens the window on Settings).
@MainActor @Observable
public final class Navigation {
    public enum Place: Hashable, Sendable {
        case home, inbox, board, task(String), agent(String), settings, pads, pad(String), loops, loop(String), later,
            laterItem(String)
    }

    /// Where the window is. A worker's task set here by its own id (a link, an inbox card, a report: every way into a
    /// task comes through here) is its lead's page with it shown, as the sidebar opens it, so the sidebar shows where
    /// you are; one step in the history.
    public var place: Place {
        get { at }
        set {
            var place = newValue
            var shown: String?
            if case let .task(id) = newValue, let lead = leadOf?(id), lead != id { place = .task(lead); shown = id }
            let old = at
            at = place
            if place != old && !travelling { behind.append((old, worker, settingsPage)); ahead.removeAll() }
            if place != old && !travelling {
                changingPlace = true; worker = shown; changingPlace = false
            } else if let shown {
                worker = shown
            }
            UserDefaults.standard.set(place.key, forKey: "place")
            switch place {
            case .home, .board, .task, .agent: homePlace = place;
            default: break
            }
        }
    }
    private var at = Place.home
    /// The lead whose page shows a worker (the app's: its tasks' parents), nil for a lead.
    @ObservationIgnored public var leadOf: (@MainActor (String) -> String?)?
    /// Where Home was last: the task that was open, so the rail's Home goes back to it rather than to New task.
    public private(set) var homePlace = Place.home
    /// On a task's page: the worker shown instead of its lead. Showing one is a step in the history too: back from a
    /// worker is its lead, not the page before the lead.
    public var worker: String? {
        didSet {
            UserDefaults.standard.set(worker, forKey: "placeWorker")
            if worker != oldValue && !travelling && !changingPlace { behind.append((place, oldValue, settingsPage)); ahead.removeAll() }
        }
    }
    /// In Settings: the page open. Each page is a step in the history too, so back goes to the page before it, then
    /// out of Settings.
    public var settingsPage: String? {
        didSet {
            if settingsPage != oldValue && !travelling && place == .settings { behind.append((place, worker, oldValue)); ahead.removeAll() }
        }
    }

    /// The control bar works with this window: what it opens opens here, not in its own panel.
    public var barDocked = false
    /// The window on screen: open, not minimised, not wholly covered. Off it, conversations aren't redrawn as agents work.
    public var windowShown = true
    /// On a scratchpad: the section a link pointed at, to scroll to once.
    public var padSection: String?
    /// Past the splash: the window shows its places, and the toolbar its arrows.
    public var ready = false
    /// The pane on a task's right, open or not, as it was last left.
    public var pane = UserDefaults.standard.object(forKey: "taskPane") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pane, forKey: "taskPane") }
    }
    /// The task open last in each workspace (and the worker shown on it), so going back to the workspace opens it.
    @ObservationIgnored private var lastTasks = UserDefaults.standard.dictionary(forKey: "lastTasks") as? [String: [String]] ?? [:]

    public func remember(_ task: String, worker: String?, in workspace: String) {
        let kept = [task] + (worker.map { [$0] } ?? [])
        guard lastTasks[workspace] != kept else { return }
        lastTasks[workspace] = kept
        UserDefaults.standard.set(lastTasks, forKey: "lastTasks")
    }

    /// The workspace shown changed: the task open last there, while it's still there (`keeps`: not archived, not
    /// moved to another workspace); else a new task. Away from the tasks (Settings, a scratchpad), the window stays.
    public func arrive(in workspace: String, keeps: (String) -> Bool) {
        switch place {
        case .home, .board, .task: break;
        default: return
        }
        guard let last = lastTasks[workspace], let task = last.first, keeps(task) else { place = .home; return }
        place = .task(task)
        worker = last.count > 1 && keeps(last[1]) ? last[1] : nil
    }

    /// Each step: the place, the worker shown there, and the settings page open.
    @ObservationIgnored private var behind: [(Place, String?, String?)] = []
    @ObservationIgnored private var ahead: [(Place, String?, String?)] = []
    /// A place change is clearing the worker: not a step of its own.
    @ObservationIgnored private var changingPlace = false
    public var canGoBack: Bool { !behind.isEmpty }
    public var canGoForward: Bool { !ahead.isEmpty }
    @ObservationIgnored private var travelling = false

    /// With `restoring`, where the window was last (and the worker shown there), so Zero opens there again after a
    /// quit or an update.
    public init(restoring: Bool = false) {
        guard restoring else { return }
        let kept = UserDefaults.standard.string(forKey: "place")
        place = kept.flatMap(Place.init(key:)) ?? .home
        // Integrations was a place of its own before it became Settings' pages.
        if kept == "integrations" { place = .settings; settingsPage = "GitHub" }
        worker = UserDefaults.standard.string(forKey: "placeWorker")
    }

    public func goBack() {
        guard let last = behind.popLast() else { return }
        ahead.append((place, worker, settingsPage))
        travel(to: last)
    }

    public func goForward() {
        guard let next = ahead.popLast() else { return }
        behind.append((place, worker, settingsPage))
        travel(to: next)
    }

    private func travel(to step: (Place, String?, String?)) {
        travelling = true
        self.place = step.0
        worker = step.1
        settingsPage = step.2
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
        case .pads: "pads"
        case let .pad(id): "pad:" + id
        case .loops: "loops"
        case let .loop(name): "loop:" + name
        case .later: "later"
        case let .laterItem(id): "later:" + id
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
        case "pads": self = .pads
        case "pad": self = .pad(value)
        case "loops": self = .loops
        case "loop": self = .loop(value)
        case "later": self = value.isEmpty ? .later : .laterItem(value)
        default: return nil
        }
    }
}
