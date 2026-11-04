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
            // Dropped: tried again every few seconds while the app is in front.
            .task(id: model.status) {
                guard case .offline = model.status, phase == .active else { return }
                try? await Task.sleep(for: .seconds(4))
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

    var body: some View {
        let screen: Screen = !model.paired ? .pair : model.rows.isEmpty && model.status != .connected ? .splash : .home
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
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.55), value: screen)
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
    var body: some View {
        let look = Self.look(state)
        if state == .working { Spinner().frame(width: 14, height: 14).frame(width: 16, height: 16) }
        else { Image(look.icon).resizable().frame(width: 16, height: 16).foregroundStyle(look.color) }
    }

    static func look(_ state: BoardRow.State) -> (icon: String, color: Color, name: String) {
        switch state {
        case .needsYou: ("hand-3-glyph", .blue, "Needs you")
        case .trouble: ("triangle-warning-glyph", .orange, "In trouble")
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

/// Before pairing: scan the code from the Mac's Settings › Devices.
struct PairView: View {
    let model: PhoneModel
    @State private var scanning = false
    @State private var pasted = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Zero").font(.largeTitle.weight(.semibold))
            Text("On your Mac, open Zero's Settings › Devices, choose Show code, and scan it here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
            Button("Scan the code") { scanning = true }
                .buttonStyle(.borderedProminent).disabled(!DataScannerViewController.isSupported)
            TextField("Or paste its link", text: $pasted).textFieldStyle(.roundedBorder).padding(.horizontal, 32)
                .onSubmit { wrong = !model.pair(pasted) }
            if wrong { Text("That isn't a Zero pairing link.").foregroundStyle(.red).font(.footnote) }
            Spacer()
        }
        .sheet(isPresented: $scanning) {
            Scanner { text in
                scanning = false
                wrong = !model.pair(text)
            }
            .ignoresSafeArea()
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

/// Paired: the tasks and recording, under the glass tab bar.
struct Home: View {
    @Bindable var model: PhoneModel
    @State private var settings = false
    @State private var choosing = false
    @State private var newTask = false

    // The stack holds the tabs, not the other way round: a task slides in over the tab bar and back out with it there
    // all along (hidden from inside a tab, it came back only once the way back had finished).
    var body: some View {
        NavigationStack(path: $model.path) {
            // Four tabs at most: a fourth, when one is needed, is a ⋯ menu of the rest.
        TabView(selection: $model.tab) {
                // What waits on the user first: its count, as the Mac's inbox has one.
                Tab("Inbox", image: "inbox-glyph", value: PhoneModel.Place.inbox) { InboxView(model: model) }
                    .badge(model.waiting.count)
                Tab("Tasks", image: "list-checkbox-glyph", value: PhoneModel.Place.tasks) { TasksView(model: model) }
                Tab("Later", image: "bookmark-glyph", value: PhoneModel.Place.later) { LaterView(model: model) }
                Tab("More", image: "dots-glyph", value: PhoneModel.Place.more) { MoreView(model: model) }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .sheet(isPresented: $settings) { SettingsView(model: model) }
            .sheet(isPresented: $newTask) { NewTaskSheet(model: model) }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in TaskView(model: model, session: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Logo() }.sharedBackgroundVisibility(.hidden)
                // The workspace shown, as the Mac's sidebar heading has it: the phone's own choice.
                if model.workspaces.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { choosing = true } label: {
                            HStack(spacing: 5) {
                                Text(model.currentWorkspace.map(Self.title) ?? "Zero").font(.subheadline.weight(.semibold)).lineLimit(1)
                                Image("chevron-down-outline").resizable().frame(width: 10, height: 10).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                        }
                        // Zero's own list, not the system menu: the tick at the right edge, where it's read last.
                        .popover(isPresented: $choosing) {
                            VStack(spacing: 2) {
                                ForEach(model.workspaces) { space in
                                    Button { model.switchWorkspace(space.id); choosing = false } label: {
                                        HStack {
                                            Text(Self.title(space)).lineLimit(1)
                                            Spacer(minLength: 16)
                                            Image("circle-check-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(Color.accentColor)
                                                .opacity(space.id == model.currentWorkspace?.id ? 1 : 0)
                                        }
                                        .padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(6)
                            .frame(width: 260)
                            .presentationCompactAdaptation(.popover)
                        }
                    }
                }
                // A new task, beside the settings, as the Mac's New task.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { newTask = true } label: { Image("plus-outline") }
                    Button { settings = true } label: { Image("gear-outline") }
                }
            }
        }
        .overlay(alignment: .top) {
            // Dropped after loading: what's here stays, the line says it's being got back.
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

extension Home {
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

/// Before the first board: the mark, and connecting, or why it can't (tried again on its own every few seconds).
struct Splash: View {
    let model: PhoneModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Logo(size: 72)
            if case .offline(let why) = model.status {
                Text("Can't reach your Mac").font(.title3.weight(.semibold))
                Text("Zero needs to be open on your Mac, and both online. Trying again…")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(why).font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                Button("Try again") { model.connect() }.buttonStyle(.glassProminent).padding(.top, 8)
            } else {
                Text("Connecting to your Mac").font(.title3.weight(.semibold))
                Spinner().frame(width: 22, height: 22)
            }
            Spacer()
            Menu("Pairing") { Button("Unpair this phone", role: .destructive) { model.unpair() } }
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(32)
        .animation(.easeOut(duration: 0.2), value: model.status)
    }
}

/// The asks waiting on you, then every task, most urgent first, as the Mac's board sorts them; as its sidebar has
/// them, each lead's workers folded under it, a chevron opening them.
struct TasksView: View {
    let model: PhoneModel
    @State private var open: Set<String> = []
    @State private var renaming: (session: String, name: String)?
    @State private var newName = ""
    @State private var archiving: (session: String, name: String, workers: Int)?

    var body: some View {
        List {
            Section("Tasks") {
                ForEach(model.tasks) { row in
                    let members = (row.team ?? []).filter { $0.session != row.session }.sorted { $0.state.urgency < $1.state.urgency }
                    let unfolded = open.contains(row.session)
                    TaskRow(name: row.task, state: row.ownState, folded: members.isEmpty ? nil : !unfolded,
                            fold: { withAnimation(.snappy(duration: 0.2)) { if unfolded { open.remove(row.session) } else { open.insert(row.session) } } },
                            show: { model.path.append(row.session) })
                    .contextMenu { actions(row.session, name: row.task, state: row.ownState, workers: members.count) } preview: { TaskPeek(row: row, name: row.task) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipes(row.session, name: row.task, state: row.ownState, workers: members.count) }
                    .swipeActions(edge: .leading) { renameSwipe(row.session, name: row.task) }
                    if unfolded {
                        ForEach(members, id: \.session) { member in
                            let name = model.names[member.session] ?? member.place
                            TaskRow(name: name, state: member.state, worker: true, show: { model.path.append(member.session) })
                                .opacity([.done, .idle, .offline].contains(member.state) ? 0.6 : 1)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipes(member.session, name: name, state: member.state, workers: 0) }
                                .swipeActions(edge: .leading) { renameSwipe(member.session, name: name) }
                                .contextMenu { actions(member.session, name: name, state: member.state, workers: 0) } preview: {
                                    if let worker = row.member(member.session) { TaskPeek(row: worker, name: name) }
                                }
                        }
                    }
                }
            }
        }
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
    /// A task's long press, as the Mac's row menu: pause or resume, rename, archive.
    /// Swiped left: archive (asking first, as from the menu), and pause or resume.
    @ViewBuilder func swipes(_ session: String, name: String, state: BoardRow.State, workers: Int) -> some View {
        Button { archiving = (session, name, workers) } label: { Label("Archive", image: "trash-outline") }.tint(.red)
        if state == .paused {
            Button { Task { _ = await model.unpause([session]) } } label: { Label("Resume", image: "arrow-rotate-clockwise-glyph") }.tint(.blue)
        } else {
            Button { Task { _ = await model.pause([session]) } } label: { Label("Pause", image: "circle-pause-glyph") }.tint(.gray)
        }
    }

    /// Swiped right: rename.
    func renameSwipe(_ session: String, name: String) -> some View {
        Button { newName = name; renaming = (session, name) } label: { Label("Rename", image: "pen-outline") }.tint(.indigo)
    }

    @ViewBuilder func actions(_ session: String, name: String, state: BoardRow.State, workers: Int) -> some View {
        if state == .paused {
            Button { Task { _ = await model.unpause([session]) } } label: { Label("Resume", image: "arrow-rotate-clockwise-glyph") }
        } else {
            Button { Task { _ = await model.pause([session]) } } label: { Label("Pause", image: "circle-pause-glyph") }
        }
        Button { newName = name; renaming = (session, name) } label: { Label("Rename", image: "pen-outline") }
        Button { Task { await model.askToSaveForLater(session) } } label: { Label("Save for later", image: "bookmark-glyph") }
        Button(role: .destructive) { archiving = (session, name, workers) } label: { Label("Archive", image: "trash-outline") }
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
struct TaskRow: View {
    let name: String
    let state: BoardRow.State
    var worker = false
    var folded: Bool?
    var fold: () -> Void = {}
    let show: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: show) {
                Text(name).font(worker ? .subheadline : .body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.primary)
            if let folded {
                Button(action: fold) {
                    Image("chevron-down-outline").resizable().frame(width: 12, height: 12).foregroundStyle(.secondary)
                        // As tall as the name's line, so a lead's row is as tall as any other's; wide enough to tap.
                        .rotationEffect(.degrees(folded ? -90 : 0)).frame(width: 28, height: 22).contentShape(Rectangle())
                }
                // Plain: the Mac's grey, not the tint a borderless button takes.
                .buttonStyle(.plain)
                .accessibilityLabel(folded ? "Show its workers" : "Hide its workers")
            }
            StateGlyph(state: state).accessibilityLabel(StateGlyph.look(state).name)
        }
        .padding(.leading, worker ? 18 : 0)
        .padding(.vertical, worker ? -2 : 0)
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

    var body: some View {
        let conversation = model.conversation(session)
        ScrollView {
            if let conversation { ConversationView(model: model, conversation: conversation).padding() }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Details") { details = true }
                    Button("Save for later") { Task { await model.askToSaveForLater(session) } }
                } label: { Image("dots-glyph") }
            }
        }
        .sheet(isPresented: $details) { TaskDetails(model: model, session: session).presentationDetents([.medium, .large]) }
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
        .task { await model.load(session) }
        .navigationBarTitleDisplayMode(.inline)
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
        return true
    }

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
        await MainActor.run {
            Self.model?.tab = .tasks
            // An ask's (not a task's): it waits in the list's Waiting on you.
            Self.model?.path = id.hasPrefix(TaskAlerts.askPrefix) ? [] : [id]
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
    let model: PhoneModel

    var body: some View {
        let handed = model.tasks.filter { $0.ownState == .handed }
        let unread = model.tasks.filter { $0.ownState == .answered }
        List {
            if !model.waiting.isEmpty {
                Section { ForEach(model.waiting) { ask in AskCard(model: model, ask: ask) } } header: { heading("Needs you", "Asks waiting for your answer") }
            }
            if !handed.isEmpty {
                Section { ForEach(handed) { row in item(row, row.needs ?? row.now) } } header: { heading("Over to you", "Done, with a step only you can take") }
            }
            if !unread.isEmpty {
                Section { ForEach(unread) { row in item(row, row.now) } } header: { heading("Unread replies") }
            }
        }
        .overlay {
            if model.waiting.isEmpty && handed.isEmpty && unread.isEmpty {
                ContentUnavailableView { Label { Text("Nothing for you") } icon: { Image("inbox-glyph") } } description: {
                    Text("Asks, steps for you and unread replies show here.")
                }
            }
        }
        .refreshable { model.connect() }
    }

    private func heading(_ title: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(.primary)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
        }
        .textCase(nil).padding(.bottom, 2)
    }

    /// A task's row: its name and state, then what it says (its reply, or the step that's the user's).
    private func item(_ row: BoardRow, _ said: String?) -> some View {
        Button { model.path.append(row.session) } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.task).lineLimit(1)
                    if let said, !said.isEmpty { Text(said).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 8)
                StateGlyph(state: row.ownState)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// ⋯: what doesn't need a tab of its own.
struct MoreView: View {
    let model: PhoneModel
    @State private var recording = false

    var body: some View {
        List {
            Button { recording = true } label: { Label { Text("Record your screen") } icon: { Image("record-glyph") } }
                .foregroundStyle(.primary)
        }
        .fullScreenCover(isPresented: $recording) {
            NavigationStack {
                RecordView(model: model)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { recording = false } } }
            }
        }
    }
}
