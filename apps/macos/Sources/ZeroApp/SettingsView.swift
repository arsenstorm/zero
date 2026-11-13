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
        case general = "General", inbox = "Inbox and bar", devices = "Phone"
        case agents = "Agents", signins = "Accounts and models", git = "Git", chrome = "Browsers", mcp = "MCP servers"
        case workspaces = "Workspaces", github = "GitHub", linear = "Linear", slack = "Slack"
        var id: String { rawValue }
        /// One each, none shared: the sidebar is scanned by its icons.
        var icon: String {
            switch self {
            case .general: "sliders"
            case .inbox: "inbox"
            case .devices: "mobile"
            case .agents: "robot"
            case .signins: "circle-user"
            case .git: "code-branch"
            case .chrome: "globe"
            case .mcp: "plug"
            case .workspaces: "suitcase"
            case .github, .linear, .slack: ""
            }
        }
        /// GitHub, Linear and Slack: drawn with their own marks.
        var integration: Integration? { Integration(rawValue: rawValue.lowercased()) }
        /// The pages before the groups: General (Zero's version and health at its foot), the inbox and the phone, which
        /// everyone meets.
        static let top: [Page] = [.general, .inbox, .devices]
        /// Then what agents run with (the tools they use among them), how the work is laid out, and the services Zero
        /// connects to.
        static let groups: [(String, [Page])] = [
            ("Agents", [.agents, .signins, .git, .chrome, .mcp]), ("Work", [.workspaces]), ("Connections", [.github, .linear, .slack]),
        ]
    }
    /// The page open, kept in the window's history (Navigation) so back and forward go between pages; on its own
    /// where there's no history (the settings window of its own).
    @State private var ownPage = Page.general
    private var page: Page {
        get { navigation.map { Page(rawValue: $0.settingsPage ?? "") ?? .general } ?? ownPage }
        nonmutating set { if let navigation { navigation.settingsPage = newValue.rawValue } else { ownPage = newValue } }
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarColumn(title: "Settings") {
                ForEach(Page.top) { item in SidebarItem(item.rawValue, icon: item.icon, selected: item == page) { page = item } }
                ForEach(Page.groups, id: \.0) { group, pages in
                    SidebarHeading(text: group)
                    ForEach(pages) { item in
                        if let integration = item.integration {
                            SidebarItem(title: item.rawValue, selected: item == page, action: { page = item }) {
                                integration.icon(size: 15)
                            }
                        } else {
                            SidebarItem(item.rawValue, icon: item.icon, selected: item == page) { page = item }
                        }
                    }
                }
            }
            Rectangle().fill(Theme.stroke).frame(width: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PageTitle(text: page.rawValue).padding(.bottom, 24)
                        content
                    }
                    .centredColumn(680)
                    .padding(.vertical, 28)
                }
                .thinScrollbar(remember: "settings")
                .background(Theme.card)
                .onAppear { scroll(proxy, to: navigation?.settingsSection) }
                .onChange(of: navigation?.settingsSection) { _, section in scroll(proxy, to: section) }
            }
        }
    }

    /// To a section asked for (the gear's dot: Health), once laid out and after the remembered offset is restored.
    private func scroll(_ proxy: ScrollViewProxy, to section: String?) {
        guard let section else { return }
        navigation?.settingsSection = nil
        DispatchQueue.main.async { DispatchQueue.main.async { proxy.scrollTo(section, anchor: .top) } }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .general: GeneralPage(settings: settings, workspace: workspace, showOnboarding: showOnboarding) { page = $0 }
        case .inbox: InboxPage(settings: settings, store: store, inbox: inbox, workspace: workspace)
        case .devices: DevicesPage()
        case .agents: AgentsPage(settings: settings)
        case .signins: SignInsPage(workspace: workspace)
        case .git: GitPage()
        case .chrome: if let workspace { BrowserRows(workspace: workspace) }
        case .mcp: McpServersPage(workspace: workspace)
        case .workspaces:
            Sections {
                WorkspacesPage(workspace: workspace)
                FoldersPage(inbox: inbox)
            }
        case .github, .linear, .slack: IntegrationPage(integration: page.integration!, workspace: workspace)
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
    @ViewBuilder let content: () -> Content
    @AppStorage(SidebarWidth.key) private var width = SidebarWidth.standard
    /// The width when the drag began.
    @State private var dragged: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarHeader(title: title, picker: picker, glyph: glyph)
                .padding(.horizontal, -10).padding(.bottom, -4)
            content()
        }
        .padding(.horizontal, 10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.composer)
        // The edge to drag: a thin strip along it, inside the sidebar so the page doesn't take its clicks.
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 6).contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragged ?? width
                            dragged = start
                            // Whole points: a fraction puts everything in it between pixels (hairlines read thicker).
                            width = min(
                                max((start + drag.translation.width).rounded(), SidebarWidth.range.lowerBound),
                                SidebarWidth.range.upperBound)
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
                    Button {
                        WorkspaceSelector.shared.toggle("workspace", kind: .menu, anchor: anchor, rows: picker)
                    } label: {
                        HStack(spacing: 5) {
                            WorkspaceGlyph(glyph: glyph, size: 18).frame(width: 18).padding(.trailing, 4)
                            Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).opacity(
                                hovered || open ? 1 : 0.55)
                        }
                        .padding(.horizontal, 6).frame(height: 26)
                        .background(open || hovered ? Theme.onBlueprint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        // The fill reaches 6 pt past the text on both sides; pulled left by that, the text stays where the title was.
                        .padding(.leading, -6)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 }
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        anchor = $0
                    }
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
    /// Its key, said in a tip.
    var shortcut: String? = nil
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
        .tip(shortcut == nil ? "" : title, shortcut: shortcut)
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
        /// Its right-click menu open: lit as under the pointer while the pointer is on the menu.
        @Environment(\.menuShown) private var menuShown
        var body: some View {
            label
                .background(
                    style.selected ? style.fill : hovering || menuShown ? style.hover : .clear,
                    in: RoundedRectangle(cornerRadius: style.radius)
                )
                .contentShape(RoundedRectangle(cornerRadius: style.radius))
                .onHover { hovering = $0 }
        }
    }
}

extension SidebarItem where Icon == NucleoIcon {
    init(_ title: String, icon: String, selected: Bool = false, shortcut: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, shortcut: shortcut, action: action) { NucleoIcon(icon, size: 15) }
    }
}

extension SidebarItem where Icon == EmptyView {
    init(_ title: String, selected: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, action: action) { EmptyView() }
    }
}

/// Nothing to show: an icon in a soft circle, what would show here, and maybe the way to start one.
struct EmptyState: View {
    let title: String
    let detail: String
    var icon = "triangle-warning"
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            NucleoIcon(icon, size: 26).foregroundStyle(.secondary)
                .frame(width: 64, height: 64).background(Theme.row, in: Circle())
            VStack(spacing: 6) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            if let action { DialogButton(title: action.title, action: action.run) }
        }
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
                    if index > 0 { Hairline() }
                    child
                }
            }
            .padding(.horizontal, 18)
            .bleedingCard()
        }
    }
}

/// The Mac's own switch at the size System Settings draws it (44 by 20): the switch macOS gives SwiftUI is 54 by 24
/// whatever its control size, large beside a row's 13 point words.
struct Switch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).focusEffectDisabled().scaleEffect(44 / 54).frame(width: 44, height: 20)
    }
}

/// A card's row that is its own menu: a soft fill under the pointer (or while it's open), and a click opens Zero's
/// menu under the row's trailing end. Nothing kept beside the row's own content for its actions.
private struct RowMenu: ViewModifier {
    let id: String
    let enabled: Bool
    let first: Bool
    let last: Bool
    let rows: () -> [SelectorSection]
    @State private var frame = CGRect.zero
    @State private var hovered = false

    func body(content: Content) -> some View {
        // Square, but for the card's own corners at its ends. Not left to the card's clip: a row's tip puts an NSView
        // in it while hovered, and the clip then rounds that row's fill on its own, a pill mid-card.
        let top: CGFloat = first ? 14 : 0, bottom: CGFloat = last ? 14 : 0
        content
            .background(
                enabled && (hovered || WorkspaceSelector.shared.open == id) ? Theme.row : .clear,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                let width = SelectorView.width(.menu)
                WorkspaceSelector.shared.toggle(
                    id, kind: .menu, anchor: CGRect(x: frame.maxX - width - 8, y: frame.minY, width: width, height: frame.height),
                    rows: rows)
            }
            .onHover { hovered = $0 }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                frame = $0
            }
    }
}

extension View {
    /// `first` and `last`: where the row sits in its card, so its fill takes the card's corners there.
    func rowMenu(
        _ id: String, enabled: Bool = true, first: Bool, last: Bool, rows: @escaping () -> [SelectorSection]
    ) -> some View {
        modifier(RowMenu(id: id, enabled: enabled, first: first, last: last, rows: rows))
    }
}

/// A heading's quiet button (Add workspace, Add account): an icon and words, a soft fill under the pointer or while
/// what it opened is open.
struct GhostButton: View {
    let title: String
    let icon: String
    var open = false
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            NucleoLabel(title, icon: icon, size: 12).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 9).frame(height: 26)
                .background(enabled && (open || hovered) ? Theme.hover : .clear, in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.4)
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
    /// A choice's own mark before its title (a terminal app's icon), where it has one.
    var icon: (Value) -> Image? = { _ in nil }
    @State private var anchor = CGRect.zero
    @State private var hovered = false

    var body: some View {
        let open = WorkspaceSelector.shared.open == id
        let chosen = choices.joined().first { $0.value == selection } ?? choices.first?.first
        Button {
            WorkspaceSelector.shared.toggle(id, kind: .menu, anchor: anchor, rows: { sections })
        } label: {
            HStack(spacing: 5) {
                if let mark = chosen.flatMap({ icon($0.value) }) { mark.resizable().frame(width: 16, height: 16) }
                Text(chosen?.title ?? "").font(.system(size: 13)).lineLimit(1)
                NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(open || hovered ? Theme.hover : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovered = $0 }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            anchor = $0
        }
    }

    private var sections: [SelectorSection] {
        choices.enumerated().map { index, group in SelectorSection(id: "\(index)", title: "", icon: nil, rows: group.map(row)) }
    }

    private func row(_ choice: (title: String, value: Value)) -> SelectorRow {
        SelectorRow(
            id: "\(choice.value)", title: choice.title, provider: nil, providerIcon: nil, detail: nil, context: nil,
            levels: [], defaultLevel: nil, modelID: nil, selected: choice.value == selection, pick: { selection = choice.value },
            image: icon(choice.value))
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
            // One height for every heading, with or without its icon or buttons (Add account's 26 pt): otherwise the
            // first heading of a page sat lower on a page whose headings had them, and moved between pages.
            .frame(height: 26)
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
    /// More on it, after the detail: the guide's page, say.
    var more: (title: String, url: URL)? = nil
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(spacing: 12) {
            if let picture {
                picture.resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let more {
                    Button {
                        NSWorkspace.shared.open(more.url)
                    } label: {
                        TaskDetails.linked(more.title).font(.system(size: 12))
                    }
                    .buttonStyle(.plain).padding(.top, 2)
                }
            }
            Spacer(minLength: 16)
            // A fixed slot, so a spinner turning into a button moves nothing beside it; a wider control widens it.
            control().frame(minWidth: 128, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}

/// The pages' sections, one under another.
struct Sections<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { VStack(alignment: .leading, spacing: 32) { content() } }
}

/// The version, and an update when there is one: installed only on the user's click, saying what it does to agents.
struct UpdateRow: View {
    var body: some View {
        let updater = Updater.shared
        switch updater.state {
        case .unchecked, .checking:
            SettingRow(title: "Zero \(updater.current)", detail: "Checking for updates…") { EmptyView() }
        case .upToDate:
            SettingRow(title: "Zero \(updater.current)", detail: "Up to date.") {
                RowButton(title: "Check now") { Task { await updater.check() } }
            }
        case .failed(let problem):
            SettingRow(title: "Zero \(updater.current)", detail: problem) {
                RowButton(title: "Check again") { Task { await updater.check() } }
            }
        case .available(let release):
            SettingRow(
                title: "Zero \(release.version) is available",
                detail: "Updating restarts Zero: running agents pause between steps for a few seconds, then carry on."
            ) {
                RowButton(title: "Update and restart") { Task { await updater.install(release) } }
            }
        case .installing(let release):
            SettingRow(title: "Updating to Zero \(release.version)…", detail: "Zero quits and opens again as the new version.") {
                EmptyView()
            }
        }
    }
}

private struct GeneralPage: View {
    @Bindable var settings: Settings
    let workspace: Workspace?
    let showOnboarding: () -> Void
    let go: (SettingsView.Page) -> Void
    /// Each state's sound, in its dialog.
    @State private var eachState = false

    var body: some View {
        Sections {
            SetupChecklist(workspace: workspace, go: go)
            SettingsSection(title: "Zero") {
                Rows {
                    SettingRow(title: "Launch Zero at login", detail: "So agents can always reach you.") {
                        Switch(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                    }
                    SettingRow(title: "Inbox hotkey", detail: "Opens the inbox from any app.") {
                        HotKeyRecorder(settings: settings, minWidth: nil)
                    }
                }
            }
            SettingsSection(title: "Notifications") {
                Rows {
                    notification(
                        "Needs you", "A task asks you something or has a step for you, or one of its workers asks.", .needsYou,
                        $settings.notifyNeedsYou)
                    notification(
                        "In trouble", "A task fails, gets stuck, runs out of usage, or is blocked.", .trouble, $settings.notifyTrouble)
                    notification("Finished", "A task is done, replied, or waiting on someone else.", .finished, $settings.notifyFinished)
                }
                Text("While you're in Zero, you hear the sound instead of seeing a notification.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            AboutSections(showOnboarding: showOnboarding)
        }
        .zeroDialog(isPresented: $eachState) { StateSoundsSheet(settings: settings) }
    }

    private func notification(_ title: String, _ detail: String, _ kind: AlertKind, _ on: Binding<Bool>) -> some View {
        SettingRow(title: title, detail: detail) {
            HStack(spacing: 8) {
                KindSound(settings: settings, kind: kind) { eachState = true }
                Switch(isOn: on)
            }
        }
    }
}

/// What's left to set up, while the two that matter aren't done: the plugin and an account. Optional ones (a phone,
/// Chrome) are listed with them, and go with the card.
private struct SetupChecklist: View {
    let workspace: Workspace?
    let go: (SettingsView.Page) -> Void
    @State private var plugin = ClaudePlugin.isInstalled
    @State private var installing = false
    @State private var chrome = false

    var body: some View {
        if !plugin || workspace?.signins.isEmpty != false {
            SettingsSection(title: "Set up Zero") {
                Rows {
                    step("Zero plugin in your agents", "So they ask you here instead of waiting in a terminal.", done: plugin) {
                        if installing {
                            Spinner().frame(width: 12, height: 12)
                        } else {
                            RowButton(title: "Install") {
                                installing = true
                                Task {
                                    _ = await ClaudePlugin.install() ?? AgentMCP.install()
                                    plugin = ClaudePlugin.isInstalled
                                    installing = false
                                }
                            }
                        }
                    }
                    step(
                        "An account for an agent", "Claude, ChatGPT or an API key, for your agents to run as.",
                        done: workspace?.signins.isEmpty == false
                    ) {
                        RowButton(title: "Add account") { go(.signins) }
                    }
                    step("Your phone (optional)", "Your tasks and asks on your iPhone.", done: !Phones.shared.devices.isEmpty) {
                        RowButton(title: "Pair") { go(.devices) }
                    }
                    step("Chrome for agents (optional)", "Agents use Chrome, each task in tabs of its own.", done: chrome) {
                        RowButton(title: "Set up") { go(.chrome) }
                    }
                }
            }
            .task { chrome = await workspace?.browsers().contains { $0 != "Firefox" } ?? false }
        }
    }

    private func step(_ title: String, _ detail: String, done: Bool, @ViewBuilder action: () -> some View) -> some View {
        let action = action()
        return SettingRow(title: title, detail: detail) {
            if done { StatePill(text: "Done", color: Theme.doneInk) } else { action }
        }
    }
}

/// A kind of notification's sound: the system's sounds and None, played as it's picked, or each of its states' own
/// (the dialog), which is what it shows when they differ.
private struct KindSound: View {
    @Bindable var settings: Settings
    let kind: AlertKind
    let eachState: () -> Void
    private static let each = "*"

    var body: some View {
        let standard = Settings.defaultSound(Settings.soundKinds.first { $0.kind == kind }!.states[0])
        let sounds = Settings.sounds.map { (title: $0 == standard ? "\($0) (default)" : $0, value: $0) }
        // ponytail: the selector's menu doesn't scroll; these 17 rows are about 500 pt, cut off where neither side of
        // the chip has that room. Let the menu kind scroll (Selector.swift) if a screen that short turns up.
        SettingChoice(
            id: "sound-" + kind.rawValue,
            choices: [sounds, [(title: "None", value: "")], [(title: "Each state's sound…", value: Self.each)]],
            selection: Binding(
                get: { settings.sound(for: kind) ?? Self.each },
                set: { sound in
                    if sound == Self.each { eachState(); return }
                    settings.setSound(sound, for: kind)
                    if !sound.isEmpty { Chime.play(sound) }
                }))
    }
}

/// Each state's own sound, for those who'd rather tell them apart than hear one a kind.
private struct StateSoundsSheet: View {
    @Bindable var settings: Settings
    @Environment(\.closeDialog) private var dismiss
    static let states: [(state: BoardRow.State, name: String)] = [
        (.needsYou, "Needs you"), (.handed, "Over to you"), (.trouble, "In trouble"), (.blocked, "Blocked"), (.answered, "Replied"),
        (.waiting, "Waiting"), (.done, "Done"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(
                text: "Each state's sound",
                detail: "A task's notification plays the sound of the state it came to."
            )
            VStack(spacing: 4) {
                ForEach(Self.states, id: \.state) { row in
                    HStack {
                        Text(row.name).font(.system(size: 13))
                        Spacer()
                        SoundPicker(settings: settings, state: row.state)
                    }
                }
            }
            HStack {
                Spacer()
                DialogButton(title: "Done", kind: .primary) { dismiss() }
            }
        }
        .frame(width: 360)
    }
}

/// A state's sound: the system's sounds and None, played as it's picked so you hear what you chose.
private struct SoundPicker: View {
    @Bindable var settings: Settings
    let state: BoardRow.State
    var body: some View {
        let sounds = Settings.sounds.map { sound in
            (title: sound == Settings.defaultSound(state) ? "\(sound) (default)" : sound, value: sound)
        }
        SettingChoice(
            id: "sound-" + state.rawValue, choices: [sounds, [(title: "None", value: "")]],
            selection: Binding(
                get: { settings.sound(for: state) },
                set: { sound in
                    settings.stateSounds[state.rawValue] = sound
                    if !sound.isEmpty { Chime.play(sound) }
                }))
    }
}

/// The inbox and the control bar: where the bar sits, how answers and asks behave, and the bar's agents.
private struct InboxPage: View {
    @Bindable var settings: Settings
    let store: Store
    let inbox: InboxController
    let workspace: Workspace?
    /// The agent being renamed, in the dialog every rename in Zero uses.
    @State private var renaming: Agent?
    private struct Agent: Identifiable { let id: String }
    @AppStorage("barFoot") private var barFoot = false
    /// "Never", as minutes: ten years.
    static let never = 10 * 365 * 1440

    var body: some View {
        Sections {
            SettingsSection(title: "Control bar") {
                Rows {
                    SettingRow(title: "Show the control bar", detail: "Off, asks reach you in Zero's window, notifications and the Dock.") {
                        Switch(isOn: $settings.showBar)
                    }
                }
            }
            SettingsSection(title: "In the bar") {
                VStack(spacing: 10) {
                    BarPartsCard(settings: settings)
                    Rows {
                        SettingRow(title: "Settings button", detail: "Under the bar, out when the pointer is on it.") {
                            Switch(isOn: $barFoot)
                        }
                    }
                }
                .barOnly(settings.showBar)
            }
            SettingsSection(title: "Placement") {
                Rows {
                    SettingRow(title: "Follow the active screen", detail: "The bar moves to the screen you use.") {
                        Switch(isOn: $settings.followActiveScreen)
                    }
                    SettingRow(title: "Show the bar in Zero's window", detail: "Rather than at the screen's edge.") {
                        SettingChoice(
                            id: "barDock", choices: [[("When it fills the screen", .auto), ("Always", .always), ("Never", .never)]],
                            selection: $settings.barDock)
                    }
                }
                .barOnly(settings.showBar)
            }
            SettingsSection(title: "Answers") {
                Rows {
                    SettingRow(title: "Undo an answer", detail: "Esc takes it back within this time.") {
                        // A time set before these choices stays among them.
                        let seconds = Set([0, 1, 2, 3, 5, settings.takeBackSeconds]).sorted()
                        SettingChoice(
                            id: "takeBack", choices: [seconds.map { (title: $0 == 0 ? "Off" : String(format: "%g s", $0), value: $0) }],
                            selection: $settings.takeBackSeconds)
                    }
                    SettingRow(title: "Unanswered asks expire after", detail: "When the agent didn't set its own expiry.") {
                        let minutes = Set([15, 60, 240, 1440, Self.never, settings.defaultTTLMinutes]).sorted()
                        SettingChoice(
                            id: "askExpiry", choices: [minutes.map { (title: Self.duration($0), value: $0) }],
                            selection: $settings.defaultTTLMinutes)
                    }
                }
            }
            SettingsSection(title: "Agents in the bar") { list.barOnly(settings.showBar) }
        }
    }

    /// 15 min, 1 h, 1 day, Never.
    static func duration(_ minutes: Int) -> String {
        if minutes >= never { return "Never" }
        if minutes % 1440 == 0 { return minutes == 1440 ? "1 day" : "\(minutes / 1440) days" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }

    @ViewBuilder private var list: some View {
        // The bar's own list: workers folded into their leads, as the dots are.
        let agents = inbox.barAgents(settings: settings, workspace: workspace)
        let names = agents.map(\.0)
        if names.isEmpty {
            Text("No agents yet. They appear here when they first ask you something.").font(.system(size: 13)).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    ForEach(names, id: \.self) { name in
                        HStack(spacing: 10) {
                            Circle().fill((agents.first { $0.0 == name }?.1 ?? .closed).color).frame(width: 8, height: 8)
                            Text(store.displayName(of: name)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            IconButton(symbol: "pen", help: "Rename") { renaming = Agent(id: name) }
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
            .zeroDialog(item: $renaming) { agent in
                NameSheet(
                    title: "Rename", name: store.names[agent.id] ?? store.displayName(of: agent.id), action: "Rename",
                    done: { store.rename(agent.id, to: $0) },
                    // A custom name only: clearing it gives the agent its own label back.
                    reset: store.names[agent.id] == nil ? nil : { store.rename(agent.id, to: "") })
            }
        }
    }
}

/// The bar's parts in its order, top to bottom: each switched on or off (for Agents, which of them), dragged to
/// reorder. Rows of one height, so a dragged row steps over its neighbours a row at a time.
private struct BarPartsCard: View {
    @Bindable var settings: Settings
    @State private var drag: (part: BarPart, y: CGFloat)?
    @State private var hovered: BarPart?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let height: CGFloat = 60

    var body: some View {
        let parts = settings.barParts
        VStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.element) { index, part in
                row(part, index: index, among: parts)
            }
        }
        .bleedingCard()
    }

    private func dropIndex(in parts: [BarPart]) -> Int? {
        guard let drag, let from = parts.firstIndex(of: drag.part) else { return nil }
        return max(0, min(parts.count - 1, from + Int((drag.y / height).rounded())))
    }

    /// While dragging, the rows between the start and the drop step aside by one.
    private func shift(_ index: Int, in parts: [BarPart]) -> CGFloat {
        guard let drag, let from = parts.firstIndex(of: drag.part), let to = dropIndex(in: parts) else { return 0 }
        if from < to, index > from, index <= to { return -height }
        if from > to, index >= to, index < from { return height }
        return 0
    }

    private func row(_ part: BarPart, index: Int, among parts: [BarPart]) -> some View {
        let dragging = drag?.part == part
        // Square, but for the card's own corners at its ends.
        let top: CGFloat = index == 0 ? 14 : 0, bottom: CGFloat = index == parts.count - 1 ? 14 : 0
        return SettingRow(title: title(part), detail: detail(part)) { control(part) }
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(
                hovered == part || dragging ? Theme.row : .clear,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
            )
            // Edge to edge, as the fill is; it travels with its row.
            .overlay(alignment: .top) { if index > 0 && !dragging { Hairline() } }
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? part : (hovered == part ? nil : hovered) }
            .pointerStyle(dragging ? .grabActive : .grabIdle)
            .offset(y: dragging ? drag!.y : shift(index, in: parts))
            .animation(dragging || reduceMotion ? nil : .snappy(duration: 0.2), value: dropIndex(in: parts))
            .zIndex(dragging ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag = (part, $0.translation.height) }
                    .onEnded { _ in
                        if let to = dropIndex(in: parts), let from = parts.firstIndex(of: part) {
                            var order = parts
                            order.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
                            settings.barParts = order
                        }
                        drag = nil
                    })
    }

    private func title(_ part: BarPart) -> String {
        switch part {
        case .inbox: "Inbox"
        case .workspaces: "Workspace"
        case .agents: "Agents"
        }
    }

    private func detail(_ part: BarPart) -> String {
        switch part {
        case .inbox: "Open asks, with a dot while one waits."
        case .workspaces: "Switch workspaces. Shown while you have more than one."
        case .agents: "A dot for each task, as the sidebar lists them."
        }
    }

    @ViewBuilder private func control(_ part: BarPart) -> some View {
        switch part {
        case .agents:
            SettingChoice(
                id: "barAgents",
                choices: [
                    [("All tasks", BarAgents.all), ("Only those that need you", .needsYou), ("Pinned tasks only", .pinned)],
                    [("None", .none)],
                ],
                selection: $settings.barAgents)
        default:
            Switch(
                isOn: Binding(
                    get: { !settings.barHidden.contains(part) },
                    set: { on in if on { settings.barHidden.remove(part) } else { settings.barHidden.insert(part) } }))
        }
    }
}

extension View {
    /// A setting only the control bar uses: greyed out while the bar is off, why on hover.
    fileprivate func barOnly(_ shown: Bool) -> some View {
        disabled(!shown).opacity(shown ? 1 : 0.5).tip(shown ? "" : "The control bar is off")
    }
}

/// How agents run and reach Zero: what everyone meets first, then stuck commands, then what few change, folded.
private struct AgentsPage: View {
    @Bindable var settings: Settings
    @AppStorage("settingsAgentsAdvanced") private var advanced = false

    var body: some View {
        Sections {
            SettingsSection(title: "Setup") { PluginRow() }
            SettingsSection(title: "Tasks") {
                Rows {
                    SettingRow(
                        title: "Archive done tasks",
                        detail: "Done means finished end to end. Put away then; back when something they follow changes."
                    ) {
                        ArchiveCompletedPicker()
                    }
                    SettingRow(title: "Terminal app", detail: "Where Open in Terminal takes a task, and a running command's output.") {
                        TerminalAppPicker()
                    }
                    SettingRow(title: "Suggest files after @", detail: "Files from the task's project as you type.") {
                        Switch(isOn: $settings.suggestFiles)
                    }
                }
            }
            SettingsSection(title: "Stuck commands") { StuckCommandsRows() }
            SettingsSection(
                title: "Advanced",
                accessory: AnyView(
                    GhostButton(title: advanced ? "Hide" : "Show", icon: "chevron-down", open: advanced) { advanced.toggle() })
            ) {
                if advanced {
                    Rows {
                        SettingRow(
                            title: "Let agents use their own subagents",
                            detail: "Off: they hand work to Zero workers, which you can see and stop. From each task's next start."
                        ) {
                            SubagentsSwitch()
                        }
                        SettingRow(
                            title: "Summarise conversations at",
                            detail: "Smaller turns, less usage. Claude Code and Codex, from each task's next start."
                        ) {
                            CompactWindowPicker()
                        }
                        BuildCacheRow()
                        SettingRow(
                            title: "Task places command",
                            detail: "A command that tells Zero which folder each ticket's task runs in.",
                            more: ("How it works", URL(string: "https://withzero.dev/docs/settings#agents")!)
                        ) {
                            PlacesCommandField()
                        }
                    }
                }
            }
        }
    }
}

/// What Zero does about a command that runs well past its usual time (learned per project, or what its agent said with
/// `zero expect`) with no output and no CPU: tells the user, stops it (its agent told why, so it carries on), or doesn't
/// look; how it tells, in a dialog. zerod's setting, so it holds while the app is closed.
private struct StuckCommandsRows: View {
    @State private var settings = StuckCommands()
    @State private var link = try? ZerodLink()
    @State private var editing = false

    var body: some View {
        Rows {
            SettingRow(
                title: "When a command looks stuck",
                detail:
                    "Stuck: well past its usual time, with no output and no CPU, or waiting for input no one will type. Stopped, its agent is told why and carries on."
            ) {
                SettingChoice(
                    id: "stuckWhen",
                    choices: [
                        [(title: "Tell me", value: StuckCommands.When.tell), (title: "Stop it", value: .stop)],
                        [(title: "Never check", value: .never)],
                    ],
                    selection: Binding(
                        get: { settings.when },
                        set: {
                            settings.when = $0; save()
                        }))
            }
            if settings.when != .never {
                SettingRow(title: "Thresholds", detail: thresholds) { RowButton(title: "Change…") { editing = true } }
            }
        }
        .task {
            guard let kept = try? await link?.stuckCommands() else { return }
            settings = kept
        }
        .zeroDialog(isPresented: $editing) {
            StuckThresholdsSheet(settings: settings) { changed in
                settings = changed
                save()
            }
        }
    }

    private var thresholds: String {
        let never = settings.never.isEmpty ? "" : " Never stops: \(settings.never.joined(separator: ", "))."
        return
            "Hung after \(Int(settings.hungMinutes)) min; past \(Int(settings.times))× its usual time, at least \(Int(settings.floorMinutes)) min.\(never)"
    }

    private func save() {
        let settings = settings
        Task { try? await link?.setStuckCommands(settings) }
    }
}

/// When a command counts as stuck, and the ones Zero never stops.
private struct StuckThresholdsSheet: View {
    @State var settings: StuckCommands
    let save: (StuckCommands) -> Void
    @State private var never = ""
    @Environment(\.closeDialog) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(text: "Stuck commands")
            row("Hung after", "No output and no CPU for this long.") {
                SettingChoice(
                    id: "stuckHung", choices: [[1.0, 3, 5, 10, 15].map { (title: "\(Int($0)) min", value: $0) }],
                    selection: $settings.hungMinutes)
            }
            row("Past its usual time", "How many times its usual time, and never sooner than the least.") {
                HStack(spacing: 4) {
                    SettingChoice(
                        id: "stuckTimes", choices: [[2.0, 3, 5, 10].map { (title: "\(Int($0))×", value: $0) }], selection: $settings.times)
                    SettingChoice(
                        id: "stuckFloor", choices: [[1.0, 3, 5, 10, 30].map { (title: "at least \(Int($0)) min", value: $0) }],
                        selection: $settings.floorMinutes)
                }
            }
            DialogPart(title: "Never stop commands containing") {
                TextField("", text: $never, prompt: Text("migrate, deploy")).textFieldStyle(.dialog).font(.system(size: 12).monospaced())
                    .firstField()
            }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Save", kind: .primary) {
                    settings.never = never.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    save(settings)
                    dismiss()
                }
            }
        }
        .frame(width: 460)
        .onAppear { never = settings.never.joined(separator: ", ") }
    }

    private func row(_ title: String, _ detail: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

/// When a done task is put away: once you've read it (as a done worker leaves once its lead has its report), after a
/// while, or never. zerod's setting, so it holds while the app is closed.
private struct ArchiveCompletedPicker: View {
    @State private var seconds = 24 * 3600
    @State private var link = try? ZerodLink()
    static let choices: [(String, Int)] = [
        ("Once you've read it", -1), ("After an hour", 3600), ("After a day", 24 * 3600), ("After a week", 7 * 24 * 3600), ("Never", 0),
    ]

    var body: some View {
        SettingChoice(
            id: "archiveCompleted", choices: [Self.choices.map { (title: $0.0, value: $0.1) }],
            selection: Binding(
                get: { seconds },
                set: { chosen in
                    seconds = chosen
                    Task { try? await link?.setArchiveCompleted(chosen) }
                })
        )
        .task { if let kept = try? await link?.archiveCompleted() { seconds = Self.choices.contains { $0.1 == kept } ? kept : 24 * 3600 } }
    }
}

/// Whether agents may use their CLI's own subagents. zerod's setting, read as each agent starts.
private struct SubagentsSwitch: View {
    @State private var on = false
    @State private var link = try? ZerodLink()

    var body: some View {
        Switch(
            isOn: Binding(
                get: { on },
                set: { chosen in
                    on = chosen
                    Task { try? await link?.setSubagents(chosen) }
                })
        )
        .task { if let kept = try? await link?.subagents() { on = kept } }
    }
}

/// Whether agents' builds share a compile cache, with what this Mac has for it: Zero passes the tools, never installs
/// them. zerod's setting, read as each agent starts.
private struct BuildCacheRow: View {
    @State private var on = false
    @State private var tools: [(tool: String, use: String, found: Bool)] = []
    @State private var link = try? ZerodLink()

    var body: some View {
        SettingRow(title: "Shared build cache", detail: "Agents' copies of a project reuse each other's compiled dependencies.") {
            HStack(spacing: 8) {
                // What this Mac lacks for it: Zero passes the tools, never installs them.
                ForEach(tools.filter { !$0.found }, id: \.tool) { missing in
                    StatePill(text: "needs \(missing.tool)", color: .orange)
                        .tip("\(missing.use) needs it: brew install \(missing.tool)")
                }
                Switch(
                    isOn: Binding(
                        get: { on },
                        set: { chosen in
                            on = chosen
                            Task { try? await link?.setBuildCache(chosen) }
                        }))
            }
        }
        .task {
            guard let kept = try? await link?.buildCache() else { return }
            on = kept.on
            tools = kept.tools
        }
    }
}

/// The context size agents compact at: off (the CLIs' own), a common size, or one of the user's, in tokens ("350k"
/// or "350000"). zerod's setting, read as each agent starts.
private struct CompactWindowPicker: View {
    /// 0 off, -1 a size of the user's.
    @State private var choice = 0
    @State private var text = ""
    @State private var link = try? ZerodLink()
    @FocusState private var focused: Bool
    static let sizes = [200_000, 400_000, 600_000, 800_000]

    var body: some View {
        HStack(spacing: 6) {
            if choice == -1 {
                TextField("", text: $text, prompt: Text("350k"))
                    .textFieldStyle(.dialog).font(.system(size: 12)).frame(width: 80)
                    .focused($focused)
                    .onSubmit(save)
                    .onChange(of: focused) { if !focused { save() } }
            }
            SettingChoice(
                id: "compactWindow",
                choices: [
                    [(title: "CLI's default", value: 0)], Self.sizes.map { (title: "\($0 / 1000)k", value: $0) },
                    [(title: "Other", value: -1)],
                ],
                selection: Binding(
                    get: { choice },
                    set: { chosen in
                        choice = chosen
                        if chosen == -1 { focused = true } else { Task { try? await link?.setCompactWindow(chosen) } }
                    })
            )
        }
        .task {
            guard let kept = try? await link?.compactWindow() else { return }
            choice = Self.sizes.contains(kept) ? kept : -1
            if choice == -1 { text = "\(kept / 1000)k" }
        }
    }

    private func save() {
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let number = Int(typed.hasSuffix("k") ? String(typed.dropLast()) : typed), number > 0 else { return }
        let tokens = typed.hasSuffix("k") ? number * 1000 : number
        Task { try? await link?.setCompactWindow(tokens) }
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
            .textFieldStyle(.dialog).font(.system(size: 12).monospaced()).frame(width: 260)
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
    @State private var dialogs = false
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
                    SettingRow(
                        title: "Firefox Developer Edition",
                        detail: firefoxError
                            ?? (firefox
                                ? "Under Zero's remote control, with your sign-ins"
                                : "Opened by Zero under remote control when an agent asks for it")
                    ) {
                        if firefox {
                            Text("Connected").font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if opening {
                            Spinner().frame(width: 12, height: 12)
                        } else {
                            RowButton(title: "Open") { openFirefox() }
                        }
                    }
                }
            }
            SettingsSection(title: "Safari") {
                Rows {
                    SettingRow(
                        title: "Let agents use Safari",
                        detail: safari.map { $0.isEmpty ? "Working · comparisons get a signed-out Safari window" : $0 }
                            ?? "For comparing pages: a signed-out Safari window with real clicks"
                    ) {
                        if trying { Spinner().frame(width: 12, height: 12) } else { RowButton(title: "Try it") { trySafari() } }
                    }
                }
            }
            SettingsSection(title: "Dialogs") {
                Rows {
                    SettingRow(
                        title: "Replace pages' dialogs in agents' tabs (experimental)",
                        detail:
                            "A page's alert, confirm or prompt answers at once and is told to the agent, so its window never comes forward"
                    ) {
                        Switch(
                            isOn: Binding(
                                get: { dialogs },
                                set: { on in
                                    dialogs = on
                                    Task { await workspace.replaceDialogs(on) }
                                }))
                    }
                }
            }
            SettingsSection(title: "Blocked sites") { sites }
        }
        .task {
            blocked = await workspace.blockedSites()
            dialogs = await workspace.replacesDialogs()
            while !Task.isCancelled {
                connected = await workspace.browsers()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rows {
                SettingRow(
                    title: "Zero for Chrome",
                    detail: chromes.map {
                        $0.isEmpty ? "Not connected · set it up so agents can use Chrome" : "Connected · each task works in tabs of its own"
                    } ?? "Lets agents use Chrome, each task in tabs of its own"
                ) {
                    RowButton(title: chromes?.isEmpty == false ? "Set up again" : "Set up", action: setUp)
                }
            }
            if let folder {
                Text(
                    "In Chrome's Extensions page (open now): turn on Developer mode, choose Load unpacked, and pick the folder Finder shows (\((folder as NSString).abbreviatingWithTildeInPath)). Zero for Chrome connects by itself."
                )
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
                    Hairline().padding(.horizontal, 18)
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
                .padding(.horizontal, 18).frame(height: 44)
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
            if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
                let page = URL(string: "chrome://extensions")
            {
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
            Text(site).font(.system(size: 13, weight: .medium))
            Spacer()
            Button(action: remove) { NucleoIcon("trash", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28) }
                .buttonStyle(Hovering(radius: 7)).tip("Unblock it").opacity(hovered ? 1 : 0)
        }
        .padding(.leading, 18).padding(.trailing, 10).frame(height: 44)
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
                SettingRow(
                    picture: Image(nsImage: appTile), title: "Zero plugin",
                    detail: "Lets your agents reach your inbox and use your scratchpads."
                ) {
                    if let plugin {
                        Switch(
                            isOn: Binding(
                                get: { plugin },
                                set: { on in
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
                        Spinner().frame(width: 12, height: 12)
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

/// The folders Zero's own agents start in. Each runs in a terminal of its own, so it keeps running whether or not
/// Zero is open.
/// Projects: where agents start. Each folder a row with a name of the user's choosing (its own until then); what's done to one, in its menu.
private struct FoldersPage: View {
    let inbox: InboxController
    @State private var folders = Projects.folders
    @State private var renaming: Folder?
    /// Bumped when a name changes: the rows read names from UserDefaults.
    @State private var named = 0

    private struct Folder: Identifiable { let path: String; var id: String { path } }

    var body: some View {
        Sections {
            SettingsSection(title: "Projects", accessory: AnyView(GhostButton(title: "Add folder…", icon: "plus", action: addFolders))) {
                card(empty: folders.isEmpty) {
                    ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                        if index > 0 { Hairline() } // edge to edge, as the row's hover fill is
                        HStack(spacing: 10) {
                            NucleoIcon("folder", size: 15).foregroundStyle(.secondary).frame(width: 18)
                            Text(Projects.name(of: folder)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 18).frame(height: 44)
                        .tip((folder as NSString).abbreviatingWithTildeInPath)
                        .rowMenu("folder-\(folder)", first: index == 0, last: index == folders.count - 1) {
                            ComposerRows.menu([
                                [
                                    ("rename", "Rename…", "pen", false, { renaming = Folder(path: folder) }),
                                    (
                                        "finder", "Show in Finder", "folder", false,
                                        { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                                    ),
                                ],
                                [("remove", "Remove", "trash", false, { save(folders.filter { $0 != folder }) })],
                            ])
                        }
                    }
                }
                .id(named)
                Text("The folders New task offers.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .zeroDialog(item: $renaming) { folder in
            NameSheet(title: "Rename \(Projects.name(of: folder.path))", name: Projects.name(of: folder.path), action: "Rename") { name in
                Projects.setName(name, for: folder.path)
                named += 1
                inbox.loadSpawnChoices(force: true)
            }
        }
    }

    private func card<Content: View>(empty: Bool, @ViewBuilder rows: () -> Content) -> some View {
        VStack(spacing: 0) {
            if empty {
                Text("None yet").font(.system(size: 13)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).frame(height: 44)
            }
            rows()
        }
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
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        ]
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
            stride(from: 0, through: size.width, by: 12).forEach { x in
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: 12).forEach { y in
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
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
            context.fill(
                Path(ellipseIn: CGRect(x: size.width - 150, y: -70, width: 180, height: 140)),
                with: .radialGradient(
                    Gradient(colors: [.white, .clear]), center: CGPoint(x: size.width - 60, y: 0), startRadius: 0, endRadius: 90))
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
                    .mask(
                        LinearGradient(
                            stops: band(layer.from, layer.to, last: index == Self.layers.count - 1), startPoint: .top, endPoint: .bottom))
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
        return [Gradient.Stop(color: .black, location: 0)]
            + (0...16).map { step in
                let t = Double(step) / 16
                let ease = t * t * t * (t * (t * 6 - 15) + 10)
                return Gradient.Stop(color: .black.opacity(1 - ease), location: start + (1 - start) * t)
            }
    }

    /// Opaque over its band, ramping in at the top of it; a layer's band overlaps the next so there are no seams.
    private func band(_ from: CGFloat, _ to: CGFloat, last: Bool) -> [Gradient.Stop] {
        let ramp = (to - from) / 3
        return [
            .init(color: .clear, location: max(0, from - 0.001)), .init(color: from == 0 ? .black : .clear, location: from),
            .init(color: .black, location: min(1, from + ramp)), .init(color: .black, location: to),
            .init(color: last ? .black : .clear, location: min(1, to + ramp)),
        ]
    }
}
