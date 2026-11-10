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
        // Blocked: can't go on at all, confirmed: as big as trouble, and told the same way.
        case .trouble, .blocked: return (.trouble, own, false)
        // A reply to a turn Zero started (an event, a worker's report): there to read, nothing to tell.
        case .answered where row.quiet == true: return nil
        case .handed, .done, .answered, .waiting: return (.finished, own, false)
        default: return nil
        }
    }

    /// From one board to the next: the tasks whose standing changed to one that asks something of the user, and those
    /// whose notification is out of date (moved on from, or gone from the board).
    public static func changes(from old: [BoardRow], to new: [BoardRow]) -> (alerts: [TaskAlert], cleared: [String]) {
        var announced: [String: String] = [:]
        return changes(from: old, to: new, announced: &announced)
    }

    /// Ends that a turn Zero started (passing on an event it follows, a worker's report) leaves as they were: a task
    /// back at the one last announced, after a moment's work, has nothing new to say.
    static let settled: Set<BoardRow.State> = [.done, .waiting, .handed]

    /// What a task was announced as: its state, and when it needs the user, what it asks (its open asks, else its words).
    /// Back at the same after a turn Zero started, it has nothing new to say; a question it hadn't asked is news.
    static func announcement(_ row: BoardRow, _ state: BoardRow.State) -> String {
        guard state == .needsYou else { return state.rawValue }
        let issues = onYou(row).map { $0.ticket + " " + $0.text }.joined(separator: "|")
        // On the user for its issues alone: those are what it says, not the lead's latest words, which change with
        // every turn it takes on something else (the same issue came again after each).
        let asked = row.asks.isEmpty ? (issues.isEmpty ? row.now ?? "" : "") : row.asks.map { $0.id + " " + $0.title }.joined(separator: "|")
        return state.rawValue + ":" + asked + "#" + issues
    }

    /// What the tasks stand at when Zero opens, as if announced: what was news before it reopened isn't news again.
    public static func announced(_ rows: [BoardRow]) -> [String: String] {
        var announced: [String: String] = [:]
        for row in rows { if let now = standing(row), !now.worker { announced[row.session] = announcement(row, now.state) } }
        return announced
    }

    /// As above, `announced` keeping what each task was last announced as (the notifier's, across boards).
    public static func changes(from old: [BoardRow], to new: [BoardRow], announced: inout [String: String]) -> (alerts: [TaskAlert], cleared: [String]) {
        var alerts: [TaskAlert] = [], cleared: [String] = []
        for row in new {
            let previous = old.first { $0.session == row.session }
            let now = standing(row), before = previous.flatMap(standing)
            // An issue of a lead's newly on the user is news, though the lead was on them already.
            let newIssue = onYou(row).contains { mine in !(previous.map(onYou) ?? []).contains { $0.ticket == mine.ticket } }
            if now?.state == before?.state && now?.worker == before?.worker && !newIssue { continue }
            if before != nil { cleared.append(row.session) }
            guard let now else { continue }
            let said = announcement(row, now.state)
            if !now.worker && (settled.contains(now.state) || now.state == .needsYou) && announced[row.session] == said { continue }
            // Its issues alone again, all of them announced already (with an ask since answered, too): nothing new.
            let issues = onYou(row).map { $0.ticket + " " + $0.text }.joined(separator: "|")
            if !now.worker, now.state == .needsYou, row.asks.isEmpty, !issues.isEmpty, !newIssue,
               announced[row.session]?.hasSuffix("#" + issues) == true { continue }
            announced[row.session] = said
            // An issue that has just turned to the user is the news, by its ticket.
            let issue = onYou(row).first { mine in !(previous.map(onYou) ?? []).contains { $0.ticket == mine.ticket } } ?? onYou(row).first
            let news = now.state == .needsYou && !now.worker ? issue.map { "\($0.ticket): \($0.text)" } : nil
            alerts.append(TaskAlert(session: row.session, kind: now.kind, state: now.state, title: plain(row.task), body: plain(news ?? body(row, now.state, worker: now.worker))))
        }
        for row in old where !new.contains(where: { $0.session == row.session }) && standing(row) != nil { cleared.append(row.session) }
        return (alerts, cleared)
    }

    /// Alerts sounded while the user was at the Mac (no notification, no phone) that still stand `after` seconds on:
    /// the user may have walked away just then, so they go to the phone. Not one for the task open in front when the
    /// user has touched the Mac since it came: that one was read there.
    public static func due(_ held: [String: (alert: TaskAlert, at: Date)], rows: [BoardRow], now: Date, front: String?, lastInput: Date,
                           after: TimeInterval = 300) -> [TaskAlert] {
        held.values.filter { alert, at in
            guard now.timeIntervalSince(at) >= after, let row = rows.first(where: { $0.session == alert.session }) else { return false }
            let read = front == alert.session && lastInput > at
            return standing(row)?.state == alert.state && !read
        }.map(\.alert).sorted { $0.session < $1.session }
    }

    /// A lead's issues on the user, by its rows (`zero issue`).
    static func onYou(_ row: BoardRow) -> [BoardRow.Issue] { (row.issues ?? []).filter { $0.state == "you" } }

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
    // Compiled once: a notification's text is worked out for every task on every change of the board.
    private static let lineMark = try! NSRegularExpression(pattern: #"^(#{1,6}\s+|>\s*|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)"#)
    private static let spaces = try! NSRegularExpression(pattern: #"\s+"#)

    public static func plain(_ text: String, limit: Int = 200) -> String {
        var parts: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") || line.isEmpty { continue }
            line = Self.lineMark.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            let inline = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? line
            let words = inline.trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { parts.append(words) }
        }
        let together = parts.joined(separator: " · ")
        let joined = Self.spaces.stringByReplacingMatches(in: together, range: NSRange(location: 0, length: (together as NSString).length), withTemplate: " ")
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
        case .blocked: "Blocked"
        case .handed: "Over to you"
        case .answered: "Replied"
        case .waiting: "Waiting"
        default: "Done"
        }
        // An ask's own question says it; the rest say their state first.
        if state == .needsYou, let detail { return detail }
        return name + (detail.map { ": " + $0 } ?? "")
    }
}
