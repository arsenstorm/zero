import AppKit
import SwiftUI
import ZeroCore

// A new task: its lead session. Home, as Devin's: Zero's mark and name over a frosted composer, the project, workspace,
// agent, model, effort and permissions as chips in its row.

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
    /// Where the composer is in the window: the backdrop frosts that place, found in its own view by AppKit.
    @State private var composer = CGRect.zero
    @Environment(\.colorScheme) private var scheme

    private var chosen: Provider { Provider(rawValue: provider) ?? .codex }
    /// The workspace the task starts in: the one shown, unless picked.
    @State private var into = ""
    /// The project folders, to start in.
    private var folders: [String] { Projects.folders }

    var body: some View {
        // Devin's: the mark and name just above the composer, over the backdrop. The composer is what's centred; the
        // name hangs above it, out of the layout.
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                Composer(draft: $prompt, placeholder: "Do anything", canSend: !starting && folders.contains(project), folder: folders.contains(project) ? project : nil,
                         workspace: workspace, images: $images, send: { start() }, translucent: true) {
                    // Where it starts, as chips in the row: the folder tab that sat above the card is gone.
                    if folders.isEmpty {
                        NucleoLabel("Add a project in Settings → Projects", icon: "folder", size: 13).font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ComposerChip(id: "new.project", label: folders.contains(project) ? Projects.name(of: project) : "Choose project", symbol: "folder") {
                            ComposerRows.list("Projects", icon: choiceIcon("zero"), folders.map { folder in
                                (folder, Projects.name(of: folder), (folder as NSString).abbreviatingWithTildeInPath, folder == project, { project = folder })
                            })
                        }
                        // Started from one workspace into another: the lead is there, and so are the workers it starts.
                        if workspace.workspaces.count > 1 {
                            ComposerChip(id: "new.workspace", label: workspace.workspaces.first { $0.id == into }?.name ?? workspace.currentWorkspace.name, symbol: "layers") {
                                ComposerRows.list("Workspace", workspace.workspaces.map { w in (w.id, w.name, nil, w.id == into, { into = w.id }) })
                            }
                        }
                    }
                    // What runs it on the right, beside Send, as Devin's mode; where it runs on the left.
                    Spacer(minLength: 8)
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
                    ComposerChip(id: "new.permissions", label: permissions == .auto ? "Permissions: Auto" : "Permissions: Unrestricted",
                                 symbol: permissions == .auto ? "wand-sparkle" : "bolt-lightning:glyph", tint: permissions == .auto ? nil : .orange, iconOnly: true) {
                        ComposerRows.list("Permissions", [
                            ("auto", "Auto", "\(chosen.title) decides what's safe, and asks you the rest", permissions == .auto, { permissions = .auto }),
                            ("unrestricted", "Unrestricted", "Anything, without asking", permissions == .unrestricted, { permissions = .unrestricted }),
                        ])
                    }
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composer = $0 }
            .overlay(alignment: .topLeading) {
                // The mark centred on the name's capitals (about 20 pt tall at this size), not on its whole line.
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    ZeroMark(small: true).frame(width: 31, height: 30).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 10 }
                    Text("Zero").font(.system(size: 28, weight: .semibold))
                }
                // Lifted off the dots: a halo of the page's own colour, close and then wide.
                .shadow(color: scheme == .dark ? .black.opacity(0.85) : .white, radius: 4)
                .shadow(color: scheme == .dark ? .black.opacity(0.6) : .white.opacity(0.9), radius: 14)
                .padding(.leading, 8)
                .alignmentGuide(.top) { $0[.bottom] + 14 }
            }
            .centredColumn(680)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background {
            DitherBackground(frostInWindow: composer)
                .ignoresSafeArea()
        }
        .onAppear {
            if !folders.contains(project) { project = folders.first ?? "" }
            if let kept = Drafts.load("new") { prompt = kept.text; images = kept.images }
            // Started from something saved for later: its words, over whatever was being written.
            if let waiting = workspace.pendingDrafts.removeValue(forKey: "new") { prompt = waiting }
        }
        .onChange(of: prompt) { Drafts.save("new", text: prompt, images: images) }
        .onChange(of: images) { Drafts.save("new", text: prompt, images: images) }
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
