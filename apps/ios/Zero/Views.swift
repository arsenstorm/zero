import SwiftUI
import UserNotifications
import VisionKit
import AppIntents

@main
struct ZeroPhone: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = PhoneModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Root(model: model)
            // Back in front: connected again if the connection dropped while away.
            .onChange(of: phase) { if phase == .active { Task { await model.wake() } } }
            // Dropped: tried again while the app is in front, at once (the Mac's app restarting is back in a moment),
            // then waiting longer each time it doesn't connect, up to four seconds.
            .task(id: model.status) {
                guard case .offline = model.status, phase == .active else { return }
                try? await Task.sleep(for: .seconds(min(4, 0.5 * pow(2, Double(model.retries)))))
                model.retries += 1
                model.connect()
            }
            .onAppear { AppDelegate.model = model }
            // A pairing link, from the Camera or anywhere: paired with that Mac (again, if it's a new code).
            .onOpenURL { url in if url.host == "pair" { model.unpair(); _ = model.pair(url.absoluteString) } }
        }
    }
}

/// Pairing, the splash, or the app, one handing over to the next: the splash zooms past you and blurs away as the
/// tasks fade in under it (only fading, with Reduce Motion).
struct Root: View {
    let model: PhoneModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Screen { case pair, splash, home }
    /// The mark held a moment at launch, however quick the Mac is: gone at once, it read as a flash, not a start.
    @State private var holding = true

    var body: some View {
        let screen: Screen = !model.paired ? .pair : holding || model.rows.isEmpty && model.status != .connected ? .splash : .home
        ZStack {
            switch screen {
            case .pair: PairView(model: model).transition(.opacity)
            case .splash:
                Splash(model: model).zIndex(1)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .modifier(active: Away(on: true), identity: Away(on: false))))
            case .home:
                // Faded in, not scaled: scaling it moved its header and tab bar, which then settled after it.
                Home(model: model).transition(.opacity)
            }
        }
        // A strong ease-out: quick to start, settling gently.
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.8), value: screen)
        .task {
            try? await Task.sleep(for: .seconds(1))
            holding = false
        }
    }

    private struct Away: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            content.scaleEffect(on ? 1.12 : 1).blur(radius: on ? 12 : 0).opacity(on ? 0 : 1)
        }
    }
}

/// A task's state, as the Mac's sidebar shows it: the same icons and colours.
struct StateGlyph: View {
    let state: BoardRow.State
    var size: CGFloat = 16
    var body: some View {
        let look = Self.look(state)
        if state == .working { Spinner().frame(width: size - 2, height: size - 2).frame(width: size, height: size) }
        else { Image(look.icon).resizable().frame(width: size, height: size).foregroundStyle(look.color) }
    }

    static func look(_ state: BoardRow.State) -> (icon: String, color: Color, name: String) {
        switch state {
        case .needsYou: ("hand-3-glyph", .blue, "Needs you")
        case .trouble: ("triangle-warning-glyph", .orange, "In trouble")
        case .blocked: ("circle-minus-glyph", .red, "Blocked")
        case .working: ("arrow-rotate-clockwise-glyph", .blue, "Working")
        case .handed: ("hand-holding-box-glyph", .teal, "Over to you")
        case .waiting: ("hourglass-glyph", .secondary, "Waiting")
        case .answered: ("message-check-glyph", .indigo, "Replied")
        case .done: ("badge-check-glyph", .purple, "Done")
        case .paused: ("circle-pause-glyph", .secondary, "Paused")
        case .read: ("message-check-glyph", .secondary, "Replied")
        case .idle: ("moon-glyph", .secondary, "Idle")
        case .offline: ("power-off-glyph", .secondary, "Offline")
        }
    }
}

/// What a task says under its name, as Linear's inbox: up to two lines, the end of the last fading out under how long
/// ago it moved.
struct Described: View {
    let text: String?
    let at: Int?
    var font: Font = .subheadline
    /// In the primary colour (a note saved for later is the row itself), not the secondary of what a task says.
    var primary = false
    @State private var timeWidth: CGFloat = 0
    @State private var lineHeight: CGFloat = 18

    var body: some View {
        let ago = at.map { Ago.short($0) }
        if let text, !text.isEmpty {
            // Left-aligned: inside a button (a task's row), lines are centred otherwise.
            Text(text).font(font).foregroundStyle(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)).lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask {
                    // Whole, but the last line's end: fading out, then nothing where the time is.
                    VStack(spacing: 0) {
                        Color.black
                        HStack(spacing: 0) {
                            Color.black
                            if ago != nil {
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                                Color.clear.frame(width: timeWidth + 4)
                            }
                        }
                        .frame(height: lineHeight)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let ago {
                        Text(ago).font(font).foregroundStyle(.secondary).monospacedDigit()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { timeWidth = $0.width; lineHeight = $0.height }
                    }
                }
        }
    }

    /// Nothing to say: the row has a single line, the time beside its name (TimeBeside), centred on its icon.
    static func says(_ text: String?) -> Bool { !(text ?? "").isEmpty }
}

/// One line of text at its own width when it fits; when it doesn't, as wide as there's room for, fading out at its end
/// rather than ending in "…". It takes its room as any one-line label does (the hidden text, which the row lays out),
/// and draws the whole line over it, clipped: the line itself never makes the row wider.
struct FadingLine: View {
    let text: String
    let font: Font
    @State private var whole: CGFloat = 0
    @State private var room: CGFloat = 0

    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
            .overlay(alignment: .leading) {
                Text(text).font(font).lineLimit(1).fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { whole = $0 }
            }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    if whole > room + 0.5 { LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28) }
                }
            }
    }
}

/// How long ago a row moved, beside its name: for a row with nothing under its name.
struct TimeBeside: View {
    let at: Int?
    var body: some View {
        if let at { Text(Ago.short(at)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
    }
}

/// A task's agent as an avatar, Linear's way: its mark in a circle, its state at the corner.
struct AgentAvatar: View {
    let provider: Provider?
    let state: BoardRow.State

    var body: some View {
        Image(Self.mark(provider)).resizable().frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .background(Color(.secondarySystemFill), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                StateGlyph(state: state).scaleEffect(0.8)
                    .frame(width: 20, height: 20)
                    .background(Color(.systemBackground), in: Circle())
                    .offset(x: 3, y: 3)
                    .accessibilityLabel(StateGlyph.look(state).name)
            }
    }

    static func mark(_ provider: Provider?) -> String {
        switch provider {
        case .claude: "provider-claude"
        case .codex: "provider-openai"
        default: "terminal-outline"
        }
    }
}

/// The camera, reading QR codes: the first that's Zero's is the one.
struct Scanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let text = code.payloadStringValue, text.hasPrefix("zero://pair") else { continue }
                done = true
                found(text)
            }
        }
    }
}

/// Paired: the places, under Zero's own bar (NavBar): the system's tab bar hidden, the tabs kept alive by it.
struct Home: View {
    @Bindable var model: PhoneModel
    @State private var newTask = false
    @State private var menu = false

    // The stack holds the tabs, not the other way round: a task slides in over the bar and back out with it there
    // all along.
    var body: some View {
        NavigationStack(path: $model.path) {
            TabView(selection: $model.tab) {
                Tab(value: PhoneModel.Place.inbox) { InboxView(model: model).modifier(UnderBar()) }
                Tab(value: PhoneModel.Place.tasks) { TasksView(model: model).modifier(UnderBar()) }
                Tab(value: PhoneModel.Place.later) { LaterView(model: model).modifier(UnderBar()) }
                Tab(value: PhoneModel.Place.record) { RecordView(model: model).modifier(UnderBar()) }
                Tab(value: PhoneModel.Place.settings) { SettingsView(model: model).modifier(UnderBar()) }
            }
            // The keyboard is a task's (or a sheet's): the places and their bar stay where they are under it. Without
            // this, swiping back from a task with its keyboard up showed the bar raised over where the keyboard was.
            .ignoresSafeArea(.keyboard)
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    if menu {
                        Color.black.opacity(0.25).ignoresSafeArea()
                            .onTapGesture { withAnimation(.bouncy(duration: 0.35)) { menu = false } }
                            .transition(.opacity)
                    }
                    NavBar(model: model, open: $menu, newTask: { newTask = true })
                }
                // The whole screen, the bar on its foot, keyboard or not. As tall as the bar alone, ignoring the
                // keyboard only stretched it down into the keyboard's room with the bar centred in it: raised by half
                // the keyboard on the way back from a task with it up.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard)
            }
            .sheet(isPresented: $newTask) { NewTaskSheet(model: model) }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in TaskView(model: model, session: id) }
            // The page's name where Zero's mark was, as Linear titles its pages.
            .toolbar {
                // A slot as wide as any page's name, its name at the start: the bar sized the item to each name and
                // moved it as the pages changed. The name changes without an animation of its own.
                ToolbarItem(placement: .topBarLeading) {
                    Text(Self.names[model.tab] ?? "").font(.title.bold()).lineLimit(1)
                        .frame(width: 220, alignment: .leading)
                        .transaction { $0.animation = nil }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        // On the lists; a task's page shows it under its own bar (over the bar, it sat on the task's name).
        .overlay(alignment: .top) { if model.path.isEmpty { ConnectionBadge(model: model) } }
    }
}

/// Dropped after loading: what's here stays, the line says it's being got back.
struct ConnectionBadge: View {
    let model: PhoneModel
    var body: some View {
        ZStack {
            if model.status != .connected {
                Text(model.status == .connecting ? "Reconnecting to your Mac" : "Can't reach your Mac").font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.status)
    }
}

/// A conversation coming: a few turns' shapes, greyed, where it will be (a spinner alone, pinned to the page's foot,
/// read as nothing happening).
private struct LoadingTurns: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<3, id: \.self) { turn in
                HStack {
                    Spacer(minLength: 80)
                    Text("A message of yours, a line or so long").padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 18))
                }
                Text(turn == 1 ? "An answer a few lines long, written out across the page as the agent's answers are, ending here." :
                     "An answer, a couple of lines long, across the page as the agent's are.")
            }
        }
        .redacted(reason: .placeholder)
        .opacity(0.6)
        .padding()
        .accessibilityLabel("Loading")
    }
}

/// A place under Zero's bar: the system's tab bar hidden, and room at the foot of what it scrolls so its last row
/// scrolls clear of the bar. (Room given to the TabView didn't reach the lists inside it.) Fixed, so the menu opening
/// over the page moves nothing.
struct UnderBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .contentMargins(.bottom, NavBar.height + 16, for: .scrollContent)
    }
}

extension Home {
    static let names: [PhoneModel.Place: String] = [.inbox: "Inbox", .tasks: "Tasks", .later: "Later", .record: "Record", .settings: "Settings"]

    /// A workspace's name, its emoji first when it has one (a Nucleo icon's name isn't shown here).
    static func title(_ space: ZerodLink.Workspace) -> String {
        let emoji = space.glyph.unicodeScalars.first.map { $0.properties.isEmojiPresentation } ?? false
        return emoji ? space.glyph + " " + space.name : space.name
    }
}

/// Zero's mark, as the app's own (tinted with the text).
struct Logo: View {
    var size: CGFloat = 24
    var body: some View { Image("logo").resizable().scaledToFit().frame(width: size, height: size) }
}

/// Every task, most urgent first, as the Mac's board sorts them; as its sidebar has them, each lead's workers folded
/// under it, a chevron opening them.
struct TasksView: View {
    let model: PhoneModel
    @State private var renaming: (session: String, name: String)?
    @State private var newName = ""
    @State private var archiving: (session: String, name: String, workers: Int)?

    var body: some View {
        List {
            Section {
                // A row a lead: its workers are in the task, not folded out here.
                ForEach(model.tasks) { row in
                    let workers = (row.team ?? []).filter { $0.session != row.session }.count
                    TaskRow(row: row, said: row.needs ?? row.now) { model.path.append(row.session) }
                        .contextMenu { actions(row.session, name: row.task, state: row.ownState, workers: workers) } preview: { TaskPeek(row: row, name: row.task) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipes(row.session, name: row.task, state: row.ownState, workers: workers) }
                        .swipeActions(edge: .leading) { renameSwipe(row.session, name: row.task) }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 36)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty { Task { await model.rename(renaming.session, to: newName) } } }
        }
        // As the Mac asks: archiving puts the task away with every worker under it.
        .confirmationDialog(archiving.map { "Archive \($0.name)?" } ?? "", isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }),
                            titleVisibility: .visible) {
            Button("Archive", role: .destructive) { if let archiving { Task { await model.archive(archiving.session) } } }
        } message: {
            if let archiving {
                Text((archiving.workers == 0 ? "It" : "It and its \(archiving.workers == 1 ? "worker" : "\(archiving.workers) workers")")
                     + " will be put away. Bring " + (archiving.workers == 0 ? "it" : "them") + " back from Archived tasks on your Mac.")
            }
        }
        .refreshable { model.connect() }
        .task { model.askForPush() }
    }
}

extension TasksView {
    /// Swiped left: archive (asking first, as from the menu), and pause or resume.
    @ViewBuilder func swipes(_ session: String, name: String, state: BoardRow.State, workers: Int) -> some View {
        Button { archiving = (session, name, workers) } label: { Label("Archive", image: "trash-glyph") }.tint(.red)
        if state == .paused {
            Button { Task { _ = await model.unpause([session]) } } label: { Label("Resume", image: "arrow-rotate-clockwise-glyph") }.tint(.blue)
        } else {
            Button { Task { _ = await model.pause([session]) } } label: { Label("Pause", image: "circle-pause-glyph") }.tint(.gray)
        }
    }

    /// Swiped right: rename.
    func renameSwipe(_ session: String, name: String) -> some View {
        Button { newName = name; renaming = (session, name) } label: { Label("Rename", image: "pen-glyph") }.tint(.indigo)
    }

    /// A task's long press, as the Mac's row menu: pause or resume, rename, archive.
    @ViewBuilder func actions(_ session: String, name: String, state: BoardRow.State, workers: Int) -> some View {
        if state == .paused {
            Button { Task { _ = await model.unpause([session]) } } label: { Label("Resume", image: "arrow-rotate-clockwise-glyph") }
        } else {
            Button { Task { _ = await model.pause([session]) } } label: { Label("Pause", image: "circle-pause-glyph") }
        }
        Button { newName = name; renaming = (session, name) } label: { Label("Rename", image: "pen-glyph") }
        Button { Task { await model.askToSaveForLater(session) } } label: { Label("Save for later", image: "bookmark-glyph") }
        Button(role: .destructive) { archiving = (session, name, workers) } label: { Label("Archive", image: "trash-glyph") }
    }
}

/// A task's long-press preview, as the Mac's hover card: its state, what it's doing, what it needs, its asks.
struct TaskPeek: View {
    let row: BoardRow
    let name: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StateGlyph(state: row.ownState)
                Text(row.ownState.title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(name).font(.headline).lineLimit(2)
            if let now = row.now, !now.isEmpty { Text(now).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }
            if let needs = row.needs { Label("For you: " + needs, image: "hand-holding-box-glyph").font(.subheadline) }
            ForEach(row.asks.prefix(3), id: \.id) { ask in Label(ask.title, image: "circle-question-glyph").font(.subheadline).lineLimit(2) }
            if let queued = row.queued, !queued.isEmpty {
                Label("\(queued.count) queued" + (row.held == true ? ", held" : ""), image: "clock-glyph").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

/// A task as the Mac's sidebar lists it: its name, then (a lead with workers) the chevron that folds them, then its
/// state. A worker's is a step in and smaller.
/// A task's row, the same in the inbox and the task list, as Linear shows an issue in its inbox: its agent's mark with
/// its state at the corner, its name (a dot before it while its reply is unread) and how long ago it moved, then what
/// it says in up to two lines.
struct TaskRow: View {
    let row: BoardRow
    /// What it says under its name: its reply, or the step that's the user's.
    let said: String?
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(alignment: .center, spacing: 12) {
                AgentAvatar(provider: row.provider, state: row.ownState)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Its name, then the unread dot right after it; a name too long for the line fades out at its
                        // end before the dot, as what it says fades before the time.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            FadingLine(text: row.task, font: .body.weight(.semibold))
                            // Centred on the name's capitals (about 12 pt tall at this size), not sat on its baseline
                            // like a full stop.
                            if row.ownState == .answered { Circle().fill(.blue).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 } }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !Described.says(said) { TimeBeside(at: row.at) }
                    }
                    if Described.says(said) { Described(text: said, at: row.at) }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Its avatar's edge under the page title's T (20.7 pt in): the circle fills its frame, unlike a padded icon.
        .listRowInsets(EdgeInsets(top: 6, leading: 20.5, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

/// An ask in the inbox, laid out as the rows under it: its task's avatar (needing you), its name and when, then the
/// question, answered in place.
struct InboxAskRow: View {
    let model: PhoneModel
    let ask: Ask

    var body: some View {
        let row = ask.session.flatMap { id in model.rows.first { $0.session == id } }
        HStack(alignment: .top, spacing: 12) {
            AgentAvatar(provider: row?.provider, state: .needsYou)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FadingLine(text: row?.task ?? ask.agent.label ?? ask.agent.name, font: .body.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    TimeBeside(at: Int(ask.createdAt.timeIntervalSince1970 * 1000))
                }
                AskCard(model: model, ask: ask, flat: true, inRow: true)
            }
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 6, leading: 20.5, bottom: 10, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

/// A task's conversation, as the Mac shows it, and a box to write to it.
struct TaskView: View {
    let model: PhoneModel
    let session: String
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @Environment(\.scenePhase) private var phase
    @State private var details = false
    /// The task's inbox open: what waits on you on it.
    @State private var asking = false
    @State private var couldNotLoad = false
    /// The Mac not reached since this page opened: said until it's back, through the tries again (each a moment of
    /// "connecting", which flipped the page between this and loading).
    @State private var missedMac = false

    /// Its history, asked for again a few times when the Mac doesn't answer, rather than once and then a blank page.
    private func loadUntilLoaded() async {
        couldNotLoad = false
        for attempt in 0..<5 {
            await model.load(session, again: attempt > 0 && model.conversation(session) == nil)
            if model.conversation(session) != nil { return }
            try? await Task.sleep(for: .seconds(2))
        }
        couldNotLoad = model.conversation(session) == nil
    }

    var body: some View {
        let conversation = model.conversation(session)
        let waiting: Int = conversation.map(model.waitingCount) ?? 0
        ScrollView {
            if let conversation { ConversationView(model: model, conversation: conversation).padding() }
            // Not loaded: a moment the Mac couldn't be reached left the page blank, with nothing to say so.
            // Can't reach the Mac (or it didn't answer): said, in the page's middle, not a spinner going on.
            else if couldNotLoad || missedMac {
                ContentUnavailableView {
                    Text(missedMac ? "Can't reach \(model.pairing?.name ?? "your Mac")" : "Couldn't load this task")
                } description: {
                    Text(missedMac ? "This task opens once your Mac is back." : "Your Mac didn't answer in time.")
                } actions: {
                    Button("Try again") { if model.offline { model.connect() }; Task { await loadUntilLoaded() } }.buttonStyle(.bordered)
                }
                .containerRelativeFrame(.vertical)
            } else {
                LoadingTurns()
            }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // The keyboard goes as the conversation is dragged down, as in Messages, or with a tap on the conversation:
        // the composer then folds back to its capsule when nothing is written.
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        // Where the reader is: at the bottom (or not scrolled yet), new words keep it there; scrolled up, they don't.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
        } action: { _, bottom in atBottom = bottom }
        // Opened, the conversation arrived, or grew: to the bottom, once it's laid out.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, _ in
            // After this layout, not inside it: asked mid-layout (the app opening on it from a notification), the scroll
            // was dropped and the page sat past its end, blank, until scrolled.
            if atBottom || old < 1 { DispatchQueue.main.async { position.scrollTo(edge: .bottom) } }
        }
        // Opened while the app comes up, or the conversation arriving after: to the bottom again once it's settled.
        .onChange(of: conversation == nil) { _, missing in if !missing { settle() } }
        .onChange(of: phase) { _, now in if now == .active, atBottom { settle() } }
        .safeAreaInset(edge: .bottom) { Composer(model: model, conversation: conversation, session: session) }
        // On screen, for Siri: "this" is this task ("save this for later", "what's it doing?").
        .appEntityIdentifier(EntityIdentifier(for: ZeroTask.self, identifier: session))
        .toolbar { bar(waiting: waiting) }
        .sheet(isPresented: $details) { TaskDetails(model: model, session: session).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $asking) { TaskInbox(model: model, session: session) }
        .environment(\.openTaskInbox) { asking = true }
        // The connection's state under this page's bar, not on its name.
        .overlay(alignment: .top) { if conversation != nil { ConnectionBadge(model: model) } }
        // Back: what didn't load is asked for again.
        .onChange(of: model.status, initial: true) { _, now in
            if model.offline { missedMac = true }
            if now == .connected { missedMac = false; if conversation == nil { Task { await loadUntilLoaded() } } }
        }
        .navigationTitle(model.rows.first { $0.session == session }?.task ?? model.names[session] ?? "Task")
        // Seen: its notification goes (on the Mac too, the board moving on).
        .onAppear {
            model.follow(session)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [session])
            model.markSeen(session)
            settle()
        }
        // A reply arriving while it's open is seen once you do something in it (tap, scroll): having it open isn't
        // reading it.
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in model.markSeen(session) })
        .simultaneousGesture(TapGesture().onEnded { model.markSeen(session) })
        .task { await loadUntilLoaded() }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ToolbarContentBuilder private func bar(waiting: Int) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            TaskInboxButton(count: waiting) { asking = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Details") { details = true }
                Button("Save for later") { Task { await model.askToSaveForLater(session) } }
            } label: { Image("dots-glyph") }
        }
    }

    /// To the bottom now, and again a moment on, once a push or the app's own opening has finished moving it.
    private func settle() {
        Task {
            for delay in [0.05, 0.35] {
                try? await Task.sleep(for: .seconds(delay))
                position.scrollTo(edge: .bottom)
            }
        }
    }
}

/// Apple's push: the token, quiet pushes that clear notifications seen on the Mac, and a tapped notification's task.
/// A notification's identifier is its task (the Mac sends it as the push's collapse id).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static weak var model: PhoneModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // A task's notification (the Notify extension marks them "task"): Reply, written on the notification itself.
        let reply = UNTextInputNotificationAction(identifier: Self.reply, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Reply to this task")
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "task", actions: [reply], intentIdentifiers: [], options: [])])
        return true
    }
    static let reply = "reply"

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Self.model?.setPushToken(hex) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let ids = info["clear"] as? [String] else { return .noData }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        return .newData
    }

    // In the app: its sound, no banner over what you're reading.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        // Replied to from the notification: to the task, through a link of its own, as the share sheet sends (iOS may
        // have started the app in the background just for this, before any page). Queued: between turns it goes at
        // once; while the task works, after its turn, never cutting into it.
        if let reply = response as? UNTextInputNotificationResponse, reply.actionIdentifier == Self.reply {
            let text = reply.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let pairing = Pairing.load(), let lines = try? TunnelLines(pairing: pairing) else { return }
            try? await ZerodLink(connection: lines).queue(session: id, text: text)
            return
        }
        await MainActor.run {
            // An ask's (not a task's): its card is in the Inbox. A task's opens the task.
            let ask = id.hasPrefix(TaskAlerts.askPrefix)
            Self.model?.tab = ask ? .inbox : .tasks
            Self.model?.path = ask ? [] : [id]
        }
    }
}

/// A task's details, as the Mac's pane has them: where it stands, where it runs, its ticket, agent and model, and the
/// attributes its agent set (links open).
struct TaskDetails: View {
    let model: PhoneModel
    let session: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        let row = model.row(session), conversation = model.conversation(session)
        NavigationStack {
            Form {
                Section {
                    if let row {
                        LabeledContent("State") { HStack(spacing: 6) { StateGlyph(state: row.ownState); Text(row.ownState.title) } }
                        if let now = row.needs ?? row.now, !now.isEmpty { Text(now).font(.subheadline).foregroundStyle(.secondary) }
                        if row.workers > 0 { LabeledContent("Workers", value: "\(row.workers)") }
                    }
                }
                Section {
                    LabeledContent("Where", value: row?.path ?? conversation.map { ($0.cwd as NSString).abbreviatingWithTildeInPath } ?? row?.place ?? "–")
                    if let branch = conversation?.branch { LabeledContent("Branch", value: branch) }
                    if let ticket = row?.ticket ?? conversation?.ticket { LabeledContent("Ticket", value: ticket) }
                }
                if let conversation {
                    Section {
                        LabeledContent("Agent", value: conversation.provider.title)
                        if let id = conversation.model { LabeledContent("Model", value: id + (conversation.effort.map { " · " + $0.capitalized } ?? "")) }
                        LabeledContent("Permissions", value: conversation.permissions == .unrestricted ? "Unrestricted" : "Auto")
                    }
                    if let attributes = conversation.attributes, !attributes.isEmpty {
                        Section("Attributes") {
                            ForEach(attributes.keys.sorted(), id: \.self) { key in
                                let value = attributes[key] ?? ""
                                if let url = URL(string: value), url.scheme?.hasPrefix("http") == true {
                                    Button { openURL(url) } label: { LabeledContent(key) { Text(url.host() ?? value).fontWeight(.medium).lineLimit(1) } }
                                        .foregroundStyle(.primary)
                                } else {
                                    LabeledContent(key, value: value)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(row?.task ?? model.names[session] ?? "Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// What needs the user, as the Mac's All tasks lays a board out: a heading and a line on what it holds, then its
/// rows. Asks to answer (in place), tasks over to them with a step only they can take, and replies not read yet; a
/// row opens its task.
struct InboxView: View {
    @Bindable var model: PhoneModel

    var body: some View {
        let handed = model.tasks.filter { $0.ownState == .handed }
        let unread = model.tasks.filter { $0.ownState == .answered }
        List {
            // Asks first, answered in place; then the tasks over to the user, then unread replies. No headings: each row's
            // badge says which it is, and the page's title says where you are.
            ForEach(model.waiting) { ask in InboxAskRow(model: model, ask: ask) }
            ForEach(handed) { row in item(row, row.needs ?? row.now) }
            ForEach(unread) { row in item(row, row.now) }
        }
        .listStyle(.plain)
        .overlay {
            // Shown: the inbox's page, nothing open over it. Emptied behind an open task (its reply read there), the
            // arrival waits until you're back, rather than playing unseen.
            if model.waiting.isEmpty && handed.isEmpty && unread.isEmpty {
                EmptyInbox(shown: model.tab == .inbox && model.path.isEmpty, pending: $model.arrivalPending)
            }
        }
        // Emptied: its arrival is owed, once.
        .onChange(of: model.waiting.isEmpty && handed.isEmpty && unread.isEmpty) { _, empty in if empty { model.arrivalPending = true } }
        .refreshable { model.connect() }
    }


    private func item(_ row: BoardRow, _ said: String?) -> some View {
        TaskRow(row: row, said: said) { model.path.append(row.session) }
    }
}

