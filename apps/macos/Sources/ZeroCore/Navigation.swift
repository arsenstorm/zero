import Foundation
import Observation

/// Where the workspace window is, and where it has been: back and forward (the mouse's side buttons, ⌘[ and ⌘])
/// retrace it. The app moves it too (Settings… in the menu opens the window on Settings).
@MainActor @Observable
public final class Navigation {
    public enum Place: Hashable, Sendable { case home, board, task(String), settings }

    public var place = Place.home {
        didSet {
            if place != oldValue { worker = nil }
            if place != oldValue && !travelling { behind.append(oldValue); ahead.removeAll() }
        }
    }
    /// On a task's page: the worker shown instead of its lead.
    public var worker: String?
    /// The pane on a task's right, open or not, as it was last left.
    public var pane = UserDefaults.standard.object(forKey: "taskPane") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pane, forKey: "taskPane") }
    }
    @ObservationIgnored private var behind: [Place] = []
    @ObservationIgnored private var ahead: [Place] = []
    public var canGoBack: Bool { !behind.isEmpty }
    public var canGoForward: Bool { !ahead.isEmpty }
    @ObservationIgnored private var travelling = false

    public init() {}

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
