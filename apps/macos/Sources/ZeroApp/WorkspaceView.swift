import AppKit
import SwiftUI
import ZeroCore

/// The workspace window: zerod's sessions by project on the left, the selected conversation on the right, and a
/// new session's composer when none is selected. Everything comes from `Workspace`; nothing here knows a provider's
/// protocol.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @State private var selected: String?

    var body: some View {
        NavigationSplitView {
            Sidebar(workspace: workspace, selected: $selected)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = selected, let conversation = workspace.conversation(id) {
                ConversationView(workspace: workspace, conversation: conversation).id(id)
            } else {
                NewSessionView(workspace: workspace, started: { selected = $0 })
            }
        }
        .overlay(alignment: .bottom) {
            if let error = workspace.lastError {
                Text(error).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.redRow, in: Capsule()).padding(16)
                    .onTapGesture { workspace.lastError = nil }
            }
        }
    }
}

private struct Sidebar: View {
    let workspace: Workspace
    @Binding var selected: String?

    /// Sessions grouped by their project's folder, newest project first as zerod sent them; a lead's workers follow it.
    private var projects: [(folder: String, sessions: [Conversation])] {
        var groups: [(String, [Conversation])] = []
        let all = workspace.conversations
        let leads = all.filter { lead in lead.parent == nil || !all.contains { $0.id == lead.parent } }
        for conversation in leads {
            if let i = groups.firstIndex(where: { $0.0 == conversation.cwd }) { groups[i].1.append(conversation) }
            else { groups.append((conversation.cwd, [conversation])) }
        }
        return groups.map { group in
            (folder: group.0, sessions: group.1.reversed().flatMap { lead in [lead] + all.filter { $0.parent == lead.id } })
        }.reversed()
    }

    var body: some View {
        List(selection: $selected) {
            Button { selected = nil } label: { Label("New session", systemImage: "square.and.pencil") }
                .buttonStyle(.plain).padding(.vertical, 2)
            ForEach(projects, id: \.folder) { project in
                Section((project.folder as NSString).lastPathComponent) {
                    ForEach(project.sessions) { conversation in
                        SessionRow(conversation: conversation).tag(conversation.id).padding(.leading, conversation.parent == nil ? 0 : 14)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if !workspace.connected {
                    Label("Connecting to Zero's daemon…", systemImage: "bolt.horizontal").font(.caption).foregroundStyle(.secondary)
                }
                // What each provider last said about its limits.
                ForEach(workspace.usage, id: \.0) { provider, usage in
                    Text("\(provider.title)  " + usage.windows.map { "\($0.name) \(Int(($0.used * 100).rounded()))%" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(usage.limited ? Color.orange : .secondary).lineLimit(1)
                }
            }
            .padding(10)
        }
    }
}

private struct SessionRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(Workspace.label(of: conversation)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        [conversation.ticket, conversation.provider.title, conversation.model, conversation.branch].compactMap { $0 }.joined(separator: " · ")
    }

    /// The bar's colours: orange it needs you, blue it works, green it is idle with an answer, grey offline.
    private var color: Color {
        if !conversation.approvals.isEmpty { return .orange }
        switch conversation.status {
        case .working, .starting: return .blue
        case .waiting: return .orange
        case .idle: return conversation.error == nil ? .green : .red
        case .offline: return .gray
        }
    }
}

// The conversation.

private struct ConversationView: View {
    let workspace: Workspace
    let conversation: Conversation
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if let health { Label(health.text, systemImage: health.icon).font(.callout).foregroundStyle(health.color)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8).background(health.color.opacity(0.08)) }
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
                    .padding(20)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: conversation.seq) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Composer(draft: $draft, placeholder: placeholder, canSend: conversation.status != .starting) {
                let text = draft
                draft = ""
                Task { await workspace.send(conversation.id, text: text) }
            }
        }
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
                Text(Workspace.label(of: conversation)).font(.headline).lineLimit(1)
                Text([conversation.provider.title, conversation.model, conversation.effort, conversation.permissions == .unrestricted ? "unrestricted" : nil,
                      usage, (conversation.cwd as NSString).abbreviatingWithTildeInPath]
                    .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        .padding(.horizontal, 20).padding(.vertical, 12)
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

private struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    var canSend = true
    let send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical).textFieldStyle(.plain).lineLimit(1...10)
                .onSubmit { if canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send() } }
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12).background(Theme.composer, in: RoundedRectangle(cornerRadius: 14))
        .padding(16)
    }
}

// A new session.

private struct NewSessionView: View {
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
        VStack(alignment: .leading, spacing: 18) {
            Text("New session").font(.largeTitle.weight(.semibold))
            Picker("Agent", selection: $provider) {
                ForEach(Provider.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().onChange(of: provider) { model = ""; effort = "" }
            if folders.isEmpty {
                Text("Add a project folder in Settings → Projects to start a session in it.").foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $project) {
                    ForEach(folders, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                }
            }
            HStack {
                modelField
                Picker("Effort", selection: $effort) {
                    Text("Default").tag("")
                    ForEach(levels, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .disabled(levels.isEmpty).frame(maxWidth: 220)
            }
            Picker("Permissions", selection: $permissions) {
                Text("Auto: \(chosen.title) decides what's safe, and asks you the rest").tag(Permissions.auto)
                Text("Unrestricted: anything, without asking").tag(Permissions.unrestricted)
            }
            .pickerStyle(.radioGroup)
            Composer(draft: $prompt, placeholder: "What should \(chosen.title) do?", canSend: !starting && folders.contains(project)) { start() }
                .padding(-16)
            Spacer()
        }
        .padding(32).frame(maxWidth: 720)
        .onAppear { if !folders.contains(project) { project = folders.first ?? "" } }
    }

    @ViewBuilder private var modelField: some View {
        let known = models
        if known.isEmpty {
            TextField("Model (\(chosen.title)'s default)", text: $model)
        } else {
            Picker("Model", selection: $model) {
                Text("Default").tag("")
                ForEach(known, id: \.id) { Text($0.name).tag($0.id) }
            }
        }
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
