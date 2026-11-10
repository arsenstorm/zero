import SwiftUI
import ZeroCore

// Workspaces: the user's work split by who it's for (zerod's workspaces.rs). Settings › Workspaces lists them; each
// has a name and a glyph for the sidebar's heading; a task is in the one it was started in or moved to. Zero is always
// there.

struct WorkspacesPage: View {
    let workspace: Workspace?
    @State private var editing: ZerodLink.Workspace?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let workspace {
                SettingsSection(
                    title: "Workspaces", accessory: AnyView(GhostButton(title: "Add workspace", icon: "plus") { adding = true })
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(workspace.workspaces.enumerated()), id: \.element.id) { index, w in
                            if index > 0 { Divider().padding(.leading, 18) }
                            WorkspaceRow(
                                workspace: w, current: w.id == workspace.current, edit: { editing = w },
                                delete: w.id == "zero" ? nil : { Task { await workspace.deleteWorkspace(w.id) } })
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .bleedingCard()
                }
                .task(id: workspace.workspacesVersion) { await workspace.loadWorkspaces() }
                .zeroDialog(item: $editing) { w in
                    WorkspaceForm(workspace: w, model: workspace) { edited in Task { await workspace.saveWorkspace(edited) } }
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

private struct WorkspaceRow: View {
    let workspace: ZerodLink.Workspace
    let current: Bool
    let edit: () -> Void
    let delete: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceGlyph(glyph: workspace.glyph, size: 17).foregroundStyle(.secondary).frame(width: 22)
            HStack(spacing: 8) {
                Text(workspace.name).font(.system(size: 13, weight: .medium))
                if current {
                    Text("Shown").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 7).frame(
                        height: 20
                    ).background(Theme.chip, in: Capsule())
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
        .padding(.leading, 18).padding(.trailing, 10).frame(height: 48)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

/// A workspace's glyph: a Nucleo icon by name, or an emoji; Zero's mark when it has none.
struct WorkspaceGlyph: View {
    let glyph: String
    let size: CGFloat
    var body: some View {
        // Zero's mark in the box the icons beside it get, its own shape kept (a hexagon, narrower than it is tall):
        // never stretched to fill it.
        if glyph.isEmpty {
            ZeroMark(small: true).frame(width: size, height: size)
        } else if glyph.unicodeScalars.first?.properties.isEmoji == true, glyph.count <= 2 {
            Text(glyph).font(.system(size: size - 1))
        } else {
            NucleoIcon(glyph, size: size)
        }
    }
}

/// Name, icon and the MCP servers its tasks get; Save, or Cancel.
private struct WorkspaceForm: View {
    @State var workspace: ZerodLink.Workspace
    let model: Workspace
    let save: (ZerodLink.Workspace) -> Void
    @Environment(\.closeDialog) private var dismiss
    /// The servers put in this workspace, as edited here: saved with the workspace.
    @State private var servers: Set<String>?

    private var canSave: Bool { !workspace.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(text: workspace.id.isEmpty ? "New workspace" : "Edit \(workspace.name)")
            if workspace.id != "zero" {
                HStack(spacing: 8) {
                    WorkspaceGlyph(glyph: workspace.glyph, size: 16).frame(width: 30, height: 30).background(
                        Theme.row, in: RoundedRectangle(cornerRadius: 8))
                    TextField("Name", text: $workspace.name).textFieldStyle(.dialog)
                }
            }
            field("Icon") {
                // Nucleo's, as many as fit the dialog's width in a few short rows: no scroll box, nothing past the edge.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 32), spacing: 2)], alignment: .leading, spacing: 2) {
                    ForEach(Self.icons, id: \.self) { name in
                        let on = workspace.glyph == name
                        Button {
                            workspace.glyph = name
                        } label: {
                            NucleoIcon(name, size: 16).foregroundStyle(on ? .primary : .secondary)
                                .frame(width: 32, height: 32)
                                .background(on ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 0.5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Hovering(radius: 7)).tip(name)
                    }
                }
                .padding(4).background(Theme.row, in: RoundedRectangle(cornerRadius: 10))
            }
            if !workspace.id.isEmpty, !model.mcpServers.isEmpty {
                field("MCP servers") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Given to this workspace's tasks; set them up in MCP servers.").font(.system(size: 11.5)).foregroundStyle(
                            .secondary)
                        ForEach(model.mcpServers) { server in
                            if server.workspaces.isEmpty {
                                Toggle(isOn: .constant(true)) { Text(server.name + " (every workspace)").font(.system(size: 12.5)) }
                                    .toggleStyle(.dialogCheckbox).disabled(true)
                            } else {
                                Toggle(
                                    isOn: Binding(
                                        get: { servers?.contains(server.id) ?? false },
                                        set: { on in
                                            if on { servers?.insert(server.id) } else { servers?.remove(server.id) }
                                        })
                                ) { Text(server.name).font(.system(size: 12.5)) }
                                .toggleStyle(.dialogCheckbox)
                            }
                        }
                    }
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
        // A new one (or one with an emoji or Zero's mark from before) starts on the first of Nucleo's.
        .onAppear { if workspace.id != "zero" && !Self.icons.contains(workspace.glyph) { workspace.glyph = Self.icons[0] } }
        .task {
            await model.loadMcpServers()
            servers = Set(model.mcpServers.filter { $0.workspaces.contains(workspace.id) }.map(\.id))
        }
    }

    /// Each server put in or taken out of this workspace here, saved as such (its values as kept).
    private func saveServers() {
        guard let servers else { return }
        let id = workspace.id
        for var server in model.mcpServers where !server.workspaces.isEmpty && server.workspaces.contains(id) != servers.contains(server.id)
        {
            if servers.contains(server.id) { server.workspaces.append(id) } else { server.workspaces.removeAll { $0 == id } }
            // Taken out of its last workspace, a server would be everyone's: off instead.
            if server.workspaces.isEmpty { server.workspaces = [id]; server.enabled = false }
            Task { _ = await model.saveMcpServer(server, secrets: [:]) }
        }
    }

    /// Zero's own icons (Resources/nucleo), each once, by name.
    /// Icons that read as a workspace's logo: things and places, not the app's controls (arrows, headings).
    static let icons: [String] = [
        "layers", "suitcase", "house", "code", "terminal", "rocket", "star", "heart", "globe", "book", "flask", "cube",
        "chart-bar", "bug", "shield", "lock", "key", "robot", "microchip", "database", "server", "atom", "lightbulb",
        "puzzle-piece", "magnifier", "camera", "music", "headphones", "palette", "leaf", "sun", "moon", "cloud", "fire",
        "bolt-lightning", "trophy", "crown", "flag", "gift", "compass", "map-pin", "anchor", "plane", "car", "mug",
        "gamepad", "graduation-cap", "wallet", "calendar", "megaphone", "folder",
    ]

    private func field(_ label: String, @ViewBuilder content: @escaping () -> some View) -> some View {
        DialogPart(title: label, content: content)
    }
}
