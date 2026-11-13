import SwiftUI

/// A new task from the phone, after Linear's new issue: close on the left, the folder it works in as a pill in the
/// middle, start on the right; the words filling the page; the agent, its model and the permissions as chips riding
/// above the keyboard. It starts in the workspace shown, and opens.
struct NewTaskSheet: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newTaskFolder") private var folder = ""
    @AppStorage("newTaskProvider") private var provider = Provider.claude.rawValue
    @State private var prompt = ""
    @State private var folders: [String] = []
    @State private var chosen: (model: String, effort: String?)?
    @State private var choosing: Choice?
    @State private var selecting = false
    @State private var starting = false
    @State private var permissions = Permissions.auto
    @State private var problem: String?
    @FocusState private var writing: Bool

    private enum Choice: Hashable { case folder, permissions }
    private var agent: Provider { Provider(rawValue: provider) ?? .claude }
    private static let agents: [Provider] = [.claude, .codex, .opencode]
    @State private var catalogue: [Provider: [PhoneModel.ModelChoice]] = [:]
    /// The chosen agent's models.
    private var models: [PhoneModel.ModelChoice] { catalogue[agent] ?? [] }
    private var canStart: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folder.isEmpty && !starting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("What should it do?", text: $prompt, axis: .vertical)
                        .font(.title3).focused($writing)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
                .padding(.horizontal, 20).padding(.top, 8)
            }
            .scrollDismissesKeyboard(.never)
        }
        // Above the keyboard, as Linear's properties: what the task starts with.
        .safeAreaInset(edge: .bottom) { chips }
        .sheet(isPresented: $selecting) {
            ModelSelector(
                agents: Self.agents.map { .init(provider: $0, models: catalogue[$0] ?? []) },
                current: (agent, chosen?.model ?? models.first?.id, chosen?.effort)
            ) { picked, m, e in
                provider = picked.rawValue
                chosen = m.map { ($0, e) }
            }
        }
        .task {
            writing = true
            folders = await model.projects()
            if !folders.contains(folder) { folder = folders.first ?? "" }
        }
        // Every agent's models, for the one picker: each as it comes.
        .task {
            for agent in Self.agents { catalogue[agent] = await model.models(agent) }
        }
    }

    private var top: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                glyph("xmark-outline")
            }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Close")
            Spacer(minLength: 12)
            Button {
                choosing = .folder
            } label: {
                HStack(spacing: 8) {
                    Image("folder-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(.blue)
                    Text(folder.isEmpty ? "Folder" : (folder as NSString).lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                }
                .padding(.horizontal, 16).frame(height: 44).contentShape(Capsule())
            }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
            .popover(isPresented: Binding(get: { choosing == .folder }, set: { if !$0 { choosing = nil } })) {
                list(folders.map { ($0, ($0 as NSString).lastPathComponent) }, selected: folder) { folder = $0 }
            }
            Spacer(minLength: 12)
            Button {
                Task { await start() }
            } label: {
                Group {
                    if starting {
                        Spinner().frame(width: 18, height: 18)
                    } else {
                        glyph("arrow-up-outline").foregroundStyle(canStart ? .white : .secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .background { if canStart { Circle().fill(Color.accentColor) } }
            }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
            .disabled(!canStart)
            .accessibilityLabel("Start")
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // The agent and its model, one choice: its mark, its model's name.
                chip(modelName, icon: providerIcon) { selecting = true }
                chip(
                    permissions == .auto ? "Auto" : "Unrestricted",
                    icon: permissions == .auto ? "wand-sparkle-outline" : "bolt-lightning-glyph",
                    tint: permissions == .auto ? nil : .orange
                ) { choosing = .permissions }
                .popover(isPresented: Binding(get: { choosing == .permissions }, set: { if !$0 { choosing = nil } })) {
                    list([("auto", "Auto"), ("unrestricted", "Unrestricted")], selected: permissions == .auto ? "auto" : "unrestricted") {
                        permissions = $0 == "auto" ? .auto : .unrestricted
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private var providerIcon: String? {
        switch agent {
        case .claude: "provider-claude"
        case .codex: "provider-openai"
        default: "terminal-outline"
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(name).resizable().frame(width: 20, height: 20).frame(width: 44, height: 44).contentShape(Circle())
    }

    private func chip(_ title: String, icon: String?, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(icon).resizable().frame(width: 16, height: 16) }
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 14).frame(height: 38).contentShape(Capsule())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
    }

    /// Zero's own list (ChoiceList), closing as it's picked from.
    private func list(_ rows: [(String, String)], selected: String, pick: @escaping (String) -> Void) -> some View {
        ChoiceList(rows: rows.map { (id: $0.0, title: $0.1) }, selected: selected) {
            pick($0); choosing = nil
        }
    }

    private var modelName: String {
        let id = chosen?.model ?? models.first?.id
        let current = models.first { $0.id == id }
        let level = chosen?.effort.flatMap { effort in current?.levels.first { $0.id == effort }?.name }
        return (current?.name ?? (models.isEmpty ? agent.title : "Default")) + (level.map { " · " + $0 } ?? "")
    }

    private func start() async {
        guard canStart else { return }
        starting = true
        defer { starting = false }
        do {
            let session = try await model.start(
                prompt, in: folder, with: agent, model: chosen?.model, effort: chosen?.effort, permissions: permissions)
            dismiss()
            model.tab = .tasks
            model.path = [session]
        } catch {
            problem = "Couldn't start it: \(error.localizedDescription)"
        }
    }
}
