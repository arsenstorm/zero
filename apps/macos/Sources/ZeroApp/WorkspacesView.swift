import SwiftUI
import ZeroCore

// Workspaces: the user's work split by who it's for (zerod's workspaces.rs). Settings › Workspaces lists them; each
// has a name, a glyph and maybe a colour for its mark in the rail; a task is in the one it was started in or moved to.
// Zero is always there.

struct WorkspacesPage: View {
    let workspace: Workspace?
    /// Settings › MCP servers, from a workspace's form.
    var openServers: () -> Void = {}
    @State private var editing: ZerodLink.Workspace?
    @State private var adding = false
    /// The row being dragged and how far: the others make way, and it lands where it's let go, in the rail's order too.
    @State private var drag: (id: String, y: CGFloat)?
    private static let step: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let workspace {
                SettingsSection(
                    title: "Workspaces", accessory: AnyView(GhostButton(title: "Add workspace", icon: "plus") { adding = true })
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(workspace.workspaces.enumerated()), id: \.element.id) { index, w in
                            let moving = drag?.id == w.id
                            WorkspaceRow(
                                workspace: w, current: w.id == workspace.current, edit: { editing = w },
                                delete: w.id == "zero" ? nil : { Task { await workspace.deleteWorkspace(w.id) } }
                            )
                            // Its line above it, drawn on it (no height of its own), so a row moves with its line.
                            .overlay(alignment: .top) { if index > 0 && !moving { Hairline().padding(.horizontal, 18) } }
                            .background(moving ? Theme.card : .clear)
                            .offset(y: moving ? drag?.y ?? 0 : shift(of: w.id, in: workspace))
                            .animation(moving ? nil : Motion.animation(.easeOut(duration: 0.2)), value: dropIndex(in: workspace))
                            .zIndex(moving ? 1 : 0)
                            .gesture(
                                DragGesture(minimumDistance: 4)
                                    .onChanged { change in
                                        // Within the card: from the top row's place to the last's.
                                        let low = -CGFloat(index) * Self.step,
                                            high = CGFloat(workspace.workspaces.count - 1 - index) * Self.step
                                        drag = (w.id, min(max(change.translation.height, low), high))
                                    }
                                    .onEnded { _ in land(in: workspace) })
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .bleedingCard()
                }
                .task(id: workspace.workspacesVersion) { await workspace.loadWorkspaces() }
                .zeroDialog(item: $editing) { w in
                    WorkspaceForm(
                        workspace: w, model: workspace, save: { edited in Task { await workspace.saveWorkspace(edited) } },
                        openServers: openServers)
                }
                .zeroDialog(isPresented: $adding) {
                    WorkspaceForm(workspace: ZerodLink.Workspace(name: ""), model: workspace) { made in
                        Task { await workspace.saveWorkspace(made) }
                    }
                }
            }
        }
    }
}

extension WorkspacesPage {
    /// Where the dragged row would land now: past each row whose middle it has crossed.
    private func dropIndex(in model: Workspace) -> Int? {
        let ids = model.workspaces.map(\.id)
        guard let drag, let from = ids.firstIndex(of: drag.id) else { return nil }
        return min(max(from + Int((drag.y / Self.step).rounded()), 0), ids.count - 1)
    }

    private func shift(of id: String, in model: Workspace) -> CGFloat {
        let ids = model.workspaces.map(\.id)
        guard let drag, drag.id != id, let from = ids.firstIndex(of: drag.id), let to = dropIndex(in: model), let i = ids.firstIndex(of: id)
        else { return 0 }
        if from < to, i > from, i <= to { return -Self.step }
        if to < from, i >= to, i < from { return Self.step }
        return 0
    }

    private func land(in model: Workspace) {
        guard let drag else { return }
        var ids = model.workspaces.map(\.id)
        let to = dropIndex(in: model)
        withAnimation(Motion.animation(.easeOut(duration: 0.2))) {
            if let from = ids.firstIndex(of: drag.id), let to, to != from {
                ids.remove(at: from)
                ids.insert(drag.id, at: to)
                model.reorderWorkspaces(ids)
            }
            self.drag = nil
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: ZerodLink.Workspace
    let current: Bool
    let edit: () -> Void
    let delete: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceMark(workspace: workspace, size: 15).frame(width: 28)
            HStack(spacing: 8) {
                Text(workspace.name).font(.system(size: 13, weight: .medium))
                if current {
                    Text("Shown").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.chip, in: Capsule())
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button(action: edit) { NucleoIcon("pen", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28) }.buttonStyle(
                    Hovering(radius: 7)
                ).tip("Edit")
                if let delete {
                    Button(action: delete) { NucleoIcon("trash", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28) }
                        .buttonStyle(Hovering(radius: 7)).tip("Delete: its tasks are Zero's again")
                }
            }
            .opacity(hovered ? 1 : 0)
        }
        .padding(.leading, 18).padding(.trailing, 10).frame(height: 44)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

/// A workspace's glyph: a Nucleo icon by name, or an emoji; Zero's mark when it has none.
struct WorkspaceGlyph: View {
    let glyph: String
    let size: CGFloat
    var stroke: CGFloat? = nil
    /// "glyph" for the filled form, where the icon has one (Zero's mark and an emoji have only theirs).
    var fill = "outline"

    static func isEmoji(_ glyph: String) -> Bool { glyph.unicodeScalars.first?.properties.isEmoji == true && glyph.count <= 2 }

    var body: some View {
        // Zero's mark in the box the icons beside it get, its own shape kept (a hexagon, narrower than it is tall):
        // never stretched to fill it.
        if glyph.isEmpty {
            ZeroMark(small: true).frame(width: size, height: size)
        } else if Self.isEmoji(glyph) {
            Text(glyph).font(.system(size: size - 1))
        } else {
            // An icon no longer bundled (since taken out of the palette) draws the palette's first, not a blank.
            let known = Nucleo.url(glyph) != nil
            NucleoIcon(known ? glyph : WorkspaceForm.icons[0], fill: fill, size: size, stroke: stroke)
        }
    }
}

/// A workspace in the rail: its glyph as the rail's icons are drawn, or, with a colour of its own, the glyph in white
/// on a tile of that colour. One mark either way, so a colour picked (or taken off) crossfades in: the tile from clear,
/// the glyph's tone with it. Selected with no colour, its glyph is the filled one, as the rail's marked items are,
/// crossfading from the outline.
struct WorkspaceMark: View {
    let workspace: ZerodLink.Workspace
    var selected = false
    var size: CGFloat = 17

    var body: some View {
        let tint = WorkspaceColors.color(workspace.color)
        let filled = selected
        ZStack {
            WorkspaceGlyph(glyph: workspace.glyph, size: size).opacity(filled ? 0 : 1)
            WorkspaceGlyph(glyph: workspace.glyph, size: size, fill: "glyph").opacity(filled ? 1 : 0)
        }
        .foregroundStyle(tint != nil ? Color.white : selected ? Color.primary : Color.secondary)
        .frame(width: size + 13, height: size + 13)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(tint ?? .clear)
                // The system gradient's light at the top, as `.gradient` draws it, there only with a colour.
                .overlay(
                    LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).opacity(tint == nil ? 0 : 1))
        }
        // A fade, not a move: kept under Reduce Motion.
        .animation(.easeOut(duration: 0.15), value: workspace.color)
        .animation(.easeOut(duration: 0.15), value: filled)
    }
}

/// The colours a workspace's mark can take, by the name zerod keeps: the system's, so each suits light and dark.
enum WorkspaceColors {
    static let all: [(name: String, color: Color)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green), ("teal", .teal), ("blue", .blue),
        ("indigo", .indigo), ("purple", .purple), ("pink", .pink), ("gray", .gray),
    ]
    static func color(_ name: String) -> Color? { all.first { $0.name == name }?.color }
}

/// Name, icon, colour and the MCP servers its tasks get; Save, or Cancel.
struct WorkspaceForm: View {
    @State var workspace: ZerodLink.Workspace
    let model: Workspace
    let save: (ZerodLink.Workspace) -> Void
    /// Settings › MCP servers, where a server is given to some workspaces only.
    var openServers: () -> Void = {}
    @Environment(\.closeDialog) private var dismiss
    /// The MCP servers' switches as set here, by server: saved with the workspace.
    @State private var servers: [String: Bool] = [:]

    private var canSave: Bool { !workspace.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(text: workspace.id.isEmpty ? "New workspace" : "Edit \(workspace.name)")
            if workspace.id != "zero" {
                HStack(spacing: 8) {
                    WorkspaceMark(workspace: workspace, selected: true, size: 17).frame(width: 30, height: 30).background(
                        workspace.color.isEmpty ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 8))
                    TextField("Name", text: $workspace.name).textFieldStyle(.dialog).firstField()
                }
            }
            field("Icon") {
                WorkspaceIconPicker(glyph: $workspace.glyph)
            }
            field("Colour") { WorkspaceColourPicker(color: $workspace.color) }
            // Before it's made, a workspace has no id for a server to be given to: the New workspace page gives them.
            if !workspace.id.isEmpty {
                WorkspaceServersPicker(servers: model.mcpServers, on: $servers, workspace: workspace.id, all: model.workspaces.map(\.id)) {
                    dismiss()
                    openServers()
                }
            }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Save", kind: .primary, enabled: canSave) {
                    save(workspace); saveServers(); dismiss()
                }
            }
        }
        .frame(width: 400)
        // A new one (or one with Zero's mark, or an icon since taken out) starts on the first of Nucleo's; an emoji stays.
        .onAppear {
            if workspace.id != "zero" && !Self.icons.contains(workspace.glyph) && !WorkspaceGlyph.isEmoji(workspace.glyph) {
                workspace.glyph = Self.icons[0]
            }
        }
        .task { await model.loadMcpServers() }
    }

    private func saveServers() {
        let (on, id, model) = (servers, workspace.id, model)
        let all = model.workspaces.map(\.id)
        Task { await WorkspaceServersPicker.save(on, in: id, all: all, before: all, model: model) }
    }

    /// Zero's own icons, each once, by name.
    /// Icons that read as a workspace's logo: things and places, not the app's controls (arrows, headings).
    static let icons: [String] = [
        "layers", "suitcase", "house-4", "code", "terminal", "rocket", "globe", "shield", "lock", "key", "robot", "server",
        "folder", "brain", "puzzle-piece", "magnifier", "bolt-lightning", "sparkle", "wand-sparkle", "moon", "code-branch",
        "paper-plane", "bookmark", "note-3", "eye", "mobile", "monitor", "crown", "fire", "graduation-cap", "heart",
        "city-building", "book-open",
    ]

    private func field(_ label: String, @ViewBuilder content: @escaping () -> some View) -> some View {
        DialogPart(title: label, content: content)
    }
}
