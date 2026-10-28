import AppKit
import SwiftUI
import ZeroCore

/// The workspace window, laid out as ChatGPT's: an outer rail (home, settings) on the window's grey, and a panel
/// holding an inner sidebar and the page. Home's sidebar is the tasks (a lead session with its workers); its page a new
/// task, every task at once, or one. Everything comes from `Workspace`; nothing here knows a provider's protocol.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @Bindable var navigation: Navigation
    let settings: () -> SettingsView

    var body: some View {
        ZStack {
            window.opacity(navigation.ready ? 1 : 0)
            if !navigation.ready { ZeroMark().frame(width: 64, height: 64).foregroundStyle(.secondary).transition(.opacity) }
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Theme.rail)
        .ignoresSafeArea()
        // The board is polled, so the sidebar stays fresh while the window is open.
        // ponytail: polls; a board feed from zerod when two seconds is too slow.
        .task {
            let deadline = ContinuousClock.now + .seconds(3)
            while !workspace.connected, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            await workspace.loadIntegrations()
            await workspace.refreshBoard()
            show()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await workspace.refreshBoard()
            }
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
            Rail(place: $navigation.place, workspace: workspace)
            Group {
                switch navigation.place {
                case .settings: settings()
                case .integrations: IntegrationsPane(workspace: workspace)
                case .pads, .pad: ScratchpadsPage(workspace: workspace, navigation: navigation)
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
        case .task(let id) where workspace.conversation(id) != nil: TaskView(workspace: workspace, lead: id, navigation: navigation).id(id)
        default: NewTaskView(workspace: workspace, started: { navigation.place = .task($0) })
        }
    }
}

/// Where the page starts across the window: the rail, then the inner sidebar and its edge.
let pageStart: CGFloat = 48 + 250 + 1

/// The outer rail: home at the top, then each integration that's switched on, in the order you put them (⌘-drag one,
/// or right-click it); integrations and settings at the foot.
private struct Rail: View {
    @Binding var place: Navigation.Place
    let workspace: Workspace
    @AppStorage("railOrder") private var order = "github,linear"
    @State private var dragging: Integration?
    @State private var dragged: CGFloat = 0
    @State private var command = NSEvent.modifierFlags.contains(.command)
    @State private var monitor: Any?
    /// One rail item and the gap after it.
    private static let step: CGFloat = 38

    private var home: Bool {
        switch place { case .settings, .integrations, .integration, .pads, .pad: false; default: true }
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

    /// Leads that aren't on the board: finished and gone offline with nothing for him.
    private var earlier: [Conversation] {
        let all = workspace.conversations
        return all.filter { lead in (lead.parent == nil || !all.contains { $0.id == lead.parent }) && !workspace.board.contains { $0.session == lead.id } }.reversed()
    }

    var body: some View {
        SidebarColumn(title: "Zero") {
            SidebarItem("New task", icon: "compose", selected: place == .home) { place = .home }
                .keyboardShortcut("n", modifiers: .command)
            SidebarItem("All tasks", icon: "list-checkbox", selected: place == .board) { place = .board }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SidebarHeading(text: "Tasks")
                    if workspace.board.isEmpty {
                        Text("No tasks").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 10)
                    }
                    let folded = Set(folded.split(separator: "\n").map(String.init))
                    ForEach(workspace.board) { row in
                        let workers = workspace.conversations.filter { $0.parent == row.session }
                        let open = !folded.contains(row.session)
                        TaskRow(title: row.task, state: row.state, selected: place == .task(row.session) && navigation.worker == nil,
                                fold: workers.isEmpty ? nil : open, action: { place = .task(row.session) }, toggle: { toggle(row.session) })
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
                    if !earlier.isEmpty {
                        SidebarHeading(text: "Earlier")
                        ForEach(earlier) { lead in
                            SidebarItem(Workspace.label(of: lead), selected: place == .task(lead.id)) { place = .task(lead.id) }
                                .contextMenu { archive(lead.id) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            footer
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
        VStack(alignment: .leading, spacing: 4) {
            if !workspace.connected {
                NucleoLabel("Connecting to Zero's daemon…", icon: "plug-off", size: 12)
            }
            // What each provider last said about its limits.
            ForEach(workspace.usage.filter { !$0.1.windows.isEmpty }, id: \.0) { provider, usage in
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

    var body: some View {
        let team = team
        let conversation = workspace.conversation(navigation.worker ?? lead)
        let row = workspace.board.first { $0.session == lead }
        if let conversation, conversation.terminal != nil {
            // A terminal runs edge to edge; the pane sits beside it as a column of its own.
            HStack(spacing: 0) {
                ConversationView(workspace: workspace, conversation: conversation).id(conversation.id)
                if navigation.pane {
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                    TaskDetails(workspace: workspace, navigation: navigation, row: row, conversation: conversation, team: team, lead: lead, shown: $navigation.worker, docked: true)
                }
            }
        } else {
            ZStack(alignment: .topTrailing) {
                if let conversation { ConversationView(workspace: workspace, conversation: conversation).id(conversation.id) }
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
    /// How far in from the bar's own edge the page starts.
    let inset: CGFloat

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
            } else {
                drag
            }
        }
        .padding(.leading, max(0, inset)).padding(.trailing, 4)
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
        VStack(alignment: .leading, spacing: 16) {
            if let row {
                section("Status") {
                    HStack(spacing: 6) { StateLabel(state: row.state) }
                    if let needs = row.asks.first?.title ?? row.needs {
                        Text(needs).foregroundStyle(row.asks.isEmpty ? Color.primary : .orange)
                    }
                }
            }
            section("Agent") {
                Text([conversation.provider.title, conversation.model, conversation.effort].compactMap { $0 }.joined(separator: " · "))
                if conversation.permissions == .unrestricted { Text("Unrestricted").foregroundStyle(.orange) }
                if let usage { Text(usage).foregroundStyle(.secondary) }
            }
            section("Folder") {
                Text((conversation.cwd as NSString).abbreviatingWithTildeInPath).truncationMode(.middle)
                if let branch = conversation.branch { NucleoLabel(branch, icon: "code-branch", size: 12).foregroundStyle(.secondary) }
            }
            if let ticket = conversation.ticket {
                section("Ticket") { Text(ticket) }
                TaskPads(workspace: workspace, ticket: ticket) { navigation.place = .pad($0) }
            }
            if team.count > 1 {
                section("Workers") {
                    ForEach(team) { member in
                        SidebarItem(member.id == lead ? "Lead" : Workspace.label(of: member), selected: (shown ?? lead) == member.id) { shown = member.id }
                            .padding(.horizontal, -10)
                    }
                }
            }
        }
        .font(.system(size: 12)).lineLimit(2)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .medium))
            content().foregroundStyle(.secondary)
        }
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
        VStack(alignment: .leading, spacing: 5) {
            if !pads.isEmpty {
                HStack {
                    Text("State").font(.system(size: 13, weight: .medium))
                    Spacer()
                    if let state { Button("Copy link") { PadLinks.copy(state.link, title: "\(ticket) state", markdown: true) }.buttonStyle(.link).font(.system(size: 11.5)) }
                }
                if let state {
                    Button { open(state.id) } label: {
                        Text(Self.gist(state.content)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(Theme.composer, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).help("Open the task's state")
                }
                ForEach(pads.filter { $0.id != state?.id }) { pad in
                    SidebarItem(pad.title, icon: "file-content") { open(pad.id) }.padding(.horizontal, -10)
                }
            }
        }
        .task(id: ticket) {
            while !Task.isCancelled {
                pads = await workspace.taskPads(ticket)
                if let found = pads.first(where: { $0.title == "State" }) { state = await workspace.readPad(found.id) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The pad without its title line and blank lines, so the preview starts with what's in it.
    static func gist(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("# ") }.joined(separator: "\n")
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
                PageTitle(text: "All tasks")
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
                             now: Text(row.now ?? "").lineLimit(3).help(row.now ?? ""),
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

    /// A worker's state in the sidebar's terms.
    static func state(of worker: Conversation) -> BoardRow.State {
        switch worker.attention {
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
    let conversation: Conversation
    @State private var draft = ""
    /// Another provider picked for the next message; nil keeps the task's own.
    @State private var provider: Provider?

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // A step waiting on an approval shows once, in the approval.
                        ForEach(conversation.items.filter { item in !conversation.approvals.contains { $0.item == item.id } }) { item in
                            ItemView(item: item, cwd: conversation.cwd).id(item.id)
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
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.vertical, 20)
                    .centredColumn(760)
                }
                .onChange(of: conversation.seq) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Composer(draft: $draft, placeholder: placeholder, canSend: conversation.status != .starting) {
                let text = draft
                draft = ""
                send(text, with: provider ?? conversation.provider)
            } controls: {
                // Another provider for the next message: the task moves there, conversation and all.
                ComposerMenu(label: (provider ?? conversation.provider).title) {
                    Picker("Agent", selection: Binding(get: { provider ?? conversation.provider }, set: { provider = $0 == conversation.provider ? nil : $0 })) {
                        ForEach(Provider.allCases, id: \.rawValue) { Text($0.title).tag($0).disabled(!Self.takeOver.contains($0)) }
                    }
                    .pickerStyle(.inline)
                }
                .disabled(conversation.status == .working || conversation.status == .waiting)
            }
            .centredColumn(760).padding(.bottom, 16)
        }
    }

    /// The providers a task can move to: they read Zero's record natively (Claude Code resumes it, Codex imports it).
    static let takeOver: [Provider] = [.claude, .codex]

    private func send(_ text: String, with chosen: Provider) {
        Task {
            if chosen != conversation.provider {
                guard await workspace.switchProvider(conversation.id, to: chosen) else { return }
                provider = nil
            }
            await workspace.send(conversation.id, text: text)
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

private struct ItemView: View {
    let item: ConversationItem
    let cwd: String

    var body: some View {
        switch item.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 80)
                Text(text).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16))
            }
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
private struct CopyButton: View {
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

/// The message box, as ChatGPT's: a white card with a soft edge, the field over a row of controls and the send button.
private struct Composer<Controls: View>: View {
    @Binding var draft: String
    let placeholder: String
    var canSend = true
    let send: () -> Void
    @ViewBuilder var controls: Controls

    var body: some View {
        let ready = canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical).textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...10)
                .onSubmit { if ready { send() } }
            HStack(spacing: 6) {
                HStack(spacing: 6) { controls }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: send) {
                    NucleoIcon("arrow-up", size: 13).foregroundStyle(Theme.onKnob)
                        .frame(width: 26, height: 26).background(Theme.knob.opacity(ready ? 1 : 0.25), in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(!ready)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

extension Composer where Controls == EmptyView {
    init(draft: Binding<String>, placeholder: String, canSend: Bool = true, send: @escaping () -> Void) {
        self.init(draft: draft, placeholder: placeholder, canSend: canSend, send: send) { EmptyView() }
    }
}

/// A small control in the composer's row: a menu that reads as a word or two, ChatGPT's "Ask for approval".
private struct ComposerMenu<Items: View>: View {
    let label: String
    var symbol: String?
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            HStack(spacing: 4) {
                if let symbol { NucleoIcon(symbol, size: 13) }
                Text(label)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
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
                Composer(draft: $prompt, placeholder: "Do anything", canSend: !starting && folders.contains(project)) { start() } controls: {
                    ComposerMenu(label: permissions == .auto ? "Auto" : "Unrestricted", symbol: permissions == .auto ? "wand-sparkle" : "bolt-lightning") {
                        Picker("Permissions", selection: $permissions) {
                            Text("Auto: \(chosen.title) decides what's safe, and asks you the rest").tag(Permissions.auto)
                            Text("Unrestricted: anything, without asking").tag(Permissions.unrestricted)
                        }
                        .pickerStyle(.inline)
                    }
                    Spacer(minLength: 0)
                    ComposerMenu(label: agentLabel) {
                        Picker("Agent", selection: $provider) {
                            ForEach(Provider.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.inline)
                        if !models.isEmpty {
                            Picker("Model", selection: $model) {
                                Text("Default").tag("")
                                ForEach(models, id: \.id) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.inline)
                        }
                        if !levels.isEmpty {
                            Picker("Effort", selection: $effort) {
                                Text("Default").tag("")
                                ForEach(levels, id: \.self) { Text($0.capitalized).tag($0) }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 36).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: provider) { model = ""; effort = "" }
        .onAppear { if !folders.contains(project) { project = folders.first ?? "" } }
    }

    /// The folder it starts in, as a tab behind the composer's top edge.
    @ViewBuilder private var projectTab: some View {
        HStack {
            if folders.isEmpty {
                NucleoLabel("Add a project in Settings → Projects", icon: "folder", size: 13).foregroundStyle(.secondary)
            } else {
                ComposerMenu(label: folders.contains(project) ? (project as NSString).lastPathComponent : "Choose project", symbol: "folder") {
                    Picker("Project", selection: $project) {
                        ForEach(folders, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 16)
        .background(Theme.composer, in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12).strokeBorder(Theme.stroke))
        .padding(.horizontal, 10).padding(.bottom, -10)
    }

    /// "Claude · Opus · High".
    private var agentLabel: String {
        [chosen.title, models.first { $0.id == model }?.name ?? (model.isEmpty ? nil : model), effort.isEmpty ? nil : effort.capitalized]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Codex's own catalogue for its account, from its cache; the aliases Claude Code takes; OpenCode's models are
    /// per session, so typed. Nothing here asks a provider's service with Arsen's credentials.
    private var models: [SpawnChoice] {
        switch chosen {
        case .codex: SoloAdapter().spawnModels(for: SpawnChoice(id: "codex", name: "Codex"))
        case .claude: ["fable", "opus", "sonnet", "haiku"].map { SpawnChoice(id: $0, name: $0.capitalized) }
        case .opencode: []
        }
    }

    private var levels: [String] {
        switch chosen {
        case .codex: (models.first { $0.id == model } ?? models.first)?.levels.map(\.id) ?? []
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        case .opencode: []
        }
    }

    private func start() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !starting else { return }
        starting = true
        Task {
            if let id = await workspace.start(provider: chosen, cwd: project, prompt: text, model: model.isEmpty ? nil : model,
                                              effort: effort.isEmpty ? nil : effort, permissions: permissions) {
                prompt = ""
                started(id)
            }
            starting = false
        }
    }
}
