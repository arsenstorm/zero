import AppKit
import Observation
import SwiftUI
import ZeroCore

/// The small pin that marks whichever control the inbox is pinned on.
struct PinBadge: View {
    var body: some View { NucleoIcon("pin-tack", size: 10).foregroundStyle(.secondary).frame(width: 12, height: 12) }
}

/// The bar's outline: rounded on the left, and merging into the screen edge on the right through two concave
/// fillets above and below, like a tab grown out of the edge.
struct PillShape: InsettableShape {
    var radius: CGFloat = 22
    var fillet: CGFloat = 22
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> PillShape {
        var shape = self
        shape.inset += amount
        return shape
    }

    /// Insets apply on the left, top and bottom only; the right side pushes out past the screen edge so the
    /// closing segment, and any stroke on it, stays off screen.
    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX + inset, y0 = rect.minY + inset, h = rect.maxY - inset, w = rect.maxX + inset
        let r = fillet, R = radius
        var path = Path()
        path.move(to: CGPoint(x: w, y: y0))
        path.addArc(center: CGPoint(x: w - r, y: y0), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: x0 + R, y: y0 + r))
        path.addArc(
            center: CGPoint(x: x0 + R, y: y0 + r + R), radius: R, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: x0, y: h - r - R))
        path.addArc(center: CGPoint(x: x0 + R, y: h - r - R), radius: R, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: w - r, y: h - r))
        path.addArc(center: CGPoint(x: w - r, y: h), radius: r, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The edge pill: the count of open asks (a plain tray when none), then one dot per agent heard from recently.
/// Dots grow by transform only, so their centre never moves: 1.0 resting, 1.18 while hovered or selected.
struct PillView: View {
    let controller: InboxController
    let settings: Settings
    /// The board, to fold workers into their leads: one dot per lead, in the lead's own state, as the sidebar
    /// lists and draws them.
    var workspace: Workspace? = nil
    let openInbox: () -> Void
    let selectAgent: (String) -> Void
    let moveHere: () -> Void
    /// Hovering a control peeks: nil for the open asks, a name for that agent's timeline.
    let peek: (String?) -> Void
    /// The workspace control clicked: the workspaces, in the inbox's pane.
    var openWorkspaces: () -> Void = {}
    @State private var overWorkspace = false
    /// The settings button in the bar's foot (Settings › Inbox and bar), and the pointer on the bar that brings it out.
    @AppStorage("barFoot") private var barFoot = false
    @State private var overBar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A dot being dragged up or down the bar, and how far.
    @State private var drag: (name: String, y: CGFloat)?

    private let slot: CGFloat = 28

    init(
        controller: InboxController, settings: Settings, workspace: Workspace? = nil, openInbox: @escaping () -> Void,
        selectAgent: @escaping (String) -> Void, moveHere: @escaping () -> Void,
        peek: @escaping (String?) -> Void = { _ in }, openWorkspaces: @escaping () -> Void = {},
        previewHovered: String? = nil
    ) {
        self.controller = controller; self.settings = settings; self.workspace = workspace
        self.openInbox = openInbox; self.selectAgent = selectAgent; self.moveHere = moveHere; self.peek = peek
        self.openWorkspaces = openWorkspaces
    }

    /// Every agent that has spoken and has not been closed, with its status. Expired asks don't count. A worker's
    /// agent (its session under a lead, by the board) is no dot of its own: it shows under its lead in the sidebar.
    private var agents: [(String, AgentStatus)] { controller.barAgents(settings: settings, workspace: workspace) }

    /// The sidebar's sort and dragged order, shared: the bar lists the tasks as the sidebar does.
    @AppStorage("taskSort") private var taskSort = BoardRow.Sort.state
    @AppStorage("taskOrder") private var taskOrder = ""
    /// The dots pinned to the bar, for "Pinned tasks only" (the sidebar's menu pins them too).
    @AppStorage("barPinned") private var barPinned = ""

    /// A dot: one of Zero's tasks, drawn as the sidebar draws it, or an agent outside Zero (a terminal's) with asks.
    private enum Mark: Equatable { case task(BoardRow.State, why: String), agent(AgentStatus) }

    /// The bar's dots: this workspace's tasks as the sidebar lists them (its order, its icons), then the agents
    /// outside Zero that have asks; those the user's choice of agents (Settings › Inbox and bar) keeps. Built from
    /// the agents with asks alone, it showed other things than the sidebar, in other shapes.
    private func dots(_ agents: [(String, AgentStatus)]) -> [(String, Mark)] {
        let mode = settings.barAgents
        guard mode != .none else { return [] }
        let pinned = BarPins.set(barPinned)
        let rows =
            workspace.map { w in BoardRow.sorted(w.board.filter { $0.workspace == w.current }, by: taskSort, order: taskOrder) } ?? []
        // A lead needs you when its team does (a worker's ask), though its dot draws the lead's own state.
        let tasks = rows.filter { mode.shows("zerod-" + $0.session, needsYou: $0.state.needsYou || $0.ownState.needsYou, pinned: pinned) }
        let others = agents.filter {
            !$0.0.hasPrefix("zerod-") && mode.shows($0.0, needsYou: [.needsYou, .handed, .trouble].contains($0.1), pinned: pinned)
        }
        // The lead's own state, as the sidebar's icon: the team's (a worker's trouble) drew another icon than the sidebar.
        return tasks.map { ("zerod-" + $0.session, Mark.task($0.ownState, why: $0.why)) } + others.map { ($0.0, Mark.agent($0.1)) }
    }

    /// The parts on, in the user's order; one with nothing to show (a lone workspace, no dots) takes no room.
    private func parts(dots: [(String, Mark)]) -> [BarPart] {
        settings.barParts.filter { part in
            switch part {
            case .inbox: settings.shows(.inbox)
            case .workspaces: settings.shows(.workspaces) && (workspace?.workspaces.count ?? 0) > 1
            case .agents: !dots.isEmpty
            }
        }
    }

    private func scale(_ name: String) -> CGFloat { controller.agentFilter == name ? 13 / 11 : 1 }

    /// Where the dragged dot would land right now.
    private func dropIndex(in names: [String]) -> Int? {
        guard let drag, let from = names.firstIndex(of: drag.name) else { return nil }
        return max(0, min(names.count - 1, from + Int((drag.y / slot).rounded())))
    }

    /// While dragging, the dots between the start slot and the drop slot step aside by one slot.
    private func shift(of name: String, in names: [String]) -> CGFloat {
        guard let drag, drag.name != name, let from = names.firstIndex(of: drag.name),
            let to = dropIndex(in: names), let i = names.firstIndex(of: name)
        else { return 0 }
        if from < to, i > from, i <= to { return -slot }
        if from > to, i >= to, i < from { return slot }
        return 0
    }

    var body: some View {
        // Once a redraw: worked out from every ask the store holds, four reads of it cost the bar a frame.
        let dots = dots(agents)
        let names = dots.map(\.0)
        let parts = parts(dots: dots)
        VStack(spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.element) { index, part in
                // The dots set apart from the controls, on whichever side they meet them.
                if index > 0, part == .agents || parts[index - 1] == .agents {
                    Rectangle().fill(Theme.stroke).frame(width: 18, height: 1).padding(.vertical, 4)
                }
                switch part {
                case .inbox: inboxSlot
                case .workspaces: workspace.map(workspaceSlot)
                case .agents: ForEach(dots, id: \.0) { name, mark in agentDot(name, mark, among: names) }
                }
            }
        }
        .onChange(of: names, initial: true) { controller.barOrder = $1 }
        .padding(.vertical, 8 + 22).padding(.horizontal, 6)
        .background(PillShape().fill(Theme.pill))
        .overlay(PillShape().strokeBorder(Theme.stroke, lineWidth: 1))
        .onHover { overBar = $0 }
        // In the bottom fillet's hollow: centred on its centre, the rect's bottom edge, 6 pt short of its radius.
        .overlay(alignment: .bottom) {
            if barFoot { BarFoot(barHovered: overBar, away: controller.panelOpen).offset(y: BarFoot.size / 2) }
        }
        // Nothing switched on, or nothing to show: no bar at all, rather than an empty tab at the edge.
        .opacity(parts.isEmpty ? 0 : 1)
        // The bar's drawn height, which the inbox uses for its scroll limits.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            controller.barHeight = $0
        }
        // Outermost on purpose: placed inside, only the dots would animate and the shape would snap.
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: names)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: parts)
        // Behind the dots, so a dot's own menu (in front) answers on a dot and this one everywhere else on the bar.
        .background {
            RightClick {
                ZeroContextMenu.open("bar") {
                    [
                        [
                            MenuItem("Customise bar…", "sliders", action: BarFoot.customise),
                            MenuItem("Open log", "file-content") { NSWorkspace.shared.open(Paths.log) },
                        ],
                        [
                            MenuItem("Settings…", "gear") { (NSApp.delegate as? AppDelegate)?.openSettings() },
                            MenuItem("Quit Zero", "power-off") { NSApp.terminate(nil) },
                        ],
                    ]
                }
            }
        }
    }

    private var inboxSlot: some View {
        let waiting = controller.store.open.count
        let selected = controller.agentFilter
        return NucleoIcon("inbox", size: 15)
            .foregroundStyle(selected == nil && !controller.newAgentOpen ? .primary : .secondary)
            .overlay(alignment: .topTrailing) {
                if controller.pinned && selected == nil && !controller.newAgentOpen {
                    PinBadge().offset(x: 4, y: -6)
                } else if waiting > 0 {
                    Circle().fill(AgentStatus.needsYou.color).frame(width: 7, height: 7).offset(x: 3, y: -3)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                controller.barSlots[InboxController.inboxSlot] = $0
            }
            .onDisappear { controller.barSlots[InboxController.inboxSlot] = nil }
            .onTapGesture(perform: openInbox)
            .tip("Open asks")
    }

    /// The workspace the bar lists (and the window shows): its glyph; a click opens the others beside the bar.
    private func workspaceSlot(_ workspace: Workspace) -> some View {
        // Under the pointer, the chevron the phone's selector has: it switches, it isn't a workspace's own button.
        Group {
            if overWorkspace {
                NucleoIcon("chevron-expand-y", size: 15)
            } else {
                WorkspaceGlyph(glyph: workspace.currentWorkspace.glyph, size: 15)
            }
        }
        .foregroundStyle(controller.workspacesOpen || overWorkspace ? .primary : .secondary)
        .overlay(alignment: .topTrailing) {
            if controller.pinned && controller.workspacesOpen { PinBadge().offset(x: 4, y: -6) }
        }
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .onHover { overWorkspace = $0 }
        // A slot of the bar's, as its others: the pointer on it opens its view in the inbox's pane.
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            controller.barSlots[InboxController.workspacesSlot] = $0
        }
        .onDisappear { controller.barSlots[InboxController.workspacesSlot] = nil }
        .onTapGesture(perform: openWorkspaces)
        .tip(workspace.currentWorkspace.name)
    }

    private func agentDot(_ name: String, _ mark: Mark, among names: [String]) -> some View {
        Group {
            switch mark {
            // The sidebar's own icon for the task's state, at its size.
            case .task(let state, let why): TaskStateIcon(state: state).font(.system(size: 12)).tip(why)
            case .agent(let status):
                Group { if status == .working { Spinner() } else { Circle().fill(status.color) } }.frame(width: 11, height: 11)
            }
        }
        .frame(width: 14, height: 14)
        .overlay(alignment: .topTrailing) {
            if controller.pinned && controller.agentFilter == name { PinBadge().offset(x: 4, y: -6) }
        }
        .scaleEffect(scale(name))
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: scale(name))
        .offset(y: drag?.name == name ? drag!.y : shift(of: name, in: names))
        .animation(drag?.name == name || reduceMotion ? nil : .snappy(duration: 0.2), value: dropIndex(in: names))
        // The whole slot, not just the dot, answers the pointer: full bar width, and the gap halves
        // above and below it, so the slots meet and there is no dead space between dots.
        .frame(width: 32, height: slot)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            controller.barSlots[name] = $0
        }
        // Gone from the bar, gone from its slots: a pointer where it was peeks nothing.
        .onDisappear { controller.barSlots[name] = nil }
        .zIndex(drag?.name == name ? 1 : 0)
        .tip(controller.store.displayName(of: name))
        // A right-click: Zero's own menu by the dot, with the task's actions under its name (not the system's menu,
        // which said "Remove zerod-01a1…").
        .overlay { RightClick { menu(name) } }
        // One gesture for click and drag, so they never compete: a press that moves under 4 pt selects;
        // a longer one drags the dot with the pointer and drops it into the nearest slot.
        // Global space: the dot moves with the drag, so a local translation would cancel itself out.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if abs(value.translation.height) >= 4 || drag != nil { drag = (name, value.translation.height) }
                }
                .onEnded { _ in
                    guard drag != nil else { open(name); return }
                    drop(name, among: names)
                }
        )
        .transition(.opacity)
    }

    /// A dot's menu, in Zero's selector by the dot: a task's own actions (open it, pause or resume it, move it to Later,
    /// archive it), or for an agent outside Zero, closing it.
    private func menu(_ name: String) {
        let window = NSApp.window(withWindowNumber: NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0))
        guard let slot = controller.barSlots[name] else { return }
        let width = SelectorView.width(.menu)
        // Beside the bar, level with the dot, on the side with room (the bar's panel is the window's width).
        let anchor = CGRect(x: slot.minX - width - 8, y: slot.minY, width: width, height: slot.height)
        WorkspaceSelector.shared.toggle("bar-\(name)", kind: .menu, anchor: anchor, in: window) { [controller, workspace] in
            var rows: [[(id: String, title: String, glyph: String, selected: Bool, pick: () -> Void)]] = []
            if name.hasPrefix("zerod-"), let workspace {
                let id = String(name.dropFirst("zerod-".count))
                let open: () -> Void = {
                    if let url = URL(string: "zero://task/" + id) { (NSApp.delegate as? AppDelegate)?.openZeroURL(url) }
                }
                rows.append([("open", "Open", "arrow-up-right", false, open)])
                rows.append([pinRow(name)])
                // Named, not inline in a ternary of tuples: CI's compiler found `Task` there ambiguous.
                let paused = workspace.isPaused(id)
                let toggle: () -> Void = {
                    Task { if paused { await workspace.unpause([id]) } else { await workspace.pause([id]) } }
                }
                rows.append([
                    (paused ? "resume" : "pause", paused ? "Resume" : "Pause", paused ? "media-play" : "circle-pause", false, toggle),
                    ("later", "Save for later", "bookmark", false, { Task { await workspace.saveForLater(id) } }),
                ])
                rows.append([
                    (
                        "archive", "Archive…", "archive", false,
                        {
                            open(); workspace.archiving = id
                        }
                    )
                ])
            } else {
                rows.append([pinRow(name)])
                rows.append([
                    (
                        controller.store.canStop(name) ? "stop" : "remove", controller.store.canStop(name) ? "Remove and stop" : "Remove",
                        "trash", false,
                        { controller.store.closeAgent(name) }
                    )
                ])
            }
            return ComposerRows.menu(rows)
        }
    }

    /// Pinned, the dot stays on the bar when it shows pinned tasks only.
    private func pinRow(_ name: String) -> (id: String, title: String, glyph: String, selected: Bool, pick: () -> Void) {
        let pinned = BarPins.set(barPinned).contains(name)
        return ("pin", pinned ? "Unpin from bar" : "Pin to bar", "pin-tack", false, { barPinned = BarPins.toggle(name, in: barPinned) })
    }

    /// The dragged dot let go: the bar's order with it moved into the slot it's over.
    /// A click: a task's asks in the inbox when it has some, else the task itself in the window, as the sidebar opens
    /// it; an agent outside Zero, its asks.
    private func open(_ name: String) {
        let asking = controller.store.asks.contains { !$0.state.isFinal && $0.agent.name == name }
        if name.hasPrefix("zerod-"), !asking, let url = URL(string: "zero://task/" + name.dropFirst("zerod-".count)) {
            (NSApp.delegate as? AppDelegate)?.openZeroURL(url)
        } else {
            selectAgent(name)
        }
    }

    /// Dropped: tasks reorder the sidebar too (its order is theirs), agents outside Zero their own.
    private func drop(_ name: String, among names: [String]) {
        guard let from = names.firstIndex(of: name), let to = dropIndex(in: names) else { drag = nil; return }
        var order = names
        order.remove(at: from)
        order.insert(name, at: to)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            if name.hasPrefix("zerod-") {
                taskOrder = order.filter { $0.hasPrefix("zerod-") }.map { String($0.dropFirst("zerod-".count)) }.joined(separator: "\n")
                taskSort = .manual
            } else {
                settings.agentOrder = order.filter { !$0.hasPrefix("zerod-") }
            }
            drag = nil
        }
    }
}

/// "claude-120" speaks as "Claude", "codex-12" as "Codex"; a name without a process number speaks as itself.
func speaker(_ agent: String) -> String {
    let parts = agent.split(separator: "-")
    guard parts.count > 1, let last = parts.last, last.allSatisfy(\.isNumber) else { return agent }
    let base = parts.dropLast().joined(separator: "-")
    return base.prefix(1).uppercased() + base.dropFirst()
}
