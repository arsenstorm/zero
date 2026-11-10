import SwiftUI
import ZeroCore

/// One line of a diff as shown: what it is, its numbers in the old file and the new, and its words without the marker.
struct DiffLine: Equatable {
    enum Kind { case context, added, removed, hunk }
    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String

    static let green = Color(
        nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 0.42, green: 0.85, blue: 0.52, alpha: 1) : NSColor(red: 0.10, green: 0.55, blue: 0.24, alpha: 1)
        })
    static let red = Color(
        nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 1.0, green: 0.48, blue: 0.45, alpha: 1) : NSColor(red: 0.78, green: 0.16, blue: 0.16, alpha: 1)
        })

    /// A unified diff's lines, numbered from its hunk headers; a new file's text (with or without "+"s) all added.
    static func parse(_ diff: String, added: Bool) -> [DiffLine] {
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var out: [DiffLine] = []
        var old = 1, new = 1
        for line in lines {
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { continue }
            if line.hasPrefix("@@") {
                // "@@ -12,7 +12,9 @@ func name": the numbers start there; what follows is the place, shown quietly.
                let numbers = line.split(separator: " ").dropFirst().prefix(2)
                old = numbers.first.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? old
                new = numbers.dropFirst().first.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? new
                let place = line.components(separatedBy: "@@").dropFirst(2).joined(separator: "@@").trimmingCharacters(in: .whitespaces)
                out.append(DiffLine(kind: .hunk, old: nil, new: nil, text: place))
                continue
            }
            if added {
                out.append(DiffLine(kind: .added, old: nil, new: new, text: line.hasPrefix("+") ? String(line.dropFirst()) : line))
                new += 1
            } else if line.hasPrefix("+") {
                out.append(DiffLine(kind: .added, old: nil, new: new, text: String(line.dropFirst()))); new += 1
            } else if line.hasPrefix("-") {
                out.append(DiffLine(kind: .removed, old: old, new: nil, text: String(line.dropFirst()))); old += 1
            } else {
                out.append(DiffLine(kind: .context, old: old, new: new, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line));
                old += 1; new += 1
            }
        }
        // A first hunk's header says nothing a reader needs when nothing comes before it.
        if out.first?.kind == .hunk, out.first?.text.isEmpty == true { out.removeFirst() }
        return out
    }
}

/// A diff as GitHub and Codex draw one: line numbers in a gutter, only the changed lines tinted (green added, red
/// taken out, a stronger edge in the gutter, the marker in the line's colour), the places between hunks quiet.
struct DiffText: View {
    let lines: [DiffLine]
    init(lines: [DiffLine]) { self.lines = lines }
    /// A whole diff (a turn's every change), parsed.
    init(diff: String, added: Bool = false) { lines = DiffLine.parse(diff, added: added) }
    /// Past this many lines, the rest is said rather than drawn: a generated file would cost the page.
    private static let shown = 1500

    var body: some View {
        let width = CGFloat(String(lines.compactMap { $0.new ?? $0.old }.max() ?? 1).count) * 7.4 + 10
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(Self.shown).enumerated()), id: \.offset) { _, line in row(line, gutter: width) }
                if lines.count > Self.shown {
                    Text("\(lines.count - Self.shown) more lines").font(.system(size: 11)).foregroundStyle(.tertiary).padding(
                        .horizontal, 12
                    ).padding(.vertical, 6)
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
        .thinScrollbar()
        .frame(maxHeight: 360)
    }

    @ViewBuilder private func row(_ line: DiffLine, gutter: CGFloat) -> some View {
        if line.kind == .hunk {
            HStack(spacing: 8) {
                Text("⋯").frame(width: gutter * 2, alignment: .center)
                Text(line.text).lineLimit(1)
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            .padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
        } else {
            let tint: Color? = line.kind == .added ? DiffLine.green : line.kind == .removed ? DiffLine.red : nil
            HStack(spacing: 0) {
                Text(line.old.map(String.init) ?? "").frame(width: gutter, alignment: .trailing)
                Text(line.new.map(String.init) ?? "").frame(width: gutter, alignment: .trailing)
                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").foregroundStyle(tint ?? .clear).frame(width: 18)
                Text(line.text.isEmpty ? " " : line.text).foregroundStyle(.primary).fixedSize()
                Spacer(minLength: 12)
            }
            .font(.system(size: 11.5, design: .monospaced).monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.vertical, 1)
            .background(tint.map { $0.opacity(0.1) } ?? .clear)
            .overlay(alignment: .leading) { if let tint { Rectangle().fill(tint.opacity(0.7)).frame(width: 2) } }
        }
    }
}
