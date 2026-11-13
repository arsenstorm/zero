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
