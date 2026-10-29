import AppKit
import SwiftUI
import ZeroCore

/// The workspace window, laid out as ChatGPT's: an outer rail (home, settings) on the window's grey, and a panel
/// holding an inner sidebar and the page. Home's sidebar is the tasks (a lead session with its workers); its page a new
/// task, every task at once, or one. Everything comes from `Workspace`; nothing here knows a provider's protocol.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @Bindable var navigation: Navigation
    /// The inbox's asks and how they're answered: the panel's, shown here too.
    let inbox: InboxController
    let settings: () -> SettingsView

    var body: some View {
        ZStack {
            window.opacity(navigation.ready ? 1 : 0)
            if !navigation.ready { ZeroMark().frame(width: 64, height: 64).foregroundStyle(.secondary).transition(.opacity) }
        }
        .frame(minWidth: 980, minHeight: 600)
        // The rail and the strip above the panel: translucent grey over what's behind the window, blurred, as Codex's.
        .background { ZStack { BehindWindow(); Theme.railTint } }
        .ignoresSafeArea()
        // The board is polled, so the sidebar stays fresh while the window is open.
        // zerod pushes the board whenever it changes; it's asked for once here only so the splash can wait for it.
        .task {
            let deadline = ContinuousClock.now + .seconds(3)
            while !workspace.connected, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            await workspace.loadIntegrations()
            await workspace.refreshBoard()
            show()
        }
        // Never held on the mark: a slow gh or zerod shows the window as it is.
        .task {
            try? await Task.sleep(for: .seconds(5))
            show()
        }
    }

    /// Until zerod has given the rail its integrations and the sidebar its tasks, the window shows Zero's mark alone,
    /// with no arrows or title bar.
    private func show() {
        guard !navigation.ready else { return }
        withAnimation(.easeOut(duration: 0.2)) { navigation.ready = true }
        NSApp.windows.forEach { $0.toolbar?.validateVisibleItems() }
    }

    private var window: some View {
        HStack(spacing: 0) {
            Rail(place: $navigation.place, workspace: workspace, inbox: inbox)
            Group {
                switch navigation.place {
                case .settings: settings()
                case .integrations: IntegrationsPane(workspace: workspace)
                case .pads, .pad: ScratchpadsPage(workspace: workspace, navigation: navigation)
                case .inbox:
                    HStack(spacing: 0) {
                        InboxSidebar(controller: inbox)
                        Rectangle().fill(Theme.stroke).frame(width: 1)
                        AsksPage(controller: inbox).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
                    }
                case .integration(let name):
                    IntegrationPage(workspace: workspace, integration: Integration(rawValue: name) ?? .github, edit: { Integration.edit(name, place: &navigation.place) },
                                    openTask: { navigation.place = .task($0) }).id(name)
                default:
                    HStack(spacing: 0) {
                        TasksSidebar(workspace: workspace, navigation: navigation)
                        Rectangle().fill(Theme.stroke).frame(width: 1)
                        page.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            .padding(.top, 38).padding([.trailing, .bottom], 4) // under the window's buttons, as ChatGPT's
        }
        .overlay(alignment: .bottom) {
            if let error = workspace.lastError {
                Text(error).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.redRow, in: Capsule()).padding(16)
                    .onTapGesture { workspace.lastError = nil }
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch navigation.place {
        case .board: BoardView(workspace: workspace, open: { navigation.place = .task($0) })
        case .agent(let name): AgentPage(controller: inbox, name: name).id(name)
        case .task(let id) where workspace.conversation(id) != nil: TaskView(workspace: workspace, lead: id, navigation: navigation).id(id)
        default: NewTaskView(workspace: workspace, started: { navigation.place = .task($0) })
        }
    }
}

/// Where the page starts across the window with the sidebar at its standard width: the rail, the sidebar, its edge.
/// The title bar adds however far the sidebar has been dragged from that.
let pageStart: CGFloat = 48 + CGFloat(SidebarWidth.standard) + 1

/// The outer rail: home at the top, then each integration that's switched on, in the order you put them (⌘-drag one,
/// or right-click it); integrations and settings at the foot.
private struct Rail: View {
    @Binding var place: Navigation.Place
    let workspace: Workspace
    let inbox: InboxController
    @AppStorage("railOrder") private var order = "github,linear"
    @State private var dragging: Integration?
    @State private var dragged: CGFloat = 0
    @State private var command = NSEvent.modifierFlags.contains(.command)
    @State private var monitor: Any?
    /// One rail item and the gap after it.
    private static let step: CGFloat = 38

    private var home: Bool {
        switch place { case .inbox, .settings, .integrations, .integration, .pads, .pad: false; default: true }
    }

    /// Every integration in your order, those never placed after.
    private var ranked: [Integration] {
        let placed = order.split(separator: ",").compactMap { Integration(rawValue: String($0)) }
        return placed + Integration.allCases.filter { !placed.contains($0) }
    }

    private var shown: [Integration] { ranked.filter { $0.enabled(in: workspace.integrations) } }

    var body: some View {
        VStack(spacing: 6) {
            item("house-4", selected: home, help: "Home") { if !home { place = .home } }
            // What agents are waiting on you for, and how many.
            item("inbox", selected: place == .inbox, help: "Inbox") { place = .inbox }
                .overlay(alignment: .topTrailing) {
                    let waiting = AsksPage.waiting(inbox).count
                    if waiting > 0 {
                        Text("\(waiting)").font(.system(size: 9.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Color.orange, in: Capsule())
                            .offset(x: 3, y: -2).allowsHitTesting(false)
                    }
                }
            let pads = { if case .pad = place { true } else { place == .pads } }()
            item("note-3", selected: pads, help: "Scratchpads") { if !pads { place = .pads } }
            let shown = shown
            ForEach(Array(shown.enumerated()), id: \.element) { index, integration in
                let selected = place == .integration(integration.rawValue)
                Button { place = .integration(integration.rawValue) } label: {
                    integration.icon(size: 17).foregroundStyle(selected ? .primary : .secondary).frame(width: 32, height: 32)
                }
                .buttonStyle(Hovering(selected: selected, fill: Theme.railSelected, hover: Theme.railHover)).help(integration.title)
                .offset(y: dragging == integration ? held(index, of: shown.count) : shift(index, in: shown))
                .zIndex(dragging == integration ? 1 : 0)
                .animation(.spring(duration: 0.22), value: dragging == integration ? 0 : shift(index, in: shown))
                .highPriorityGesture(drag(integration, from: index, of: shown.count), including: command ? .all : .subviews)
                .contextMenu {
                    if index > 0 { Button("Move up") { move(integration, to: index - 1) } }
                    if index < shown.count - 1 { Button("Move down") { move(integration, to: index + 1) } }
                    Button("Edit views") { Integration.edit(integration.rawValue, place: &place) }
                    Divider()
                    Button("Hide from the sidebar") { Task { await workspace.setIntegration(integration.rawValue, enabled: false) } }
                }
            }
            Spacer()
            item("puzzle-piece", selected: place == .integrations, help: "Integrations") { place = .integrations }
            item("gear", selected: place == .settings, help: "Settings") { place = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.top, 50).padding(.bottom, 12)
        .frame(width: 48)
        // ⌘ held or not decides whether a drag moves an item or is a click.
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in command = event.modifierFlags.contains(.command); return event }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    /// Held ⌘: the item follows the pointer within the integrations' slots, the others making way as it passes, and it
    /// lands in the slot it's let go over.
    private func drag(_ integration: Integration, from index: Int, of count: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in dragging = integration; dragged = value.translation.height }
            .onEnded { _ in
                let target = slot(from: index, of: count)
                // Landed where it's drawn already: no animation back and forth.
                withTransaction(Transaction(animation: nil)) {
                    move(integration, to: target)
                    dragging = nil
                    dragged = 0
                }
            }
    }

    /// Where the dragged item is drawn: under the pointer, but not past the first or last integration's slot, with a
    /// little give beyond (never over Home or the items at the foot).
    private func held(_ index: Int, of count: Int) -> CGFloat {
        let (top, bottom) = (-CGFloat(index) * Self.step, CGFloat(count - 1 - index) * Self.step)
        let give = { (over: CGFloat) in min(8, over * 0.2) }
        if dragged < top { return top - give(top - dragged) }
        if dragged > bottom { return bottom + give(dragged - bottom) }
        return dragged
    }

    /// The slot the dragged item is over.
    private func slot(from index: Int, of count: Int) -> Int {
        max(0, min(count - 1, index + Int((dragged / Self.step).rounded())))
    }

    /// How far an item moves to make way: one slot towards where the dragged one came from, if it's been passed.
    private func shift(_ index: Int, in shown: [Integration]) -> CGFloat {
        guard let dragging, let from = shown.firstIndex(of: dragging), index != from else { return 0 }
        let to = slot(from: from, of: shown.count)
        if from < to, index > from, index <= to { return -Self.step }
        if to < from, index >= to, index < from { return Self.step }
        return 0
    }

    private func move(_ integration: Integration, to index: Int) {
        var list = shown
        guard let from = list.firstIndex(of: integration) else { return }
        list.remove(at: from)
        list.insert(integration, at: max(0, min(list.count, index)))
        order = (list + ranked.filter { !list.contains($0) }).map(\.rawValue).joined(separator: ",")
    }

    private func item(_ symbol: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIcon(symbol, fill: selected ? "glyph" : "outline", size: 17)
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(Hovering(selected: selected, fill: Theme.railSelected, hover: Theme.railHover)).help(help)
    }
}

private struct TasksSidebar: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    private var place: Navigation.Place {
        get { navigation.place }
        nonmutating set { navigation.place = newValue }
    }
    /// Leads whose workers are folded away, one per line.
    @AppStorage("foldedLeads") private var folded = ""
    /// How the tasks are ordered: by state (the board's own order), by name, or as they were dragged.
    @AppStorage("taskSort") private var sort = Sort.state
    /// The dragged order, one lead per line; tasks not in it yet go on top.
    @AppStorage("taskOrder") private var order = ""
    @State private var sortHovered = false

    enum Sort: String, CaseIterable { case state, name, manual }

    private func sorted(_ rows: [BoardRow]) -> [BoardRow] {
        switch sort {
        case .state: return rows
        case .name: return rows.sorted { $0.task.localizedStandardCompare($1.task) == .orderedAscending }
        case .manual:
            let rank = Dictionary(order.split(separator: "\n").enumerated().map { (String($1), $0) }, uniquingKeysWith: { first, _ in first })
            return rows.enumerated().sorted { (rank[$0.element.session] ?? -1, $0.offset) < (rank[$1.element.session] ?? -1, $1.offset) }.map(\.element)
        }
    }

    /// The lead being dragged, as the control bar's dots are: how far the pointer has moved it.
    @State private var drag: (lead: String, y: CGFloat)?
    /// Each lead's group (it and its workers shown) as drawn, with the gap below it: groups differ in height.
    @State private var heights: [String: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func height(_ lead: String) -> CGFloat { (heights[lead] ?? 30) + 1 }

    /// Where the dragged lead would land now: past each group whose middle it has crossed.
    private func dropIndex(in ids: [String]) -> Int? {
        guard let drag, let from = ids.firstIndex(of: drag.lead) else { return nil }
        var (to, y) = (from, drag.y)
        while y > 0, to + 1 < ids.count, y > height(ids[to + 1]) / 2 { y -= height(ids[to + 1]); to += 1 }
        while y < 0, to > 0, -y > height(ids[to - 1]) / 2 { y += height(ids[to - 1]); to -= 1 }
        return to
    }

    /// While dragging, the groups between where it came from and where it would land make way by its height.
    private func shift(of lead: String, in ids: [String]) -> CGFloat {
        guard let drag, drag.lead != lead, let from = ids.firstIndex(of: drag.lead), let to = dropIndex(in: ids),
              let i = ids.firstIndex(of: lead) else { return 0 }
        if from < to, i > from, i <= to { return -height(drag.lead) }
        if to < from, i >= to, i < from { return height(drag.lead) }
        return 0
    }

    /// A press that moves 4 pt drags the lead; let go, it takes the slot it's over and the order is manual from then
    /// on. False if it never moved: a click.
    private func reorder(_ lead: String, in rows: [BoardRow]) -> TaskRow.Reorder {
        TaskRow.Reorder(changed: { y in if abs(y) >= 4 || drag != nil { drag = (lead, y) } }, ended: {
            guard drag != nil else { return false }
            var ids = rows.map(\.session)
            let target = dropIndex(in: ids)
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                if let from = ids.firstIndex(of: lead), let target, target != from {
                    ids.remove(at: from)
                    ids.insert(lead, at: target)
                    order = ids.joined(separator: "\n")
                    sort = .manual
                }
                drag = nil
            }
            return true
        })
    }

    /// Leads that aren't on the board: finished and gone offline with nothing for him.
    private func earlier(_ all: [Conversation]) -> [Conversation] {
        let ids = Set(all.map(\.id)), onBoard = Set(workspace.board.map(\.session))
        return all.filter { lead in (lead.parent.map { !ids.contains($0) } ?? true) && !onBoard.contains(lead.id) }.reversed()
    }

    var body: some View {
        SidebarColumn(title: "Zero") {
            SidebarItem("New task", icon: "compose", selected: place == .home) { place = .home }
                .keyboardShortcut("n", modifiers: .command)
            SidebarItem("All tasks", icon: "list-checkbox", selected: place == .board) { place = .board }
            // Each lead's workers looked up once per update, not by searching every task for every row.
            let all = workspace.conversations
            let workersOf = Dictionary(grouping: all.filter { $0.parent != nil }, by: { $0.parent ?? "" })
            let earlier = earlier(all)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // The heading where every sidebar's is, its sort button centred over the tasks' state icons below.
                    HStack(spacing: 0) {
                        Text("Tasks").font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 10)
                        Spacer()
                        Menu {
                            Picker("Sort by", selection: $sort) {
                                Text("State").tag(Sort.state)
                                Text("Name").tag(Sort.name)
                                Text("Manual (drag to arrange)").tag(Sort.manual)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            NucleoIcon("sliders", size: 13).foregroundStyle(.secondary).frame(width: 24, height: 24)
                                .background(sortHovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        // Drawn as its label, not as AppKit's pop-up button: the square shows under the pointer.
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .onHover { sortHovered = $0 }
                        // A row's state icon is 14 pt, 10 pt in from the edge: its centre is 17 pt in, as this 24 pt button's.
                        .padding(.trailing, 5).help("Sort tasks")
                    }
                    // A 16 pt heading line with 18 above and 6 below, as SidebarHeading has, now 24 pt for the button.
                    .padding(.top, 14).padding(.bottom, 2)
                    if workspace.board.isEmpty {
                        Text("No tasks").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 10)
                    }
                    let folded = Set(folded.split(separator: "\n").map(String.init))
                    let rows = sorted(workspace.board)
                    let ids = rows.map(\.session)
                    ForEach(rows) { row in
                        let workers = workersOf[row.session] ?? []
                        let open = !folded.contains(row.session)
                        // A lead and its workers move as one.
                        VStack(alignment: .leading, spacing: 1) {
                            TaskRow(title: row.task, state: row.state, selected: place == .task(row.session) && navigation.worker == nil,
                                    fold: workers.isEmpty ? nil : open, action: {
                                // Its worker shown, the same task: back to the lead.
                                place = .task(row.session)
                                navigation.worker = nil
                            }, toggle: { toggle(row.session) }, reorder: reorder(row.session, in: rows))
                                .contextMenu { archive(row.session) }
                            if open {
                                ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
                                    TaskRow(title: Workspace.label(of: worker), state: TaskRow.state(of: worker), selected: navigation.worker == worker.id,
                                            branch: index == workers.count - 1 ? .last : .middle, action: {
                                        place = .task(row.session)
                                        navigation.worker = worker.id
                                    })
                                }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[row.session] = $0 }
                        .offset(y: drag?.lead == row.session ? drag!.y : shift(of: row.session, in: ids))
                        .animation(drag?.lead == row.session || reduceMotion ? nil : .snappy(duration: 0.2), value: dropIndex(in: ids))
                        .zIndex(drag?.lead == row.session ? 1 : 0)
                    }
                    if !earlier.isEmpty {
                        SidebarHeading(text: "Earlier")
                        ForEach(earlier) { lead in
                            SidebarItem(Workspace.label(of: lead), selected: place == .task(lead.id)) { place = .task(lead.id) }
                                .contextMenu { archive(lead.id) }
                        }
                    }
                }
                // The last task clear of the fade at the foot.
                .padding(.bottom, 36)
            }
            .thinScrollbar(outset: 10, remember: "sidebar.tasks") // in the sidebar's padding: at its edge, clear of the rows
            .scrollIndicators(.never)
            // Soft edges, as the conversation has: more above, more below.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 20)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                }
            }
            // The list has the sidebar's whole height: what's said about the daemon and usage lies over its foot, on a
            // fade, and the last task scrolls clear of it.
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
    }

    private func toggle(_ lead: String) {
        var set = Set(folded.split(separator: "\n").map(String.init))
        if set.contains(lead) { set.remove(lead) } else { set.insert(lead) }
        withAnimation(.easeOut(duration: 0.15)) { folded = set.sorted().joined(separator: "\n") }
    }

    /// Archive: the task leaves the sidebar; its files stay in zerod's archive/.
    private func archive(_ id: String) -> some View {
        Button("Archive") {
            if place == .task(id) { place = .home }
            Task { await workspace.archive(id) }
        }
    }

    @ViewBuilder private var footer: some View {
        let usage = workspace.usage.filter { !$0.1.windows.isEmpty }
        if !workspace.connected || !usage.isEmpty {
            footerLines(usage)
                .padding(.horizontal, 10).padding(.top, 22)
                .background(LinearGradient(stops: [.init(color: Theme.composer.opacity(0), location: 0), .init(color: Theme.composer, location: 0.5)],
                                           startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, -10)
        }
    }

    private func footerLines(_ usage: [(Provider, Usage)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !workspace.connected {
                NucleoLabel("Connecting to Zero's daemon…", icon: "plug-off", size: 12)
            }
            // What each provider last said about its limits.
            ForEach(usage, id: \.0) { provider, usage in
                Text("\(provider.title)  " + usage.windows.map { "\($0.name) \(Int(($0.used * 100).rounded()))%" }.joined(separator: " · "))
                    .foregroundStyle(usage.limited ? Color.orange : .secondary)
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 10)
    }
}

// A task, laid out as Codex lays one out: its name and actions in the window's title bar (TitleBar), the conversation
// in a column centred in the page, and a pane floating on the right with what's known about it (its workers a click
// away).

private struct TaskView: View {
    let workspace: Workspace
    let lead: String
    @Bindable var navigation: Navigation

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
        let conversation = workspace.conversation(navigation.worker ?? lead)
        let row = workspace.board.first { $0.session == lead }
        if let conversation, conversation.terminal != nil {
            // A terminal runs edge to edge; the pane sits beside it as a column of its own.
            HStack(spacing: 0) {
                if let live = workspace.live(conversation.id) { ConversationView(workspace: workspace, live: live, open: open).id(conversation.id) }
                if navigation.pane {
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                    TaskDetails(workspace: workspace, navigation: navigation, row: row, conversation: conversation, team: team, lead: lead, shown: $navigation.worker, docked: true)
                }
            }
        } else {
            ZStack(alignment: .topTrailing) {
                if let conversation, let live = workspace.live(conversation.id) { ConversationView(workspace: workspace, live: live, open: open).id(conversation.id) }
                if navigation.pane, let conversation {
                    TaskDetails(workspace: workspace, navigation: navigation, row: row, conversation: conversation, team: team, lead: lead, shown: $navigation.worker).padding(8)
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
            if navigation.ready, case .task(let lead) = navigation.place, let conversation = workspace.conversation(navigation.worker ?? lead) {
                // The line between the sidebar and the title, there only when a title is.
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 16).padding(.trailing, 12)
                Text(workspace.board.first { $0.session == lead }?.task ?? workspace.conversation(lead).map(Workspace.label(of:)) ?? "")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .onTapGesture(count: 2, perform: Self.doubleClicked)
                drag
                actions(conversation)
                BarButton(symbol: "sidebar-right", help: navigation.pane ? "Hide details" : "Show details", selected: navigation.pane) { navigation.pane.toggle() }
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
        if busy && conversation.terminal == nil {
            ProgressView().controlSize(.small).padding(.trailing, 2)
            Button("Stop") { Task { await workspace.interrupt(conversation.id) } }
                .keyboardShortcut(".", modifiers: .command).controlSize(.small)
        }
        BarButton(symbol: "terminal", help: conversation.terminal == nil
                  ? "Open in \(conversation.provider.title)'s own terminal, for what only it has"
                  : "Back to Zero, with what happened in the terminal", selected: conversation.terminal != nil) {
            Task { conversation.terminal == nil ? await workspace.openTerminal(conversation.id) : await workspace.closeTerminal(conversation.id) }
        }
        .disabled(conversation.terminal == nil && (conversation.thread == nil || busy))
        Menu {
            if conversation.status == .offline {
                Button("Resume") { Task { await workspace.resume(conversation.id) } }
            } else {
                Button("End session") { Task { await workspace.stop(conversation.id) } }
            }
            Button("Copy folder path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conversation.cwd, forType: .string)
            }
            Button("Show folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: conversation.cwd)) }
            Divider()
            if case .task(let lead) = navigation.place {
                Button("Archive") {
                    navigation.place = .home
                    Task { await workspace.archive(lead) }
                }
            }
        } label: {
            NucleoIcon("dots", size: 15).foregroundStyle(.secondary).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
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
        .buttonStyle(Hovering(selected: selected, radius: 7, fill: Theme.chip)).help(help)
    }
}

/// The pane on a task's right: where it stands, what it needs from you, the agent on it, where it works, its workers.
private struct TaskDetails: View {
    let workspace: Workspace
    let navigation: Navigation
    let row: BoardRow?
    let conversation: Conversation
    let team: [Conversation]
    let lead: String
    @Binding var shown: String?
    /// Beside a terminal: a full-height column on the sidebar's grey rather than a floating card.
    var docked = false

    var body: some View {
        details
            .padding(16).frame(width: 280, alignment: .leading)
            .frame(maxHeight: docked ? .infinity : nil, alignment: .top)
            .background(docked ? Theme.composer : Theme.card, in: RoundedRectangle(cornerRadius: docked ? 0 : 14))
            .overlay { if !docked { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke) } }
            .shadow(color: .black.opacity(docked ? 0 : 0.04), radius: 10, y: 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            // What it is doing, first and largest: its state, then where it is in its own words.
            if let row {
                VStack(alignment: .leading, spacing: 6) {
                    StateLabel(state: row.state).font(.system(size: 13))
                    if let needs = row.asks.first?.title ?? row.needs {
                        Text(needs).font(.system(size: 12.5)).foregroundStyle(.orange).lineLimit(3)
                    } else if let now = row.now {
                        // The agent's words are Markdown: a link reads as its words, not its address.
                        Text((try? AttributedString(markdown: now, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(now))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3).help(now)
                    }
                }
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                property("Agent") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([conversation.provider.title, conversation.model, conversation.effort].compactMap { $0 }.joined(separator: " · "))
                        if conversation.permissions == .unrestricted { Text("Unrestricted").foregroundStyle(.orange) }
                        if let usage { Text(usage).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                    }
                }
                property("Where") {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: conversation.cwd)) } label: {
                        Text(row?.place ?? (conversation.cwd as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain).help((conversation.cwd as NSString).abbreviatingWithTildeInPath + " — show in Finder")
                }
                if let branch = conversation.branch {
                    property("Branch") { Text(branch).lineLimit(1).truncationMode(.middle).help(branch) }
                }
                if let ticket = conversation.ticket {
                    property("Ticket") {
                        if let url = ticketURL(ticket) {
                            Button { NSWorkspace.shared.open(url) } label: { NucleoLabel(ticket, icon: "link", size: 11).foregroundStyle(Color.accentColor) }
                                .buttonStyle(.plain).help("Open \(ticket)")
                        } else {
                            Text(ticket)
                        }
                    }
                }
            }
            .font(.system(size: 12.5))
            if team.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workers").font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(team) { member in
                        SidebarItem(member.id == lead ? "Lead" : Workspace.label(of: member), selected: (shown ?? lead) == member.id) { shown = member.id }
                            .padding(.horizontal, -10)
                    }
                }
            }
            if let ticket = conversation.ticket {
                TaskPads(workspace: workspace, ticket: ticket) { navigation.place = .pad($0) }
            }
        }
    }

    /// A row of the pane's properties: its name in a narrow column, its value beside it.
    private func property(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.leading).frame(width: 52, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The ticket's page, from the integration's view that lists it.
    private func ticketURL(_ ticket: String) -> URL? {
        let link = workspace.items.values.lazy.flatMap { $0 }.first { $0.ticketKey == ticket }?.url
        return link.flatMap { LinearLinks.url($0) }
    }

    /// "5 hours 18% · 7 days 5%": what the provider last reported for the account.
    private var usage: String? {
        guard let windows = conversation.usage?.windows, !windows.isEmpty else { return nil }
        return windows.map { "\($0.name) \(Int(($0.used * 100).rounded()))%" }.joined(separator: " · ")
    }
}

/// A task's own scratchpads (Tasks/<ticket>): its state first, the start of it shown, each one a click away. Looked at
/// again while shown, since the agent keeps them current.
private struct TaskPads: View {
    let workspace: Workspace
    let ticket: String
    let open: (String) -> Void
    @State private var pads: [PadSummary] = []
    @State private var state: Pad?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pads.isEmpty {
                HStack(spacing: 2) {
                    Text("State").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if let state {
                        icon("link", help: "Copy a link to it") { PadLinks.copy(state.link, title: "\(ticket) state", markdown: true) }
                        icon("arrow-right", help: "Open it") { open(state.id) }
                    }
                }
                if let state {
                    // The pad as it reads, without its title and link; its start, fading out, the rest a click away.
                    Button { open(state.id) } label: {
                        MarkdownText(Self.gist(state.content), size: 12, compact: true).allowsHitTesting(false)
                            .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading).clipped()
                            .mask { VStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 36) } }
                            .padding(10)
                            .background(Theme.composer, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Open the task's state")
                }
                ForEach(pads.filter { $0.id != state?.id }) { pad in
                    SidebarItem(pad.title, icon: "file-content") { open(pad.id) }.padding(.horizontal, -10)
                }
            }
        }
        // Read again when zerod says a pad changed (an agent keeping its state), and every half minute for one edited
        // outside Zero.
        .task(id: "\(ticket)|\(workspace.padsVersion)") {
            while !Task.isCancelled {
                pads = await workspace.taskPads(ticket)
                if let found = pads.first(where: { $0.title == "State" }) { state = await workspace.readPad(found.id) }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { NucleoIcon(name, size: 13).foregroundStyle(.secondary).frame(width: 24, height: 24) }
            .buttonStyle(Hovering(radius: 6)).help(help)
    }

    /// The pad without its title and the bare link under it: the preview starts with what's in it.
    static func gist(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[first].hasPrefix("# ") { lines.remove(at: first) }
        lines.removeAll { line in let t = line.trimmingCharacters(in: .whitespaces); return t.hasPrefix("http") && !t.contains(" ") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

// The board: every task at once, most urgent first, as a panel from arsenstorm.com: a grey shell carrying the
// headings, a lighter body, hairlines between rows.

private struct BoardView: View {
    let workspace: Workspace
    let open: (String) -> Void

    var body: some View {
        let rows = workspace.board
        // A column of one place says nothing.
        let places = Set(rows.map(\.place)).count > 1
        let (running, offline) = (rows.filter(\.online), rows.filter { !$0.online })
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading("Running", "Agents at work now, most urgent first.")
                table(running, places: places, empty: "Nothing is running. Start a task, or message one below to resume it.")
                if !offline.isEmpty {
                    heading("Offline", "Not running now. Each shows the state it was last in; a message resumes it.").padding(.top, 14)
                    table(offline, places: places).opacity(0.85)
                }
            }
            .centredColumn(1040)
            .padding(.vertical, 36)
        }
        .thinScrollbar(remember: "board")
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView { NucleoLabel("No tasks", icon: "list-checkbox", size: 20) } description: { Text("Start one with New task (⌘N). Each shows here as a row, its workers folded in.") }
            }
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func table(_ rows: [BoardRow], places: Bool, empty: String? = nil) -> some View {
        ArticlePanel {
            // The headings in the shell's strip, over the columns they name.
            line(head: true, places: places, task: Text("Task"), place: Text("Where"), state: Text("State"), now: Text("Now"), actions: Text(""))
                .padding(.vertical, -3)
        } content: {
            VStack(spacing: 0) {
                // No rows: the table stays, its body saying why.
                if rows.isEmpty, let empty {
                    Text(empty).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 22)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1) }
                    Button { open(row.session) } label: {
                        line(head: false, places: places,
                             task: VStack(alignment: .leading, spacing: 2) {
                                 // Three lines at most; the whole of it on hover.
                                 Text(row.task).foregroundStyle(.primary).lineLimit(3).help(row.task)
                                 if row.workers > 0 { Text(row.workers == 1 ? "1 worker" : "\(row.workers) workers").font(.system(size: 12)).foregroundStyle(.secondary) }
                             },
                             place: Text(row.place).foregroundStyle(.secondary),
                             state: VStack(alignment: .leading, spacing: 3) {
                                 StateLabel(state: row.state)
                                 if let needs = needs(row) { Text(needs).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3).help(needs) }
                             },
                             now: Text((try? AttributedString(markdown: row.now ?? "", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(row.now ?? ""))
                                 .lineLimit(3).help(row.now ?? ""),
                             actions: Text(""))
                    }
                    .buttonStyle(Hovering(radius: 0, hover: Theme.rowHover))
                    // Over the row's last column, not in its label: a menu inside a button gives its clicks to the button.
                    .overlay(alignment: .trailing) { RowActions(workspace: workspace, row: row, open: open).padding(.trailing, 12) }
                }
            }
        }
    }

    /// One row of the table, the header included: two fixed columns, the rest sharing what's left.
    private func line(head: Bool, places: Bool, task: some View, place: some View, state: some View, now: some View, actions: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            task.frame(maxWidth: .infinity, alignment: .leading)
            if places { place.frame(width: 140, alignment: .leading) }
            state.frame(width: 170, alignment: .leading)
            now.frame(maxWidth: .infinity, alignment: .leading)
            actions.frame(width: 28)
        }
        .font(head ? .system(size: 12, weight: .medium) : .system(size: 13))
        .tracking(head ? -0.2 : 0)
        .foregroundStyle(head ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.85)))
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// What a blocked task waits on the user for: an open ask first, then what the agent handed over.
    private func needs(_ row: BoardRow) -> String? {
        if let first = row.asks.first { return first.title + (row.asks.count > 1 ? " (+\(row.asks.count - 1) more)" : "") }
        return row.needs
    }
}

/// A row's quick actions, in the ⋯ menu at its end.
private struct RowActions: View {
    let workspace: Workspace
    let row: BoardRow
    let open: (String) -> Void

    /// What the agent is asked when the user wants to know where it is.
    static let statusCheck = """
        Status check from the user: where is this task now? Answer in two or three lines, then post the same as a Zero \
        note: `zero note "<where it is>"`, with --blocked and --needs "<what you need from the user>" if you're waiting \
        on them, --waiting if on something else, --done if it's finished, --merged once it's merged. Keep the task's \
        state pad current too. Then \
        carry on with what you were doing.
        """

    @State private var hovered = false

    var body: some View {
        Menu {
            Button("Ask for a status update") { Task { await workspace.send(row.session, text: Self.statusCheck) } }
            Button("Open") { open(row.session) }
            Divider()
            if row.online {
                Button("End session") { Task { await workspace.stop(row.session) } }
            } else {
                Button("Resume") { Task { await workspace.resume(row.session) } }
            }
            Button("Copy task id") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.session, forType: .string)
            }
            Divider()
            Button("Archive") { Task { await workspace.archive(row.session) } }
        } label: {
            NucleoIcon("dots", size: 15).foregroundStyle(hovered ? .primary : .secondary).frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        // The menu's own size is wider than its dots; a square, as the rail's items are.
        .frame(width: 30, height: 30)
        // A square under the pointer, as the rail's items have; behind the menu, which draws no background of its label's.
        .background(hovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
        .help("Actions")
    }
}

/// A panel as arsenstorm.com draws one, in the app's own greys: the rail's grey as a shell 2 pt thick with a strip on
/// top (here, the table's headings), around a body in the sidebar's grey.
struct ArticlePanel<Strip: View, Content: View>: View {
    @ViewBuilder let strip: () -> Strip
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            strip()
            content()
                .background(Theme.composer)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(2)
        .background(Theme.rail, in: RoundedRectangle(cornerRadius: 12))
        // Bled out by its inner padding (the shell's 2 pt and a cell's 16), so its text lines up with the page's, as
        // the site's panels do with its prose.
        .padding(.horizontal, -18)
    }
}

/// What a task's state looks like, in colours that say it at a glance: orange it waits on you, red it's in trouble,
/// blue it works, green it's ready for you, grey the rest.
/// A task in the sidebar, as Solo lists an agent's: a lead with a chevron that folds its workers away, each worker
/// under it on a dotted branch. The state sits at the right, as on every task row.
private struct TaskRow: View {
    enum Branch { case middle, last }
    let title: String
    let state: BoardRow.State
    let selected: Bool
    /// A lead with workers: whether they show. Nil for a lead without any.
    var fold: Bool? = nil
    /// A worker: its place on its lead's branch.
    var branch: Branch? = nil
    let action: () -> Void
    var toggle: () -> Void = {}
    /// A lead that can be dragged into place: told how far the pointer moved, and when it let go (false: a click).
    var reorder: Reorder? = nil

    struct Reorder {
        let changed: (CGFloat) -> Void
        let ended: () -> Bool
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let branch { Branched(last: branch == .last).frame(width: 28) }
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                StateIcon(state: state).font(.system(size: 12))
            }
            .foregroundStyle(.primary)
            // A lead's title lines up with the headings, as every sidebar row's does; a worker's sits on its branch.
            .padding(.leading, branch == nil ? 10 : 0).padding(.trailing, 10).frame(height: 30)
        }
        .buttonStyle(Hovering(selected: selected))
        // One gesture for click and drag, as the control bar's: on the row's button only, so the fold chevron keeps its
        // own click. Global space: the row moves with the drag, so a local translation would cancel itself out.
        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { reorder?.changed($0.translation.height) }
            .onEnded { _ in if reorder?.ended() == false { action() } },
            including: reorder == nil ? .subviews : .all)
        // In the margin left of the title, outside the row's own button so its click is its own.
        .overlay(alignment: .leading) {
            if let fold {
                Button(action: toggle) {
                    NucleoIcon("chevron-down", size: 8).foregroundStyle(.tertiary).rotationEffect(.degrees(fold ? 0 : -90))
                        .frame(width: 10, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).offset(x: -1)
                .help(fold ? "Hide its workers" : "Show its workers")
            }
        }
    }

    /// A worker's state in the sidebar's terms: how it ended its last turn, if it said, else what it's doing.
    static func state(of worker: Conversation) -> BoardRow.State {
        if [.idle, .done, .offline].contains(worker.attention), let answer = worker.items.last(where: { if case .agent(_, true) = $0.kind { true } else { false } }),
           case let .agent(text, _) = answer.kind, let ending = ZeroEnding.split(text).1 {
            switch ending {
            case .done: return .done
            case .working: return .waiting
            case .blocked, .asked: return .needsYou
            }
        }
        return switch worker.attention {
        case .needsYou: .needsYou
        case .limited, .stuck, .failed: .trouble
        case .working, .starting: .working
        case .done: .done
        case .idle: .idle
        case .offline: .offline
        }
    }

    /// The dotted line from the lead down to this worker, and across to it; it runs on past a worker that isn't last.
    private struct Branched: View {
        let last: Bool
        var body: some View {
            Canvas { context, size in
                // Down from under the lead's chevron, then across to the worker's title.
                let x: CGFloat = 4, mid = size.height / 2
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: last ? mid : size.height))
                line.move(to: CGPoint(x: x, y: mid))
                line.addLine(to: CGPoint(x: size.width - 2, y: mid))
                context.stroke(line, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2.5]))
            }
            .frame(height: 30)
        }
    }
}

private struct StateIcon: View {
    let state: BoardRow.State

    var body: some View {
        Group {
            // At work it spins, as everywhere else in Zero something under way does.
            if state == .working { Spinner().frame(width: 12, height: 12).frame(width: 14, height: 14) }
            else { NucleoIcon(Self.look(state).symbol, fill: "glyph", size: 14).foregroundStyle(Self.look(state).color) }
        }
        .help(Self.look(state).name)
    }

    static func look(_ state: BoardRow.State) -> (symbol: String, color: Color, name: String) {
        switch state {
        case .needsYou: ("circle-warning", .orange, "Blocked")
        case .trouble: ("triangle-warning", .red, "In trouble")
        case .working: ("arrow-rotate-clockwise", .blue, "Working")
        case .waiting: ("hourglass", .secondary, "Waiting")
        case .done: ("circle-check", .green, "Done")
        case .merged: ("code-branch", .purple, "Merged")
        case .idle: ("moon", .secondary, "Idle")
        case .offline: ("power-off", .secondary, "Offline")
        }
    }
}

/// The symbol and its name, for the board's State column.
struct StateLabel: View {
    let state: BoardRow.State

    var body: some View {
        let look = StateIcon.look(state)
        HStack(spacing: 6) {
            StateIcon(state: state).font(.system(size: 13))
            Text(look.name).font(.system(size: 12, weight: .medium)).foregroundStyle(look.color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(look.color))
        }
    }
}

// The conversation.

private struct ConversationView: View {
    let workspace: Workspace
    /// The task's whole conversation, observed on its own: its words redraw this view, not the window.
    let live: LiveConversation
    /// Opens another task: a branch made from this one.
    var open: (String) -> Void = { _ in }
    private var conversation: Conversation { live.conversation }
    @State private var draft = ""
    /// The message of yours being gone back to.
    @State private var rewinding: ConversationItem?
    /// Images going with the next message.
    @State private var images: [URL] = []
    /// Where the conversation is scrolled to, and how much of it there is: for the scrollbar drawn over it.
    @State private var position = ScrollPosition(edge: .bottom)
    /// Where it's scrolled and what's on screen, read only by the scrollbar, the way down and the rail: scrolling
    /// redraws those, not the conversation.
    @State private var tracker = ScrollTracker()
    /// Your messages in the whole conversation, for the rail.
    @State private var outline: [OutlineMark] = []
    /// The rows standing in for older items are on screen: only then is the next page fetched.
    @State private var olderShown = false
    /// How tall the composer is: the conversation fades out just above it.
    @State private var composerHeight: CGFloat = 0
    /// Another provider picked for the next message; nil keeps the task's own.
    @State private var provider: Provider?
    /// The blocks on screen, by the message of yours each answers to: the rail's bright ticks.

    var body: some View {
        VStack(spacing: 0) {
            if let terminal = conversation.terminal {
                // The provider's own terminal has the task, for what only it has: the same thread, typed into there.
                HostTerminal(id: terminal.id, claudeCode: conversation.provider == .claude).id(terminal.id)
            } else {
                conversationPane
            }
        }
    }


    /// Where you are in the conversation: at its end (nothing kept), or the block at the top of the screen.
    private func rememberScroll() {
        guard let geometry = tracker.geometry else { return }
        if geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) < 60 {
            ScrollMemory.keep(nil, in: conversation.id)
            return
        }
        let order = TimelineBlock.of(conversation.items, working: false).map(\.id)
        guard let top = order.first(where: { tracker.seen[$0] != nil }), let turn = tracker.seen[top] else { return }
        ScrollMemory.keep((top, turn), in: conversation.id)
    }

    /// The message as a quote at the end of what's being written.
    private func quote(_ text: String) {
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        draft = (draft.isEmpty ? "" : draft + "\n\n") + quoted + "\n\n"
    }

    /// The message kept as a scratchpad in Saved, named by its first line.
    private func save(_ text: String) {
        let first = text.split(separator: "\n").first.map { String($0.prefix(60)) } ?? "Saved"
        let title = first.replacingOccurrences(of: "/", with: "\u{2215}").trimmingCharacters(in: CharacterSet(charactersIn: "#> ").union(.whitespaces))
        Task { await workspace.createPad(title: title.isEmpty ? "Saved" : title, folder: "Saved", content: text) }
    }

    private var conversationPane: some View {
        VStack(spacing: 0) {
            if let health {
                HStack(spacing: 10) {
                    NucleoLabel(health.text, icon: health.icon).font(.callout).foregroundStyle(health.color)
                    Spacer()
                    // Out of usage: the task carries on with another provider, the whole conversation with it.
                    if conversation.attention == .limited {
                        ForEach(Self.takeOver.filter { $0 != conversation.provider }, id: \.self) { other in
                            Button("Continue with \(other.title)") { carryOn(with: other) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8).background(health.color.opacity(0.08))
            }
            ScrollViewReader { proxy in
                // A step waiting on an approval shows once, in the approval.
                let blocks = TimelineBlock.of(conversation.items.filter { item in !conversation.approvals.contains { $0.item == item.id } },
                                              working: conversation.status == .working || conversation.status == .waiting)
                let turns = TimelineBlock.turns(blocks)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        // More above: rows standing in for it, the next page fetched as they come into view, the view
                        // kept on what was at its top.
                        let more = live.earlier
                        if more > 0 {
                            // While it's on screen, page after page (a long turn can leave it there); kept alive just
                            // off screen by the list, it fetches nothing. Anchored at the bottom, the view stays on
                            // what's read as each page goes in above.
                            SkeletonTurns().id("earlier")
                                .onScrollVisibilityChange(threshold: 0.01) { olderShown = $0 }
                                .task(id: olderShown ? more : -1) { if olderShown { await workspace.loadEarlier(conversation.id) } }
                        }
                        ForEach(blocks) { block in
                            // Compared before it's drawn: a word streamed into the last answer redraws only that one.
                            BlockRow(block: block, cwd: conversation.cwd, quote: quote, save: save, rewind: { rewinding = $0 }).equatable()
                                .id(block.id)
                                .onScrollVisibilityChange(threshold: 0.05) { shown in
                                    guard let turn = turns[block.id] else { return }
                                    if shown { tracker.seen[block.id] = turn } else { tracker.seen[block.id] = nil }
                                }
                                // The list drops what's far off screen without saying it went out of view.
                                .onDisappear { tracker.seen[block.id] = nil }
                        }
                        // Its provider still getting ready (signing in, say): say so, rather than an empty page.
                        if conversation.status == .starting {
                            Thinking(text: "Starting \(conversation.provider.title)…").id("starting")
                        }
                        ForEach(conversation.questions) { question in
                            QuestionCard(question: question) { answers in
                                Task { await workspace.answer(conversation.id, question: question.id, answers: answers) }
                            }
                            .id("question-" + question.id)
                        }
                        ForEach(conversation.approvals) { approval in
                            ApprovalCard(approval: approval, cwd: conversation.cwd) { choice in
                                Task { await workspace.decide(conversation.id, approval: approval.id, choice: choice.id) }
                            }
                            .id("approval-" + approval.id)
                        }
                        if let diff = conversation.diff, conversation.status == .idle, !diff.isEmpty {
                            DisclosureGroup("Everything the last turn changed") { DiffText(diff: diff) }.padding(.top, 4)
                        }
                        // Room for the composer and the fade above it: scrolled to the end, the last message sits just
                        // above the composer, and the scrollbar is at the bottom.
                        Color.clear.frame(height: composerHeight + 32).id("end")
                    }
                    .padding(.top, 20)
                    .centredColumn(760)
                }
                .scrollIndicators(.never)
                // Opened at the end, and held there as answers measure themselves and new ones come, while you're at
                // the end; content added above (an older page) leaves what you're reading where it is.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollPosition($position)
                // Where you were in it, kept when scrolling stops and when you leave.
                .onScrollPhaseChange { _, phase in if phase == .idle { rememberScroll() } }
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, now in tracker.geometry = now }
                // Soft edges: at the top, there's more above; just above the composer, the text fades out before it,
                // as Codex's does, with nothing behind the composer but the page.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 32)
                        // Under the composer: nothing, so the conversation doesn't show at its sides.
                        Color.clear.frame(height: composerHeight)
                    }
                }
                // The composer lies over the conversation's foot; the conversation runs the full height under it.
                .overlay(alignment: .bottom) {
                    composer.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { composerHeight = $0 }
                }
                // Scrolled up: a way back down, just above the composer.
                .overlay(alignment: .bottom) {
                    WayDown(tracker: tracker) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }.padding(.bottom, composerHeight + 6)
                }
                .overlay(alignment: .trailing) { ThinScrollbar(tracker: tracker) { position.scrollTo(y: $0) }.padding(.trailing, 2) }
                .overlay(alignment: .leading) {
                    // Every message of yours, loaded or not, from zerod's outline of the conversation.
                    let marks = outline.map { MessageRail.Mark(id: $0.id, text: $0.text, answer: $0.answer.map { ZeroEnding.split($0).0 }) }
                    if marks.count > 1 {
                        MessageRail(marks: marks, tracker: tracker) { id in
                            Task {
                                // Not loaded yet: everything from it down to what is, then there.
                                if !conversation.items.contains(where: { $0.id == id }) { await workspace.loadEarlier(conversation.id, from: id) }
                                withAnimation { proxy.scrollTo(id, anchor: .top) }
                            }
                        }
                        .padding(.leading, 18).padding(.vertical, 40)
                    }
                }
                // Fetched again as your messages come and go, not with every word streamed.
                .task(id: conversation.items.count(where: { if case .user = $0.kind { true } else { false } }) + live.earlier) {
                    outline = await workspace.outline(conversation.id)
                }
                // Left, it goes back to its latest items: memory doesn't grow with every long task opened.
                .onDisappear { rememberScroll(); workspace.trim(conversation.id) }
                // Back where you were: the block that was at the top of the screen, its older page loaded first if
                // it isn't any more. At the end, it opens at the end, as ever.
                .task {
                    guard let kept = ScrollMemory.place(in: conversation.id) else { return }
                    if !conversation.items.contains(where: { $0.id == kept.turn }) { await workspace.loadEarlier(conversation.id, from: kept.turn) }
                    try? await Task.sleep(for: .milliseconds(80))
                    position.scrollTo(id: kept.block, anchor: .top)
                }
                // What you'd written and attached and not sent yet, kept as you go (a branch's message waiting first).
                .onAppear {
                    if let kept = Drafts.load("task:" + conversation.id) { draft = kept.text; images = kept.images }
                    if let waiting = workspace.pendingDrafts.removeValue(forKey: conversation.id) { draft = waiting }
                }
                .onChange(of: draft) { Drafts.save("task:" + conversation.id, text: draft, images: images) }
                .onChange(of: images) { Drafts.save("task:" + conversation.id, text: draft, images: images) }
                .overlay {
                    if let item = rewinding {
                        RewindCard(workspace: workspace, task: conversation.id, item: item, close: { rewinding = nil }) { rewound, conversationToo in
                            // The message back in the box, to send again or change.
                            if conversationToo { draft = rewound.text; images = rewound.images.map { URL(fileURLWithPath: $0) } }
                        } branched: { open($0) }
                    }
                }
            }
        }
    }

    private var composer: some View {
        Composer(draft: $draft, placeholder: placeholder, canSend: conversation.status != .starting, folder: conversation.cwd, workspace: workspace,
                 images: $images) {
            let (text, attached) = (draft, images.map(\.path))
            draft = ""
            images = []
            send(text, images: attached, with: provider ?? conversation.provider)
        } controls: {
            // Another provider for the next message: the task moves there, conversation and all.
            let current = provider ?? conversation.provider
            ComposerChip(id: "task.\(conversation.id).agent", label: current.title, symbol: "terminal", icon: current.mark, prominent: true) {
                ComposerRows.list("Agent", Self.takeOver.map { other in
                    (other.rawValue, other.title, other == conversation.provider ? "Carries on as it is" : "Takes the task over, with its whole conversation",
                     other == current, { provider = other == conversation.provider ? nil : other })
                })
            }
            .disabled(conversation.status == .working || conversation.status == .waiting)
        }
        // A little narrower than the conversation.
        .centredColumn(680)
        .padding(.top, 4).padding(.bottom, 16)
    }

    /// The providers a task can move to: they read Zero's record natively (Claude Code resumes it, Codex imports it).
    static let takeOver: [Provider] = [.claude, .codex]

    private func send(_ text: String, images: [String] = [], with chosen: Provider) {
        Task {
            if chosen != conversation.provider {
                guard await workspace.switchProvider(conversation.id, to: chosen) else { return }
                provider = nil
            }
            await workspace.send(conversation.id, text: text, images: images)
        }
    }

    private func carryOn(with other: Provider) {
        send("You've taken this task over from \(conversation.provider.title), which ran out of usage. Carry on from where it stopped.", with: other)
    }

    /// What's wrong, and what to do about it: the session's attention beyond working or waiting.
    private var health: (text: String, icon: String, color: Color)? {
        switch conversation.attention {
        case .stuck: return (conversation.stalled ?? "Stuck", "triangle-warning", .orange)
        case .limited:
            let reset = (conversation.usage?.resetsAt).map { " Resets \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened))." } ?? ""
            return ("Usage limit reached.\(reset)", "hourglass", .orange)
        case .failed:
            let message = conversation.failure?.message ?? conversation.error ?? "It failed"
            let hint = switch conversation.failure?.kind {
            case .signIn?: " Sign in with \(conversation.provider == .claude ? "claude" : conversation.provider.rawValue) in a terminal."
            case .network?: " Check the network, then send a message to retry."
            case .model?: " Try another model."
            default: ""
            }
            return (message + hint, "triangle-warning", .red)
        default: return nil
        }
    }

    private var placeholder: String {
        switch conversation.status {
        case .offline: "Message to resume it"
        case .working, .waiting: conversation.provider == .opencode ? "OpenCode answers one message at a time" : "Steer it while it works"
        default: "Reply"
        }
    }
}

/// The agent asking: each field's options as buttons (toggles where several may be picked), its own words where it
/// takes them, dots for a secret. Sent once every field has an answer.
private struct QuestionCard: View {
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
                VStack(alignment: .leading, spacing: 8) {
                    if let header = field.header { Text(header.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(field.question).font(.headline)
                    HStack {
                        ForEach(field.options, id: \.label) { option in
                            let on = picked[field.id, default: []].contains(option.label)
                            Button(option.label) {
                                if field.multiple { picked[field.id, default: []].formSymmetricDifference([option.label]) }
                                else { picked[field.id] = on ? [] : [option.label] }
                            }
                            .buttonStyle(.bordered).tint(on ? .accentColor : nil).help(option.description ?? "")
                        }
                    }
                    if field.secret { SecureField("Secret", text: Binding(get: { typed[field.id, default: ""] }, set: { typed[field.id] = $0 })) }
                    else if field.other || field.options.isEmpty {
                        TextField(field.options.isEmpty ? "Your answer" : "Or say something else", text: Binding(get: { typed[field.id, default: ""] }, set: { typed[field.id] = $0 }))
                    }
                }
            }
            Button("Answer") { send(Dictionary(uniqueKeysWithValues: question.fields.map { ($0.id, answer($0)) })) }
                .buttonStyle(.borderedProminent).disabled(question.fields.contains { answer($0).isEmpty })
        }
        .padding(16).background(Theme.orangeRow, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ItemView: View {
    let item: ConversationItem
    let cwd: String

    var body: some View {
        switch item.kind {
        case let .user(text, images):
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    HStack(spacing: 6) { ForEach(images, id: \.self) { Thumbnail(path: $0, side: 120) } }
                }
                if !text.isEmpty {
                    HStack {
                        Spacer(minLength: 80)
                        Text(text).font(.system(size: 14.5)).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case let .agent(text, final):
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text, cwd: cwd)
                if final { CopyButton(text: text) }
            }
        case let .reasoning(text):
            DisclosureGroup { Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) } label: {
                NucleoLabel("Thinking", icon: "brain").font(.callout).foregroundStyle(.secondary)
            }
        case let .plan(text):
            Text(text).font(.system(.callout, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
        case let .command(command, _, output, exitCode, _):
            CommandCard(command: command, output: output, exitCode: exitCode, status: item.status)
        case let .fileChange(changes):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(changes, id: \.path) { change in FileChangeCard(change: change, status: item.status, cwd: cwd) }
            }
        case let .tool(name, detail):
            HStack(spacing: 8) {
                StatusIcon(status: item.status)
                Text(name).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).truncationMode(.middle)
            }
            .font(.callout).lineLimit(1)
        case let .notice(text, error):
            NucleoLabel(text, icon: error ? "triangle-warning" : "circle-info")
                .font(.callout).foregroundStyle(error ? Color.red : .secondary)
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
        .buttonStyle(Hovering(radius: 6)).help("Copy")
    }
}

private struct StatusIcon: View {
    let status: ItemStatus
    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .done: NucleoIcon("circle-check", fill: "glyph", size: 14).foregroundStyle(.green)
        case .failed: NucleoIcon("circle-xmark", fill: "glyph", size: 14).foregroundStyle(.red)
        case .declined: NucleoIcon("ban", size: 14).foregroundStyle(.orange)
        }
    }
}

private struct CommandCard: View {
    let command: String
    let output: String
    let exitCode: Int?
    let status: ItemStatus
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    StatusIcon(status: status)
                    Text("$ " + command).font(.system(.callout, design: .monospaced)).lineLimit(open ? nil : 1)
                    Spacer()
                    if let exitCode, exitCode != 0 { Text("exit \(exitCode)").font(.caption).foregroundStyle(.red) }
                    if !output.isEmpty { NucleoIcon("chevron-down", size: 13).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && !output.isEmpty {
                ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .thinScrollbar()
                    .frame(maxHeight: 280)
            }
        }
        .padding(12).background(Theme.code, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FileChangeCard: View {
    let change: FileChange
    let status: ItemStatus
    let cwd: String
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    StatusIcon(status: status)
                    Text(verb).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(relative(change.path, to: cwd)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    NucleoIcon("chevron-down", size: 13).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && !change.diff.isEmpty { DiffText(diff: change.diff, added: change.kind == "add") }
        }
        .padding(12).card()
    }

    private var verb: String {
        switch change.kind {
        case "add": "ADDED"
        case "delete": "DELETED"
        default: change.movePath == nil ? "EDITED" : "MOVED"
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

/// A diff's lines, additions green and removals red. A new file's contents arrive without markers: all added.
private struct DiffText: View {
    let diff: String
    var added = false

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line)).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(line)).frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: 360)
    }

    private func color(_ line: Substring) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        return .primary
    }

    private func background(_ line: Substring) -> Color {
        if added || (line.hasPrefix("+") && !line.hasPrefix("+++")) { return Theme.greenRow }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Theme.redRow }
        return .clear
    }
}

/// The provider asking before it acts: what it wants, why, and its own choices, the first one the default.
private struct ApprovalCard: View {
    let approval: Approval
    let cwd: String
    let choose: (Choice) -> Void

    /// Claude describes a file approval by the file's name, which the title already says.
    private var reason: String? {
        guard let reason = approval.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty,
              !approval.title.localizedCaseInsensitiveContains(reason) else { return nil }
        return reason
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NucleoLabel(approval.title, icon: "shield", size: 16).font(.headline).foregroundStyle(.orange)
            if let reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            if let command = approval.command {
                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(approval.changes, id: \.path) { change in FileChangeCard(change: change, status: .running, cwd: cwd) }
            HStack {
                ForEach(Array(approval.choices.enumerated()), id: \.element.id) { index, choice in
                    let button = Button(choice.label) { choose(choice) }
                    if index == 0 { button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) } else { button }
                }
            }
        }
        .padding(16).background(Theme.orangeRow, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The message box, as the control bar's: its field ("/" for commands, "@" for the folder's files), the images going
/// with it, and a row of chips with the send button at its end.
private struct Composer<Controls: View>: View {
    @Binding var draft: String
    let placeholder: String
    var canSend = true
    /// Where "@" finds files: the task's folder.
    var folder: String?
    /// Where the + finds scratchpads.
    var workspace: Workspace?
    /// Images going with the message: pasted, dropped, or picked with the +.
    @Binding var images: [URL]
    let send: () -> Void
    @ViewBuilder var controls: Controls
    @State private var focused = false
    /// Whether the text has focus, where the paste handler (AppKit's, outside SwiftUI's updates) can read it.
    @State private var focus = FocusBox()
    @State private var dropping = false
    @State private var monitor: Any?
    @State private var fieldHeight = ComposeField.lineHeight * 2
    /// The "/" or "@" suggestions open over the composer, and where the caret goes after one is taken.
    @State private var mention: InboxController.MentionState?
    @State private var mentionTask: Task<Void, Never>?
    @State private var mentionHeight: CGFloat = 0
    @State private var caret: Int?
    /// The + menu, open on its first page or on the scratchpads; where it and the + are, for a click outside it.
    @State private var adding: AddMenu.Page?
    @State private var addHeight: CGFloat = 0
    @State private var addFrame = CGRect.zero
    @State private var plusFrame = CGRect.zero
    @State private var addMonitor: Any?

    final class FocusBox { var on = false }

    /// The same switches as the control bar's composer (Settings → Inbox).
    private var suggestCommands: Bool { UserDefaults.standard.object(forKey: "suggestCommands") as? Bool ?? true }
    private var suggestFiles: Bool { UserDefaults.standard.object(forKey: "suggestFiles") as? Bool ?? false }

    var body: some View {
        let attached = images
        let ready = canSend && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty)
        VStack(alignment: .leading, spacing: 12) {
            if !attached.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(attached, id: \.self) { url in
                            Thumbnail(path: url.path, remove: { images.removeAll { $0 == url } })
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            ComposeField(text: $draft, placeholder: placeholder, focused: focused, editable: true,
                         caret: caret, onCaretApplied: { caret = nil },
                         onFocus: { focused = $0; focus.on = $0 },
                         onSubmit: { if ready { send() } },
                         onTrigger: suggest, onKey: key, highlightFiles: suggestFiles, height: $fieldHeight)
                .frame(height: fieldHeight)
                .padding(.horizontal, -TokenTextView.inset.width) // the text still starts on the card's 14 pt
            HStack(spacing: 6) {
                Button { adding = adding == nil ? .add : nil } label: {
                    NucleoIcon("plus", size: 15).foregroundStyle(.primary).frame(width: 28, height: 28)
                        .background(adding == nil ? .clear : Theme.row, in: Circle())
                }
                .buttonStyle(Hovering(radius: 14, fill: Theme.row, hover: Theme.row)).help("Add files, folders or a scratchpad")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { plusFrame = $0 }
                HStack(spacing: 6) { controls }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: send) {
                    NucleoIcon("arrow-up", size: 14).foregroundStyle(ready ? Theme.onKnob : .white)
                        .frame(width: 28, height: 28).background(ready ? Theme.knob : Theme.sendIdle, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(!ready)
            }
        }
        .padding(14)
        // The whole card focuses the text, not just its line; the chips and buttons keep their own clicks.
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture {
            focused = false
            DispatchQueue.main.async { focused = true }
        }
        // Codex's card: white on a hairline, lifted by a wide, soft shadow (and a close one that firms its edge), which
        // also falls on the folder tab behind its top.
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(dropping ? Color.accentColor : Theme.fieldEdge, lineWidth: dropping ? 2 : 1))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 5)
        .shadow(color: .black.opacity(0.03), radius: 1.5, y: 1)
        .overlay(alignment: .top) {
            if let mention {
                MentionList(state: mention, pick: accept, hover: { self.mention?.selected = $0 })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mentionHeight = $0 }
                    .offset(y: -mentionHeight - 6)
            }
        }
        // The + menu, as Codex's: the composer's width, just above it.
        .overlay(alignment: .top) {
            if let page = adding {
                AddMenu(page: Binding(get: { page }, set: { adding = $0 }), pads: workspace?.pads ?? [],
                        files: { adding = nil; addFiles() }, pad: { pad in adding = nil; insert("[\(pad.title)](\(pad.link))") })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { addFrame = $0; addHeight = $0.height }
                    .offset(y: -addHeight - 6)
            }
        }
        .onChange(of: adding == nil) { _, closed in closed ? stopWatchingAdd() : watchAdd() }
        .onChange(of: adding) { _, page in if page == .pads { Task { await workspace?.loadPads() } } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            let images = $images
            Attachments.fromDrop(providers) { images.wrappedValue += $0 }
            return true
        }
        // ⌘V with an image on the clipboard attaches it; anything else pastes into the text as usual.
        .onAppear {
            guard monitor == nil else { return }
            let (focus, images) = (focus, $images)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focus.on, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v",
                      let urls = Attachments.fromPasteboard(), !urls.isEmpty else { return event }
                images.wrappedValue += urls
                return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; stopWatchingAdd() }
    }

    // The + menu.

    /// Files and folders from an open panel: images go with the message, anything else into it as its path (from the
    /// task's folder when it's inside it), which the agent reads.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var paths: [String] = []
        for url in panel.urls {
            if Attachments.isImage(url), let copied = Attachments.copy(url) { images.append(copied); continue }
            var path = url.path
            if let folder, path.hasPrefix(folder + "/") { path = String(path.dropFirst(folder.count + 1)) }
            paths.append(path.contains(" ") ? "\"\(path)\"" : "@" + path)
        }
        if !paths.isEmpty { insert(paths.joined(separator: " ")) }
    }

    /// Words added at the end of what's written, and the field focused again.
    private func insert(_ text: String) {
        let gap = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
        draft += gap + text + " "
        focused = false
        DispatchQueue.main.async { focused = true }
    }

    /// While the menu is open: a click outside it (and outside the +, which toggles it) or Esc closes it.
    private func watchAdd() {
        stopWatchingAdd()
        let (menu, plus, close) = ({ addFrame }, { plusFrame }, { adding = nil })
        addMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                close()
                return nil
            }
            guard let content = event.window?.contentView else { return event }
            // SwiftUI's global frames are in the window's content, from its top left.
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if !menu().contains(point) && !plus().contains(point) { close() }
            return event
        }
    }

    private func stopWatchingAdd() {
        if let addMonitor { NSEvent.removeMonitor(addMonitor) }
        addMonitor = nil
    }

    // Suggestions, as the control bar's composer makes them (InboxController.updateMention).

    private func suggest(_ trigger: MentionTrigger?) {
        mentionTask?.cancel()
        guard let trigger, trigger.symbol == "/" ? suggestCommands : suggestFiles else { mention = nil; return }
        if trigger.symbol == "/" {
            let query = trigger.query.lowercased()
            let all = ClaudeCommands.all(projectPath: folder)
            let name = { (m: Mention) in m.insert.dropFirst().lowercased() }
            show(trigger, Array((all.filter { name($0).hasPrefix(query) } + all.filter { !name($0).hasPrefix(query) && name($0).contains(query) }).prefix(8)))
        } else {
            guard let folder else { mention = nil; return }
            mentionTask = Task {
                let files = await ProjectFiles.list(folder)
                guard !Task.isCancelled else { return }
                show(trigger, ProjectFiles.match(trigger.query, in: files).map { Mention(kind: .file, insert: "@" + $0, detail: nil) })
            }
        }
    }

    private func show(_ trigger: MentionTrigger, _ items: [Mention]) {
        guard !items.isEmpty else { mention = nil; return }
        let sameWord = mention?.trigger.range.location == trigger.range.location
        mention = .init(key: "", trigger: trigger, items: items, selected: sameWord ? min(mention?.selected ?? 0, items.count - 1) : 0)
    }

    /// Arrows move, Tab or Return takes the highlighted suggestion, Esc closes the list.
    private func key(_ key: ComposeKey) -> Bool {
        guard var state = mention else { return false }
        switch key {
        case .up: state.selected = max(0, state.selected - 1); mention = state
        case .down: state.selected = min(state.items.count - 1, state.selected + 1); mention = state
        case .accept: accept(state.selected)
        case .dismiss: mention = nil
        }
        return true
    }

    /// The whole word under the caret replaced by the suggestion, a space after it unless one follows already.
    private func accept(_ index: Int) {
        guard let state = mention, state.items.indices.contains(index) else { return }
        let text = draft as NSString
        let word = state.trigger.word
        guard NSMaxRange(word) <= text.length else { mention = nil; return }
        let spaced = NSMaxRange(word) < text.length && text.substring(with: NSRange(location: NSMaxRange(word), length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let insert = state.items[index].insert + (spaced ? "" : " ")
        draft = text.replacingCharacters(in: word, with: insert)
        caret = word.location + (insert as NSString).length + (spaced ? 1 : 0)
        mention = nil
    }
}

extension Composer where Controls == EmptyView {
    init(draft: Binding<String>, placeholder: String, canSend: Bool = true, folder: String? = nil, workspace: Workspace? = nil, images: Binding<[URL]>,
         send: @escaping () -> Void) {
        self.init(draft: draft, placeholder: placeholder, canSend: canSend, folder: folder, workspace: workspace, images: images, send: send) { EmptyView() }
    }
}

/// Going back to a message of yours, as Claude Code's rewind has it: the conversation, the folder's code, or both,
/// as they were when the message went; or a new task branched from there. What the code would lose is said first.
private struct RewindCard: View {
    let workspace: Workspace
    let task: String
    let item: ConversationItem
    let close: () -> Void
    let rewound: (Rewound, Bool) -> Void
    let branched: (String) -> Void
    @State private var preview: RewindPreview?
    @State private var busy = false
    @State private var hovered: String?

    private var text: String { if case let .user(text, _) = item.kind { text } else { "" } }
    private var kept: Bool { preview?.snapshot == true }

    var body: some View {
        ZStack {
            // Outside the card: never mind.
            Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 4) {
                Text("Rewind").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.top, 6)
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 10)
                Text(folder).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 6)
                row("both", "Restore conversation and code", "Back to before this message, files and all", enabled: kept) { go(conversation: true, code: true) }
                row("conversation", "Restore conversation", "The files stay as they are now") { go(conversation: true, code: false) }
                row("code", "Restore code", "The conversation carries on as it is", enabled: kept) { go(conversation: false, code: true) }
                row("branch", "Branch from here", "A new task from before this message; this one stays") { branch() }
                Button("Never mind", action: close).keyboardShortcut(.cancelAction).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
            }
            .padding(8)
            .frame(width: 440, alignment: .leading)
            .card()
            .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
            .disabled(busy)
        }
        .task { preview = await workspace.rewindPreview(task, message: item.id) }
    }

    /// What restoring the code would undo, or why it can't.
    private var folder: String {
        guard let preview else { return "Looking at the folder…" }
        guard preview.snapshot else { return "Zero didn't keep the folder for this message, so only the conversation can go back." }
        let files = preview.files ?? 0
        if files == 0 { return "The folder hasn't changed since this message." }
        return "Since this message: \(files) file\(files == 1 ? "" : "s") changed, +\(preview.insertions ?? 0) −\(preview.deletions ?? 0)."
    }

    private func go(conversation: Bool, code: Bool) {
        busy = true
        Task {
            if let back = await workspace.rewind(task, message: item.id, conversation: conversation, code: code) { rewound(back, conversation) }
            busy = false
            close()
        }
    }

    private func branch() {
        busy = true
        Task {
            let made = await workspace.branch(task, message: item.id)
            busy = false
            close()
            if let id = made?.session { branched(id) }
        }
    }

    private func row(_ id: String, _ title: String, _ detail: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered == id && enabled ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { inside in if inside { hovered = id } else if hovered == id { hovered = nil } }
    }
}

/// The composer's + menu, as Codex's: what can go with a message, each with a line about it; a scratchpad opens a
/// list of them to find one in.
private struct AddMenu: View {
    enum Page { case add, pads }
    @Binding var page: Page
    let pads: [PadSummary]
    let files: () -> Void
    let pad: (PadSummary) -> Void
    @State private var query = ""
    @State private var hovered: String?
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch page {
            case .add:
                Text("Add").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
                row("files", icon: "file", title: "Files and folders", detail: "Images go with it, anything else as its path", action: files)
                row("pads", icon: "note-3", title: "Scratchpad", detail: "Point the agent at one of your pads") { page = .pads }
            case .pads:
                HStack(spacing: 8) {
                    Button { page = .add } label: {
                        NucleoIcon("arrow-left", size: 13).foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Back")
                    TextField("Find a scratchpad", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                        .onSubmit { if let first = found.first { pad(first) } }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(found) { summary in
                            row(summary.id, icon: "note-3", title: summary.title, detail: summary.folder.isEmpty ? nil : summary.folder) { pad(summary) }
                        }
                        if found.isEmpty {
                            Text(pads.isEmpty ? "Loading…" : "No scratchpad matches").font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 10).frame(height: 32)
                        }
                    }
                }
                .thinScrollbar()
                .scrollIndicators(.never)
                .frame(height: 8 * 33)
                .onAppear { searching = true }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Most recently changed first; matched on title and folder.
    private var found: [PadSummary] {
        let words = query.lowercased().split(separator: " ")
        return pads.filter { pad in words.allSatisfy { (pad.title + " " + pad.folder).lowercased().contains($0) } }.sorted { $0.updated > $1.updated }
    }

    private func row(_ id: String, icon: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                NucleoIcon(icon, size: 15).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(hovered == id ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hovered = id } else if hovered == id { hovered = nil } }
    }
}

/// The selector open from a workspace composer's chip, the control bar's own: one at a time, over the window the
/// chip is in, and a second click on its chip closes it.
@MainActor @Observable
final class WorkspaceSelector {
    static let shared = WorkspaceSelector()
    /// The chip whose selector is open.
    private(set) var open: String?
    @ObservationIgnored private var closed: (chip: String, at: Date)?

    func toggle(_ chip: String, kind: SelectorKind, anchor: CGRect, rows: @escaping () -> [SelectorSection],
                level: @escaping (String) -> String? = { _ in nil }, setLevel: @escaping (String, String) -> Void = { _, _ in }) {
        if open == chip { close(); return }
        // The click that closed it through the click-outside monitor arrives here next: it was that close.
        if let closed, closed.chip == chip, Date().timeIntervalSince(closed.at) < 0.3 { return }
        guard let window = NSApp.keyWindow, let app = NSApp.delegate as? AppDelegate else { return }
        let state = SelectorState(kind: kind)
        state.sections = rows()
        state.rebuild = rows
        state.level = level
        state.setLevel = setLevel
        state.close = { [weak self] in self?.close() }
        open = chip
        app.presentSelector(state, chip: anchor, in: window, returning: window)
    }

    func close() {
        guard let open else { return }
        closed = (open, Date())
        self.open = nil
        (NSApp.delegate as? AppDelegate)?.hideSelector()
    }
}

/// A chip in the composer's row, the control bar's: an icon, what's chosen, and a chevron, on a small pill; it opens
/// Zero's selector, and reads pressed while that's open.
private struct ComposerChip: View {
    let id: String
    let label: String
    var symbol: String?
    /// A picture of its own (a provider's mark), before a Nucleo symbol.
    var icon: Image?
    var kind = SelectorKind.project
    /// What's chosen in full colour (the model), as Codex shows it; the rest in grey.
    var prominent = false
    let rows: () -> [SelectorSection]
    var level: (String) -> String? = { _ in nil }
    var setLevel: (String, String) -> Void = { _, _ in }
    @State private var anchor = CGRect.zero
    @State private var hovered = false

    var body: some View {
        let open = WorkspaceSelector.shared.open == id
        Button {
            WorkspaceSelector.shared.toggle(id, kind: kind, anchor: anchor, rows: rows, level: level, setLevel: setLevel)
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    icon.resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
                } else if let symbol {
                    NucleoIcon(symbol, size: 13).foregroundStyle(.secondary)
                }
                Text(label).font(.system(size: 13)).foregroundStyle(prominent ? .primary : .secondary).lineLimit(1)
                NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            // Plain words, as Codex's controls are; a soft fill under the pointer, and while its selector is open.
            .background(open || hovered ? Theme.row : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovered = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
    }
}

/// The selector's rows for what a workspace composer chooses.
@MainActor enum ComposerRows {
    /// Each provider's models from its own catalogue, as the control bar's model selector has them; a provider
    /// without one is a single row. `selected` says which (provider, model id) is chosen; `pick` takes one.
    static func models(_ providers: [Provider], selected: (Provider, String) -> Bool, pick: @escaping (Provider, SpawnChoice) -> Void) -> [SelectorSection] {
        providers.map { provider in
            let catalogue = catalogue(provider)
            let rows = catalogue.isEmpty
                ? [SelectorRow(id: provider.rawValue, title: provider.title, provider: nil, providerIcon: provider.mark, detail: nil, context: nil,
                               levels: [], defaultLevel: nil, modelID: nil, selected: selected(provider, "")) { pick(provider, SpawnChoice(id: "", name: provider.title)) }]
                : catalogue.map { model in
                    SelectorRow(id: provider.rawValue + "/" + model.id, title: model.name, provider: model.provider, providerIcon: choiceIcon(model.icon) ?? provider.mark,
                                detail: model.detail, context: model.context, levels: model.levels, defaultLevel: model.defaultLevel,
                                modelID: provider.rawValue + "/" + model.id, selected: selected(provider, model.id)) { pick(provider, model) }
                }
            return SelectorSection(id: provider.rawValue, title: provider.title, icon: provider.mark, rows: rows)
        }
    }

    /// The models a provider's CLI offers the signed-in account, from its own cache.
    static func catalogue(_ provider: Provider) -> [SpawnChoice] {
        switch provider {
        case .claude: SoloAdapter().spawnModels(for: SpawnChoice(id: "claude", name: "Claude"))
        case .codex: SoloAdapter().spawnModels(for: SpawnChoice(id: "codex", name: "Codex"))
        case .opencode: []
        }
    }

    /// A single list: title, the line under it, whether it's chosen, and what picking it does.
    static func list(_ title: String, icon: Image? = nil, _ rows: [(id: String, title: String, detail: String?, selected: Bool, pick: () -> Void)]) -> [SelectorSection] {
        [SelectorSection(id: title, title: title, icon: icon, rows: rows.map { row in
            SelectorRow(id: row.id, title: row.title, provider: nil, providerIcon: nil, detail: row.detail, context: nil, levels: [],
                        defaultLevel: nil, modelID: nil, selected: row.selected, pick: row.pick)
        })]
    }
}

extension Provider {
    /// Its mark, as the control bar's chips show it.
    @MainActor var mark: Image? {
        switch self {
        case .claude: choiceIcon("claude")
        case .codex: choiceIcon("openai")
        case .opencode: nil
        }
    }
}

// A new task: its lead session. Home, as ChatGPT's: a greeting in the middle, the composer at the foot with the
// project above it and the agent, model, effort and permissions in its row.

private struct NewTaskView: View {
    let workspace: Workspace
    let started: (String) -> Void
    @AppStorage("workspaceProvider") private var provider = Provider.codex.rawValue
    @AppStorage("workspaceProject") private var project = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var permissions = Permissions.auto
    @State private var prompt = ""
    @State private var images: [URL] = []
    @State private var starting = false

    private var chosen: Provider { Provider(rawValue: provider) ?? .codex }
    private var folders: [String] { Projects.folders }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                ZeroMark(small: true).frame(width: 34, height: 33).foregroundStyle(.secondary)
                Text("What should we work on?").font(.system(size: 26))
            }
            Spacer()
            VStack(spacing: 0) {
                projectTab
                Composer(draft: $prompt, placeholder: "Do anything", canSend: !starting && folders.contains(project), folder: folders.contains(project) ? project : nil,
                         workspace: workspace, images: $images) { start() } controls: {
                    ComposerChip(id: "new.permissions", label: permissions == .auto ? "Auto" : "Unrestricted",
                                 symbol: permissions == .auto ? "wand-sparkle" : "bolt-lightning") {
                        ComposerRows.list("Permissions", [
                            ("auto", "Auto", "\(chosen.title) decides what's safe, and asks you the rest", permissions == .auto, { permissions = .auto }),
                            ("unrestricted", "Unrestricted", "Anything, without asking", permissions == .unrestricted, { permissions = .unrestricted }),
                        ])
                    }
                    Spacer(minLength: 0)
                    ComposerChip(id: "new.agent", label: agentLabel, symbol: "terminal", icon: chosen.mark, kind: .runtime, prominent: true, rows: {
                        ComposerRows.models(Provider.allCases, selected: { provider, id in
                            provider == chosen && (id == model || (model.isEmpty && id == (ComposerRows.catalogue(provider).first?.id ?? "")))
                        }, pick: { picked, choice in
                            provider = picked.rawValue
                            model = choice.id
                            if !choice.levels.contains(where: { $0.id == effort }) { effort = "" }
                        })
                    }, level: { id in id == "\(chosen.rawValue)/\(model)" && !effort.isEmpty ? effort : nil }, setLevel: { _, level in effort = level })
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 36).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if !folders.contains(project) { project = folders.first ?? "" }
            if let kept = Drafts.load("new") { prompt = kept.text; images = kept.images }
        }
        .onChange(of: prompt) { Drafts.save("new", text: prompt, images: images) }
        .onChange(of: images) { Drafts.save("new", text: prompt, images: images) }
    }

    /// The folder it starts in, as a tab behind the composer's top edge.
    @ViewBuilder private var projectTab: some View {
        HStack {
            if folders.isEmpty {
                NucleoLabel("Add a project in Settings → Projects", icon: "folder", size: 13).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
            } else {
                ComposerChip(id: "new.project", label: folders.contains(project) ? (project as NSString).lastPathComponent : "Choose project", symbol: "folder") {
                    ComposerRows.list("Projects", icon: choiceIcon("zero"), folders.map { folder in
                        (folder, (folder as NSString).lastPathComponent, (folder as NSString).abbreviatingWithTildeInPath, folder == project, { project = folder })
                    })
                }
            }
            Spacer()
        }
        .font(.system(size: 12))
        // Codex's tab: flat grey, no edge, a little in from the card's sides; the card's shadow gives it depth.
        .padding(.horizontal, 7).padding(.top, 8).padding(.bottom, 16)
        .background(Theme.fieldTab, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous))
        .padding(.horizontal, 13).padding(.bottom, -12)
    }

    /// "Claude · Opus · High".
    private var agentLabel: String {
        [chosen.title, models.first { $0.id == model }?.name ?? (model.isEmpty ? nil : model), effort.isEmpty ? nil : effortLabel(effort, short: true)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The chosen provider's models, from its CLI's own cache.
    private var models: [SpawnChoice] { ComposerRows.catalogue(chosen) }

    private func start() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = images.map(\.path)
        guard !text.isEmpty || !attached.isEmpty, !starting else { return }
        starting = true
        Task {
            if let id = await workspace.start(provider: chosen, cwd: project, prompt: text, images: attached, model: model.isEmpty ? nil : model,
                                              effort: effort.isEmpty ? nil : effort, permissions: permissions) {
                prompt = ""
                images = []
                started(id)
            }
            starting = false
        }
    }
}

/// The system's blur of what's behind the window (a sidebar's material), solid when the window isn't the active one.
struct BehindWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

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
        controller.store.asks.filter { $0.kind != .note && $0.kind != .message && $0.state != .expired && $0.sameAs == nil }
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
                    // Open, the row and the control bar's card (flat, to answer it here) are one lifted surface.
                    VStack(spacing: 0) {
                        Button { picked = open == ask.id ? "" : ask.id } label: {
                            line(head: false,
                                 ask: Text(ask.title).foregroundStyle(.primary).lineLimit(2).help(ask.title),
                                 agent: Text(controller.store.displayName(of: ask.agent.name)).foregroundStyle(.secondary).lineLimit(1),
                                 kind: Text(Self.kind(ask)).foregroundStyle(.secondary),
                                 since: since(ask))
                        }
                        .buttonStyle(Hovering(radius: 0, fill: .clear, hover: open == ask.id ? .clear : Theme.rowHover))
                        if open == ask.id {
                            CardView(ask: ask, controller: controller, focus: $focus, flat: true).padding(.top, -10)
                        }
                    }
                    .background(open == ask.id ? Theme.rowHover : .clear)
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

/// An agent Zero doesn't run (Solo's, Rex's, Claude Code in a terminal), opened from the docked bar: its conversation
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
