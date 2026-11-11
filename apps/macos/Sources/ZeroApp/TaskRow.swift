import AppKit
import SwiftUI
import ZeroCore

/// What a task's state looks like, in colours that say it at a glance: orange it waits on you, red it's in trouble,
/// blue it works, green it's ready for you, grey the rest.
/// A task in the sidebar: a lead with a chevron that folds its workers away, each worker under it on a dotted
/// branch. The state sits at the right, as on every task row.
struct TaskRow: View {
    enum Branch { case middle, last }
    let title: String
    let state: BoardRow.State
    let selected: Bool
    @State private var hovering = false
    /// A lead with workers: whether they show. Nil for a lead without any.
    var fold: Bool? = nil
    /// A worker: its place on its lead's branch.
    var branch: Branch? = nil
    /// Beside the icon, small: how long an issue has been on the user.
    var detail: String? = nil
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
                if let detail { Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize() }
                // The icon keeps its place however long the title: the title gives way, not the state.
                TaskStateIcon(state: state).font(.system(size: 12)).fixedSize().layoutPriority(1)
            }
            .foregroundStyle(.primary)
            // In from the edge as the heading is; a worker's title sits on its branch.
            .padding(.leading, branch != nil ? 0 : 10).padding(.trailing, 10).frame(height: 30)
        }
        .buttonStyle(Hovering(selected: selected))
        .onHover { hovering = $0 }
        // One gesture for click and drag, as the control bar's: on the row's button only, so the fold chevron keeps its
        // own click. Global space: the row moves with the drag, so a local translation would cancel itself out.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { reorder?.changed($0.translation.height) }
                .onEnded { _ in if reorder?.ended() == false { action() } },
            including: reorder == nil ? .subviews : .all
        )
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
        if [.idle, .done, .offline].contains(worker.attention),
            let answer = worker.items.last(where: { if case .agent(_, true) = $0.kind { true } else { false } }),
            case let .agent(text, _) = answer.kind, let ending = ZeroEnding.split(text).1
        {
            switch ending {
            case .done: return .done
            case .working: return .idle
            case .waiting: return .waiting
            case .asked: return .needsYou
            }
        }
        return switch worker.attention {
        case .needsYou: .needsYou
        case .blocked: .waiting
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

struct TaskStateIcon: View {
    let state: BoardRow.State

    var body: some View {
        Group {
            // At work it spins, as everywhere else in Zero something under way does.
            if state == .working {
                Spinner().frame(width: 12, height: 12).frame(width: 14, height: 14)
            } else {
                NucleoIcon(Self.look(state).symbol, fill: "glyph", size: 14).foregroundStyle(Self.look(state).color)
            }
        }
        // A view of its own for each state: a spinner's AppKit view kept from Working could otherwise stand where the
        // next state's icon should be, and the row would show nothing.
        .id(state)
    }

    static func look(_ state: BoardRow.State) -> (symbol: String, color: Color, name: String) {
        switch state {
        case .needsYou: ("hand-3", .blue, "Needs you")
        case .trouble: ("triangle-warning", .orange, "In trouble")
        // Can't go on at all, as its agent confirmed (zero blocked): red, kept for what's big.
        case .blocked: ("circle-minus", .red, "Blocked")
        case .working: ("arrow-rotate-clockwise", .blue, "Working")
        // Done, with a step for the user: a calm to-do, not a decision.
        case .handed: ("hand-holding-box", .teal, "Over to you")
        // The next move is someone else's: grey, as it asks nothing of the user.
        case .waiting: ("hourglass", .secondary, "Waiting")
        case .answered: ("message-check", .indigo, "Replied")
        // Nothing left it can do: purple, as GitHub shows a PR merged or an issue completed.
        case .done: ("badge-check", .purple, "Done")
        case .paused: ("circle-pause", .secondary, "Paused")
        // Replied, and read: greyed, so what still needs reading stands out.
        case .read: ("message-check", .secondary, "Replied")
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
            card(
                row,
                title: lead.session == id ? row.task : workspace.conversations.first { $0.id == id }.map(Workspace.label(of:)) ?? row.task
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                open(lead.session, lead.session == id ? nil : id); peek.close()
            }
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
                    if let calling = Self.calling(row) { Text(calling).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                StateLabel(state: row.ownState)
            }
            // Over to you: what's yours to do is the whole story, in the description's place (the pill says whose).
            if row.ownState == .handed, let needs = row.needs {
                Text("For you: " + needs).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let now = row.now, !now.isEmpty {
                    Text(now).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let needs = row.needs { line("hand-holding-box:glyph", "For you: " + needs) }
            }
            ForEach(row.asks.prefix(3), id: \.id) { ask in line("circle-question", ask.title) }
            if row.asks.count > 3 { Text("and \(row.asks.count - 3) more asks").font(.system(size: 11.5)).foregroundStyle(.tertiary) }
            if let queued = row.queued, !queued.isEmpty { line("clock", "\(queued.count) queued" + (row.held == true ? ", held" : "")) }
            if let wakes = row.wakes {
                let at = Date(timeIntervalSince1970: TimeInterval(wakes))
                line(
                    "clock",
                    "Wakes "
                        + (Calendar.current.isDateInToday(at)
                            ? at.formatted(date: .omitted, time: .shortened)
                            : at.formatted(.dateTime.weekday(.abbreviated).hour().minute())))
            }
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
        let look = TaskStateIcon.look(state)
        let tint: Color = look.color == .secondary ? .secondary : look.color
        HStack(spacing: 5) {
            TaskStateIcon(state: state).scaleEffect(0.86)
            Text(look.name).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(
                    look.color == .secondary
                        ? AnyShapeStyle(.secondary) : look.color == .green ? AnyShapeStyle(Theme.done) : AnyShapeStyle(look.color))
        }
        .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
        // Level with the words beside it in a row aligned on baselines: the pill's middle where their baseline sits
        // (its spinner has no baseline of its own).
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }
}
