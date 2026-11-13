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
        return inbox.store.asks(of: session)
            .filter { ask in
                ask.state != .expired && order.contains(ask.request ?? "")
                    && (ask.agent.ref == session || ask.agent.name == "zerod-" + session)
            }
            .sorted { (order.firstIndex(of: $0.request ?? "") ?? 0) < (order.firstIndex(of: $1.request ?? "") ?? 0) }
    }

    var body: some View {
        let asks = asks
        // The table's panel: a grey shell and strip around the card's own surface, one tone, as the other cards are.
        ArticlePanel {
            HStack(spacing: 6) {
                NucleoIcon("circle-question", fill: "glyph", size: 13)
                Text(question.fields.count == 1 ? (question.fields.first?.header ?? "Question") : "Questions").font(
                    .system(size: 12, weight: .medium)
                ).tracking(-0.2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).frame(height: QueueStrip.heading)
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
    /// In the conversation: a step among its turn's steps, quiet as thinking is (the question and what became of it);
    /// the full card is above the composer while it waits.
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
        if compact { line } else { card }
    }

    private var line: some View {
        HStack(alignment: .top, spacing: 8) {
            NucleoIcon(ask.kind == .run ? "terminal" : "circle-question", fill: ask.kind == .run ? "outline" : "glyph", size: 14)
                .foregroundStyle(.secondary).frame(width: 14, height: 16)
            Text(ask.kind == .run ? "Asked to run" : "Asked").fontWeight(.medium)
            // Its whole title on hover, by the words cut short (on the full-width row, it showed at the row's middle).
            Text(ask.kind == .run ? (ask.command ?? ask.title) : ask.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .tip(ask.title)
            Spacer(minLength: 8)
            Text(answered).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.system(size: 12))
    }

    private var card: some View {
        cardBody
            .environment(\.doneCard, ask.doneCheck == true)
    }

    private var cardBody: some View {
        ArticlePanel {
            HStack(spacing: 6) {
                NucleoIcon(ask.kind == .run ? "terminal" : "circle-question", fill: ask.kind == .run ? "outline" : "glyph", size: 13)
                Text(ask.kind == .run ? "Run on your Mac" : ask.kind == .approve ? "Approval" : "Question").font(
                    .system(size: 12, weight: .medium)
                ).tracking(-0.2)
            }
            // Whether the task is done: a question still, in the Done state's colour, so it reads as the one it is.
            .foregroundStyle(ask.doneCheck == true ? AnyShapeStyle(Theme.doneInk) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 14).frame(height: QueueStrip.heading)
            .modifier(PagedStrip())
        } content: {
            CardView(ask: ask, controller: inbox, focus: $focus, flat: true, showsByline: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
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

/// Sinking in a conversation, nothing elsewhere.
private struct SinkingIn: ViewModifier {
    let foot: ConversationView.Foot?
    @ViewBuilder func body(content: Content) -> some View {
        if let foot { content.modifier(Sinking(foot: foot)) } else { content }
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
                    Text(
                        (try? AttributedString(markdown: field.question, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                            ?? AttributedString(field.question)
                    )
                    .font(.system(size: 13, weight: .medium)).lineSpacing(5).textSelection(.enabled).tint(Theme.link)
                    if !field.options.isEmpty {
                        WrappingStack(spacing: 6) {
                            ForEach(field.options, id: \.label) { option in
                                let on = picked[field.id, default: []].contains(option.label)
                                Button(option.label) {
                                    if field.multiple {
                                        picked[field.id, default: []].formSymmetricDifference([option.label])
                                    } else {
                                        picked[field.id] = on ? [] : [option.label]
                                    }
                                }
                                .buttonStyle(ChoiceChip(on: on)).tip(option.description ?? "")
                            }
                        }
                    }
                    if field.secret {
                        SecureField("Secret", text: Binding(get: { typed[field.id, default: ""] }, set: { typed[field.id] = $0 }))
                            .textFieldStyle(.dialog)
                    } else if field.other || field.options.isEmpty {
                        TextField(
                            field.options.isEmpty ? "Your answer" : "Or say something else",
                            text: Binding(get: { typed[field.id, default: ""] }, set: { typed[field.id] = $0 })
                        )
                        .textFieldStyle(.dialog)
                    }
                }
            }
            let unanswered = question.fields.contains { answer($0).isEmpty }
            DialogButton(title: "Answer", kind: .primary, enabled: !unanswered) {
                send(Dictionary(uniqueKeysWithValues: question.fields.map { ($0.id, answer($0)) }))
            }
            .tip(unanswered ? "Answer every question first" : "")
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
            !approval.title.localizedCaseInsensitiveContains(reason)
        else { return nil }
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
            .padding(.horizontal, 14).frame(height: QueueStrip.heading)
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
                        let row = Button {
                            choose(choice)
                        } label: {
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
    /// The most a docked card may be: its share of the page.
    @Entry var askDockMax: CGFloat? = nil
    /// Told when a text box in a docked card gains or loses focus.
    @Entry var dockFocus: ConversationView.Foot? = nil
    /// A docked card held at a height (a step between cards easing it), not its own; nil, its own.
    @Entry var askDockHeight: CGFloat? = nil
    /// Told a docked card's own height as it's laid out, while a step eases to it.
    @Entry var dockOwn: ((CGFloat) -> Void)? = nil
    /// A panel in a done question's shades (ArticlePanel).
    @Entry var doneCard = false
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
                    Button {
                        pager.move(-1)
                    } label: {
                        NucleoIcon("chevron-right", size: 11).rotationEffect(.degrees(180)).frame(width: 22, height: 22).contentShape(
                            Rectangle())
                    }
                    .disabled(pager.index == 0)
                    Text("\(pager.index + 1) of \(pager.count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Button {
                        pager.move(1)
                    } label: {
                        NucleoIcon("chevron-right", size: 11).frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .disabled(pager.index == pager.count - 1)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.trailing, 8)
            }
        }
    }
}

/// What waits on you, above the composer: one at a time (the provider's questions and approvals, then what the agent
/// asked through Zero), the rest a step away in its strip. Each at its own height, a step between them instant. A
/// view of its own: paging redraws the dock, not the conversation.
struct AskDock: View, Equatable {
    /// Drawn again only when what waits changes, not with each redraw of the conversation (a keystroke, a send).
    static func == (a: AskDock, b: AskDock) -> Bool {
        a.session == b.session && a.cwd == b.cwd && a.questions == b.questions && a.approvals == b.approvals && a.asks == b.asks
            && a.page == b.page
    }

    let session: String
    let cwd: String
    let questions: [Question]
    let approvals: [Approval]
    let asks: [Ask]
    let inbox: InboxController
    let page: CGFloat
    /// In a conversation: the card sinks as it's scrolled up (Sinking), its ring and clip coming and going with it.
    var foot: ConversationView.Foot? = nil
    let answer: (String, [String: [String]]) -> Void
    let decide: (String, String) -> Void
    @State private var index = 0
    /// A step between cards: the new one held at the last one's height, then eased to its own, frame by frame, so it
    /// stays on the composer and the conversation slides with it. Instant, the conversation jumped; the dock's frame
    /// eased around a card swapped at once, a shorter one was left off the composer for a moment.
    @State private var stepping = false
    @State private var easing = false
    @State private var held: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    private var ids: [String] { questions.map(\.id) + asks.map(\.id) + approvals.map(\.id) }

    /// How far a docked card runs on under the composer: its foot behind it, so it reads as coming out from under it.
    static let tuck: CGFloat = 14

    var body: some View {
        // Rising out from behind the composer (drawn over it), and fading where it is once answered.
        // One piece: its contents placed by it as it moves (the body's text, an AppKit view, went straight to where it
        // ends while the card was still rising). Its sinking (ring, clip) inside the transition: outside, the ring
        // showed before the card, and the clip, sized to an emptied dock, left a scrap of the card leaving. (Not
        // composited as one: the ring's blur would have nothing behind it to blur.)
        ZStack { dock }
            .animation(ConversationView.slide, value: ids.isEmpty)
    }

    @ViewBuilder private var dock: some View {
        let ids = ids
        if !ids.isEmpty {
            let shown = min(index, ids.count - 1)
            card(ids[shown])
                .modifier(HeldHeight(height: held, on: stepping))
                .environment(\.dockOwn, stepping ? { own in settle(own) } : nil)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    if !stepping { shownHeight = $0 }
                }
                .environment(\.askDockMax, max(160, page * 0.45))
                .environment(
                    \.askPager,
                    AskPager(index: shown, count: ids.count) { step in
                        let next = max(0, min(ids.count - 1, shown + step))
                        guard next != shown, !stepping else { return }
                        held = shownHeight
                        stepping = true
                        index = next
                        // Never told its own height: let go of it, at its own at once.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if stepping && !easing { stepping = false } }
                    }
                )
                .modifier(SinkingIn(foot: foot))
                .geometryGroup()
                // In, it rises from behind the composer (Sinker), with the conversation's scroll. Out, answered, it
                // fades where it is: sliding down as it faded read as something moving that the user didn't move.
                .transition(
                    .asymmetric(
                        insertion: foot == nil ? Motion.transition(.offset(y: 36).combined(with: .opacity)) : .identity,
                        removal: .opacity))
        }
    }

    /// The new card's own height, known once it's laid out at the last one's: eased to.
    private func settle(_ own: CGFloat) {
        guard stepping, !easing else { return }
        let to = min(own, max(160, page * 0.45))
        guard abs(to - held) > 0.5 else { stepping = false; return }
        easing = true
        // Its height measured as it eased isn't kept (it was the held one's): the one it ends at is.
        withAnimation(Motion.animation(ConversationView.slide)) {
            held = to
        } completion: {
            shownHeight = to; stepping = false; easing = false
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

/// The docked card's height, given to it frame by frame as it eases (an environment value alone isn't animated).
private struct HeldHeight: ViewModifier, Animatable {
    var height: CGFloat
    let on: Bool
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }
    func body(content: Content) -> some View { content.environment(\.askDockHeight, on ? height : nil) }
}
