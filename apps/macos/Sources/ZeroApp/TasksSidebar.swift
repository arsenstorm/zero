import AppKit
import SwiftUI
import ZeroCore

struct TasksSidebar: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    private var place: Navigation.Place {
        get { navigation.place }
        nonmutating set { navigation.place = newValue }
    }
    /// Leads whose workers are folded away, one per line.
    @AppStorage("foldedLeads") private var folded = ""
    /// Where each lead's row starts down the window's task area: where its hover card goes.
    /// Each row's top, for the peek card on hover: kept where writing it doesn't redraw the sidebar (rows moving in an
    /// animation write theirs every frame).
    @State private var tops = Tops()
    final class Tops {
        var y: [String: CGFloat] = [:];
        subscript(_ id: String) -> CGFloat? {
            get { y[id] }
            set { y[id] = newValue }
        }
    }
    /// How the tasks are ordered: by state (the board's own order), by name, or as they were dragged.
    @AppStorage("taskSort") private var sort = BoardRow.Sort.state
    /// The dragged order, one lead per line; tasks not in it yet go on top.
    @AppStorage("taskOrder") private var order = ""
    @State private var sortHovered = false
    /// The sort button's frame, where Zero's selector opens its menu.
    @State private var sortAnchor = CGRect.zero
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
            let i = ids.firstIndex(of: lead)
        else { return 0 }
        if from < to, i > from, i <= to { return -height(drag.lead) }
        if to < from, i >= to, i < from { return height(drag.lead) }
        return 0
    }

    /// A press that moves 4 pt drags the lead; let go, it takes the slot it's over and the order is manual from then
    /// on. False if it never moved: a click.
    private func reorder(_ lead: String, in rows: [BoardRow]) -> TaskRow.Reorder {
        TaskRow.Reorder(
            changed: { y in if abs(y) >= 4 || drag != nil { drag = (lead, y) } },
            ended: {
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

    /// Leads that aren't on the board: finished and gone offline with nothing for the user. One running isn't (a task
    /// just started, before the board has it, is among the tasks: `starting`); one being archived isn't either.
    private func earlier(_ all: [Conversation]) -> [Conversation] {
        let ids = Set(all.map(\.id)), onBoard = Set(workspace.board.map(\.session))
        let saved = workspace.savedForLater
        return all.filter { lead in
            (lead.parent.map { !ids.contains($0) } ?? true) && !onBoard.contains(lead.id) && !workspace.putAway.contains(lead.id)
                && !saved.contains(lead.id) && lead.status == .offline
        }.reversed()
    }

    /// Leads started and running that the board hasn't got to yet: rows of their own, Working, until it has.
    private func starting(_ all: [Conversation]) -> [BoardRow] {
        let ids = Set(all.map(\.id)), onBoard = Set(workspace.board.map(\.session))
        return all.filter { lead in
            (lead.parent.map { !ids.contains($0) } ?? true) && !onBoard.contains(lead.id) && !workspace.putAway.contains(lead.id)
                && lead.status != .offline && workspace.workspace(of: lead) == workspace.current
        }
        .compactMap { BoardRow.starting(session: $0.id, task: Workspace.label(of: $0), workspace: workspace.current) }
    }

    @State private var namingWorkspace = false

    /// The heading's selector: the workspaces, the current one marked; New workspace… and Workspace settings… under them.
    private func workspaceRows() -> [SelectorSection] {
        ComposerRows.menu([
            workspace.workspaces.map { w in (w.id, w.name, w.glyph, w.id == workspace.current, { workspace.current = w.id }) },
            [
                ("new", "New workspace…", "plus", false, { namingWorkspace = true }),
                (
                    "settings", "Workspace settings…", "sliders", false,
                    {
                        SettingsView.requested = .workspaces; place = .settings
                    }
                ),
            ],
        ])
    }

    var body: some View {
        SidebarColumn(title: workspace.currentWorkspace.name, picker: workspaceRows, glyph: workspace.currentWorkspace.glyph) {
            SidebarItem("New task", icon: "compose", selected: place == .home) { place = .home }
                .keyboardShortcut("n", modifiers: .command)
            SidebarItem("All tasks", icon: "list-checkbox", selected: place == .board) { place = .board }
            // Each lead's workers looked up once per update, not by searching every task for every row.
            let all = workspace.conversations
            let workersOf = Dictionary(grouping: all.filter { $0.parent != nil }, by: { $0.parent ?? "" })
            // Not before the first board: until then every lead looks like it isn't on it.
            let earlier = workspace.board.isEmpty ? [] : earlier(all).filter { workspace.workspace(of: $0) == workspace.current }
            ScrollView { taskList(all: all, workersOf: workersOf, earlier: earlier) }
                .thinScrollbar(outset: 10, remember: "sidebar.tasks") // in the sidebar's padding: at its edge, clear of the rows
                .scrollIndicators(.never)
                .zeroDialog(isPresented: $namingWorkspace) {
                    NameSheet(title: "New workspace", name: "", action: "Create") { name in
                        Task {
                            if let error = await workspace.saveWorkspace(ZerodLink.Workspace(name: name)) {
                                NSSound.beep(); Log.write("workspace: \(error)")
                            }
                        }
                    }
                }
                .zeroDialog(item: $renaming) { task in
                    NameSheet(title: "Rename", name: task.name, action: "Rename") { name in
                        Task { await workspace.rename(task.id, to: name, ticket: task.ticket) }
                    }
                }
                .zeroDialog(item: $pairing) { task in
                    PairSheet(task: task, others: workspace.board.filter { $0.session != task.id }) { other in
                        Task { await workspace.introduce(task.id, to: other) }
                    }
                }
                .background { taskShortcuts }
                // Soft edges, as the conversation has: more above, more below.
                .softEdges(top: 20, bottom: 28)
                // The list has the sidebar's whole height: what's said about the daemon lies over its foot, on a fade, and
                // the last task scrolls clear of it.
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
    }

    /// Not lazy: a lazy stack reuses row views, and a task added at the top showed a reused row whose state icon
    /// wasn't its own (or none). A sidebar holds tens of tasks, not thousands.
    private func taskList(all: [Conversation], workersOf: [String: [Conversation]], earlier: [Conversation]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            tasksHeader
            if workspace.board.isEmpty {
                Text("No tasks").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 10)
            }
            leads(all: all, workersOf: workersOf)
            if !earlier.isEmpty {
                SidebarHeading(text: "Earlier")
                ForEach(earlier) { lead in
                    SidebarItem(Workspace.label(of: lead), selected: place == .task(lead.id)) { place = .task(lead.id) }
                        .zeroContextMenu("task-\(lead.id)") { menu(lead.id, name: Workspace.label(of: lead), ticket: lead.ticket) }
                }
            }
        }
        // The last task clear of the fade at the foot.
        .padding(.bottom, 36)
        // Tasks coming and going move the rest smoothly, Earlier's included.
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.25),
            value: (workspace.board.map(\.session) + starting(all).map(\.session) + earlier.map(\.id)))
    }

    /// The heading where every sidebar's is, its sort button centred over the tasks' state icons below.
    private var tasksHeader: some View {
        HStack(spacing: 0) {
            Text("Tasks").font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 10)
            Spacer()
            Button {
                WorkspaceSelector.shared.toggle("tasks", kind: .menu, anchor: sortAnchor, rows: taskMenuRows)
            } label: {
                NucleoIcon("sliders", size: 13).foregroundStyle(.secondary).frame(width: 24, height: 24)
                    .background(
                        sortHovered || WorkspaceSelector.shared.open == "tasks" ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { sortHovered = $0 }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                sortAnchor = $0
            }
            // A row's state icon is 14 pt, 10 pt in from the edge: its centre is 17 pt in, as this 24 pt button's.
            .padding(.trailing, 5).tip("Sort, pause or unarchive tasks")
            .zeroDialog(isPresented: $showingArchive) { ArchiveSheet(workspace: workspace) }
        }
        // A 16 pt heading line with 18 above and 6 below, as SidebarHeading has, now 24 pt for the button.
        .padding(.top, 14).padding(.bottom, 2)
    }

    /// The Tasks heading's menu, in Zero's selector: how they're sorted, pausing them, and the archive.
    private func taskMenuRows() -> [SelectorSection] {
        // This workspace's tasks: for the night, or while you're away.
        let here = workspace.board.filter { $0.workspace == workspace.current }
        let running = here.filter { $0.ownState != .paused }.map(\.session)
        let paused = here.filter { $0.ownState == .paused }.map(\.session)
        let sorts: [(BoardRow.Sort, String, String)] = [
            (.state, "State", "circle-check"), (.name, "Name", "heading-1"),
            (.manual, "Manual (drag to arrange)", "ordered-list"),
        ]
        var pausing: [(id: String, title: String, glyph: String, selected: Bool, pick: () -> Void)] = []
        if !running.isEmpty {
            pausing.append(("pause", "Pause all tasks", "circle-pause:glyph", false, { Task { await workspace.pause(running) } }))
        }
        if !paused.isEmpty {
            pausing.append(
                ("resume", "Resume paused tasks", "arrow-rotate-clockwise:glyph", false, { Task { await workspace.unpause(paused) } }))
        }
        return ComposerRows.menu(
            [
                sorts.map { option, title, glyph in (option.rawValue, title, glyph, sort == option, { sort = option }) },
                pausing,
                [("archive", "Archived tasks…", "layers", false, { showingArchive = true })],
            ].filter { !$0.isEmpty })
    }

    /// The rows in a stack of their own, masked at its top: one arriving slides in from under the heading
    /// as the rest move down, rather than across it. The mask reaches well below, for the archive card.
    private func leads(all: [Conversation], workersOf: [String: [Conversation]]) -> some View {
        let folded = Set(folded.split(separator: "\n").map(String.init))
        let rows = sorted(workspace.board.filter { $0.workspace == workspace.current } + starting(all))
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(rows) { row in
                leadGroup(row, workers: workersOf[row.session] ?? [], open: !folded.contains(row.session), in: rows)
            }
        }
        .mask(alignment: .top) { Rectangle().padding(.bottom, -800) }
    }

    /// A lead and its workers move as one, with no gap between them: the branch runs unbroken.
    private func leadGroup(_ row: BoardRow, workers: [Conversation], open: Bool, in rows: [BoardRow]) -> some View {
        let ids = rows.map(\.session)
        return VStack(alignment: .leading, spacing: 0) {
            TaskRow(
                title: row.task, state: row.ownState, selected: place == .task(row.session) && navigation.worker == nil,
                fold: workers.isEmpty ? nil : open,
                action: {
                    // Its worker shown, the same task: back to the lead.
                    place = .task(row.session)
                    navigation.worker = nil
                }, toggle: { toggle(row.session) }, reorder: reorder(row.session, in: rows)
            )
            .zeroContextMenu("task-\(row.session)") { menu(row.session, name: row.task, ticket: row.ticket) }
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named("tasks")).minY
            } action: {
                tops[row.session] = $0
            }
            .onHover { inside in TaskPeek.shared.hover(row.session, top: tops[row.session] ?? 0, inside: inside && drag == nil) }
            // Its workers, a row each. Its issues aren't rows (not tasks of their own, a row with nothing to open):
            // they're in its details pane.
            if open {
                ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
                    workerRow(worker, of: row, branch: index == workers.count - 1 ? .last : .middle)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            heights[row.session] = $0
        }
        .offset(y: drag?.lead == row.session ? drag!.y : shift(of: row.session, in: ids))
        .animation(drag?.lead == row.session || reduceMotion ? nil : .snappy(duration: 0.2), value: dropIndex(in: ids))
        // Asked to archive it: the question under its row, over the rows below.
        .overlay(alignment: .topLeading) {
            if workspace.archiving == row.session {
                ArchiveCard(workspace: workspace, id: row.session) { if place == .task(row.session) { place = .home } }
                    .offset(y: (heights[row.session] ?? 30) + 4)
            }
        }
        .zIndex(drag?.lead == row.session ? 1 : workspace.archiving == row.session ? 2 : 0)
        // A task arriving slides in under the heading as the rest move down; one leaving fades.
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
    }

    private func workerRow(_ worker: Conversation, of row: BoardRow, branch: TaskRow.Branch) -> some View {
        TaskRow(
            title: Workspace.label(of: worker), state: row.member(worker.id)?.state ?? TaskRow.state(of: worker),
            selected: navigation.worker == worker.id,
            branch: branch,
            action: {
                place = .task(row.session)
                navigation.worker = worker.id
            }
        )
        // A worker's own menu, as its lead's: rename it, pause or stop it, archive it.
        .zeroContextMenu("worker-\(worker.id)") { workerMenu(worker) }
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named("tasks")).minY
        } action: {
            tops[worker.id] = $0
        }
        .onHover { inside in TaskPeek.shared.hover(worker.id, top: tops[worker.id] ?? 0, inside: inside && drag == nil) }
    }

    private func workerMenu(_ worker: Conversation) -> [[MenuItem]] {
        [
            [MenuItem("Rename…", "pen") { renaming = Renaming(id: worker.id, name: Workspace.label(of: worker), ticket: worker.ticket) }],
            [
                workspace.isPaused(worker.id)
                    ? MenuItem("Resume", "media-play") { Task { await workspace.unpause([worker.id]) } }
                    : MenuItem("Pause", "circle-pause") { Task { await workspace.pause([worker.id]) } }
            ]
                + (worker.status == .working || worker.status == .waiting
                    ? [MenuItem("Stop", "circle-xmark") { Task { await workspace.stop(worker.id) } }] : []),
            [MenuItem("Archive…", "archive") { workspace.archiving = worker.id }],
        ]
    }

    /// ⌘1 to ⌘9: the first nine tasks as the sidebar shows them (this workspace's, leads only), as a browser's tabs.
    private var taskShortcuts: some View {
        let rows = sorted(workspace.board.filter { $0.workspace == workspace.current }).prefix(9)
        return ForEach(Array(rows.enumerated()), id: \.element.session) { index, row in
            Button("") {
                place = .task(row.session); navigation.worker = nil
            }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }
        .hidden()
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
    /// Asked to work with another task: the one the menu was opened on.
    @State private var pairing: Renaming?

    private func menu(_ id: String, name: String, ticket: String?) -> [[MenuItem]] {
        // Move to: a group of its own (Zero's menus have no submenus), the workspace it's in left out.
        var moves =
            workspace.workspaces.count > 1
            ? workspace.workspaces.filter { $0.id != workspace.current }.map { w in
                MenuItem("Move to \(w.name)", "layers") { Task { await workspace.place(id, in: w.id) } }
            } : []
        if workspace.workspaces.count > 1, workspace.roster[id]?.workspace != nil {
            moves.append(MenuItem("Move to its folder's workspace", "folder") { Task { await workspace.place(id, in: nil) } })
        }
        return [
            [
                MenuItem("Rename…", "pen") { renaming = Renaming(id: id, name: name, ticket: ticket) },
                MenuItem("Work with another task…", "link") { pairing = Renaming(id: id, name: name, ticket: ticket) },
            ],
            moves,
            [
                workspace.isPaused(id)
                    ? MenuItem("Resume", "media-play") { Task { await workspace.unpause([id]) } }
                    : MenuItem("Pause", "circle-pause") { Task { await workspace.pause([id]) } },
                MenuItem("Save for later", "bookmark") { Task { await workspace.askToSaveForLater(id) } },
                MenuItem("Move to Later", "clock") {
                    Task {
                        if place == .task(id) { place = .home }; await workspace.moveToLater(id)
                    }
                },
            ],
            [MenuItem("Archive…", "archive") { workspace.archiving = id }],
        ]
    }

    /// At the foot, in a card of its own: the accounts used today and their usage; while Zero can't reach its daemon,
    /// that instead (on a fade, over the list's end).
    @ViewBuilder private var footer: some View {
        if !workspace.connected {
            NucleoLabel("Connecting to Zero's daemon…", icon: "plug", size: 12)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 10)
                .padding(.horizontal, 10).padding(.top, 22)
                .background(
                    LinearGradient(
                        stops: [.init(color: Theme.composer.opacity(0), location: 0), .init(color: Theme.composer, location: 0.5)],
                        startPoint: .top, endPoint: .bottom)
                )
                .padding(.horizontal, -10)
        } else {
            // In from the sidebar's edges by its inset (the column pads its content 10 at the sides, none below).
            UsageFooter(workspace: workspace) {
                SettingsView.requested = .signins; place = .settings
            }
            .padding(.horizontal, UsageFooter.inset - 10).padding(.vertical, UsageFooter.inset)
        }
    }
}

/// Two tasks to work together: the other picked from the board's, and both told about each other and how to reach it.
private struct PairSheet: View {
    let task: TasksSidebar.Renaming
    let others: [BoardRow]
    let pick: (String) -> Void
    @Environment(\.closeDialog) private var dismiss
    @State private var chosen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(text: "Work with another task")
            Text("\(task.name) and the task you pick each hear about the other and how to reach it, and settle between them what they can.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(others, id: \.session) { row in
                        Button {
                            chosen = row.session
                        } label: {
                            HStack {
                                Text(row.task).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                if chosen == row.session { NucleoIcon("check", size: 12) }
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(chosen == row.session ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .thinScrollbar()
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Work together", kind: .primary, enabled: chosen != nil) {
                    if let chosen { pick(chosen) }
                    dismiss()
                }
            }
        }
        .frame(width: 380)
    }
}
