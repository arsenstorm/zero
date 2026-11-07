import AppKit
import SwiftUI
import ZeroCore

/// The integrations, as the rail and the pages name and draw them. Slack has no views: it connects so that channels
/// and threads named in messages open in Slack.
enum Integration: String, CaseIterable, Identifiable {
    case github, linear, slack
    var id: String { rawValue }
    static let shownKey = "integrationsShown"

    /// Goes to Integrations, on `name`'s views.
    static func edit(_ name: String, place: inout Navigation.Place) {
        UserDefaults.standard.set(name, forKey: shownKey)
        place = .integrations
    }
    var title: String {
        switch self {
        case .github: "GitHub"
        case .linear: "Linear"
        case .slack: "Slack"
        }
    }

    @ViewBuilder func icon(size: CGFloat) -> some View {
        switch self {
        case .github: NucleoIcon("github", fill: "glyph", size: size)
        case .slack: NucleoIcon("slack", fill: "glyph", size: size)
        case .linear:
            if let mark = Self.linearMark {
                Image(nsImage: mark).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
            }
        }
    }

    /// Linear isn't in Nucleo, and the app bundles its tile (a light mark on a dark square): the mark alone, its
    /// brightness as its opacity and cropped to it, so it draws as a template like the rest.
    static let linearMark: NSImage? = {
        guard let tile = Bundle.main.image(forResource: "linear"), let source = tile.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let (width, height) = (source.width, source.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var (minX, minY, maxX, maxY) = (width, height, 0, 0)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let light = (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
                let alpha = UInt8(max(0, min(1, (light - 0.28) / 0.22)) * Double(pixels[i + 3]))
                (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (alpha, alpha, alpha, alpha)
                if alpha > 40 { (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y)) }
            }
        }
        guard maxX > minX, let mark = context.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
        let image = NSImage(cgImage: mark, size: NSSize(width: mark.width, height: mark.height))
        image.isTemplate = true
        return image
    }()

    /// The account it's connected as: gh's login, the Linear workspace, or the Slack workspace.
    @MainActor func account(in state: IntegrationState?) -> String? {
        switch self {
        case .github: state?.github
        case .linear: state?.linear
        case .slack: state?.slack.flatMap { $0.isEmpty ? nil : $0.map(\.team.name).joined(separator: ", ") }
        }
    }

    func enabled(in state: IntegrationState?) -> Bool {
        guard let state else { return false }
        return switch self {
        case .github: state.settings.github.enabled
        case .linear: state.settings.linear.enabled
        case .slack: false
        }
    }

    /// Its views as (id, name), in order.
    /// What agents can follow through it (the Following section).
    var followingDetail: String {
        switch self {
        case .github: "Agents follow pull requests with zero follow <url>: reviews, comments, CI, pushes and merges reach them between turns."
        case .linear: "Agents follow issues, or one comment thread, with zero follow <url>: status changes and comments reach them between turns."
        case .slack: "Agents follow threads and channels with zero follow <url>: replies reach them between turns."
        }
    }

    func views(in state: IntegrationState?) -> [(id: String, name: String)] {
        guard let state else { return [] }
        return switch self {
        case .github: state.settings.github.views.map { ($0.id, $0.name) }
        case .linear: state.settings.linear.views.map { ($0.id, $0.name) }
        case .slack: []
        }
    }
}

// Integrations: each one's connection, whether it has a place in the rail, and its views.

struct IntegrationsPane: View {
    let workspace: Workspace
    /// The integration on show; Edit views from an integration's page or rail item sets it.
    @AppStorage(Integration.shownKey) private var shown = Integration.github
    @AppStorage(LinearLinks.key) private var linearInApp = true

    var body: some View {
        HStack(spacing: 0) {
            SidebarColumn(title: "Integrations") {
                ForEach(Integration.allCases) { integration in
                    SidebarItem(title: integration.title, selected: shown == integration, action: { shown = integration }) { integration.icon(size: 15) }
                }
            }
            Rectangle().fill(Theme.stroke).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(text: shown.title).padding(.bottom, 24)
                    connection.padding(.bottom, 28)
                    if shown.account(in: workspace.integrations) != nil {
                        Text("Following").font(.system(size: 15, weight: .semibold)).padding(.bottom, 4)
                        Text(shown.followingDetail).font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 12)
                        FollowRows(workspace: workspace, source: shown).padding(.bottom, 28)
                    }
                    if shown != .slack {
                        Text("Views").font(.system(size: 15, weight: .semibold)).padding(.bottom, 4)
                        Text(shown == .github ? "Each view is a GitHub search: add org:YourOrg to narrow it to one organisation's repositories."
                                              : "Each view picks whose issues, which teams and which states.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 12)
                        views
                    }
                }
                .centredColumn(680)
                .padding(.top, 44).padding(.bottom, 28)
            }
            .thinScrollbar()
            .background(Theme.card)
        }
        .task { await workspace.loadIntegrations() }
        .task(id: workspace.integrations?.linear) { if workspace.integrations?.linear != nil { await workspace.loadLinearTeams() } }
    }

    private var connectedDetail: String {
        switch shown {
        case .github: "Through the GitHub CLI, signed in as it already is."
        case .linear: "Read-only, kept on this Mac."
        case .slack: "Read-only, kept on this Mac. #channel and message links open in Slack; agents can follow threads and channels."
        }
    }

    @ViewBuilder private var connection: some View {
        let enabled = Binding(get: { shown.enabled(in: workspace.integrations) }, set: { on in Task { await workspace.setIntegration(shown.rawValue, enabled: on) } })
        if let account = shown.account(in: workspace.integrations) {
            Rows {
                OnboardingRow(icon: "", picture: nil, title: shown == .github ? "Connected as \(account)" : "Connected to \(account)",
                              detail: connectedDetail) {
                    if shown == .linear { Button("Disconnect") { Task { await workspace.disconnectLinear() } } }
                    if shown == .slack, let team = workspace.integrations?.slack?.first?.team, workspace.integrations?.slack?.count == 1 {
                        Button("Disconnect") { Task { await workspace.disconnectSlack(team: team.id) } }
                    }
                }
                .overlay(alignment: .leading) { shown.icon(size: 17).foregroundStyle(.secondary).frame(width: 22) }
                if shown != .slack {
                    OnboardingRow(icon: "sidebar-right", title: "Show in the sidebar", detail: "A place of its own in the rail, with these views.") { Switch(isOn: enabled) }
                }
                if shown == .linear, LinearLinks.installed {
                    OnboardingRow(icon: "link", title: "Open issues in the Linear app", detail: "Rather than the browser, here and in messages.") { Switch(isOn: $linearInApp) }
                }
            }
        } else {
            ConnectCard(integration: shown, workspace: workspace)
                .settingsCard()
        }
    }

    @ViewBuilder private var views: some View {
        let integration = shown
        let rows: [(id: String, name: String, summary: String, mono: Bool)] = switch integration {
        case .github: (workspace.integrations?.settings.github.views ?? []).map { ($0.id, $0.name, $0.query, true) }
        case .linear: (workspace.integrations?.settings.linear.views ?? []).map { ($0.id, $0.name, Self.summary($0, teams: workspace.linearTeams), false) }
        case .slack: []
        }
        let ids = rows.map(\.id)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 16) }
                ViewRow(name: row.name, summary: row.summary, mono: row.mono,
                        moveUp: index > 0 ? { move(ids, from: index, to: index - 1) } : nil,
                        moveDown: index < ids.count - 1 ? { move(ids, from: index, to: index + 1) } : nil,
                        delete: { Task { await workspace.deleteView(integration.rawValue, view: row.id) } }) {
                    form(for: row.id)
                }
            }
            if !rows.isEmpty { Divider() }
            AddViewRow { form(for: nil) }
        }
        .settingsCard()
    }

    /// The form for a view (nil: a new one), saving to zerod.
    @ViewBuilder private func form(for id: String?) -> some View {
        switch shown {
        case .github:
            let view = workspace.integrations?.settings.github.views.first { $0.id == id } ?? GitHubView(name: "", query: "is:pr is:open author:@me archived:false")
            GitHubViewForm(view: view) { edited in Task { await workspace.saveView("github", view: edited) } }
        case .linear:
            let view = workspace.integrations?.settings.linear.views.first { $0.id == id } ?? LinearView(name: "")
            LinearViewForm(view: view, workspace: workspace) { edited in Task { await workspace.saveView("linear", view: edited) } }
        case .slack: EmptyView()
        }
    }

    private func move(_ ids: [String], from: Int, to: Int) {
        var order = ids
        order.swapAt(from, to)
        Task { await workspace.orderViews(shown.rawValue, ids: order) }
    }

    static let stateNames = ["triage": "Triage", "backlog": "Backlog", "unstarted": "To do", "started": "In progress", "completed": "Done", "canceled": "Canceled"]

    /// "Assigned to me · U, T · PM review, Self QA, Working on +3": the states it shows by their own names, once Linear's
    /// teams are known.
    static func summary(_ view: LinearView, teams known: [LinearTeam]?) -> String {
        let who = ["me": "Assigned to me", "anyone": "Anyone's", "nobody": "Unassigned"][view.assignee] ?? view.assignee
        let teams = view.teams.isEmpty ? "Every team" : view.teams.joined(separator: ", ")
        let names = !view.stateNames.isEmpty ? view.stateNames
            : known.map { LinearViewForm.offered($0, teams: view.teams).filter { view.states.contains($0.type) }.map(\.name) }
            ?? view.states.compactMap { stateNames[$0] }
        let states = names.isEmpty ? "Every state" : (names.prefix(3) + (names.count > 3 ? ["+\(names.count - 3)"] : [])).joined(separator: ", ")
        return [who, teams, states].joined(separator: " · ")
    }
}

/// One view in the list: its name and what it shows; on hover, edit and a menu with moving and deleting.
private struct ViewRow<Form: View>: View {
    let name: String
    let summary: String
    let mono: Bool
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?
    let delete: () -> Void
    @ViewBuilder let form: () -> Form
    @State private var hovered = false
    @State private var editing = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(summary).font(mono ? .system(size: 11.5).monospaced() : .system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { editing = true } label: { NucleoIcon("pen", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28) }
                    .buttonStyle(Hovering(radius: 7)).tip("Edit")
                    .popover(isPresented: $editing, arrowEdge: .trailing) { form().environment(\.dismissForm, { editing = false }) }
                Menu {
                    if let moveUp { Button("Move up", action: moveUp) }
                    if let moveDown { Button("Move down", action: moveDown) }
                    Divider()
                    Button("Delete", role: .destructive, action: delete)
                } label: { NucleoIcon("dots", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .opacity(hovered || editing ? 1 : 0)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { editing = true }
        .contextMenu {
            Button("Edit") { editing = true }
            if let moveUp { Button("Move up", action: moveUp) }
            if let moveDown { Button("Move down", action: moveDown) }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

private struct AddViewRow<Form: View>: View {
    @ViewBuilder let form: () -> Form
    @State private var adding = false

    var body: some View {
        Button { adding = true } label: {
            NucleoLabel("Add a view", icon: "plus", size: 13).font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
        }
        .buttonStyle(Hovering(radius: 0))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        .popover(isPresented: $adding, arrowEdge: .trailing) { form().environment(\.dismissForm, { adding = false }) }
    }
}

private struct DismissForm: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var dismissForm: () -> Void { get { self[DismissForm.self] } set { self[DismissForm.self] = newValue } }
}

/// A form's frame: its fields with their labels, then Cancel and Save.
private struct FormSheet<Fields: View>: View {
    let title: String
    let canSave: Bool
    var width: CGFloat = 420
    let save: () -> Void
    @ViewBuilder let fields: () -> Fields
    @Environment(\.dismissForm) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            fields()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(18).frame(width: width)
    }
}

private struct Field<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium))
            content()
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

private struct GitHubViewForm: View {
    let view: GitHubView
    let save: (GitHubView) -> Void
    @State private var name = ""
    @State private var query = ""
    private static let snippets = ["author:@me", "review-requested:@me", "org:", "repo:", "is:draft", "-is:draft", "label:"]

    var body: some View {
        FormSheet(title: view.id.isEmpty ? "New view" : "Edit view", canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && !query.isEmpty,
                  save: { save(GitHubView(id: view.id, name: name, query: query)) }) {
            Field(label: "Name") { TextField("", text: $name, prompt: Text("My team's pull requests")) }
            Field(label: "Search", hint: "GitHub's search syntax, as on github.com.") {
                TextField("", text: $query).font(.system(size: 12).monospaced())
                FlowChips(items: Self.snippets) { snippet in query = (query.trimmingCharacters(in: .whitespaces) + " " + snippet).trimmingCharacters(in: .whitespaces) }
            }
        }
        .onAppear { name = view.name; query = view.query }
    }
}

private struct LinearViewForm: View {
    let view: LinearView
    let workspace: Workspace
    let save: (LinearView) -> Void
    @State private var name = ""
    @State private var assignee = "me"
    @State private var keys: [String] = []
    @State private var states: [String] = []
    @State private var stateNames: [String] = []
    @State private var start: TaskStart?
    private static let order = ["triage", "backlog", "unstarted", "started", "completed", "canceled"]
    /// Linear's state types as it groups them, in its order; a duplicate counts as canceled.
    private static let groups = [("started", "In progress"), ("unstarted", "To do"), ("backlog", "Backlog"), ("triage", "Triage"), ("completed", "Done"), ("canceled", "Canceled")]
    private static func group(_ type: String) -> String { type == "duplicate" ? "canceled" : type }

    /// The teams' states (every team's when none is picked), each name once, in Linear's order of their types.
    static func offered(_ known: [LinearTeam], teams keys: [String]) -> [LinearTeam.State] {
        var seen = Set<String>()
        let types = groups.map(\.0)
        let states = known.filter { keys.isEmpty || keys.contains($0.key) }.flatMap(\.states).filter { seen.insert($0.name).inserted }
        return states.enumerated().sorted { a, b in
            let (x, y) = (types.firstIndex(of: group(a.element.type)) ?? types.count, types.firstIndex(of: group(b.element.type)) ?? types.count)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        FormSheet(title: view.id.isEmpty ? "New view" : "Edit view", canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty, width: 540, save: {
            save(LinearView(id: view.id, name: name, assignee: assignee, teams: keys, states: states, stateNames: stateNames, start: start))
        }) {
            Field(label: "Name") { TextField("", text: $name, prompt: Text("My issues")) }
            Field(label: "Assigned to") {
                Picker("", selection: $assignee) { Text("Me").tag("me"); Text("Anyone").tag("anyone"); Text("No one").tag("nobody") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let known = workspace.linearTeams {
                Field(label: "Teams") {
                    WrappingStack(spacing: 6) {
                        Pill(selected: keys.isEmpty, action: { keys = [] }) { Text("Every team") }
                        ForEach(known) { team in
                            Pill(selected: keys.contains(team.key), action: {
                                keys = known.map(\.key).filter { $0 == team.key ? !keys.contains($0) : keys.contains($0) }
                            }) {
                                HStack(spacing: 6) {
                                    Text(team.key).font(.system(size: 10.5, weight: .semibold).monospaced()).opacity(0.55)
                                    Text(team.name)
                                }
                            }
                        }
                    }
                }
                states(Self.offered(known, teams: keys))
            } else {
                Field(label: "Teams", hint: "Team keys, separated by commas. Empty for every team.") {
                    TextField("", text: Binding(get: { keys.joined(separator: ", ") }, set: { text in
                        keys = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
                    }), prompt: Text("U, T"))
                }
                Field(label: "States", hint: "None picked shows every state.") {
                    WrappingStack(spacing: 6) {
                        ForEach(Self.order, id: \.self) { state in
                            Pill(selected: states.contains(state), action: { states = Self.order.filter { $0 == state ? !states.contains(state) : states.contains($0) } }) {
                                Text(IntegrationsPane.stateNames[state] ?? state)
                            }
                        }
                    }
                }
            }
            StartFields(start: $start, noun: "issue")
        }
        .onAppear { name = view.name; assignee = view.assignee; keys = view.teams; states = view.states; stateNames = view.stateNames; start = view.start }
        .task { await workspace.loadLinearTeams() }
    }

    /// The teams' own states under their kinds, as Linear groups them, each with its icon; a kind's name picks all of it.
    private func states(_ offered: [LinearTeam.State]) -> some View {
        // The states the view shows: those named, else those of its types.
        let picked = stateNames.isEmpty ? offered.filter { states.contains($0.type) }.map(\.name) : stateNames
        let started = offered.filter { $0.type == "started" }.map(\.name)
        let pick = { (names: [String]) in
            stateNames = offered.map(\.name).filter { names.contains($0) }
            if stateNames.isEmpty { states = [] }
        }
        return Field(label: "States") {
            VStack(alignment: .leading, spacing: 10) {
                Pill(selected: picked.isEmpty, action: { pick([]) }) { Text("Every state") }
                ForEach(Self.groups.filter { kind in offered.contains { Self.group($0.type) == kind.0 } }, id: \.0) { kind, title in
                    let members = offered.filter { Self.group($0.type) == kind }.map(\.name)
                    let all = members.allSatisfy(picked.contains)
                    HStack(alignment: .top, spacing: 12) {
                        Button { pick(all ? picked.filter { !members.contains($0) } : picked + members) } label: {
                            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 76, height: 26, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).tip(all ? "Leave out every \(title.lowercased()) state" : "Pick every \(title.lowercased()) state")
                        WrappingStack(spacing: 6) {
                            ForEach(offered.filter { Self.group($0.type) == kind }, id: \.name) { state in
                                let on = picked.contains(state.name)
                                Pill(selected: on, action: { pick(on ? picked.filter { $0 != state.name } : picked + [state.name]) }) {
                                    HStack(spacing: 6) {
                                        StateIcon(kind: state.type, color: Color(hex: state.color),
                                                  fill: started.firstIndex(of: state.name).map { Double(started.count - $0) / Double(started.count + 1) } ?? 0.5)
                                        Text(state.name)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Whether a view's items start tasks, and how: the folder, the agent, and the prompt template.
private struct StartFields: View {
    @Binding var start: TaskStart?
    /// "issue" or "pull request".
    let noun: String
    private static let efforts = ["", "low", "medium", "high", "xhigh", "max"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { start != nil }, set: { on in
                start = on ? TaskStart(cwd: "", prompt: "Work on {key}: {title} ({url}).", provider: "claude") : nil
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a task from each \(noun)").font(.system(size: 12, weight: .medium))
                    Text("One task per \(noun), with a scratchpad of its own for its state.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            if let current = start {
                let field = { (key: WritableKeyPath<TaskStart, String>) in Binding(get: { current[keyPath: key] }, set: { start?[keyPath: key] = $0 }) }
                let optional = { (key: WritableKeyPath<TaskStart, String?>) in Binding(get: { current[keyPath: key] ?? "" }, set: { start?[keyPath: key] = $0.isEmpty ? nil : $0 }) }
                Field(label: "Folder") {
                    HStack {
                        TextField("", text: field(\.cwd), prompt: Text("~/Documents/projects/app"))
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url { start?.cwd = url.path }
                        }
                    }
                }
                Field(label: "Agent") {
                    HStack(spacing: 8) {
                        Picker("", selection: optional(\.provider)) { Text("Claude").tag("claude"); Text("Codex").tag("codex"); Text("OpenCode").tag("opencode") }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        TextField("", text: optional(\.model), prompt: Text("Model (its default)")).frame(width: 150)
                        Picker("", selection: optional(\.effort)) { ForEach(Self.efforts, id: \.self) { Text($0.isEmpty ? "Effort" : $0.capitalized).tag($0) } }
                            .labelsHidden().fixedSize()
                    }
                }
                Field(label: "Prompt", hint: "{key}, {title} and {url} are filled in. The task is told where its state pad is, unless you place {state} yourself.") {
                    TextEditor(text: field(\.prompt))
                        .font(.system(size: 12).monospaced()).frame(height: 64).scrollContentBackground(.hidden)
                        .padding(4).background(Theme.composer, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                }
            }
        }
        .padding(.top, 4)
    }
}

/// A toggle as a pill: outlined while off, solid (black, white in dark mode) while on.
private struct Pill<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label().font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(selected ? AnyShapeStyle(Theme.onKnob) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10).frame(height: 26)
                .background(selected ? AnyShapeStyle(Theme.knob) : AnyShapeStyle(hovered ? Theme.hover : .clear), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : Theme.stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// Lays its children out in rows, starting a new row when the next doesn't fit; `trailing` ends each row at the right.
struct WrappingStack: Layout {
    var spacing: CGFloat
    var trailing = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            let shift = trailing ? bounds.width - row.width : 0
            for (index, x) in row.items { subviews[index].place(at: CGPoint(x: bounds.minX + shift + x, y: bounds.minY + row.y), proposal: .unspecified) }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, items: [(Int, CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append((items, y, x - spacing, height))
                y += height + spacing; x = 0; height = 0; items = []
            }
            items.append((index, x))
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, height)) }
        return rows
    }
}

extension Color {
    /// "#f2c94c", as Linear gives a state's colour.
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        self.init(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

/// Snippets to add to a search, in rows that wrap.
private struct FlowChips: View {
    let items: [String]
    let add: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { add(item) } label: { Text(item).font(.system(size: 11).monospaced()).padding(.horizontal, 7).frame(height: 22) }
                    .buttonStyle(Hovering(radius: 6, fill: Theme.chip, hover: Theme.chip))
                    .background(Theme.composer, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// An integration's own place: its views down the side, the chosen one's items as a table.

struct IntegrationPage: View {
    let workspace: Workspace
    let integration: Integration
    let edit: () -> Void
    let openTask: (String) -> Void
    @State private var shown: String?

    var body: some View {
        let views = integration.views(in: workspace.integrations)
        let view = views.first { $0.id == shown } ?? views.first
        HStack(spacing: 0) {
            SidebarColumn(title: integration.title, footer: AnyView(SidebarItem("Edit views", icon: "sliders", action: edit))) {
                ForEach(views, id: \.id) { item in
                    SidebarItem(item.name, selected: item.id == view?.id) { shown = item.id }
                }
            }
            Rectangle().fill(Theme.stroke).frame(width: 1)
            Group {
                if integration.account(in: workspace.integrations) == nil, workspace.integrations != nil { ConnectCard(integration: integration, workspace: workspace) }
                else if let view { ItemsTable(workspace: workspace, integration: integration, view: view.id, name: view.name, actions: actions(view.id)).id(view.id) }
                else { ContentUnavailableView { NucleoLabel("No views", icon: "sliders", size: 20) } description: { Text("Add one in Integrations.") } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
        }
        .task { await workspace.loadIntegrations() }
    }

    /// What a view's rows can do with their tasks: open one, or start one when the view says how.
    private func actions(_ view: String) -> TaskActions {
        let starts = switch integration {
        case .linear: workspace.integrations?.settings.linear.views.first { $0.id == view }?.start != nil
        case .github: workspace.integrations?.settings.github.views.first { $0.id == view }?.start != nil
        case .slack: false
        }
        return TaskActions(
            state: { session in workspace.board.first { $0.session == session }?.state },
            open: openTask,
            start: starts ? { item in Task { if let started = await workspace.startTask(integration.rawValue, view: view, item: item) { openTask(started.session) } } } : nil)
    }
}

/// A row's task: its state, opening it, and starting one (nil when the view doesn't start tasks).
struct TaskActions {
    let state: (String) -> BoardRow.State?
    let open: (String) -> Void
    let start: ((IntegrationItem) -> Void)?
}

/// The task an item has, as its state (click to open it), or a Start button under the pointer when it has none.
private struct TaskControl: View {
    let row: IntegrationItem
    let actions: TaskActions
    let hovered: Bool

    var body: some View {
        if let task = row.task {
            Button { actions.open(task) } label: {
                Group {
                    if let state = actions.state(task) { StateLabel(state: state) } else { Text("Task") }
                }
                .font(.system(size: 12)).padding(.horizontal, 9).frame(height: 24)
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).tip("Open this \(row.key.hasPrefix("#") ? "pull request" : "issue")'s task")
        } else if let start = actions.start {
            Button { start(row) } label: {
                NucleoLabel("Start", icon: "paper-plane", size: 12).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.onKnob).padding(.horizontal, 10).frame(height: 24)
                    .background(Theme.knob, in: Capsule())
            }
            .buttonStyle(.plain).opacity(hovered ? 1 : 0).tip("Start a task for \(row.key)")
        }
    }
}

private struct ItemsTable: View {
    let workspace: Workspace
    let integration: Integration
    let view: String
    let name: String
    let actions: TaskActions

    var body: some View {
        let key = "\(integration.rawValue)/\(view)"
        let rows = workspace.items[key]
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(text: name)
                    Spacer()
                    if workspace.refreshing.contains(key) {
                        ProgressView().controlSize(.small).frame(width: 28, height: 28).tip("Fetching again")
                    } else {
                        Button { Task { await workspace.refreshView(integration.rawValue, view: view) } } label: {
                            NucleoIcon("arrow-rotate-clockwise", fill: "glyph", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28)
                        }
                        .buttonStyle(Hovering(radius: 7)).tip("Refresh")
                    }
                }
                if let error = workspace.itemErrors[key] {
                    NucleoLabel(error, icon: "triangle-warning", size: 14).font(.callout).foregroundStyle(.red)
                }
                if integration == .linear, let rows, !rows.isEmpty {
                    LinearList(rows: rows, view: view, actions: actions)
                } else if rows == nil && workspace.itemErrors[key] == nil || rows?.isEmpty == false {
                    ArticlePanel {
                        line(head: true, key: Text("#"), title: Text(integration == .github ? "Pull request" : "Issue"), place: Text(integration == .github ? "Repository" : "Team"),
                             state: Text("State"), extra: Text(integration == .github ? "Checks" : "Priority"), person: Text(integration == .github ? "Author" : "Assignee"))
                            .padding(.vertical, -3)
                    } content: {
                        VStack(spacing: 0) {
                            if rows == nil { skeleton }
                            ForEach(Array((rows ?? []).enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1) }
                                Button { if let url = LinearLinks.url(row.url) { NSWorkspace.shared.open(url) } } label: {
                                    line(head: false, key: Text(row.key).foregroundStyle(.secondary), title: Text(row.title), place: Text(row.place).foregroundStyle(.secondary),
                                         state: Text(row.state), extra: extra(row), person: Text(row.person ?? "").foregroundStyle(.secondary))
                                }
                                .buttonStyle(Hovering(radius: 0, hover: Theme.rowHover))
                            }
                        }
                    }
                } else if rows != nil {
                    Text("Nothing in this view.").foregroundStyle(.secondary)
                }
            }
            .centredColumn(1040)
            .padding(.vertical, 36)
        }
        .thinScrollbar()
        // ponytail: looks every minute while shown; events from zerod when it watches these itself.
        .task {
            while !Task.isCancelled {
                await workspace.refreshView(integration.rawValue, view: view)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func line(head: Bool, key: some View, title: some View, place: some View, state: some View, extra: some View, person: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            key.frame(width: 80, alignment: .leading)
            title.frame(maxWidth: .infinity, alignment: .leading)
            place.frame(width: 150, alignment: .leading)
            state.frame(width: 100, alignment: .leading)
            extra.frame(width: 110, alignment: .leading)
            person.frame(width: 110, alignment: .leading)
        }
        .font(head ? .system(size: 12, weight: .medium) : .system(size: 13))
        .foregroundStyle(head ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.85)))
        .lineLimit(1)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Rows standing in for the items while they load, laid out as the real ones are so nothing moves when they come.
    @ViewBuilder private var skeleton: some View {
        ForEach([0.62, 0.48, 0.71, 0.55, 0.66, 0.43].indices, id: \.self) { index in
            if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1) }
            line(head: false, key: Bar(width: 48), title: Bar(fraction: [0.62, 0.48, 0.71, 0.55, 0.66, 0.43][index]), place: Bar(width: 100),
                 state: Bar(width: 56), extra: Bar(width: 60), person: Bar(width: 70))
        }
    }

    /// A pull request's checks and review, or an issue's priority.
    @ViewBuilder private func extra(_ row: IntegrationItem) -> some View {
        if integration == .github {
            HStack(spacing: 6) {
                switch row.checks {
                case "success": NucleoIcon("circle-check", fill: "glyph", size: 13).foregroundStyle(.green)
                case "failure", "error": NucleoIcon("circle-xmark", fill: "glyph", size: 13).foregroundStyle(.red)
                case .some: NucleoIcon("hourglass", fill: "glyph", size: 13).foregroundStyle(.orange)
                case nil: EmptyView()
                }
                Text(row.review.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "").foregroundStyle(row.review == "changes requested" ? Color.orange : .secondary)
            }
        } else {
            Text(["No priority", "Urgent", "High", "Medium", "Low"][min(row.priority ?? 0, 4)]).foregroundStyle(row.priority == 1 ? Color.red : .secondary)
        }
    }
}

/// A Linear view as Linear lists it: a header tinted in each state's colour, which folds its issues away (remembered
/// per view), then the issues: priority, key, state, title, labels and project, assignee, when it was made.
private struct LinearList: View {
    let rows: [IntegrationItem]
    let actions: TaskActions
    /// The folded states' names, one per line.
    @AppStorage private var folded: String

    init(rows: [IntegrationItem], view: String, actions: TaskActions) {
        self.rows = rows
        self.actions = actions
        _folded = AppStorage(wrappedValue: "", "linearFolded.\(view)")
    }

    private struct Group: Identifiable {
        var state: String
        var rows: [IntegrationItem]
        var id: String { state }
    }

    /// zerod sends issues already grouped, in Linear's order.
    private var groups: [Group] {
        rows.reduce(into: []) { groups, row in
            if groups.last?.state == row.state { groups[groups.count - 1].rows.append(row) } else { groups.append(Group(state: row.state, rows: [row])) }
        }
    }

    var body: some View {
        let groups = groups
        let folded = Set(folded.split(separator: "\n").map(String.init))
        // In-progress states fill their circle the further along they are, as Linear's do.
        let started = groups.filter { $0.rows[0].kind == "started" }.map(\.state)
        LazyVStack(spacing: 0) {
            ForEach(groups) { group in
                let first = group.rows[0]
                let fill = started.firstIndex(of: group.state).map { Double(started.count - $0) / Double(started.count + 1) } ?? 0.5
                let icon = StateIcon(kind: first.kind, color: first.color.map(Color.init(hex:)) ?? .secondary, fill: fill)
                Button { toggle(group.state, in: folded) } label: {
                    HStack(spacing: 9) {
                        NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(folded.contains(group.state) ? -90 : 0))
                        icon
                        Text(group.state).font(.system(size: 13, weight: .medium))
                        Text("\(group.rows.count)").font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                    .background((first.color.map(Color.init(hex:)) ?? .secondary).opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, group.id == groups.first?.id ? 0 : 4)
                if !folded.contains(group.state) {
                    ForEach(group.rows) { IssueRow(row: $0, icon: icon, actions: actions) }
                }
            }
        }
        .padding(.horizontal, -12) // the headers' tint bleeds past the title's edge, as Linear's does
    }

    private func toggle(_ state: String, in folded: Set<String>) {
        self.folded = (folded.contains(state) ? folded.subtracting([state]) : folded.union([state])).sorted().joined(separator: "\n")
    }
}

private struct IssueRow: View {
    let row: IntegrationItem
    let icon: StateIcon
    let actions: TaskActions
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            PriorityIcon(priority: row.priority ?? 0)
            Text(row.key).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit().frame(width: 70, alignment: .leading)
            icon
            Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 12)
            TaskControl(row: row, actions: actions, hovered: hovered)
            ForEach(row.tags ?? [], id: \.self) { TagChip(tag: $0) }
            Avatar(url: row.avatar, name: row.person)
            Text(Self.date(row.created)).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(hovered ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if let url = LinearLinks.url(row.url) { NSWorkspace.shared.open(url) } }
        .contextMenu {
            if let task = row.task { Button("Open task") { actions.open(task) } } else if let start = actions.start { Button("Start task") { start(row) } }
            Button("Open in Linear") { if let url = LinearLinks.url(row.url) { NSWorkspace.shared.open(url) } }
            Button("Copy link") { PadLinks.copy(row.url, title: "\(row.key) \(row.title)") }
        }
        .tip(row.title)
    }

    /// "Oct 12" this year, "Mar 2025" before it.
    static func date(_ iso: String?) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let iso, let date = parser.date(from: iso) else { return "" }
        let thisYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(thisYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).year())
    }
}

/// A workflow state as Linear draws it: dashed for the backlog, empty to do, filling as it goes, done ticked, triage
/// swapped arrows, canceled crossed.
private struct StateIcon: View {
    let kind: String?
    let color: Color
    /// How full an in-progress state's circle is.
    var fill = 0.5

    var body: some View {
        ZStack {
            switch kind {
            case "backlog": Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.4, dash: [2, 1.7]))
            case "started":
                Circle().strokeBorder(color, lineWidth: 1.4)
                Pie(fraction: fill).fill(color).padding(3)
            case "completed": Circle().fill(color); Text("✓").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
            case "canceled", "duplicate": Circle().fill(Color.secondary); Text("✕").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
            case "triage": Circle().fill(color); Text("⇄").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            default: Circle().strokeBorder(Color.secondary, lineWidth: 1.4)
            }
        }
        .frame(width: 14, height: 14)
    }

    private struct Pie: Shape {
        let fraction: Double
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            path.move(to: centre)
            path.addArc(center: centre, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
            path.closeSubpath()
            return path
        }
    }
}

/// Linear's priority: three bars filled as high as it is, urgent a warning square, none dashes.
private struct PriorityIcon: View {
    let priority: Int

    var body: some View {
        Group {
            switch priority {
            case 1:
                Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 13, height: 13).background(Color.orange, in: RoundedRectangle(cornerRadius: 3))
            case 2, 3, 4:
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(0..<3) { bar in
                        RoundedRectangle(cornerRadius: 1).frame(width: 3, height: [6, 9, 12][bar])
                            .opacity(bar < 5 - priority ? 1 : 0.25)
                    }
                }
                .foregroundStyle(.secondary)
            default:
                HStack(spacing: 1.5) { ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 1).frame(width: 3, height: 1.5) } }.foregroundStyle(.tertiary)
            }
        }
        .frame(width: 16, height: 14)
    }
}

/// A label (its colour's dot) or a project (its emoji when it has one), in a pill.
private struct TagChip: View {
    let tag: IntegrationTag

    var body: some View {
        HStack(spacing: 5) {
            if let emoji = tag.icon.flatMap(Self.emoji) { Text(emoji).font(.system(size: 11)) }
            else { Circle().fill(tag.color.map(Color.init(hex:)) ?? .secondary).frame(width: 8, height: 8) }
            Text(tag.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: 190)
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Shortcodes whose emoji's Unicode name is something else.
    private static let aliases = ["moneybag": "💰", "bee": "🐝", "rolled_up_newspaper": "🗞️", "alien": "👽", "us": "🇺🇸", "tv": "📺", "up": "🆙",
                                  "art": "🎨", "arrow_upper_right": "↗️", "female-artist": "👩‍🎨", "flag-cz": "🇨🇿", "+1": "👍", "rocket": "🚀"]

    /// ":fire:" as 🔥, by its Unicode name; nil for Linear's own icons ("Server") and custom emoji.
    static func emoji(_ code: String) -> String? {
        guard code.count > 2, code.hasPrefix(":"), code.hasSuffix(":") else { return nil }
        let name = String(code.dropFirst().dropLast())
        if let alias = aliases[name] { return alias }
        let spoken = name.replacingOccurrences(of: "_", with: " ").uppercased()
        for candidate in [spoken, spoken + " SIGN", spoken + " FACE"] {
            if let emoji = "\\N{\(candidate)}".applyingTransform(StringTransform("Name-Any"), reverse: false), !emoji.hasPrefix("\\") { return emoji }
        }
        return nil
    }
}

/// The assignee's picture from Linear, or their initial while it loads or when they have none.
private struct Avatar: View {
    let url: String?
    let name: String?

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(name?.prefix(1) ?? "").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.chip)
        }
        .frame(width: 18, height: 18).clipShape(Circle())
        .opacity(name == nil ? 0 : 1)
    }
}

/// Not connected yet: the integration's mark, what it gives you, and the one step to connect it (Linear signs in in the
/// browser; GitHub goes through the GitHub CLI, signed in in a terminal).
struct ConnectCard: View {
    let integration: Integration
    let workspace: Workspace
    @State private var waiting = false
    @State private var copied = false
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16).fill(Theme.composer).frame(width: 64, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.stroke))
                .overlay(integration.icon(size: 30).foregroundStyle(.primary))
                .padding(.bottom, 18)
            Text("Connect \(integration.title)").font(.system(size: 20, weight: .semibold)).padding(.bottom, 6)
            BalancedText(pitch, font: .systemFont(ofSize: 13), maxWidth: 380)
                .foregroundStyle(.secondary).padding(.bottom, 20)
            switch integration {
            case .linear:
                Button(waiting ? "Waiting for Linear…" : "Connect Linear") { connectLinear() }
                    .buttonStyle(Prominent()).disabled(waiting)
            case .slack:
                // Slack's sign-in needs a secret Zero can't carry: instead each workspace gets Zero's app from its
                // manifest, and the person pastes the user token Slack shows once it's installed.
                Button("Create Zero's Slack app") { NSWorkspace.shared.open(Slack.createAppURL) }.buttonStyle(Prominent())
                Text("Slack opens with the app filled in: Create, then Install to Workspace, then copy the User OAuth Token it shows and paste it here. Connected before agents could follow Slack? Add the scopes from the manifest to your app, reinstall it, and paste the new token.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380).padding(.top, 12).padding(.bottom, 14)
                HStack(spacing: 8) {
                    SecureField("xoxp-…", text: $token).textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced()).frame(width: 260)
                        .onSubmit(connectSlack)
                    Button(waiting ? "Connecting…" : "Connect") { connectSlack() }.disabled(waiting || token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 10) }
            case .github:
                HStack(spacing: 8) {
                    Text("gh auth login").font(.system(size: 12.5).monospaced()).textSelection(.enabled)
                    Button { copy() } label: { NucleoIcon(copied ? "check" : "copy", size: 13).foregroundStyle(.secondary).frame(width: 24, height: 24) }
                        .buttonStyle(Hovering(radius: 6)).tip("Copy")
                }
                .padding(.leading, 12).padding(.trailing, 4).frame(height: 34)
                .background(Theme.composer, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
                .padding(.bottom, 14)
                Button(waiting ? "Checking…" : "Check again") { check() }.buttonStyle(Prominent()).disabled(waiting)
                Text("Run it in a terminal to sign the GitHub CLI in. No GitHub CLI? brew install gh.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 12)
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var pitch: String {
        switch integration {
        case .linear: "See your issues in Zero, in views you choose: yours, a team's, or any states you like."
        case .github: "See your pull requests and the reviews waiting on you, in views you choose, such as one organisation's repositories."
        case .slack: "Channels and threads named in messages open in Slack itself, and agents can follow a thread or a channel to hear its replies. Zero reads channels, messages and names; it posts nothing."
        }
    }

    private func connectSlack() {
        waiting = true
        error = nil
        Task {
            error = await workspace.connectSlack(token: token)
            if error == nil { token = "" }
            waiting = false
        }
    }

    private func connectLinear() {
        waiting = true
        Task {
            if let url = await workspace.connectLinear() { NSWorkspace.shared.open(url) }
            // It finishes in the browser: look again until it has.
            for _ in 0..<150 where workspace.integrations?.linear == nil {
                try? await Task.sleep(for: .seconds(2))
                await workspace.loadIntegrations()
            }
            waiting = false
        }
    }

    private func check() {
        waiting = true
        Task { await workspace.loadIntegrations(); waiting = false }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("gh auth login", forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

/// The one button that matters on a screen: solid, in the app's ink.
struct Prominent: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.onKnob)
            .padding(.horizontal, 18).frame(height: 34)
            .background(Theme.knob.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

/// A placeholder for a line of text while it loads: a rounded bar a text line tall, gently pulsing (still, with Reduce
/// Motion on). Fixed in width, or a fraction of the space it's given.
private struct Bar: View {
    var width: CGFloat? = nil
    var fraction: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Text(" ").hidden() // a text line's height, so the row is as tall as a real one
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { size in
                    RoundedRectangle(cornerRadius: 5).fill(Theme.chip)
                        .frame(width: width ?? size.size.width * (fraction ?? 1), height: 10)
                        .frame(maxHeight: .infinity)
                }
            }
            .opacity(dim ? 0.5 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Centred text wrapped into lines of even length (CSS's text-wrap: balance): as narrow as still takes the same number
/// of lines it needs at `maxWidth`, so no line is left with a word or two.
struct BalancedText: View {
    let text: String
    let font: NSFont
    let maxWidth: CGFloat

    init(_ text: String, font: NSFont, maxWidth: CGFloat) { self.text = text; self.font = font; self.maxWidth = maxWidth }

    var body: some View {
        Text(text).font(Font(font)).multilineTextAlignment(.center).frame(width: width).fixedSize(horizontal: false, vertical: true)
    }

    /// Narrows from `maxWidth` while the text still fits in as many lines.
    private var width: CGFloat {
        let lines = { (width: CGFloat) -> Int in
            let height = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                                        attributes: [.font: font]).height
            return Int((height / (font.ascender - font.descender + font.leading)).rounded())
        }
        let target = lines(maxWidth)
        var (low, high) = (CGFloat(40), maxWidth)
        while high - low > 2 {
            let middle = (low + high) / 2
            if lines(middle) > target { low = middle } else { high = middle }
        }
        return ceil(high) + 1
    }
}

/// Linear links open in Linear's app when it's installed, unless you'd rather the browser.
enum LinearLinks {
    static let key = "linearOpensInApp"
    /// Issues (ABC-123) in messages as links; on unless turned off. Opening them in the app needs this on.
    static let enabledKey = "linearLinks"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static let installed = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "linear://")!) != nil
    static var inApp: Bool { enabled && installed && UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// The link to open: Linear's web link as the app's (linear://acme/issue/ENG-1), when the app opens it.
    static func url(_ link: String) -> URL? {
        let web = "https://linear.app/"
        return URL(string: inApp && link.hasPrefix(web) ? "linear://" + link.dropFirst(web.count) : link)
    }
}
