import Foundation

/// A task's followed links by the issue each is about, for the details pane: an issue's own link (its Linear issue)
/// and its pull requests, the same change in several repositories as one; then what's about no issue, and the
/// channels. A link is about an issue when it's that issue (`linear/<ticket>`) or its name carries the ticket.
public struct LinkGroups {
    public struct Change: Identifiable {
        public var id: String { follows[0].id }
        public let name: String
        public let state: String?
        public let closed: Bool
        /// One per repository, in the order followed.
        public let follows: [ZerodLink.Followed]
    }

    public struct Issue: Identifiable {
        public var id: String { ticket }
        public let ticket: String
        public let issue: ZerodLink.Followed?
        public let changes: [Change]
        /// Done on the lead's board, or (without a board) everything in it closed: shown behind the pane's count.
        public let folded: Bool
    }

    public let issues: [Issue]
    /// About no issue: pull requests, issues and threads, in the order followed.
    public let other: [ZerodLink.Followed]
    public let channels: [ZerodLink.Followed]

    /// `issues` in the order to show them, with whether each is done on the board (nil without one). Issues with no
    /// link of their own are left out.
    public static func of(_ follows: [ZerodLink.Followed], issues: [(ticket: String, done: Bool?)]) -> LinkGroups {
        var groups: [Issue] = []
        var taken = Set<String>()
        for (ticket, done) in issues {
            let own = follows.filter { !taken.contains($0.id) && about($0, ticket) }
            guard !own.isEmpty else { continue }
            taken.formUnion(own.map(\.id))
            let issue = own.first { $0.source == "linear" }
            var changes: [Change] = []
            for follow in own where follow.source == "github" {
                let name = shorn(follow.name ?? follow.summary, of: ticket)
                if let i = changes.firstIndex(where: { $0.name == name && $0.state == follow.state }) {
                    changes[i] = Change(name: name, state: follow.state, closed: changes[i].closed, follows: changes[i].follows + [follow])
                } else {
                    changes.append(Change(name: name, state: follow.state, closed: follow.closed ?? false, follows: [follow]))
                }
            }
            let folded = done ?? own.allSatisfy { $0.closed ?? false }
            groups.append(Issue(ticket: ticket, issue: issue, changes: changes, folded: folded))
        }
        let rest = follows.filter { !taken.contains($0.id) }
        let channel = { (f: ZerodLink.Followed) in f.source == "slack" && f.topic.split(separator: "/").count == 2 }
        return LinkGroups(issues: groups, other: rest.filter { !channel($0) }, channels: rest.filter(channel))
    }

    /// A pull request's name without the ticket it starts with, which its issue's line says.
    private static func shorn(_ name: String, of ticket: String) -> String {
        guard name.hasPrefix(ticket) else { return name }
        let rest = name.dropFirst(ticket.count).drop { $0 == ":" || $0 == " " }
        return rest.isEmpty ? name : String(rest)
    }

    /// The issue itself, or a pull request whose name carries the ticket as a word ("ENG-1 Fix", "ENG-1: Fix").
    private static func about(_ follow: ZerodLink.Followed, _ ticket: String) -> Bool {
        let parts = follow.topic.split(separator: "/")
        if follow.source == "linear" { return parts.count > 1 && parts[1] == ticket }
        guard follow.source == "github" else { return false }
        let words = (follow.name ?? follow.summary).split { !($0.isLetter || $0.isNumber || $0 == "-") }
        return words.contains { $0 == ticket }
    }
}
