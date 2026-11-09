import AppKit
import Observation
import SwiftUI
import ZeroCore

/// The small pin that marks whichever control the inbox is pinned on.
struct PinBadge: View {
    var body: some View { Text("📌").font(.system(size: 9)).frame(width: 12, height: 12) }
}

/// The bar's outline: rounded on the left, and merging into the screen edge on the right through two concave
/// fillets above and below, like a tab grown out of the edge.
struct PillShape: InsettableShape {
    var radius: CGFloat = 22
    var fillet: CGFloat = 10
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
        path.addArc(center: CGPoint(x: x0 + R, y: y0 + r + R), radius: R, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
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
    /// The board, to fold workers into their leads: one dot per lead, in its team's most urgent state, as the sidebar
    /// lists them.
    var workspace: Workspace? = nil
    let openInbox: () -> Void
    let selectAgent: (String) -> Void
    let moveHere: () -> Void
    /// Hovering a control peeks: nil for the open asks, a name for that agent's timeline.
    let peek: (String?) -> Void
    var openNewAgent: () -> Void = {}
    var peekNewAgent: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A dot being dragged up or down the bar, and how far.
    @State private var drag: (name: String, y: CGFloat)?

    private let slot: CGFloat = 28

    init(controller: InboxController, settings: Settings, workspace: Workspace? = nil, openInbox: @escaping () -> Void,
         selectAgent: @escaping (String) -> Void, moveHere: @escaping () -> Void,
         peek: @escaping (String?) -> Void = { _ in }, openNewAgent: @escaping () -> Void = {}, peekNewAgent: @escaping () -> Void = {},
         previewHovered: String? = nil) {
        self.controller = controller; self.settings = settings; self.workspace = workspace
        self.openInbox = openInbox; self.selectAgent = selectAgent; self.moveHere = moveHere; self.peek = peek
        self.openNewAgent = openNewAgent; self.peekNewAgent = peekNewAgent
    }

    /// Every agent that has spoken and has not been closed, with its status. Expired asks don't count. A worker's
    /// agent (its session under a lead, by the board) is no dot of its own: its lead's dot carries the team's most
    /// urgent state.
    private var agents: [(String, AgentStatus)] { controller.barAgents(settings: settings, workspace: workspace) }

    private func scale(_ name: String) -> CGFloat { controller.agentFilter == name ? 13 / 11 : 1 }

    /// Where the dragged dot would land right now.
    private func dropIndex(in names: [String]) -> Int? {
        guard let drag, let from = names.firstIndex(of: drag.name) else { return nil }
        return max(0, min(names.count - 1, from + Int((drag.y / slot).rounded())))
    }

    /// While dragging, the dots between the start slot and the drop slot step aside by one slot.
    private func shift(of name: String, in names: [String]) -> CGFloat {
        guard let drag, drag.name != name, let from = names.firstIndex(of: drag.name),
              let to = dropIndex(in: names), let i = names.firstIndex(of: name) else { return 0 }
        if from < to, i > from, i <= to { return -slot }
        if from > to, i >= to, i < from { return slot }
        return 0
    }

    var body: some View {
        // Once a redraw: worked out from every ask the store holds, four reads of it cost the bar a frame.
        let agents = agents
        VStack(spacing: 2) {
            inboxSlot
            if controller.canSpawn { newAgentSlot }
            if !agents.isEmpty {
                Rectangle().fill(Theme.hairline).frame(width: 18, height: 1).padding(.vertical, 4)
                    .onChange(of: agents.map(\.0), initial: true) { controller.barOrder = $1 }
                    .onDisappear { controller.barOrder = [] }
            }
            let names = agents.map(\.0)
            ForEach(agents, id: \.0) { name, status in agentDot(name, status, among: names) }
        }
        .padding(.vertical, 8 + 10).padding(.horizontal, 6)
        .background(PillShape().fill(Theme.pill))
        .overlay(PillShape().strokeBorder(Theme.stroke, lineWidth: 1))
        // The bar's drawn height, which the inbox uses for its scroll limits.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.barHeight = $0 }
        // Outermost on purpose: placed inside, only the dots would animate and the shape would snap.
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: agents.map(\.0))
        .pointerStyle(.link)
        .contextMenu {
            Button("Open Log") { NSWorkspace.shared.open(Paths.log) }
            Divider()
            Button("Settings…") { (NSApp.delegate as? AppDelegate)?.openSettings() }
            Button("Quit Zero") { NSApp.terminate(nil) }
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
                    Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 3, y: -3)
                }
            }
            .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.barSlots[InboxController.inboxSlot] = $0 }
        .onTapGesture(perform: openInbox)
        .tip("Open asks")
    }

    private var newAgentSlot: some View {
        NucleoIcon("plus", size: 15)
            .foregroundStyle(controller.newAgentOpen ? .primary : .secondary)
            .overlay(alignment: .topTrailing) {
                if controller.pinned && controller.newAgentOpen { PinBadge().offset(x: 4, y: -6) }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.barSlots[InboxController.newSlot] = $0 }
            .onTapGesture(perform: openNewAgent)
            .tip("Start a new agent")
    }

    private func agentDot(_ name: String, _ status: AgentStatus, among names: [String]) -> some View {
        Group {
            if status == .working { Spinner() } else { Circle().fill(status.color) }
        }
            .frame(width: 11, height: 11)
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.barSlots[name] = $0 }
            // Gone from the bar, gone from its slots: a pointer where it was peeks nothing.
            .onDisappear { controller.barSlots[name] = nil }
            .zIndex(drag?.name == name ? 1 : 0)
            .tip(controller.store.displayName(of: name))
            .contextMenu { agentMenu(name) }
            // One gesture for click and drag, so they never compete: a press that moves under 4 pt selects;
            // a longer one drags the dot with the pointer and drops it into the nearest slot.
            // Global space: the dot moves with the drag, so a local translation would cancel itself out.
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if abs(value.translation.height) >= 4 || drag != nil { drag = (name, value.translation.height) }
                }
                .onEnded { _ in
                    guard drag != nil else { selectAgent(name); return }
                    drop(name)
                })
            .transition(.opacity)
    }

    @ViewBuilder private func agentMenu(_ name: String) -> some View {
        if let identity = controller.store.identity(of: name), identity.runtime == "rex" {
            Button("Open in Rex") { Task { await RexAdapter.reveal(identity) } }
        }
        if let identity = controller.store.identity(of: name), identity.runtime == "zero", let ref = identity.ref {
            Button("Open in Terminal") { HostAdapter.reveal(ref) }
        }
        Button(controller.store.canStop(name) ? "Remove and stop \(name)" : "Remove \(name)") { controller.store.closeAgent(name) }
    }

    /// The dragged dot let go: the bar's order with it moved into the slot it's over.
    private func drop(_ name: String) {
        let names = agents.map(\.0)
        guard let from = names.firstIndex(of: name), let to = dropIndex(in: names) else { drag = nil; return }
        var order = names
        order.remove(at: from)
        order.insert(name, at: to)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            settings.agentOrder = order
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
