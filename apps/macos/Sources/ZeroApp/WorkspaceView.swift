import AppKit
import SwiftUI
import ZeroCore

/// The workspace window, laid out as ChatGPT's: an outer rail (home, settings) on the window's grey, and a panel
/// holding an inner sidebar and the page. Home's sidebar is the tasks (a lead session with its workers); its page a new
/// task, every task at once, or one. Everything comes from `Workspace`; nothing here knows a provider's protocol.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @Bindable var navigation: Navigation
    let settings: () -> SettingsView

    var body: some View {
        HStack(spacing: 0) {
            Rail(place: $navigation.place)
            Group {
                if navigation.place == .settings {
                    settings()
                } else {
                    HStack(spacing: 0) {
                        TasksSidebar(workspace: workspace, place: $navigation.place)
                        Rectangle().fill(Theme.stroke).frame(width: 1)
                        page.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            .padding(.top, 38).padding([.trailing, .bottom], 4) // under the window's buttons, as ChatGPT's
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Theme.rail)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if let error = workspace.lastError {
                Text(error).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.redRow, in: Capsule()).padding(16)
                    .onTapGesture { workspace.lastError = nil }
            }
        }
        // The sidebar lists the board's tasks, so it stays fresh while the window is open.
        // ponytail: polls; a board feed from zerod when two seconds is too slow.
        .task {
            while !Task.isCancelled {
                await workspace.refreshBoard()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch navigation.place {
        case .board: BoardView(workspace: workspace, open: { navigation.place = .task($0) })
        case .task(let id) where workspace.conversation(id) != nil: TaskView(workspace: workspace, lead: id).id(id)
        default: NewTaskView(workspace: workspace, started: { navigation.place = .task($0) })
        }
    }
}

/// The outer rail: home at the top, settings at the foot, room for more later.
private struct Rail: View {
    @Binding var place: Navigation.Place

    var body: some View {
        VStack(spacing: 6) {
            item("house", selected: place != .settings, help: "Home") { if place == .settings { place = .home } }
            Spacer()
            item("gearshape", selected: place == .settings, help: "Settings") { place = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.top, 50).padding(.bottom, 12)
        .frame(width: 48)
    }

    private func item(_ symbol: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: selected ? symbol + ".fill" : symbol).font(.system(size: 15))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(Hovering(selected: selected, fill: Theme.railSelected, hover: Theme.railHover)).help(help)
    }
}

private struct TasksSidebar: View {
    let workspace: Workspace
    @Binding var place: Navigation.Place

    /// Leads that aren't on the board: finished and gone offline with nothing for him.
    private var earlier: [Conversation] {
        let all = workspace.conversations
        return all.filter { lead in (lead.parent == nil || !all.contains { $0.id == lead.parent }) && !workspace.board.contains { $0.session == lead.id } }.reversed()
    }

    var body: some View {
        SidebarColumn(title: "Zero") {
            SidebarItem("New task", systemImage: "square.and.pencil", selected: place == .home) { place = .home }
                .keyboardShortcut("n", modifiers: .command)
            SidebarItem("All tasks", systemImage: "tablecells", selected: place == .board) { place = .board }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SidebarHeading(text: "Tasks")
                    if workspace.board.isEmpty {
                        Text("No tasks").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 10)
                    }
                    ForEach(workspace.board) { row in
                        SidebarItem(title: row.task, selected: place == .task(row.session), trailing: true, action: { place = .task(row.session) }) {
                            StateIcon(state: row.state)
                        }
                    }
                    if !earlier.isEmpty {
                        SidebarHeading(text: "Earlier")
                        ForEach(earlier) { lead in
                            SidebarItem(Workspace.label(of: lead), selected: place == .task(lead.id)) { place = .task(lead.id) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            footer
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !workspace.connected {
                Label("Connecting to Zero's daemon…", systemImage: "bolt.horizontal")
            }
            // What each provider last said about its limits.
            ForEach(workspace.usage.filter { !$0.1.windows.isEmpty }, id: \.0) { provider, usage in
                Text("\(provider.title)  " + usage.windows.map { "\($0.name) \(Int(($0.used * 100).rounded()))%" }.joined(separator: " · "))
                    .foregroundStyle(usage.limited ? Color.orange : .secondary)
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 10)
    }
}

// A task: its lead, its workers a click away.

private struct TaskView: View {
    let workspace: Workspace
    let lead: String
    @State private var shown: String?

    private var team: [Conversation] {
        let all = workspace.conversations
        var team = all.filter { $0.id == lead }
        var i = 0
        while i < team.count { let id = team[i].id; team += all.filter { $0.parent == id }; i += 1 }
        return team
    }

    var body: some View {
        let team = team
        let row = workspace.board.first { $0.session == lead }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let row { StateIcon(state: row.state) }
                    PageTitle(text: row?.task ?? team.first.map(Workspace.label(of:)) ?? "")
                }
                Text([row?.ticket ?? team.first?.ticket, row?.place].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                if let row, let needs = row.asks.first?.title ?? row.needs {
                    Label(needs, systemImage: row.asks.isEmpty ? "hand.raised" : "questionmark.circle")
                        .font(.callout).foregroundStyle(row.asks.isEmpty ? Color.primary : .orange)
                }
                if team.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(team) { member in
                            Button { shown = member.id } label: {
                                Text(member.id == lead ? "Lead" : Workspace.label(of: member)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    .padding(.horizontal, 10).frame(height: 24)
                            }
                            .buttonStyle(Hovering(selected: (shown ?? lead) == member.id, radius: 12, fill: Theme.railSelected, hover: Theme.chip))
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .centredColumn(760)
            .padding(.top, 36).padding(.bottom, 12)
            if let conversation = workspace.conversation(shown ?? lead) {
                ConversationView(workspace: workspace, conversation: conversation).id(conversation.id)
            }
        }
    }
}

// The board: every task at once, most urgent first, as a panel from arsenstorm.com: a grey shell carrying the
// headings, a lighter body, hairlines between rows.

private struct BoardView: View {
    let workspace: Workspace
    let open: (String) -> Void

    var body: some View {
        let rows = workspace.board
        // A column of one place says nothing.
        let places = Set(rows.map(\.place)).count > 1
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(text: "All tasks")
                if !rows.isEmpty {
                    ArticlePanel {
                        // The headings in the shell's strip, over the columns they name.
                        line(head: true, places: places, task: Text("Task"), place: Text("Where"), state: Text("State"), now: Text("Now"), needs: Text("Needs you"))
                            .padding(.vertical, -3)
                    } content: {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1) }
                                Button { open(row.session) } label: {
                                    line(head: false, places: places,
                                         task: VStack(alignment: .leading, spacing: 2) {
                                             Text(row.task).foregroundStyle(.primary)
                                             if row.workers > 0 { Text(row.workers == 1 ? "1 worker" : "\(row.workers) workers").font(.system(size: 12)).foregroundStyle(.secondary) }
                                         },
                                         place: Text(row.place).foregroundStyle(.secondary),
                                         state: StateLabel(state: row.state),
                                         now: Text(row.now ?? ""),
                                         needs: needs(row))
                                }
                                .buttonStyle(Hovering(radius: 0, hover: Theme.rowHover))
                            }
                        }
                    }
                }
            }
            .centredColumn(1040)
            .padding(.vertical, 36)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No tasks", systemImage: "tablecells", description: Text("Start one with New task (⌘N). Each shows here as a row, its workers folded in."))
            }
        }
    }

    /// One row of the table, the header included: two fixed columns, the rest sharing what's left.
    private func line(head: Bool, places: Bool, task: some View, place: some View, state: some View, now: some View, needs: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            task.frame(maxWidth: .infinity, alignment: .leading)
            if places { place.frame(width: 140, alignment: .leading) }
            state.frame(width: 110, alignment: .leading)
            now.frame(maxWidth: .infinity, alignment: .leading)
            needs.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(head ? .system(size: 12, weight: .medium) : .system(size: 13))
        .tracking(head ? -0.2 : 0)
        .foregroundStyle(head ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.85)))
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// An open ask first: it waits on him. Then what the agent handed over.
    @ViewBuilder private func needs(_ row: BoardRow) -> some View {
        if let first = row.asks.first {
            Text("Yes: " + first.title + (row.asks.count > 1 ? " (+\(row.asks.count - 1) more)" : "")).foregroundStyle(.orange)
        } else if let needs = row.needs {
            Text(needs)
        } else {
            Text("No").foregroundStyle(.secondary)
        }
    }
}

/// A panel as arsenstorm.com draws one, in the app's own greys: the rail's grey as a shell 2 pt thick with a strip on
/// top (here, the table's headings), around a body in the sidebar's grey.
private struct ArticlePanel<Strip: View, Content: View>: View {
    @ViewBuilder let strip: () -> Strip
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            strip()
            content()
                .background(Theme.composer)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(2)
        .background(Theme.rail, in: RoundedRectangle(cornerRadius: 12))
        // Bled out by its inner padding (the shell's 2 pt and a cell's 16), so its text lines up with the page's, as
        // the site's panels do with its prose.
        .padding(.horizontal, -18)
    }
}

/// What a task's state looks like, in colours that say it at a glance: orange it waits on you, red it's in trouble,
/// blue it works, green it's ready for you, grey the rest.
private struct StateIcon: View {
    let state: BoardRow.State

    var body: some View {
        Image(systemName: Self.look(state).symbol).foregroundStyle(Self.look(state).color).help(Self.look(state).name)
    }

    static func look(_ state: BoardRow.State) -> (symbol: String, color: Color, name: String) {
        switch state {
        case .needsYou: ("questionmark.circle.fill", .orange, "Needs you")
        case .trouble: ("exclamationmark.triangle.fill", .red, "In trouble")
        case .working: ("arrow.triangle.2.circlepath.circle.fill", .blue, "Working")
        case .waiting: ("hourglass.circle.fill", .secondary, "Waiting")
        case .ready: ("checkmark.circle.fill", .green, "Ready for you")
        case .done: ("checkmark.circle.fill", .secondary, "Done")
        case .idle: ("moon.circle.fill", .secondary, "Idle")
        case .offline: ("power.circle.fill", .secondary, "Offline")
        }
    }
}

/// The symbol and its name, for the board's State column.
private struct StateLabel: View {
    let state: BoardRow.State

    var body: some View {
        let look = StateIcon.look(state)
        HStack(spacing: 6) {
            StateIcon(state: state).font(.system(size: 13))
            Text(look.name).font(.system(size: 12, weight: .medium)).foregroundStyle(look.color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(look.color))
        }
    }
}

// The conversation.

private struct ConversationView: View {
    let workspace: Workspace
    let conversation: Conversation
    @State private var draft = ""
    /// Another provider picked for the next message; nil keeps the task's own.
    @State private var provider: Provider?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let health {
                HStack(spacing: 10) {
                    Label(health.text, systemImage: health.icon).font(.callout).foregroundStyle(health.color)
                    Spacer()
                    // Out of usage: the task carries on with another provider, the whole conversation with it.
                    if conversation.attention == .limited {
                        ForEach(Self.takeOver.filter { $0 != conversation.provider }, id: \.self) { other in
                            Button("Continue with \(other.title)") { carryOn(with: other) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8).background(health.color.opacity(0.08))
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // A step waiting on an approval shows once, in the approval.
                        ForEach(conversation.items.filter { item in !conversation.approvals.contains { $0.item == item.id } }) { item in
                            ItemView(item: item, cwd: conversation.cwd).id(item.id)
                        }
                        ForEach(conversation.questions) { question in
                            QuestionCard(question: question) { answers in
                                Task { await workspace.answer(conversation.id, question: question.id, answers: answers) }
                            }
                            .id("question-" + question.id)
                        }
                        ForEach(conversation.approvals) { approval in
                            ApprovalCard(approval: approval, cwd: conversation.cwd) { choice in
                                Task { await workspace.decide(conversation.id, approval: approval.id, choice: choice.id) }
                            }
                            .id("approval-" + approval.id)
                        }
                        if let diff = conversation.diff, conversation.status == .idle, !diff.isEmpty {
                            DisclosureGroup("Everything the last turn changed") { DiffText(diff: diff) }.padding(.top, 4)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.vertical, 20)
                    .centredColumn(760)
                }
                .onChange(of: conversation.seq) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Composer(draft: $draft, placeholder: placeholder, canSend: conversation.status != .starting) {
                let text = draft
                draft = ""
                send(text, with: provider ?? conversation.provider)
            } controls: {
                // Another provider for the next message: the task moves there, conversation and all.
                ComposerMenu(label: (provider ?? conversation.provider).title) {
                    Picker("Agent", selection: Binding(get: { provider ?? conversation.provider }, set: { provider = $0 == conversation.provider ? nil : $0 })) {
                        ForEach(Provider.allCases, id: \.rawValue) { Text($0.title).tag($0).disabled(!Self.takeOver.contains($0)) }
                    }
                    .pickerStyle(.inline)
                }
                .disabled(conversation.status == .working || conversation.status == .waiting)
            }
            .centredColumn(760).padding(.bottom, 16)
        }
    }

    /// The providers a task can move to: they read Zero's record natively (Claude Code resumes it, Codex imports it).
    static let takeOver: [Provider] = [.claude, .codex]

    private func send(_ text: String, with chosen: Provider) {
        Task {
            if chosen != conversation.provider {
                guard await workspace.switchProvider(conversation.id, to: chosen) else { return }
                provider = nil
            }
            await workspace.send(conversation.id, text: text)
        }
    }

    private func carryOn(with other: Provider) {
        send("You've taken this task over from \(conversation.provider.title), which ran out of usage. Carry on from where it stopped.", with: other)
    }

    /// What's wrong, and what to do about it: the session's attention beyond working or waiting.
    private var health: (text: String, icon: String, color: Color)? {
        switch conversation.attention {
        case .stuck: return (conversation.stalled ?? "Stuck", "exclamationmark.arrow.circlepath", .orange)
        case .limited:
            let reset = (conversation.usage?.resetsAt).map { " Resets \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened))." } ?? ""
            return ("Usage limit reached.\(reset)", "hourglass", .orange)
        case .failed:
            let message = conversation.failure?.message ?? conversation.error ?? "It failed"
            let hint = switch conversation.failure?.kind {
            case .signIn?: " Sign in with \(conversation.provider == .claude ? "claude" : conversation.provider.rawValue) in a terminal."
            case .network?: " Check the network, then send a message to retry."
            case .model?: " Try another model."
            default: ""
            }
            return (message + hint, "exclamationmark.triangle", .red)
        default: return nil
        }
    }

    private var placeholder: String {
        switch conversation.status {
        case .offline: "Message to resume it"
        case .working, .waiting: conversation.provider == .opencode ? "OpenCode answers one message at a time" : "Steer it while it works"
        default: "Reply"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text([conversation.provider.title, conversation.model, conversation.effort, conversation.permissions == .unrestricted ? "unrestricted" : nil,
                      usage, (conversation.cwd as NSString).abbreviatingWithTildeInPath]
                    .compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch conversation.status {
            case .working, .waiting:
                ProgressView().controlSize(.small)
                Button("Stop turn") { Task { await workspace.interrupt(conversation.id) } }.keyboardShortcut(".", modifiers: .command)
            case .offline:
                Button("Resume") { Task { await workspace.resume(conversation.id) } }
            default:
                Button("End session") { Task { await workspace.stop(conversation.id) } }
            }
        }
        .centredColumn(760).padding(.vertical, 10)
    }

    /// "5 hours 18% · 7 days 5%": what the provider last reported for the account.
    private var usage: String? {
        guard let windows = conversation.usage?.windows, !windows.isEmpty else { return nil }
        return windows.map { "\($0.name) \(Int(($0.used * 100).rounded()))%" }.joined(separator: " · ")
    }
}

/// The agent asking: each field's options as buttons (toggles where several may be picked), its own words where it
/// takes them, dots for a secret. Sent once every field has an answer.
private struct QuestionCard: View {
    let question: Question
    let send: ([String: [String]]) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    private func answer(_ field: Field) -> [String] {
        let own = typed[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let options = field.options.map(\.label).filter { picked[field.id, default: []].contains($0) }
        return own.isEmpty ? options : options + [own]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(question.fields) { field in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = field.header { Text(header.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(field.question).font(.headline)
                    HStack {
                        ForEach(field.options, id: \.label) { option in
                            let on = picked[field.id, default: []].contains(option.label)
                            Button(option.label) {
                                if field.multiple { picked[field.id, default: []].formSymmetricDifference([option.label]) }
                                else { picked[field.id] = on ? [] : [option.label] }
                            }
                            .buttonStyle(.bordered).tint(on ? .accentColor : nil).help(option.description ?? "")
                        }
                    }
                    if field.secret { SecureField("Secret", text: Binding(get: { typed[field.id, default: ""] }, set: { typed[field.id] = $0 })) }
                    else if field.other || field.options.isEmpty {
                        TextField(field.options.isEmpty ? "Your answer" : "Or say something else", text: Binding(get: { typed[field.id, default: ""] }, set: { typed[field.id] = $0 }))
                    }
                }
            }
            Button("Answer") { send(Dictionary(uniqueKeysWithValues: question.fields.map { ($0.id, answer($0)) })) }
                .buttonStyle(.borderedProminent).disabled(question.fields.contains { answer($0).isEmpty })
        }
        .padding(16).background(Theme.orangeRow, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ItemView: View {
    let item: ConversationItem
    let cwd: String

    var body: some View {
        switch item.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 80)
                Text(text).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.knob, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Theme.onKnob)
            }
        case let .agent(text, _):
            MarkdownText(text, cwd: cwd)
        case let .reasoning(text):
            DisclosureGroup { Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) } label: {
                Label("Thinking", systemImage: "brain").font(.callout).foregroundStyle(.secondary)
            }
        case let .plan(text):
            Text(text).font(.system(.callout, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
        case let .command(command, _, output, exitCode, _):
            CommandCard(command: command, output: output, exitCode: exitCode, status: item.status)
        case let .fileChange(changes):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(changes, id: \.path) { change in FileChangeCard(change: change, status: item.status, cwd: cwd) }
            }
        case let .tool(name, detail):
            HStack(spacing: 8) {
                StatusIcon(status: item.status)
                Text(name).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).truncationMode(.middle)
            }
            .font(.callout).lineLimit(1)
        case let .notice(text, error):
            Label(text, systemImage: error ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.callout).foregroundStyle(error ? Color.red : .secondary)
        }
    }
}

private struct StatusIcon: View {
    let status: ItemStatus
    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .declined: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        }
    }
}

private struct CommandCard: View {
    let command: String
    let output: String
    let exitCode: Int?
    let status: ItemStatus
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    StatusIcon(status: status)
                    Text("$ " + command).font(.system(.callout, design: .monospaced)).lineLimit(open ? nil : 1)
                    Spacer()
                    if let exitCode, exitCode != 0 { Text("exit \(exitCode)").font(.caption).foregroundStyle(.red) }
                    if !output.isEmpty { Image(systemName: open ? "chevron.up" : "chevron.down").foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && !output.isEmpty {
                ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 280)
            }
        }
        .padding(12).background(Theme.code, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FileChangeCard: View {
    let change: FileChange
    let status: ItemStatus
    let cwd: String
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    StatusIcon(status: status)
                    Text(verb).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(relative(change.path, to: cwd)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && !change.diff.isEmpty { DiffText(diff: change.diff, added: change.kind == "add") }
        }
        .padding(12).card()
    }

    private var verb: String {
        switch change.kind {
        case "add": "ADDED"
        case "delete": "DELETED"
        default: change.movePath == nil ? "EDITED" : "MOVED"
        }
    }
}

/// A path inside the session's folder, from that folder: "src/main.rs".
private func relative(_ path: String, to folder: String) -> String {
    let base = folder.hasSuffix("/") ? folder : folder + "/"
    let resolved = { (p: String) in p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }
    let (inner, outer) = (resolved(path), resolved(base))
    return inner.hasPrefix(outer) ? String(inner.dropFirst(outer.count)) : (path as NSString).abbreviatingWithTildeInPath
}

/// A diff's lines, additions green and removals red. A new file's contents arrive without markers: all added.
private struct DiffText: View {
    let diff: String
    var added = false

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line)).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(line)).frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: 360)
    }

    private func color(_ line: Substring) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        return .primary
    }

    private func background(_ line: Substring) -> Color {
        if added || (line.hasPrefix("+") && !line.hasPrefix("+++")) { return Theme.greenRow }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Theme.redRow }
        return .clear
    }
}

/// The provider asking before it acts: what it wants, why, and its own choices, the first one the default.
private struct ApprovalCard: View {
    let approval: Approval
    let cwd: String
    let choose: (Choice) -> Void

    /// Claude describes a file approval by the file's name, which the title already says.
    private var reason: String? {
        guard let reason = approval.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty,
              !approval.title.localizedCaseInsensitiveContains(reason) else { return nil }
        return reason
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.title, systemImage: "hand.raised").font(.headline).foregroundStyle(.orange)
            if let reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            if let command = approval.command {
                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(approval.changes, id: \.path) { change in FileChangeCard(change: change, status: .running, cwd: cwd) }
            HStack {
                ForEach(Array(approval.choices.enumerated()), id: \.element.id) { index, choice in
                    let button = Button(choice.label) { choose(choice) }
                    if index == 0 { button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) } else { button }
                }
            }
        }
        .padding(16).background(Theme.orangeRow, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The message box, as ChatGPT's: a white card with a soft edge, the field over a row of controls and the send button.
private struct Composer<Controls: View>: View {
    @Binding var draft: String
    let placeholder: String
    var canSend = true
    let send: () -> Void
    @ViewBuilder var controls: Controls

    var body: some View {
        let ready = canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical).textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...10)
                .onSubmit { if ready { send() } }
            HStack(spacing: 6) {
                HStack(spacing: 6) { controls }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onKnob)
                        .frame(width: 26, height: 26).background(Theme.knob.opacity(ready ? 1 : 0.25), in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(!ready)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

extension Composer where Controls == EmptyView {
    init(draft: Binding<String>, placeholder: String, canSend: Bool = true, send: @escaping () -> Void) {
        self.init(draft: draft, placeholder: placeholder, canSend: canSend, send: send) { EmptyView() }
    }
}

/// A small control in the composer's row: a menu that reads as a word or two, ChatGPT's "Ask for approval".
private struct ComposerMenu<Items: View>: View {
    let label: String
    var symbol: String?
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(label)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
    }
}

// A new task: its lead session. Home, as ChatGPT's: a greeting in the middle, the composer at the foot with the
// project above it and the agent, model, effort and permissions in its row.

private struct NewTaskView: View {
    let workspace: Workspace
    let started: (String) -> Void
    @AppStorage("workspaceProvider") private var provider = Provider.codex.rawValue
    @AppStorage("workspaceProject") private var project = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var permissions = Permissions.auto
    @State private var prompt = ""
    @State private var starting = false

    private var chosen: Provider { Provider(rawValue: provider) ?? .codex }
    private var folders: [String] { Projects.folders }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                ZeroMark(small: true).frame(width: 34, height: 33).foregroundStyle(.secondary)
                Text("What should we work on?").font(.system(size: 26))
            }
            Spacer()
            VStack(spacing: 0) {
                projectTab
                Composer(draft: $prompt, placeholder: "Do anything", canSend: !starting && folders.contains(project)) { start() } controls: {
                    ComposerMenu(label: permissions == .auto ? "Auto" : "Unrestricted", symbol: permissions == .auto ? "hand.raised" : "exclamationmark.shield") {
                        Picker("Permissions", selection: $permissions) {
                            Text("Auto: \(chosen.title) decides what's safe, and asks you the rest").tag(Permissions.auto)
                            Text("Unrestricted: anything, without asking").tag(Permissions.unrestricted)
                        }
                        .pickerStyle(.inline)
                    }
                    Spacer(minLength: 0)
                    ComposerMenu(label: agentLabel) {
                        Picker("Agent", selection: $provider) {
                            ForEach(Provider.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.inline)
                        if !models.isEmpty {
                            Picker("Model", selection: $model) {
                                Text("Default").tag("")
                                ForEach(models, id: \.id) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.inline)
                        }
                        if !levels.isEmpty {
                            Picker("Effort", selection: $effort) {
                                Text("Default").tag("")
                                ForEach(levels, id: \.self) { Text($0.capitalized).tag($0) }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 36).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: provider) { model = ""; effort = "" }
        .onAppear { if !folders.contains(project) { project = folders.first ?? "" } }
    }

    /// The folder it starts in, as a tab behind the composer's top edge.
    @ViewBuilder private var projectTab: some View {
        HStack {
            if folders.isEmpty {
                Label("Add a project in Settings → Projects", systemImage: "folder").foregroundStyle(.secondary)
            } else {
                ComposerMenu(label: folders.contains(project) ? (project as NSString).lastPathComponent : "Choose project", symbol: "folder") {
                    Picker("Project", selection: $project) {
                        ForEach(folders, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 16)
        .background(Theme.composer, in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12).strokeBorder(Theme.stroke))
        .padding(.horizontal, 10).padding(.bottom, -10)
    }

    /// "Claude · Opus · High".
    private var agentLabel: String {
        [chosen.title, models.first { $0.id == model }?.name ?? (model.isEmpty ? nil : model), effort.isEmpty ? nil : effort.capitalized]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Codex's own catalogue for its account, from its cache; the aliases Claude Code takes; OpenCode's models are
    /// per session, so typed. Nothing here asks a provider's service with Arsen's credentials.
    private var models: [SpawnChoice] {
        switch chosen {
        case .codex: SoloAdapter().spawnModels(for: SpawnChoice(id: "codex", name: "Codex"))
        case .claude: ["fable", "opus", "sonnet", "haiku"].map { SpawnChoice(id: $0, name: $0.capitalized) }
        case .opencode: []
        }
    }

    private var levels: [String] {
        switch chosen {
        case .codex: (models.first { $0.id == model } ?? models.first)?.levels.map(\.id) ?? []
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        case .opencode: []
        }
    }

    private func start() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !starting else { return }
        starting = true
        Task {
            if let id = await workspace.start(provider: chosen, cwd: project, prompt: text, model: model.isEmpty ? nil : model,
                                              effort: effort.isEmpty ? nil : effort, permissions: permissions) {
                prompt = ""
                started(id)
            }
            starting = false
        }
    }
}
