/// A part of the control bar, as Settings › Control bar › In the bar lists them.
public enum BarPart: String, CaseIterable, Sendable {
    case inbox, agents

    /// The user's order, kept as names: parts it doesn't know are dropped, parts it lacks (new ones) follow in
    /// today's order, so a kept order never loses a part.
    public static func order(_ stored: [String]) -> [BarPart] {
        var parts: [BarPart] = []
        for part in stored.compactMap(BarPart.init) where !parts.contains(part) { parts.append(part) }
        return parts + allCases.filter { !parts.contains($0) }
    }
}

/// Whose agents the bar shows: every workspace's, grouped, or only the window's workspace's.
public enum BarAgentsFrom: String, CaseIterable, Sendable {
    case all, window
}

/// The bar's agents by workspace, always in the rail's order (the window's workspace in its own place: switching the
/// window changes which group is the window's, never the order). Another workspace than the window's folds to its
/// mark unless something there waits on the user. A workspace with no agents has no group.
public struct BarGroup: Equatable, Sendable {
    public var workspace: String
    /// Its dots' names, in the bar's order.
    public var dots: [String]
    /// How many of its agents are at work.
    public var running: Int
    /// Something there waits on the user.
    public var waiting: Bool
    /// The window's workspace: no mark, never folded.
    public var window: Bool
    /// Folded to its mark: another workspace with nothing waiting on the user.
    public var folds: Bool { !window && !waiting }
}

public enum BarGroups {
    /// A dot, and what the grouping reads of it. `workspace`: nil for an agent outside Zero (a terminal's), which
    /// goes with the window's workspace.
    public struct Dot: Sendable {
        public var name: String
        public var workspace: String?
        public var running: Bool
        public var waiting: Bool
        public init(name: String, workspace: String?, running: Bool, waiting: Bool) {
            self.name = name; self.workspace = workspace; self.running = running; self.waiting = waiting
        }
    }

    /// The groups carry their workspace's mark: more than one shows, or the one that does isn't the window's.
    public static func marked(_ groups: [BarGroup]) -> Bool { groups.count > 1 || groups.first?.window == false }

    /// A group in words, for its mark's tip and VoiceOver: "Infra · 2 working", "Website · needs you · 1 working".
    public static func summary(name: String, _ group: BarGroup) -> String {
        var parts = [name]
        if group.waiting { parts.append("needs you") }
        if group.running > 0 { parts.append("\(group.running) working") }
        if parts.count == 1 { parts.append("nothing working") }
        return parts.joined(separator: " · ")
    }

    /// `workspaces`: the rail's order; a workspace it doesn't list (not loaded yet) follows, in the dots' order.
    public static func make(_ dots: [Dot], workspaces: [String], window: String, from: BarAgentsFrom) -> [BarGroup] {
        let home = { (dot: Dot) in dot.workspace ?? window }
        let shown = from == .all ? dots : dots.filter { home($0) == window }
        let order = workspaces + [window] + shown.map(home)
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }.compactMap { id in
            let mine = shown.filter { home($0) == id }
            guard !mine.isEmpty else { return nil }
            return BarGroup(
                workspace: id, dots: mine.map(\.name), running: mine.filter(\.running).count, waiting: mine.contains(where: \.waiting),
                window: id == window)
        }
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

/// Which of the bar's two buttons (the inbox at its top, the settings at its foot) the pointer on the bar is at: the
/// one it's near, the nearer one where it's near both, and neither where it's near neither (over the agents, which
/// keep the buttons folded).
public enum BarReach: Sendable {
    case inbox, settings, neither

    /// Near is within 12 pt of a button's edge. `was` is what's out now: it holds on for 3 pt past each line, so a
    /// pointer resting on one doesn't flicker the buttons.
    public static func at(_ y: Double, height: Double, was: BarReach, button: Double = 32) -> BarReach {
        let top = button / 2, foot = height - button / 2, near = button / 2 + 12, slack = 3.0
        let split = (top + foot) / 2 + (was == .inbox ? slack : was == .settings ? -slack : 0)
        let nearInbox = y - top <= near + (was == .inbox ? slack : 0)
        let nearSettings = foot - y <= near + (was == .settings ? slack : 0)
        if nearInbox, !nearSettings || y < split { return .inbox }
        return nearSettings ? .settings : .neither
    }
}
