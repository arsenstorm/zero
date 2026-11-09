import SwiftUI

// A task's conversation on the phone, read as the Mac reads it (ZeroCore's TimelineBlock): your messages, each turn's
// work folded under "Worked for…" with only its answer in full, and what waits on you, answered where it stands.

struct ConversationView: View {
    let model: PhoneModel
    let conversation: Conversation
    /// A question, ask or approval just answered: the page keeps the height it had, so the card fades out where it was
    /// and nothing above it moves; what comes next fills that room. Given back when you scroll (the page's).
    @Binding var room: CGFloat
    /// The conversation's own height, without that room: read when a card leaves, never by the body, so its every
    /// change redraws nothing.
    @State private var measured = Measured()
    final class Measured { var height: CGFloat = 0 }
    /// A card answered fades out where it was (and a new one in): its own animation, nothing else animated with it.
    private static let fade = AnyTransition.opacity.animation(.easeOut(duration: 0.2))

    var body: some View {
        let blocks = TimelineBlock.of(Sending.merge(conversation.items, model.sending[conversation.id] ?? []).filter { item in !conversation.approvals.contains { $0.item == item.id } },
                                      working: conversation.status == .working || conversation.status == .waiting)
        // Not lazy: a lazy stack under a bottom anchor drew nothing until scrolled, and the phone holds one page only.
        VStack(alignment: .leading, spacing: 24) {
            if model.earlier(conversation.id) > 0 {
                Button("Earlier messages") { Task { await model.loadEarlier(conversation.id) } }
                    .font(.footnote).frame(maxWidth: .infinity)
            }
            ForEach(blocks) { block in
                switch block {
                case let .user(item): UserMessage(item: item)
                case let .work(_, items, start, end, live): WorkBlock(model: model, session: conversation.id, items: items, start: start, end: end, live: live)
                // An answer that was only its ending (an event or a worker's report taken in, "[zero: waiting]") has
                // no words to show: nothing, not its copy and menu under an empty reply.
                case let .answer(item):
                    if case let .agent(text, _) = item.kind, case let words = ZeroEnding.split(text).0,
                       !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Answer(text: words) }
                case let .step(item): StepView(model: model, session: conversation.id, item: item)
                }
            }
            ForEach(conversation.questions) { question in QuestionCard(model: model, session: conversation.id, question: question).transition(Self.fade) }
            ForEach(conversation.approvals) { approval in ApprovalCard(model: model, session: conversation.id, approval: approval).transition(Self.fade) }
            // Still waiting after its turn (an ask sent with --async), its step folded away with the rest.
            ForEach(openAsks) { ask in AskCard(model: model, ask: ask).transition(Self.fade) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [measured] in measured.height = $0 }
        .frame(minHeight: room, alignment: .top)
        .onChange(of: waiting) { old, new in if !Set(old).subtracting(new).isEmpty { room = max(room, measured.height) } }
    }

    private var openAsks: [Ask] {
        guard conversation.status != .working, conversation.status != .waiting else { return [] }
        return model.asks.filter { $0.isAgents(in: conversation.id) && !$0.state.isFinal }
    }

    /// What waits on you, by id: a card leaving this is one answered.
    private var waiting: [String] { conversation.questions.map(\.id) + conversation.approvals.map(\.id) + openAsks.map(\.id) }
}

/// An answer: its Markdown, and under it a copy button and the way to pick out part of it (as ChatGPT's): SwiftUI's
/// text on the phone copies a whole paragraph or nothing.
struct Answer: View {
    let text: String
    @State private var selecting = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownView(text: text)
                .contextMenu { CopyActions(text: text, select: { selecting = true }) }
            HStack(spacing: 4) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(copied ? "circle-check-glyph" : "copy-outline").resizable().frame(width: 18, height: 18)
                        .foregroundStyle(.secondary).frame(width: 36, height: 32).contentShape(Rectangle())
                }
                Menu { CopyActions(text: text, select: { selecting = true }) } label: {
                    Image("dots-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(.secondary).frame(width: 36, height: 32).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, -9)
        }
        .sheet(isPresented: $selecting) { SelectText(text: text) }
    }
}

/// Copy, and pick out part of it.
struct CopyActions: View {
    let text: String
    var select: (() -> Void)?
    var body: some View {
        Button("Copy") { UIPasteboard.general.string = text }
        if let select { Button("Select text", action: select) }
    }
}

/// The text to select from, as much or as little as wanted: its words without Markdown's marks, in iOS's own text
/// view, which selects with handles.
struct SelectText: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? text)
                .padding(.horizontal, 12)
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 10
        view.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label, .paragraphStyle: style])
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}

/// Yours, on the right; another task's or Zero's words (a worker's report) as a quiet line.
struct UserMessage: View {
    let item: ConversationItem
    @State private var open = false

    var body: some View {
        if case let .user(text, images) = item.kind {
            if let given = ConversationItem.from(text) {
                Button { open.toggle() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(given.text.split(separator: "\n").first.map(String.init) ?? "").lineLimit(open ? nil : 1)
                        if open { MarkdownView(text: given.text) }
                    }
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                // As the Mac shows yours: the images above the words, as tiles; the words without their "[Image #1]".
                let words = text.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                VStack(alignment: .trailing, spacing: 6) {
                    if !images.isEmpty { MessageImages(paths: images) }
                    if !words.isEmpty {
                        Text(words).padding(.horizontal, 12).padding(.vertical, 8)
                            .contextMenu { CopyActions(text: words) }
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
            }
        }
    }
}

/// A turn's work: "Working for 12s" while it goes, every step under it; "Worked for 2m 37s" once answered, folded.
struct WorkBlock: View {
    let model: PhoneModel
    let session: String
    let items: [ConversationItem]
    let start: Date?
    let end: Date?
    let live: Bool
    @State private var toggled = false
    private var open: Bool { live != toggled }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { toggled.toggle() } } label: {
                HStack(spacing: 6) {
                    // As the Mac's: thought alone isn't work, and under a second is "for a moment", never "0s".
                    if live, !worked {
                        Text("Thinking")
                    } else if live {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(start.map { "Working for " + Took.length(context.date.timeIntervalSince($0)) } ?? "Working")
                        }
                    } else {
                        Text(Took.text(worked ? "Worked" : "Thought", start.flatMap { start in end.map { $0.timeIntervalSince(start) } }))
                    }
                    if !items.isEmpty { Image("chevron-down-outline").resizable().frame(width: 9, height: 9).rotationEffect(.degrees(open ? 0 : -90)) }
                }
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(items.isEmpty)
            if open {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    StepView(model: model, session: session, item: item, until: index + 1 < items.count ? items[index + 1].date : end)
                }
            }
            // Under steps of work, what it's at now; with only thought so far the heading says "Thinking" already.
            if live, worked { Text("Thinking…").font(.subheadline).foregroundStyle(.tertiary) }
        }
    }

    /// Steps of substance: reading, running, editing. Thought alone isn't work.
    private var worked: Bool { items.contains { if case .reasoning = $0.kind { false } else { true } } }
}

/// One step: a command (its output a tap away), files changed, a tool, the agent's words between steps, a notice, a
/// table; the agent asking you through Zero, as that ask's card.
struct StepView: View {
    let model: PhoneModel
    let session: String
    let item: ConversationItem
    /// When the next step began: how long a thought took.
    var until: Date? = nil
    @State private var open = false

    var body: some View {
        if let ask = item.ask(in: model.asks, session: session) {
            AskCard(model: model, ask: ask)
        } else {
            switch item.kind {
            case let .command(command, _, output, exitCode, _):
                Button { open.toggle() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            StatusIcon(status: item.status)
                            Text("$ " + command).lineLimit(open ? nil : 1)
                            Spacer(minLength: 0)
                            if let exitCode, exitCode != 0 { Text("exit \(exitCode)").font(.caption2).foregroundStyle(.red) }
                        }
                        if open, !output.isEmpty {
                            ScrollView(.horizontal) { Text(output).padding(10) }
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .font(.footnote.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            case let .fileChange(changes):
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: item.status)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(changes, id: \.path) { change in
                            Text((change.kind == "add" ? "Added " : change.kind == "delete" ? "Deleted " : "Edited ") + (change.path as NSString).lastPathComponent)
                        }
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            case let .tool(name, detail):
                // Its name as people say it, its arguments as their values, not JSON (as the Mac's).
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: item.status)
                    Text(ToolNames.name(name)).fontWeight(.medium)
                    Text(ToolNames.detail(detail)).foregroundStyle(.secondary)
                }
                .font(.footnote).lineLimit(1)
            case let .agent(text, _):
                MarkdownView(text: ZeroEnding.split(text).0).foregroundStyle(.secondary)
            case let .notice(text, error):
                // A server's sign-in link calls back to the Mac, where its CLI listens: here, the words alone.
                Text(String(NoticeText.attributed(text).characters)).font(.footnote).foregroundStyle(error ? .red : .secondary)
            case let .table(title, columns, rows):
                TableView(title: title, columns: columns, rows: rows)
            case let .reasoning(text):
                // As the Mac's: "Thought for 4s" and its first line; opened, all of it.
                Button { open.toggle() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image("brain-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.secondary).frame(width: 14, height: 16)
                            Text(Took.text("Thought", until.flatMap { until in item.date.map { until.timeIntervalSince($0) } })).fontWeight(.medium)
                            if !open { Text(text.split(separator: "\n").first.map(String.init) ?? "").foregroundStyle(.secondary).lineLimit(1) }
                        }
                        if open { Text(text).foregroundStyle(.secondary).padding(.leading, 22).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .font(.footnote).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .user, .plan:
                EmptyView()
            }
        }
    }
}

/// Markdown as an answer uses it (ZeroCore's MarkdownBlock), its inline parts (bold, code, links) styled by SwiftUI.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    init(text: String) { blocks = MarkdownCache.blocks(text) }
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }

    // Spaced as ChatGPT's answers are: a little air between lines, a clear gap between paragraphs, so a long answer
    // reads as paragraphs rather than one block of text.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in Self.view(block) }
        }
        .lineSpacing(3)
    }

    static func inline(_ text: String) -> Text {
        Text(MarkdownCache.inline(text))
    }

    @ViewBuilder static func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text).font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case let .paragraph(text): inline(text)
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ordered ? "\(start + index)." : "•").foregroundStyle(.secondary).frame(minWidth: 12, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            inline(item.text)
                            if !item.children.isEmpty { MarkdownView(blocks: item.children) }
                        }
                    }
                }
            }
        case let .code(code):
            ScrollView(.horizontal) { Text(code).font(.footnote.monospaced()).padding(10) }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        case let .quote(text):
            inline(text).foregroundStyle(.secondary).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case let .table(rows):
            if let head = rows.first { TableView(title: "", columns: head, rows: Array(rows.dropFirst())) }
        case let .image(path, alt):
            AnswerImage(path: path, alt: alt)
        case .rule:
            Divider()
        }
    }
}

/// A table, as `zero table` makes them: a cell naming a state shows as its pill, a risk column's level as a pill (its
/// gaps a tap away), the rest as Markdown. Wider than the phone: it scrolls sideways.
struct TableView: View {
    let title: String
    let columns: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
            ScrollView(.horizontal) {
                // A column with long words is a set width its cells wrap in, so each row is as tall as its words;
                // the rest are as wide as they need, on one line. (In a sideways scroll a cell is otherwise measured
                // on one line and only then narrowed, its wrapped lines spilling over the rows below.)
                let wide = columns.indices.map { column in rows.contains { column < $0.count && $0[column].count > 28 } }
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow { ForEach(Array(columns.enumerated()), id: \.offset) { _, column in Text(column).font(.caption.weight(.semibold)) } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                                let content = Cell(text: cell, column: index < columns.count ? columns[index] : "")
                                if index < wide.count, wide[index] {
                                    content.fixedSize(horizontal: false, vertical: true).frame(width: 240, alignment: .leading)
                                } else {
                                    content.fixedSize()
                                }
                            }
                        }
                    }
                }
                .font(.footnote)
                .padding(12)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    struct Cell: View {
        let text: String
        let column: String
        @State private var showing = false
        var body: some View {
            switch TableCell.of(text, column: column) {
            case let .risk(level, gaps):
                Button { showing.toggle() } label: { RiskPill(level: level) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showing) { Text(gaps).font(.footnote).padding().presentationCompactAdaptation(.popover) }
                    .disabled(gaps.isEmpty)
            case let .state(state): StatePill(state: state)
            case .empty: MarkdownView.inline("–")
            case let .text(text): MarkdownView.inline(text)
            }
        }
    }
}

struct StatePill: View {
    let state: BoardRow.State
    var body: some View {
        let look = StateGlyph.look(state)
        HStack(spacing: 4) {
            StateGlyph(state: state).scaleEffect(0.8)
            Text(look.name).font(.caption.weight(.medium)).foregroundStyle(look.color)
        }
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 2)
        .background(look.color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

struct RiskPill: View {
    let level: String
    var body: some View {
        let color: Color = level == "low" ? .green : level == "medium" ? .orange : .red
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(level.capitalized).font(.caption.weight(.medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

/// An ask the agent sent through Zero (run, ask, approve), answered here as in the inbox: its options as buttons, an
/// option that takes words ("Something else…") opening a field; once answered, the answer and a run's output.
struct AskCard: View {
    let model: PhoneModel
    let ask: Ask
    /// In a list's row, which is the card already: no card of its own (never a card in a card).
    var flat = false
    @State private var typing: Int?
    @State private var words = ""

    /// A command for you to run yourself (an agent's question with `--code`: another machine's shell, sudo), laid out as
    /// steps. An approval's command is the agent's own, to allow or not, so it's never this.
    private var manual: Bool { (ask.kind == .question || ask.kind == .choice) && ask.command != nil && ask.state == .waiting }

    private var kindName: String {
        switch ask.kind {
        case .run: "Run on your Mac"
        case .approve: "Approval"
        case .permission: "Permission"
        default: manual ? "Run this yourself" : "Question"
        }
    }

    /// The question itself, as the Mac's card has it: a question's words (its --title is the agent's context), an
    /// approval's request.
    private var headline: String {
        switch ask.kind {
        case .run: ask.state == .waiting ? "Allow this command?" : ask.title
        case .question, .choice: ask.body.isEmpty ? ask.title : ask.body
        default: ask.title
        }
    }

    /// Under it: a question's --body, why a run or an approval is wanted.
    private var supporting: String? {
        let text = switch ask.kind {
        case .question, .choice: ask.detail ?? ""
        default: ask.body
        }
        return text.isEmpty || text == headline ? nil : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(ask.kind == .run || manual ? "terminal-outline" : "circle-question-glyph").resizable().frame(width: 13, height: 13)
                Text(kindName)
                Text("·")
                Text(ask.agent.label ?? ask.agent.name).lineLimit(1)
            }
            .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(headline).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if let supporting { MarkdownView(text: supporting).font(.subheadline).foregroundStyle(.secondary) }
            if let command = ask.command {
                // What runs is what's read: the command, the script it runs, and what it printed.
                let shown = [(ask.kind == .run ? "$ " : "") + command, ask.script, ask.output.isEmpty ? nil : ask.output].compactMap { $0 }.joined(separator: "\n")
                ScrollView(.horizontal) { Text(shown).font(.footnote.monospaced()).textSelection(.enabled).padding(10) }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) {
                        Button { UIPasteboard.general.string = [command, ask.script].compactMap { $0 }.joined(separator: "\n") } label: {
                            Image("copy-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.secondary).frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("Copy the command")
                    }
                if manual, let typed = ask.options.firstIndex(where: Ask.expectsText) {
                    // What it printed, from the clipboard into the reply, ready to send.
                    Button("Paste its output") { words = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; typing = typed }
                        .font(.footnote.weight(.medium))
                }
            }
            if ask.state == .waiting {
                if ask.options.isEmpty {
                    answerField { text in await model.reply(ask, text: text) }
                } else {
                    ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            if Ask.expectsText(option) { typing = index } else { Task { await model.choose(ask, option: index) } }
                        } label: {
                            Text(option).font(.subheadline.weight(.medium))
                                .foregroundStyle(Ask.expectsText(option) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 12)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    if let typing { answerField { text in await model.answer(ask, option: typing, text: text) } }
                }
            } else if ask.state == .pending {
                // Answered, and about to go: a moment to take it back.
                HStack {
                    Text(ask.answer ?? (ask.choice.flatMap { ask.options.indices.contains($0) ? ask.options[$0] : nil } ?? "Answered")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Take back") { Task { await model.takeBack(ask) } }.font(.footnote.weight(.semibold))
                }
            } else if let answer = ask.answer, ask.kind != .run {
                Text(answer).font(.footnote).foregroundStyle(.secondary)
                // Typed into the agent's session for it, and that didn't take: again.
                if ask.delivery == .failed {
                    Button("Not delivered · Try again") { Task { await model.deliver(ask) } }.font(.footnote.weight(.medium))
                }
            } else if ask.state == .running {
                Text("Running…").font(.footnote).foregroundStyle(.secondary)
            } else if ask.lost {
                Text("Lost: Zero can't tell whether it finished. Check what it did before running it again.").font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(flat ? 0 : 14)
        .padding(.vertical, flat ? 6 : 0)
        .background(flat ? AnyShapeStyle(.clear) : AnyShapeStyle(.background.secondary), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(flat ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary)))
    }

    private func answerField(_ send: @escaping (String) async -> Void) -> some View {
        HStack {
            TextField("Your answer", text: $words, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("Send") { let text = words; words = ""; Task { await send(text) } }
                .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// The provider asking (Claude Code's or Codex's own question): each field's options, or words.
struct QuestionCard: View {
    let model: PhoneModel
    let session: String
    let question: Question
    @State private var picked: [String: [String]] = [:]
    @State private var words: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Question", image: "circle-question-glyph").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(question.fields) { field in
                VStack(alignment: .leading, spacing: 8) {
                    Text(field.question).font(.subheadline.weight(.semibold))
                    ForEach(field.options, id: \.label) { option in
                        let on = picked[field.id]?.contains(option.label) == true
                        Button {
                            if field.multiple { picked[field.id, default: []].toggle(option.label) } else { picked[field.id] = [option.label] }
                        } label: {
                            HStack {
                                Image(on ? "circle-check-glyph" : "shape-circle-outline").resizable().frame(width: 18, height: 18)
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if let detail = option.description { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if field.other || field.options.isEmpty {
                        if field.secret { SecureField("Your answer", text: binding(field.id)).textFieldStyle(.roundedBorder) }
                        else { TextField("Your answer", text: binding(field.id), axis: .vertical).textFieldStyle(.roundedBorder) }
                    }
                }
            }
            Button("Send") { Task { await model.answer(session: session, question: question.id, answers: answers) } }
                .buttonStyle(.borderedProminent)
                .disabled(question.fields.contains { (answers[$0.id] ?? []).isEmpty })
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }

    private var answers: [String: [String]] {
        var out = picked
        for (id, text) in words where !text.isEmpty { out[id, default: []].append(text) }
        return out
    }

    private func binding(_ id: String) -> Binding<String> { Binding(get: { words[id] ?? "" }, set: { words[id] = $0 }) }
}

/// The provider asking to run a command or change files: its choices as buttons.
struct ApprovalCard: View {
    let model: PhoneModel
    let session: String
    let approval: Approval
    @State private var commandOpen = false

    /// What's asked, short: the command or the changes are below it, not spelled out again in the question.
    private var question: String {
        if approval.command != nil { return "Allow this command?" }
        if !approval.changes.isEmpty { return approval.changes.count == 1 ? "Allow this change?" : "Allow these changes?" }
        return approval.title.hasSuffix("?") ? approval.title : approval.title + "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval", image: "shield-outline").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(question).font(.subheadline.weight(.semibold))
            if let reason = approval.reason { Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            if let command = approval.command {
                let lines = command.split(separator: "\n", omittingEmptySubsequences: false).count
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView(.horizontal) { Text("$ " + command).font(.footnote.monospaced()).lineLimit(commandOpen ? nil : 8) }
                    if lines > 8 {
                        Button(commandOpen ? "Show less" : "Show all \(lines) lines") { commandOpen.toggle() }
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary).buttonStyle(.plain)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(approval.changes, id: \.path) { change in Text(change.path).font(.footnote.monospaced()).foregroundStyle(.secondary) }
            ForEach(approval.choices) { choice in
                Button { Task { await model.decide(session: session, approval: approval.id, choice: choice.id) } } label: {
                    Text(choice.label).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(choice.kind == .deny || choice.kind == .stop ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }
}

private extension Array where Element == String {
    mutating func toggle(_ value: String) { if let index = firstIndex(of: value) { remove(at: index) } else { append(value) } }
}

/// Markdown parsed once per text: a page drawn again (a new step arriving, a tick of the clock) reuses what it parsed.
@MainActor enum MarkdownCache {
    private final class Blocks { let value: [MarkdownBlock]; init(_ value: [MarkdownBlock]) { self.value = value } }
    private final class Inline { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    private static let blockCache: NSCache<NSString, Blocks> = { let c = NSCache<NSString, Blocks>(); c.countLimit = 500; return c }()
    private static let inlineCache: NSCache<NSString, Inline> = { let c = NSCache<NSString, Inline>(); c.countLimit = 3000; return c }()

    static func blocks(_ text: String) -> [MarkdownBlock] {
        if let kept = blockCache.object(forKey: text as NSString) { return kept.value }
        let parsed = MarkdownBlock.parse(text)
        blockCache.setObject(Blocks(parsed), forKey: text as NSString)
        return parsed
    }

    static func inline(_ text: String) -> AttributedString {
        if let kept = inlineCache.object(forKey: text as NSString) { return kept.value }
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        inlineCache.setObject(Inline(parsed), forKey: text as NSString)
        return parsed
    }
}

/// A step's state, as the Mac shows it: a spinner while it runs, a green tick done, a red cross failed, declined in
/// orange; one size whatever the state, the first line's height.
struct StatusIcon: View {
    let status: ItemStatus
    var body: some View {
        Group {
            switch status {
            case .running: Spinner().frame(width: 12, height: 12)
            case .done: Image("circle-check-glyph").resizable().frame(width: 14, height: 14).foregroundStyle(.green)
            case .failed: Image("circle-xmark-glyph").resizable().frame(width: 14, height: 14).foregroundStyle(.red)
            case .declined: Image("ban-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.orange)
            }
        }
        .frame(width: 14, height: 16)
    }
}

/// A message's images as tiles, from the right as the Mac lays them; each a tap from its full size.
struct MessageImages: View {
    let paths: [String]
    @State private var shown: String?

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(paths, id: \.self) { path in
                ImageTile(path: path, side: 88).onTapGesture { shown = path }
            }
        }
        .sheet(item: Binding(get: { shown.map(Shown.init) }, set: { shown = $0?.path })) { shown in
            ImageViewer(path: shown.path)
        }
    }

    private struct Shown: Identifiable { let path: String; var id: String { path } }
}

/// An image from the Mac, as large as asked, a placeholder of the same size until it comes: nothing moves.
struct ImageTile: View {
    let path: String
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.primary.opacity(0.08) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .task(id: path) { image = await PhoneModel.shared.image(path, side: Int(side * 3)) }
    }
}

/// An image an agent shows (a screenshot, a render), from the Mac: the answer's width, its own proportions once it
/// comes, a tap from its full size.
struct AnswerImage: View {
    let path: String
    let alt: String
    @State private var image: UIImage?
    @State private var open = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(image.size, contentMode: .fit) }
            else { Color.primary.opacity(0.08).aspectRatio(16 / 10, contentMode: .fit) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .accessibilityLabel(alt)
        .onTapGesture { open = true }
        .sheet(isPresented: $open) { ImageViewer(path: path) }
        .task(id: path) { image = await PhoneModel.shared.image(path, side: 1600) }
    }
}

/// One image, whole, to look at.
struct ImageViewer: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { Spinner().frame(width: 22, height: 22) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { image = await PhoneModel.shared.image(path, side: 2400) }
    }
}
