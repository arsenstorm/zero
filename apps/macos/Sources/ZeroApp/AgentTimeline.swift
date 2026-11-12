import AppKit
import Observation
import SwiftUI
import ZeroCore

/// One agent, read top to bottom like a chat: a short list of what came before, its latest note, then what to do now.
struct AgentTimeline: View {
    @Bindable var controller: InboxController
    var focus: FocusState<String?>.Binding
    private static let earlierRow: CGFloat = 16, earlierGap: CGFloat = 8
    private static func earlierHeight(_ rows: Int) -> CGFloat {
        min(CGFloat(rows) * earlierRow + CGFloat(max(rows - 1, 0)) * earlierGap, 6 * earlierRow + 5 * earlierGap) // six rows at most
    }

    var body: some View {
        let open = controller.cards.filter { !$0.state.isFinal }
        let exchange = Self.latestExchange(controller.cards.filter { $0.state.isFinal })
        let waiting = controller.agentFilter.map { controller.waitingOn($0) } ?? false

        if !exchange.earlier.isEmpty { earlierCard(exchange.earlier) }
        ForEach(exchange.recent) { ask in
            CardView(ask: ask, controller: controller, focus: focus).id(ask.id)
                // Yours rises out of the composer; a reply takes the placeholder's place.
                .transition(ask.kind == .message ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
        }
        // A task of Zero's: what it said last, in its own words, newer than any note above.
        if let agent = controller.agentFilter, let reply = latestReply(agent), !waiting { replyCard(agent, reply) }
        if waiting, let agent = controller.agentFilter { workingRow(agent) }
        ForEach(open) { ask in CardView(ask: ask, controller: controller, focus: focus).id(ask.id) }
        if let agent = controller.agentFilter, let screen = controller.store.screens[agent] {
            ScreenCard(agent: agent, screen: screen, controller: controller)
        }
        if let agent = controller.agentFilter, controller.store.canMessage(agent) {
            ComposerCard(controller: controller, focus: focus, mode: .agent(agent))
        }
        if open.isEmpty && exchange.recent.isEmpty && exchange.earlier.isEmpty {
            Text("Nothing from this agent yet").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(18)
                .card()
        }
    }

    /// The latest exchange stays in view: your last message on the right and what the agent said since on the
    /// left, with a placeholder holding the reply's place while it works. Everything before folds into
    /// "Earlier", so sending again moves the previous exchange up into the list and opens a new one below.
    private static func latestExchange(_ history: [Ask]) -> (recent: [Ask], earlier: [Ask]) {
        let start =
            history.lastIndex(where: { $0.kind == .message })
            ?? history.lastIndex(where: { $0.kind == .note }) ?? history.endIndex
        return (Array(history[start...]), Array(history[..<start].suffix(40)))
    }

    private func earlierCard(_ earlier: [Ask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Earlier").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            // Six rows at most, the newest in view, scrolling contained like a run's output, with the edges
            // fading where more is past them.
            ContainedList(height: Self.earlierHeight(earlier.count)) {
                VStack(alignment: .leading, spacing: Self.earlierGap) {
                    ForEach(earlier) { ask in EarlierRow(ask: ask, controller: controller) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(controller.agentFilter) // each agent's list starts fresh, fades included
            // A row opened from the list shows in full beneath it, inside the same card: it is history,
            // not a new turn in the conversation.
            if let id = controller.expandedEarlier, let ask = earlier.first(where: { $0.id == id }) {
                Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 4)
                EarlierDetail(ask: ask).transition(.opacity)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// A Zero task's latest answer, without its ending line, when it's newer than the agent's latest ask or note.
    private func latestReply(_ agent: String) -> (text: String, at: Date?)? {
        guard agent.hasPrefix("zerod-"), let conversation = controller.workspace?.conversation(String(agent.dropFirst("zerod-".count))),
            let answer = conversation.items.last(where: { if case .agent(_, true) = $0.kind { true } else { false } }),
            case let .agent(text, _) = answer.kind
        else { return nil }
        let words = ZeroEnding.split(text).0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        let at = answer.at.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        if let at, let latest = controller.cards.last?.createdAt, latest > at { return nil }
        return (words, at)
    }

    private func replyCard(_ agent: String, _ reply: (text: String, at: Date?)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(speaker(agent)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if let at = reply.at {
                    Text("· " + at.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Open task") {
                    if let url = URL(string: "zero://task/" + agent.dropFirst("zerod-".count)) {
                        (NSApp.delegate as? AppDelegate)?.openZeroURL(url)
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            // Its first few paragraphs: the pane is a glance; the task's page has the rest.
            MarkdownText(String(reply.text.prefix(1200)), size: 12.5, compact: true)
                .frame(maxHeight: 220, alignment: .top).clipped()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .id("reply-\(agent)")
    }

    private func workingRow(_ agent: String) -> some View {
        HStack(spacing: 8) {
            Spinner().frame(width: 10, height: 10)
            Text("\(speaker(agent)) is working…").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .card()
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("waiting")
        .transition(.opacity)
    }

}

/// An Earlier row in full: the whole message, or the question with what was answered and, for a run, its output.
private struct EarlierDetail: View {
    let ask: Ask
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ask.kind == .note || ask.kind == .message {
                MarkdownText(ask.body, cwd: ask.agent.cwd ?? ask.cwd)
            } else {
                Text(ask.title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled).fixedSize(
                    horizontal: false, vertical: true)
                if !ask.body.isEmpty, ask.body != ask.title {
                    Text(ask.body).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let detail = ask.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let command = ask.command, !command.isEmpty {
                    Text(ask.kind == .run && !ask.output.isEmpty ? "$ \(command)\n\(ask.output.suffix(2000))" : command)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(14)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if ask.kind != .run, let answer = ask.answer {
                    NucleoLabel(answer, icon: ask.state == .declined ? "circle-xmark" : "circle-check", fill: "glyph", size: 13)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(ask.state == .declined ? .red : .green)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line of an agent's history: when, what kind, who said what. A click opens it into its full card under the
/// list; on hover, a reply button starts a message quoting it.
private struct EarlierRow: View {
    let ask: Ask
    @Bindable var controller: InboxController
    @State private var hovered = false

    private var open: Bool { controller.expandedEarlier == ask.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TimelineView(.periodic(from: .zeroBeat, by: 1)) { context in
                Text(shortAge(ask.answeredAt ?? ask.createdAt, now: context.date))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
            }
            NucleoIcon(symbol, size: 12).foregroundStyle(.tertiary).frame(width: 14)
            Text(summary).font(.system(size: 12)).foregroundStyle(open ? .primary : .secondary).lineLimit(1)
            Spacer(minLength: 4)
            if let agent = controller.agentFilter, controller.store.canMessage(agent) {
                Button {
                    controller.quote(ask, to: agent)
                } label: {
                    NucleoIcon("share-left", size: 12).foregroundStyle(.secondary)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).tip("Reply to this").opacity(hovered ? 1 : 0)
            }
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            controller.holdTop = true
            withAnimation(.easeOut(duration: 0.2)) { controller.expandedEarlier = open ? nil : ask.id }
        }
    }

    private var symbol: String {
        switch ask.kind {
        case .note where ask.status == "closed": "circle-xmark"
        case .note: "message-check"
        case .message: "circle-arrow-up"
        case .run: "terminal"
        case .permission: "lock"
        case .approve: "badge-check"
        case .question, .choice: "circle-question"
        }
    }

    /// A transcript line: who said it, then the first line of what they said.
    private var summary: String {
        switch ask.kind {
        case .note where ask.status == "closed": return "Closed"
        case .note: return speaker(ask.agent.name) + ": " + (ask.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ask.body)
        case .message: return "You: " + ask.body
        case .run: return "\(ask.title) · " + (ask.state == .declined ? "rejected" : "ran, exit \(ask.exitCode ?? 0)")
        default: return "\(ask.title) · " + (ask.state == .declined ? "rejected" : (ask.answer ?? "answered"))
        }
    }
}
