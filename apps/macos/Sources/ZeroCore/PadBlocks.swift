import Foundation

/// A scratchpad cut into the blocks the page shows and edits one at a time: a heading, a paragraph, a list, a table,
/// a code block, a quote, an image. Each keeps its exact text and the blank lines after it, so the blocks joined are
/// the pad as written: a block not edited stays byte for byte as an agent wrote it.
public struct PadBlock: Equatable, Sendable {
    /// Blank lines before the first block; empty for the others.
    public var lead: String
    /// The block's lines, without the line break after its last.
    public var body: String
    /// What follows it up to the next block: its line break and any blank lines.
    public var gap: String

    public init(lead: String = "", body: String, gap: String) { self.lead = lead; self.body = body; self.gap = gap }
    public var text: String { lead + body + gap }

    public enum Kind: Equatable, Sendable { case heading(Int), paragraph, list, table, code, quote, rule, image(path: String) }

    public var kind: Kind {
        let first = body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        if PadBlocks.fenceOpen(first) != nil { return .code }
        if let level = PadBlocks.heading(first) { return .heading(level) }
        if trimmed.hasPrefix("|") { return .table }
        if PadBlocks.listItem(first) { return .list }
        if trimmed.hasPrefix(">") { return .quote }
        if PadBlocks.rule.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil { return .rule }
        if !body.contains("\n"), let match = trimmed.range(of: #"^!\[[^\]]*\]\(([^)\s]+)\)$"#, options: .regularExpression) {
            let link = trimmed[match]
            let path = link[link.index(after: link.firstIndex(of: "(")!)..<link.index(before: link.endIndex)]
            return .image(path: String(path))
        }
        return .paragraph
    }
}

public enum PadBlocks {
    public static func split(_ text: String) -> [PadBlock] {
        var lines = text.components(separatedBy: "\n")
        // "a\nb\n" is two lines and a final break, not three.
        let endsWithBreak = lines.last == ""
        if endsWithBreak { lines.removeLast() }
        var blocks: [PadBlock] = []
        var lead = ""
        var body: [String] = []
        var gap: [String] = []
        var fence: String?

        func flush() {
            guard !body.isEmpty else { return }
            blocks.append(PadBlock(lead: blocks.isEmpty ? lead : "", body: body.joined(separator: "\n"), gap: "\n" + gap.map { $0 + "\n" }.joined()))
            body = []; gap = []
        }

        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if let open = fence {
                body.append(line)
                if fenceClose(line, open) { fence = nil }
                continue
            }
            if blank {
                if body.isEmpty && blocks.isEmpty { lead += line + "\n" } else { gap.append(line) }
                continue
            }
            let current = PadBlock(body: body.joined(separator: "\n"), gap: "").kind
            let continues: Bool = {
                guard !body.isEmpty else { return false }
                if fenceOpen(line) != nil || heading(line) != nil { return false }
                if case .heading = current { return false }
                // A list runs on past blank lines while what follows is an item or indented under one.
                if current == .list { return gap.isEmpty || listItem(line) || line.first == " " || line.first == "\t" }
                guard gap.isEmpty else { return false }
                // A rule and an image stand alone; a quote, a table and prose each end where the other starts.
                let next = PadBlock(body: line, gap: "").kind
                let alone = { (kind: PadBlock.Kind) in if case .image = kind { true } else { kind == .rule } }
                if alone(next) || alone(current) { return false }
                return (current == .table) == (next == .table) && (current == .quote) == (next == .quote)
            }()
            if continues {
                body.append(contentsOf: gap)
                gap = []
                body.append(line)
            } else {
                flush()
                body = [line]
                if let open = fenceOpen(line) { fence = open }
            }
        }
        flush()
        // The final break, or its absence, is the last block's: the text comes back exactly.
        if var last = blocks.popLast() {
            if !endsWithBreak { last.gap.removeLast() }
            blocks.append(last)
        } else if !lead.isEmpty || !text.isEmpty {
            return [PadBlock(lead: text, body: "", gap: "")]
        }
        return blocks
    }

    public static func join(_ blocks: [PadBlock]) -> String { blocks.map(\.text).joined() }

    static func fenceOpen(_ line: String) -> String? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3 else { return nil }
        for mark in ["```", "~~~"] where trimmed.hasPrefix(mark) { return String(trimmed.prefix { $0 == mark.first }) }
        return nil
    }

    static func fenceClose(_ line: String, _ open: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(open) && trimmed.allSatisfy { $0 == open.first }
    }

    static func heading(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first.map({ $0 == " " || $0 == "\t" }) ?? true else { return nil }
        return hashes
    }

    /// A list's item: "- ", "* ", "1. " and the like.
    static func listItem(_ line: String) -> Bool {
        item.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }
    // Compiled once: a pad's every line is sorted into blocks as it's typed in.
    static let rule = try! NSRegularExpression(pattern: #"^(-{3,}|\*{3,}|_{3,})$"#)
    private static let item = try! NSRegularExpression(pattern: #"^\s*([-*+]|\d+[.)])(\s|$)"#)
    private static let divider = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$"#)

    // A table's cells, and back.

    /// A table's rows of cells, its header first, the line under the header left out.
    public static func cells(_ table: String) -> [[String]] {
        table.split(separator: "\n").map(String.init).filter { !isDivider($0) }.map(row)
    }

    /// A table from its rows, the first the header; `divider` kept when it still fits (its alignment, as written).
    public static func table(_ rows: [[String]], divider: String? = nil) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        let line = { (cells: [String]) in "| " + (cells + Array(repeating: "", count: width - cells.count)).map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
        let kept = divider.flatMap { row($0).count == width ? $0 : nil } ?? "|" + Array(repeating: "---", count: width).joined(separator: "|") + "|"
        return ([line(rows[0]), kept] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    public static func divider(of table: String) -> String? { table.split(separator: "\n").map(String.init).first(where: isDivider) }

    static func isDivider(_ line: String) -> Bool {
        divider.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    static func row(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped { cell.append(character == "|" ? "|" : "\\\(character)"); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(cell); cell = ""; continue }
            cell.append(character)
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        // The pipes at each end make an empty cell either side.
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|") && !line.hasSuffix("\\|") { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
