import Foundation

/// Links into a task's conversation: zero://task/<id>#<anchor>, or "#<anchor>" within the task's own words. An anchor is
/// a heading's (GitHub's, as pads have them: "## Bench plan" is #bench-plan) or an item's id; zerod finds which.
public enum TaskLinks {
    /// The task and anchor a link names; "#plan" is the `current` task's.
    public static func parse(_ url: URL, current: String? = nil) -> (task: String, anchor: String?)? {
        if url.scheme == nil, url.host() == nil, url.path().isEmpty, let anchor = url.fragment(), !anchor.isEmpty, let current {
            return (current, anchor)
        }
        guard url.scheme == "zero", url.host() == "task" else { return nil }
        let task = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let id = task.isEmpty ? current : task
        return id.map { ($0, url.fragment().flatMap { $0.isEmpty ? nil : $0 }) }
    }

    public static func link(_ task: String, _ anchor: String? = nil) -> String {
        "zero://task/\(task)" + (anchor.map { "#" + $0 } ?? "")
    }

    /// Markdown's "#anchor" links made the task's own, for words shown away from its conversation (an ask's card).
    public static func absolute(_ markdown: String, task: String) -> String {
        markdown.replacingOccurrences(of: "](#", with: "](zero://task/\(task)#")
    }
}

/// A passage of a task's conversation to show: its page opens on it, highlighted a moment. Asked from a card, the page
/// offers a way back to that ask.
public struct Reveal: Equatable, Sendable {
    public var task: String
    /// An item's id, or a heading's anchor (zerod finds it).
    public var anchor: String
    /// The ask it was opened from.
    public var ask: String?
    /// Each reveal its own, so the same passage shown twice shows twice.
    public var id = UUID()

    public init(task: String, anchor: String, ask: String? = nil) {
        self.task = task; self.anchor = anchor; self.ask = ask
    }
}

extension TimelineRow {
    /// The row an item is shown in, and the block within it: a turn's work holds its steps and words, a fold of quiet
    /// turns holds their blocks.
    public static func holding(_ item: String, in rows: [TimelineRow]) -> (row: String, block: String)? {
        for row in rows {
            let blocks: [TimelineBlock] =
                switch row {
                case let .block(block): [block]
                case let .quiet(_, blocks, _): blocks
                }
            for block in blocks where block.holds(item) { return (row.id, block.id) }
        }
        return nil
    }
}

extension TimelineBlock {
    public func holds(_ item: String) -> Bool {
        switch self {
        case let .user(shown), let .answer(shown), let .step(shown): shown.id == item
        case let .work(_, items, _, _, _): items.contains { $0.id == item }
        }
    }
}
