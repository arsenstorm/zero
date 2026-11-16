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
    /// The mark clicked: that workspace, in Zero's window.
    var openWorkspace: (String) -> Void = { _ in }
    /// Another workspace's group folded to its mark, opened while the pointer is on it: after a moment's rest (a
    /// pass-through down the bar opens nothing), closed after a short grace (an overshoot doesn't collapse it).
    @State private var openGroup: String?
    @State private var hoverGroup: Task<Void, Never>?
    /// The groups as drawn (`follow`): they follow the board's, cutting when the window switched. A dot gone from the
    /// board keeps its last look here. Nil until the first draw, which takes the board's as they are.
    @State private var drawn: [BarGroup]?
    @State private var drawnDots: [String: Dot] = [:]
    /// The window's workspace as last drawn, so a switch is told from the bar changing on its own.
    @State private var drawnWindow: String?
    /// Set for the draw that follows the window switching: nothing comes or goes with a transition then.
    @State private var cutting = false
    /// The settings button in the bar's foot (Settings › Control bar), and the pointer on the bar that brings it out.
    @AppStorage("barFoot") private var barFoot = false
    @State private var overBar = false
    /// Bumped as a new ask comes in while the inbox is folded: its arc brightens once.
    @State private var inboxPulse = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A dot being dragged up or down the bar, and how far.
    @State private var drag: (name: String, y: CGFloat)?

    private let slot: CGFloat = 28

    init(
        controller: InboxController, settings: Settings, workspace: Workspace? = nil, openInbox: @escaping () -> Void,
        selectAgent: @escaping (String) -> Void, moveHere: @escaping () -> Void,
        peek: @escaping (String?) -> Void = { _ in }, openWorkspace: @escaping (String) -> Void = { _ in },
        previewHovered: String? = nil
    ) {
        self.controller = controller; self.settings = settings; self.workspace = workspace
        self.openInbox = openInbox; self.selectAgent = selectAgent; self.moveHere = moveHere; self.peek = peek
        self.openWorkspace = openWorkspace
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

    /// A dot and what the bar groups it by.
    private struct Dot {
        let mark: Mark
        let workspace: String?
        let running: Bool
        let waiting: Bool
        /// For VoiceOver: the task (or agent) and its state.
        let label: String
    }

    /// The bar's dots: every workspace's tasks as the sidebar lists them (its order, its icons), then the agents
    /// outside Zero that have asks; those the user's choice of agents (Settings › Control bar) keeps. Built from
    /// the agents with asks alone, it showed other things than the sidebar, in other shapes.
    private func dots(_ agents: [(String, AgentStatus)]) -> [(String, Dot)] {
        let mode = settings.barAgents
        guard mode != .none else { return [] }
        let pinned = BarPins.set(barPinned)
        let rows = workspace.map { BoardRow.sorted($0.board, by: taskSort, order: taskOrder) } ?? []
        // A lead needs you when its team does (a worker's ask), though its dot draws the lead's own state.
        let tasks = rows.filter { mode.shows("zerod-" + $0.session, needsYou: $0.state.needsYou || $0.ownState.needsYou, pinned: pinned) }
        let others = agents.filter {
            !$0.0.hasPrefix("zerod-") && mode.shows($0.0, needsYou: [.needsYou, .handed, .trouble].contains($0.1), pinned: pinned)
        }
        // The lead's own state, as the sidebar's icon: the team's (a worker's trouble) drew another icon than the sidebar.
        return tasks.map { row in
            (
                "zerod-" + row.session,
                Dot(
                    mark: .task(row.ownState, why: row.why), workspace: row.workspace, running: row.ownState == .working,
                    waiting: row.state.needsYou || row.ownState.needsYou,
                    label: "\(row.task), \(TaskStateIcon.look(row.ownState).name)")
            )
        }
            + others.map { name, status in
                let waiting = [.needsYou, .handed, .trouble].contains(status)
                return (
                    name,
                    Dot(
                        mark: .agent(status), workspace: nil, running: status == .working, waiting: waiting,
                        label: controller.store.displayName(of: name) + (waiting ? ", needs you" : ""))
                )
            }
    }

    /// The dots by workspace (`BarGroups`), in the rail's order.
    private func groups(_ dots: [(String, Dot)]) -> [BarGroup] {
        BarGroups.make(
            dots.map { BarGroups.Dot(name: $0.0, workspace: $0.1.workspace, running: $0.1.running, waiting: $0.1.waiting) },
            workspaces: workspace?.workspaces.map(\.id) ?? [], window: workspace?.current ?? "zero", from: settings.barAgentsFrom)
    }

    /// The parts on in the bar's body, in the user's order; one with nothing to show (no dots) takes no room. The
    /// inbox isn't one: it's the button in the top hollow.
    private func parts(groups: [BarGroup]) -> [BarPart] {
        settings.barParts.filter { $0 == .agents && !groups.isEmpty }
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
        let live = groups(dots)
        let groups = drawn ?? live
        let looks = drawnDots.merging(dots.map { ($0.0, $0.1) }, uniquingKeysWith: { _, now in now })
        // The dots on the bar now: a folded group's are not (nor are their slots).
        let names = groups.flatMap { !$0.folds || openGroup == $0.workspace ? $0.dots : [] }
        let parts = parts(groups: groups)
        let inbox = settings.shows(.inbox)
        let slim = parts.isEmpty
        // A group opened by the pointer grows the bar downward only: the bar sits centred in its panel, so it's moved
        // down by half of what it grew, and the mark under the pointer, the inbox and all above stay where they were.
        let shift =
            openGroup.flatMap { id in groups.first { $0.workspace == id && $0.folds } }
            .map { CGFloat($0.dots.count) * (slot + 2) / 2 } ?? 0
        Group {
            if slim {
                slimPair
            } else {
                // The buttons sit in the hollows, half over the body's ends: its fillets are centred on its edges.
                VStack(spacing: -barKnob / 2) {
                    if inbox { inboxKnob.zIndex(1) }
                    barBody(groups: groups, dots: looks)
                    if barFoot { settingsKnob.zIndex(1) }
                }
            }
        }
        .offset(y: reduceMotion ? 0 : shift)
        .onChange(of: reduceMotion ? 0 : shift, initial: true) { controller.barShift = $1 }
        .frame(width: 44)
        .onHover { overBar = $0 }
        .onChange(of: names, initial: true) { controller.barOrder = $1 }
        .onChange(of: live, initial: true) { _, now in follow(now, dots: looks) }
        // Nothing switched on: no bar at all, rather than an empty tab at the edge.
        .opacity(slim && !inbox ? 0 : 1)
        // The bar's drawn height, which the inbox uses for its scroll limits.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            controller.barHeight = $0
        }
        // Outermost on purpose: placed inside, only the dots would animate and the shape would snap. One motion on the
        // whole bar, the knobs' ease-out cubic: 220 ms as things come or open, 150 ms as they go (the board's changes
        // by `follow`, the same curve). Reduce Motion: no movement (the dots still fade in and out, by their own
        // transition).
        .animation(reduceMotion ? nil : barMotion(entering: openGroup != nil), value: openGroup)
        // Behind the dots, so a dot's own menu (in front) answers on a dot and this one everywhere else on the bar.
        .background {
            RightClick {
                ZeroContextMenu.open("bar") {
                    [
                        [
                            MenuItem("Customise bar…", "sliders", action: customiseBar),
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

    /// The dots, between the bar's curves, grouped by workspace; at least a slot tall, so the curves always fit.
    private func barBody(groups: [BarGroup], dots: [String: Dot]) -> some View {
        // One group, the window's: the bar as it always was, no mark and no segment.
        let marked = BarGroups.marked(groups)
        return VStack(spacing: 4) {
            ForEach(groups, id: \.workspace) { group in groupView(group, dots: dots, marked: marked) }
        }
        .frame(width: 32).frame(minHeight: 28)
        .padding(.vertical, 8 + 22).padding(.horizontal, 6)
        .background(PillShape().fill(Theme.pill))
        .overlay(PillShape().strokeBorder(Theme.stroke, lineWidth: 1))
    }

    /// A workspace's agents under its mark (the window's too, when more than one group shows): another workspace's
    /// folded to just the mark while nothing there waits on the user, and opened while the pointer rests on it. Open,
    /// its dots have a segment beside them at the screen's edge, neutral (the window's a little stronger): on the bar
    /// colour means state alone, the workspaces' own colours are the rail's and the window's. A click on the mark
    /// opens the workspace in Zero's window.
    private func groupView(_ group: BarGroup, dots: [String: Dot], marked: Bool) -> some View {
        let open = !group.folds || openGroup == group.workspace
        let byPointer = group.folds && openGroup == group.workspace
        let space =
            workspace?.workspaces.first { $0.id == group.workspace } ?? ZerodLink.Workspace(id: group.workspace, name: group.workspace)
        let summary = BarGroups.summary(name: space.name, group)
        return VStack(spacing: 2) {
            if marked {
                BarMark(workspace: space)
                    .frame(width: 32, height: slot)
                    .contentShape(Rectangle())
                    .onTapGesture { openWorkspace(group.workspace) }
                    .tip(summary, side: .left)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(summary)
                    .accessibilityHint("Opens the workspace in Zero's window")
                    .accessibilityAddTraits(.isButton)
                    .transition(arrival(byPointer: false))
            }
            if open {
                VStack(spacing: 2) {
                    ForEach(group.dots, id: \.self) { name in
                        if let dot = dots[name] {
                            agentDot(name, dot.mark, among: group.dots, byPointer: byPointer).accessibilityLabel(dot.label)
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if marked {
                        Capsule().fill(Color.secondary.opacity(group.window ? 0.7 : 0.35))
                            .frame(width: 3).padding(.vertical, 6).offset(x: 3)
                            .transition(arrival(byPointer: byPointer))
                    }
                }
            }
        }
        // The whole group, mark and dots, keeps it open, so the pointer can go down to its dots.
        .onHover { on in hover(group, on) }
        .transition(arrival(byPointer: false))
    }

    /// The pointer on a folded group or off it: open after 120 ms at rest on it (a pass-through down the bar opens
    /// nothing; straight from another open group's mark, at once, as a tooltip's neighbours do), and not while it heads
    /// into the open panel (the aim triangle); closed 200 ms after it leaves, unless it comes back.
    private func hover(_ group: BarGroup, _ on: Bool) {
        guard group.folds else { return }
        hoverGroup?.cancel()
        let id = group.workspace
        if on {
            guard openGroup != id else { return }
            let wait: Duration = openGroup == nil ? .milliseconds(120) : .zero
            hoverGroup = Task { @MainActor in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, !controller.barAiming else { return }
                openGroup = id
            }
        } else if openGroup == id {
            hoverGroup = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                if openGroup == id { openGroup = nil }
            }
        }
    }

    /// The board's groups drawn, by what changed them. The window switched (⌥N, the rail, a mark clicked): the bar
    /// cuts in one frame, as the window does, with nothing easing open or shut. The bar changed on its own (an agent
    /// came, went, moved workspace or changed state): its layout snaps and what came fades in (`arrival`); nothing
    /// travels or scales. Only the pointer opening a group eases (`openGroup`'s animation).
    private func follow(_ now: [BarGroup], dots: [String: Dot]) {
        let window = workspace?.current
        guard let was = drawn else { drawn = now; drawnDots = dots; drawnWindow = window; return }
        guard now != was else { return }
        drawnDots = dots
        guard window == drawnWindow else {
            drawnWindow = window
            // Transitions read `cutting` as the views come and go, so it's set a draw ahead of the groups, then put back.
            cutting = true
            DispatchQueue.main.async {
                drawn = now
                DispatchQueue.main.async { cutting = false }
            }
            return
        }
        drawn = now
    }

    /// The bar's one curve, the knobs' ease-out cubic: 220 ms in, 150 ms out.
    private func barMotion(entering: Bool) -> Animation { .timingCurve(0.33, 1, 0.68, 1, duration: entering ? 0.22 : 0.15) }

    /// How a dot, a mark or a segment comes and goes. Opened by the pointer: in from 0.9 with a fade, out by fading.
    /// The bar changing on its own: a fade in, gone at once (fading out, it would sit over the neighbour that snapped
    /// into its place). The window switching: nothing, a cut. Reduce Motion: the fades alone.
    private func arrival(byPointer: Bool) -> AnyTransition {
        if cutting { return .identity }
        let fadeIn = AnyTransition.opacity.animation(.easeOut(duration: reduceMotion ? 0.15 : 0.2))
        guard byPointer else { return .asymmetric(insertion: fadeIn, removal: .identity) }
        return .asymmetric(
            insertion: reduceMotion
                ? fadeIn : AnyTransition.opacity.combined(with: .scale(scale: 0.9)).animation(barMotion(entering: true)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.15)))
    }

    /// The inbox, in the top hollow: out while its pane is open or with the pointer in its zone at the bar's top;
    /// otherwise folded to its arc, blue while asks wait. The pointer on it opens the inbox, as the other slots do.
    /// Nothing in the body: the two buttons alone, 12 pt apart, joined from the screen edge by a low bump that's always
    /// there, so a button that's out never floats alone. Without the settings button its arc stays, for the same reason.
    private var slimPair: some View {
        VStack(spacing: BarPeak.gap) {
            inboxKnob
            if barFoot { settingsKnob } else { BarKnob(out: false) { _ in EmptyView() }.allowsHitTesting(false) }
        }
        .frame(width: 44)
        .background { BarPeak().fill(Theme.pill).overlay(BarPeak().stroke(Theme.stroke, lineWidth: 1)) }
    }

    /// The inbox is out while its pane (the asks) is open, or with the pointer in its zone at the bar's top
    /// (`BarReach`); over the agents it stays folded.
    private var inboxOut: Bool {
        let asksOpen = controller.panelOpen && controller.agentFilter == nil && !controller.newAgentOpen
        return settings.shows(.inbox) && (asksOpen || overBar && controller.barReach == .inbox)
    }
    /// The settings button is out with the pointer in its zone at the bar's foot, and in while the inbox's panel is
    /// open.
    private var settingsOut: Bool {
        barFoot && overBar && controller.barReach == .settings && !controller.panelOpen
    }

    private var inboxKnob: some View {
        let selected = controller.agentFilter
        return BarKnob(
            top: true, out: inboxOut, passing: controller.barAiming, waiting: !controller.store.open.isEmpty, pulse: inboxPulse
        ) { _ in
            // 16 pt, on whole points in the 32 pt disc; half a point up, as the tray's ink sits low in its box. Out is
            // the only time it shows, so always the text's colour (one solid white in dark).
            NucleoIcon("inbox", size: 16).offset(y: -0.5)
                .foregroundStyle(.primary)
                .overlay(alignment: .topTrailing) {
                    if controller.pinned && selected == nil && !controller.newAgentOpen { PinBadge().offset(x: 4, y: -6) }
                }
        }
        .onChange(of: controller.store.open.count) { before, now in
            if now > before, !inboxOut, !reduceMotion { inboxPulse += 1 }
        }
        .onTapGesture(perform: openInbox)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open asks")
        .accessibilityAddTraits(.isButton)
    }

    /// The settings button, in the bottom hollow: out with the pointer in its zone at the bar's foot, in while the
    /// inbox's panel is open.
    private var settingsKnob: some View {
        BarKnob(out: settingsOut, passing: controller.barAiming) { _ in
            NucleoIcon("gear", size: 16).foregroundStyle(.primary)
        }
        .onTapGesture(perform: customiseBar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Customise bar")
        .accessibilityAddTraits(.isButton)
    }

    private func agentDot(_ name: String, _ mark: Mark, among names: [String], byPointer: Bool) -> some View {
        ZStack {
            switch mark {
            // The sidebar's own icon for the task's state, at its size; a new state crossfades in place.
            case .task(let state, _):
                TaskStateIcon(state: state).font(.system(size: 12)).id(state)
                    .transition(.opacity.animation(.easeOut(duration: cutting ? 0 : 0.2)))
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
        // Gone from the bar, gone from its slots: a pointer where it was peeks nothing.
        .modifier(BarSlot(controller: controller, key: name))
        .zIndex(drag?.name == name ? 1 : 0)
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
        .transition(arrival(byPointer: byPointer))
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
                // The group's own order, merged in: every workspace's tasks share the one order, and the others'
                // keep their places (each group is sorted within itself, so only their own sequence counts).
                let mine = order.filter { $0.hasPrefix("zerod-") }.map { String($0.dropFirst("zerod-".count)) }
                let rest = taskOrder.split(separator: "\n").map(String.init).filter { !mine.contains($0) }
                taskOrder = (rest + mine).joined(separator: "\n")
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

/// A control's slot on the bar (`InboxController.barSlots`), kept as the control moves and dropped when it goes. Owned
/// by the view that set it: when the bar changes shape the control's new view can set its slot before the old one
/// disappears, and the old one's leaving mustn't clear it (the frames can be the same, so they can't tell them apart).
private struct BarSlot: ViewModifier {
    let controller: InboxController
    let key: String
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                controller.barSlots[key] = $0
                controller.barSlotOwners[key] = owner
            }
            .onDisappear {
                guard controller.barSlotOwners[key] == owner else { return }
                controller.barSlots[key] = nil
                controller.barSlotOwners[key] = nil
            }
    }
}

/// A workspace's mark at the bar's size: its glyph on a faint tile of its own, 18 pt, monochrome whatever the
/// workspace's colour (on the bar colour means state alone; bare, the glyph read as one more dot).
private struct BarMark: View {
    let workspace: ZerodLink.Workspace

    var body: some View {
        WorkspaceGlyph(glyph: workspace.glyph, size: 11)
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
    }
}
