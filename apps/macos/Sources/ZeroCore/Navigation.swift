import Observation

/// Where the workspace window is, and where it has been: back and forward (the mouse's side buttons, ⌘[ and ⌘])
/// retrace it. The app moves it too (Settings… in the menu opens the window on Settings).
@MainActor @Observable
public final class Navigation {
    public enum Place: Hashable, Sendable { case home, board, task(String), settings }

    public var place = Place.home {
        didSet { if place != oldValue && !travelling { behind.append(oldValue); ahead.removeAll() } }
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
