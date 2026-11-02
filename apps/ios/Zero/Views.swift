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
        case .blocked: ("circle-minus-glyph", .red, "Blocked")
        case .done: ("circle-check-glyph", .green, "Done")
        case .answered: ("message-check-glyph", .indigo, "Replied")
        case .merged: ("code-branch-glyph", .purple, "Merged")
        case .paused: ("circle-pause-glyph", .secondary, "Paused")
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
                Tab("Tasks", image: "list-checkbox-glyph", value: PhoneModel.Place.tasks) { TasksView(model: model) }
                Tab("Later", image: "bookmark-glyph", value: PhoneModel.Place.later) { LaterView(model: model) }
                Tab("Record", image: "record-glyph", value: PhoneModel.Place.record) { RecordView(model: model) }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .sheet(isPresented: $settings) { SettingsView(model: model) }
            .sheet(isPresented: $newTask) { NewTaskSheet(model: model) }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in TaskView(model: model, session: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Logo() }.sharedBackgroundVisibility(.hidden)
                // The workspace shown, as the Mac's sidebar heading: the same one there and here, switched from either.
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

/// The asks waiting on you, then every task, most urgent first, as the Mac's board sorts them.
struct TasksView: View {
    let model: PhoneModel

    var body: some View {
        List {
            if !model.waiting.isEmpty {
                Section("Waiting on you") {
                    ForEach(model.waiting) { ask in AskCard(model: model, ask: ask) }
                }
            }
            Section("Tasks") {
                ForEach(model.tasks) { row in
                    NavigationLink(value: row.session) { TaskRow(row: row) }
                }
            }
        }
        .refreshable { model.connect() }
        .task { model.askForPush() }
    }
}

struct TaskRow: View {
    let row: BoardRow
    var body: some View {
        HStack(spacing: 10) {
            StateGlyph(state: row.ownState)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.task).lineLimit(1)
            }
        }
    }
}

/// A task's conversation, as the Mac shows it, and a box to write to it.
struct TaskView: View {
    let model: PhoneModel
    let session: String
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @Environment(\.scenePhase) private var phase

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
                Menu { Button("Save for later") { Task { await model.askToSaveForLater(session) } } } label: { Image("dots-glyph") }
            }
        }
        .navigationTitle(model.rows.first { $0.session == session }?.task ?? "Task")
        // Seen: its notification goes (on the Mac too, the board moving on).
        .onAppear {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [session])
            model.markSeen(session)
            settle()
        }
        // A reply arriving while it's open is read as it comes.
        .onChange(of: conversation?.items.last?.id) { model.markSeen(session) }
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
