import AppKit
import SwiftUI
import ZeroCore

// A task, laid out as Codex lays one out: its name and actions in the window's title bar (TitleBar), the conversation
// in a column centred in the page, and a pane floating on the right with what's known about it (its workers a click
// away).

/// The task pages, the last few kept mounted behind the one shown: a switch back to one shows it as it was, scroll,
/// draft and all, with nothing to build. Hidden pages take no clicks, keys or focus.
struct TaskPages: View {
    let workspace: Workspace
    let inbox: InboxController
    @Bindable var navigation: Navigation
    let current: String
    @State private var recent: [String] = []
    /// Each in a hosting view of its own (PageHost), so kept pages cost a streamed update nothing: in one view graph,
    /// every update of the window went through all of them (twice the cost at 8 pages).
    private static let kept = 8

    var body: some View {
        let shown = recent.contains(current) ? recent : recent + [current]
        ZStack {
            ForEach(shown, id: \.self) { id in
                let active = id == current
                PageHost(active: active) {
                    TaskView(
                        workspace: workspace, inbox: inbox, lead: id, navigation: navigation, active: active,
                        shown: active && navigation.windowShown
                    )
                    .disabled(!active)
                    .accessibilityHidden(!active)
                }
                .zIndex(active ? 1 : 0)
            }
        }
        .onChange(of: current, initial: true) {
            var list = recent.filter { $0 != current && workspace.conversation($0) != nil }
            list.append(current)
            if list.count > Self.kept { list.removeFirst(list.count - Self.kept) }
            recent = list
        }
    }
}

/// A page in a view graph of its own, hidden (no clicks, keys or drawing) while another is shown.
private struct PageHost<Content: View>: NSViewRepresentable {
    let active: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content().environment(\.self, context.environment)))
        // Sized by the page's frame, never the other way round.
        host.sizingOptions = []
        host.isHidden = !active
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        host.rootView = AnyView(content().environment(\.self, context.environment))
        host.isHidden = !active
    }
}

private struct TaskView: View {
    let workspace: Workspace
    let inbox: InboxController
    let lead: String
    @Bindable var navigation: Navigation

    /// Other tasks by id, for a message from one: its name, and opening it (a worker on its lead's page).
    private var taskLink: TaskLink {
        TaskLink(
            name: { [workspace] id in workspace.names[id] },
            open: { [workspace, navigation] id in
                let lead = workspace.roster[id]?.parent
                navigation.place = .task(lead ?? id)
                navigation.worker = lead == nil ? nil : id
            })
    }
    /// The page shown, as against one kept behind it.
    var active = true
    /// And on screen: the window open and not covered.
    var shown = true

    private var team: [Conversation] {
        let all = workspace.conversations
        var team = all.filter { $0.id == lead }
        var i = 0
        while i < team.count { let id = team[i].id; team += all.filter { $0.parent == id }; i += 1 }
        return team
    }

    /// Another task, from this one (a branch): a worker of the same lead shows under it.
    private func open(_ id: String) {
        if let parent = workspace.conversation(id)?.parent, workspace.conversation(parent)?.parent == nil {
            navigation.place = .task(parent)
            navigation.worker = id
        } else {
            navigation.place = .task(id)
        }
    }

    var body: some View {
        let team = team
        // The worker shown, when it is one of this lead's: another page's worker is not this page's business.
        let worker = navigation.worker.flatMap { id in team.contains { $0.id == id } ? id : nil }
        let conversation = workspace.conversation(worker ?? lead)
        // The lead's row, or the worker's own when a worker is shown: its status, place and asks are its own.
        let leadRow = workspace.board.first { $0.session == lead }
        let row = worker.flatMap { leadRow?.member($0) } ?? leadRow
        if let conversation, conversation.terminal != nil {
            // A terminal runs edge to edge; the pane sits beside it as a column of its own.
            HStack(spacing: 0) {
                if let live = workspace.live(conversation.id) {
                    ConversationView(
                        workspace: workspace, inbox: inbox, active: active, shown: shown,
                        queued: workspace.queued(conversation.id, board: row?.queued ?? []), held: row?.held ?? false, next: row?.next,
                        live: live, open: open
                    ).equatable().id(conversation.id).environment(\.taskLink, taskLink)
                }
                if navigation.pane {
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                    TaskDetails(
                        workspace: workspace, inbox: inbox, navigation: navigation, row: row, conversation: conversation, docked: true)
                }
            }
        } else {
            ZStack(alignment: .topTrailing) {
                if let conversation, let live = workspace.live(conversation.id) {
                    ConversationView(
                        workspace: workspace, inbox: inbox, active: active, shown: shown,
                        queued: workspace.queued(conversation.id, board: row?.queued ?? []), held: row?.held ?? false, next: row?.next,
                        live: live, open: open
                    ).equatable().id(conversation.id).environment(\.taskLink, taskLink)
                }
                if navigation.pane, let conversation {
                    TaskDetails(workspace: workspace, inbox: inbox, navigation: navigation, row: row, conversation: conversation).padding(
                        TaskDetails.inset)
                }
            }
        }
    }
}

/// The window's title bar beside the back and forward arrows, from where the page starts: on a task's page its name,
/// and what can be done with it (stop a turn, its provider's terminal, the rest in a menu), and the pane's toggle.
struct TitleBar: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    /// How far in from the bar's own edge the page starts, with the sidebar at its standard width.
    let inset: CGFloat
    @AppStorage(SidebarWidth.key) private var sidebarWidth = SidebarWidth.standard
    @AppStorage(InboxFilter.key) private var inboxFilter = InboxFilter.waiting
    @AppStorage(InboxFilter.titleKey) private var inboxFilterTitle = ""

    /// "Inbox" for what's waiting; "Inbox – Answered", or the agent's name, for the rest.
    private var inboxTitle: String {
        switch inboxFilter {
        case InboxFilter.waiting: "Inbox"
        case InboxFilter.answered: "Inbox – Answered"
        default: "Inbox – " + inboxFilterTitle
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if navigation.ready, case .task(let lead) = navigation.place,
                let conversation = workspace.conversation(navigation.worker ?? lead)
            {
                // The line between the sidebar and the title, there only when a title is.
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 16).padding(.trailing, 12)
                Text(workspace.board.first { $0.session == lead }?.task ?? workspace.conversation(lead).map(Workspace.label(of:)) ?? "")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .onTapGesture(count: 2, perform: Self.doubleClicked)
                drag
                actions(conversation)
                BarButton(symbol: "sidebar-right", help: navigation.pane ? "Hide details" : "Show details", selected: navigation.pane) {
                    navigation.pane.toggle()
                }
            } else if navigation.ready, navigation.place == .board || navigation.place == .inbox {
                // The page's name in the bar, as a task's is.
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 16).padding(.trailing, 12)
                Text(navigation.place == .inbox ? inboxTitle : "All tasks").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .onTapGesture(count: 2, perform: Self.doubleClicked)
                drag
            } else {
                drag
            }
        }
        .padding(.leading, max(0, inset + CGFloat(sidebarWidth - SidebarWidth.standard))).padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The bar's empty stretch still moves the window and zooms it on a double-click, as a title bar does.
    private var drag: some View {
        Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
            .simultaneousGesture(TapGesture(count: 2).onEnded(Self.doubleClicked))
    }

    /// What System Settings › Desktop & Dock says a title bar's double-click does: zoom, minimise, or nothing.
    static func doubleClicked() {
        guard let window = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    @ViewBuilder private func actions(_ conversation: Conversation) -> some View {
        let busy = conversation.status == .working || conversation.status == .waiting
        BarButton(
            symbol: "terminal",
            help: conversation.terminal == nil
                ? "Open in \(conversation.provider.title)'s own terminal, for what only it has"
                : "Back to Zero, with what happened in the terminal", selected: conversation.terminal != nil
        ) {
            Task {
                conversation.terminal == nil
                    ? await workspace.openTerminal(conversation.id) : await workspace.closeTerminal(conversation.id)
            }
        }
        .disabled(conversation.terminal == nil && (conversation.thread == nil || busy))
        Menu {
            // Paused, its Resume is the pause's.
            if workspace.isPaused(conversation.id) {
                pausing(conversation.id, in: workspace)
            } else {
                if conversation.status == .offline {
                    Button("Resume") { Task { await workspace.resume(conversation.id) } }
                } else {
                    Button("End session") { Task { await workspace.stop(conversation.id) } }
                }
                pausing(conversation.id, in: workspace)
            }
            Button("Copy folder path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conversation.cwd, forType: .string)
            }
            Button("Show folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: conversation.cwd)) }
            Divider()
            if case .task(let lead) = navigation.place {
                Button("Move to Later") {
                    navigation.place = .home; Task { await workspace.moveToLater(lead) }
                }
                Button("Archive…") { workspace.archiving = lead }
            }
        } label: {
            NucleoIcon("dots", size: 15).foregroundStyle(.secondary).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tip("More")
    }
}

/// A small icon button in a bar: grey, a soft square under the pointer, a firmer one while it's on.
private struct BarButton: View {
    let symbol: String
    let help: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NucleoIcon(symbol, size: 15).foregroundStyle(selected ? .primary : .secondary).frame(width: 28, height: 28)
        }
        .buttonStyle(Hovering(selected: selected, radius: 7, fill: Theme.chip)).tip(help)
    }
}
