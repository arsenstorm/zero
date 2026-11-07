import AppKit
import SwiftUI
import ZeroCore

/// The agent asking: each field's options as buttons (toggles where several may be picked), its own words where it
/// takes them, dots for a secret. Sent once every field has an answer.
/// A question on the page: the callout's shell and strip in amber, and inside, the inbox's own card for each of its
/// fields, flat (one card for an ask, wherever it shows), so answering here is answering there. Until the inbox has
/// them, the plain form.
struct QuestionCard: View {
    let question: Question
    let session: String
    let inbox: InboxController
    let send: ([String: [String]]) -> Void
    @FocusState private var focus: String?

    private var asks: [Ask] {
        let order = question.fields.map { question.id + "#" + $0.id }
        return inbox.store.asks
            .filter { ask in ask.state != .expired && order.contains(ask.request ?? "") && (ask.agent.ref == session || ask.agent.name == "zerod-" + session) }
            .sorted { (order.firstIndex(of: $0.request ?? "") ?? 0) < (order.firstIndex(of: $1.request ?? "") ?? 0) }
    }

    var body: some View {
        let asks = asks
        // The table's panel: a grey shell and strip around the card's own surface, one tone, as the other cards are.
        ArticlePanel {
            HStack(spacing: 6) {
                NucleoIcon("circle-question", fill: "glyph", size: 13)
                Text(question.fields.count == 1 ? (question.fields.first?.header ?? "Question") : "Questions").font(.system(size: 12, weight: .medium)).tracking(-0.2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .modifier(PagedStrip())
        } content: {
            Group {
                if asks.isEmpty {
                    PlainQuestionCard(question: question, send: send)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(asks) { ask in CardView(ask: ask, controller: inbox, focus: $focus, flat: true, showsByline: false) }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An ask the agent put to the user through Zero, in its task's chat as in the inbox: the same card, answered either
/// place. Shown while it waits, and while a run runs.
struct AgentAskCard: View {
    let ask: Ask
    let inbox: InboxController
    /// In the conversation: the question and its answer (or that it waits on you) on one line of fixed height; the
    /// full card is above the composer while it waits.
    var compact = false
    @FocusState private var focus: String?

    /// The agent's own asks (not the provider's questions and approvals, which have cards of their own above).
    static func agents(_ ask: Ask, in session: String) -> Bool { ask.isAgents(in: session) }

    /// Still waiting at the conversation's end: after its turn, when the step that asked is folded away with the rest
    /// (an ask sent with --async); during a turn its card is that step, in place.
    static func open(_ ask: Ask, in conversation: Conversation) -> Bool {
        agents(ask, in: conversation.id) && !ask.state.isFinal && ![.working, .waiting].contains(conversation.status)
    }

    static func made(by item: ConversationItem, in asks: [Ask], session: String) -> Ask? { item.ask(in: asks, session: session) }

    var body: some View {
        ArticlePanel {
            HStack(spacing: 6) {
                NucleoIcon(ask.kind == .run ? "terminal" : "circle-question", fill: ask.kind == .run ? "outline" : "glyph", size: 13)
                Text(ask.kind == .run ? "Run on your Mac" : ask.kind == .approve ? "Approval" : "Question").font(.system(size: 12, weight: .medium)).tracking(-0.2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .modifier(PagedStrip())
        } content: {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ask.kind == .run ? (ask.command ?? ask.title) : ask.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(answered).font(.system(size: 13)).foregroundStyle(ask.state.isFinal ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .tip(ask.title)
            } else {
                CardView(ask: ask, controller: inbox, focus: $focus, flat: true, showsByline: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
    }

    /// What became of it, in a few words.
    private var answered: String {
        switch ask.state {
        case .waiting, .pending: "Waiting on you"
        case .running: "Running"
        case .declined: "Declined"
        case .expired: "Expired"
        case .answered where ask.kind == .run: (ask.exitCode ?? 0) == 0 ? "Ran" : "Failed (exit \(ask.exitCode ?? 0))"
        default: ask.choice.flatMap { ask.options.indices.contains($0) ? ask.options[$0] : nil } ?? ask.answer ?? "Answered"
        }
    }
}

/// The question's own form, when the inbox has no card for it yet.
private struct PlainQuestionCard: View {
    let question: Question
    let send: ([String: [String]]) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    private func answer(_ field: Field) -> [String] {
        let own = typed[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let options = field.options.map(\.label).filter { picked[field.id, default: []].contains($0) }
        return own.isEmpty ? options : options + [own]
    }

    var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(question.fields) { field in
                    VStack(alignment: .leading, spacing: 10) {
                        if question.fields.count > 1, let header = field.header {
                            Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        Text((try? AttributedString(markdown: field.question, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(field.question))
                            .font(.system(size: 13, weight: .medium)).lineSpacing(4).textSelection(.enabled)
                        if !field.options.isEmpty {
                            WrappingStack(spacing: 6) {
                                ForEach(field.options, id: \.label) { option in
                                    let on = picked[field.id, default: []].contains(option.label)
                                    Button(option.label) {
                                        if field.multiple { picked[field.id, default: []].formSymmetricDifference([option.label]) }
                                        else { picked[field.id] = on ? [] : [option.label] }
                                    }
                                    .buttonStyle(ChoiceChip(on: on)).tip(option.description ?? "")
                                }
                            }
                        }
                        if field.secret {
                            SecureField("Secret", text: Binding(get: { typed[field.id, default: ""] }, set: { typed[field.id] = $0 })).modifier(AnswerField())
                        } else if field.other || field.options.isEmpty {
                            TextField(field.options.isEmpty ? "Your answer" : "Or say something else", text: Binding(get: { typed[field.id, default: ""] }, set: { typed[field.id] = $0 }))
                                .modifier(AnswerField())
                        }
                    }
                }
                Button("Answer") { send(Dictionary(uniqueKeysWithValues: question.fields.map { ($0.id, answer($0)) })) }
                    .buttonStyle(Prominent()).keyboardShortcut(.defaultAction).disabled(question.fields.contains { answer($0).isEmpty })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    /// An option: a pill, solid once picked.
    private struct ChoiceChip: ButtonStyle {
        let on: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(on ? AnyShapeStyle(Theme.onKnob) : AnyShapeStyle(.primary))
                .padding(.horizontal, 12).frame(height: 28)
                .background(on ? AnyShapeStyle(Theme.knob) : AnyShapeStyle(Theme.card), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.stroke))
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }

    /// The free answer's field: a plain field on a pale panel, as the composer's.
    private struct AnswerField: ViewModifier {
        func body(content: Content) -> some View {
            content.textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 30)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
        }
    }
}

/// A diff's lines, additions green and removals red. A new file's contents arrive without markers: all added.

/// The provider asking before it acts, in the panel a question has: "Approval" in its strip; what it wants (a command,
/// or changes to files: shown, not spelled out again in the question), why, and its own choices as the question card's
/// numbered rows, the first one the default (Return).
struct ApprovalCard: View {
    let approval: Approval
    let cwd: String
    let choose: (Choice) -> Void
    @State private var commandOpen = false

    /// A command's lines shown before "Show all".
    private static let folded = 8

    /// Claude describes a file approval by the file's name, which the title already says.
    private var reason: String? {
        guard let reason = approval.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty,
              !approval.title.localizedCaseInsensitiveContains(reason) else { return nil }
        return reason
    }

    /// What's asked, short: the command or the changes are below it.
    private var question: String {
        if approval.command != nil { return "Allow this command?" }
        if !approval.changes.isEmpty { return approval.changes.count == 1 ? "Allow this change?" : "Allow these changes?" }
        return approval.title.hasSuffix("?") ? approval.title : approval.title + "?"
    }

    var body: some View {
        ArticlePanel {
            HStack(spacing: 6) {
                NucleoIcon("shield", size: 13)
                Text("Approval").font(.system(size: 12, weight: .medium)).tracking(-0.2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .modifier(PagedStrip())
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(question).font(.system(size: 15, weight: .semibold))
                    if let reason { Text(reason).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2) }
                }
                if let command = approval.command {
                    let lines = command.split(separator: "\n", omittingEmptySubsequences: false).count
                    VStack(alignment: .leading, spacing: 6) {
                        Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(commandOpen ? nil : Self.folded).fixedSize(horizontal: false, vertical: true)
                        if lines > Self.folded {
                            Button(commandOpen ? "Show less" : "Show all \(lines) lines") { commandOpen.toggle() }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) { CopyButton(text: command).padding(4) }
                }
                ForEach(approval.changes, id: \.path) { change in FileChangeCard(change: change, status: .running, cwd: cwd) }
                // As the question card's options: a numbered row each.
                VStack(spacing: 6) {
                    ForEach(Array(approval.choices.enumerated()), id: \.element.id) { index, choice in
                        let row = Button { choose(choice) } label: {
                            HStack(spacing: 10) {
                                Text("\(index + 1)").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                                    .background(Theme.choiceCap).clipShape(RoundedRectangle(cornerRadius: 5))
                                Text(choice.label).font(.system(size: 13))
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.choice, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        if index == 0 { row.keyboardShortcut(.defaultAction) } else { row }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension EnvironmentValues {
    /// Above the composer (ConversationView's dock): as wide as the composer, and denser.
    @Entry var askDocked = false
    /// The height of a docked card, the same for every card waiting; nil, its own.
    @Entry var askDockHeight: CGFloat? = nil
    /// The dock's place among what waits: "1 of 3", and a step either way.
    @Entry var askPager: AskPager? = nil
}

/// Where the dock is among the asks waiting, and how to move.
struct AskPager {
    let index: Int
    let count: Int
    let move: (Int) -> Void
}

/// A card's strip, with the dock's pager at its end when several wait.
private struct PagedStrip: ViewModifier {
    @Environment(\.askPager) private var pager

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            Spacer(minLength: 8)
            if let pager, pager.count > 1 {
                HStack(spacing: 2) {
                    Button { pager.move(-1) } label: { NucleoIcon("chevron-right", size: 11).rotationEffect(.degrees(180)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .disabled(pager.index == 0)
                    Text("\(pager.index + 1) of \(pager.count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Button { pager.move(1) } label: { NucleoIcon("chevron-right", size: 11).frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .disabled(pager.index == pager.count - 1)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.trailing, 8)
            }
        }
    }
}

/// What waits on you, above the composer: one at a time (the provider's questions and approvals, then what the agent
/// asked through Zero), the rest a step away in its strip. As tall as the tallest of them, so stepping between them
/// moves nothing, and a step is instant. A view of its own: paging and measuring redraw the dock, not the conversation.
struct AskDock: View, Equatable {
    /// Drawn again only when what waits changes, not with each redraw of the conversation (a keystroke, a send): it
    /// lays out every card waiting to measure them.
    static func == (a: AskDock, b: AskDock) -> Bool {
        a.session == b.session && a.cwd == b.cwd && a.questions == b.questions && a.approvals == b.approvals && a.asks == b.asks && a.page == b.page
    }

    let session: String
    let cwd: String
    let questions: [Question]
    let approvals: [Approval]
    let asks: [Ask]
    let inbox: InboxController
    let page: CGFloat
    let answer: (String, [String: [String]]) -> Void
    let decide: (String, String) -> Void
    @State private var index = 0
    @State private var heights: [String: CGFloat] = [:]

    private var ids: [String] { questions.map(\.id) + asks.map(\.id) + approvals.map(\.id) }

    var body: some View {
        let ids = ids
        if !ids.isEmpty {
            let shown = min(index, ids.count - 1)
            let tallest = ids.compactMap { heights[$0] }.max()
            card(ids[shown])
                .environment(\.askDockHeight, tallest.map { min($0, max(160, page * 0.45)) })
                .environment(\.askPager, AskPager(index: shown, count: ids.count) { step in index = max(0, min(ids.count - 1, shown + step)) })
                // Each one laid out unseen at its own height, so the dock is as tall as the tallest. Only with
                // several: one alone is its own height.
                .background(alignment: .top) {
                    if ids.count > 1 {
                        ZStack(alignment: .top) {
                            ForEach(ids, id: \.self) { id in
                                card(id)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                        // Only a change: each write redraws the dock and every card in it.
                                        if abs((heights[id] ?? 0) - height) > 0.5 { heights[id] = height }
                                    }
                            }
                        }
                        .environment(\.askPager, AskPager(index: 0, count: ids.count) { _ in })
                        .hidden().allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .onChange(of: ids.count) { if ids.count <= 1 { heights = [:] } }
        }
    }

    @ViewBuilder private func card(_ id: String) -> some View {
        Group {
            if let question = questions.first(where: { $0.id == id }) {
                QuestionCard(question: question, session: session, inbox: inbox) { answers in answer(question.id, answers) }
            } else if let approval = approvals.first(where: { $0.id == id }) {
                ApprovalCard(approval: approval, cwd: cwd) { choice in decide(approval.id, choice.id) }
            } else if let ask = asks.first(where: { $0.id == id }) {
                AgentAskCard(ask: ask, inbox: inbox)
            }
        }
        .id(id)
        .environment(\.askDocked, true)
    }
}
