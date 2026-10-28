import Foundation

/// Markdown's blocks, as an agent's answer uses them: headings, paragraphs, lists (inside lists too), quotes, tables,
/// code and rules. The text inside each stays Markdown, for the app's text to style (bold, code, links).
public indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [Item])
    case code(String)
    case quote(String)
    case table([[String]])
    case rule

    /// A list item: its first line, and what's indented under it (more text, a list of its own).
    public struct Item: Equatable, Sendable {
        public var text: String
        public var children: [MarkdownBlock]
        public init(text: String, children: [MarkdownBlock] = []) { self.text = text; self.children = children }
    }

    public static func parse(_ text: String) -> [MarkdownBlock] { parse(lines: text.components(separatedBy: "\n")) }

    static func parse(lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if fence(trimmed) {
                var code: [String] = []
                i += 1
                while i < lines.count, !fence(lines[i].trimmingCharacters(in: .whitespaces)) { code.append(lines[i]); i += 1 }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
            } else if let heading = heading(trimmed) {
                blocks.append(heading)
                i += 1
            } else if rule(trimmed) {
                blocks.append(.rule)
                i += 1
            } else if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count, case let line = lines[i].trimmingCharacters(in: .whitespaces), line.hasPrefix(">") {
                    quoted.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
            } else if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                while i < lines.count, case let line = lines[i].trimmingCharacters(in: .whitespaces), line.hasPrefix("|") {
                    let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    // The line under the headings (|---|:--:|) is layout, not a row.
                    if !cells.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) { rows.append(cells) }
                    i += 1
                }
                blocks.append(.table(rows))
            } else if marker(lines[i]) != nil {
                blocks.append(list(lines, from: &i))
            } else {
                var paragraph: [String] = []
                while i < lines.count {
                    let line = lines[i].trimmingCharacters(in: .whitespaces)
                    if line.isEmpty || fence(line) || heading(line) != nil || line.hasPrefix(">") || line.hasPrefix("|") || marker(lines[i]) != nil || (rule(line) && !paragraph.isEmpty) { break }
                    paragraph.append(line)
                    i += 1
                }
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }
        return blocks
    }

    /// The list starting at line `i`: its items at that indent and kind, each with what's indented under it.
    private static func list(_ lines: [String], from i: inout Int) -> MarkdownBlock {
        guard let first = marker(lines[i]) else { return .paragraph(lines[i]) }
        var items: [Item] = []
        while i < lines.count, let item = marker(lines[i]), item.indent == first.indent, item.ordered == first.ordered {
            i += 1
            var body: [String] = []
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    // A blank line keeps the item going only if what follows is indented under it.
                    var next = i
                    while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                    guard next < lines.count, indent(lines[next]) > first.indent else { break }
                    body += Array(repeating: "", count: next - i)
                    i = next
                } else if indent(lines[i]) > first.indent {
                    body.append(String(lines[i].dropFirst(min(indent(lines[i]), item.width))))
                    i += 1
                } else {
                    break
                }
            }
            items.append(Item(text: item.content, children: parse(lines: body)))
            // Blank lines between items keep the list going.
            var next = i
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            if next < lines.count, let following = marker(lines[next]), following.indent == first.indent, following.ordered == first.ordered { i = next }
        }
        return .list(ordered: first.ordered, start: first.number, items: items)
    }

    private struct Marker { let indent: Int; let ordered: Bool; let number: Int; let content: String; let width: Int }

    /// "- item", "* item", "12. item", "3) item", with how far in it is and how wide its marker.
    private static func marker(_ line: String) -> Marker? {
        guard let match = line.firstMatch(of: #/^( *)([-*+]|(\d{1,9})[.)])[ \t]+(.*)$/#) else { return nil }
        let indent = match.output.1.count
        let number = match.output.3.flatMap { Int($0) }
        let width = line.count - match.output.4.count
        return Marker(indent: indent, ordered: number != nil, number: number ?? 1, content: String(match.output.4), width: width)
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
    private static func fence(_ line: String) -> Bool { line.hasPrefix("```") || line.hasPrefix("~~~") }
    private static func rule(_ line: String) -> Bool { line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil }

    private static func heading(_ line: String) -> MarkdownBlock? {
        guard let match = line.firstMatch(of: #/^(#{1,6})[ \t]+(.*?)[ \t#]*$/#) else { return nil }
        return .heading(level: match.output.1.count, text: String(match.output.2))
    }
}
