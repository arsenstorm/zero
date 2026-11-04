import AppKit
import SwiftUI
import ZeroCore

// The board: every task at once, most urgent first, as a panel from arsenstorm.com: a grey shell carrying the
// headings, a lighter body, hairlines between rows.

struct BoardView: View {
    let workspace: Workspace
    let open: (String) -> Void

    var body: some View {
        // The workspace shown, as the sidebar: another workspace's tasks are there.
        let rows = workspace.board.filter { $0.workspace == workspace.current }
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
            Button("Archive…") { workspace.archiving = row.session }
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
