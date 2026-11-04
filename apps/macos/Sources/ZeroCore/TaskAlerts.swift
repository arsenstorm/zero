import Foundation

/// What a task's change asks of the user: notified and sounded by the app (ZeroApp/Notifications.swift).
public enum AlertKind: String, Sendable { case needsYou, trouble, finished }

/// One task's notification: one per task, replaced by its next and cleared once it's out of date.
public struct TaskAlert: Equatable, Sendable {
    public let session: String
    public let kind: AlertKind
    /// The state it came to: what its sound is chosen by.
    public let state: BoardRow.State
    public let title: String
    public let body: String
}

public enum TaskAlerts {
    /// A lead's row as it stands for the user: its own state, or a worker's ask, which only the user can answer, as
    /// its own. A worker finishing or stuck is its lead's to deal with. Working, idle and paused ask nothing.
    static func standing(_ row: BoardRow) -> (kind: AlertKind, state: BoardRow.State, worker: Bool)? {
        let own = row.ownState
        if own == .needsYou { return (.needsYou, own, false) }
        if row.state == .needsYou { return (.needsYou, .needsYou, true) }
        switch own {
        case .trouble: return (.trouble, own, false)
        // A reply to a turn Zero started (an event, a worker's report): there to read, nothing to tell.
        case .answered where row.quiet == true: return nil
        case .handed, .done, .answered, .blocked, .completed: return (.finished, own, false)
        default: return nil
        }
    }

    /// From one board to the next: the tasks whose standing changed to one that asks something of the user, and those
    /// whose notification is out of date (moved on from, or gone from the board).
    public static func changes(from old: [BoardRow], to new: [BoardRow]) -> (alerts: [TaskAlert], cleared: [String]) {
        var announced: [String: BoardRow.State] = [:]
        return changes(from: old, to: new, announced: &announced)
    }

    /// Ends that a turn Zero started (passing on an event it follows, a worker's report) leaves as they were: a task
    /// back at the one last announced, after a moment's work, has nothing new to say.
    static let settled: Set<BoardRow.State> = [.done, .completed, .blocked, .handed]

    /// As above, `announced` keeping each task's state as last announced (the notifier's, across boards).
    public static func changes(from old: [BoardRow], to new: [BoardRow], announced: inout [String: BoardRow.State]) -> (alerts: [TaskAlert], cleared: [String]) {
        var alerts: [TaskAlert] = [], cleared: [String] = []
        for row in new {
            let now = standing(row), before = old.first { $0.session == row.session }.flatMap(standing)
            if now?.state == before?.state && now?.worker == before?.worker { continue }
            if before != nil { cleared.append(row.session) }
            guard let now else { continue }
            if !now.worker && settled.contains(now.state) && announced[row.session] == now.state { continue }
            announced[row.session] = now.state
            alerts.append(TaskAlert(session: row.session, kind: now.kind, state: now.state, title: plain(row.task), body: plain(body(row, now.state, worker: now.worker))))
        }
        for row in old where !new.contains(where: { $0.session == row.session }) && standing(row) != nil { cleared.append(row.session) }
        return (alerts, cleared)
    }

    /// An agent's ask that isn't a Zero task's (a terminal's `zero ask`, a permission it wants): its own notification,
    /// cleared once it's answered or the user has looked at the inbox.
    public static func ask(_ ask: Ask, agent: String) -> TaskAlert {
        let what = switch ask.kind {
        case .run: "Wants to run: " + (ask.command ?? ask.title)
        case .approve: "Wants your approval: " + ask.title
        default: ask.title
        }
        return TaskAlert(session: askPrefix + ask.id, kind: .needsYou, state: .needsYou, title: plain(agent), body: plain(what))
    }

    /// An ask's notification's identifier starts so; a task's is its session.
    public static let askPrefix = "ask-"

    /// Markdown as a notification shows it: its words, without the marks that are only noise there (**, `, #, links'
    /// addresses, list markers, code fences), its lines run together, and short.
    public static func plain(_ text: String, limit: Int = 200) -> String {
        var parts: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") || line.isEmpty { continue }
            line = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)"#, with: "", options: .regularExpression)
            let inline = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? line
            let words = inline.trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { parts.append(words) }
        }
        let joined = parts.joined(separator: " · ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return joined.count > limit ? String(joined.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : joined
    }

    /// The tasks waiting on the user, a worker's ask counted as its lead's: the Dock's badge.
    public static func needingYou(_ rows: [BoardRow]) -> Int { rows.filter { standing($0)?.kind == .needsYou }.count }

    private static func body(_ row: BoardRow, _ state: BoardRow.State, worker: Bool) -> String {
        if worker { return "A worker needs you" + (row.asks.first.map { ": " + $0.title } ?? "") }
        let detail: String? = switch state {
        case .needsYou: row.asks.first?.title ?? row.now
        case .handed: row.needs ?? row.now
        default: row.now
        }
        let name = switch state {
        case .needsYou: "Needs you"
        case .trouble: "In trouble"
        case .handed: "Over to you"
        case .answered: "Replied"
        case .blocked: "Blocked"
        case .completed: "Completed"
        default: "Done"
        }
        // An ask's own question says it; the rest say their state first.
        if state == .needsYou, let detail { return detail }
        return name + (detail.map { ": " + $0 } ?? "")
    }
}
