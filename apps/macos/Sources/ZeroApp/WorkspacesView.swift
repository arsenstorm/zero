import SwiftUI
import ZeroCore

// Workspaces: the user's work split by who it's for (zerod's workspaces.rs). Settings › Workspaces lists them; each
// has a name, a glyph for the sidebar's heading, and the folders whose tasks are its. Zero is always there.

struct WorkspacesPage: View {
    let workspace: Workspace?
    @State private var editing: ZerodLink.Workspace?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("A workspace is a view of your tasks: switch it in the sidebar's heading, and every workspace's tasks keep running. A task is in the workspace it was started in; otherwise the workspace one of whose folders holds it; otherwise Zero. A lead's workers are in its workspace wherever they run, and a task can be started into another workspace from New task.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let workspace {
                VStack(spacing: 0) {
                    ForEach(Array(workspace.workspaces.enumerated()), id: \.element.id) { index, w in
                        if index > 0 { Divider().padding(.leading, 16) }
                        WorkspaceRow(workspace: w, current: w.id == workspace.current, edit: { editing = w },
                                     delete: w.id == "zero" ? nil : { Task { await workspace.deleteWorkspace(w.id) } })
                    }
                    Divider()
                    Button { adding = true } label: {
                        NucleoLabel("Add a workspace", icon: "plus", size: 13).font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(Hovering(radius: 0))
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
                .task(id: workspace.workspacesVersion) { await workspace.loadWorkspaces() }
                .sheet(item: $editing) { w in WorkspaceForm(workspace: w, model: workspace) { edited in Task { await workspace.saveWorkspace(edited) } } }
                .sheet(isPresented: $adding) { WorkspaceForm(workspace: ZerodLink.Workspace(name: ""), model: workspace) { made in Task { await workspace.saveWorkspace(made) } } }
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

    private var detail: String {
        workspace.id == "zero" ? "Always there: tasks in no other workspace's folders"
            : workspace.folders.isEmpty ? "No folders of its own: only tasks started into it" : workspace.folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceGlyph(glyph: workspace.glyph, size: 17).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(workspace.name).font(.system(size: 13, weight: .semibold))
                    if current { Text("Shown").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 7).frame(height: 20).background(Theme.chip, in: Capsule()) }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button(action: edit) { NucleoIcon("pen", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28) }.buttonStyle(Hovering(radius: 7)).tip("Edit")
                if let delete {
                    Button(action: delete) { NucleoIcon("trash", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28) }.buttonStyle(Hovering(radius: 7)).tip("Delete: its tasks are Zero's again")
                }
            }
            .opacity(hovered ? 1 : 0)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 11)
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
        if glyph.isEmpty { ZeroMark(small: true).frame(width: size + 2, height: size + 1) }
        else if glyph.unicodeScalars.first?.properties.isEmoji == true, glyph.count <= 2 { Text(glyph).font(.system(size: size - 1)) }
        else { NucleoIcon(glyph, size: size) }
    }
}

/// Name, glyph, folders and the MCP servers its tasks get; Save, or Cancel.
private struct WorkspaceForm: View {
    @State var workspace: ZerodLink.Workspace
    let model: Workspace
    let save: (ZerodLink.Workspace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    /// The servers put in this workspace, as edited here: saved with the workspace.
    @State private var servers: Set<String>?

    private var canSave: Bool { !workspace.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(workspace.id.isEmpty ? "New workspace" : "Edit workspace").font(.system(size: 15, weight: .semibold))
            if workspace.id != "zero" {
                field("Name") { TextField("Acme", text: $workspace.name).textFieldStyle(.roundedBorder) }
            }
            field("Glyph") {
                HStack(spacing: 8) {
                    TextField("An emoji, or a Nucleo icon's name", text: $workspace.glyph).textFieldStyle(.roundedBorder)
                    WorkspaceGlyph(glyph: workspace.glyph, size: 16).foregroundStyle(.secondary).frame(width: 22)
                }
            }
            if workspace.id != "zero" {
                field("Folders") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tasks started in these folders (or under them) are this workspace's.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        ForEach(Projects.folders.filter { !workspace.folders.contains($0) } + workspace.folders, id: \.self) { path in
                            Toggle(isOn: Binding(get: { workspace.folders.contains(path) }, set: { on in
                                if on { workspace.folders.append(path) } else { workspace.folders.removeAll { $0 == path } }
                            })) { Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle) }
                            .toggleStyle(.checkbox)
                        }
                        HStack(spacing: 8) {
                            TextField("Another folder, such as ~/Documents/work", text: $folder).textFieldStyle(.roundedBorder).font(.system(size: 12))
                                .onSubmit(addFolder)
                            Button("Add", action: addFolder).disabled(folder.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            if !workspace.id.isEmpty, !model.mcpServers.isEmpty {
                field("MCP servers") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Given to this workspace's tasks as their agent starts. Set them up in Settings › MCP servers.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        ForEach(model.mcpServers) { server in
                            if server.workspaces.isEmpty {
                                Toggle(isOn: .constant(true)) { Text(server.name + " (every workspace)").font(.system(size: 12.5)) }
                                    .toggleStyle(.checkbox).disabled(true)
                            } else {
                                Toggle(isOn: Binding(get: { servers?.contains(server.id) ?? false }, set: { on in
                                    if on { servers?.insert(server.id) } else { servers?.remove(server.id) }
                                })) { Text(server.name).font(.system(size: 12.5)) }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(workspace); saveServers(); dismiss() }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20).frame(width: 440)
        .task {
            await model.loadMcpServers()
            servers = Set(model.mcpServers.filter { $0.workspaces.contains(workspace.id) }.map(\.id))
        }
    }

    /// Each server put in or taken out of this workspace here, saved as such (its values as kept).
    private func saveServers() {
        guard let servers else { return }
        let id = workspace.id
        for var server in model.mcpServers where !server.workspaces.isEmpty && server.workspaces.contains(id) != servers.contains(server.id) {
            if servers.contains(server.id) { server.workspaces.append(id) } else { server.workspaces.removeAll { $0 == id } }
            // Taken out of its last workspace, a server would be everyone's: off instead.
            if server.workspaces.isEmpty { server.workspaces = [id]; server.enabled = false }
            Task { _ = await model.saveMcpServer(server, secrets: [:]) }
        }
    }

    private func addFolder() {
        let path = ((folder.trimmingCharacters(in: .whitespaces)) as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        if !workspace.folders.contains(path) { workspace.folders.append(path) }
        folder = ""
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
