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
        // The whole window, title bar included, however tall AppKit makes it.
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 552, maxHeight: .infinity)
        .background(Theme.card)
        .ignoresSafeArea() // under the transparent title bar too, so the sidebar runs to the window's top
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            header.padding(.horizontal, -8).padding(.bottom, -6)
            ForEach(Page.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).font(.system(size: 13)).frame(width: 18)
                        Text(item.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    // The page you are on is in full colour; the rest recede, no highlight box (as in the reference).
                    .foregroundStyle(item == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 12).frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.composer)
    }

    /// The heading as a blueprint, inverted against the app: black with white lines and lettering in light mode,
    /// white with black in dark. The window's buttons sit on it; its foot fades into the sidebar.
    private var header: some View {
        ZStack(alignment: .topLeading) {
            // The panel fades out on an eased curve (a straight ramp bands); only the drawing blurs as it goes,
            // since blurring a flat fill just smudges its edge.
            Theme.knob.mask(LinearGradient(stops: ProgressiveBlur<EmptyView>.eased, startPoint: .top, endPoint: .bottom))
            ProgressiveBlur { Blueprint().foregroundStyle(Theme.onKnob) }
            HStack(spacing: 8) {
                ZeroMark(small: true).frame(width: 28, height: 27)
                Text("Zero").font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Theme.onKnob)
            .padding(.leading, 20).padding(.top, 44) // just under the window's buttons
        }
        .frame(height: 118) // its fade ends just above the first page
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
    /// The agent being renamed, and the name typed so far.
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var focused: Bool
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
                            if editing == name {
                                TextField("Name", text: $draft, prompt: Text(store.identity(of: name)?.label ?? name))
                                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium)).focused($focused)
                                    .onSubmit { store.rename(name, to: draft); editing = nil }
                                    .onExitCommand { editing = nil }
                            } else {
                                Text(store.displayName(of: name)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            }
                            Spacer()
                            IconButton(symbol: "pencil", help: "Rename") {
                                draft = store.names[name] ?? store.displayName(of: name)
                                editing = name
                                focused = true
                            }
                            IconButton(symbol: "trash", help: store.canStop(name) ? "Remove and stop" : "Remove") { store.closeAgent(name) }
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
                Text("Drag to reorder the bar. Removing an agent stops it; it comes back when it next asks you something.")
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
    @State private var claude = ClaudeAdding()
    @State private var showingClaude = false
    @State private var linear = LinearConnecting()
    @State private var showingLinear = false

    private var claudeDetail: String {
        ClaudeAccounts.shared.active.map { "Signed in as \($0)." } ?? "Asks and progress come to your inbox."
    }

    private var linearDetail: String {
        switch Linear.shared.workspaces.count {
        case 0: "Issue ids in messages open in Linear."
        case 1: "Connected to \(Linear.shared.workspaces[0].name)."
        case let count: "Connected to \(count) workspaces."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rows {
                OnboardingRow(icon: "sparkle", picture: choiceIcon("claude"), title: "Claude Code", detail: claudeDetail) {
                    if ClaudeAccounts.shared.accounts.isEmpty {
                        if claude.busy { ProgressView().controlSize(.small) } else { RowButton(title: "Add account") { claude.add() } }
                    } else {
                        RowButton(title: "Configure") { showingClaude = true }
                    }
                }
                OnboardingRow(icon: "chevron.left.forwardslash.chevron.right", picture: choiceIcon("openai"), title: "Codex", detail: "Start Codex agents from Zero.") {
                    RowButton(title: "Coming soon", enabled: false)
                }
                OnboardingRow(icon: "square.stack", picture: choiceIcon("solo"), title: "Solo", detail: "Starts agents and carries your messages.") {
                    Text(soloStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                OnboardingRow(icon: "link", picture: choiceIcon("linear"), title: "Linear", detail: linearDetail) {
                    if Linear.shared.workspaces.isEmpty {
                        if linear.busy { ProgressView().controlSize(.small) } else { RowButton(title: "Connect") { linear.connect() } }
                    } else {
                        RowButton(title: "View connections") { showingLinear = true }
                    }
                }
            }
            if let error = claude.error, !showingClaude { Text(error).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
            if let error = linear.error, !showingLinear { Text(error).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
        }
        .sheet(isPresented: $showingLinear) { LinearConnections(connecting: linear) }
        .sheet(isPresented: $showingClaude) { ClaudeAccountsSheet(adding: claude) }
    }

    private var soloStatus: String {
        guard let solo = store.adapters.first(where: { $0 is SoloAdapter }) as? SoloAdapter,
              FileManager.default.isExecutableFile(atPath: solo.helper) else { return "Not installed" }
        let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/soloterm/solo-mcp.sock").path
        return FileManager.default.fileExists(atPath: socket) ? "Connected" : "Not running"
    }
}

/// A Claude Code sign-in in progress, shared by the Integrations row and the accounts sheet.
@MainActor @Observable
private final class ClaudeAdding {
    var busy = false
    var error: String?

    func add() {
        busy = true
        error = nil
        Task {
            error = await ClaudeAccounts.shared.add()
            busy = false
        }
    }
}

/// The Zero plugin, auto-switch, and the Claude Code accounts Zero switches between.
private struct ClaudeAccountsSheet: View {
    let adding: ClaudeAdding
    @Environment(\.dismiss) private var dismiss
    /// nil while it is being changed.
    @State private var plugin: Bool? = ClaudePlugin.isInstalled
    @State private var pluginError: String?
    @State private var switchError: String?
    /// The account whose single-agent token is being set up, while Arsen signs in in the browser.
    @State private var settingUp: String?

    private var accounts: ClaudeAccounts { ClaudeAccounts.shared }
    private static let thresholds: [Double] = [80, 85, 90, 95, 98, 100]

    var body: some View {
        @Bindable var accounts = accounts
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude Code settings").font(.system(size: 17, weight: .semibold)).padding(.bottom, 4)
            Text("Agents and your terminal use the active account.").font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.bottom, 12)
            Rows {
                OnboardingRow(icon: "puzzlepiece.extension", picture: Image(nsImage: appTile), title: "Zero plugin",
                              detail: "Asks and progress come to your inbox.") {
                    if let plugin {
                        Switch(isOn: Binding(get: { plugin }, set: { on in
                            self.plugin = nil
                            pluginError = nil
                            Task {
                                if on { pluginError = await ClaudePlugin.install() } else { await ClaudePlugin.uninstall() }
                                self.plugin = ClaudePlugin.isInstalled
                            }
                        }))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                OnboardingRow(icon: "arrow.left.arrow.right", title: "Auto-switch", detail: "Moves to the account with the most room left.") {
                    Switch(isOn: $accounts.autoSwitch)
                }
                // Always shown, dimmed while auto-switch is off, so turning it on moves nothing.
                OnboardingRow(icon: "gauge.with.dots.needle.67percent", title: "Switch at", detail: "Checked every 5 minutes.") {
                    HStack(spacing: 8) {
                        Picker("Limit", selection: $accounts.window) {
                            Text("5 hours").tag(ClaudeAccounts.Window.fiveHour)
                            Text("Weekly").tag(ClaudeAccounts.Window.weekly)
                            Text("Either").tag(ClaudeAccounts.Window.either)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Picker("Threshold", selection: $accounts.threshold) {
                            ForEach(Self.thresholds, id: \.self) { Text("\(Int($0))%").tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    .disabled(!accounts.autoSwitch).opacity(accounts.autoSwitch ? 1 : 0.5)
                }
            }
            table.padding(.top, 16)
            ForEach([switchError, adding.error, pluginError].compactMap { $0 }, id: \.self) { error in
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).padding(.top, 8)
            }
            HStack {
                Spacer()
                SolidButton(title: "Done") { dismiss() }
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 560)
    }

    private static let usageWidth: CGFloat = 64
    private static let actionsWidth: CGFloat = 116

    /// One row per account: who, how much of each limit is used, and what can be done with it.
    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Account").frame(maxWidth: .infinity, alignment: .leading)
                Text("5 hours").frame(width: Self.usageWidth)
                Text("Weekly").frame(width: Self.usageWidth)
                ZStack(alignment: .trailing) {
                    IconButton(symbol: "plus", help: "Add account") { adding.add() }.opacity(adding.busy ? 0 : 1)
                    if adding.busy { ProgressView().controlSize(.small) }
                }
                .frame(minWidth: Self.actionsWidth, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 40)
            .background(Theme.composer)
            ForEach(accounts.accounts) { account in
                Rectangle().fill(Theme.stroke).frame(height: 1)
                HStack(spacing: 12) {
                    (choiceIcon("claude") ?? Image(systemName: "person.crop.circle")).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(account.plan.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Claude")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    percent(accounts.usage[account.email]?.fiveHour)
                    percent(accounts.usage[account.email]?.sevenDay)
                    HStack(spacing: 6) {
                        singleAgent(account.email)
                        if account.email == accounts.active {
                            Label("Active", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                        } else {
                            IconButton(symbol: "trash", help: "Remove") { accounts.remove(account.email) }
                            IconButton(symbol: "arrow.left.arrow.right", help: "Switch to this account") {
                                switchError = accounts.switchTo(account.email)
                            }
                        }
                    }
                    .frame(minWidth: Self.actionsWidth, alignment: .trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
    }

    /// A key: set up (filled) means one agent can be started as this account, whatever the active one is.
    @ViewBuilder private func singleAgent(_ email: String) -> some View {
        if settingUp == email {
            ProgressView().controlSize(.small).frame(width: 26, height: 26)
        } else if accounts.perAgent.contains(email) {
            IconButton(symbol: "key.fill", help: "Single agents can run as this account. Click to remove its token.") {
                accounts.removePerAgent(email)
            }
        } else {
            IconButton(symbol: "key", help: "Let single agents run as this account: sign in as \(email) in the browser") {
                settingUp = email
                switchError = nil
                Task {
                    switchError = await accounts.setUpPerAgent(email)
                    settingUp = nil
                }
            }
        }
    }

    /// "22%", or a dash when the account's usage isn't known (its token has lapsed since it was last active).
    private func percent(_ value: Double?) -> some View {
        Text(value.map { "\(Int($0))%" } ?? "–").font(.system(size: 12)).monospacedDigit()
            .foregroundStyle(value == nil ? .tertiary : .primary)
            .frame(width: Self.usageWidth)
    }
}

/// Zero's app icon without the margin macOS icons carry, so it fills a row's picture slot like the other logos,
/// and with a faint edge, since its white tile would otherwise vanish on a white sheet.
@MainActor private let appTile: NSImage = {
    let size = NSSize(width: 64, height: 64)
    return NSImage(size: size, flipped: false) { rect in
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        // The tile is 824 of the icon's 1024 points, centred.
        let scale = 1024.0 / 824.0
        NSApp.applicationIconImage.draw(in: rect.insetBy(dx: -rect.width * (scale - 1) / 2, dy: -rect.height * (scale - 1) / 2))
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.12).setStroke()
        tile.lineWidth = 1
        tile.stroke()
        return true
    }
}()

/// A round button with one symbol, for row actions; `help` names it on hover.
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 26, height: 26).background(Theme.chip).clipShape(Circle())
        }
        .buttonStyle(PressableStyle()).help(help).accessibilityLabel(help)
    }
}

/// A Linear sign-in in progress, shared by the Integrations row and the connections sheet.
@MainActor @Observable
private final class LinearConnecting {
    var busy = false
    var error: String?

    func connect() {
        busy = true
        error = nil
        Task {
            error = await Linear.shared.connect { NSWorkspace.shared.open($0) }
            busy = false
        }
    }
}

/// The connected Linear workspaces, each with its logo and teams, and a way to add another.
private struct LinearConnections: View {
    let connecting: LinearConnecting
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Linear connections").font(.system(size: 17, weight: .semibold)).padding(.bottom, 4)
            Text("Issue ids from these workspaces open in Linear.").font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.bottom, 12)
            Rows {
                ForEach(Linear.shared.workspaces) { workspace in
                    HStack(spacing: 12) {
                        WorkspaceLogo(workspace: workspace)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name).font(.system(size: 13, weight: .semibold))
                            Text("Teams \(workspace.teams.joined(separator: ", ")).").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        RowButton(title: "Remove") { Linear.shared.remove(workspace.urlKey) }
                    }
                    .padding(.vertical, 12)
                }
            }
            if let error = connecting.error { Text(error).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).padding(.top, 8) }
            HStack {
                ZStack {
                    RowButton(title: "Add workspace") { connecting.connect() }.opacity(connecting.busy ? 0 : 1)
                    if connecting.busy { ProgressView().controlSize(.small) }
                }
                Spacer()
                SolidButton(title: "Done") { dismiss() }
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: Linear.shared.workspaces.isEmpty) { _, empty in if empty { dismiss() } }
    }
}

/// The workspace's own logo, from Zero's copy of it, or its initial on a tile when it has none.
private struct WorkspaceLogo: View {
    let workspace: Linear.Workspace
    var body: some View {
        let _ = Linear.shared.logos
        Group {
            if let image = NSImage(contentsOf: Linear.logoFile(workspace.urlKey)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Text(workspace.name.prefix(1).uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.keycap)
            }
        }
        .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
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

/// A drafting-table backdrop: a fine grid, a dashed circle with its crosshair, a dashed rectangle, a dimension
/// line with end ticks, and a few plus marks, all faint, with a soft light over the top right.
private struct Blueprint: View {
    var body: some View {
        Canvas { context, size in
            let ink = GraphicsContext.Shading.foreground
            var grid = Path()
            stride(from: 0, through: size.width, by: 12).forEach { x in grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            stride(from: 0, through: size.height, by: 12).forEach { y in grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
            context.opacity = 0.07
            context.stroke(grid, with: ink, lineWidth: 0.5)
            context.opacity = 0.35
            let dashed = StrokeStyle(lineWidth: 0.8, dash: [3, 3])
            let center = CGPoint(x: size.width - 70, y: 46)
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36)), with: ink, style: dashed)
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - 7, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 7, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 7)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 7))
            context.stroke(cross, with: ink, lineWidth: 0.8)
            context.stroke(Path(CGRect(x: size.width - 66, y: 76, width: 50, height: 20)), with: ink, style: dashed) // clear of the badge
            var dimension = Path()
            let x = size.width - 16
            dimension.move(to: CGPoint(x: x, y: 14)); dimension.addLine(to: CGPoint(x: x, y: 70))
            dimension.move(to: CGPoint(x: x - 4, y: 14)); dimension.addLine(to: CGPoint(x: x + 4, y: 14))
            dimension.move(to: CGPoint(x: x - 4, y: 70)); dimension.addLine(to: CGPoint(x: x + 4, y: 70))
            context.stroke(dimension, with: ink, lineWidth: 0.8)
            var plus = Path()
            for p in [CGPoint(x: size.width - 120, y: 30), CGPoint(x: 110, y: 18), CGPoint(x: 150, y: 64)] {
                plus.move(to: CGPoint(x: p.x - 3, y: p.y)); plus.addLine(to: CGPoint(x: p.x + 3, y: p.y))
                plus.move(to: CGPoint(x: p.x, y: p.y - 3)); plus.addLine(to: CGPoint(x: p.x, y: p.y + 3))
            }
            context.stroke(plus, with: ink, lineWidth: 0.8)
            context.opacity = 0.16
            context.fill(Path(ellipseIn: CGRect(x: size.width - 150, y: -70, width: 180, height: 140)),
                         with: .radialGradient(Gradient(colors: [.white, .clear]), center: CGPoint(x: size.width - 60, y: 0), startRadius: 0, endRadius: 90))
        }
    }
}

/// A progressive blur: the content is sharp at the top and dissolves toward the bottom, each layer more blurred
/// and shown over a lower band, the last fading out entirely, so the edge melts instead of cutting off.
private struct ProgressiveBlur<Content: View>: View {
    @ViewBuilder let content: () -> Content
    private static var layers: [(blur: CGFloat, from: CGFloat, to: CGFloat)] {
        [(0, 0.0, 0.7), (1.5, 0.62, 0.8), (3, 0.72, 0.88), (5, 0.8, 0.95), (8, 0.88, 1.0)]
    }
    var body: some View {
        ZStack {
            ForEach(Array(Self.layers.enumerated()), id: \.offset) { index, layer in
                content().blur(radius: layer.blur, opaque: false)
                    .mask(LinearGradient(stops: band(layer.from, layer.to, last: index == Self.layers.count - 1), startPoint: .top, endPoint: .bottom))
            }
        }
        .compositingGroup()
        .mask(LinearGradient(stops: Self.eased, startPoint: .top, endPoint: .bottom))
    }

    /// Solid to clear over the bottom third along a smootherstep curve, sampled finely: it leaves the solid and
    /// arrives at clear with no visible start or end, so the colour melts into the sidebar instead of passing
    /// through a band of grey.
    static var eased: [Gradient.Stop] {
        let start = 0.64
        return [Gradient.Stop(color: .black, location: 0)] + (0...16).map { step in
            let t = Double(step) / 16
            let ease = t * t * t * (t * (t * 6 - 15) + 10)
            return Gradient.Stop(color: .black.opacity(1 - ease), location: start + (1 - start) * t)
        }
    }

    /// Opaque over its band, ramping in at the top of it; a layer's band overlaps the next so there are no seams.
    private func band(_ from: CGFloat, _ to: CGFloat, last: Bool) -> [Gradient.Stop] {
        let ramp = (to - from) / 3
        return [.init(color: .clear, location: max(0, from - 0.001)), .init(color: from == 0 ? .black : .clear, location: from),
                .init(color: .black, location: min(1, from + ramp)), .init(color: .black, location: to),
                .init(color: last ? .black : .clear, location: min(1, to + ramp))]
    }
}
