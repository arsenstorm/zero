import SwiftUI

/// A new task from the phone, as the Mac's New task: what to do, the folder it works in, the agent and its model; it
/// starts in the workspace shown, and opens.
struct NewTaskSheet: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newTaskFolder") private var folder = ""
    @AppStorage("newTaskProvider") private var provider = Provider.claude.rawValue
    @State private var prompt = ""
    @State private var folders: [String] = []
    @State private var models: [PhoneModel.ModelChoice] = []
    @State private var chosen: (model: String, effort: String?)?
    @State private var selecting = false
    @State private var starting = false
    @State private var problem: String?
    @FocusState private var writing: Bool

    private var agent: Provider { Provider(rawValue: provider) ?? .claude }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should it do?", text: $prompt, axis: .vertical).lineLimit(4...12).focused($writing)
                }
                Section("Folder") {
                    if folders.isEmpty {
                        Spinner().frame(width: 16, height: 16)
                    } else {
                        Picker("Folder", selection: $folder) {
                            ForEach(folders, id: \.self) { path in Text((path as NSString).lastPathComponent).tag(path) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
                Section("Agent") {
                    Picker("Agent", selection: $provider) {
                        ForEach([Provider.claude, .codex, .opencode], id: \.self) { p in Text(p.title).tag(p.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    if !models.isEmpty {
                        Button { selecting = true } label: {
                            HStack {
                                Text("Model")
                                Spacer()
                                Text(modelName).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if starting { Spinner().frame(width: 18, height: 18) } else {
                        Button("Start") { Task { await start() } }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $selecting) {
                ModelSelector(provider: agent, models: models, current: (chosen?.model ?? models.first?.id, chosen?.effort)) { m, e in chosen = (m, e) }
            }
        }
        .task {
            writing = true
            folders = await model.projects()
            if !folders.contains(folder) { folder = folders.first ?? "" }
        }
        .task(id: provider) {
            chosen = nil
            models = await model.models(agent)
        }
    }

    private var modelName: String {
        let id = chosen?.model ?? models.first?.id
        let current = models.first { $0.id == id }
        let level = chosen?.effort.flatMap { effort in current?.levels.first { $0.id == effort }?.name }
        return (current?.name ?? "Default") + (level.map { " " + $0 } ?? "")
    }

    private func start() async {
        starting = true
        defer { starting = false }
        do {
            let session = try await model.start(prompt, in: folder, with: agent, model: chosen?.model, effort: chosen?.effort)
            dismiss()
            model.tab = .tasks
            model.path = [session]
        } catch {
            problem = "Couldn't start it: \(error.localizedDescription)"
        }
    }
}
