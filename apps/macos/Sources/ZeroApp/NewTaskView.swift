import AppKit
import SwiftUI
import ZeroCore

// A new task: its lead session. Home, as ChatGPT's: a greeting in the middle, the composer at the foot with the
// project above it and the agent, model, effort and permissions in its row.

struct NewTaskView: View {
    let workspace: Workspace
    let started: (String) -> Void
    @AppStorage("workspaceProvider") private var provider = Provider.codex.rawValue
    @AppStorage("workspaceProject") private var project = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var permissions = Permissions.auto
    @State private var prompt = ""
    @State private var images: [URL] = []
    @State private var starting = false

    private var chosen: Provider { Provider(rawValue: provider) ?? .codex }
    /// The workspace the task starts in: the one shown, unless picked.
    @State private var into = ""
    /// The workspace's own folders first, then the rest (Zero's are those no other claims).
    private var folders: [String] {
        let owned = workspace.workspaces.first { $0.id == (into.isEmpty ? workspace.current : into) }?.folders ?? []
        let all = Projects.folders
        return owned.filter(all.contains) + all.filter { !owned.contains($0) }
    }

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
                Composer(draft: $prompt, placeholder: "Do anything", canSend: !starting && folders.contains(project), folder: folders.contains(project) ? project : nil,
                         workspace: workspace, images: $images) { start() } controls: {
                    ComposerChip(id: "new.agent", label: agentLabel, symbol: "terminal", icon: chosen.mark, kind: .runtime, prominent: true, rows: {
                        ComposerRows.models(Provider.allCases, selected: { provider, id in
                            // Nothing picked: the provider's first, except OpenCode's, whose default is its own config's.
                            provider == chosen && (id == model || (model.isEmpty && provider != .opencode && id == (ComposerRows.catalogue(provider).first?.id ?? "")))
                        }, pick: { picked, choice in
                            provider = picked.rawValue
                            model = choice.id
                            if !choice.levels.contains(where: { $0.id == effort }) { effort = "" }
                        })
                    }, level: { id in id == "\(chosen.rawValue)/\(model)" && !effort.isEmpty ? effort : nil }, setLevel: { _, level in effort = level })
                    ComposerChip(id: "new.permissions", label: permissions == .auto ? "Auto" : "Unrestricted",
                                 symbol: permissions == .auto ? "wand-sparkle" : "bolt-lightning:glyph", tint: permissions == .auto ? nil : .orange) {
                        ComposerRows.list("Permissions", [
                            ("auto", "Auto", "\(chosen.title) decides what's safe, and asks you the rest", permissions == .auto, { permissions = .auto }),
                            ("unrestricted", "Unrestricted", "Anything, without asking", permissions == .unrestricted, { permissions = .unrestricted }),
                        ])
                    }
                }
            }
            // A task's composer's column and place: the same width, as far from the window's foot.
            .centredColumn(680)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if !folders.contains(project) { project = folders.first ?? "" }
            if let kept = Drafts.load("new") { prompt = kept.text; images = kept.images }
            // Started from something saved for later: its words, over whatever was being written.
            if let waiting = workspace.pendingDrafts.removeValue(forKey: "new") { prompt = waiting }
        }
        .onChange(of: prompt) { Drafts.save("new", text: prompt, images: images) }
        .onChange(of: images) { Drafts.save("new", text: prompt, images: images) }
    }

    /// The folder it starts in, as a tab behind the composer's top edge.
    @ViewBuilder private var projectTab: some View {
        HStack {
            if folders.isEmpty {
                NucleoLabel("Add a project in Settings → Projects", icon: "folder", size: 13).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
            } else {
                ComposerChip(id: "new.project", label: folders.contains(project) ? (project as NSString).lastPathComponent : "Choose project", symbol: "folder") {
                    ComposerRows.list("Projects", icon: choiceIcon("zero"), folders.map { folder in
                        (folder, (folder as NSString).lastPathComponent, (folder as NSString).abbreviatingWithTildeInPath, folder == project, { project = folder })
                    })
                }
                // Started from one workspace into another: the lead is there, and so are the workers it starts.
                if workspace.workspaces.count > 1 {
                    ComposerChip(id: "new.workspace", label: workspace.workspaces.first { $0.id == into }?.name ?? workspace.currentWorkspace.name, symbol: "layers") {
                        ComposerRows.list("Workspace", workspace.workspaces.map { w in (w.id, w.name, nil, w.id == into, { into = w.id }) })
                    }
                }
            }
            Spacer()
        }
        .font(.system(size: 12))
        // Codex's tab: flat grey, no edge, a little in from the card's sides; the card's shadow gives it depth.
        .padding(.horizontal, 7).padding(.top, 8).padding(.bottom, 16)
        .background(Theme.fieldTab, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous))
        .padding(.horizontal, 13).padding(.bottom, -12)
    }

    /// "Opus 5.5 · High": the model, its provider as the chip's icon. None picked, the provider's first; a provider with
    /// no catalogue (OpenCode) by its name.
    private var agentLabel: String {
        [models.first { $0.id == model }?.name ?? (model.isEmpty ? (chosen == .opencode ? nil : models.first?.name) ?? chosen.title : model), effort.isEmpty ? nil : effortLabel(effort, short: true)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The chosen provider's models, from its CLI's own cache.
    private var models: [SpawnChoice] { ComposerRows.catalogue(chosen) }

    private func start() {
        let (text, attached) = ImageToken.compact(prompt.trimmingCharacters(in: .whitespacesAndNewlines), images: images.map(\.path))
        guard !text.isEmpty || !attached.isEmpty, !starting else { return }
        starting = true
        Task {
            // The model the chip shows: none picked, it shows the provider's first, so that's the one asked for. Left
            // to itself the provider would start on its own default, and the task would change model as it began.
            let shown = model.isEmpty ? (models.first?.id ?? "") : model
            if let id = await workspace.start(provider: chosen, cwd: project, prompt: text, images: attached, model: shown.isEmpty ? nil : shown,
                                              effort: effort.isEmpty ? nil : effort, permissions: permissions, workspace: into.isEmpty ? workspace.current : into) {
                prompt = ""
                images = []
                into = ""
                started(id)
            }
            starting = false
        }
    }
}

/// The system's blur of what's behind the window (a sidebar's material), solid when the window isn't the active one.
/// In full screen there's nothing behind it to blur (it comes out black), so it's solid there too.
struct BehindWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> Blur { Blur() }
    func updateNSView(_ view: Blur, context: Context) {}

    final class Blur: NSVisualEffectView {
        private var watching: [Any] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            material = .sidebar
            blendingMode = .behindWindow
            state = .followsWindowActiveState
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching.forEach(NotificationCenter.default.removeObserver)
            watching = []
            guard let window else { return }
            let update = { [weak self, weak window] in
                guard let self, let window else { return }
                state = window.styleMask.contains(.fullScreen) ? .inactive : .followsWindowActiveState
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                watching.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in MainActor.assumeIsolated(update) })
            }
            update()
        }
    }
}
