import AppKit
import Carbon.HIToolbox
import SwiftUI
import ZeroCore

/// Settings as a sidebar of pages: each page a column of rows in onboarding's style (what it is, one line on
/// why, its control on the right), so the two read as the same app.
struct SettingsView: View {
    @Bindable var settings: Settings
    let store: Store
    let inbox: InboxController
    var showOnboarding: () -> Void = {}

    enum Page: String, CaseIterable, Identifiable {
        case general = "General", inbox = "Inbox", dictation = "Dictation", agents = "Agents"
        case integrations = "Integrations", dropFolders = "Drop folders", advanced = "Advanced"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .inbox: "tray"
            case .dictation: "mic"
            case .agents: "circle.grid.2x1"
            case .integrations: "puzzlepiece.extension"
            case .dropFolders: "folder"
            case .advanced: "gearshape.2"
            }
        }
    }
    @State private var page = Page.general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.stroke).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.rawValue).font(.system(size: 22, weight: .semibold)).padding(.bottom, 18)
                    content
                }
                .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.card)
        }
        .frame(width: 760, height: 520)
        .ignoresSafeArea() // under the transparent title bar too, so the sidebar runs to the window's top
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ZeroMark(small: true).frame(width: 20, height: 19)
                Text("Zero").font(.system(size: 15, weight: .semibold))
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.keycap).clipShape(Capsule())
            }
            .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 18)
            ForEach(Page.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).font(.system(size: 13)).frame(width: 18)
                        Text(item.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    // The page you are on is in full colour; the rest recede, no highlight box (as in the reference).
                    .foregroundStyle(item == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 12).frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 200)
        .background(Theme.composer)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .general: GeneralPage(settings: settings)
        case .inbox: InboxPage(settings: settings)
        case .dictation: DictationPage(settings: settings)
        case .agents: AgentsPage(settings: settings, store: store)
        case .integrations: IntegrationsPage(store: store, inbox: inbox)
        case .dropFolders: DropFoldersPage(settings: settings)
        case .advanced: AdvancedPage(showOnboarding: showOnboarding)
        }
    }
}

/// Rows with a hairline between them.
private struct Rows<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        _VariadicView.Tree(Divided()) { content() }
    }
    private struct Divided: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    if index > 0 { Divider() }
                    child
                }
            }
        }
    }
}

private struct Switch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch) }
}

private struct GeneralPage: View {
    @Bindable var settings: Settings
    var body: some View {
        Rows {
            OnboardingRow(icon: "keyboard", title: "Talk hotkey", detail: "Opens the inbox and starts dictation.") {
                HotKeyRecorder(settings: settings, minWidth: nil)
            }
            OnboardingRow(icon: "power", title: "Launch Zero at login", detail: "So agents can always reach you.") {
                Switch(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
            OnboardingRow(icon: "display.2", title: "Follow the active screen", detail: "The bar moves to the screen you use.") {
                Switch(isOn: $settings.followActiveScreen)
            }
        }
    }
}

private struct InboxPage: View {
    @Bindable var settings: Settings
    var body: some View {
        Rows {
            OnboardingRow(icon: "arrow.uturn.backward", title: "Take-back window", detail: "Esc takes an answer back within this time.") {
                HStack(spacing: 6) {
                    Slider(value: $settings.takeBackSeconds, in: 0...5, step: 0.5).frame(width: 80)
                    Text(String(format: "%.1f s", settings.takeBackSeconds)).font(.system(size: 12)).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            }
            OnboardingRow(icon: "forward", title: "Move to the next ask", detail: "3 s after an answer lands.") {
                Switch(isOn: $settings.autoAdvance)
            }
            OnboardingRow(icon: "clock", title: "Ask expiry", detail: "For asks that set none.") {
                Stepper("\(settings.defaultTTLMinutes) min", value: $settings.defaultTTLMinutes, in: 5...1440, step: 5).font(.system(size: 12))
            }
            OnboardingRow(icon: "command", title: "Suggest skills after /", detail: "Commands and skills as you type.") {
                Switch(isOn: $settings.suggestCommands)
            }
            OnboardingRow(icon: "at", title: "Suggest files after @", detail: "Files from the agent's project.") {
                Switch(isOn: $settings.suggestFiles)
            }
        }
    }
}

private struct DictationPage: View {
    @Bindable var settings: Settings
    @State private var microphones: [(name: String, uid: String)] = []
    var body: some View {
        Rows {
            OnboardingRow(icon: "mic", title: "Microphone", detail: missing ? "Not connected; the system default is used." : "Used when you dictate a reply.") {
                Picker("", selection: Binding(get: { settings.inputDeviceUID ?? "" }, set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.uid) { mic in Text(mic.name).tag(mic.uid) }
                }
                .labelsHidden().pickerStyle(.menu)
            }
        }
        .onAppear { microphones = Dictation.inputDevices() }
    }
    private var missing: Bool { settings.inputDeviceUID.map { uid in !microphones.contains { $0.uid == uid } } ?? false }
}

private struct AgentsPage: View {
    @Bindable var settings: Settings
    let store: Store
    var body: some View {
        let names = agentNames
        if names.isEmpty {
            Text("No agents yet. They appear here when they first ask you something.").font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    ForEach(names, id: \.self) { name in
                        HStack(spacing: 10) {
                            Circle().fill(AgentStatus.of(store.asks.filter { $0.agent.name == name }).color).frame(width: 8, height: 8)
                            Text(store.displayName(of: name)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            RowButton(title: "Close") { store.closeAgent(name) }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                    }
                    .onMove { from, to in
                        var order = names
                        order.move(fromOffsets: from, toOffset: to)
                        settings.agentOrder = order
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).frame(height: 320)
                Text("Drag to reorder the bar. A closed agent comes back when it next asks you something.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var agentNames: [String] {
        var seen: [String] = []
        for ask in store.asks where ask.state != .expired && !seen.contains(ask.agent.name) { seen.append(ask.agent.name) }
        let open = seen.filter { name in AgentStatus.of(store.asks.filter { $0.agent.name == name }) != .closed }
        return settings.sorted(open)
    }
}

private struct IntegrationsPage: View {
    let store: Store
    let inbox: InboxController
    /// nil while it is being checked or changed.
    @State private var plugin: Bool?
    @State private var pluginError: String?
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rows {
                OnboardingRow(icon: "sparkle", picture: choiceIcon("claude"), title: "Claude Code", detail: "Asks and progress come to your inbox.") {
                    if let plugin {
                        Switch(isOn: Binding(get: { plugin }, set: { on in
                            self.plugin = nil
                            pluginError = nil
                            Task {
                                if on { pluginError = await ClaudePlugin.install() } else { await ClaudePlugin.uninstall() }
                                self.plugin = await ClaudePlugin.isInstalled()
                            }
                        }))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                OnboardingRow(icon: "chevron.left.forwardslash.chevron.right", picture: choiceIcon("openai"), title: "Codex", detail: "Start Codex agents from Zero.") {
                    RowButton(title: "Coming soon", enabled: false)
                }
                OnboardingRow(icon: "square.stack", picture: choiceIcon("solo"), title: "Solo", detail: "Starts agents and carries your messages.") {
                    Text(soloStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                OnboardingRow(icon: "list.bullet", title: "Claude models", detail: account.map { "For \($0)." } ?? "For your Claude Code account.") {
                    if refreshing { ProgressView().controlSize(.small) }
                    else {
                        RowButton(title: "Refresh") {
                            refreshing = true
                            Task {
                                if let adapter = store.spawners.first, await adapter.refreshModels() { inbox.modelsVersion += 1 }
                                refreshing = false
                            }
                        }
                    }
                }
            }
            if let pluginError { Text(pluginError).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
        }
        .task { plugin = await ClaudePlugin.isInstalled() }
    }

    private var account: String? { store.adapters.compactMap { $0.spawnNote(for: SpawnChoice(id: "", name: "Claude")) }.first }

    private var soloStatus: String {
        guard let solo = store.adapters.first(where: { $0 is SoloAdapter }) as? SoloAdapter,
              FileManager.default.isExecutableFile(atPath: solo.helper) else { return "Not installed" }
        let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/soloterm/solo-mcp.sock").path
        return FileManager.default.fileExists(atPath: socket) ? "Connected" : "Not running"
    }
}

private struct DropFoldersPage: View {
    @Bindable var settings: Settings
    @State private var newPattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Asks arrive as files in these folders and answers go back the same way, so agents on another machine that syncs with this Mac can reach you.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Rows {
                ForEach(settings.dropPatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        RowButton(title: "Remove") { settings.dropPatterns.removeAll { $0 == pattern } }
                    }
                    .padding(.vertical, 10)
                }
            }
            HStack(spacing: 8) {
                TextField("Example: ~/remotes/*/.zero", text: $newPattern).textFieldStyle(.roundedBorder).onSubmit(add)
                RowButton(title: "Add", enabled: !newPattern.trimmingCharacters(in: .whitespaces).isEmpty, action: add)
                RowButton(title: "Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        settings.dropPatterns.append(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    }
                }
            }
        }
    }

    private func add() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        settings.dropPatterns.append(pattern)
        newPattern = ""
    }
}

private struct AdvancedPage: View {
    let showOnboarding: () -> Void
    var body: some View {
        Rows {
            OnboardingRow(icon: "doc.text", title: "Log", detail: Paths.log.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                RowButton(title: "View log") { NSWorkspace.shared.open(Paths.log) }
            }
            OnboardingRow(icon: "sparkles", title: "Onboarding", detail: "See the welcome again.") {
                RowButton(title: "Open", action: showOnboarding)
            }
        }
    }
}

/// Click, press a combination, done. Stores the key code and Carbon modifiers the hotkey needs.
struct HotKeyRecorder: View {
    @Bindable var settings: Settings
    /// Settings gives the button a 120 pt floor; onboarding lets it hug its label so it sits flush right.
    var minWidth: CGFloat? = 120
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : settings.hotKeyLabel) {
            recording ? stop() : start()
        }
        .frame(minWidth: minWidth)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { return nil }
            var carbon = 0
            if flags.contains(.command) { carbon |= cmdKey }
            if flags.contains(.option) { carbon |= optionKey }
            if flags.contains(.control) { carbon |= controlKey }
            if flags.contains(.shift) { carbon |= shiftKey }
            settings.hotKeyLabel = label(flags: flags, event: event)
            settings.hotKeyModifiers = carbon
            settings.hotKeyCode = Int(event.keyCode)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func label(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→"]
        let key = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return parts.joined() + " " + key
    }
}
