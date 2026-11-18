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
    /// The model Claude Code consults ("fable"); "" for none.
    @State private var advisor = ""
    @State private var permissions = Permissions.auto
    @State private var prompt = ""
    @State private var images: [URL] = []
    @State private var starting = false
    /// Where the composer is in the window: the backdrop frosts that place, found in its own view by AppKit.
    @State private var composer = CGRect.zero
    @Environment(\.colorScheme) private var scheme

    private var chosen: Provider { Provider(rawValue: provider) ?? .codex }
    /// The workspace the task starts in: the one shown, unless picked.
    /// The project folders, to start in.
    private var folders: [String] { Projects.folders }

    var body: some View {
        // Devin's: the mark and name just above the composer, over the backdrop. The composer is what's centred; the
        // name hangs above it, out of the layout.
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                Composer(
                    draft: $prompt, placeholder: "Do anything", canSend: !starting,
                    folder: folders.contains(project) ? project : nil,
                    workspace: workspace, images: $images, send: { start() }, translucent: true
                ) {
                    // Where it starts: a project picked here, else a new folder of its own in ~/Zero (zerod makes it).
                    ComposerChip(
                        id: "new.project", label: folders.contains(project) ? Projects.name(of: project) : "Select folder",
                        symbol: "folder", kind: .menu
                    ) {
                        ZeroContextMenu.sections(
                            [
                                folders.map { folder in
                                    var item = MenuItem(Projects.name(of: folder), "folder") { project = folder }
                                    item.selected = folder == project
                                    return item
                                },
                                [
                                    {
                                        var item = MenuItem("New folder in ~/Zero", "folder-plus") { project = "" }
                                        item.selected = !folders.contains(project)
                                        return item
                                    }(),
                                    MenuItem("Add folder…", "plus") { addFolder() },
                                ],
                            ].filter { !$0.isEmpty })
                    }
                    // What runs it on the right, beside Send, as Devin's mode; where it runs on the left.
                    Spacer(minLength: 8)
                    ComposerChip(
                        id: "new.agent", label: agentLabel, symbol: "terminal", icon: chosen.mark, kind: .runtime, prominent: true,
                        rows: {
                            ComposerRows.models(
                                Provider.allCases,
                                selected: { provider, id in
                                    // Nothing picked: the provider's first, except OpenCode's, whose default is its own config's.
                                    provider == chosen
                                        && (id == model
                                            || (model.isEmpty && provider != .opencode
                                                && id == (ComposerRows.catalogue(provider).first?.id ?? "")))
                                },
                                pick: { picked, choice in
                                    // Onto another CLI: the advisor kept for it (Claude's, Fable at first).
                                    if picked != chosen {
                                        advisor = NewTaskChoice.kept(for: picked).advisor
                                        permissions = NewTaskChoice.permissions(for: picked)
                                    }
                                    provider = picked.rawValue
                                    model = choice.id
                                    if !choice.levels.contains(where: { $0.id == effort }) { effort = "" }
                                    if !ClaudeModels.advisors(for: shownModel).contains(where: { $0.id == advisor }) { advisor = "" }
                                    NewTaskChoice.keep(chosen, model: model, effort: effort, advisor: advisor)
                                })
                        }, level: { id in id == "\(chosen.rawValue)/\(shownModel)" && !effort.isEmpty ? effort : nil },
                        setLevel: { _, level in
                            effort = level
                            NewTaskChoice.keep(chosen, model: model, effort: effort, advisor: advisor)
                        },
                        advisor: { id in id == "\(chosen.rawValue)/\(shownModel)" ? advisor : nil },
                        setAdvisor: { _, picked in advisor = picked })
                    ComposerChip(
                        id: "new.permissions", label: permissions == .auto ? "Permissions: Auto" : "Permissions: Unrestricted",
                        symbol: permissions == .auto ? "wand-sparkle" : "bolt-lightning:glyph", tint: permissions == .auto ? nil : .orange,
                        iconOnly: true
                    ) {
                        ComposerRows.list(
                            "Permissions",
                            [
                                (
                                    "auto", "Auto", "\(chosen.title) decides what's safe, and asks you the rest", permissions == .auto,
                                    { pick(.auto) }
                                ),
                                (
                                    "unrestricted", "Unrestricted", "Anything, without asking", permissions == .unrestricted,
                                    { pick(.unrestricted) }
                                ),
                            ])
                    }
                }
                // Starting a task is the user's: an agent starts one with zero spawn, never through the desktop tools.
                .agentProof()
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                composer = $0
            }
            .overlay(alignment: .topLeading) {
                // The mark centred on the name's capitals (about 20 pt tall at this size), not on its whole line.
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    ZeroMark(small: true).frame(width: 31, height: 30).alignmentGuide(.firstTextBaseline) {
                        $0[VerticalAlignment.center] + 10
                    }
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
            if !folders.contains(project) { project = "" }
            (model, effort, advisor) = NewTaskChoice.kept(for: chosen)
            permissions = NewTaskChoice.permissions(for: chosen)
            if let kept = Drafts.load("new") { prompt = kept.text; images = kept.images }
            // Started from something saved for later: its words, over whatever was being written.
            if let waiting = workspace.pendingDrafts.removeValue(forKey: "new") { prompt = waiting }
        }
        .onChange(of: prompt) { Drafts.save("new", text: prompt, images: images) }
        .onChange(of: images) { Drafts.save("new", text: prompt, images: images) }
    }

    /// "Opus 5.5 · High", or "Opus 5.5 + Fable" with an advisor: the model, its provider as the chip's icon. None picked,
    /// the provider's first; a provider with no catalogue (OpenCode) by its name.
    private var agentLabel: String {
        ModelNames.agent(
            models.first { $0.id == model }?.name
                ?? (model.isEmpty ? (chosen == .opencode ? nil : models.first?.name) ?? chosen.title : ModelNames.readable(model)),
            effort: effort.isEmpty ? nil : effortLabel(effort, short: true), advisor: startAdvisor)
    }

    /// The model the chip shows: none picked, the provider's first.
    private var shownModel: String { model.isEmpty ? (models.first?.id ?? "") : model }
    /// The advisor it starts with: Claude's only, and only one the shown model can have.
    private var startAdvisor: String? {
        chosen == .claude && ClaudeModels.advisors(for: shownModel).contains { $0.id == advisor } ? advisor : nil
    }

    /// The chosen provider's models, from its CLI's own cache.
    private var models: [SpawnChoice] { ComposerRows.catalogue(chosen) }

    /// A folder from Finder's panel: a project from now on (as Settings › Workspaces adds one), and this task's.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Projects.add(url.path)
        project = url.path
    }

    private func pick(_ picked: Permissions) {
        permissions = picked
        NewTaskChoice.keep(chosen, permissions: picked)
    }

    private func start() {
        let (text, attached) = ImageToken.outgoing(prompt.trimmingCharacters(in: .whitespacesAndNewlines), images: images.map(\.path))
        guard !text.isEmpty || !attached.isEmpty, !starting else { return }
        starting = true
        Task {
            // The model the chip shows: none picked, it shows the provider's first, so that's the one asked for. Left
            // to itself the provider would start on its own default, and the task would change model as it began.
            let shown = shownModel
            if let id = await workspace.start(
                provider: chosen, cwd: folders.contains(project) ? project : nil, prompt: text, images: attached,
                model: shown.isEmpty ? nil : shown,
                effort: effort.isEmpty ? nil : effort, advisor: startAdvisor, permissions: permissions,
                workspace: workspace.current)
            {
                // Cleared here, not left to onChange(of: prompt): started(id) takes this view away in the same update,
                // and a view gone before its onChange runs never saves the empty box, so the sent prompt came back.
                Drafts.save("new", text: "", images: [])
                prompt = ""
                images = []
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
                watching.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                        MainActor.assumeIsolated(update)
                    })
            }
            update()
        }
    }
}
