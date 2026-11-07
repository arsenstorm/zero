import AppKit
import SwiftUI
import ZeroCore

struct ItemView: View {
    let item: ConversationItem
    let cwd: String
    /// When the step after this one began: how long a thought took.
    var until: Date? = nil

    var body: some View {
        switch item.kind {
        case let .user(text, images):
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    // In rows, from the right: many images wrap rather than widen the message past the page.
                    WrappingStack(spacing: 6, trailing: true) { ForEach(images, id: \.self) { Thumbnail(path: $0, side: 88, among: images) } }
                }
                if !text.isEmpty {
                    HStack {
                        Spacer(minLength: 80)
                        // As an answer reads: links that open (zero://, PRs, commits, tickets) and code as code, an
                        // image's token as its pill; the bubble hugs its words.
                        MarkdownText(ImageToken.linked(text, images: images), cwd: cwd, size: 14.5, hugs: true, yours: true).padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case let .agent(text, final):
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text, cwd: cwd, size: 14.5)
                if final { CopyButton(text: text) }
            }
        case let .reasoning(text):
            ReasoningRow(text: text, seconds: until.flatMap { until in item.date.map { until.timeIntervalSince($0) } })
        case let .plan(text):
            Text(text).font(.system(.callout, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
        case let .command(command, _, output, exitCode, _):
            CommandCard(command: command, output: output, exitCode: exitCode, status: item.status)
        case let .fileChange(changes):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(changes, id: \.path) { change in FileChangeCard(change: change, status: item.status, cwd: cwd) }
            }
        case let .tool(name, detail):
            // A row like every step's: its name as people say it, its arguments as their values, not JSON.
            HStack(alignment: .top, spacing: 8) {
                StatusIcon(status: item.status)
                Text(ToolNames.name(name)).fontWeight(.medium)
                Text(ToolNames.detail(detail)).foregroundStyle(.secondary).truncationMode(.tail)
            }
            .font(.callout).lineLimit(1).tip(detail)
        case let .notice(text, error):
            if error {
                CautionCallout(text: text)
            } else {
                // The icon on the first line, centred on its letters, however many lines the notice runs to.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        // Running: something under way the agent is silent through, as compacting the conversation.
                        if item.status == .running { StatusIcon(status: item.status) } else { NucleoIcon("circle-info", size: 14) }
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    Text(NoticeText.attributed(text))
                }
                    .font(.callout).foregroundStyle(.secondary).tint(.primary)
            }
        case let .table(title, columns, rows):
            TableCard(title: title, columns: columns, rows: rows, cwd: cwd)
        }
    }
}

/// Copies an answer; a tick for a moment says it did.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            NucleoIcon(copied ? "circle-check" : "copy", size: 13).foregroundStyle(.secondary).frame(width: 22, height: 22)
        }
        .buttonStyle(Hovering(radius: 6)).tip("Copy")
    }
}

private struct StatusIcon: View {
    let status: ItemStatus
    var body: some View {
        Group {
            switch status {
            case .running: Spinner().frame(width: 12, height: 12)
            case .done: NucleoIcon("circle-check", fill: "glyph", size: 14).foregroundStyle(.green)
            case .failed: NucleoIcon("circle-xmark", fill: "glyph", size: 14).foregroundStyle(.red)
            case .declined: NucleoIcon("ban", size: 14).foregroundStyle(.orange)
            }
        }
        // One size whatever the state (a step ending moves nothing), the first line's height: it sits on that line.
        .frame(width: 14, height: 16)
    }
}

/// Something that went wrong, as a caution callout built as the table's panel is: a rose shell with the warning mark
/// and a label in its strip, the words on a rounded panel inside, bled out so they line up with the page's prose. A
/// notice that names itself ("Blocked: …") gives the label; the rest say Error.
/// A callout's three tones, light and dark: the shell around it, the panel its words sit on, the ink.
private enum CalloutColors {
    private static func tinted(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1) : NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1) })
    }
    static let rose = (shell: tinted(light: (1.0, 0.894, 0.902), dark: (0.24, 0.03, 0.10)), panel: tinted(light: (1.0, 0.945, 0.949), dark: (0.40, 0.06, 0.18)),
                       ink: tinted(light: (0.30, 0.02, 0.10), dark: (1.0, 0.894, 0.902)))
    static let amber = (shell: tinted(light: (1.0, 0.925, 0.835), dark: (0.26, 0.14, 0.02)), panel: tinted(light: (1.0, 0.957, 0.902), dark: (0.40, 0.22, 0.04)),
                        ink: tinted(light: (0.36, 0.18, 0.0), dark: (1.0, 0.925, 0.835)))
}

struct CautionCallout<Actions: View>: View {
    /// Rose for a failure, amber for trouble that may pass (stuck, out of usage).
    enum Tone { case rose, amber }
    let text: String
    var tone = Tone.rose
    @ViewBuilder var actions: () -> Actions

    init(text: String, tone: Tone = .rose, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.text = text; self.tone = tone; self.actions = actions
    }

    var body: some View {
        let colors = tone == .rose ? CalloutColors.rose : CalloutColors.amber
        let (label, body) = Self.split(text)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                NucleoIcon("triangle-warning", fill: "glyph", size: 13)
                Text(label).font(.system(size: 12, weight: .medium)).tracking(-0.2)
            }
            .foregroundStyle(colors.ink)
            .padding(.horizontal, 14).padding(.vertical, 7)
            VStack(alignment: .leading, spacing: 12) {
                Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body))
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(colors.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions()
            }
            .padding(14)
            .background(colors.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(2)
        .background(colors.shell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Bled out by its inner padding (the shell's 2 and the panel's 14), so its words line up with the page's.
        .padding(.horizontal, -16)
    }

    /// "Blocked: the words" → ("Blocked", "the words"); anything else is an Error with all its words.
    static func split(_ text: String) -> (String, String) {
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 24,
           !text[..<colon].contains("\n"), text[text.index(after: colon)...].first == " " {
            return (String(text[..<colon]), String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return ("Error", text)
    }
}

/// A table the agent handed to Zero (`zero table`), drawn as All tasks is: the headings in the shell's strip, rows on
/// the panel with a hairline between, bled out so its text lines up with the page's. A cell that is a state reads as
/// the board's pill, a ticket, a PR or a link opens as in an answer, the rest is words with inline code.
private struct TableCard: View {
    let title: String
    let columns: [String]
    let rows: [[String]]
    let cwd: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 2) }
            ArticlePanel {
                line(columns.map { AnyView(Text($0)) }, head: true).padding(.vertical, -3)
            } content: {
                VStack(spacing: 0) {
                    if rows.isEmpty { Text("Nothing in it").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1) }
                        line(row.enumerated().map { column, text in AnyView(cell(text, in: column < columns.count ? columns[column] : "")) }, head: false)
                    }
                }
            }
        }
    }

    /// One row, the header included: every column shares the width alike. Aligned on their tops: a Markdown cell is a
    /// text view of its own with no baseline to give, and sat low on a baseline row.
    private func line(_ cells: [AnyView], head: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in cell.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(head ? .system(size: 12, weight: .medium) : .system(size: 13))
        .tracking(head ? -0.2 : 0)
        .foregroundStyle(head ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.85)))
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private func cell(_ text: String, in column: String) -> some View {
        switch TableCell.of(text, column: column) {
        // The gaps behind the grade, on hover: the column reads at a glance.
        case let .risk(level, gaps): RiskLabel(level: level).tip(gaps)
        case let .state(state): StateLabel(state: state)
        case .empty: Text("–").foregroundStyle(.tertiary)
        case let .text(text): MarkdownText(text, cwd: cwd, size: 13, compact: true)
        }
    }

}

/// A risk level as a pill: green low, amber medium, red high, on a wash of its colour, as a state's pill is.
private struct RiskLabel: View {
    let level: String
    var body: some View {
        let color: Color = level == "low" ? .green : level == "medium" ? .orange : .red
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(level.capitalized).font(.system(size: 11.5, weight: .medium)).foregroundStyle(level == "low" ? AnyShapeStyle(Theme.done) : AnyShapeStyle(color))
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

/// A thought as a step's row: "Thought for 4s" and its first line; opened, all of it under.
private struct ReasoningRow: View {
    let text: String
    let seconds: TimeInterval?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    NucleoIcon("brain", size: 14).foregroundStyle(.secondary).frame(width: 14, height: 16)
                    Text(Took.text("Thought", seconds)).fontWeight(.medium)
                    if !open { Text(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                    Spacer(minLength: 0)
                    NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { Text(text).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 22) }
        }
        .font(.callout)
    }
}

private struct CommandCard: View {
    let command: String
    let output: String
    let exitCode: Int?
    let status: ItemStatus
    @State private var open = false
    /// How tall what it printed is: the box is that tall (up to 300 pt, then it scrolls), not the most it may be.
    @State private var outputHeight: CGFloat = 0

    var body: some View {
        // A row like every step's; its output, opened, in a box beneath it, under its words.
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: status)
                    Text("$ " + command).font(.system(.callout, design: .monospaced)).lineLimit(open ? nil : 1)
                    Spacer(minLength: 0)
                    if let exitCode, exitCode != 0 { Text("exit \(exitCode)").font(.caption).foregroundStyle(.red) }
                    if !output.isEmpty { NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && !output.isEmpty {
                // As a terminal's pane, drawn as the diffs are: the command whole at its head with what it printed
                // (how much, and a copy), then the output itself, quieter, under a hairline.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        (Text("$ ").foregroundStyle(.tertiary) + Text(command).foregroundStyle(.primary))
                            .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let count = output.split(separator: "\n", omittingEmptySubsequences: false).count
                        Text(count == 1 ? "1 line" : "\(count) lines").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                        CopyButton(text: output).tip("Copy the output")
                    }
                    .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.03))
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                    // Scrolling both ways, a box larger than what's in it centres it: anchored top left instead, and
                    // only as tall as the output.
                    ScrollView([.vertical, .horizontal]) {
                        Text(output).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineSpacing(2)
                            .textSelection(.enabled).fixedSize()
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { outputHeight = $0 }
                    }
                    .defaultScrollAnchor(.topLeading)
                    .thinScrollbar()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: min(max(outputHeight, 1), 300))
                }
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                .padding(.leading, 22)
            }
        }
    }
}

struct FileChangeCard: View {
    let change: FileChange
    let status: ItemStatus
    let cwd: String
    @State private var open = true

    var body: some View {
        let lines = DiffLine.parse(change.diff, added: change.kind == "add")
        let path = relative(change.path, to: cwd)
        let (folder, name) = ((path as NSString).deletingLastPathComponent, (path as NSString).lastPathComponent)
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: status)
                    Text(verb).font(.callout.weight(.medium))
                    // The file first, its folder after it and quieter: the name is what's read.
                    (Text(name).font(.system(.callout, design: .monospaced).weight(.medium))
                        + Text(folder.isEmpty ? "" : "  " + folder).font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    let added = lines.count { $0.kind == .added }, removed = lines.count { $0.kind == .removed }
                    if added > 0 { Text("+\(added)").foregroundStyle(DiffLine.green) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(DiffLine.red) }
                    if !lines.isEmpty { NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary) }
                }
                .font(.system(.callout).monospacedDigit())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && !lines.isEmpty {
                DiffText(lines: lines)
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                    .padding(.leading, 22)
            }
        }
    }

    private var verb: String {
        switch change.kind {
        case "add": "Added"
        case "delete": "Deleted"
        default: change.movePath == nil ? "Edited" : "Moved"
        }
    }
}

/// A path inside the session's folder, from that folder: "src/main.rs".
private func relative(_ path: String, to folder: String) -> String {
    let base = folder.hasSuffix("/") ? folder : folder + "/"
    let resolved = { (p: String) in p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }
    let (inner, outer) = (resolved(path), resolved(base))
    return inner.hasPrefix(outer) ? String(inner.dropFirst(outer.count)) : (path as NSString).abbreviatingWithTildeInPath
}
