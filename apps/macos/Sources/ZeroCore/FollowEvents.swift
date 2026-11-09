import Foundation

/// zerod's message to an agent about what it follows (following.rs `format`), read back for the conversation: each
/// thing followed, under its line (`topic  —  title`, its link on the next), and its events, two spaces in, their
/// words and link four.
public enum FollowEvents {
    public struct Group: Equatable, Sendable {
        public var topic: String
        public var title = ""
        public var url: String?
        public var events: [Event] = []
        /// What it is, short: a pull request as `repo#123`, anything else by its last part.
        public var name: String {
            let parts = topic.split(separator: "/")
            if parts.count == 4, parts[0] == "github" { return "\(parts[2])#\(parts[3])" }
            return parts.last.map(String.init) ?? topic
        }
    }

    public struct Event: Equatable, Sendable {
        public var summary: String
        public var body = ""
        public var url: String?
        /// Possibly the user's own action, echoing back.
        public var mine = false
    }

    private static let echo = " (you: possibly your own action echoing back)"

    public static func parse(_ text: String) -> [Group] {
        var lines = text.components(separatedBy: "\n")
        guard let head = lines.first, head.contains(" on what you follow") else { return [] }
        lines.removeFirst()
        var groups: [Group] = []
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let words = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("    ") {
                guard !groups.isEmpty, !groups[groups.count - 1].events.isEmpty else { continue }
                let i = groups[groups.count - 1].events.count - 1
                var event = groups[groups.count - 1].events[i]
                if words.hasPrefix("http"), !words.contains(" ") { event.url = words }
                else { event.body += (event.body.isEmpty ? "" : "\n") + words }
                groups[groups.count - 1].events[i] = event
            } else if line.hasPrefix("  ") {
                guard !groups.isEmpty else { continue }
                let mine = words.hasSuffix(echo)
                groups[groups.count - 1].events.append(Event(summary: mine ? String(words.dropLast(echo.count)) : words, mine: mine))
            } else if !groups.isEmpty, groups[groups.count - 1].events.isEmpty, words.hasPrefix("http") {
                groups[groups.count - 1].url = words
            } else {
                let parts = words.components(separatedBy: "  —  ")
                groups.append(Group(topic: parts[0], title: parts.dropFirst().joined(separator: "  —  ")))
            }
        }
        return groups
    }
}
