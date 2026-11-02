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
        // Loops named in messages read as pills: the names, for the renderer.
        .task { await workspace.loadLoops() }
        .task { await workspace.loadLater() }
        .onChange(of: workspace.loops.map(\.name), initial: true) { _, names in LoopNames.known = names }
        // The rail and the strip above the panel: translucent grey over what's behind the window, blurred, as Codex's.
        .background { ZStack { BehindWindow(); Theme.railTint } }
        .ignoresSafeArea()
        // Behind the mark, everything the first screen needs: zerod and the inbox connected, the rail's integrations,
        // the sidebar's tasks, loop names for the pills, and the page the window opens on with its words already
        // styled, so nothing loads or reflows once the window shows.
        .task {
            let deadline = ContinuousClock.now + .seconds(4.5)
            func until(_ done: @autoclosure () -> Bool) async {
                while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            }
            await until(workspace.connected)
            await workspace.loadIntegrations()
            await workspace.refreshBoard()
            await workspace.loadLoops()
            await until(inbox.store.connected)
            if case .task(let lead) = navigation.place {
                let id = navigation.worker ?? lead
                await until(workspace.conversation(id) != nil)
                await workspace.outline(id)
                if let live = workspace.live(id) { await MarkdownText.warm(live.conversation) }
            }
            show()
            // Then every other lead, behind the window: its rail and its styled words, so the first switch to it is as
            // quick as the next.
            for row in workspace.board.prefix(5) {
                await workspace.outline(row.session)
                if let live = workspace.live(row.session) { await MarkdownText.warm(live.conversation) }
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
            Rail(place: $navigation.place, homePlace: navigation.homePlace, workspace: workspace, inbox: inbox)
            Group {
                switch navigation.place {
                case .settings: settings()
                case .integrations: IntegrationsPane(workspace: workspace)
                case .pads, .pad: ScratchpadsPage(workspace: workspace, navigation: navigation)
                case .loops, .loop: LoopsPage(workspace: workspace, navigation: navigation)
                case .later, .laterItem: LaterPage(workspace: workspace, navigation: navigation)
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
                    .coordinateSpace(.named("tasks"))
                    // A task's details, beside the sidebar where the pointer rests on its row: over the page, since the
                    // sidebar clips what it scrolls.
                    .overlay(alignment: .topLeading) { TaskPeekCard(workspace: workspace, open: { navigation.place = .task($0); navigation.worker = $1 }) }
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
        case .task(let id) where workspace.conversation(id) != nil: TaskPages(workspace: workspace, inbox: inbox, navigation: navigation, current: id)
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
    /// Where Home was last (a task, say): what its icon goes back to.
    var homePlace: Navigation.Place = .home
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
        switch place { case .inbox, .settings, .integrations, .integration, .pads, .pad, .loops, .loop, .later, .laterItem: false; default: true }
    }

    /// Every integration in your order, those never placed after.
    private var ranked: [Integration] {
        let placed = order.split(separator: ",").compactMap { Integration(rawValue: String($0)) }
        return placed + Integration.allCases.filter { !placed.contains($0) }
    }

    private var shown: [Integration] { ranked.filter { $0.enabled(in: workspace.integrations) } }

    var body: some View {
        VStack(spacing: 6) {
            item("house-4", selected: home, help: "Home") { if !home { place = homePlace } }
            // What agents are waiting on you for, and how many.
            item("inbox", selected: place == .inbox, help: "Inbox") { place = .inbox }
                .overlay(alignment: .topTrailing) {
                    let waiting = AsksPage.waiting(inbox).count
                    if waiting > 0 {
                        Text("\(waiting)").font(.system(size: 9.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Color.red, in: Capsule())
                            .padding(1.5).background(Theme.composer, in: Capsule()) // a ring in the rail's colour, as the Dock cuts its badges out
                            .offset(x: 4.5, y: -3.5).allowsHitTesting(false)
                    }
                }
            let later = { if case .laterItem = place { true } else { place == .later } }()
            item("bookmark", selected: later, help: "Later") { if !later { place = .later } }
            let pads = { if case .pad = place { true } else { place == .pads } }()
            item("note-3", selected: pads, help: "Scratchpads") { if !pads { place = .pads } }
            let loops = { if case .loop = place { true } else { place == .loops } }()
            item("animation-repeat", selected: loops, help: "Loops") { if !loops { place = .loops } }
            let shown = shown
            ForEach(Array(shown.enumerated()), id: \.element) { index, integration in
                let selected = place == .integration(integration.rawValue)
                Button { place = .integration(integration.rawValue) } label: {
                    integration.icon(size: 17).foregroundStyle(selected ? .primary : .secondary).frame(width: 32, height: 32)
                }
                .buttonStyle(Hovering(selected: selected, fill: Theme.railSelected, hover: Theme.railHover)).tip(integration.title)
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
            item("gear", selected: place == .settings, help: "Settings", shortcut: "⌘,") { place = .settings }
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

    private func item(_ symbol: String, selected: Bool, help: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIcon(symbol, fill: selected ? "glyph" : "outline", size: 17)
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(Hovering(selected: selected, fill: Theme.railSelected, hover: Theme.railHover)).tip(help, shortcut: shortcut)
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
    /// Where each lead's row starts down the window's task area: where its hover card goes.
    @State private var tops: [String: CGFloat] = [:]
    /// How the tasks are ordered: by state (the board's own order), by name, or as they were dragged.
    @AppStorage("taskSort") private var sort = BoardRow.Sort.state
    /// The dragged order, one lead per line; tasks not in it yet go on top.
    @AppStorage("taskOrder") private var order = ""
    @State private var sortHovered = false
    @State private var showingArchive = false

    private func sorted(_ rows: [BoardRow]) -> [BoardRow] { BoardRow.sorted(rows, by: sort, order: order) }

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

    @State private var namingWorkspace = false

    /// The heading's selector: the workspaces, the current one marked; New workspace… and Workspace settings… under them.
    private func workspaceRows() -> [SelectorSection] {
        ComposerRows.menu([
            workspace.workspaces.map { w in (w.id, w.name, w.glyph, w.id == workspace.current, { workspace.current = w.id }) },
            [("new", "New workspace…", "plus", false, { namingWorkspace = true }),
             ("settings", "Workspace settings…", "sliders", false, { SettingsView.requested = .workspaces; place = .settings })],
        ])
    }

    var body: some View {
        SidebarColumn(title: workspace.currentWorkspace.name, picker: workspaceRows) {
            SidebarItem("New task", icon: "compose", selected: place == .home) { place = .home }
                .keyboardShortcut("n", modifiers: .command)
            SidebarItem("All tasks", icon: "list-checkbox", selected: place == .board) { place = .board }
            // Each lead's workers looked up once per update, not by searching every task for every row.
            let all = workspace.conversations
            let workersOf = Dictionary(grouping: all.filter { $0.parent != nil }, by: { $0.parent ?? "" })
            // Not before the first board: until then every lead looks like it isn't on it.
            let earlier = workspace.board.isEmpty ? [] : earlier(all).filter { workspace.workspace(of: $0) == workspace.current }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // The heading where every sidebar's is, its sort button centred over the tasks' state icons below.
                    HStack(spacing: 0) {
                        Text("Tasks").font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 10)
                        Spacer()
                        Menu {
                            Picker("Sort by", selection: $sort) {
                                Text("State").tag(BoardRow.Sort.state)
                                Text("Name").tag(BoardRow.Sort.name)
                                Text("Manual (drag to arrange)").tag(BoardRow.Sort.manual)
                            }
                            .pickerStyle(.inline)
                            Divider()
                            // This workspace's tasks: for the night, or while you're away.
                            let here = workspace.board.filter { $0.workspace == workspace.current }
                            Button("Pause all tasks") { Task { await workspace.pause(here.filter { $0.ownState != .paused }.map(\.session)) } }
                                .disabled(!here.contains { $0.ownState != .paused })
                            if here.contains(where: { $0.ownState == .paused }) {
                                Button("Resume paused tasks") { Task { await workspace.unpause(here.filter { $0.ownState == .paused }.map(\.session)) } }
                            }
                            Divider()
                            Button("Archived tasks…") { showingArchive = true }
                        } label: {
                            NucleoIcon("sliders", size: 13).foregroundStyle(.secondary).frame(width: 24, height: 24)
                                .background(sortHovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        // Drawn as its label, not as AppKit's pop-up button: the square shows under the pointer.
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .onHover { sortHovered = $0 }
                        // A row's state icon is 14 pt, 10 pt in from the edge: its centre is 17 pt in, as this 24 pt button's.
                        .padding(.trailing, 5).tip("Sort, pause or unarchive tasks")
                        .sheet(isPresented: $showingArchive) { ArchiveSheet(workspace: workspace) }
                    }
                    // A 16 pt heading line with 18 above and 6 below, as SidebarHeading has, now 24 pt for the button.
                    .padding(.top, 14).padding(.bottom, 2)
                    if workspace.board.isEmpty {
                        Text("No tasks").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 10)
                    }
                    let folded = Set(folded.split(separator: "\n").map(String.init))
                    let rows = sorted(workspace.board.filter { $0.workspace == workspace.current })
                    let ids = rows.map(\.session)
                    ForEach(rows) { row in
                        let workers = workersOf[row.session] ?? []
                        let open = !folded.contains(row.session)
                        // A lead and its workers move as one, with no gap between them: the branch runs unbroken.
                        VStack(alignment: .leading, spacing: 0) {
                            TaskRow(title: row.task, state: row.ownState, selected: place == .task(row.session) && navigation.worker == nil,
                                    fold: workers.isEmpty ? nil : open, action: {
                                // Its worker shown, the same task: back to the lead.
                                place = .task(row.session)
                                navigation.worker = nil
                            }, toggle: { toggle(row.session) }, reorder: reorder(row.session, in: rows))
                                .contextMenu { menu(row.session, name: row.task, ticket: row.ticket) }
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("tasks")).minY } action: { tops[row.session] = $0 }
                                .onHover { inside in TaskPeek.shared.hover(row.session, top: tops[row.session] ?? 0, inside: inside && drag == nil) }
                            if open {
                                ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
                                    TaskRow(title: Workspace.label(of: worker), state: row.member(worker.id)?.state ?? TaskRow.state(of: worker), selected: navigation.worker == worker.id,
                                            branch: index == workers.count - 1 ? .last : .middle, action: {
                                        place = .task(row.session)
                                        navigation.worker = worker.id
                                    })
                                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("tasks")).minY } action: { tops[worker.id] = $0 }
                                    .onHover { inside in TaskPeek.shared.hover(worker.id, top: tops[worker.id] ?? 0, inside: inside && drag == nil) }
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
                                .contextMenu { menu(lead.id, name: Workspace.label(of: lead), ticket: lead.ticket) }
                        }
                    }
                }
                // The last task clear of the fade at the foot.
                .padding(.bottom, 36)
            }
            .thinScrollbar(outset: 10, remember: "sidebar.tasks") // in the sidebar's padding: at its edge, clear of the rows
            .scrollIndicators(.never)
            .sheet(isPresented: $namingWorkspace) {
                NameSheet(title: "New workspace", name: "", action: "Create") { name in
                    Task { if let error = await workspace.saveWorkspace(ZerodLink.Workspace(name: name)) { NSSound.beep(); Log.write("workspace: \(error)") } }
                }
            }
            .sheet(item: $renaming) { task in
                NameSheet(title: "Rename", name: task.name, action: "Rename") { name in Task { await workspace.rename(task.id, to: name, ticket: task.ticket) } }
            }
            // ⌘1 to ⌘9: the first nine tasks as the sidebar shows them (this workspace's, leads only), as a browser's tabs.
            .background {
                let rows = sorted(workspace.board.filter { $0.workspace == workspace.current }).prefix(9)
                ForEach(Array(rows.enumerated()), id: \.element.session) { index, row in
                    Button("") { place = .task(row.session); navigation.worker = nil }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                .hidden()
            }
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
    /// A task's name is the user's to change; the sheet asks for it.
    struct Renaming: Identifiable { let id: String; let name: String; let ticket: String? }
    @State private var renaming: Renaming?

    @ViewBuilder private func menu(_ id: String, name: String, ticket: String?) -> some View {
        Button("Rename…") { renaming = Renaming(id: id, name: name, ticket: ticket) }
        if workspace.workspaces.count > 1 {
            Menu("Move to") {
                ForEach(workspace.workspaces) { w in
                    Button(w.name) { Task { await workspace.place(id, in: w.id) } }.disabled(w.id == workspace.current)
                }
                if workspace.roster[id]?.workspace != nil {
                    Divider()
                    Button("Its folder's workspace") { Task { await workspace.place(id, in: nil) } }
                }
            }
        }
        pausing(id, in: workspace)
        Button("Save for later") { Task { await workspace.askToSaveForLater(id) } }
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

/// The task pages, the last few kept mounted behind the one shown: a switch back to one shows it as it was, scroll,
/// draft and all, with nothing to build. Hidden pages take no clicks, keys or focus.
private struct TaskPages: View {
    let workspace: Workspace
    let inbox: InboxController
    @Bindable var navigation: Navigation
    let current: String
    @State private var recent: [String] = []
    private static let kept = 3

    var body: some View {
        let shown = recent.contains(current) ? recent : recent + [current]
        ZStack {
            ForEach(shown, id: \.self) { id in
                let active = id == current
                TaskView(workspace: workspace, inbox: inbox, lead: id, navigation: navigation, active: active)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .disabled(!active)
                    .accessibilityHidden(!active)
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

private struct TaskView: View {
    let workspace: Workspace
    let inbox: InboxController
    let lead: String
    @Bindable var navigation: Navigation
    /// The page shown, as against one kept behind it.
    var active = true

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
                if let live = workspace.live(conversation.id) { ConversationView(workspace: workspace, inbox: inbox, active: active, queued: workspace.queued(conversation.id, board: row?.queued ?? []), held: row?.held ?? false, live: live, open: open).id(conversation.id) }
                if navigation.pane {
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                    TaskDetails(workspace: workspace, inbox: inbox, navigation: navigation, row: row, conversation: conversation, docked: true)
                }
            }
        } else {
            ZStack(alignment: .topTrailing) {
                if let conversation, let live = workspace.live(conversation.id) { ConversationView(workspace: workspace, inbox: inbox, active: active, queued: workspace.queued(conversation.id, board: row?.queued ?? []), held: row?.held ?? false, live: live, open: open).id(conversation.id) }
                if navigation.pane, let conversation {
                    TaskDetails(workspace: workspace, inbox: inbox, navigation: navigation, row: row, conversation: conversation).padding(TaskDetails.inset)
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
        BarButton(symbol: "terminal", help: conversation.terminal == nil
                  ? "Open in \(conversation.provider.title)'s own terminal, for what only it has"
                  : "Back to Zero, with what happened in the terminal", selected: conversation.terminal != nil) {
            Task { conversation.terminal == nil ? await workspace.openTerminal(conversation.id) : await workspace.closeTerminal(conversation.id) }
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
                Button("Archive") {
                    navigation.place = .home
                    Task { await workspace.archive(lead) }
                }
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

/// The pane on a task's right: where it stands, what it needs from you, the agent on it, where it works, its workers.
private struct TaskDetails: View {
    let workspace: Workspace
    /// For answering what it's blocked on, from its status.
    let inbox: InboxController
    let navigation: Navigation
    let row: BoardRow?
    let conversation: Conversation
    /// Beside a terminal: a full-height column on the sidebar's grey rather than a floating card.
    var docked = false
    /// How far in from the panel's edges it floats, and its corners: together the panel's radius (12).
    static let inset: CGFloat = 6
    static let radius: CGFloat = 12 - inset
    /// The status card, beside the pane level with the Status row: open while the pointer is on the pill or the card,
    /// held once clicked into (an answer being typed) until a click outside it or Esc.
    @State private var peek = false
    @State private var peekY: CGFloat = 0
    @State private var overPill = false
    @State private var overCard = false
    @State private var held = false
    @State private var cardFrame = CGRect.zero
    @State private var monitor: Any?
    /// The Agent row's selector: where it opens from, and the row under the pointer.
    @State private var agentAnchor = CGRect.zero
    /// Every worker listed, not only the ones that need attention.
    @State private var allWorkers = false
    @State private var overAgent = false
    private var agentChip: String { "details.\(conversation.id).agent" }

    var body: some View {
        // Its properties, then its workers.
        VStack(alignment: .leading, spacing: 0) { properties; workers }.padding(16)
        .frame(width: 280, alignment: .leading)
        .frame(maxHeight: docked ? .infinity : nil, alignment: .top)
        // Concentric with the panel's corner it sits in: its radius and its inset add up to the panel's (6 + 6 = 12).
        .background(docked ? Theme.composer : Theme.card, in: RoundedRectangle(cornerRadius: docked ? 0 : Self.radius))
        .overlay { if !docked { RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Theme.stroke) } }
        .compositingGroup()
        .shadow(color: .black.opacity(docked ? 0 : 0.04), radius: 10, y: 2)
        .coordinateSpace(name: "details")
        .overlay(alignment: .topLeading) {
            if peek, let row {
                StatusCard(row: row, inbox: inbox)
                    .onHover { inside in overCard = inside; if !inside { closeSoon() } }
                    .simultaneousGesture(TapGesture().onEnded { hold() })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
                    .offset(x: -(StatusCard.width + 8), y: max(0, peekY - 14))
            }
        }
        .onDisappear(perform: release)
    }

    /// A moment to cross from the pill to the card; held, it stays.
    private func closeSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if !overPill && !overCard && !held { peek = false }
        }
    }

    /// Clicked into: it stays until a click outside it, or Esc.
    private func hold() {
        guard !held else { return }
        held = true
        let (frame, close) = ({ cardFrame }, { release() })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                close()
                return nil
            }
            guard let content = event.window?.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if !frame().contains(point) { close() }
            return event
        }
    }

    private func release() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = false
        peek = false
    }

    /// The agent on it, where it works, its status (its detail, and what it's blocked on, on hover), then what its agent
    /// says about it: its branch, ticket, and whatever it set with `zero attr` (a PR, say); a link opens.
    private var properties: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
            property("Agent") {
                VStack(alignment: .leading, spacing: 2) {
                    // The provider's mark and the model by its name ("Opus 5.5"), not its id: a click picks another
                    // model, or another provider to take the task over.
                    let open = WorkspaceSelector.shared.open == agentChip
                    HStack(spacing: 6) {
                    Button {
                        WorkspaceSelector.shared.toggle(agentChip, kind: .runtime, anchor: agentAnchor, rows: {
                            ComposerRows.taskModels(conversation, chosen: (conversation.provider, conversation.model)) { picked, choice in
                                Task { await workspace.switchProvider(conversation.id, to: picked, model: choice.id.isEmpty ? nil : choice.id) }
                            }
                        }, level: { id in id == "\(conversation.provider.rawValue)/\(conversation.model ?? "")" ? conversation.effort : nil },
                           setLevel: { _, level in Task { await workspace.switchProvider(conversation.id, to: conversation.provider, model: conversation.model, effort: level) } })
                    } label: {
                        HStack(spacing: 5) {
                            if let mark = conversation.provider.mark {
                                mark.resizable().aspectRatio(contentMode: .fit).frame(width: 13, height: 13).clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            Text([modelName ?? conversation.provider.title, conversation.effort.map { effortLabel($0, short: true) }].compactMap { $0 }.joined(separator: " · "))
                                .lineLimit(1).truncationMode(.tail).tip([conversation.provider.title, conversation.model].compactMap { $0 }.joined(separator: " · "))
                            NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3).padding(.leading, -6)
                        .background(open || overAgent ? Theme.row : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).fixedSize()
                    .onHover { overAgent = $0 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { agentAnchor = $0 }
                    .disabled(conversation.status == .working || conversation.status == .waiting)
                    // Unrestricted: a bolt beside the agent, as the composer's permissions chip shows it.
                    if conversation.permissions == .unrestricted {
                        // A square to hover, so the tip shows: a bare icon gives macOS nothing to track.
                        NucleoIcon("bolt-lightning", fill: "glyph", size: 13).foregroundStyle(.orange)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                            .tip("Unrestricted: it acts without asking")
                    }
                    }
                    if let usage { Text(usage).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                }
            }
            property("Where") {
                // The place's own folder when the places command says (a bench's), else the task's.
                let folder = row?.path ?? conversation.cwd
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) } label: {
                    Self.linked(row?.place ?? (conversation.cwd as NSString).lastPathComponent).truncationMode(.middle)
                }
                .buttonStyle(.plain).tip((folder as NSString).abbreviatingWithTildeInPath + " — open in Finder")
            }
            if let row {
                property("Status") {
                    StateLabel(state: row.ownState)
                        .onHover { inside in
                            overPill = inside
                            if inside { peek = true } else { closeSoon() }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("details")).minY } action: { peekY = $0 }
                }
            }
            if let branch = conversation.branch {
                property("Branch") { Text(branch).lineLimit(1).truncationMode(.middle).tip(branch) }
            }
            if let ticket = conversation.ticket {
                property("Ticket") { link(ticket, to: ticketURL(ticket)) }
            }
            ForEach(attributes, id: \.name) { attribute in
                property(attribute.name) { link(Self.shown(attribute.value), to: Self.url(attribute.value)) }
            }
        }
        .font(.system(size: 12.5))
    }

    /// Its workers, what each is on and where it stands, most urgent first; a click shows that worker.
    @ViewBuilder private var workers: some View {
        let members = (row?.team ?? []).filter { $0.session != conversation.id }.sorted { Self.urgency($0.state) < Self.urgency($1.state) }
        if !members.isEmpty {
            // The few that matter (needing you, in trouble, at work), the rest behind their count; opened, the whole
            // list scrolls inside the pane rather than running off the window.
            let urgent = members.filter { Self.urgency($0.state) <= 2 }
            let shown = allWorkers ? members : Array((urgent.isEmpty ? members : urgent).prefix(8))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Workers").foregroundStyle(.secondary)
                    Spacer()
                    if members.count > shown.count || allWorkers {
                        Button(allWorkers ? "Fewer" : "All \(members.count)") { allWorkers.toggle() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 14).padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { workerRows(shown) }
                }
                .thinScrollbar()
                .frame(maxHeight: allWorkers ? 360 : .infinity)
                .fixedSize(horizontal: false, vertical: !allWorkers)
            }
            .font(.system(size: 12.5))
        }
    }

    @ViewBuilder private func workerRows(_ members: [BoardRow.Member]) -> some View {
                ForEach(members, id: \.session) { member in
                    Button { navigation.worker = member.session } label: {
                        HStack(alignment: .top, spacing: 7) {
                            StateIcon(state: member.state).frame(width: 14, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title(of: member)).fontWeight(.medium).lineLimit(1)
                                if let now = member.needs ?? member.now, !now.isEmpty {
                                    Text(now).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity([.done, .merged, .idle, .offline].contains(member.state) ? 0.6 : 1)
                }
    }

    /// Most urgent first, as the board sorts its rows.
    private static func urgency(_ state: BoardRow.State) -> Int {
        switch state {
        case .needsYou: 0
        case .trouble: 1
        case .working: 2
        case .handed: 3
        case .answered: 4
        case .blocked: 5
        case .done: 6
        case .merged: 7
        default: 8
        }
    }

    private func title(of member: BoardRow.Member) -> String {
        workspace.conversations.first { $0.id == member.session }.map(Workspace.label(of:)) ?? member.place
    }

    /// A row of the pane's properties: its name in a narrow column, its value beside it.
    private func property(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.leading).frame(width: 52, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The ticket's page: from the integration's view that lists it, else Linear's link for its team's workspace.
    private func ticketURL(_ ticket: String) -> URL? {
        if let listed = workspace.items.values.lazy.flatMap({ $0 }).first(where: { $0.ticketKey == ticket })?.url { return LinearLinks.url(listed) }
        guard let team = ticket.split(separator: "-").first, let space = Linear.shared.teams[String(team)] else { return nil }
        return LinearLinks.url("https://linear.app/\(space)/issue/\(ticket)")
    }

    /// Something that opens, as the pane shows it: a little heavier, on a dashed underline; no icon, no blue.
    static func linked(_ text: String) -> some View {
        Text(text).fontWeight(.medium).lineLimit(1)
            // Drawn, not the system's underline, which sits too far below the words: just under the baseline.
            .overlay(alignment: .bottom) {
                Rule().stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: 1).offset(y: -1.5)
            }
    }

    /// A line across, for the dashed underline.
    private struct Rule: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) } }
    }

    /// Its value as a link when it is one, plain words otherwise.
    @ViewBuilder private func link(_ text: String, to url: URL?) -> some View {
        if let url {
            Button { NSWorkspace.shared.open(url) } label: { Self.linked(text) }
                .buttonStyle(.plain).tip("Open " + url.absoluteString)
        } else {
            Text(text).lineLimit(2)
        }
    }

    /// What its agent set (`zero attr`), by name; a pull request the conversation mentions, until one's set.
    private var attributes: [(name: String, value: String)] {
        var all = (conversation.attributes ?? [:]).sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
        if !all.contains(where: { $0.name.uppercased() == "PR" }), let found = mentionedPR { all.insert((name: "PR", value: found), at: 0) }
        return all
    }

    /// The latest pull request the task's words mention: a GitHub link, or "repo#123" for a repository one of the
    /// GitHub views shows (which says whose it is).
    private var mentionedPR: String? {
        let texts = [row?.asks.first?.title, row?.needs, row?.now].compactMap { $0 }
            + (workspace.live(conversation.id)?.conversation.items ?? []).reversed().compactMap { item -> String? in
                switch item.kind { case let .agent(text, _), let .user(text, _): text; default: nil }
            }
        let owners = Dictionary(workspace.items.values.flatMap { $0 }.compactMap { item -> (String, String)? in
            let parts = item.url.split(separator: "/")
            guard item.url.contains("github.com/"), parts.count >= 4 else { return nil }
            return (String(parts[3]).lowercased(), String(parts[2]))
        }, uniquingKeysWith: { first, _ in first })
        for text in texts {
            if let match = text.firstMatch(of: #/https://github\.com/[\w.-]+/[\w.-]+/pull/\d+/#) { return String(match.0) }
            if let match = text.firstMatch(of: #/\b([\w.-]+)#(\d+)\b/#), let owner = owners[String(match.1).lowercased()] {
                return "https://github.com/\(owner)/\(match.1)/pull/\(match.2)"
            }
        }
        return nil
    }

    /// A GitHub pull request as "repo#123"; any other link without its scheme; words as they are.
    static func shown(_ value: String) -> String {
        if let pr = value.firstMatch(of: #/github\.com/[\w.-]+/([\w.-]+)/pull/(\d+)/#) { return "\(pr.1)#\(pr.2)" }
        if value.hasPrefix("https://") || value.hasPrefix("http://") { return String(value.split(separator: "/", maxSplits: 1).last ?? Substring(value)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return value
    }

    static func url(_ value: String) -> URL? {
        guard value.hasPrefix("https://") || value.hasPrefix("http://") else { return nil }
        return URL(string: value)
    }

    /// The model as its provider's catalogue names it; nil leaves the provider's name (its default model).
    private var modelName: String? {
        guard let model = conversation.model else { return nil }
        return ComposerRows.catalogue(conversation.provider).first { $0.id == model }?.name ?? model
    }

    /// "5 hours 18% · 7 days 5%": what the provider last reported for the account.
    private var usage: String? {
        guard let windows = conversation.usage?.windows, !windows.isEmpty else { return nil }
        return windows.map { "\($0.name) \(Int(($0.used * 100).rounded()))%" }.joined(separator: " · ")
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
                                 Text(row.task).foregroundStyle(.primary).lineLimit(3).tip(row.task)
                                 if row.workers > 0 { Text(row.workers == 1 ? "1 worker" : "\(row.workers) workers").font(.system(size: 12)).foregroundStyle(.secondary) }
                             },
                             place: Text(row.place).foregroundStyle(.secondary),
                             state: VStack(alignment: .leading, spacing: 3) {
                                 StateLabel(state: row.state)
                                 if let needs = needs(row) { Text(needs).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3).tip(needs) }
                             },
                             now: Text((try? AttributedString(markdown: row.now ?? "", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(row.now ?? ""))
                                 .lineLimit(3).tip(row.now ?? ""),
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
            if !workspace.isPaused(row.session) {
                if row.online {
                    Button("End session") { Task { await workspace.stop(row.session) } }
                } else {
                    Button("Resume") { Task { await workspace.resume(row.session) } }
                }
            }
            pausing(row.session, in: workspace)
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
        .tip("Actions")
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

/// A task's Pause, or its Resume when it's paused: it and its workers, on hold and off it.
@MainActor @ViewBuilder func pausing(_ id: String, in workspace: Workspace) -> some View {
    if workspace.isPaused(id) {
        Button("Resume") { Task { await workspace.unpause([id]) } }
    } else {
        Button("Pause") { Task { await workspace.pause([id]) } }
    }
}

/// One line of text, cut short with an ellipsis when it doesn't fit. While `moving`, a line that doesn't fit glides
/// left to its end after a moment and stops there; it slides back when `moving` ends.
struct Marquee: View {
    let text: String
    let moving: Bool
    @State private var full: CGFloat = 0
    @State private var shown: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text).lineLimit(1)
            .opacity(scrolling ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shown = $0 }
            .background(alignment: .leading) {
                Text(text).lineLimit(1).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { full = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolling { Text(text).lineLimit(1).fixedSize().offset(x: offset) }
            }
            .clipped()
            // Moving from the start (a card's title) glides once it's measured.
            .onChange(of: moving) { glide() }
            .onChange(of: full) { glide() }
            .onChange(of: shown) { glide() }
    }

    private func glide() {
        let distance = full - shown
        if moving, distance > 0, !reduceMotion {
            guard offset != -distance else { return }
            scrolling = true
            // An ease-out that holds a steady pace (about 42 points a second) through its first half and slows only to
            // come to rest at the end: 30 points a second on average, so a long name takes longer at the same pace.
            withAnimation(.timingCurve(0.4, 0.5, 0.6, 1, duration: max(0.6, distance / 30)).delay(0.8)) { offset = -distance }
        } else if scrolling {
            withAnimation(.easeOut(duration: 0.2)) { offset = 0 } completion: { if offset == 0 { scrolling = false } }
        }
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
    @State private var hovering = false
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
                if let branch { Branched(last: branch == .last).frame(width: 34) }
                Marquee(text: title, moving: hovering).font(.system(size: 13))
                // A lead with workers: room for its chevron (drawn in the overlay below, so its click is its own).
                if fold != nil { Color.clear.frame(width: 16, height: 1) }
                // The icon keeps its place however long the title: the title gives way, not the state.
                StateIcon(state: state).font(.system(size: 12)).fixedSize().layoutPriority(1)
            }
            .foregroundStyle(.primary)
            // In from the edge as the heading is; a worker's title sits on its branch.
            .padding(.leading, branch != nil ? 0 : 10).padding(.trailing, 10).frame(height: 30)
        }
        .buttonStyle(Hovering(selected: selected))
        .onHover { hovering = $0 }
        // One gesture for click and drag, as the control bar's: on the row's button only, so the fold chevron keeps its
        // own click. Global space: the row moves with the drag, so a local translation would cancel itself out.
        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { reorder?.changed($0.translation.height) }
            .onEnded { _ in if reorder?.ended() == false { action() } },
            including: reorder == nil ? .subviews : .all)
        // Just left of the state icon, outside the row's own button so its click is its own.
        .overlay(alignment: .trailing) {
            if let fold {
                Button(action: toggle) {
                    NucleoIcon("chevron-down", size: 9).foregroundStyle(.secondary).rotationEffect(.degrees(fold ? 0 : -90))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                // Its own hover, a rounded square, in place of the row's.
                .buttonStyle(Hovering(radius: 5))
                .tip(fold ? "Hide its workers" : "Show its workers")
                .padding(.trailing, 10 + 14 + 4)
            }
        }
    }

    /// A worker's state in the sidebar's terms: how it ended its last turn, if it said, else what it's doing.
    static func state(of worker: Conversation) -> BoardRow.State {
        if [.idle, .done, .offline].contains(worker.attention), let answer = worker.items.last(where: { if case .agent(_, true) = $0.kind { true } else { false } }),
           case let .agent(text, _) = answer.kind, let ending = ZeroEnding.split(text).1 {
            switch ending {
            case .done: return .done
            case .working: return .idle
            case .blocked: return .blocked
            case .asked: return .needsYou
            }
        }
        return switch worker.attention {
        case .needsYou: .needsYou
        case .blocked: .blocked
        case .limited, .stuck, .failed: .trouble
        case .working, .starting: .working
        case .done: .done
        case .answered: .answered
        case .idle: .idle
        case .offline: .offline
        }
    }

    /// The dotted line from the lead down to this worker, and across to it; it runs on past a worker that isn't last.
    private struct Branched: View {
        /// Where the line runs: under the centre of the lead's chevron, in the middle of the tree's column.
        static let x: CGFloat = 12
        static var line: some View { Rectangle().fill(.secondary.opacity(0.35)) }
        let last: Bool
        var body: some View {
            // Down from the lead's chevron and across to the worker's title, as hairlines: rectangles, which land on
            // whole pixels as the lead's does (a drawn stroke between pixels reads thicker), and meet without overlap.
            GeometryReader { space in
                let mid = (space.size.height / 2).rounded()
                ZStack(alignment: .topLeading) {
                    Branched.line.frame(width: 1, height: last ? mid + 1 : space.size.height).offset(x: Branched.x - 0.5)
                    Branched.line.frame(width: space.size.width - Branched.x - 4, height: 1).offset(x: Branched.x + 0.5, y: mid)
                }
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
        // A view of its own for each state: a spinner's AppKit view kept from Working could otherwise stand where the
        // next state's icon should be, and the row would show nothing.
        .id(state)
    }

    static func look(_ state: BoardRow.State) -> (symbol: String, color: Color, name: String) {
        switch state {
        case .needsYou: ("hand-3", .blue, "Needs you")
        case .trouble: ("triangle-warning", .orange, "In trouble")
        case .working: ("arrow-rotate-clockwise", .blue, "Working")
        // Done, with a step for the user: a calm to-do, not a decision.
        case .handed: ("hand-holding-box", .teal, "Over to you")
        // No entry, in red: stopped.
        case .blocked: ("circle-minus", .red, "Blocked")
        case .done: ("circle-check", .green, "Done")
        case .answered: ("message-check", .indigo, "Replied")
        case .merged: ("code-branch", .purple, "Merged")
        case .paused: ("circle-pause", .secondary, "Paused")
        case .idle: ("moon", .secondary, "Idle")
        case .offline: ("power-off", .secondary, "Offline")
        }
    }
}

/// Which task's row the pointer rests on in the sidebar, and where: its card shows after a moment's rest, follows the
/// pointer from row to row once it shows, and stays while the pointer is on it.
@MainActor @Observable final class TaskPeek {
    static let shared = TaskPeek()
    var session: String?
    var top: CGFloat = 0
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored var overCard = false

    func hover(_ session: String, top: CGFloat, inside: Bool) {
        pending?.cancel()
        if inside {
            // Open already: on to this row at once. Else after a rest, so passing over the list shows nothing.
            if self.session != nil { self.session = session; self.top = top; return }
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self?.session = session; self?.top = top
            }
        } else {
            // A moment to cross to the card.
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, !self.overCard else { return }
                self.session = nil
            }
        }
    }

    func close() { pending?.cancel(); overCard = false; session = nil }
}

/// A task's details where the pointer rests on its row: its name, its own state, what it's doing, what it needs from
/// you (a step, its asks). Drawn as the rail's preview is; a click opens the task.
struct TaskPeekCard: View {
    let workspace: Workspace
    /// The lead's task, and the worker in it when the card is a worker's.
    let open: (String, String?) -> Void
    @AppStorage(SidebarWidth.key) private var width = SidebarWidth.standard

    var body: some View {
        let peek = TaskPeek.shared
        if let id = peek.session, let (lead, row) = found(id) {
            card(row, title: lead.session == id ? row.task : workspace.conversations.first { $0.id == id }.map(Workspace.label(of:)) ?? row.task)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { open(lead.session, lead.session == id ? nil : id); peek.close() }
                .onHover { inside in
                    peek.overCard = inside
                    if !inside { peek.close() }
                }
                .offset(x: width + 8, y: max(8, peek.top - 4))
        }
    }

    /// The lead's row, and the row to show: the lead's, or one of its workers' from its team.
    private func found(_ id: String) -> (BoardRow, BoardRow)? {
        for lead in workspace.board {
            if lead.session == id { return (lead, lead) }
            if let member = lead.member(id) { return (lead, member) }
        }
        return nil
    }

    /// What a lead's workers call for, when it's more than the lead itself shows: "1 worker needs you". Only what wants
    /// the user, so a row's height doesn't change each time a worker starts or stops.
    static func calling(_ row: BoardRow) -> String? {
        guard row.state != row.ownState, [.needsYou, .trouble].contains(row.state) else { return nil }
        let count = (row.team ?? []).filter { $0.state == row.state }.count
        guard count > 0 else { return nil }
        let what = row.state == .needsYou ? (count == 1 ? "needs you" : "need you") : "in trouble"
        return "\(count) worker\(count == 1 ? "" : "s") \(what)"
    }

    private func card(_ row: BoardRow, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // One line, as in the sidebar: a long name glides to its end while the card shows.
                    Marquee(text: title, moving: true).font(.system(size: 13.5, weight: .semibold)).id(title)
                    if let ticket = row.ticket { Text(ticket).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                    if let calling = Self.calling(row) { Text(calling).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                StateLabel(state: row.ownState)
            }
            if let now = row.now, !now.isEmpty {
                Text(now).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let needs = row.needs {
                line("hand-holding-box:glyph", "For you: " + needs)
            }
            ForEach(row.asks.prefix(3), id: \.id) { ask in line("circle-question", ask.title) }
            if row.asks.count > 3 { Text("and \(row.asks.count - 3) more asks").font(.system(size: 11.5)).foregroundStyle(.tertiary) }
            if let queued = row.queued, !queued.isEmpty { line("clock", "\(queued.count) queued" + (row.held == true ? ", held" : "")) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        .compositingGroup()
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            NucleoIcon(icon, size: 12).foregroundStyle(.secondary).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// The symbol and its name, for the board's State column.
/// A task's state as a pill: its icon and name on a wash of its colour.
struct StateLabel: View {
    let state: BoardRow.State

    var body: some View {
        let look = StateIcon.look(state)
        let tint: Color = look.color == .secondary ? .secondary : look.color
        HStack(spacing: 5) {
            StateIcon(state: state).scaleEffect(0.86)
            Text(look.name).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(look.color == .secondary ? AnyShapeStyle(.secondary) : look.color == .green ? AnyShapeStyle(Theme.done) : AnyShapeStyle(look.color))
        }
        .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
        // Level with the words beside it in a row aligned on baselines: the pill's middle where their baseline sits
        // (its spinner has no baseline of its own).
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }
}

// The conversation.

private struct ConversationView: View {
    let workspace: Workspace
    let inbox: InboxController
    /// Shown, as against kept behind the page shown: only the shown page answers Esc and holds the keyboard.
    var active = true
    @State private var isActive = true
    /// Your messages waiting for after the agent's turn, and whether they're held since you stopped it.
    var queued: [Queued] = []
    var held = false
    /// The task's whole conversation, observed on its own: its words redraw this view, not the window.
    let live: LiveConversation
    /// Opens another task: a branch made from this one.
    var open: (String) -> Void = { _ in }
    private var conversation: Conversation { live.conversation }
    /// What's being written, in an object of its own: typing redraws the composer, not this view and its timeline,
    /// which only ever write it (a quote, a rewind, a sent message).
    @State private var box = DraftBox()
    private var draft: String {
        get { box.text }
        nonmutating set { box.text = newValue }
    }
    /// Held at the end of the conversation as it opens and while you're at its end; let go when you scroll away.
    @State private var following = true
    /// Your hand on the page (dragging, or its momentum): nothing else moves it meanwhile.
    @State private var userScrolling = false
    /// The message of yours being gone back to.
    @State private var rewinding: ConversationItem?
    /// Esc twice in quick succession: pick a message to rewind to, then how (RewindCard).
    @State private var pickingRewind = false
    @State private var lastEscape: Date?
    @State private var escapeMonitor: Any?
    /// Images going with the next message.
    @State private var images: [URL] = []
    /// Where the conversation is scrolled to, and how much of it there is: for the scrollbar drawn over it.
    @State private var position = ScrollPosition(edge: .bottom)
    /// Where it's scrolled and what's on screen, read only by the scrollbar, the way down and the rail: scrolling
    /// redraws those, not the conversation.
    @State private var tracker = ScrollTracker()
    /// Your messages in the whole conversation, for the rail.
    /// The rows standing in for older items are on screen: only then is the next page fetched, and one page per
    /// approach: the next only once those rows have left the screen and come back as you scroll on.
    @State private var olderShown = false
    @State private var olderArmed = true
    /// How tall the composer is: the conversation fades out just above it.
    @State private var composerHeight: CGFloat = 0
    /// Just sent: the message sits at the top of the page with room under it for the answer, which fills that room
    /// without moving anything, as Codex's does. Over once you scroll.
    @State private var lifted = false
    /// The lift's scroll has put the message at the top: only then can scrolling up end the lift.
    @State private var liftPlaced = false
    /// The message just sent and the least height of the conversation from it down: a page's worth, so the message
    /// sits at the top with room under it that the answer fills without changing the page's size, so nothing moves.
    /// A scroll up gives the room back: from where you stop you can come down a composer's height, no further.
    @State private var liftId: String?
    @State private var liftMin: CGFloat = 0
    @State private var pageHeight: CGFloat = 0
    /// The room just gone: growth still anchors to the top until scrolling settles, so taking it away moves nothing.
    @State private var settling = false
    /// An older page is coming in above: the page keeps its distance from the end through that, so what's read stays.
    @State private var loadingAbove = false
    /// Another provider picked for the next message; nil keeps the task's own.
    @State private var provider: Provider?
    /// A model and effort picked for the next message; nil keeps the task's own.
    @State private var model: String?
    @State private var effort: String?
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


    /// The next older page, with what's read kept where it is: the offset moves by exactly what was added above once
    /// the new rows have measured (the scroll view's own anchoring isn't to be relied on through that).
    private func loadOlder() async {
        guard olderShown, olderArmed else { return }
        olderArmed = false
        loadingAbove = true
        let before = tracker.geometry
        await workspace.loadEarlier(conversation.id)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            if let before, let now = tracker.geometry, now.contentSize.height > before.contentSize.height + 1 {
                position.scrollTo(y: before.contentOffset.y + (now.contentSize.height - before.contentSize.height))
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        loadingAbove = false
    }

    /// One block as a row: compared before it's drawn (a word streamed into the last answer redraws only that one),
    /// and reporting whether it's on screen, for the rail.
    /// The provider's questions and approvals, and what the agent asked through Zero.
    @ViewBuilder private func waiting(_ conversation: Conversation) -> some View {
        ForEach(conversation.questions) { question in
            QuestionCard(question: question, session: conversation.id, inbox: inbox) { answers in
                Task { await workspace.answer(conversation.id, question: question.id, answers: answers) }
            }
            .id("question-" + question.id)
        }
        // What the agent asked through Zero (zero ask, approve, run): the inbox's own card, here too.
        ForEach(inbox.store.asks.filter { AgentAskCard.open($0, in: conversation) }) { ask in
            AgentAskCard(ask: ask, inbox: inbox).id("ask-" + ask.id)
        }
        ForEach(conversation.approvals) { approval in
            ApprovalCard(approval: approval, cwd: conversation.cwd) { choice in
                Task { await workspace.decide(conversation.id, approval: approval.id, choice: choice.id) }
            }
            .id("approval-" + approval.id)
        }
    }

    private func blockRow(_ block: TimelineBlock, turns: [String: String]) -> some View {
        BlockRow(block: block, cwd: conversation.cwd, quote: quote, save: save, rewind: { rewinding = $0 },
                 later: { [workspace, id = conversation.id] text in Task { await workspace.askToSaveForLater(id, answer: text) } }).equatable()
            .id(block.id)
            .onScrollVisibilityChange(threshold: 0.05) { shown in
                guard let turn = turns[block.id] else { return }
                if shown { tracker.seen[block.id] = turn } else { tracker.seen[block.id] = nil }
            }
            .onDisappear { tracker.seen[block.id] = nil }
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

    /// The blocks before the lifted message, and from it on (none when nothing's lifted).
    private func split(_ blocks: [TimelineBlock]) -> (head: [TimelineBlock], tail: [TimelineBlock]) {
        guard lifted, let at = blocks.firstIndex(where: { $0.id == liftId }) else { return (blocks, []) }
        return (Array(blocks[..<at]), Array(blocks[at...]))
    }

    private var conversationPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                // A step waiting on an approval shows once, in the approval.
                let blocks = TimelineBlock.of(conversation.items.filter { item in !conversation.approvals.contains { $0.item == item.id } },
                                              working: conversation.status == .working || conversation.status == .waiting)
                let turns = TimelineBlock.turns(blocks)
                ScrollView {
                    // Laid out in full, not lazily: a lazy stack keeps the heights it guessed for rows measured off
                    // screen, so its end could sit below its last row and the page open blank. The page loaded is a
                    // few dozen rows; older pages come in on demand above.
                    VStack(alignment: .leading, spacing: 18) {
                        // More above: rows standing in for it, the next page fetched as they come into view, the view
                        // kept on what was at its top.
                        let more = live.earlier
                        if more > 0 {
                            // While it's on screen, page after page (a long turn can leave it there); kept alive just
                            // off screen by the list, it fetches nothing. Anchored at the bottom, the view stays on
                            // what's read as each page goes in above.
                            SkeletonTurns().id("earlier")
                                .onScrollVisibilityChange(threshold: 0.01) { shown in
                                    olderShown = shown
                                    if !shown { olderArmed = true }
                                }
                                .task(id: olderShown ? more : -1) { await loadOlder() }
                        }
                        let (head, tail) = split(blocks)
                        ForEach(head) { block in blockRow(block, turns: turns) }
                        if !tail.isEmpty {
                            // Lifted: from the message just sent down, at least a page tall, so what the agent adds
                            // under it fills room that is already there and the page's size doesn't change.
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(tail) { block in blockRow(block, turns: turns) }
                                // What waits on you, right under the step that asked: in the room kept for the turn,
                                // not after it.
                                waiting(conversation)
                            }
                            .frame(minHeight: liftMin, alignment: .top)
                        } else {
                            waiting(conversation)
                        }
                        // Its provider still getting ready (signing in, say): say so, rather than an empty page.
                        if conversation.status == .starting {
                            Thinking(text: "Starting \(conversation.provider.title)…").id("starting")
                        }
                        // Stuck or out of usage: a callout where the trouble is, at the end of the work, like a failure's.
                        if let health {
                            CautionCallout(text: health.label + ": " + health.text, tone: .amber) {
                                // Out of usage: the task carries on with another provider, the whole conversation with it.
                                if conversation.attention == .limited {
                                    HStack(spacing: 8) {
                                        ForEach(Self.takeOver.filter { $0 != conversation.provider }, id: \.self) { other in
                                            Button("Continue with \(other.title)") { carryOn(with: other) }
                                        }
                                    }
                                }
                            }
                            .id("health")
                        }
                        if let diff = conversation.diff, conversation.status == .idle, !diff.isEmpty {
                            DisclosureGroup("Everything the last turn changed") {
                                DiffText(diff: diff)
                                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                            }.padding(.top, 4)
                        }
                        // Room for the composer and the fade above it: scrolled to the end, the last message sits just
                        // above the composer, and the scrollbar is at the bottom. Just sent, a page of room, so the
                        // message can sit at the top.
                        Color.clear.frame(height: composerHeight + 32).id("end")
                    }
                    .padding(.top, 20)
                    .centredColumn(760)
                    .environment(\.askInbox, inbox)
                    .environment(\.askSession, conversation.id)
                }
                .scrollIndicators(.never)
                // Opened at the end, and held there as answers measure themselves and new ones come, while you're at
                // the end; content added above (an older page) leaves what you're reading where it is.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // Only you scroll: what's read keeps its distance from the top as the agent adds words below, so
                // nothing moves under your eyes. The end is kept only while you're at it (following), and while an
                // older page comes in above.
                .defaultScrollAnchor((following || loadingAbove) && !lifted && !settling ? .bottom : .top, for: .sizeChanges)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, height in pageHeight = height }
                // The message just sent goes to the top of the page once it's in the conversation.
                .onChange(of: conversation.items.last(where: \.isYours)?.id) { _, id in
                    // Once per send: a worker's report landing right after (a message of its own) mustn't move the page again.
                    guard lifted, !liftPlaced, let id else { return }
                    liftId = id
                    liftMin = max(0, pageHeight - 52 - composerHeight - 32)
                    Task {
                        try? await Task.sleep(for: .milliseconds(50))
                        guard lifted else { return }
                        position.scrollTo(id: id, anchor: UnitPoint(x: 0, y: 52 / max(pageHeight, 1)))
                        liftPlaced = true
                    }
                }
                // Where you were in it, kept when scrolling stops and when you leave.
                .onScrollPhaseChange { _, phase in
                    // Scrolled by you: it stops following the end, until you're back at it. Scrolling while the rows
                    // for older items show asks for the next page (one page per gesture, never a chain).
                    userScrolling = phase == .interacting || phase == .decelerating
                    if phase == .interacting {
                        following = false
                        if olderShown, !olderArmed { olderArmed = true; Task { await loadOlder() } }
                    }
                    if phase == .idle {
                        settling = false
                        // Lifted, the room gives way behind you as you scroll up: from where you stop you can come
                        // back down a composer's height, no further. Far enough up and the room is gone, the lift
                        // with it. The page is put back where you stopped, in case the shrink moved it.
                        if lifted, liftPlaced, let g = tracker.geometry {
                            let offset = g.contentOffset.y
                            let beyond = max(0, g.contentSize.height - g.containerSize.height - offset - composerHeight)
                            if beyond > 0 {
                                liftMin = max(0, liftMin - beyond)
                                if liftMin == 0 { lifted = false; liftPlaced = false; liftId = nil }
                                DispatchQueue.main.async { position.scrollTo(y: offset) }
                            }
                        }
                        rememberScroll()
                        // At the end, following: never while lifted, whose room ends exactly at the page's foot (the
                        // lift's own scroll settles here too, and would read as you having scrolled to the end).
                        // At the end means at it, not near it: a release of the lift leaves the end a few points off.
                        if let g = tracker.geometry, !lifted {
                            let end = g.contentSize.height + g.contentInsets.bottom - g.contentInsets.top - g.containerSize.height
                            following = end - g.contentOffset.y < 2
                        }
                    }
                }
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { before, now in
                    tracker.geometry = now
                    // Lifted, and the reply has outgrown the room while you sat at its foot: the lift has done its
                    // work, and the page follows the end from here, as it would have without it.
                    let foot = { (g: ScrollGeometry) in g.contentSize.height + g.contentInsets.bottom - g.contentInsets.top - g.containerSize.height }
                    if lifted, liftPlaced, !userScrolling, foot(before) - before.contentOffset.y < 2, foot(now) - now.contentOffset.y > 2 {
                        lifted = false; liftPlaced = false; liftId = nil; following = true
                        position.scrollTo(edge: .bottom)
                        return
                    }
                    // Following the end (as it opens, and while you're at it): rows measure themselves after the first
                    // layout, and the list's height can settle far from its first guess (a long conversation came out
                    // 2,000 pt shorter, leaving the view past its end, blank). It stays at the end of what's there.
                    // The offset at the end: the content, less the page, with the insets (the title bar's 38 above)
                    // in; without them being at the end read as 38 short of it.
                    let end = now.contentSize.height + now.contentInsets.bottom - now.contentInsets.top - now.containerSize.height
                    if following, end > 0, abs(now.contentOffset.y - end) > 2 { position.scrollTo(edge: .bottom) }
                    // Past the end is never a place to be (a page left blank until scrolled): back to the end, whether
                    // following it or restoring where you were.
                    else if end > 0, now.contentOffset.y > end + 2 { position.scrollTo(edge: .bottom) }
                    // Scrolled up past the room under a sent message (it's wholly below the page): the room goes, out
                    // of sight, so scrolling back down ends at the conversation's end.
                }
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
                    // What waits for after this turn sits above the composer, part of its height for the fade above.
                    VStack(spacing: 0) {
                        if !queued.isEmpty || held {
                            QueueStrip(queued: queued, held: held,
                                       steer: { item in Task { if await workspace.unqueue(conversation.id, item: item.id) { send(item.text, images: item.images ?? [], with: conversation.provider) } } },
                                       edit: { item in Task { if await workspace.unqueue(conversation.id, item: item.id) { draft = item.text; images = (item.images ?? []).map { URL(fileURLWithPath: $0) } } } },
                                       remove: { item in Task { _ = await workspace.unqueue(conversation.id, item: item.id) } },
                                       release: { Task { await workspace.release(conversation.id) } })
                                .frame(maxWidth: 680)
                        }
                        composer
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { composerHeight = $0 }
                }
                // Scrolled up: a way back down, just above the composer.
                .overlay(alignment: .bottom) {
                    WayDown(tracker: tracker) { following = true; lifted = false; withAnimation { proxy.scrollTo("end", anchor: .bottom) } }.padding(.bottom, composerHeight + 6)
                }
                .overlay(alignment: .trailing) { ThinScrollbar(tracker: tracker) { following = false; lifted = false; position.scrollTo(y: $0) }.padding(.trailing, 2) }
                .overlay(alignment: .leading) {
                    // Every message of yours, loaded or not, from zerod's outline of the conversation.
                    let marks = (workspace.outlines[conversation.id] ?? []).map { MessageRail.Mark(id: $0.id, text: $0.text, answer: $0.answer.map { ZeroEnding.split($0).0 }) }
                    if marks.count > 1 {
                        MessageRail(marks: marks, tracker: tracker, inset: 18) { id in
                            Task {
                                // Not loaded yet: everything from it down to what is, then there.
                                following = false
                                if !conversation.items.contains(where: { $0.id == id }) { await workspace.loadEarlier(conversation.id, from: id) }
                                withAnimation { proxy.scrollTo(id, anchor: .top) }
                            }
                        }
                        .padding(.vertical, 40)
                    }
                }
                // Fetched again as your messages come and go, not with every word streamed.
                .task(id: conversation.items.count(where: { if case .user = $0.kind { true } else { false } }) + live.earlier) {
                    await workspace.outline(conversation.id)
                }
                // Left, it goes back to its latest items: memory doesn't grow with every long task opened.
                .onDisappear { rememberScroll(); workspace.trim(conversation.id); lifted = false }
                // Back where you were: the block that was at the top of the screen, its older page loaded first if
                // it isn't any more. At the end, it opens at the end, as ever.
                .task {
                    guard let kept = ScrollMemory.place(in: conversation.id) else { return }
                    following = false
                    if !conversation.items.contains(where: { $0.id == kept.turn }) { await workspace.loadEarlier(conversation.id, from: kept.turn) }
                    try? await Task.sleep(for: .milliseconds(80))
                    position.scrollTo(id: kept.block, anchor: .top)
                }
                // What you'd written and attached and not sent yet, kept as you go (a branch's message waiting first).
                .onAppear {
                    if let kept = Drafts.load("task:" + conversation.id) { draft = kept.text; images = kept.images }
                    // Kept as it's typed, here rather than in an onChange this view would have to read it for.
                    let (key, imagesNow) = ("task:" + conversation.id, { images })
                    box.saved = { text in Drafts.save(key, text: text, images: imagesNow()) }
                    if let waiting = workspace.pendingDrafts.removeValue(forKey: conversation.id) { draft = waiting }
                    let id = conversation.id
                    Task { try? await Task.sleep(for: .milliseconds(600)); workspace.markSeen(id) }
                    watchEscape()
                }
                .onDisappear { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil }
                .onChange(of: active, initial: true) { isActive = active }
                // An answer that lands while you're here is seen too.
                .onChange(of: conversation.items.last?.id) { workspace.markSeen(conversation.id) }
                .onChange(of: images) { Drafts.save("task:" + conversation.id, text: box.text, images: images) }
                .overlay {
                    if pickingRewind {
                        RewindPicker(messages: conversation.items.filter { if case .user = $0.kind { true } else { false } }.reversed(),
                                     close: { pickingRewind = false }) { item in pickingRewind = false; rewinding = item }
                    } else if let item = rewinding {
                        RewindCard(workspace: workspace, task: conversation.id, item: item, close: { rewinding = nil }) { rewound, conversationToo in
                            // The message back in the box, to send again or change.
                            if conversationToo { draft = rewound.text; images = rewound.images.map { URL(fileURLWithPath: $0) } }
                        } branched: { open($0) }
                    }
                }
            }
        }
    }

    /// Esc, then Esc again within half a second, on the page or in its composer: the rewind picker. A single Esc goes
    /// on to whatever it was for; nothing opens over a card already open.
    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isActive, event.keyCode == 53, !pickingRewind, rewinding == nil else { return event }
            let now = Date()
            if let last = lastEscape, now.timeIntervalSince(last) < 0.5 {
                lastEscape = nil
                guard conversation.items.contains(where: { if case .user = $0.kind { true } else { false } }) else { return event }
                pickingRewind = true
                return nil
            }
            lastEscape = now
            return event
        }
    }

    private var composer: some View {
        let busy = conversation.status == .working || conversation.status == .waiting
        return Composer(draft: Binding(get: { box.text }, set: { box.text = $0 }), placeholder: placeholder, canSend: conversation.status != .starting, folder: conversation.cwd, workspace: workspace,
                 images: $images, active: active, stop: busy && conversation.terminal == nil ? { Task { await workspace.interrupt(conversation.id) } } : nil,
                 queue: busy && conversation.terminal == nil ? {
                     // Return while it works: the message waits for after this turn, in the strip above.
                     let (text, attached) = ImageToken.compact(draft, images: images.map(\.path))
                     draft = ""
                     images = []
                     Task { await workspace.queue(conversation.id, text: text, images: attached) }
                 } : nil) {
            let (text, attached) = ImageToken.compact(draft, images: images.map(\.path))
            draft = ""
            images = []
            send(text, images: attached, with: provider ?? conversation.provider)
            lifted = true
            liftPlaced = false
            following = false
        } controls: {
            // The model for the next message: one of this provider's, or another provider's, which takes the task
            // over, conversation and all.
            let current = provider ?? conversation.provider
            let chosen = provider == nil ? (model ?? conversation.model) : model
            let level = effort ?? (provider == nil && model == nil ? conversation.effort : nil)
            // The model is the subject, its provider the icon: "Opus 5.5 · High". No model picked, the provider's first;
            // a provider with no catalogue (OpenCode) by its name.
            let catalogue = ComposerRows.catalogue(current)
            let name = catalogue.first { $0.id == chosen }?.name ?? chosen ?? catalogue.first?.name ?? current.title
            ComposerChip(id: "task.\(conversation.id).agent", label: [name, level.map { effortLabel($0, short: true) }].compactMap { $0 }.joined(separator: " · "),
                         symbol: "terminal", icon: current.mark, kind: .runtime, prominent: true, rows: {
                ComposerRows.taskModels(conversation, chosen: (current, chosen)) { picked, choice in
                    provider = picked == conversation.provider ? nil : picked
                    model = choice.id.isEmpty ? nil : choice.id
                    if let effort, !choice.levels.contains(where: { $0.id == effort }) { self.effort = nil }
                }
            }, level: { id in id == "\(current.rawValue)/\(chosen ?? "")" ? level : nil }, setLevel: { _, picked in effort = picked })
            .disabled(busy)
            // Between turns only: the agent is started again with them, and carries on its thread.
            ComposerChip(id: "task.\(conversation.id).permissions", label: conversation.permissions == .auto ? "Auto" : "Unrestricted",
                         symbol: conversation.permissions == .auto ? "wand-sparkle" : "bolt-lightning:glyph", tint: conversation.permissions == .auto ? nil : .orange) {
                ComposerRows.list("Permissions", [
                    ("auto", "Auto", "\(conversation.provider.title) decides what's safe, and asks you the rest", conversation.permissions == .auto,
                     { Task { await workspace.setPermissions(conversation.id, .auto) } }),
                    ("unrestricted", "Unrestricted", "Anything, without asking", conversation.permissions == .unrestricted,
                     { Task { await workspace.setPermissions(conversation.id, .unrestricted) } }),
                ])
            }
            .disabled(busy)
            .tip(busy ? "Change permissions once this turn ends" : "What the agent may do without asking")
        }
        // A little narrower than the conversation.
        .centredColumn(680)
        .padding(.top, 4).padding(.bottom, 16)
    }

    /// The providers a task can move to: they read Zero's record natively (Claude Code resumes it, Codex imports it).
    static let takeOver: [Provider] = [.claude, .codex]

    private func send(_ text: String, images: [String] = [], with chosen: Provider) {
        Task {
            let (model, effort) = (model, effort)
            if chosen != conversation.provider {
                guard await workspace.switchProvider(conversation.id, to: chosen, model: model, effort: effort) else { return }
                provider = nil
            }
            await workspace.send(conversation.id, text: text, images: images, model: model, effort: effort)
            self.model = nil
            self.effort = nil
        }
    }

    private func carryOn(with other: Provider) {
        send("You've taken this task over from \(conversation.provider.title), which ran out of usage. Carry on from where it stopped.", with: other)
    }

    /// What's wrong, and what to do about it: the session's attention beyond working or waiting.
    private var health: (label: String, text: String)? {
        switch conversation.attention {
        case .stuck: return ("Stuck", conversation.stalled ?? "It has stopped making progress.")
        case .limited:
            let reset = (conversation.usage?.resetsAt).map { " Resets \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened))." } ?? ""
            return ("Usage limit", "The provider's usage limit is reached.\(reset)")
        // A failure is in the conversation itself, as a callout.
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
/// A question on the page: the callout's shell and strip in amber, and inside, the inbox's own card for each of its
/// fields, flat (one card for an ask, wherever it shows), so answering here is answering there. Until the inbox has
/// them, the plain form.
private struct QuestionCard: View {
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
                    WrappingStack(spacing: 6, trailing: true) { ForEach(images, id: \.self) { Thumbnail(path: $0, side: 88, among: images) } }
                }
                if !text.isEmpty {
                    HStack {
                        Spacer(minLength: 80)
                        // As an answer reads: links that open (zero://, PRs, commits, tickets) and code as code, an
                        // image's token as its pill; the bubble hugs its words.
                        MarkdownText(ImageToken.linked(text, images: images), cwd: cwd, size: 14.5, hugs: true, yours: true).padding(.horizontal, 14).padding(.vertical, 9)
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
            ReasoningRow(text: text, seconds: until.flatMap { until in item.date.map { until.timeIntervalSince($0) } })
        case let .plan(text):
            Text(text).font(.system(.callout, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
        case let .command(command, _, output, exitCode, _):
            CommandCard(command: command, output: output, exitCode: exitCode, status: item.status)
        case let .fileChange(changes):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(changes, id: \.path) { change in FileChangeCard(change: change, status: item.status, cwd: cwd) }
            }
        case let .tool(name, detail):
            // A row like every step's: its name as people say it, its arguments as their values, not JSON.
            HStack(alignment: .top, spacing: 8) {
                StatusIcon(status: item.status)
                Text(ToolNames.name(name)).fontWeight(.medium)
                Text(ToolNames.detail(detail)).foregroundStyle(.secondary).truncationMode(.tail)
            }
            .font(.callout).lineLimit(1).tip(detail)
        case let .notice(text, error):
            if error {
                CautionCallout(text: text)
            } else {
                NucleoLabel(text, icon: "circle-info").font(.callout).foregroundStyle(.secondary)
            }
        case let .table(title, columns, rows):
            TableCard(title: title, columns: columns, rows: rows, cwd: cwd)
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
        .buttonStyle(Hovering(radius: 6)).tip("Copy")
    }
}

private struct StatusIcon: View {
    let status: ItemStatus
    var body: some View {
        Group {
            switch status {
            case .running: Spinner().frame(width: 12, height: 12)
            case .done: NucleoIcon("circle-check", fill: "glyph", size: 14).foregroundStyle(.green)
            case .failed: NucleoIcon("circle-xmark", fill: "glyph", size: 14).foregroundStyle(.red)
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
/// A callout's three tones, light and dark: the shell around it, the panel its words sit on, the ink.
private enum CalloutColors {
    private static func tinted(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1) : NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1) })
    }
    static let rose = (shell: tinted(light: (1.0, 0.894, 0.902), dark: (0.24, 0.03, 0.10)), panel: tinted(light: (1.0, 0.945, 0.949), dark: (0.40, 0.06, 0.18)),
                       ink: tinted(light: (0.30, 0.02, 0.10), dark: (1.0, 0.894, 0.902)))
    static let amber = (shell: tinted(light: (1.0, 0.925, 0.835), dark: (0.26, 0.14, 0.02)), panel: tinted(light: (1.0, 0.957, 0.902), dark: (0.40, 0.22, 0.04)),
                        ink: tinted(light: (0.36, 0.18, 0.0), dark: (1.0, 0.925, 0.835)))
}

private struct CautionCallout<Actions: View>: View {
    /// Rose for a failure, amber for trouble that may pass (stuck, out of usage).
    enum Tone { case rose, amber }
    let text: String
    var tone = Tone.rose
    @ViewBuilder var actions: () -> Actions

    init(text: String, tone: Tone = .rose, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.text = text; self.tone = tone; self.actions = actions
    }

    var body: some View {
        let colors = tone == .rose ? CalloutColors.rose : CalloutColors.amber
        let (label, body) = Self.split(text)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                NucleoIcon("triangle-warning", fill: "glyph", size: 13)
                Text(label).font(.system(size: 12, weight: .medium)).tracking(-0.2)
            }
            .foregroundStyle(colors.ink)
            .padding(.horizontal, 14).padding(.vertical, 7)
            VStack(alignment: .leading, spacing: 12) {
                Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body))
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(colors.ink)
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
           !text[..<colon].contains("\n"), text[text.index(after: colon)...].first == " " {
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
                    if rows.isEmpty { Text("Nothing in it").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1) }
                        line(row.enumerated().map { column, text in AnyView(cell(text, in: column < columns.count ? columns[column] : "")) }, head: false)
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
        if column.localizedCaseInsensitiveContains("risk"), let (level, rest) = BoardRow.risk(text) {
            // The gaps behind the grade, on hover: the column reads at a glance.
            RiskLabel(level: level).tip(rest)
        } else if let state = BoardRow.State.named(text) {
            StateLabel(state: state)
        } else if text.isEmpty || text == "-" || text == "—" || text == "–" {
            Text("–").foregroundStyle(.tertiary)
        } else {
            MarkdownText(text, cwd: cwd, size: 13, compact: true)
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
            Text(level.capitalized).font(.system(size: 11.5, weight: .medium)).foregroundStyle(level == "low" ? AnyShapeStyle(Theme.done) : AnyShapeStyle(color))
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

/// A thought as a step's row: "Thought for 4s" and its first line; opened, all of it under.
private struct ReasoningRow: View {
    let text: String
    let seconds: TimeInterval?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    NucleoIcon("brain", size: 14).foregroundStyle(.secondary).frame(width: 14, height: 16)
                    Text(Took.text("Thought", seconds)).fontWeight(.medium)
                    if !open { Text(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                    Spacer(minLength: 0)
                    NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { Text(text).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 22) }
        }
        .font(.callout)
    }
}

private struct CommandCard: View {
    let command: String
    let output: String
    let exitCode: Int?
    let status: ItemStatus
    @State private var open = false

    var body: some View {
        // A row like every step's; its output, opened, in a box beneath it, under its words.
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: status)
                    Text("$ " + command).font(.system(.callout, design: .monospaced)).lineLimit(open ? nil : 1)
                    Spacer(minLength: 0)
                    if let exitCode, exitCode != 0 { Text("exit \(exitCode)").font(.caption).foregroundStyle(.red) }
                    if !output.isEmpty { NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && !output.isEmpty {
                // As a terminal's pane, drawn as the diffs are: the command whole at its head with what it printed
                // (how much, and a copy), then the output itself, quieter, under a hairline.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        (Text("$ ").foregroundStyle(.tertiary) + Text(command).foregroundStyle(.primary))
                            .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let count = output.split(separator: "\n", omittingEmptySubsequences: false).count
                        Text(count == 1 ? "1 line" : "\(count) lines").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                        CopyButton(text: output).tip("Copy the output")
                    }
                    .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.03))
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                    ScrollView([.vertical, .horizontal]) {
                        Text(output).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineSpacing(2)
                            .textSelection(.enabled).fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .thinScrollbar()
                    .frame(maxHeight: 300)
                }
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                .padding(.leading, 22)
            }
        }
    }
}

private struct FileChangeCard: View {
    let change: FileChange
    let status: ItemStatus
    let cwd: String
    @State private var open = true

    var body: some View {
        let lines = DiffLine.parse(change.diff, added: change.kind == "add")
        let path = relative(change.path, to: cwd)
        let (folder, name) = ((path as NSString).deletingLastPathComponent, (path as NSString).lastPathComponent)
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: status)
                    Text(verb).font(.callout.weight(.medium))
                    // The file first, its folder after it and quieter: the name is what's read.
                    (Text(name).font(.system(.callout, design: .monospaced).weight(.medium))
                        + Text(folder.isEmpty ? "" : "  " + folder).font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    let added = lines.count { $0.kind == .added }, removed = lines.count { $0.kind == .removed }
                    if added > 0 { Text("+\(added)").foregroundStyle(DiffLine.green) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(DiffLine.red) }
                    if !lines.isEmpty { NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary) }
                }
                .font(.system(.callout).monospacedDigit())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

/// A diff's lines, additions green and removals red. A new file's contents arrive without markers: all added.

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

/// A conversation's message being written (ConversationView's draft): observed by the composer alone.
@Observable final class DraftBox {
    var text = "" { didSet { if text != oldValue { saved(text) } } }
    @ObservationIgnored var saved: (String) -> Void = { _ in }
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
    /// On the page shown; a composer on a page kept behind it gives the keyboard up.
    var active = true
    /// While the agent works: the send button stops it instead.
    var stop: (() -> Void)?
    /// While the agent works: what Return does (the message waits for after this turn); ⌘⏎ still sends to steer.
    var queue: (() -> Void)?
    let send: () -> Void
    @ViewBuilder var controls: Controls
    @State private var focused = false
    /// Edits to the field from here (an image's token, a thumbnail's ×), undoable as typing is.
    @State private var handle = ComposeHandle()
    /// More text above or below what the field shows: a fade at that edge.
    @State private var fades = (top: false, bottom: false)
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
    /// Whether this composer's page is the one shown, where the typing and paste monitor (AppKit's, outside SwiftUI's
    /// updates) can read it: a page kept behind the shown one must leave the keyboard and the clipboard alone.
    @State private var shown = FocusBox()

    /// The same switches as the control bar's composer (Settings → Inbox).
    private var suggestCommands: Bool { UserDefaults.standard.object(forKey: "suggestCommands") as? Bool ?? true }
    private var suggestFiles: Bool { UserDefaults.standard.object(forKey: "suggestFiles") as? Bool ?? false }

    var body: some View {
        // The images whose pill is in the words: one whose pills were deleted is out of the strip (and back with ⌘Z).
        let named = Set(ImageToken.find(in: draft).map(\.number))
        let attached = images.enumerated().filter { named.contains($0.offset + 1) }
        let ready = canSend && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty)
        VStack(alignment: .leading, spacing: 12) {
            if !attached.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(attached, id: \.offset) { number, url in
                            // A click puts the image's token where the caret is; its pill opens the image.
                            Thumbnail(path: url.path, tap: { insert(ImageToken.text(number + 1)) }, remove: { handle.remove(number + 1) })
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            ComposeField(text: $draft, placeholder: placeholder, focused: active && focused, editable: true,
                         caret: caret, onCaretApplied: { caret = nil },
                         onFocus: { focused = $0; focus.on = $0 },
                         onSubmit: { if ready { (queue ?? send)() } },
                         onCommandSubmit: queue == nil ? nil : { if ready { send() } },
                         onTrigger: suggest, onKey: key, highlightFiles: suggestFiles,
                         onImage: { number in if images.indices.contains(number - 1) { ImageViewer.shared.show(images[number - 1].path, among: images.map(\.path)) } },
                         handle: handle, onEdges: { fades = (top: $0, bottom: $1) }, height: $fieldHeight)
                .frame(height: fieldHeight)
                .padding(.horizontal, -TokenTextView.inset.width) // the text still starts on the card's 14 pt
                // Scrolled inside: the text fades at an edge with more beyond it, so that more is seen to be there.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [fades.top ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                        Color.black
                        LinearGradient(colors: [.black, fades.bottom ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    }
                }
            HStack(spacing: 6) {
                Button { adding = adding == nil ? .add : nil } label: {
                    NucleoIcon("plus", size: 15).foregroundStyle(.primary).frame(width: 28, height: 28)
                        .background(adding == nil ? .clear : Theme.row, in: Circle())
                }
                .buttonStyle(Hovering(radius: 14, fill: Theme.row, hover: Theme.row)).tip("Add files, folders or a scratchpad")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { plusFrame = $0 }
                HStack(spacing: 6) { controls }.frame(maxWidth: .infinity, alignment: .leading)
                if let stop {
                    Button(action: stop) {
                        NucleoIcon("media-stop", fill: "glyph", size: 12).foregroundStyle(Theme.onKnob).frame(width: 28, height: 28).background(Theme.knob, in: Circle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command).tip("Stop", shortcut: "⌘.")
                } else {
                    Button(action: send) {
                        NucleoIcon("arrow-up", size: 14).foregroundStyle(ready ? Theme.onKnob : .white)
                            .frame(width: 28, height: 28).background(ready ? Theme.knob : Theme.sendIdle, in: Circle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(!ready).tip("Send", shortcut: "⌘↩")
                }
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
        .compositingGroup()
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
        .task(id: workspace?.loopsVersion) { await workspace?.loadLoops() }
        .onChange(of: adding) { _, page in if page == .pads { Task { await workspace?.loadPads() } } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            Attachments.fromDrop(providers) { attach($0) }
            return true
        }
        // ⌘V with an image on the clipboard attaches it; anything else pastes into the text as usual. With nothing that
        // takes typing focused (a click into the conversation, say), typing or pasting goes to the composer, focused.
        .onAppear {
            guard monitor == nil else { return }
            let (focus, draft, focused, caret) = (focus, $draft, $focused, $caret)
            let attach = { (urls: [URL]) in attach(urls) }
            let shown = shown
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard shown.on else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let paste = flags == .command && event.charactersIgnoringModifiers == "v"
                if focus.on {
                    guard paste, let urls = Attachments.fromPasteboard(), !urls.isEmpty else { return event }
                    attach(urls)
                    return nil
                }
                // Only in the workspace's window (not a panel), and only when nothing there takes typing already: a
                // field, the inbox card's reply, a terminal. An answer's text (selectable, not editable) doesn't.
                guard let window = event.window, !(window is NSPanel), !Self.takesTyping(window.firstResponder) else { return event }
                let land = { (text: String) in
                    draft.wrappedValue += text
                    caret.wrappedValue = (draft.wrappedValue as NSString).length
                    focused.wrappedValue = true
                }
                if paste {
                    if let urls = Attachments.fromPasteboard(), !urls.isEmpty { attach(urls) }
                    else if let text = NSPasteboard.general.string(forType: .string) { land(text) }
                    else { return event }
                    return nil
                }
                // Words, not shortcuts (⌘, ⌃) or keys that move about (Return, Tab, Esc, arrows, Space).
                guard flags.isDisjoint(with: [.command, .control]), let typed = event.characters, Self.isWords(typed) else { return event }
                land(typed)
                return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; stopWatchingAdd() }
        .onChange(of: active, initial: true) { shown.on = active; if !active { focus.on = false } }
    }

    /// Whether what has the keyboard takes typing: an editable text view (a field's editor too), or anything that reads
    /// keys as text (a terminal). An answer's text view, selectable but not editable, doesn't.
    private static func takesTyping(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextInputClient
    }

    /// Printable characters other than a lone space: what starts a message.
    private static func isWords(_ text: String) -> Bool {
        guard !text.isEmpty, text != " " else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value) // AppKit's arrow and function keys
        }
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
        var pictures: [URL] = []
        for url in panel.urls {
            if Attachments.isImage(url), let copied = Attachments.copy(url) { pictures.append(copied); continue }
            var path = url.path
            if let folder, path.hasPrefix(folder + "/") { path = String(path.dropFirst(folder.count + 1)) }
            paths.append(path.contains(" ") ? "\"\(path)\"" : "@" + path)
        }
        if !paths.isEmpty { insert(paths.joined(separator: " ")) }
        attach(pictures)
    }

    /// Images attached, each leaving its token in the words: at the caret (a paste while typing is about that spot),
    /// else at the end.
    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let first = images.count + 1
        images += urls
        insert((first..<first + urls.count).map(ImageToken.text).joined(separator: " "))
    }

    /// Words put in at the caret, through the field (undoable); it's focused after.
    private func insert(_ text: String) {
        handle.insert(text)
        if !focused { focused = true }
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
        guard let trigger, trigger.symbol == "/" ? suggestCommands : true else { mention = nil; return }
        if trigger.symbol == "@" {
            // Loops first, always; the folder's files after them when that's on.
            let query = trigger.query.lowercased()
            let loops = (workspace?.loops ?? []).filter { query.isEmpty || $0.name.contains(query) || $0.description.lowercased().contains(query) }
                .map { Mention(kind: .loop, insert: "@" + $0.name, detail: $0.description.isEmpty ? "Loop" : $0.description) }
            guard suggestFiles, let folder else { show(trigger, loops); return }
            mentionTask = Task {
                let files = await ProjectFiles.list(folder)
                guard !Task.isCancelled else { return }
                show(trigger, loops + ProjectFiles.match(trigger.query, in: files).map { Mention(kind: .file, insert: "@" + $0, detail: nil) })
            }
            return
        }
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
         stop: (() -> Void)? = nil, send: @escaping () -> Void) {
        self.init(draft: draft, placeholder: placeholder, canSend: canSend, folder: folder, workspace: workspace, images: images, stop: stop, send: send) { EmptyView() }
    }
}

/// Going back to a message of yours, as Claude Code's rewind has it: the conversation, the folder's code, or both,
/// as they were when the message went; or a new task branched from there. What the code would lose is said first.
/// Your messages waiting for after the agent's current turn, as a tab behind the composer: each with edit, delete and
/// Steer (now, mid-turn); its words go back into the composer on a click. Held since you stopped the agent, the tab
/// says so with Send.
private struct QueueStrip: View {
    let queued: [Queued]
    let held: Bool
    let steer: (Queued) -> Void
    let edit: (Queued) -> Void
    let remove: (Queued) -> Void
    let release: () -> Void
    @State private var hovered: String?
    /// A control under the pointer: it takes the hover, and the row gives its own up. The row gives it up across the
    /// whole cluster of controls, gaps included, so crossing from one to the next doesn't flash the row.
    @State private var control: String?
    @State private var overControls: String?

    var body: some View {
        // The project tab's place and shape, behind the composer's top edge; inside it the panel's parts: a strip
        // naming it, and the queue as rows on their own surface.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                NucleoIcon(held ? "media-stop" : "clock", fill: "glyph", size: 13)
                Text(held ? "Held" : "Queued").font(.system(size: 12, weight: .medium)).tracking(-0.2)
                Spacer()
                if held { Button("Send", action: release).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).tip("You stopped the agent; let the queue go on") }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 28)
            VStack(spacing: 0) {
                ForEach(Array(queued.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 2) {
                        Button { edit(item) } label: {
                            Text(Self.gist(item)).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).tip("Back into the composer")
                        // Edit and delete on squares that take the row's hover when the pointer is on them; then Steer
                        // as a pill, on a hairline so it reads on the hovered row too, solid under the pointer. The
                        // arrow turns the corner: out of the queue and up to the agent.
                        HStack(spacing: 2) {
                            square("pen", help: "Edit in the composer", id: item.id + "/edit") { edit(item) }
                            square("trash", help: "Delete", id: item.id + "/delete") { remove(item) }
                            let lit = control == item.id + "/steer"
                            Button { steer(item) } label: {
                                HStack(spacing: 5) {
                                    Text("Steer").font(.system(size: 12, weight: .medium))
                                    NucleoIcon("arrow-turn-up-2", size: 12)
                                }
                                .foregroundStyle(lit ? AnyShapeStyle(Theme.onKnob) : AnyShapeStyle(.primary))
                                .padding(.leading, 10).padding(.trailing, 8).frame(height: 24)
                                .background(lit ? Theme.knob : Theme.chip, in: Capsule())
                                .overlay(Capsule().strokeBorder(lit ? Color.clear : Theme.stroke))
                            }
                            .buttonStyle(PressableStyle()).tip("Send it now, mid-turn").padding(.leading, 4)
                            .onHover { inside in if inside { control = item.id + "/steer" } else if control == item.id + "/steer" { control = nil } }
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                        .onHover { inside in if inside { overControls = item.id } else if overControls == item.id { overControls = nil } }
                    }
                    .padding(.leading, 14).padding(.trailing, 4).frame(height: 32)
                    // The last row runs on under the composer's card by exactly what the card covers, hover and all.
                    .padding(.bottom, index == queued.count - 1 ? 12 : 0)
                    // The tab's own grey: a step down from the surface, never deeper than the strip above the rows.
                    .background { if hovered == item.id && overControls != item.id { Rectangle().fill(Theme.fieldTab) } }
                    .onHover { inside in if inside { hovered = item.id } else if hovered == item.id { hovered = nil } }
                }
            }
            .frame(maxWidth: .infinity)
            // Not the composer's white: the queue is behind the composer, a step back from it.
            .background(Theme.composer)
            // Concentric: the Steer pill's 12 plus its 4 inset is the surface's 16; plus the surface's 2, the tab's 18.
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous))
            .padding(.horizontal, 2)
        }
        // Codex's tab: flat grey, no edge, a little in from the card's sides; the card's shadow gives it depth. The
        // card sits 4 down inside its own column (the composer's top padding), so 16 here puts 12 of the tab under it:
        // the last row's 12 exactly, leaving the same 4 under its pill as over the first row's.
        .background(Theme.fieldTab, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
        .padding(.horizontal, 13).padding(.bottom, -16)
    }

    private func square(_ symbol: String, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIcon(symbol, size: 13).foregroundStyle(.secondary).frame(width: 24, height: 24)
                .background(control == id ? Theme.fieldTab : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle()).tip(help)
        .onHover { inside in if inside { control = id } else if control == id { control = nil } }
    }

    private static func gist(_ item: Queued) -> String {
        let line = item.text.replacingOccurrences(of: #"\s*\[Image #\d+\]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let count = item.images?.count ?? 0
        let pictures = count == 0 ? "" : (count == 1 ? "an image" : "\(count) images")
        return line.isEmpty ? (pictures.isEmpty ? item.text : pictures.prefix(1).uppercased() + pictures.dropFirst()) : (pictures.isEmpty ? line : "\(line) · \(pictures)")
    }
}

/// Where to rewind to: your messages, latest first, picked with the arrows and Return (or a click); Esc closes it.
/// The pick opens RewindCard for the how.
private struct RewindPicker: View {
    let messages: [ConversationItem]
    let close: () -> Void
    let pick: (ConversationItem) -> Void
    @State private var index = 0
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Rewind to").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(messages.count) message\(messages.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { i, item in
                                Button { pick(item) } label: {
                                    HStack(spacing: 12) {
                                        Text(Self.gist(item)).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                                        if let date = item.date {
                                            Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                                                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                        NucleoIcon("chevron-right", size: 11).foregroundStyle(.tertiary).opacity(i == index ? 1 : 0)
                                    }
                                    .padding(.horizontal, 10).frame(height: 32)
                                    .background(i == index ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in if inside { index = i } }
                                .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .thinScrollbar(outset: 2)
                    .scrollIndicators(.never)
                    // As tall as its rows, up to nine: no room left under a short list.
                    .frame(height: 12 + 33 * CGFloat(min(messages.count, 9)) - 1)
                    .onChange(of: index) { if index < messages.count { proxy.scrollTo(messages[index].id) } }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 14) {
                    key("↑↓", "Choose")
                    key("↩", "Pick")
                    key("esc", "Close")
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .frame(width: 460, alignment: .leading)
            .card()
            .compositingGroup()
            .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
        }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: index = min(index + 1, messages.count - 1); return nil // ↓
                case 126: index = max(index - 1, 0); return nil // ↑
                case 36, 76: if index < messages.count { pick(messages[index]) }; return nil // Return
                case 53: close(); return nil
                default: return event
                }
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    /// A key and what it does, as the footer of a menu names them.
    private func key(_ cap: String, _ does: String) -> some View {
        HStack(spacing: 5) {
            Text(cap).font(.system(size: 10.5, weight: .medium)).monospacedDigit().padding(.horizontal, 5).frame(height: 17)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
            Text(does).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    /// The message's first line, its image tokens read as words ("an image", "2 images").
    private static func gist(_ item: ConversationItem) -> String {
        guard case let .user(text, images) = item.kind else { return "" }
        let words = ConversationItem.from(text)?.text ?? text
        let line = words.replacingOccurrences(of: #"\s*\[Image #\d+\]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let pictures = images.isEmpty ? "" : (images.count == 1 ? "an image" : "\(images.count) images")
        return line.isEmpty ? (pictures.isEmpty ? words : pictures.prefix(1).uppercased() + pictures.dropFirst()) : (pictures.isEmpty ? line : "\(line) · \(pictures)")
    }
}

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
            .compositingGroup()
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
                    .buttonStyle(.plain).tip("Back")
                    TextField("Find a scratchpad", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                        .onSubmit { if let first = found.first { pad(first) } }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle()).onTapGesture { searching = true }
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
    /// A colour for its icon and words, for a choice that should stand out (Unrestricted, orange as in the details).
    var tint: Color? = nil
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
                    NucleoIcon(symbol, size: 13).foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                }
                Text(label).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? (prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
            }
            // As tall as the + and Send beside it (28), so the row's pills are one size.
            .padding(.horizontal, 8).frame(height: 28)
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

    /// A task's choices: its own provider's models, then each provider that can take it over (ConversationView.takeOver).
    /// `chosen` is the (provider, model id) in effect; no id means the provider's first.
    static func taskModels(_ conversation: Conversation, chosen: (Provider, String?), pick: @escaping (Provider, SpawnChoice) -> Void) -> [SelectorSection] {
        let providers = [conversation.provider] + ConversationView.takeOver.filter { $0 != conversation.provider }
        return models(providers, selected: { provider, id in
            provider == chosen.0 && (id == (chosen.1 ?? "") || (chosen.1 == nil && id == (catalogue(provider).first?.id ?? "")))
        }, pick: pick)
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
    /// A menu's groups (SelectorKind.menu): each a section, drawn one under another with a line between.
    static func menu(_ groups: [[(id: String, title: String, glyph: String, selected: Bool, pick: () -> Void)]]) -> [SelectorSection] {
        groups.enumerated().map { index, rows in
            SelectorSection(id: "group-\(index)", title: "", icon: nil, rows: rows.map { row in
                SelectorRow(id: row.id, title: row.title, provider: nil, providerIcon: nil, detail: nil, context: nil, levels: [],
                            defaultLevel: nil, modelID: nil, selected: row.selected, pick: row.pick, glyph: row.glyph)
            })
        }
    }

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
    /// The workspace the task starts in: the one shown, unless picked.
    @State private var into = ""
    /// The workspace's own folders first, then the rest (Zero's are those no other claims).
    private var folders: [String] {
        let owned = workspace.workspaces.first { $0.id == (into.isEmpty ? workspace.current : into) }?.folders ?? []
        let all = Projects.folders
        return owned.filter(all.contains) + all.filter { !owned.contains($0) }
    }

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
                                 symbol: permissions == .auto ? "wand-sparkle" : "bolt-lightning:glyph", tint: permissions == .auto ? nil : .orange) {
                        ComposerRows.list("Permissions", [
                            ("auto", "Auto", "\(chosen.title) decides what's safe, and asks you the rest", permissions == .auto, { permissions = .auto }),
                            ("unrestricted", "Unrestricted", "Anything, without asking", permissions == .unrestricted, { permissions = .unrestricted }),
                        ])
                    }
                    ComposerChip(id: "new.agent", label: agentLabel, symbol: "terminal", icon: chosen.mark, kind: .runtime, prominent: true, rows: {
                        ComposerRows.models(Provider.allCases, selected: { provider, id in
                            provider == chosen && (id == model || (model.isEmpty && id == (ComposerRows.catalogue(provider).first?.id ?? "")))
                        }, pick: { picked, choice in
                            provider = picked.rawValue
                            model = choice.id
                            if !choice.levels.contains(where: { $0.id == effort }) { effort = "" }
                        })
                    }, level: { id in id == "\(chosen.rawValue)/\(model)" && !effort.isEmpty ? effort : nil }, setLevel: { _, level in effort = level })
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: 680) // the same column as a task's composer
            .padding(.horizontal, 36).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if !folders.contains(project) { project = folders.first ?? "" }
            if let kept = Drafts.load("new") { prompt = kept.text; images = kept.images }
            // Started from something saved for later: its words, over whatever was being written.
            if let waiting = workspace.pendingDrafts.removeValue(forKey: "new") { prompt = waiting }
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
                // Started from one workspace into another: the lead is there, and so are the workers it starts.
                if workspace.workspaces.count > 1 {
                    ComposerChip(id: "new.workspace", label: workspace.workspaces.first { $0.id == into }?.name ?? workspace.currentWorkspace.name, symbol: "layers") {
                        ComposerRows.list("Workspace", workspace.workspaces.map { w in (w.id, w.name, nil, w.id == into, { into = w.id }) })
                    }
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

    /// "Opus 5.5 · High": the model, its provider as the chip's icon. None picked, the provider's first; a provider with
    /// no catalogue (OpenCode) by its name.
    private var agentLabel: String {
        [models.first { $0.id == model }?.name ?? (model.isEmpty ? (models.first?.name ?? chosen.title) : model), effort.isEmpty ? nil : effortLabel(effort, short: true)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The chosen provider's models, from its CLI's own cache.
    private var models: [SpawnChoice] { ComposerRows.catalogue(chosen) }

    private func start() {
        let (text, attached) = ImageToken.compact(prompt.trimmingCharacters(in: .whitespacesAndNewlines), images: images.map(\.path))
        guard !text.isEmpty || !attached.isEmpty, !starting else { return }
        starting = true
        Task {
            // The model the chip shows: none picked, it shows the provider's first, so that's the one asked for. Left
            // to itself the provider would start on its own default, and the task would change model as it began.
            let shown = model.isEmpty ? (models.first?.id ?? "") : model
            if let id = await workspace.start(provider: chosen, cwd: project, prompt: text, images: attached, model: shown.isEmpty ? nil : shown,
                                              effort: effort.isEmpty ? nil : effort, permissions: permissions, workspace: into.isEmpty ? workspace.current : into) {
                prompt = ""
                images = []
                into = ""
                started(id)
            }
            starting = false
        }
    }
}

/// The system's blur of what's behind the window (a sidebar's material), solid when the window isn't the active one.
/// In full screen there's nothing behind it to blur (it comes out black), so it's solid there too.
struct BehindWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> Blur { Blur() }
    func updateNSView(_ view: Blur, context: Context) {}

    final class Blur: NSVisualEffectView {
        private var watching: [Any] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            material = .sidebar
            blendingMode = .behindWindow
            state = .followsWindowActiveState
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching.forEach(NotificationCenter.default.removeObserver)
            watching = []
            guard let window else { return }
            let update = { [weak self, weak window] in
                guard let self, let window else { return }
                state = window.styleMask.contains(.fullScreen) ? .inactive : .followsWindowActiveState
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                watching.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in MainActor.assumeIsolated(update) })
            }
            update()
        }
    }
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
        // Agents by their latest ask, newest first. Solo's agents that are gone (its process ended) with nothing open
        // are history, not agents: their asks stay under Answered, their names leave the list (they carried the same
        // session titles Zero's tasks do, and read as doubles).
        let agents = asks.reversed().reduce(into: [String]()) { names, ask in if !names.contains(ask.agent.name) { names.append(ask.agent.name) } }
            .filter { name in
                guard name.hasPrefix("solo-"), controller.store.offline.contains(name) else { return true }
                return waiting.contains { $0.agent.name == name }
            }
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

/// A task's status in words, beside the details pane: what it's blocked on or where it is and, blocked on an ask, the
/// inbox's own card for it, to answer right there. Zero's own card, drawn at once.
private struct StatusCard: View {
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

