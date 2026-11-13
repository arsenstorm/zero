import Foundation

/// What a task's Copy menu puts on the clipboard beyond its id, link and title: Markdown to paste elsewhere.
public enum TaskCopy {
    /// [title](zero://task/<id>), its brackets escaped so the link holds.
    public static func titleLink(_ title: String, task: String) -> String {
        let escaped = title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(TaskLinks.link(task)))"
    }

    /// The latest answer, without Zero's ending line.
    public static func lastAnswer(_ items: [ConversationItem]) -> String? {
        for item in items.reversed() {
            if case let .agent(text, true) = item.kind { return ZeroEnding.split(text).0 }
        }
        return nil
    }

    /// The whole conversation: the user's messages, the answers and Zero's notices, each under its heading; the steps
    /// between them folded to a line each.
    public static func markdown(title: String, items: [ConversationItem]) -> String {
        var blocks = ["# \(title)"]
        var steps: [String] = []
        func flush() {
            if !steps.isEmpty { blocks.append(steps.joined(separator: "\n")); steps = [] }
        }
        for item in items {
            switch item.kind {
            case let .user(text, _):
                flush()
                if let given = ConversationItem.from(text) {
                    blocks.append("### From \(given.from == "zero" ? "Zero" : given.from)\n\n\(given.text)")
                } else {
                    blocks.append("### You\n\n\(text)")
                }
            case let .agent(text, _):
                flush()
                let words = ZeroEnding.split(text).0
                if !words.isEmpty { blocks.append("### Agent\n\n\(words)") }
            case let .notice(text, _):
                flush()
                blocks.append("> \(oneLine(text))")
            case .reasoning: break
            case .plan: steps.append("- Planned")
            case let .command(command, _, _, _, _, description):
                steps.append("- " + (description.isEmpty ? "`\(oneLine(command))`" : oneLine(description)))
            case let .fileChange(changes):
                steps.append("- Edited " + changes.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))
            case let .tool(name, detail):
                steps.append("- \(name)" + (detail.isEmpty ? "" : ": \(oneLine(detail))"))
            case let .table(title, _, _):
                steps.append("- Table: \(title)")
            }
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }

    /// What a prompt to carry the work on elsewhere is made of.
    public struct Brief: Sendable {
        public var title: String
        public var ticket: String?
        public var folder: String
        public var branch: String?
        /// Where it stands: its agent's last note.
        public var now: String?
        public var answer: String?
        /// What it follows (pull requests, issues), a line each.
        public var follows: [String] = []
        /// What's waiting: open asks, what it needs from the user, messages queued, its issues not done.
        public var pending: [String] = []
        public init(title: String, folder: String) { self.title = title; self.folder = folder }
    }

    /// A prompt that stands on its own: another agent, given only this, can carry on the work.
    public static func prompt(_ brief: Brief) -> String {
        var facts = ["- Folder: \(brief.folder)"]
        if let ticket = brief.ticket, !ticket.isEmpty { facts.insert("- Ticket: \(ticket)", at: 0) }
        if let branch = brief.branch, !branch.isEmpty { facts.append("- Branch: \(branch)") }
        var blocks = [
            "Carry on with a task another agent started. What it is and where it got to are below; read the folder's "
                + "current state before changing anything.",
            "# \(brief.title)\n\n" + facts.joined(separator: "\n"),
        ]
        if let now = brief.now, !now.isEmpty { blocks.append("## Where it stands\n\n\(now)") }
        if !brief.pending.isEmpty { blocks.append("## Pending\n\n" + brief.pending.map { "- \($0)" }.joined(separator: "\n")) }
        if !brief.follows.isEmpty { blocks.append("## Followed\n\n" + brief.follows.map { "- \($0)" }.joined(separator: "\n")) }
        if let answer = brief.answer, !answer.isEmpty { blocks.append("## The last answer\n\n\(answer)") }
        return blocks.joined(separator: "\n\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
