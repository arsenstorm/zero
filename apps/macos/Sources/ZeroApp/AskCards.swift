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
        } content: {
            CardView(ask: ask, controller: inbox, focus: $focus, flat: true, showsByline: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
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
