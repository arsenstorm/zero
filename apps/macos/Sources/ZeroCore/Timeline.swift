import Foundation

// A conversation read as both apps show it: your messages, then each turn's work folded under one line with only its
// answer in full.

/// One thing in the timeline: a message of yours, a turn's work, an answer, or a step that shows on its own (a notice).
public enum TimelineBlock: Identifiable, Equatable, Sendable {
    case user(ConversationItem)
    case work(id: String, items: [ConversationItem], start: Date?, end: Date?, live: Bool)
    case answer(ConversationItem)
    case step(ConversationItem)

    public var id: String {
        switch self {
        case let .user(item), let .answer(item), let .step(item): item.id
        case let .work(id, _, _, _, _): id
        }
    }

    /// The items as blocks: everything between your message and the agent's answer is the turn's work. The work still
    /// going at the end is live while the agent is at it.
    public static func of(_ items: [ConversationItem], working: Bool) -> [TimelineBlock] {
        var blocks: [TimelineBlock] = []
        var work: [ConversationItem] = []
        var start: Date?
        func flush(end: Date?, live: Bool) {
            guard let first = work.first else { return }
            blocks.append(.work(id: "work-" + first.id, items: work, start: start ?? first.date, end: end ?? work.last?.date, live: live))
            work = []
        }
        for item in items {
            switch item.kind {
            case .user:
                flush(end: nil, live: false)
                blocks.append(.user(item))
                start = item.date
            case let .agent(text, finalAnswer: true):
                // Ending on an ask: the words just before it are the reasoning behind the question, shown in full above
                // it rather than folded with the commands. Only words that are the work's last: words with steps after
                // them stay where they were, above those steps (moved below them, they jumped as the turn ended).
                var before: ConversationItem?
                if case .asked? = ZeroEnding.split(text).1, case .agent(_, false)? = work.last?.kind {
                    before = work.removeLast()
                }
                flush(end: item.date, live: false)
                if let before { blocks.append(.answer(before)) }
                blocks.append(.answer(item))
            case .notice(_, error: true):
                // A failure mid-turn reads like the agent's interim words: in the work, where it happened.
                work.append(item)
            case .notice, .table:
                // Something to see without opening anything: a notice, or a table the agent handed to Zero. Where it
                // happened: the work so far closes before it, and what follows is a block of its own.
                flush(end: item.date, live: false)
                start = nil
                blocks.append(.step(item))
            default:
                work.append(item)
            }
        }
        // Working with nothing to show yet (it's thinking before its first step): the live block anyway, so it never looks
        // stuck.
        if working && work.isEmpty, !blocks.isEmpty {
            blocks.append(.work(id: "work-live", items: [], start: start, end: nil, live: true))
        }
        flush(end: nil, live: working)
        return blocks
    }

    /// The message of yours each block answers to, for the rail.
    public static func turns(_ blocks: [TimelineBlock]) -> [String: String] {
        var owner: [String: String] = [:]
        var current: String?
        for block in blocks {
            if case let .user(item) = block { current = item.id }
            if let current { owner[block.id] = current }
        }
        return owner
    }
}

/// A row of the conversation as the Mac lays it out: a block, or turns Zero started that changed nothing for the user,
/// folded into one.
public enum TimelineRow: Identifiable, Equatable, Sendable {
    case block(TimelineBlock)
    case quiet(id: String, blocks: [TimelineBlock], turns: Int)

    public var id: String {
        switch self {
        case let .block(block): block.id
        case let .quiet(id, _, _): id
        }
    }

    /// Turns a worker's report or an event started that asked the user nothing and set no issue row: folded,
    /// consecutive ones together, so what changed for the user stands out. The last turn, being read, never folds.
    public static func of(_ blocks: [TimelineBlock]) -> [TimelineRow] {
        var turns: [[TimelineBlock]] = [[]]
        for block in blocks {
            if case .user = block, !turns[turns.count - 1].isEmpty { turns.append([]) }
            turns[turns.count - 1].append(block)
        }
        var rows: [TimelineRow] = []
        var folded: [[TimelineBlock]] = []
        func fold() {
            // Named by its last turn: older pages coming in above add turns at its start, and it stays the same row.
            if let last = folded.last?.first {
                rows.append(.quiet(id: "quiet-" + last.id, blocks: folded.flatMap { $0 }, turns: folded.count))
            }
            folded = []
        }
        for (index, turn) in turns.enumerated() {
            if index < turns.count - 1, quiet(turn) { folded.append(turn); continue }
            fold()
            rows += turn.map(TimelineRow.block)
        }
        fold()
        return rows
    }

    nonisolated(unsafe) private static let changes = #/\bzero (run|ask|approve|issue)\b|\bzero_(run|ask|approve|issue)\b|\[zero: asked/#

    private static func quiet(_ turn: [TimelineBlock]) -> Bool {
        guard case let .user(first)? = turn.first, case let .user(text, _) = first.kind, let given = ConversationItem.from(text) else {
            return false
        }
        // The user's own answer to an ask, passed on by Zero: theirs, not an update that needed nothing from them.
        if NoticeText.headline(given.text) != nil { return false }
        let items = turn.dropFirst().flatMap { block -> [ConversationItem] in
            switch block {
            case let .work(_, items, _, _, live): live ? [] : items
            case let .answer(item), let .step(item), let .user(item): [item]
            }
        }
        if turn.contains(where: { if case let .work(_, _, _, _, live) = $0 { live } else { false } }) { return false }
        return !items.contains { item in
            switch item.kind {
            case let .command(command, _, _, _, _, _): command.contains(changes)
            case let .tool(name, _): name.contains(changes)
            case let .agent(text, _): text.contains(changes)
            case .table: true
            default: false
            }
        }
    }
}

extension ConversationItem {
    /// The ask this step made, when it was the agent asking the user through Zero (`zero run`, `zero ask`,
    /// `zero approve`): by its id in what the step printed, else by its words in the command, the first asked from when
    /// the step began. Its card stands in the step's place.
    // Built once: every command step of a page asks, every time the page is drawn.
    nonisolated(unsafe) private static let zeroAsks = #/\bzero (run|ask|approve)\b/#
    nonisolated(unsafe) private static let askID = #/ask ([a-z0-9]{6})/#

    public func ask(in asks: [Ask], session: String) -> Ask? {
        guard case let .command(command, _, output, _, _, _) = kind,
            command.firstMatch(of: Self.zeroAsks) != nil
        else { return nil }
        let own = asks.filter { $0.isAgents(in: session) }
        if let id = output.firstMatch(of: Self.askID).map({ String($0.output.1) }),
            let ask = own.first(where: { $0.id == id })
        {
            return ask
        }
        let since = date?.addingTimeInterval(-5) ?? .distantPast
        return own.filter { $0.createdAt >= since && command.contains(($0.kind == .run ? $0.command : nil) ?? $0.title) }
            .min { $0.createdAt < $1.createdAt }
    }
}

extension Ask {
    /// The zerod session that asked, when one did.
    public var session: String? { agent.ref ?? (agent.name.hasPrefix("zerod-") ? String(agent.name.dropFirst("zerod-".count)) : nil) }

    /// The agent's own ask in this session (`zero ask`, `approve`, `run`), not the provider's questions and approvals.
    public func isAgents(in session: String) -> Bool {
        self.session == session && request == nil && ![.note, .message].contains(kind)
    }
}

extension BoardRow {
    /// A risk column's cell that opens with its level ("medium. No dry run for the backfill", "Merge risk: high"): the
    /// level, and whatever follows it.
    public static func risk(_ text: String) -> (String, String)? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        if let colon = rest.range(of: ":"), rest[..<colon.lowerBound].localizedCaseInsensitiveContains("risk") {
            rest = String(rest[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard let level = ["low", "medium", "high"].first(where: { rest.lowercased().hasPrefix($0) }) else { return nil }
        let after = rest.dropFirst(level.count)
        guard after.isEmpty || !(after.first?.isLetter ?? false) else { return nil }
        return (level, after.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:—– ")))
    }
}

/// A cell of a table an agent handed over (`zero table`), as the Mac and the phone draw it: a risk column's grade
/// with the gaps behind it, a state as the board's pill, a dash for nothing, or words.
public enum TableCell: Equatable, Sendable {
    case risk(level: String, gaps: String)
    case state(BoardRow.State)
    case empty
    case text(String)

    public static func of(_ text: String, column: String) -> TableCell {
        if column.localizedCaseInsensitiveContains("risk"), let (level, rest) = BoardRow.risk(text) {
            return .risk(level: level, gaps: rest)
        }
        if let state = BoardRow.State.named(text) { return .state(state) }
        if ["", "-", "—", "–"].contains(text) { return .empty }
        return .text(text)
    }
}

extension BoardRow.State {
    /// A cell that names a state, in the board's words or the agents' usual ones.
    public static func named(_ text: String) -> Self? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "needs you", "needsyou": .needsYou
        case "blocked", "waiting": .waiting
        case "over to you", "handed": .handed
        case "trouble", "in trouble", "failed", "stuck": .trouble
        case "working": .working
        case "done", "completed", "merged": .done
        case "replied", "answered": .answered
        case "idle": .idle
        case "offline": .offline
        default: nil
        }
    }
}

extension BoardRow {
    /// How the sidebar orders tasks: by state (the board's own order), by name, or as they were dragged.
    public enum Sort: String, CaseIterable, Sendable { case state, name, manual }

    /// The rows as the sidebar shows them; `order` is the dragged one, a session per line, tasks not in it on top.
    public static func sorted(_ rows: [BoardRow], by sort: Sort, order: String) -> [BoardRow] {
        switch sort {
        case .state: return rows
        case .name: return rows.sorted { $0.task.localizedStandardCompare($1.task) == .orderedAscending }
        case .manual:
            let rank = Dictionary(
                order.split(separator: "\n").enumerated().map { (String($1), $0) }, uniquingKeysWith: { first, _ in first })
            return rows.enumerated().sorted { (rank[$0.element.session] ?? -1, $0.offset) < (rank[$1.element.session] ?? -1, $1.offset) }
                .map(\.element)
        }
    }
}

/// How long something took, as a conversation says it: "Thought for 8s", "Worked for 2m 37s"; under a second, "for a
/// moment" (a "0s" reads as something broken).
public enum Took {
    public static func length(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    public static func text(_ verb: String, _ seconds: TimeInterval?) -> String {
        guard let seconds else { return verb }
        return seconds < 1 ? verb + " for a moment" : verb + " for " + length(seconds)
    }
}

/// A tool as people say it, and its arguments as their values: "Linear · list comments", "ENG-9737 · 5".
/// A message sent from here that its conversation doesn't have yet (its agent still starting, say): shown at once,
/// as yours, until the conversation has a message of yours from after it was sent.
public struct Sending: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let images: [String]
    /// When it was sent, in milliseconds since 1970, as items' times are.
    public let at: Int
    public init(text: String, images: [String], at: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        id = "sending-\(UUID().uuidString)"; self.text = text; self.images = images; self.at = at
    }

    /// The conversation's items, then those sent and not in it yet.
    public static func merge(_ items: [ConversationItem], _ sending: [Sending]) -> [ConversationItem] {
        guard !sending.isEmpty else { return items }
        let latest = items.last { if case .user = $0.kind { true } else { false } }?.at ?? 0
        let waiting = sending.filter { latest < $0.at }
        return items
            + waiting.map {
                ConversationItem(id: $0.id, turn: nil, kind: .user(text: $0.text, images: $0.images), status: .done, at: $0.at)
            }
    }
}

/// What a task is called: the name it was given, its title, the gist of your first message, or its agent and folder.
public enum TaskName {
    public static func of(_ conversation: Conversation) -> String {
        if let label = conversation.label, !label.isEmpty { return label }
        if let title = conversation.title, !title.isEmpty { return title }
        for item in conversation.items {
            if case let .user(text, _) = item.kind, let gist = gist(of: text) { return gist }
        }
        #if os(macOS)
            let folder = Projects.name(of: conversation.cwd)
        #else
            // The phone has no names of its own for folders (Projects isn't part of its build).
            let folder = (conversation.cwd as NSString).lastPathComponent
        #endif
        return "\(conversation.provider.title) in \(folder)"
    }

    /// A prompt's first line as a name: its first five words, when it has at least three.
    public static func gist(of prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(["'"])) }.filter {
            !$0.isEmpty
        }
        guard words.count >= 3 else { return nil }
        let kept = words.prefix(5).joined(separator: " ")
        return kept.prefix(1).uppercased() + kept.dropFirst() + (words.count > 5 ? "…" : "")
    }
}

/// A notice's words, its links (a server's sign-in) ready to open; anything else as it was written, not read as
/// Markdown (a command's `*` stays a `*`).
public enum NoticeText {
    public static func attributed(_ text: String) -> AttributedString {
        guard text.contains("](http"), let linked = try? AttributedString(markdown: text) else { return AttributedString(text) }
        return linked
    }

    /// Zero's word to an agent about one of its asks, as its folded row reads to the user: what came of it ("Ask
    /// answered with “…”"), not "The user answered your ask…", which is written for the agent. Nil for anything else.
    public static func headline(_ text: String) -> String? {
        if text.hasPrefix("The user answered your ask "), let colon = text.range(of: "\"): ") {
            let answer =
                text[colon.upperBound...].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
                ?? ""
            return "Ask answered with “\(answer)”"
        }
        if text.hasPrefix("The user declined your ask ") { return "Ask declined" }
        if text.hasPrefix("Your ask "), text.contains(" expired without an answer") { return "Ask expired" }
        if text.hasPrefix("The user ran your command ") { return "Command ran" }
        if text.hasPrefix("The user rejected your command ") { return "Command rejected" }
        return nil
    }
}

public enum ToolNames {
    /// "mcp__linear-server__list_comments" → "Linear · list comments"; Claude Code's Agent tool is a subagent, said so;
    /// anything else as it is.
    public static func name(_ raw: String) -> String {
        if raw == "Agent" || raw == "Task" { return "Subagent" }
        guard raw.hasPrefix("mcp__") else { return raw }
        let parts = raw.dropFirst("mcp__".count).components(separatedBy: "__")
        guard parts.count >= 2 else { return raw }
        // "linear-server", "plugin_zero_zero": the service's own name, its last word.
        let server =
            parts[0].replacingOccurrences(of: "-server", with: "").split(whereSeparator: { $0 == "_" || $0 == "-" }).last.map(String.init)
            ?? parts[0]
        return server.capitalized + " · " + parts[1...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// A JSON object's values, shortest first (what it's about before what it says); anything else as it is.
    public static func detail(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        let values: [String] = object.values.compactMap { value in
            switch value {
            case let text as String: text
            case let number as NSNumber: number.stringValue
            case let list as [Any]: list.map { "\($0)" }.joined(separator: ", ")
            default: nil
            }
        }
        return values.sorted { $0.count < $1.count }.joined(separator: " · ")
    }
}

/// A command as a step's row says it, when the agent gave no words for what it does: the line that says something.
/// A heredoc's first line is only its interpreter (`python3 - <<'EOF'`), so its body's first line goes with it; a
/// leading `cd somewhere &&` is where, not what.
public enum CommandText {
    nonisolated(unsafe) private static let heredoc = #/\s*<<-?\s*['"]?\w+['"]?/#
    nonisolated(unsafe) private static let cd = #/^cd\s+\S+\s*&&\s*/#

    public static func line(_ command: String) -> String {
        let lines = command.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var first = lines.first else { return "" }
        first = first.replacing(cd, with: "")
        guard first.contains(heredoc) else { return first }
        let head = first.replacing(heredoc, with: "")
        return lines.count > 1 ? head + " · " + lines[1] : head
    }
}

/// A run of steps folded to one line, as Codex says them: "Thought, ran 3 commands, edited a file".
public enum StepSummary {
    public static func text(_ steps: [ConversationItem]) -> String {
        var thought = false, commands = 0, files = 0, tools = 0, other = 0
        for step in steps {
            switch step.kind {
            case .reasoning: thought = true
            case .command: commands += 1
            case let .fileChange(changes): files += changes.count
            case .tool: tools += 1
            default: other += 1
            }
        }
        let count = { (n: Int, one: String, word: String) in n == 1 ? one : "\(n) \(word)s" }
        var parts: [String] = []
        if thought { parts.append("thought") }
        if commands > 0 { parts.append("ran " + count(commands, "a command", "command")) }
        if files > 0 { parts.append("edited " + count(files, "a file", "file")) }
        if tools > 0 { parts.append("used " + count(tools, "a tool", "tool")) }
        if other > 0 { parts.append(count(other, "a step", "step")) }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
