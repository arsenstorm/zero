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
    var workspace: Workspace? = nil
    var showOnboarding: () -> Void = {}

    enum Page: String, CaseIterable, Identifiable {
        case general = "General", controlBar = "Control bar", composer = "Composer and inbox", devices = "Phone"
        case agents = "Agents", signins = "Accounts", mcp = "MCP servers", chrome = "Browsers"
        case workspaces = "Workspaces", projects = "Folders", links = "Links", events = "Following"
        var id: String { rawValue }
        /// One each, none shared: the sidebar is scanned by its icons.
        var icon: String {
            switch self {
            case .general: "sliders"
            case .controlBar: "layout-top"
            case .composer: "inbox"
            case .devices: "mobile"
            case .agents: "robot"
            case .signins: "circle-user"
            case .mcp: "plug"
            case .chrome: "globe"
            case .workspaces: "suitcase"
            case .projects: "folder"
            case .links: "link"
            case .events: "eye"
            }
        }
        /// General leads on its own, where Home's New task is, so switching between the two moves no row. Then the
        /// app itself, what agents run with, and how the work is laid out.
        static let groups: [(String, [Page])] = [("App", [.controlBar, .composer, .devices]), ("Agents", [.agents, .signins, .mcp, .chrome]),
                                                 ("Work", [.workspaces, .projects, .links, .events])]
    }
    @State private var page = Page.general
    /// A page asked for from elsewhere (the sidebar's Workspace settings…), taken when the view appears.
    @MainActor static var requested: Page?

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
            .thinScrollbar(remember: "settings")
            .background(Theme.card)
        }
        .onAppear { if let asked = Self.requested { page = asked; Self.requested = nil } }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .general: GeneralPage(settings: settings, showOnboarding: showOnboarding)
        case .controlBar: ControlBarPage(settings: settings, store: store, inbox: inbox, workspace: workspace)
        case .composer: ComposerPage(settings: settings)
        case .devices: DevicesPage()
        case .agents: AgentsPage(store: store, inbox: inbox, workspace: workspace)
        case .projects: FoldersPage(settings: settings, inbox: inbox)
        case .links: LinksPage()
        case .events: EventsPage(workspace: workspace)
        case .workspaces: WorkspacesPage(workspace: workspace)
        case .mcp: McpServersPage(workspace: workspace)
        case .signins: SignInsPage(workspace: workspace)
        case .chrome: if let workspace { BrowserRows(workspace: workspace) }
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
    /// The heading as a selector (the tasks sidebar's workspace): the rows it opens.
    var picker: (() -> [SelectorSection])? = nil
    /// The heading's logo: a workspace's glyph; none, Zero's mark.
    var glyph = ""
    /// A row at the foot under a divider (an integration's Edit views), level with the rail's settings.
    var footer: AnyView? = nil
    @ViewBuilder let content: () -> Content
    @AppStorage(SidebarWidth.key) private var width = SidebarWidth.standard
    /// The width when the drag began.
    @State private var dragged: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarHeader(title: title, picker: picker, glyph: glyph)
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
                        // Whole points: a fraction puts everything in it between pixels (hairlines read thicker).
                        width = min(max((start + drag.translation.width).rounded(), SidebarWidth.range.lowerBound), SidebarWidth.range.upperBound)
                    }
                    .onEnded { _ in dragged = nil })
        }
    }
}

/// The heading as a blueprint on drafting paper: dark lines and lettering on light grey (light on dark grey in dark
/// mode). Its foot fades into the sidebar.
struct SidebarHeader: View {
    let title: String
    var picker: (() -> [SelectorSection])? = nil
    var glyph = ""
    @State private var anchor = CGRect.zero
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The panel fades out on an eased curve (a straight ramp bands); only the drawing blurs as it goes,
            // since blurring a flat fill just smudges its edge.
            Theme.blueprint.mask(LinearGradient(stops: ProgressiveBlur<EmptyView>.eased, startPoint: .top, endPoint: .bottom))
            ProgressiveBlur { Blueprint().foregroundStyle(Theme.onBlueprint) }
            // The mark over the rows' icons and the title over their text (10 + 10 + an 18 pt icon + 9), level with the
            // rail's home icon (its centre 28 pt under the panel's top).
            HStack(spacing: 9) {
                if let picker {
                    let open = WorkspaceSelector.shared.open == "workspace"
                    // The logo and the name, one button: either opens the workspaces.
                    Button { WorkspaceSelector.shared.toggle("workspace", kind: .menu, anchor: anchor, rows: picker) } label: {
                        HStack(spacing: 5) {
                            WorkspaceGlyph(glyph: glyph, size: 18).frame(width: 18).padding(.trailing, 4)
                            Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).opacity(hovered || open ? 1 : 0.55)
                        }
                        .padding(.horizontal, 6).frame(height: 26)
                        .background(open || hovered ? Theme.onBlueprint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        // The fill reaches 6 pt past the text on both sides; pulled left by that, the text stays where the title was.
                        .padding(.leading, -6)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
                    .tip("Switch workspace")
                } else {
                    ZeroMark(small: true).frame(width: 20, height: 19).frame(width: 18)
                    Text(title).font(.system(size: 17, weight: .semibold))
                }
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
        @Environment(\.cardBleed) private var bleed
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
            // In Settings the card bleeds past the column by its own inset, so its text lines up with the headings.
            .padding(.horizontal, -bleed)
        }
    }
}

struct Switch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch) }
}

/// How far a card reaches past its column, so its rows' text starts where the text around it does.
extension EnvironmentValues { @Entry var cardBleed: CGFloat = 0 }

/// A heading over a card: what the rows under it are about.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .environment(\.cardBleed, 18)
    }
}

/// One setting: what it is, a line or two on what it does, its control on the right. A logo when the row is a tool's.
struct SettingRow<Control: View>: View {
    var picture: Image? = nil
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(spacing: 12) {
            if let picture { picture.resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            // A fixed slot, so a spinner turning into a button moves nothing beside it; a wider control widens it.
            control().frame(minWidth: 128, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}

/// The pages' sections, one under another.
private struct Sections<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { VStack(alignment: .leading, spacing: 32) { content() } }
}

private struct GeneralPage: View {
    @Bindable var settings: Settings
    let showOnboarding: () -> Void
    /// The states a task's notification comes with, each with its own sound.
    struct Sounded { let state: BoardRow.State; let name: String; let detail: String }
    static let sounded = [
        Sounded(state: .needsYou, name: "Needs you", detail: "It asks you something, or one of its workers does."),
        Sounded(state: .trouble, name: "In trouble", detail: "It failed, got stuck or ran out of usage."),
        Sounded(state: .handed, name: "Over to you", detail: "It has a step for you."),
        Sounded(state: .answered, name: "Replied", detail: "It answered you."),
        Sounded(state: .waiting, name: "Waiting", detail: "The next move is someone else's."),
        Sounded(state: .done, name: "Done", detail: "Nothing is left that it can do."),
    ]
    var body: some View {
        Sections {
            SettingsSection(title: "Zero") {
                Rows {
                    SettingRow(title: "Launch Zero at login", detail: "So agents can always reach you.") {
                        Switch(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                    }
                    SettingRow(title: "Talk hotkey", detail: "Opens the inbox and starts dictation.") {
                        HotKeyRecorder(settings: settings, minWidth: nil)
                    }
                }
            }
            SettingsSection(title: "Notifications") {
                Rows {
                    SettingRow(title: "Needs you", detail: "A task asks you something, or one of its workers does.") {
                        Switch(isOn: $settings.notifyNeedsYou)
                    }
                    SettingRow(title: "In trouble", detail: "A task fails, gets stuck or runs out of usage.") {
                        Switch(isOn: $settings.notifyTrouble)
                    }
                    SettingRow(title: "Finished", detail: "A task is done, replied, blocked or over to you.") {
                        Switch(isOn: $settings.notifyFinished)
                    }
                    SettingRow(title: "Sounds", detail: "With each notification; in Zero, a sound instead.") {
                        Switch(isOn: $settings.notificationSounds)
                    }
                }
            }
            if settings.notificationSounds {
                SettingsSection(title: "Sounds") {
                    Rows {
                        ForEach(Self.sounded, id: \.state) { sounded in
                            SettingRow(title: sounded.name, detail: sounded.detail) { SoundPicker(settings: settings, state: sounded.state) }
                        }
                    }
                }
            }
            SettingsSection(title: "Advanced") {
                Rows {
                    SettingRow(title: "Log", detail: "What Zero did and when: " + Log.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        RowButton(title: "View log") { NSWorkspace.shared.open(Log.file) }
                    }
                    SettingRow(title: "Onboarding", detail: "See the welcome again.") {
                        RowButton(title: "Open", action: showOnboarding)
                    }
                }
            }
        }
    }
}

/// A state's sound: the system's sounds and None, played as it's picked so you hear what you chose.
private struct SoundPicker: View {
    @Bindable var settings: Settings
    let state: BoardRow.State
    var body: some View {
        Picker("", selection: Binding(get: { settings.sound(for: state) }, set: { sound in
            settings.stateSounds[state.rawValue] = sound
            if !sound.isEmpty { NSSound(named: sound)?.play() }
        })) {
            ForEach(Settings.sounds, id: \.self) { sound in
                Text(sound == Settings.defaultSound(state) ? "\(sound) (default)" : sound).tag(sound)
            }
            Divider()
            Text("None").tag("")
        }
        .labelsHidden().fixedSize()
    }
}

private struct ControlBarPage: View {
    @Bindable var settings: Settings
    let store: Store
    let inbox: InboxController
    let workspace: Workspace?
    /// The agent being renamed, and the name typed so far.
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        Sections {
            SettingsSection(title: "Placement") {
                Rows {
                    SettingRow(title: "Follow the active screen", detail: "The bar moves to the screen you use.") {
                        Switch(isOn: $settings.followActiveScreen)
                    }
                    SettingRow(title: "Bar in the window", detail: "The bar sits in Zero's window instead of at the screen's edge.") {
                        Picker("", selection: $settings.barDock) {
                            Text("When it fills the screen").tag(Settings.BarDock.auto)
                            Text("Always").tag(Settings.BarDock.always)
                            Text("Never").tag(Settings.BarDock.never)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            SettingsSection(title: "Agents in the bar") { list }
        }
    }

    @ViewBuilder private var list: some View {
        // The bar's own list: workers folded into their leads, as the dots are.
        let agents = inbox.barAgents(settings: settings, workspace: workspace)
        let names = agents.map(\.0)
        if names.isEmpty {
            Text("No agents yet. They appear here when they first ask you something.").font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    ForEach(names, id: \.self) { name in
                        HStack(spacing: 10) {
                            Circle().fill((agents.first { $0.0 == name }?.1 ?? .closed).color).frame(width: 8, height: 8)
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
                .listStyle(.plain).scrollContentBackground(.hidden).frame(height: min(320, CGFloat(names.count) * 44 + 8))
                Text("Drag to reorder. A removed agent comes back when it next asks you something.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ComposerPage: View {
    @Bindable var settings: Settings
    @State private var microphones: [(name: String, uid: String)] = []
    var body: some View {
        Sections {
            SettingsSection(title: "Composer") {
                Rows {
                    SettingRow(title: "Suggest skills after /", detail: "Commands and skills as you type.") {
                        Switch(isOn: $settings.suggestCommands)
                    }
                    SettingRow(title: "Suggest files after @", detail: "Files from the agent's project.") {
                        Switch(isOn: $settings.suggestFiles)
                    }
                }
            }
            SettingsSection(title: "Inbox") {
                Rows {
                    SettingRow(title: "Take-back window", detail: "Esc takes an answer back within this time.") {
                        HStack(spacing: 6) {
                            Slider(value: $settings.takeBackSeconds, in: 0...5, step: 0.5).frame(width: 80)
                            Text(String(format: "%.1f s", settings.takeBackSeconds)).font(.system(size: 12)).monospacedDigit().frame(width: 38, alignment: .trailing)
                        }
                    }
                    SettingRow(title: "Move to the next ask", detail: "3 s after an answer lands.") {
                        Switch(isOn: $settings.autoAdvance)
                    }
                    SettingRow(title: "Ask expiry", detail: "For asks that set none.") {
                        Stepper("\(settings.defaultTTLMinutes) min", value: $settings.defaultTTLMinutes, in: 5...1440, step: 5).font(.system(size: 12))
                    }
                }
            }
            SettingsSection(title: "Dictation") {
                Rows {
                    SettingRow(title: "Microphone", detail: missing ? "Not connected; the system default is used." : "Used when you dictate a reply.") {
                        Picker("", selection: Binding(get: { settings.inputDeviceUID ?? "" }, set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })) {
                            Text("System default").tag("")
                            ForEach(microphones, id: \.uid) { mic in Text(mic.name).tag(mic.uid) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                }
            }
        }
        .onAppear { microphones = Dictation.inputDevices() }
    }
    private var missing: Bool { settings.inputDeviceUID.map { uid in !microphones.contains { $0.uid == uid } } ?? false }
}

/// How agents run and reach Zero, and where their tasks are.
private struct AgentsPage: View {
    let store: Store
    let inbox: InboxController
    let workspace: Workspace?
    var body: some View {
        Sections {
            SettingsSection(title: "Setup") { PluginRow() }
            SettingsSection(title: "Runtimes") { RuntimesRows(store: store, inbox: inbox) }
            SettingsSection(title: "Tasks") {
                Rows {
                    SettingRow(title: "Archive done tasks", detail: "Put away after this; back when something they follow changes.") {
                        ArchiveCompletedPicker()
                    }
                    SettingRow(title: "Where tasks run", detail: "A command printing [{\"ticket\": \"ENG-1\", \"place\": \"my-bench\"}], run in your login shell every five minutes. Each task's Where is its place, by ticket, in place of its folder.") {
                        PlacesCommandField()
                    }
                }
            }
        }
    }
}

private struct RuntimesRows: View {
    let store: Store
    let inbox: InboxController
    @State private var rexOn = UserDefaults.standard.bool(forKey: RexAdapter.enabledKey)

    private var rexDetail: String {
        rexOn && RexAdapter.executable != nil ? "New agents start in Rex." : "Start new agents in Rex instead of Zero's terminals."
    }

    var body: some View {
        Rows {
            SettingRow(picture: choiceIcon("solo"), title: "Solo", detail: "Starts agents and carries your messages.") {
                Text(soloStatus).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            SettingRow(picture: choiceIcon("rex"), title: "Rex", detail: rexDetail) {
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

/// How long a completed task stays before zerod archives it: zerod's setting, so it holds while the app is closed.
private struct ArchiveCompletedPicker: View {
    @State private var seconds = 24 * 3600
    @State private var link = try? ZerodLink()
    static let choices: [(String, Int)] = [("After an hour", 3600), ("After a day", 24 * 3600), ("After a week", 7 * 24 * 3600), ("Never", 0)]

    var body: some View {
        Picker("", selection: Binding(get: { seconds }, set: { chosen in
            seconds = chosen
            Task { try? await link?.setArchiveCompleted(chosen) }
        })) {
            ForEach(Self.choices, id: \.1) { Text($0.0).tag($0.1) }
        }
        .labelsHidden().fixedSize()
        .task { if let kept = try? await link?.archiveCompleted() { seconds = Self.choices.contains { $0.1 == kept } ? kept : 24 * 3600 } }
    }
}

/// The places command, saved when Return is pressed or the field is left.
private struct PlacesCommandField: View {
    @State private var command = ""
    @State private var saved = ""
    @State private var link = try? ZerodLink()
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $command, prompt: Text("Command"))
            .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced()).frame(width: 260)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .task { if let current = try? await link?.placesCommand() { command = current; saved = current } }
    }

    private func save() {
        let command = command
        guard command != saved else { return }
        Task { if (try? await link?.setPlacesCommand(command)) != nil { saved = command } }
    }
}

/// Settings › Browsers: the browsers agents use, each task in tabs of its own. Zero for Chrome is set up by hand (the
/// native host's manifest, then the extension loaded unpacked); Firefox Developer Edition needs nothing, as Zero opens
/// it under remote control and installs its extension itself. The sites no task may use are every browser's.
private struct BrowserRows: View {
    let workspace: Workspace
    @State private var connected: [String]?
    @State private var folder: String?
    @State private var blocked: [String] = []
    @State private var adding = ""
    /// Safari tried: nil not yet, "" fine, else why not.
    @State private var safari: String?
    @State private var trying = false
    @State private var opening = false
    @State private var firefoxError: String?

    private var chromes: [String]? { connected?.filter { $0 != "Firefox" } }
    private var firefox: Bool { connected?.contains("Firefox") == true }

    var body: some View {
        Sections {
            SettingsSection(title: "Chrome") { chrome }
            SettingsSection(title: "Firefox") {
                Rows {
                    SettingRow(title: "Firefox Developer Edition", detail: firefoxError ?? (firefox
                        ? "Under Zero's remote control, with your sign-ins"
                        : "Opened by Zero under remote control when an agent asks for it")) {
                        if firefox { Text("Connected").font(.system(size: 12)).foregroundStyle(.secondary) }
                        else if opening { ProgressView().controlSize(.small) }
                        else { RowButton(title: "Open") { openFirefox() } }
                    }
                }
            }
            SettingsSection(title: "Safari") {
                Rows {
                    SettingRow(title: "Safari's automation windows", detail: safari.map { $0.isEmpty ? "Working · comparisons get a signed-out Safari window" : $0 }
                        ?? "For comparing pages: a signed-out Safari window with real clicks") {
                        if trying { ProgressView().controlSize(.small) }
                        else { RowButton(title: "Try it") { trySafari() } }
                    }
                }
            }
            SettingsSection(title: "Blocked sites") { sites }
        }
        .task {
            blocked = await workspace.blockedSites()
            while !Task.isCancelled {
                connected = await workspace.browsers()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rows {
                SettingRow(title: "Zero for Chrome", detail: chromes.map { $0.isEmpty ? "Not connected · set it up so agents can use Chrome" : "Connected · each task works in tabs of its own" } ?? "Lets agents use Chrome, each task in tabs of its own") {
                    RowButton(title: chromes?.isEmpty == false ? "Set up again" : "Set up", action: setUp)
                }
            }
            if let folder {
                Text("In Chrome's Extensions page (open now): turn on Developer mode, choose Load unpacked, and pick the folder Finder shows (\((folder as NSString).abbreviatingWithTildeInPath)). Zero for Chrome connects by itself.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private func openFirefox() {
        opening = true
        firefoxError = nil
        Task {
            firefoxError = await workspace.openFirefox()
            connected = await workspace.browsers()
            opening = false
        }
    }

    /// The sites no task may use, in every browser: one a row, removed from its row, added from the last.
    private var sites: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No task may open these sites or their subdomains.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(blocked, id: \.self) { site in
                    BlockedSiteRow(site: site) { saveSites(blocked.filter { $0 != site }) }
                    Divider().padding(.leading, 16)
                }
                HStack(spacing: 10) {
                    NucleoIcon("plus", size: 13).foregroundStyle(.secondary)
                    TextField("Add a site (bank.com)", text: $adding).textFieldStyle(.plain).font(.system(size: 13))
                        .onSubmit {
                            let site = adding.trimmingCharacters(in: .whitespaces).lowercased()
                            guard !site.isEmpty, !blocked.contains(site) else { adding = ""; return }
                            saveSites(blocked + [site])
                            adding = ""
                        }
                }
                .padding(.horizontal, 16).frame(height: 40)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
            .padding(.horizontal, -18)
        }
    }

    private func saveSites(_ sites: [String]) {
        blocked = sites
        Task { await workspace.saveBlockedSites(sites) }
    }

    private func trySafari() {
        trying = true
        Task {
            safari = await workspace.checkSafari() ?? ""
            trying = false
        }
    }

    private func setUp() {
        Task {
            guard let path = await workspace.browserSetup() else { return }
            folder = path
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"), let page = URL(string: "chrome://extensions") {
                NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        }
    }
}

/// A blocked site's row: its name, and a trash icon on hover that removes it.
private struct BlockedSiteRow: View {
    let site: String
    let remove: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack {
            Text(site).font(.system(size: 13))
            Spacer()
            Button(action: remove) { NucleoIcon("trash", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28) }
                .buttonStyle(Hovering(radius: 7)).tip("Unblock it").opacity(hovered ? 1 : 0)
        }
        .padding(.leading, 16).padding(.trailing, 8).frame(height: 40)
        .contentShape(Rectangle()).onHover { hovered = $0 }
    }
}

private struct PluginRow: View {
    /// nil while it is being changed.
    @State private var plugin: Bool? = ClaudePlugin.isInstalled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rows {
                SettingRow(picture: Image(nsImage: appTile), title: "Zero plugin",
                           detail: "Lets your agents reach your inbox and use your scratchpads.") {
                    if let plugin {
                        Switch(isOn: Binding(get: { plugin }, set: { on in
                            self.plugin = nil
                            error = nil
                            Task {
                                if on {
                                    error = await ClaudePlugin.install() ?? AgentMCP.install()
                                } else {
                                    await ClaudePlugin.uninstall()
                                    AgentMCP.uninstall()
                                }
                                self.plugin = ClaudePlugin.isInstalled
                            }
                        }))
                    } else {
                        ProgressView().controlSize(.small)
                    }
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
        .buttonStyle(PressableStyle()).disabled(!enabled).tip(help).accessibilityLabel(help)
    }
}

/// The folders Zero's own agents start in. Each runs in a terminal of its own (Zero's, or Rex's when Rex is on),
/// so it keeps running whether or not Zero is open.
private struct ProjectsPage: View {
    let inbox: InboxController
    @State private var folders = Projects.folders

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where new tasks can start.")
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
            Text("Agents on another machine reach you through files in these synced folders.")
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

/// Projects and drop folders: where agents start, and where asks arrive as files.
private struct FoldersPage: View {
    @Bindable var settings: Settings
    let inbox: InboxController
    var body: some View {
        Sections {
            SettingsSection(title: "Projects") { ProjectsPage(inbox: inbox) }
            SettingsSection(title: "Drop folders") { DropFoldersPage(settings: settings) }
        }
    }
}

/// Where references in messages open: issues in Linear's app, channels and threads in Slack.
private struct LinksPage: View {
    @AppStorage(LinearLinks.key) private var linearInApp = true
    @AppStorage(GitHubLinks.key) private var githubOwner = ""
    var body: some View {
        Sections {
            SettingsSection(title: "Where links open") {
                Rows {
                    SettingRow(title: "GitHub pull requests", detail: "Where repo#123 opens: this owner's, or the agent's folder's if empty.") {
                        TextField("", text: $githubOwner, prompt: Text("Owner"))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced()).frame(width: 140)
                    }
                    SettingRow(title: "Linear issues in the app", detail: LinearLinks.installed ? "Rather than the browser, here and in messages." : "Linear's app isn't installed; issues open in the browser.") {
                        if LinearLinks.installed { Switch(isOn: $linearInApp) } else { Text("Not installed").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    SettingRow(title: "Slack", detail: "Channels and message links open in Slack once it's connected.") {
                        Text(Slack.shared.team.map { "Connected to \($0.name)" } ?? "Not connected").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
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
