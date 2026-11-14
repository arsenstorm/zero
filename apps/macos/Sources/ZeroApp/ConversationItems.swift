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
                    let tiles = ImageToken.tiles(text, images: images)
                    let pictures = tiles.filter { $0.video == nil }.map(\.path)
                    WrappingStack(spacing: 6, trailing: true) {
                        ForEach(tiles, id: \.path) { tile in
                            if let video = tile.video {
                                Thumbnail(
                                    path: tile.path, side: 200, fit: true, tap: { NSWorkspace.shared.open(URL(fileURLWithPath: video)) }
                                )
                                .overlay { VideoBadge() }
                            } else {
                                // Large enough to read what it shows (a screenshot is usually what the message is about).
                                Thumbnail(path: tile.path, side: 200, fit: true, among: pictures)
                            }
                        }
                    }
                }
                if !text.isEmpty {
                    HStack {
                        Spacer(minLength: 80)
                        // As an answer reads: links that open (zero://, PRs, commits, tickets) and code as code, an
                        // image's token as its pill; the bubble hugs its words.
                        MarkdownText(ImageToken.linked(text, images: images), cwd: cwd, size: 14.5, hugs: true, yours: true).padding(
                            .horizontal, 14
                        ).padding(.vertical, 9)
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
            ReasoningRow(text: text, date: item.date, until: until)
        case let .plan(text):
            Text(text).font(.system(size: 12, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
        case let .command(command, _, output, exitCode, _, description):
            CommandCard(
                command: command, description: description, output: output, exitCode: exitCode, status: item.status, started: item.date)
        case let .fileChange(changes):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(changes, id: \.path) { change in FileChangeCard(change: change, status: item.status, cwd: cwd) }
            }
        case let .tool(name, detail):
            ToolCard(name: name, detail: detail, status: item.status)
        case let .notice(text, error):
            if error {
                CautionCallout(text: text)
            } else {
                // The icon on the first line, centred on its letters, however many lines the notice runs to.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        // Running: something under way the agent is silent through, as compacting the conversation.
                        if item.status == .running {
                            StatusIcon(status: item.status)
                        } else if let icon = AgentIcons.notice(text) {
                            PixelIcon(icon, height: 14)
                        } else {
                            NucleoIcon("circle-info", size: 14)
                        }
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    Text(NoticeText.attributed(text))
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).tint(Theme.link)
            }
        case let .table(title, columns, rows):
            TableCard(title: title, columns: columns, rows: rows, cwd: cwd)
        }
    }
}

/// Copies an answer; a tick for a moment says it did.
struct CopyButton: View {
    let text: String
    /// Its tile's side: a message's row has smaller ones (MessageBlock).
    var size: CGFloat = 22
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5)); copied = false
            }
        } label: {
            NucleoIcon(copied ? "check" : "copy", size: 13).foregroundStyle(.secondary).frame(width: size, height: size)
        }
        .buttonStyle(Hovering(radius: 6)).tip("Copy")
    }
}

/// A step's state, one size whatever the state.
struct StatusIcon: View {
    let status: ItemStatus
    var body: some View {
        Group {
            switch status {
            // Done needs no colour, as Codex's steps: colour is kept for what needs you (failed, declined).
            case .running: Spinner().frame(width: 12, height: 12)
            case .done: NucleoIcon("check", size: 13).foregroundStyle(.tertiary)
            case .failed: NucleoIcon("circle-xmark", size: 14).foregroundStyle(.red)
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
        let colors = tone == .rose ? Theme.rose : Theme.amber
        let (label, body) = Self.split(text)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                NucleoIcon("triangle-warning", fill: "glyph", size: 13)
                Text(label).font(.system(size: 12, weight: .medium)).tracking(-0.2)
            }
            .foregroundStyle(colors.ink)
            .padding(.horizontal, 14).padding(.vertical, 7)
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(body)
                )
                .font(.system(size: 13)).lineSpacing(5).foregroundStyle(colors.ink).tint(Theme.link)
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
            !text[..<colon].contains("\n"), text[text.index(after: colon)...].first == " "
        {
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
                    if rows.isEmpty {
                        Text("Nothing in it").font(.system(size: 13)).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(
                            .vertical, 16)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1) }
                        line(
                            row.enumerated().map { column, text in AnyView(cell(text, in: column < columns.count ? columns[column] : "")) },
                            head: false)
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
            Text(level.capitalized).font(.system(size: 11.5, weight: .medium)).foregroundStyle(
                level == "low" ? AnyShapeStyle(Theme.done) : AnyShapeStyle(color))
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

/// A step's row, as Codex draws them: quieter than the answer (secondary), the row itself the button, its chevron
/// right after its words, shown on hover or while open (its place kept, so nothing shifts).
private struct StepRow<Label: View, Trailing: View>: View {
    @Binding var open: Bool
    /// There's more to it to open.
    let opens: Bool
    @ViewBuilder let label: () -> Label
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovered = false

    var body: some View {
        Button {
            if opens { open.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                label()
                if opens {
                    NucleoIcon("chevron-down", size: 10).rotationEffect(.degrees(open ? 0 : -90)).frame(height: 16)
                        .opacity(hovered || open ? 1 : 0)
                }
                Spacer(minLength: 0)
                trailing()
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

extension StepRow where Trailing == EmptyView {
    init(open: Binding<Bool>, opens: Bool, @ViewBuilder label: @escaping () -> Label) {
        self.init(open: open, opens: opens, label: label, trailing: { EmptyView() })
    }
}

/// A thought as a step's row: "Thought for 4s" and its first line; opened, all of it under. The latest of a turn still
/// going counts on, so its words never change as the next step comes.
private struct ReasoningRow: View {
    let text: String
    let date: Date?
    let until: Date?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepRow(open: $open, opens: true) {
                NucleoIcon("brain", size: 14).frame(width: 14, height: 16)
                Group {
                    if let date, until == nil {
                        TimelineView(.periodic(from: .zeroBeat, by: 1)) { context in
                            Text(Took.text("Thought", context.date.timeIntervalSince(date)))
                        }
                    } else {
                        Text(Took.text("Thought", until.flatMap { until in date.map { until.timeIntervalSince($0) } }))
                    }
                }
                .fontWeight(.medium).monospacedDigit()
                if !open {
                    Text(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").foregroundStyle(.tertiary).lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if open { Text(text).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 22) }
        }
        .font(.system(size: 12))
    }
}

/// A command's step, titled by what it does (the agent's words for it, where it gave them) with the command after it,
/// quieter; without them, the command's line that says something. Running, how long it has been, and after a few
/// seconds the latest line it printed in the command's place: on the row's one line, so nothing moves.
private struct CommandCard: View {
    let command: String
    let description: String
    let output: String
    let exitCode: Int?
    let status: ItemStatus
    let started: Date?
    @State private var open = false
    /// How tall what it printed is: the box is that tall (up to 300 pt, then it scrolls), not the most it may be.
    @State private var outputHeight: CGFloat = 0

    /// What it last printed: the last line with something on it.
    private var latest: String? {
        output.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// More to it than the row shows: what it printed, or the command whole.
    private var opens: Bool { !output.isEmpty || !description.isEmpty || command.contains("\n") }

    var body: some View {
        // A row like every step's; opened, the command whole and its output in a box beneath it, under its words.
        VStack(alignment: .leading, spacing: 8) {
            StepRow(open: $open, opens: opens) {
                // An agent's own `zero` step, once it went through: named for what it did, in the pixel family.
                if status == .done, (exitCode ?? 0) == 0, let named = AgentIcons.step(command) {
                    PixelIcon(named.icon)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(named.words).layoutPriority(1)
                        if !named.detail.isEmpty { Text(named.detail).foregroundStyle(.tertiary) }
                    }
                    .lineLimit(1).truncationMode(.tail)
                } else {
                    StatusIcon(status: status)
                    if status == .running, let started {
                        TimelineView(.periodic(from: .zeroBeat, by: 1)) { context in title(running: context.date.timeIntervalSince(started))
                        }
                    } else {
                        title(running: nil)
                    }
                }
            } trailing: {
                if let exitCode, exitCode != 0 { Text("exit \(exitCode)").font(.system(size: 11)).foregroundStyle(.red) }
                if status == .running, let started {
                    TimelineView(.periodic(from: .zeroBeat, by: 1)) { context in
                        Text(Took.length(context.date.timeIntervalSince(started))).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(
                                .tertiary)
                    }
                }
            }
            if open && opens {
                // As a terminal's pane, drawn as the diffs are: the command whole at its head with what it printed
                // (how much, and a copy), then the output itself, quieter, under a hairline.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        (Text("$ ").foregroundStyle(.tertiary) + Text(command).foregroundStyle(.primary))
                            .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !output.isEmpty {
                            let count = output.split(separator: "\n", omittingEmptySubsequences: false).count
                            Text(count == 1 ? "1 line" : "\(count) lines").font(.system(size: 11).monospacedDigit()).foregroundStyle(
                                .tertiary)
                            CopyButton(text: output).tip("Copy the output")
                        } else {
                            CopyButton(text: command).tip("Copy the command")
                        }
                    }
                    .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                    .background(Theme.tint)
                    if !output.isEmpty {
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                        // Scrolling both ways, a box larger than what's in it centres it: anchored top left instead, and
                        // only as tall as the output.
                        ScrollView([.vertical, .horizontal]) {
                            Text(output).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineSpacing(2)
                                .textSelection(.enabled).fixedSize()
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .onGeometryChange(for: CGFloat.self) {
                                    $0.size.height
                                } action: {
                                    outputHeight = $0
                                }
                        }
                        .defaultScrollAnchor(.topLeading)
                        .thinScrollbar()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: min(max(outputHeight, 1), 300))
                    }
                }
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                .padding(.leading, 22)
            }
        }
    }

    /// Its words, then the command (or, running a while, what it last printed), quieter, cut to the line.
    @ViewBuilder private func title(running: TimeInterval?) -> some View {
        let printing = running.map { $0 >= 3 } == true ? latest : nil
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if description.isEmpty, printing == nil {
                (Text("$ ").foregroundStyle(.tertiary) + Text(CommandText.line(command))).font(.system(size: 12, design: .monospaced))
            } else {
                if !description.isEmpty { Text(description).layoutPriority(1) }
                Text(printing ?? CommandText.line(command)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1).truncationMode(.tail)
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
            StepRow(open: $open, opens: !lines.isEmpty) {
                StatusIcon(status: status)
                Text(verb).fontWeight(.medium)
                // The file first, its folder after it and quieter: the name is what's read.
                (Text(name).font(.system(size: 12, design: .monospaced).weight(.medium))
                    + Text(folder.isEmpty ? "" : "  " + folder).font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary))
                    .lineLimit(1).truncationMode(.tail)
                let added = lines.count { $0.kind == .added }, removed = lines.count { $0.kind == .removed }
                if added > 0 { Text("+\(added)").foregroundStyle(Theme.done).monospacedDigit().fixedSize() }
                if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.removed).monospacedDigit().fixedSize() }
            }
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

/// A tool's step: a row like every step's, its name as people say it and its arguments' values on one line; opened (as a
/// command is), each argument by its name with its whole value, in a box beneath it. No tooltip of raw JSON.
private struct ToolCard: View {
    let name: String
    let detail: String
    let status: ItemStatus
    @State private var open = false

    /// Its arguments by name, in the order given, each value as text (a nested value as compact JSON).
    private var arguments: [(key: String, value: String)] {
        guard let data = detail.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return detail.isEmpty ? [] : [("", detail)] }
        let order = Self.keys(in: detail)
        let keys = order.filter { object[$0] != nil } + object.keys.filter { !order.contains($0) }.sorted()
        return keys.compactMap { key in
            guard let value = object[key] else { return nil }
            switch value {
            case let text as String: return (key, text)
            case let number as NSNumber: return (key, number.stringValue)
            default:
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                return (key, data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)")
            }
        }
    }

    /// The top level's keys in the order they're written (JSONSerialization's dictionary forgets it).
    private static func keys(in json: String) -> [String] {
        var keys: [String] = [], depth = 0, inString = false, escaped = false, start: String.Index?
        var index = json.startIndex
        while index < json.endIndex {
            let c = json[index]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                    if depth == 1, let from = start {
                        let after = json[json.index(after: index)...].drop { $0 == " " }
                        if after.first == ":" { keys.append(String(json[json.index(after: from)..<index])) }
                    }
                }
            } else if c == "\"" {
                inString = true; start = index
            } else if c == "{" || c == "[" {
                depth += 1
            } else if c == "}" || c == "]" {
                depth -= 1
            }
            index = json.index(after: index)
        }
        return keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepRow(open: $open, opens: !detail.isEmpty) {
                StatusIcon(status: status)
                Text(ToolNames.name(name)).fontWeight(.medium).lineLimit(1)
                Text(ToolNames.detail(detail)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            }
            if open && !detail.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(arguments.enumerated()), id: \.offset) { _, argument in
                        VStack(alignment: .leading, spacing: 3) {
                            if !argument.key.isEmpty {
                                Text(argument.key).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                            }
                            Text(argument.value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                .lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            }
        }
    }
}
