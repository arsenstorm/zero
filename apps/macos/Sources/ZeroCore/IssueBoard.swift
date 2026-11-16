import Foundation

/// A lead's issues as its board in the conversation shows them: in zerod's order when it opens (on the user first, as
/// board.rs sorts them), each row kept in its place while it's shown, and the cells a change touched lit.
public enum IssueBoard {
    /// What of a row a change touched.
    public enum Cell: Sendable { case state, text }

    /// zerod's IssueState order (model.rs).
    private static let order = ["you", "over", "working", "waiting", "parked", "done"]
    private static func rank(_ state: String) -> Int { order.firstIndex(of: state) ?? order.count }

    /// On the user first, then over to them, at work, waiting, parked, done; in each, the longest in it first.
    public static func sorted(_ issues: [BoardRow.Issue]) -> [BoardRow.Issue] {
        issues.sorted { (rank($0.state), $0.since) < (rank($1.state), $1.since) }
    }

    /// The rows in the order they were shown: a new one at the end, one gone left out. Nothing moves under the pointer.
    public static func kept(_ issues: [BoardRow.Issue], order shown: [String]) -> [BoardRow.Issue] {
        let place = Dictionary(shown.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let known = issues.filter { place[$0.ticket] != nil }.sorted { place[$0.ticket]! < place[$1.ticket]! }
        return known + sorted(issues.filter { place[$0.ticket] == nil })
    }

    /// The cells each row's change touched, by ticket; a new row has none.
    public static func changed(from before: [BoardRow.Issue], to after: [BoardRow.Issue]) -> [String: Set<Cell>] {
        var lit: [String: Set<Cell>] = [:]
        for issue in after {
            guard let was = before.first(where: { $0.ticket == issue.ticket }) else { continue }
            var cells: Set<Cell> = []
            if was.state != issue.state { cells.insert(.state) }
            if was.text != issue.text { cells.insert(.text) }
            if !cells.isEmpty { lit[issue.ticket] = cells }
        }
        return lit
    }

    /// How many in each state, for the strip, in the board's order; states with none left out.
    public static func counts(_ issues: [BoardRow.Issue]) -> [(state: BoardRow.State, count: Int)] {
        order.compactMap { state in
            let n = issues.filter { $0.state == state }.count
            return n == 0 ? nil : (Self.state(state), n)
        }
    }

    /// A state's name (`zero issue`'s) as the sidebar's state.
    public static func state(_ name: String) -> BoardRow.State {
        BoardRow.Issue(ticket: "", state: name, text: "", since: 0).boardState
    }

    /// The states it went through; without its steps (an older zerod's), the one it's in.
    public static func steps(_ issue: BoardRow.Issue) -> [BoardRow.Issue.Step] {
        issue.history ?? [BoardRow.Issue.Step(state: issue.state, text: issue.text, at: issue.since)]
    }

    /// Its time in its state: "14m", "3h", "2d".
    public static func age(since: Int, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince1970 - Double(since) / 1000) / 60)
        return minutes < 60 ? "\(minutes)m" : minutes < 48 * 60 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
    }
}
