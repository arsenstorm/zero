import PhotosUI
import SwiftUI
import UserNotifications
import VisionKit
import AppIntents

@main
struct ZeroPhone: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = PhoneModel.shared
    @Environment(\.scenePhase) private var phase

    init() {
        StateGlyph.terminal = { PhoneModel.shared.terminalName }
        // The workspace the Tasks list shows, for the share sheet's list of tasks to send to.
        Keychain.write("workspace", Data(PhoneModel.shared.workspace.utf8))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                    if CommandLine.arguments.contains("-composerTest") { TaskTestPage() } else { Root(model: model) }
                #else
                    Root(model: model)
                #endif
            }
            // Back in front: connected again if the connection dropped while away.
            .onChange(of: phase) { if phase == .active { Task { await model.wake() } } }
            // In front: the system's appearance, held while the app is away (Appearance).
            .onChange(of: phase, initial: true) { if phase == .active { Appearance.hold() } }
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

/// The app's appearance held to the system's while the app is in front, and kept as it was while it's away. To picture
/// a suspended app for the app switcher, iOS draws it again in the other appearance and then back, and part of it (a
/// list's rows, a toolbar's title) hadn't come back when the picture was taken: dark words on the dark page.
@MainActor enum Appearance {
    private static var followed = Set<ObjectIdentifier>()

    static func hold() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            pin(scene)
            // Changed while in front (Control Center, the evening's switch): followed at once.
            guard followed.insert(ObjectIdentifier(scene)).inserted else { continue }
            scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (scene: UIWindowScene, _) in
                if UIApplication.shared.applicationState == .active { pin(scene) }
            }
        }
    }

    /// The scene's traits are the system's; a window's override is the window's alone.
    private static func pin(_ scene: UIWindowScene) {
        for window in scene.windows { window.overrideUserInterfaceStyle = scene.traitCollection.userInterfaceStyle }
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
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(insertion: .opacity, removal: .modifier(active: Away(on: true), identity: Away(on: false))))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                            .onTapGesture { withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35)) { menu = false } }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            // Steadied (PhoneModel.banner): one message through a restart's many tries.
            if let banner = model.banner {
                Text(banner == .reconnecting ? "Reconnecting to your Mac" : "Can't reach \(model.pairing?.name ?? "your Mac")").font(
                    .footnote.weight(.medium)
                )
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 4)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.banner)
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
                Text(
                    turn == 1
                        ? "An answer a few lines long, written out across the page as the agent's answers are, ending here."
                        : "An answer, a couple of lines long, across the page as the agent's are.")
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
    static let names: [PhoneModel.Place: String] = [
        .inbox: "Inbox", .tasks: "Tasks", .later: "Later", .record: "Record", .settings: "Settings",
    ]

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
                        .contextMenu {
                            actions(row.session, name: row.task, state: row.ownState, workers: workers)
                        } preview: {
                            TaskPeek(row: row, name: row.task)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            swipes(row.session, name: row.task, state: row.ownState, workers: workers)
                        }
                        .swipeActions(edge: .leading) { renameSwipe(row.session, name: row.task) }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 36)
        .overlay {
            if model.tasks.isEmpty, model.status == .connected {
                EmptyPage(icon: "list-checkbox-glyph", title: "No tasks yet", line: "Start one with + below, or from your Mac.")
            }
        }
        // Zero's own sheet, as the Mac's: not the system's alert with a field in it.
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            RenameSheet(name: $newName) {
                if let renaming { Task { await model.rename(renaming.session, to: newName) } }
            }
        }
        // As the Mac asks: archiving puts the task away with every worker under it.
        .confirmationDialog(
            archiving.map { "Archive \($0.name)?" } ?? "",
            isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) { if let archiving { Task { await model.archive(archiving.session) } } }
        } message: {
            if let archiving {
                Text(
                    (archiving.workers == 0 ? "It" : "It and its \(archiving.workers == 1 ? "worker" : "\(archiving.workers) workers")")
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
        Button {
            archiving = (session, name, workers)
        } label: {
            Label("Archive", image: "archive-glyph")
        }.tint(.red)
        if state == .paused {
            Button {
                Task { _ = await model.unpause([session]) }
            } label: {
                Label("Resume", image: "media-play-glyph")
            }.tint(.blue)
        } else {
            Button {
                Task { _ = await model.pause([session]) }
            } label: {
                Label("Pause", image: "circle-pause-glyph")
            }.tint(.gray)
        }
    }

    /// Swiped right: rename.
    func renameSwipe(_ session: String, name: String) -> some View {
        Button {
            newName = name; renaming = (session, name)
        } label: {
            Label("Rename task", image: "pen-glyph")
        }.tint(.indigo)
    }

    /// A task's long press, as the Mac's row menu: pause or resume, rename, archive.
    @ViewBuilder func actions(_ session: String, name: String, state: BoardRow.State, workers: Int) -> some View {
        if state == .paused {
            Button {
                Task { _ = await model.unpause([session]) }
            } label: {
                Label("Resume", image: "media-play-glyph")
            }
        } else {
            Button {
                Task { _ = await model.pause([session]) }
            } label: {
                Label("Pause", image: "circle-pause-glyph")
            }
        }
        Button {
            newName = name; renaming = (session, name)
        } label: {
            Label("Rename task", image: "pen-glyph")
        }
        Button {
            Task { await model.saveForLater(session) }
        } label: {
            Label("Save for later", image: "bookmark-glyph")
        }
        Button(role: .destructive) {
            archiving = (session, name, workers)
        } label: {
            Label("Archive…", image: "archive-glyph")
        }
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
                Text(StateGlyph.look(row.ownState).name).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(name).font(.headline).lineLimit(2)
            if let now = row.now, !now.isEmpty { Text(now).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }
            if let needs = row.needs { Label("For you: " + needs, image: "hand-holding-box-glyph").font(.subheadline) }
            ForEach(row.asks.prefix(3), id: \.id) { ask in Label(ask.title, image: "circle-question-glyph").font(.subheadline).lineLimit(2)
            }
            if let queued = row.queued, !queued.isEmpty {
                Label("\(queued.count) queued" + (row.held == true ? ", held" : ""), image: "clock-glyph").font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
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
                    FadingLine(text: row?.task ?? ask.agent.label ?? ask.agent.name, font: .body.weight(.semibold)).frame(
                        maxWidth: .infinity, alignment: .leading)
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
    /// Opened: held at the end until then, while the page settles (a long conversation's turns, its markdown and the
    /// composer's inset laying out after the first scroll left it short of its end), or until you touch it.
    @State private var settling = Date.distantPast
    /// The conversation's end and the page's foot, and ↓ (TaskEnd).
    @State private var end = TaskEnd()
    /// Your message just sent, lifted to the page's top with room under it for the answer (as ChatGPT's): its id, and
    /// the room, a screen's height without the keyboard, so the keyboard going doesn't take it away.
    @State private var lifted: (id: String, room: CGFloat)?
    /// One of this task's asks just answered (here, in its inbox, or the Inbox): when, and the items there were then.
    /// What it brings is lifted when it lands, as a message sent is: the user acted in this task.
    @State private var answered: (at: Date, known: Set<String>)?
    /// What the composer opens over the page, presented here.
    @State private var panels = ComposerPanels()
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var details = false
    /// The task's inbox open: what waits on you on it.
    @State private var asking = false
    @State private var couldNotLoad = false
    /// The Mac not reached since this page opened: said until it's back, through the tries again (each a moment of
    /// "connecting", which flipped the page between this and loading).
    @State private var missedMac = false

    /// Its history, asked for again a few times when the Mac doesn't answer, rather than once and then a blank page.
    /// To the end while the page settles after opening. After this layout, not inside it: asked mid-layout (the app
    /// opening on it from a notification), the scroll was dropped and the page sat past its end, blank, until scrolled.
    private func settle() {
        guard Date() < settling else { return }
        DispatchQueue.main.async { position.scrollTo(edge: .bottom) }
    }

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
            if let conversation {
                ConversationView(model: model, conversation: conversation, lift: lifted?.room ?? 0, liftAt: lifted?.id, end: end)
                    .padding()
            }
            // Not loaded: a moment the Mac couldn't be reached left the page blank, with nothing to say so.
            // Can't reach the Mac (or it didn't answer): said, in the page's middle, not a spinner going on.
            else if couldNotLoad || missedMac {
                ContentUnavailableView {
                    Label {
                        Text(missedMac ? "Can't reach \(model.pairing?.name ?? "your Mac")" : "Couldn't load this task")
                    } icon: {
                        Image("link-slash-outline").resizable().frame(width: 28, height: 28).foregroundStyle(.secondary)
                    }
                } description: {
                    Text(missedMac ? "This task opens once your Mac is back." : "Your Mac didn't answer in time.")
                } actions: {
                    WideButton(title: "Try again", prominent: true) {
                        if model.offline { model.connect() }; Task { await loadUntilLoaded() }
                    }
                    .padding(.horizontal, 40)
                }
                .containerRelativeFrame(.vertical)
            } else {
                LoadingTurns()
            }
        }
        .scrollPosition($position)
        // Opened at the end; after that only you scroll: words added below don't move what you're reading.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        // The keyboard goes as the conversation is dragged down, as in Messages, or with a tap on the conversation:
        // the composer then folds back to its capsule when nothing is written.
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        )
        // Opened, or the conversation arrived: to the bottom, once it's laid out. After that only you scroll: growing,
        // it isn't followed (ChatGPT's way: followed, the words being read slid up under the eye); ↓ goes there.
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentSize.height
        } action: { old, _ in
            if old < 1 { settling = Date().addingTimeInterval(1) }
            settle()
        }
        .onChange(of: conversation == nil) { _, missing in
            if !missing { settling = Date().addingTimeInterval(1); settle() }
        }
        .onAppear {
            settling = Date().addingTimeInterval(1); settle()
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { settling = .distantPast }
        }
        // The keyboard about to move: whether the end is in view now, and the keyboard's own time and curve.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            end.keyboardWillMove(note)
        }
        // The room at the foot changed (the keyboard came or went, the composer grew or shrank): the end held above it
        // if it was in view.
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentInsets.bottom
        } action: { _, _ in
            if Date() < settling { settle() } else { DispatchQueue.main.async { end.footMoved() } }
        }
        // An ask of this task answered: what it brings (zerod telling the agent, the agent's reply) lifted to the top
        // when it lands, with the room under it. Content coming on its own still never scrolls the page.
        .onChange(of: model.acted[session]) { _, _ in askAnswered() }
        .onChange(of: conversation?.items.count) { _, _ in answerLanded() }
        // Yours sent: lifted to the top, with the room under it for the answer, once that room is laid out.
        .onChange(of: model.sending[session]?.last?.id) { _, sent in
            guard let sent else { return }
            lifted = (sent, end.room)
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { position.scrollTo(id: ConversationView.lifted, anchor: .top) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Composer(model: model, conversation: conversation, session: session, panels: panels)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: { _ in
                    DispatchQueue.main.async { end.footMoved() }
                }
                // The page fades out above the composer and is solid under it, its queue strip included: the
                // conversation read through the gaps (a reply's line cut in half between the strip and the box, a
                // bubble past the capsule's end).
                .background(alignment: .top) { ComposerFade(end: end) }
                // Past the end of what's on screen: a way down, once, as ChatGPT's. Over the fade, 10 pt above the
                // composer: under it, the fade dimmed its lower half.
                .overlay(alignment: .top) {
                    if conversation != nil, end.down {
                        Button {
                            // To the conversation's end, not into the empty room under it.
                            end.toEnd()
                        } label: {
                            Image("arrow-down-outline").resizable().frame(width: 14, height: 14)
                                .foregroundStyle(.primary)
                                // Solid: a material let the line of text under it read through ("Sim↓ator").
                                .frame(width: 36, height: 36).background(Color(uiColor: .secondarySystemBackground), in: Circle())
                                .overlay(Circle().strokeBorder(.quaternary))
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.top) { $0[.bottom] + 10 }
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                        .accessibilityLabel("To the end")
                    }
                }
        }
        // The keyboard's room is SwiftUI's own: it moves in the keyboard's own animation (and with a finger taking it
        // down from the conversation), so the composer stays on the keyboard's top. Followed by hand, a frame at a time,
        // the composer jumped ahead of the keyboard as it opened (measured in the Simulator: 313 pt in one frame).
        // Photos and videos (a screen recording goes to the agent as a file, as from the Mac).
        .photosPicker(
            isPresented: $panels.picking, selection: $panels.picked, maxSelectionCount: 10, matching: .any(of: [.images, .videos])
        )
        .sheet(isPresented: $panels.selecting) { modelSheet(conversation) }
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
        }
        // A reply arriving while it's open is seen once you do something in it (tap, scroll): having it open isn't
        // reading it.
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in model.markSeen(session) })
        .simultaneousGesture(TapGesture().onEnded { model.markSeen(session) })
        .task { await loadUntilLoaded() }
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The composer's model and effort for the next message: the Mac's selector, as a sheet.
    @ViewBuilder private func modelSheet(_ conversation: Conversation?) -> some View {
        if let conversation {
            let provider = conversation.provider
            let id = panels.chosen?.model ?? conversation.model
            let effort = panels.chosen?.effort ?? conversation.effort
            ModelSelector(agents: [.init(provider: provider, models: panels.models)], current: (provider, id, effort)) { _, picked, level in
                guard let picked else { return }
                panels.chosen = (picked, level)
                // Mid-turn, as the Mac's chip: zerod keeps it for the next turn now, not with a message (which would
                // have to go at once, steering the turn, to carry it).
                if conversation.status == .working || conversation.status == .waiting {
                    Task { await model.switchModel(session, provider: provider, model: picked, effort: level) }
                }
            }
        }
    }

    /// One of this task's asks just answered: the items there are now, to know what it brings.
    private func askAnswered() {
        answered = (Date(), Set(model.conversation(session)?.items.map(\.id) ?? []))
    }

    /// The first message an answer brought (zerod telling the agent of it), lifted to the top.
    private func answerLanded() {
        guard let answered, Date().timeIntervalSince(answered.at) < 120, let items = model.conversation(session)?.items else { return }
        let new = items.first { item in
            guard !answered.known.contains(item.id), case .user = item.kind else { return false }
            return true
        }
        guard let event = new else { return }
        self.answered = nil
        lifted = (event.id, end.room)
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { position.scrollTo(id: ConversationView.lifted, anchor: .top) }
        }
    }

    /// The tray and ⋯ in one item, 36 pt apart, each tappable 4 pt past its 36 pt slot (44 pt targets, meeting in the
    /// middle): as two items, the bar's glass pill held them far apart with an empty middle.
    @ToolbarContentBuilder private func bar(waiting: Int) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 0) {
                TaskInboxButton(count: waiting) { asking = true }
                    .frame(width: 36, height: 44).contentShape(Rectangle().inset(by: -4))
                Menu {
                    Button("Details") { details = true }
                    Button("Save for later") { Task { await model.saveForLater(session) } }
                } label: {
                    Image("dots-glyph").frame(width: 36, height: 44).contentShape(Rectangle().inset(by: -4))
                }
                .accessibilityLabel("More")
            }
        }
    }

    /// To the bottom now, and again a moment on, once a push or the app's own opening has finished moving it.
}

/// A conversation's end and the page's foot, measured in the page's own scroll view (UIKit's, at one moment, in its
/// content's points), and the ↓ button. The end is the conversation's last row's foot (EndMarker), whatever room lies
/// under it; ↓ shows when it's below what's on screen. Growing never scrolls the page; the keyboard coming or going,
/// or the composer growing, scrolls it once, with the keyboard, and only when the end was in view.
/// The page's fade above the composer, with the solid under it. Only while something runs under it (TaskEnd's
/// `under`): at the end it looked like more to scroll.
private struct ComposerFade: View {
    let end: TaskEnd

    var body: some View {
        #if DEBUG
            let _ = FrameLog.fade = end.under
        #endif
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Color(uiColor: .systemBackground).opacity(0), Color(uiColor: .systemBackground)], startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 40)
            .opacity(end.under)
            Color(uiColor: .systemBackground)
        }
        .padding(.top, -40)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        #if DEBUG
            // Its alpha, for the UI tests.
            .overlay {
                if CommandLine.arguments.contains("-composerTest") {
                    Color.clear.frame(width: 1, height: 1).accessibilityElement()
                    .accessibilityIdentifier("test.fade").accessibilityValue(String(end.under))
                }
            }
        #endif
    }
}

@MainActor @Observable final class TaskEnd {
    /// ↓ shows: the conversation's last row is below what's on screen.
    private(set) var down = false
    /// How far the conversation runs under the composer's fade: none with its end in view (where ↓ takes it), all of
    /// it once the end is at the page's foot or past it, in between as it comes.
    private(set) var under: Double = 0
    @ObservationIgnored weak var scroll: UIScrollView?
    @ObservationIgnored weak var marker: UIView?
    /// Not worked out again before then: a scroll of ours is running.
    @ObservationIgnored private var still = Date.distantPast
    /// The keyboard moving: its time and curve, and how the end stood as it began to.
    @ObservationIgnored private var keyboard: (duration: Double, curve: UInt, visible: Bool, close: Bool, end: CGFloat?, at: Date)?
    /// The room at the page's foot (the composer, the keyboard), as last seen.
    @ObservationIgnored private var foot: CGFloat?
    /// The last row this far above the page's foot when it's held there.
    private static let margin: CGFloat = 24

    /// Where an answer being read out has got to (ReadingMarker): its unread words are laid out, unseen, and the page
    /// followed them as the keyboard moved, scrolling to keep blank lines above it.
    @ObservationIgnored weak var reading: UIView?
    /// The room at the page's foot with the keyboard down: the closed composer and the home indicator, as measured.
    @ObservationIgnored private var resting: CGFloat?
    @ObservationIgnored private var keyboardUp = false
    /// Where the page was scrolled before a change at its foot: UIKit clamps it to the new end before footMoved runs
    /// (a queued message's strip going, at the end, dropped the page 82 pt in a frame).
    @ObservationIgnored private var lastOffset: CGFloat?
    /// And where its end was then: content coming in the same moment (a queued message sent on as its strip goes)
    /// moved the end down, and the page, judged by the new end, was let drop.
    @ObservationIgnored private var lastEnd: CGFloat?

    /// The conversation's end as seen: where the read-out has got to, while one is under way, or its last row.
    private var endY: CGFloat? {
        guard let scroll else { return nil }
        if let reading, reading.window != nil { return reading.convert(CGPoint(x: 0, y: reading.bounds.maxY), to: scroll).y }
        guard let marker, marker.window != nil else { return nil }
        return marker.convert(CGPoint(x: 0, y: marker.bounds.maxY), to: scroll).y
    }

    /// The page's foot (above the composer and keyboard), in the content's points, with the room there `foot`.
    private func bottom(_ foot: CGFloat) -> CGFloat {
        guard let scroll else { return 0 }
        return scroll.contentOffset.y + scroll.bounds.height - foot
    }

    /// The end in view, or within a little of it.
    private func visible(_ foot: CGFloat) -> Bool { endY.map { $0 <= bottom(foot) + 12 } ?? true }
    /// In view and near the foot: the page is at the end (not lifted, the end higher up with room under it).
    private func close(_ foot: CGFloat) -> Bool { endY.map { visible(foot) && $0 >= bottom(foot) - 60 } ?? false }

    /// A screen's height without the keyboard, less the closed composer: the room under a message just sent. From the
    /// foot as measured with the keyboard down: guessed (90 pt), it was 16 pt short, and the lifted message slid down as
    /// the keyboard closed.
    var room: CGFloat {
        guard let scroll, let window = scroll.window else { return 600 }
        return window.bounds.height - scroll.adjustedContentInset.top - (resting ?? window.safeAreaInsets.bottom + 90)
            - ConversationView.liftGap
    }

    /// The page's scroll view and its end found: the room at its foot as it is now, so the first change after (the
    /// keyboard coming up the first time a task is opened) is followed. Known only from that change, it was taken as
    /// the starting point, and the conversation didn't lift the first time.
    func found() {
        if foot == nil, let scroll { foot = scroll.adjustedContentInset.bottom }
        if !keyboardUp, let foot { resting = foot }
        recount()
    }

    /// The page scrolled, or the conversation changed: ↓ again.
    func recount() {
        guard let scroll else { return }
        let foot = scroll.adjustedContentInset.bottom
        // The fade follows every frame, our own glides included (↓, the keyboard): none with the page at its end (the
        // last row its padding, 16 pt, above the foot), all of it 24 pt further down, in steps of 5 %.
        let depth = endY.map { ($0 - (bottom(foot) - 16)) / Self.margin } ?? 1
        let fade = (min(1, max(0, depth)) * 20).rounded() / 20
        // A jump (↓'s glide, which sets where it ends at once) eased over its time, not in a frame.
        if abs(under - fade) > 0.3 {
            withAnimation(.easeOut(duration: 0.3)) { under = fade }
        } else if under != fade {
            under = fade
        }
        guard Date() >= still else { return }
        // Only with the foot as footMoved last took it: between a change at the foot and footMoved, the page has
        // already been clamped by UIKit, and that's not where it was.
        if self.foot.map({ abs($0 - foot) < 0.5 }) ?? true {
            lastOffset = scroll.contentOffset.y
            lastEnd = endY
        }
        let now = !visible(foot)
        if down != now { down = now }
    }

    func keyboardWillMove(_ note: Notification) {
        guard let scroll else { return }
        let info = note.userInfo ?? [:]
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        let foot = foot ?? scroll.adjustedContentInset.bottom
        if let frame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let screen = scroll.window?.screen {
            keyboardUp = frame.minY < screen.bounds.maxY - 1
        }
        keyboard = (duration, curve, visible(foot), close(foot), endY, Date())
        still = Date().addingTimeInterval(duration + 0.1)
    }

    /// The room at the page's foot changed: if the end was in view, it stays in view, just above it (at the end,
    /// held there whether the room grew or shrank); one scroll, on the keyboard's own time and curve when it's the
    /// keyboard.
    func footMoved() {
        guard let scroll else { return }
        let now = scroll.adjustedContentInset.bottom
        guard let before = foot else { foot = now; recount(); return }
        guard abs(now - before) > 0.5, let endY else { return }
        foot = now
        if !keyboardUp { resting = now }
        let moving = keyboard.flatMap { Date().timeIntervalSince($0.at) < $0.duration + 0.3 ? $0 : nil }
        // As it stood before the change: the end and offset recorded then, not the ones it brought.
        let then = (end: lastEnd ?? endY, bottom: (lastOffset ?? scroll.contentOffset.y) + scroll.bounds.height - before)
        let wasVisible = moving?.visible ?? (then.end <= then.bottom + 12)
        let wasClose = moving?.close ?? (wasVisible && then.end >= then.bottom - 60)
        guard wasVisible else { recount(); return }
        // Where the end was as the keyboard began to move: a read-out going on meanwhile was chased, the page
        // scrolling on with each step of the move (measured: 130 pt past the words read when it began).
        let fit = (moving?.end ?? endY) + Self.margin - (scroll.bounds.height - now)
        let lowest = -scroll.adjustedContentInset.top
        let highest = max(lowest, scroll.contentSize.height + now - scroll.bounds.height)
        // From where the page was before the change (UIKit may have clamped it already; it's put back, so the move is
        // one glide, not a drop and then a second move).
        let from = (moving == nil ? lastOffset : nil) ?? scroll.contentOffset.y
        // At the end: by the foot's change, as it was when the move began. Worked out from where the end is now, a
        // read-out gone on since had the page scroll again after the keyboard had settled.
        let target = min(highest, max(lowest, wasClose ? from + (now - before) : max(from, fit)))
        if abs(from - scroll.contentOffset.y) > 0.5, abs(target - from) >= 40 { scroll.contentOffset.y = from }
        lastOffset = target
        lastEnd = endY
        guard abs(target - scroll.contentOffset.y) > 0.5 else { return }
        // A step of a move already under way (the box growing frame by frame, the keyboard following a finger): taken
        // as it comes. Animated, each frame's started a new animation and the page trailed behind.
        if abs(target - scroll.contentOffset.y) < 40 {
            scroll.contentOffset.y = target
            return
        }
        let duration = moving?.duration ?? 0.25
        // The keyboard's curve (7) is a spring that runs about half a second whatever its duration: nothing is
        // recorded from the page until it's done (a mid-glide offset was taken as where the page stood).
        still = Date().addingTimeInterval(max(duration, 0.5) + 0.05)
        UIView.animate(
            withDuration: duration, delay: 0,
            options: [UIView.AnimationOptions(rawValue: (moving?.curve ?? 7) << 16), .beginFromCurrentState, .allowUserInteraction]
        ) {
            scroll.contentOffset.y = target
        } completion: { _ in
            self.still = .distantPast
            self.recount()
        }
    }

    /// ↓: the conversation's last row just above the page's foot.
    func toEnd() {
        guard let scroll, let endY else { return }
        let foot = scroll.adjustedContentInset.bottom
        let lowest = -scroll.adjustedContentInset.top
        let highest = max(lowest, scroll.contentSize.height + foot - scroll.bounds.height)
        let target = min(highest, max(lowest, endY + Self.margin - (scroll.bounds.height - foot)))
        down = false
        still = Date().addingTimeInterval(0.4)
        // A jump under Reduce Motion, not a glide.
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.35, delay: 0, options: [.curveEaseOut, .allowUserInteraction]
        ) {
            scroll.contentOffset.y = target
        } completion: { _ in
            self.still = .distantPast
            self.recount()
        }
    }
}

/// Where an answer being read out has got to, as a view of UIKit's, handed to TaskEnd (StreamingText places it).
struct ReadingMarker: UIViewRepresentable {
    let end: TaskEnd?
    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.end = end
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Marker, context: Context) { view.end = end }

    final class Marker: UIView {
        weak var end: TaskEnd?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { end?.reading = self } else if end?.reading === self { end?.reading = nil }
            end?.recount()
        }
    }
}

/// The conversation's end, as a view of UIKit's: where it is in the page's scroll view, which it finds and hands to
/// TaskEnd.
struct EndMarker: UIViewRepresentable {
    let end: TaskEnd?
    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.end = end
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Marker, context: Context) { view.end = end }

    final class Marker: UIView {
        weak var end: TaskEnd?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let end else { return }
            var view = superview
            while let next = view, !(next is UIScrollView) { view = next.superview }
            end.scroll = view as? UIScrollView
            end.marker = self
            end.found()
        }
    }
}

/// Apple's push: the token, quiet pushes that clear notifications seen on the Mac, and a tapped notification's task.
/// A notification's identifier is its task (the Mac sends it as the push's collapse id).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static weak var model: PhoneModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil)
        -> Bool
    {
        UNUserNotificationCenter.current().delegate = self
        // The watch's way to the Mac (iOS starts the app in the background when the watch asks something of it).
        WatchBridge.shared.start()
        // A task's notification (the Notify extension marks them "task"): Reply, written on the notification itself.
        let reply = UNTextInputNotificationAction(
            identifier: Self.reply, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Reply to this task")
        // Beside the asks' (AskActions), which the Notify extension registers as they come.
        Task { await AskActions.register(UNNotificationCategory(identifier: "task", actions: [reply], intentIdentifiers: [], options: [])) }
        return true
    }
    static let reply = "reply"

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Self.model?.setPushToken(hex) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // Every push wakes the app a moment (the Mac marks them so): the watch hears what changed.
        await WatchBridge.shared.refresh()
        guard let ids = info["clear"] as? [String] else { return .noData }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        // Nothing on screen changed. New data makes iOS draw the app again, suspended, for the app switcher, and that
        // drawing came out half in light mode: the conversation's words black on its black page.
        return .noData
    }

    // In the app: its sound, no banner over what you're reading.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        // An ask answered from its notification (here or on the watch): an option, an option's words, or a reply.
        if let ask = response.notification.request.content.userInfo["ask"] as? String, await answer(ask, response) { return }
        // Replied to from the notification: to the task, through a link of its own, as the share sheet sends (iOS may
        // have started the app in the background just for this, before any page). Queued: between turns it goes at
        // once; while the task works, after its turn, never cutting into it.
        if let reply = response as? UNTextInputNotificationResponse, reply.actionIdentifier == Self.reply {
            let text = reply.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let pairing = Pairing.load(), let lines = try? TunnelLines(pairing: pairing) else { return }
            try? await ZerodLink(connection: lines).queue(session: id, text: text)
            return
        }
        await openNotified(id)
    }

    /// Answered through a link of its own, as a reply is: whether it was an answer.
    private func answer(_ ask: String, _ response: UNNotificationResponse) async -> Bool {
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let option = action.hasPrefix(AskActions.option) ? Int(action.dropFirst(AskActions.option.count)) : nil
        guard option != nil || action == AskActions.reply else { return false }
        if text?.isEmpty == true { return true }
        guard let pairing = Pairing.load(), let lines = try? TunnelLines(pairing: pairing) else { return true }
        let link = ZerodLink(connection: lines)
        defer { link.close() }
        switch (option, text) {
        case let (index?, text?): try? await link.answer(ask, option: index, text: text)
        case let (index?, nil): try? await link.choose(ask, option: index)
        case let (nil, text?): try? await link.reply(ask, text: text)
        default: break
        }
        return true
    }

    private func openNotified(_ id: String) async {
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let row = model.row(session), conversation = model.conversation(session)
        NavigationStack {
            // The app's own page (PageParts), as Settings: not the system's grouped form.
            PageScroll {
                if let row {
                    PageGroup(note: (row.needs ?? row.now).flatMap { $0.isEmpty ? nil : $0 }) {
                        HStack(spacing: 12) {
                            StateGlyph(state: row.ownState, size: 20)
                            Text(StateGlyph.look(row.ownState).name)
                            Spacer(minLength: 12)
                        }
                        .frame(minHeight: 46)
                        if row.workers > 0 { PageRow(title: "Workers", value: "\(row.workers)") }
                    }
                }
                PageGroup {
                    PageRow(
                        title: "Where",
                        value: row?.path ?? conversation.map { ($0.cwd as NSString).abbreviatingWithTildeInPath } ?? row?.place ?? "–")
                    if let branch = conversation?.branch { PageRow(title: "Branch", value: branch) }
                    if let ticket = row?.ticket ?? conversation?.ticket { PageRow(title: "Ticket", value: ticket) }
                }
                if let conversation {
                    PageGroup {
                        PageRow(title: "Agent", value: conversation.provider.title)
                        if let id = conversation.model {
                            PageRow(title: "Model", value: id + (conversation.effort.map { " · " + $0.capitalized } ?? ""))
                        }
                        PageRow(title: "Permissions", value: conversation.permissions == .unrestricted ? "Unrestricted" : "Auto")
                    }
                    if let attributes = conversation.attributes, !attributes.isEmpty {
                        PageGroup(title: "Attributes") {
                            ForEach(attributes.keys.sorted(), id: \.self) { key in
                                let value = attributes[key] ?? ""
                                if let url = URL(string: value), url.scheme?.hasPrefix("http") == true {
                                    // A link in a property: medium weight on a dashed line, as the Mac's.
                                    Button {
                                        openURL(url)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Text(key)
                                            Spacer(minLength: 12)
                                            Text(url.host() ?? value).fontWeight(.medium).lineLimit(1)
                                                .overlay(alignment: .bottom) { DashedRule().offset(y: -1.5) }
                                        }
                                        .frame(minHeight: 46).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    PageRow(title: key, value: value)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(row?.task ?? model.names[session] ?? "Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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

/// How much of the keyboard is on screen, frame by frame as it's drawn: from its top to the screen's foot, less the
/// home indicator's room. Followed while it moves on its own (announced) and while it's up (a finger can take it down,
/// unannounced until it lets go). The composer opens and closes by it (Composer).
struct KeyboardFollow: UIViewRepresentable {
    /// The keyboard's room now, and when it's all the way up (as iOS last announced it).
    let room: (CGFloat, CGFloat) -> Void
    func makeUIView(context: Context) -> Follower {
        let view = Follower()
        view.room = room
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Follower, context: Context) { view.room = room }
    static func dismantleUIView(_ view: Follower, coordinator: ()) { view.stop() }

    final class Follower: UIView {
        var room: (CGFloat, CGFloat) -> Void = { _, _ in }
        private var full: CGFloat = 0
        private var told: CGFloat = 0
        private var link: CADisplayLink?

        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(
                self, selector: #selector(moves(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() }
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        private var bottom: CGFloat { (window?.screen.bounds.maxY ?? 0) - (window?.safeAreaInsets.bottom ?? 0) }

        /// Pinned to the keyboard's top by its layout guide, which follows a finger taking it down frame by frame.
        private lazy var probe: UIView = {
            let probe = UIView()
            probe.isUserInteractionEnabled = false
            probe.translatesAutoresizingMaskIntoConstraints = false
            addSubview(probe)
            NSLayoutConstraint.activate([
                probe.heightAnchor.constraint(equalToConstant: 1), probe.widthAnchor.constraint(equalToConstant: 1),
                probe.leadingAnchor.constraint(equalTo: leadingAnchor),
                probe.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            ])
            return probe
        }()

        /// Until when the keyboard is moving on its own (its announced time): followed frame by frame till then.
        private var until = Date.distantPast
        private var up = false

        @objc private func moves(_ note: Notification) {
            guard window != nil, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let time = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            up = frame.minY < (window?.screen.bounds.maxY ?? 0) - 1
            if up { full = max(0, bottom - frame.minY) }
            until = Date().addingTimeInterval(time + 0.1)
            _ = probe
            if link == nil {
                let link = CADisplayLink(target: self, selector: #selector(frameTick))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        }

        /// The keyboard's top where it is on screen this frame (its guide's layer as drawn, mid-animation too), while
        /// it moves on its own or is up (a finger can take it down at any time). Read on SwiftUI's own approximation
        /// of the keyboard's curve, the composer trailed the keyboard as it rose and was covered for a moment.
        @objc private func frameTick() {
            guard window != nil else { return }
            // As drawn: the probe's and every ancestor's layer as presented this frame. Not laid out again here (the
            // guide was at the keyboard's end at once), nor converted with the views' own frames (this view rides the
            // keyboard with the composer: its frame was the keyboard's end at once too).
            var foot = (probe.layer.presentation() ?? probe.layer).frame.maxY
            var view: UIView? = self
            while let current = view, !(current is UIWindow) {
                let layer = current.layer.presentation() ?? current.layer
                let parent = current.superview.map { $0.layer.presentation() ?? $0.layer }
                foot += layer.frame.minY - (parent?.bounds.minY ?? 0)
                view = current.superview
            }
            tell(max(0, bottom - foot), animated: false)
            if !up, Date() > until { stop() }
        }

        private func tell(_ now: CGFloat, animated: Bool) {
            guard abs(now - told) > 0.5 else { return }
            told = now
            room(now, full)
        }
    }
}
