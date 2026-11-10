import AppKit
import SwiftUI
import ZeroCore

/// What the inbox page shows, kept between visits: what's waiting, what's been answered, or one agent's asks.
enum InboxFilter {
    static let key = "inboxFilter"
    /// The agent's name as shown, for the title bar, which doesn't know the inbox's agents.
    static let titleKey = "inboxFilterTitle"
    static let waiting = "waiting", answered = "answered"
    static func agent(_ name: String) -> String { "agent:" + name }
}

/// The inbox's own sidebar: what's waiting and what's been answered, then each agent that has asked you anything,
/// with how many of its asks wait on you.
struct InboxSidebar: View {
    @Bindable var controller: InboxController
    @AppStorage(InboxFilter.key) private var filter = InboxFilter.waiting
    @AppStorage(InboxFilter.titleKey) private var filterTitle = ""

    var body: some View {
        let asks = AsksPage.asks(controller)
        let waiting = asks.filter { !$0.state.isFinal }
        // Agents by their latest ask, newest first.
        let agents = asks.reversed().reduce(into: [String]()) { names, ask in if !names.contains(ask.agent.name) { names.append(ask.agent.name) } }
        SidebarColumn(title: "Inbox") {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row(InboxFilter.waiting, "Waiting on you", count: waiting.count) { NucleoIcon("hourglass", size: 15) }
                    row(InboxFilter.answered, "Answered", count: nil) { NucleoIcon("circle-check", size: 15) }
                    if !agents.isEmpty {
                        SidebarHeading(text: "Agents")
                        ForEach(agents, id: \.self) { name in
                            let open = waiting.filter { $0.agent.name == name }.count
                            row(InboxFilter.agent(name), controller.store.displayName(of: name), count: open > 0 ? open : nil) {
                                Circle().fill(open > 0 ? Color.orange : Theme.stroke).frame(width: 7, height: 7)
                            }
                        }
                    }
                }
                .padding(.bottom, 36)
            }
            .thinScrollbar(outset: 10, remember: "sidebar.inbox") // in the sidebar's padding: at its edge, clear of the rows
        }
    }

    private func row(_ id: String, _ title: String, count: Int?, @ViewBuilder icon: () -> some View) -> some View {
        Button { filter = id; filterTitle = title } label: {
            HStack(spacing: 9) {
                icon().foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 { Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary) }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).frame(height: 30)
        }
        .buttonStyle(Hovering(selected: filter == id))
    }
}

/// The inbox as a page: the board's table of asks, with the control bar's card for the one picked opening under its
/// row, so it's answered right there (the same card, answered here or in the panel alike).
struct AsksPage: View {
    @Bindable var controller: InboxController
    @AppStorage(InboxFilter.key) private var filter = InboxFilter.waiting
    @FocusState private var focus: String?
    /// The row whose card is open; the oldest waiting one until another is picked.
    @State private var picked: String?

    /// Asks for you (not notes or messages), one card for runs several agents asked for alike.
    static func asks(_ controller: InboxController) -> [Ask] {
        controller.store.asks.filter(\.isForYou)
    }

    static func waiting(_ controller: InboxController) -> [Ask] { asks(controller).filter { !$0.state.isFinal } }

    /// What the filter shows: waiting oldest first (a queue), answered newest first.
    private var shown: [Ask] {
        let all = Self.asks(controller)
        let answered = Array(all.filter(\.state.isFinal).sorted { ($0.answeredAt ?? $0.createdAt) > ($1.answeredAt ?? $1.createdAt) }.prefix(50))
        switch filter {
        case InboxFilter.waiting: return all.filter { !$0.state.isFinal }
        case InboxFilter.answered: return answered
        default:
            let name = String(filter.dropFirst("agent:".count))
            return all.filter { $0.agent.name == name && !$0.state.isFinal } + answered.filter { $0.agent.name == name }
        }
    }

    var body: some View {
        let asks = shown
        // "" is every row closed, on purpose.
        let open: String? = picked == "" ? nil : picked.flatMap { id in asks.first { $0.id == id }?.id } ?? asks.first { !$0.state.isFinal }?.id
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !asks.isEmpty { table(asks, open: open) }
            }
            .centredColumn(1040)
            .padding(.vertical, 36)
        }
        .thinScrollbar(remember: "inbox")
        .overlay { if asks.isEmpty { empty } }
        .onChange(of: filter) { picked = nil }
    }

    private func table(_ asks: [Ask], open: String?) -> some View {
        ArticlePanel {
            line(head: true, ask: Text("Ask"), agent: Text("Agent"), kind: Text("Kind"), since: Text("When")).padding(.vertical, -3)
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(asks.enumerated()), id: \.element.id) { index, ask in
                    if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1) }
                    // Open, the row becomes the control bar's card (flat, to answer it here): the card says what the
                    // row did, so it isn't said twice. Its × folds it back to a row.
                    if open == ask.id {
                        CardView(ask: ask, controller: controller, focus: $focus, flat: true)
                            // Room at the right for the ×, clear of the card's own corner (a run's Stop sits there).
                            .padding(.trailing, 30)
                            .background(Theme.rowHover)
                            .overlay(alignment: .topTrailing) {
                                Button { picked = "" } label: {
                                    NucleoIcon("xmark", size: 11).foregroundStyle(.secondary).frame(width: 24, height: 24)
                                }
                                .buttonStyle(Hovering(radius: 6)).tip("Fold it back").padding(10)
                            }
                    } else {
                        Button { picked = ask.id } label: {
                            line(head: false,
                                 ask: Text(ask.title).foregroundStyle(.primary).lineLimit(2).tip(ask.title),
                                 agent: Text(controller.store.displayName(of: ask.agent.name)).foregroundStyle(.secondary).lineLimit(1),
                                 kind: Text(Self.kind(ask)).foregroundStyle(.secondary),
                                 since: since(ask))
                        }
                        .buttonStyle(Hovering(radius: 0, fill: .clear, hover: Theme.rowHover))
                    }
                }
            }
        }
    }

    private func line(head: Bool, ask: some View, agent: some View, kind: some View, since: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            ask.frame(maxWidth: .infinity, alignment: .leading)
            agent.frame(width: 180, alignment: .leading)
            kind.frame(width: 100, alignment: .leading)
            since.frame(width: 110, alignment: .leading)
        }
        .font(head ? .system(size: 12, weight: .medium) : .system(size: 13))
        .tracking(head ? -0.2 : 0)
        .foregroundStyle(head ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.85)))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private static func kind(_ ask: Ask) -> String {
        switch ask.kind {
        case .question, .choice: "Question"
        case .approve, .permission: "Approval"
        case .run: "Command"
        case .note: "Note"
        case .message: "Message"
        }
    }

    /// When it was asked (waiting, in orange) or answered: the time today, the date before.
    private func since(_ ask: Ask) -> some View {
        let date = ask.state.isFinal ? (ask.answeredAt ?? ask.createdAt) : ask.createdAt
        return Text(MessageBlock<EmptyView>.stamp(date) + (ask.state == .declined ? " · declined" : ""))
            .foregroundStyle(ask.state.isFinal ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange)).lineLimit(1)
    }

    /// Nothing to show: said plainly, with what would show here.
    private var empty: some View {
        let (title, detail): (String, String) = switch filter {
        case InboxFilter.waiting: ("You're all caught up", "When an agent asks you something, wants an approval or needs a command run, it lands here, and the bar's inbox turns orange.")
        case InboxFilter.answered: ("Nothing answered yet", "Asks you answer show here, newest first.")
        default: ("Nothing from this agent", "Its questions, approvals and commands show here when it asks.")
        }
        return VStack(spacing: 14) {
            NucleoIcon("inbox", fill: "glyph", size: 26).foregroundStyle(.secondary)
                .frame(width: 64, height: 64).background(Theme.row, in: Circle())
            VStack(spacing: 6) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
        }
        .padding(.top, 40)
    }
}

/// An agent Zero doesn't run (Claude Code in a terminal, say), opened from the docked bar: its conversation
/// with you, as the panel shows it, with the box to message it.
struct AgentPage: View {
    @Bindable var controller: InboxController
    let name: String
    @FocusState private var focus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(text: controller.store.displayName(of: name))
                AgentTimeline(controller: controller, focus: $focus)
            }
            .centredColumn(620)
            .padding(.vertical, 36)
        }
        .thinScrollbar()
        .scrollIndicators(.never)
        .defaultScrollAnchor(.bottom)
        // The panel's conversation view follows the agent it's set to; the panel is hidden while the bar is docked.
        .onAppear { controller.agentFilter = name }
        .onDisappear { if controller.agentFilter == name { controller.agentFilter = nil } }
    }
}

/// What's written and attached in a composer and not sent yet, by composer ("task:<id>", "new"): kept as you type, so
/// quitting Zero (an update) loses none of it. Images are Zero's own copies (~/.zero/attachments), kept by path.
enum Drafts {
    private struct Draft: Codable { var text: String; var images: [String] }
    private static let key = "drafts"

    static func load(_ composer: String) -> (text: String, images: [URL])? {
        guard let data = UserDefaults.standard.dictionary(forKey: key)?[composer] as? Data,
              let draft = try? JSONDecoder().decode(Draft.self, from: data) else { return nil }
        return (draft.text, draft.images.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) })
    }

    /// Nothing written or attached: gone.
    static func save(_ composer: String, text: String, images: [URL]) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[composer] = text.isEmpty && images.isEmpty ? nil : try? JSONEncoder().encode(Draft(text: text, images: images.map(\.path)))
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// A task's status in words, beside the details pane: what it's blocked on or where it is and, blocked on an ask, the
/// inbox's own card for it, to answer right there. Zero's own card, drawn at once.
struct StatusCard: View {
    static let width: CGFloat = 380
    let row: BoardRow
    let inbox: InboxController
    @FocusState private var focus: String?

    var body: some View {
        let asks = row.asks.compactMap { waiting in inbox.store.asks.first { $0.id == waiting.id } }
        VStack(alignment: .leading, spacing: 10) {
            StateLabel(state: row.state)
            // Blocked on an ask, the ask says it all: no words of the status beside it.
            if asks.isEmpty, let needs = row.needs { Text(needs).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
            if asks.isEmpty, let now = row.now, row.needs == nil {
                Text((try? AttributedString(markdown: now, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(now))
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // The inbox's card without its own frame (a card in a card), lined up with this one's padding.
            ForEach(asks) { ask in CardView(ask: ask, controller: inbox, focus: $focus, flat: true, showsByline: false).padding(.horizontal, -16) }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        // One layer, then its shadow: a shadow on the stack itself shadows every row and word in it.
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
    }
}

/// Zero restarting for an update, said while it happens: what it's letting finish first (a task's command, for at most
/// a couple of minutes, counted down), then that the new version is starting. The tasks it paused say so themselves.
struct UpdatingBar: View {
    let updating: Workspace.Updating

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Spinner().frame(width: 12, height: 12)
                    Text("Updating Zero").font(.system(size: 13, weight: .semibold))
                    Text(status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if let left = left(at: context.date) {
                        Text(left).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if !updating.starting && !updating.waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(updating.waiting.prefix(3).enumerated()), id: \.element.id) { index, waiting in
                            if index > 0 { Divider().padding(.leading, 10) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(waiting.task.isEmpty ? "A task" : waiting.task).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(waiting.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.row, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            // Concentric: the commands' 6 pt corners inset 10 pt in the card's 16.
            .padding(10)
            .frame(width: 400, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.stroke))
            .compositingGroup().shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }

    private var status: String {
        if updating.starting { return "Starting the new version" }
        if updating.waiting.isEmpty { return "Pausing tasks between steps" }
        return updating.waiting.count == 1 ? "Letting a command finish" : "Letting \(updating.waiting.count) commands finish"
    }

    /// The longest it may still wait, while it waits on commands.
    private func left(at now: Date) -> String? {
        guard !updating.starting, !updating.waiting.isEmpty else { return nil }
        let left = max(0, updating.most - Int(now.timeIntervalSince(updating.since)))
        return "\(left / 60):\(String(format: "%02d", left % 60))"
    }
}
