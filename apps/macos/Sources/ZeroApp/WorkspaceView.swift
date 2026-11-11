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
            if !navigation.ready { LoadingMark().frame(width: 64, height: 64).transition(.opacity) }
            DialogHost()
        }
        .frame(minWidth: 980, minHeight: 600)
        // Loops named in messages read as pills: the names, for the renderer.
        .task { await workspace.loadLoops() }
        .task { await workspace.loadLater() }
        .onChange(of: workspace.loops.map(\.name), initial: true) { _, names in LoopNames.known = names }
        .onChange(of: workspace.pads, initial: true) { _, pads in
            PadNames.known = Dictionary(pads.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
        // Each workspace opens on the task last open in it: kept as tasks are opened, and gone back to on a switch.
        .onChange(of: [navigation.place.key, navigation.worker ?? ""]) {
            guard case .task(let id) = navigation.place, let lead = workspace.conversation(id) else { return }
            let home = workspace.workspace(of: root(lead))
            navigation.remember(id, worker: navigation.worker, in: home)
            // A task of another workspace opened (a notification, the inbox, a link): the window goes to its workspace.
            // Remembered first, so arriving there keeps this task open.
            if home != workspace.current { workspace.current = home }
        }
        .onChange(of: workspace.current) { _, now in
            navigation.arrive(in: now) { id in workspace.conversation(id).map { workspace.workspace(of: root($0)) == now } ?? false }
        }
        // The rail and the strip above the panel: translucent grey over what's behind the window, blurred, as Codex's.
        .background {
            ZStack {
                BehindWindow(); Theme.railTint
            }
        }
        .ignoresSafeArea()
        // Behind the mark, everything the first screen needs: zerod and the inbox connected, the rail's integrations,
        // the sidebar's tasks, loop names for the pills, and the page the window opens on with its words already
        // styled, so nothing loads or reflows once the window shows.
        .task {
            // zerod first, for as long as it takes to come back (an update restarts it, finishing running commands
            // first: seconds, not the 5 the window used to wait before showing empty, on a new task's page).
            let started = ContinuousClock.now
            while !workspace.connected, ContinuousClock.now < started + .seconds(30) {
                try? await Task.sleep(for: .milliseconds(30))
            }
            // Then the rest, from when it answered.
            let deadline = ContinuousClock.now + .seconds(4.5)
            func until(_ done: @autoclosure () -> Bool) async {
                while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            }
            await workspace.loadIntegrations()
            await workspace.refreshBoard()
            await workspace.loadLoops()
            await workspace.loadPads()
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
        // Never held on the mark for good: a zerod that doesn't come back shows the window as it is, saying so.
        .task {
            try? await Task.sleep(for: .seconds(35))
            show()
        }
    }

    /// A task's lead, however deep: what decides a worker's workspace, as zerod has it.
    private func root(_ conversation: Conversation) -> Conversation {
        var top = conversation
        while let parent = top.parent, let up = workspace.conversation(parent) { top = up }
        return top
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
                    IntegrationPage(
                        workspace: workspace, integration: Integration(rawValue: name) ?? .github,
                        edit: { Integration.edit(name, place: &navigation.place) },
                        openTask: { navigation.place = .task($0) }
                    ).id(name)
                default:
                    HStack(spacing: 0) {
                        TasksSidebar(workspace: workspace, navigation: navigation)
                        Rectangle().fill(Theme.stroke).frame(width: 1)
                        page.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
                    }
                    .coordinateSpace(.named("tasks"))
                    // A task's details, beside the sidebar where the pointer rests on its row: over the page, since the
                    // sidebar clips what it scrolls.
                    .overlay(alignment: .topLeading) {
                        TaskPeekCard(
                            workspace: workspace,
                            open: {
                                navigation.place = .task($0); navigation.worker = $1
                            })
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            .padding(.top, 38).padding([.trailing, .bottom], 4) // under the window's buttons, as ChatGPT's
        }
        // Archiving asks first, in Zero's dialog over the window (as Linear asks before deleting), wherever it was asked.
        .zeroDialog(item: Binding(get: { workspace.archiving.map(Archiving.init) }, set: { workspace.archiving = $0?.id })) { asked in
            ArchiveDialog(workspace: workspace, id: asked.id) {
                if navigation.place == .task(asked.id) { navigation.place = .home }
            }
        }
        // What went wrong, or Zero updating: a toast in the window's corner, clear of the composer and of a turn's
        // heading (at the top, the update covered it), on a menu's card (Linear's); an error gone on a click or after
        // a while. Eased in and out, never popping in a frame.
        .overlay(alignment: .bottomTrailing) {
            ZStack(alignment: .bottomTrailing) {
                if let updating = workspace.updating {
                    UpdatingBar(updating: updating).transition(.opacity.combined(with: .offset(y: 8)))
                } else if let error = workspace.lastError {
                    ErrorToast(text: error) { workspace.lastError = nil }
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: workspace.lastError)
            .animation(.easeOut(duration: 0.2), value: workspace.updating == nil)
            .padding(16)
        }
    }

    @ViewBuilder private var page: some View {
        switch navigation.place {
        case .board: BoardView(workspace: workspace, open: { navigation.place = .task($0) })
        case .agent(let name): AgentPage(controller: inbox, name: name).id(name)
        case .task(let id) where workspace.conversation(id) != nil:
            TaskPages(workspace: workspace, inbox: inbox, navigation: navigation, current: id)
        default: NewTaskView(workspace: workspace, started: { navigation.place = .task($0) })
        }
    }
}

/// The task being asked about, as the dialog's item.
private struct Archiving: Identifiable { let id: String }

/// Archiving puts a task away with every worker under it: the task named, what goes with it, and where it comes back
/// from. Return archives, Escape cancels.
private struct ArchiveDialog: View {
    let workspace: Workspace
    let id: String
    let leaving: () -> Void
    @Environment(\.closeDialog) private var close

    var body: some View {
        let workers = workspace.team(of: id).count
        let name = workspace.conversation(id).map { "\u{201C}\(Workspace.label(of: $0))\u{201D}" } ?? "this task"
        VStack(alignment: .leading, spacing: 6) {
            DialogTitle(
                text: workers == 0 ? "Archive \(name)?" : "Archive \(name) and its \(workers == 1 ? "worker" : "\(workers) workers")?"
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("Bring \(workers == 0 ? "it" : "them") back from Archived tasks.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                DialogButton(title: "Cancel") { close() }
                DialogButton(title: "Archive", kind: .primary) {
                    close()
                    leaving()
                    Task { await workspace.archive(id) }
                }
            }
            .padding(.top, 12)
        }
        .frame(width: 380, alignment: .leading)
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
        switch place {
        case .inbox, .settings, .integrations, .integration, .pads, .pad, .loops, .loop, .later, .laterItem: false;
        default: true
        }
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
            // Always to what's waiting on you, whichever of the inbox's lists was open last.
            item("inbox", selected: place == .inbox, help: "Inbox") {
                UserDefaults.standard.set(InboxFilter.waiting, forKey: InboxFilter.key)
                UserDefaults.standard.set("", forKey: InboxFilter.titleKey)
                place = .inbox
            }
            .overlay(alignment: .topTrailing) {
                let waiting = AsksPage.waiting(inbox).count
                if waiting > 0 {
                    Text("\(waiting)").font(.system(size: 9.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Color.red, in: Capsule())
                        // A ring in the rail's colour, as the Dock cuts its badges out.
                        .padding(1.5).background(Theme.composer, in: Capsule())
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
                Button {
                    place = .integration(integration.rawValue)
                } label: {
                    integration.icon(size: 17).foregroundStyle(selected ? .primary : .secondary).frame(width: 32, height: 32)
                }
                .buttonStyle(Hovering(selected: selected, fill: Theme.railSelected, hover: Theme.railHover)).tip(integration.title)
                .offset(y: dragging == integration ? held(index, of: shown.count) : shift(index, in: shown))
                .zIndex(dragging == integration ? 1 : 0)
                .animation(.spring(duration: 0.22), value: dragging == integration ? 0 : shift(index, in: shown))
                .highPriorityGesture(drag(integration, from: index, of: shown.count), including: command ? .all : .subviews)
                .zeroContextMenu("rail-\(integration.rawValue)") {
                    [
                        (index > 0 ? [MenuItem("Move up", "arrow-up") { move(integration, to: index - 1) }] : [])
                            + (index < shown.count - 1 ? [MenuItem("Move down", "chevron-down") { move(integration, to: index + 1) }] : [])
                            + [MenuItem("Edit views", "pen") { Integration.edit(integration.rawValue, place: &place) }],
                        [
                            MenuItem("Hide from the sidebar", "eye") {
                                Task { await workspace.setIntegration(integration.rawValue, enabled: false) }
                            }
                        ],
                    ]
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
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                command = event.modifierFlags.contains(.command); return event
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    /// Held ⌘: the item follows the pointer within the integrations' slots, the others making way as it passes, and it
    /// lands in the slot it's let go over.
    private func drag(_ integration: Integration, from index: Int, of count: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                dragging = integration; dragged = value.translation.height
            }
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

/// An error, said quietly: its icon and words on a menu's card, and a close button. It goes by itself after six
/// seconds (a new error starts the count again).
private struct ErrorToast: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            NucleoIcon("triangle-warning", fill: "glyph", size: 14).foregroundStyle(.orange)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.menuText).fixedSize(horizontal: false, vertical: true)
            Button(action: close) {
                NucleoIcon("xmark", size: 11).foregroundStyle(Theme.menuIcon).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).tip("Dismiss")
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .modifier(MenuCard(radius: 12, linear: true))
        .task(id: text) {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { close() }
        }
    }
}

/// Zero's mark while the window gets ready: soft grey, with a brighter band of it sweeping across, corner to corner,
/// every 1.6 s, so a wait (an update restarting zerod) reads as loading. With Reduce Motion, it breathes instead.
private struct LoadingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period = 1.6

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            if reduceMotion {
                ZeroMark().foregroundStyle(.secondary).opacity(0.55 + 0.45 * (0.5 - 0.5 * cos(phase * 2 * .pi)))
            } else {
                // The band's middle, from just off one corner to just off the other, easing in and out.
                let eased = 0.5 - 0.5 * cos(phase * .pi)
                let at = -0.35 + 1.7 * eased
                ZeroMark().foregroundStyle(.tertiary)
                    .overlay {
                        ZeroMark().foregroundStyle(.primary)
                            .mask {
                                // Sampled along the diagonal (a gradient's stops must lie within it): bright at the band's
                                // middle, nothing 0.3 either side.
                                LinearGradient(
                                    stops: (0...20).map { step in
                                        let x = Double(step) / 20
                                        return .init(color: .black.opacity(max(0, 1 - abs(x - at) / 0.3)), location: x)
                                    }, startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                    }
            }
        }
    }
}
