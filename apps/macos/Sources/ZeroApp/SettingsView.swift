import AppKit
import Carbon.HIToolbox
import SwiftUI
import ZeroCore

/// Settings as the workspace window shows it: a sidebar of pages in groups, and the page itself in a column centred
/// in the rest. Each page is a card of rows in onboarding's style (what it is, one line on why, its control on the
/// right), so the two read as the same app.
struct SettingsView: View {
    @Bindable var settings: Settings
    let store: Store
    let inbox: InboxController
    var showOnboarding: () -> Void = {}

    enum Page: String, CaseIterable, Identifiable {
        case general = "General", inbox = "Inbox", dictation = "Dictation", advanced = "Advanced"
        case agents = "Agents", projects = "Projects", dropFolders = "Drop folders", integrations = "Integrations"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "sliders"
            case .inbox: "inbox"
            case .dictation: "microphone"
            case .agents: "robot"
            case .projects: "layers"
            case .integrations: "puzzle-piece"
            case .dropFolders: "folder-download"
            case .advanced: "gears"
            }
        }
        /// General leads on its own, where Home's New task is, so switching between the two moves no row.
        static let groups: [(String, [Page])] = [("Personal", [.inbox, .dictation, .advanced]), ("Agents", [.agents, .projects, .dropFolders, .integrations])]
    }
    @State private var page = Page.general

    var body: some View {
        HStack(spacing: 0) {
            SidebarColumn(title: "Settings") {
                SidebarItem(Page.general.rawValue, icon: Page.general.icon, selected: page == .general) { page = .general }
                ForEach(Page.groups, id: \.0) { group, pages in
                    SidebarHeading(text: group)
                    ForEach(pages) { item in
                        SidebarItem(item.rawValue, icon: item.icon, selected: item == page) { page = item }
                    }
                }
            }
            Rectangle().fill(Theme.stroke).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(text: page.rawValue).padding(.bottom, 24)
                    content
                }
                .centredColumn(680)
                .padding(.top, 44).padding(.bottom, 28)
            }
            .background(Theme.card)
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .general: GeneralPage(settings: settings)
        case .inbox: InboxPage(settings: settings)
        case .dictation: DictationPage(settings: settings)
        case .agents: AgentsPage(settings: settings, store: store)
        case .integrations: IntegrationsPage(store: store, inbox: inbox)
        case .dropFolders: DropFoldersPage(settings: settings)
        case .projects: ProjectsPage(inbox: inbox)
        case .advanced: AdvancedPage(showOnboarding: showOnboarding)
        }
    }
}

/// How wide the inner sidebars are: one width for all of them, dragged at their right edge between these.
enum SidebarWidth {
    static let key = "sidebarWidth"
    static let standard: Double = 250
    static let range: ClosedRange<Double> = 200...420
}

/// An inner sidebar: its title on a blueprint, then its rows, on the sidebar's grey. Its right edge drags it wider or
/// narrower.
struct SidebarColumn<Content: View>: View {
    let title: String
    /// A row at the foot under a divider (an integration's Edit views), level with the rail's settings.
    var footer: AnyView? = nil
    @ViewBuilder let content: () -> Content
    @AppStorage(SidebarWidth.key) private var width = SidebarWidth.standard
    /// The width when the drag began.
    @State private var dragged: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarHeader(title: title)
                .padding(.horizontal, -10).padding(.bottom, -4)
            content()
            if let footer {
                Spacer(minLength: 0)
                Rectangle().fill(Theme.stroke).frame(height: 1).padding(.horizontal, -10).padding(.bottom, 4)
                // A 30 pt row centred 24 pt above the panel's foot, as the rail's settings is (12 + 16 from the
                // window's, less the panel's 4).
                footer.padding(.bottom, 9)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.composer)
        // The edge to drag: a thin strip along it, inside the sidebar so the page doesn't take its clicks.
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 6).contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragged ?? width
                        dragged = start
                        width = min(max(start + drag.translation.width, SidebarWidth.range.lowerBound), SidebarWidth.range.upperBound)
                    }
                    .onEnded { _ in dragged = nil })
        }
    }
}

/// The heading as a blueprint on drafting paper: dark lines and lettering on light grey (light on dark grey in dark
/// mode). Its foot fades into the sidebar.
struct SidebarHeader: View {
    let title: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The panel fades out on an eased curve (a straight ramp bands); only the drawing blurs as it goes,
            // since blurring a flat fill just smudges its edge.
            Theme.blueprint.mask(LinearGradient(stops: ProgressiveBlur<EmptyView>.eased, startPoint: .top, endPoint: .bottom))
            ProgressiveBlur { Blueprint().foregroundStyle(Theme.onBlueprint) }
            // The mark over the rows' icons and the title over their text (10 + 10 + an 18 pt icon + 9), level with the
            // rail's home icon (its centre 28 pt under the panel's top).
            HStack(spacing: 9) {
                ZeroMark(small: true).frame(width: 20, height: 19).frame(width: 18)
                Text(title).font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Theme.onBlueprint)
            .frame(height: 22)
            .padding(.leading, 20).padding(.top, 17)
        }
        .frame(height: 96) // its fade ends just above the first row
    }
}

struct SidebarHeading: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 6)
    }
}

/// A sidebar row, as ChatGPT's: plain text, the one you are on on a soft grey pill, a lighter one under the pointer.
/// With no icon, text alone (a recent task); a trailing icon (a task's state) keeps every row's text on one edge.
struct SidebarItem<Icon: View>: View {
    let title: String
    var selected = false
    var trailing = false
    let action: () -> Void
    @ViewBuilder var icon: Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if Icon.self != EmptyView.self && !trailing { icon.font(.system(size: 13)).frame(width: 18) }
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if trailing { icon.font(.system(size: 12)) }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).frame(height: 30)
        }
        .buttonStyle(Hovering(selected: selected))
    }
}

/// A button that keeps still when pressed (no dimming) and shows a background under the pointer, and a firmer one
/// when it is the selected place.
struct Hovering: ButtonStyle {
    var selected = false
    var radius: CGFloat = 8
    var fill = Theme.chip
    var hover = Theme.hover

    func makeBody(configuration: Configuration) -> some View { Tile(label: configuration.label, style: self) }

    private struct Tile<Label: View>: View {
        let label: Label
        let style: Hovering
        @State private var hovering = false
        var body: some View {
            label
                .background(style.selected ? style.fill : hovering ? style.hover : .clear, in: RoundedRectangle(cornerRadius: style.radius))
                .contentShape(RoundedRectangle(cornerRadius: style.radius))
                .onHover { hovering = $0 }
        }
    }
}

extension SidebarItem where Icon == NucleoIcon {
    init(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, action: action) { NucleoIcon(icon, size: 15) }
    }
}

extension SidebarItem where Icon == EmptyView {
    init(_ title: String, selected: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, action: action) { EmptyView() }
    }
}

/// A page's title.
struct PageTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 26, weight: .semibold)).lineLimit(2) }
}

extension View {
    /// A column at most `width` wide, centred in what's left, its contents to its leading edge.
    func centredColumn(_ width: CGFloat) -> some View {
        frame(maxWidth: width, alignment: .leading).padding(.horizontal, 36).frame(maxWidth: .infinity)
    }
}

/// Rows with a hairline between them, on a card.
struct Rows<Content: View>: View {
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
            .padding(.horizontal, 18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        }
    }
}

struct Switch: View {
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
            OnboardingRow(icon: "power-off", title: "Launch Zero at login", detail: "So agents can always reach you.") {
                Switch(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
            OnboardingRow(icon: "monitor", title: "Follow the active screen", detail: "The bar moves to the screen you use.") {
                Switch(isOn: $settings.followActiveScreen)
            }
        }
    }
}

private struct InboxPage: View {
    @Bindable var settings: Settings
    var body: some View {
        Rows {
            OnboardingRow(icon: "undo", title: "Take-back window", detail: "Esc takes an answer back within this time.") {
                HStack(spacing: 6) {
                    Slider(value: $settings.takeBackSeconds, in: 0...5, step: 0.5).frame(width: 80)
                    Text(String(format: "%.1f s", settings.takeBackSeconds)).font(.system(size: 12)).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            }
            OnboardingRow(icon: "arrow-right", title: "Move to the next ask", detail: "3 s after an answer lands.") {
                Switch(isOn: $settings.autoAdvance)
            }
            OnboardingRow(icon: "clock", title: "Ask expiry", detail: "For asks that set none.") {
                Stepper("\(settings.defaultTTLMinutes) min", value: $settings.defaultTTLMinutes, in: 5...1440, step: 5).font(.system(size: 12))
            }
            OnboardingRow(icon: "command", title: "Suggest skills after /", detail: "Commands and skills as you type.") {
                Switch(isOn: $settings.suggestCommands)
            }
            OnboardingRow(icon: "at-sign", title: "Suggest files after @", detail: "Files from the agent's project.") {
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
            OnboardingRow(icon: "microphone", title: "Microphone", detail: missing ? "Not connected; the system default is used." : "Used when you dictate a reply.") {
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
        VStack(alignment: .leading, spacing: 0) {
            PluginRow()
            PlacesField().padding(.top, 20)
            Text("Agents in the bar").font(.system(size: 15, weight: .semibold)).padding(.top, 28).padding(.bottom, 12)
            list
        }
    }

    @ViewBuilder private var list: some View {
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
                            IconButton(symbol: "pen", help: "Rename") {
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
    @State private var rexOn = UserDefaults.standard.bool(forKey: RexAdapter.enabledKey)

    private var rexDetail: String {
        rexOn && RexAdapter.executable != nil ? "New agents start in Rex." : "Start new agents in Rex instead of Zero's terminals."
    }

    var body: some View {
        Rows {
            OnboardingRow(icon: "stack", picture: choiceIcon("solo"), title: "Solo", detail: "Starts agents and carries your messages.") {
                Text(soloStatus).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            OnboardingRow(icon: "terminal", picture: choiceIcon("rex"), title: "Rex", detail: rexDetail) {
                if RexAdapter.executable == nil {
                    Text("Not installed").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Toggle("", isOn: Binding(get: { rexOn }, set: { on in
                        rexOn = on
                        UserDefaults.standard.set(on, forKey: RexAdapter.enabledKey)
                        inbox.loadSpawnChoices(force: true)
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private var soloStatus: String {
        guard let solo = store.adapters.first(where: { $0 is SoloAdapter }) as? SoloAdapter,
              FileManager.default.isExecutableFile(atPath: solo.helper) else { return "Not installed" }
        let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/soloterm/solo-mcp.sock").path
        return FileManager.default.fileExists(atPath: socket) ? "Connected" : "Not running"
    }
}

/// The command that says where tasks run (a bench, a machine) by ticket, for the board's Where. zerod reruns it every
/// minute; a task can also name its own with `zero label --where`.
private struct PlacesField: View {
    @State private var command = ""
    @State private var saved = ""
    @State private var link = try? ZerodLink()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where tasks run").font(.system(size: 13, weight: .medium))
            HStack {
                TextField("", text: $command, prompt: Text("A command printing [{\"ticket\": \"ENG-1\", \"place\": \"my-bench\"}]"))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced())
                    .onSubmit(save)
                Button("Save", action: save).disabled(command == saved)
            }
            Text("Shown as each task's Where, by its ticket, in place of its folder. Run in your login shell every five minutes.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .task {
            if let current = try? await link?.placesCommand() { command = current; saved = current }
        }
    }

    private func save() {
        let command = command
        Task { if (try? await link?.setPlacesCommand(command)) != nil { saved = command } }
    }
}

/// The Zero plugin, which has Claude Code send its asks and progress to the inbox.
private struct PluginRow: View {
    /// nil while it is being changed.
    @State private var plugin: Bool? = ClaudePlugin.isInstalled
    @State private var mcp = AgentMCP.isInstalled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rows {
                OnboardingRow(icon: "puzzle-piece", picture: Image(nsImage: appTile), title: "Zero plugin",
                              detail: "Configures your agents to work with Zero: asks and progress come to your inbox.") {
                    if let plugin {
                        Switch(isOn: Binding(get: { plugin }, set: { on in
                            self.plugin = nil
                            error = nil
                            Task {
                                if on { error = await ClaudePlugin.install() } else { await ClaudePlugin.uninstall() }
                                self.plugin = ClaudePlugin.isInstalled
                            }
                        }))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                OnboardingRow(icon: "note-3", title: "Scratchpads in Codex and OpenCode",
                              detail: "Adds Zero's MCP server to their config, as the plugin does for Claude Code.") {
                    Switch(isOn: Binding(get: { mcp }, set: { on in
                        error = on ? AgentMCP.install() : nil
                        if !on { AgentMCP.uninstall() }
                        mcp = AgentMCP.isInstalled
                    }))
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
        }
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
    var enabled = true
    /// Solid black (white in dark mode) with the symbol in the opposite colour: a state that is on.
    var filled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            NucleoIcon(symbol, size: 13)
                .foregroundStyle(filled ? AnyShapeStyle(Theme.onKnob) : enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 26).background(filled ? Theme.knob : Theme.chip).clipShape(Circle())
        }
        .buttonStyle(PressableStyle()).disabled(!enabled).help(help).accessibilityLabel(help)
    }
}

/// The folders Zero's own agents start in. Each runs in a terminal of its own (Zero's, or Rex's when Rex is on),
/// so it keeps running whether or not Zero is open.
private struct ProjectsPage: View {
    let inbox: InboxController
    @State private var folders = Projects.folders

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New agents can start in these folders. Each runs in its own terminal and keeps running when Zero closes.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !folders.isEmpty {
                Rows {
                    ForEach(folders, id: \.self) { folder in
                        HStack(spacing: 10) {
                            NucleoIcon("folder", size: 15).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((folder as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                                Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            RowButton(title: "Remove") { save(folders.filter { $0 != folder }) }
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            HStack {
                RowButton(title: "Add folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        save(folders + panel.urls.map(\.path).filter { !folders.contains($0) })
                    }
                }
                Spacer()
            }
        }
    }

    private func save(_ list: [String]) {
        folders = list
        UserDefaults.standard.set(list, forKey: Projects.key)
        inbox.loadSpawnChoices(force: true)
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
            OnboardingRow(icon: "file-content", title: "Log", detail: Paths.log.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                RowButton(title: "View log") { NSWorkspace.shared.open(Paths.log) }
            }
            OnboardingRow(icon: "sparkle-2", title: "Onboarding", detail: "See the welcome again.") {
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
