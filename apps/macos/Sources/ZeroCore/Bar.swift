/// A part of the control bar, as Settings › Control bar › In the bar lists them.
public enum BarPart: String, CaseIterable, Sendable {
    case inbox, workspaces, agents

    /// The user's order, kept as names: parts it doesn't know are dropped, parts it lacks (new ones) follow in
    /// today's order, so a kept order never loses a part.
    public static func order(_ stored: [String]) -> [BarPart] {
        var parts: [BarPart] = []
        for part in stored.compactMap(BarPart.init) where !parts.contains(part) { parts.append(part) }
        return parts + allCases.filter { !parts.contains($0) }
    }
}

/// Which agents the bar has a dot for.
public enum BarAgents: String, CaseIterable, Sendable {
    case all, needsYou, pinned, none

    public func shows(_ name: String, needsYou: Bool, pinned: Set<String>) -> Bool {
        switch self {
        case .all: true
        case .needsYou: needsYou
        case .pinned: pinned.contains(name)
        case .none: false
        }
    }
}

extension BoardRow.State {
    /// A step that is the user's: an ask, a hand-over, or trouble to look at.
    public var needsYou: Bool { self == .needsYou || self == .handed || self == .trouble }
}

/// The dots the user pinned to the bar ("Pinned tasks only"), kept a name a line as the sidebar's order is.
public enum BarPins {
    public static func set(_ stored: String) -> Set<String> { Set(stored.split(separator: "\n").map(String.init)) }
    public static func toggle(_ name: String, in stored: String) -> String {
        var pins = set(stored)
        if pins.remove(name) == nil { pins.insert(name) }
        return pins.sorted().joined(separator: "\n")
    }
}

/// Which of the bar's two buttons (the inbox at its top, the settings at its foot) the pointer on the bar brings out:
/// the one it's near, the nearer one where it's near both, and both where it's near neither (over the agents).
public enum BarReach: Sendable {
    case inbox, settings, both

    /// Near is within 12 pt of a button's edge. `was` is what's out now: it holds on for 3 pt past each line, so a
    /// pointer resting on one doesn't flicker the buttons.
    public static func at(_ y: Double, height: Double, was: BarReach, button: Double = 32) -> BarReach {
        let top = button / 2, foot = height - button / 2, near = button / 2 + 12, slack = 3.0
        let split = (top + foot) / 2 + (was == .inbox ? slack : was == .settings ? -slack : 0)
        let nearInbox = y - top <= near + (was == .inbox ? slack : 0)
        let nearSettings = foot - y <= near + (was == .settings ? slack : 0)
        if nearInbox, !nearSettings || y < split { return .inbox }
        return nearSettings ? .settings : .both
    }
}
