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
    /// Where the window has been: each page opened here is a step back and forward retrace.
    var navigation: Navigation? = nil
    var showOnboarding: () -> Void = {}

    enum Page: String, CaseIterable, Identifiable {
        case general = "General", controlBar = "Control bar", composer = "Composer and inbox", devices = "Phone"
        case agents = "Agents", signins = "Accounts", mcp = "MCP servers", chrome = "Browsers"
        case workspaces = "Workspaces", projects = "Folders", git = "Git", links = "Links", events = "Following"
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
            case .git: "code-branch"
            case .links: "link"
            case .events: "eye"
            }
        }
        /// General leads on its own, where Home's New task is, so switching between the two moves no row. Then the
        /// app itself, what agents run with, and how the work is laid out.
        static let groups: [(String, [Page])] = [("App", [.controlBar, .composer, .devices]), ("Agents", [.agents, .signins, .mcp, .chrome]),
                                                 ("Work", [.workspaces, .projects, .git, .links, .events])]
    }
    /// The page open, kept in the window's history (Navigation) so back and forward go between pages; on its own
    /// where there's no history (the settings window of its own).
    @State private var ownPage = Page.general
    private var page: Page {
        get { navigation.map { Page(rawValue: $0.settingsPage ?? "") ?? .general } ?? ownPage }
        nonmutating set { if let navigation { navigation.settingsPage = newValue.rawValue } else { ownPage = newValue } }
    }
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
        case .git: GitPage()
        case .links: LinksPage(workspace: workspace)
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
    /// Settings' card: its surface, rounded, with a hairline edge. Rows put theirs on one.
    func settingsCard() -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
    }

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
            .bleedingCard()
        }
    }
}

struct Switch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch) }
}

/// A card's row that is its own menu: a soft fill under the pointer (or while it's open), and a click opens Zero's
/// menu under the row's trailing end. Nothing kept beside the row's own content for its actions.
private struct RowMenu: ViewModifier {
    let id: String
    let enabled: Bool
    let rows: () -> [SelectorSection]
    @State private var frame = CGRect.zero
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(enabled && (hovered || WorkspaceSelector.shared.open == id) ? Theme.row : .clear)
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                let width = SelectorView.width(.menu)
                WorkspaceSelector.shared.toggle(id, kind: .menu, anchor: CGRect(x: frame.maxX - width - 8, y: frame.minY, width: width, height: frame.height), rows: rows)
            }
            .onHover { hovered = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

extension View {
    func rowMenu(_ id: String, enabled: Bool = true, rows: @escaping () -> [SelectorSection]) -> some View { modifier(RowMenu(id: id, enabled: enabled, rows: rows)) }
}

/// A heading's quiet button (Add workspace, Add account): an icon and words, a soft fill under the pointer or while
/// what it opened is open.
struct GhostButton: View {
    let title: String
    let icon: String
    var open = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            NucleoLabel(title, icon: icon, size: 12).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 9).frame(height: 26)
                .background(open || hovered ? Theme.row : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovered = $0 }
    }
}

/// A setting's choice: what's chosen and a chevron, on a chip that opens Zero's selector as a plain menu, as a
/// composer's chip opens it; groups of choices with a line between. A soft fill under the pointer and while it's open.
struct SettingChoice<Value: Hashable>: View {
    /// The selector's name for this chip, one per setting.
    let id: String
    let choices: [[(title: String, value: Value)]]
    @Binding var selection: Value
    @State private var anchor = CGRect.zero
    @State private var hovered = false

    var body: some View {
        let open = WorkspaceSelector.shared.open == id
        let chosen = choices.joined().first { $0.value == selection } ?? choices.first?.first
        Button { WorkspaceSelector.shared.toggle(id, kind: .menu, anchor: anchor, rows: { sections }) } label: {
            HStack(spacing: 5) {
                Text(chosen?.title ?? "").font(.system(size: 13)).lineLimit(1)
                NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(open || hovered ? Theme.row : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovered = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
    }

    private var sections: [SelectorSection] {
        choices.enumerated().map { index, group in SelectorSection(id: "\(index)", title: "", icon: nil, rows: group.map(row)) }
    }

    private func row(_ choice: (title: String, value: Value)) -> SelectorRow {
        SelectorRow(id: "\(choice.value)", title: choice.title, provider: nil, providerIcon: nil, detail: nil, context: nil,
                    levels: [], defaultLevel: nil, modelID: nil, selected: choice.value == selection) { selection = choice.value }
    }
}

/// How far a card reaches past its column, so its rows' text starts where the text around it does.
extension EnvironmentValues { @Entry var cardBleed: CGFloat = 0 }

/// A heading over a card: what the rows under it are about, with a mark before it and a button at its end if it has
/// them. Its cards bleed past the column (bleedingCard).
struct SettingsSection<Content: View>: View {
    let title: String
    var icon: AnyView? = nil
    var accessory: AnyView? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let icon { icon }
                Text(title).font(.system(size: 13, weight: .semibold))
                if let accessory { Spacer(); accessory }
            }
            content()
        }
        .environment(\.cardBleed, 18)
    }
}

/// A card that bleeds past its column by its own inset, so its rows' text (18 in) lines up with the headings.
private struct BleedingCard: ViewModifier {
    @Environment(\.cardBleed) private var bleed
    func body(content: Content) -> some View { content.settingsCard().padding(.horizontal, -bleed) }
}

extension View {
    func bleedingCard() -> some View { modifier(BleedingCard()) }
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

/// The version, and an update when there is one: installed only on the user's click, saying what it does to agents.
private struct UpdateRow: View {
    var body: some View {
        let updater = Updater.shared
        switch updater.state {
        case .unchecked, .checking:
            SettingRow(title: "Zero \(updater.current)", detail: "Checking for updates…") { EmptyView() }
        case .upToDate:
            SettingRow(title: "Zero \(updater.current)", detail: "Up to date.") { Button("Check now") { Task { await updater.check() } } }
        case .failed(let problem):
            SettingRow(title: "Zero \(updater.current)", detail: problem) { Button("Check again") { Task { await updater.check() } } }
        case .available(let release):
            SettingRow(title: "Zero \(release.version) is available",
                       detail: "Updating restarts Zero: running agents pause between steps for a few seconds, then carry on.") {
                Button("Update and restart") { Task { await updater.install(release) } }
            }
        case .installing(let release):
            SettingRow(title: "Updating to Zero \(release.version)…", detail: "Zero quits and opens again as the new version.") { EmptyView() }
        }
    }
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
                    UpdateRow()
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
                    SettingRow(title: "In trouble", detail: "A task fails, gets stuck, runs out of usage, or is blocked.") {
                        Switch(isOn: $settings.notifyTrouble)
                    }
                    SettingRow(title: "Finished", detail: "A task is done, replied, waiting or over to you.") {
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
        let sounds = Settings.sounds.map { sound in (title: sound == Settings.defaultSound(state) ? "\(sound) (default)" : sound, value: sound) }
        // ponytail: the selector's menu doesn't scroll; these 15 rows are about 450 pt, cut off where neither side of
        // the chip has that room. Let the menu kind scroll (Selector.swift) if a screen that short turns up.
        SettingChoice(id: "sound-" + state.rawValue, choices: [sounds, [(title: "None", value: "")]], selection: Binding(get: { settings.sound(for: state) }, set: { sound in
            settings.stateSounds[state.rawValue] = sound
            if !sound.isEmpty { Chime.play(sound) }
        }))
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
                        SettingChoice(id: "barDock", choices: [[("When it fills the screen", .auto), ("Always", .always), ("Never", .never)]], selection: $settings.barDock)
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
                        SettingChoice(id: "microphone", choices: [[(title: "System default", value: "")] + microphones.map { (title: $0.name, value: $0.uid) }],
                                      selection: Binding(get: { settings.inputDeviceUID ?? "" }, set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }))
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
                    SettingRow(title: "Archive done tasks", detail: "Done means finished end to end. Put away then; back when something they follow changes.") {
                        ArchiveCompletedPicker()
                    }
                    SettingRow(title: "Agents' own subagents", detail: "Off, agents hand work to Zero workers, which you see, steer and stop here. On, Claude and Codex may also use their own, which you can't. From each task's next start.") {
                        SubagentsSwitch()
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

/// When a done task is put away: once you've read it (as a done worker leaves once its lead has its report), after a
/// while, or never. zerod's setting, so it holds while the app is closed.
private struct ArchiveCompletedPicker: View {
    @State private var seconds = 24 * 3600
    @State private var link = try? ZerodLink()
    static let choices: [(String, Int)] = [("Once you've read it", -1), ("After an hour", 3600), ("After a day", 24 * 3600), ("After a week", 7 * 24 * 3600), ("Never", 0)]

    var body: some View {
        SettingChoice(id: "archiveCompleted", choices: [Self.choices.map { (title: $0.0, value: $0.1) }], selection: Binding(get: { seconds }, set: { chosen in
            seconds = chosen
            Task { try? await link?.setArchiveCompleted(chosen) }
        }))
        .task { if let kept = try? await link?.archiveCompleted() { seconds = Self.choices.contains { $0.1 == kept } ? kept : 24 * 3600 } }
    }
}

/// Whether agents may use their CLI's own subagents. zerod's setting, read as each agent starts.
private struct SubagentsSwitch: View {
    @State private var on = false
    @State private var link = try? ZerodLink()

    var body: some View {
        Switch(isOn: Binding(get: { on }, set: { chosen in
            on = chosen
            Task { try? await link?.setSubagents(chosen) }
        }))
        .task { if let kept = try? await link?.subagents() { on = kept } }
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
            VStack(spacing: 0) {
                ForEach(blocked, id: \.self) { site in
                    BlockedSiteRow(site: site) { saveSites(blocked.filter { $0 != site }) }
                    Divider().padding(.leading, 18)
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
                .padding(.horizontal, 18).frame(height: 40)
            }
            .bleedingCard()
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
        .padding(.leading, 18).padding(.trailing, 8).frame(height: 40)
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
/// Projects and drop folders: where agents start, and where asks arrive as files. Each folder a row with a name of
/// the user's choosing (its own until then); what's done to one, in its menu.
private struct FoldersPage: View {
    @Bindable var settings: Settings
    let inbox: InboxController
    @State private var folders = Projects.folders
    @State private var renaming: Folder?
    @State private var addingDrop = false
    /// Bumped when a name changes: the rows read names from UserDefaults.
    @State private var named = 0

    private struct Folder: Identifiable { let path: String; var id: String { path } }

    var body: some View {
        Sections {
            SettingsSection(title: "Projects", accessory: AnyView(GhostButton(title: "Add folder", icon: "plus", action: addFolders))) {
                card(empty: folders.isEmpty) {
                    ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                        if index > 0 { Divider().padding(.leading, 18) }
                        HStack(spacing: 10) {
                            NucleoIcon("folder", size: 15).foregroundStyle(.secondary).frame(width: 18)
                            Text(Projects.name(of: folder)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 18).frame(height: 44)
                        .tip((folder as NSString).abbreviatingWithTildeInPath)
                        .rowMenu("folder-\(folder)") {
                            ComposerRows.menu([
                                [("rename", "Rename…", "pen", false, { renaming = Folder(path: folder) }),
                                 ("finder", "Show in Finder", "folder", false, { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) })],
                                [("remove", "Remove", "trash", false, { save(folders.filter { $0 != folder }) })],
                            ])
                        }
                    }
                }
                .id(named)
            }
            SettingsSection(title: "Drop folders", accessory: AnyView(GhostButton(title: "Add drop folder", icon: "plus") { addingDrop = true })) {
                card(empty: settings.dropPatterns.isEmpty) {
                    ForEach(Array(settings.dropPatterns.enumerated()), id: \.element) { index, pattern in
                        if index > 0 { Divider().padding(.leading, 18) }
                        HStack {
                            Text(pattern).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 18).frame(height: 44)
                        .rowMenu("drop-\(pattern)") {
                            ComposerRows.menu([[("remove", "Remove", "trash", false, { settings.dropPatterns.removeAll { $0 == pattern } })]])
                        }
                    }
                }
            }
        }
        .zeroDialog(item: $renaming) { folder in
            NameSheet(title: "Rename \(Projects.name(of: folder.path))", name: Projects.name(of: folder.path), action: "Rename") { name in
                Projects.setName(name, for: folder.path)
                named += 1
                inbox.loadSpawnChoices(force: true)
            }
        }
        .zeroDialog(isPresented: $addingDrop) { DropFolderForm(settings: settings) }
    }

    private func card<Content: View>(empty: Bool, @ViewBuilder rows: () -> Content) -> some View {
        VStack(spacing: 0) {
            if empty { Text("None yet").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 44) }
            rows()
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .bleedingCard()
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { save(folders + panel.urls.map(\.path).filter { !folders.contains($0) }) }
    }

    private func save(_ list: [String]) {
        folders = list
        UserDefaults.standard.set(list, forKey: Projects.key)
        inbox.loadSpawnChoices(force: true)
    }
}

/// A drop folder added: a pattern of synced folders (~/remotes/*/.zero), typed or chosen.
private struct DropFolderForm: View {
    @Bindable var settings: Settings
    @Environment(\.closeDialog) private var dismiss
    @State private var pattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                DialogTitle(text: "Add a drop folder")
                Text("Agents on another machine reach you through files in synced folders that match it.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("", text: $pattern, prompt: Text("~/remotes/*/.zero")).textFieldStyle(.dialog).font(.system(size: 13, design: .monospaced)).onSubmit(add)
                DialogButton(title: "Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { pattern = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
                }
            }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Add", kind: .primary, enabled: !pattern.trimmingCharacters(in: .whitespaces).isEmpty, action: add)
            }
        }
        .frame(width: 440)
    }

    private func add() {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        if !settings.dropPatterns.contains(pattern) { settings.dropPatterns.append(pattern) }
        dismiss()
    }
}

/// Where references in messages open: issues in Linear's app, channels and threads in Slack.
private struct LinksPage: View {
    @AppStorage(GitHubLinks.key) private var github = true
    @AppStorage(LinearLinks.enabledKey) private var linear = true
    @AppStorage(LinearLinks.key) private var linearInApp = true
    let workspace: Workspace?
    @State private var connecting = false

    var body: some View {
        Sections {
            SettingsSection(title: "GitHub", icon: AnyView(Integration.github.icon(size: 14).foregroundStyle(.secondary))) {
                Rows {
                    SettingRow(title: "Link pull requests and commits", detail: "repo#123, #123 and commit hashes in messages open on GitHub.") { Switch(isOn: $github) }
                }
            }
            SettingsSection(title: "Linear", icon: AnyView(Integration.linear.icon(size: 14).foregroundStyle(.secondary))) {
                Rows {
                    SettingRow(title: "Link issues", detail: "ABC-123 in messages opens the issue.") { Switch(isOn: $linear) }
                    SettingRow(title: "Open issues in the Linear app", detail: LinearLinks.installed ? "Rather than the browser." : "Linear's app isn't installed.") {
                        Switch(isOn: Binding(get: { linear && LinearLinks.installed && linearInApp }, set: { linearInApp = $0 })).disabled(!linear || !LinearLinks.installed)
                    }
                }
            }
            SettingsSection(title: "Slack", icon: AnyView(Integration.slack.icon(size: 14).foregroundStyle(.secondary)),
                            accessory: workspace == nil ? nil : AnyView(GhostButton(title: "Connect Slack", icon: "plus") { connecting = true })) {
                Rows {
                    if Slack.shared.teams.isEmpty {
                        SettingRow(title: "No workspace connected", detail: "Once one is, its #channels and message links open in Slack.") { EmptyView() }
                    }
                    ForEach(Slack.shared.teams, id: \.team.id) { connected in
                        SettingRow(title: connected.team.name, detail: "\(connected.team.domain).slack.com: its #channels and message links open in Slack.") {
                            if let workspace { DialogButton(title: "Disconnect") { Task { await workspace.disconnectSlack(team: connected.team.id) } } }
                        }
                    }
                }
            }
        }
        .zeroDialog(isPresented: $connecting) { if let workspace { SlackConnect(workspace: workspace) } }
    }
}

/// Connecting a Slack workspace: Zero's Slack app made in it from the manifest, then the user token Slack shows.
private struct SlackConnect: View {
    let workspace: Workspace
    @Environment(\.closeDialog) private var dismiss
    @State private var token = ""
    @State private var waiting = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                DialogTitle(text: "Connect Slack")
                Text("Zero reads channels, messages and names; it posts nothing. Each workspace gets Zero's own Slack app.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DialogPart(title: "1. Make Zero's app in the workspace") {
                HStack {
                    Text("Slack opens with it filled in: Create, then Install to Workspace.").font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    DialogButton(title: "Open Slack") { NSWorkspace.shared.open(Slack.createAppURL) }
                }
            }
            DialogPart(title: "2. Paste its User OAuth Token") {
                SecureField("", text: $token, prompt: Text("xoxp-…")).textFieldStyle(.dialog).onSubmit(connect)
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: waiting ? "Connecting…" : "Connect", kind: .primary, enabled: !waiting && !token.trimmingCharacters(in: .whitespaces).isEmpty, action: connect)
            }
        }
        .frame(width: 440)
    }

    private func connect() {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        waiting = true
        problem = nil
        Task {
            problem = await workspace.connectSlack(token: token)
            waiting = false
            if problem == nil { dismiss() }
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
