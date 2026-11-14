import SwiftUI
import ZeroCore

/// A new workspace, as a page of its own: its name, icon, colour and the MCP servers its tasks get, beside a preview of
/// how it will sit in the rail and head its sidebar; a few lines on what a workspace keeps apart. Create workspace makes
/// it, shows it and opens its New task page; Cancel or Esc goes back to where the window was.
struct NewWorkspacePage: View {
    let workspace: Workspace
    /// Made: its id, to show it.
    let created: (String) -> Void
    let cancel: () -> Void
    /// Settings › MCP servers, where a server is given to some workspaces only.
    var openServers: () -> Void = {}
    @State var draft = ZerodLink.Workspace(name: "", glyph: WorkspaceForm.icons[0])
    /// The MCP servers' switches as set here, by server.
    @State var servers: [String: Bool] = [:]
    @State private var creating = false
    @State private var problem: String?

    private var name: String { draft.name.trimmingCharacters(in: .whitespaces) }
    /// Its ⌥ number once made: the rail's next place, if one of the first nine.
    private var number: Int? { workspace.workspaces.count < 9 ? workspace.workspaces.count + 1 : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New workspace").font(.system(size: 22, weight: .semibold))
                    Text("Keep one part of your work apart from the rest, such as your own projects and your job.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 32) {
                    form.frame(width: 400)
                    VStack(alignment: .leading, spacing: 20) {
                        NewWorkspacePreview(workspace: workspace, draft: draft)
                        apart
                    }
                    .frame(width: 280)
                }
                HStack(spacing: 8) {
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red) }
                    Spacer()
                    DialogButton(title: "Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    DialogButton(title: "Create workspace", kind: .primary, enabled: !name.isEmpty && !creating, action: create)
                }
                .frame(width: 712)
            }
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .thinScrollbar()
        .task { await workspace.loadMcpServers() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            DialogPart(title: "Name") {
                TextField("Personal, a client, a side project", text: $draft.name).textFieldStyle(.dialog).firstField()
                    .onSubmit { if !name.isEmpty { create() } }
            }
            DialogPart(title: "Icon") {
                WorkspaceIconPicker(glyph: $draft.glyph)
            }
            DialogPart(title: "Colour") {
                WorkspaceColourPicker(color: $draft.color)
            }
            WorkspaceServersPicker(
                servers: workspace.mcpServers, on: $servers, workspace: "", all: workspace.workspaces.map(\.id), configure: openServers)
        }
    }

    /// What a workspace is, in a few plain lines.
    private var apart: some View {
        VStack(alignment: .leading, spacing: 12) {
            line("list-checkbox", "Its own tasks, Later, scratchpads and loops. Agents it starts work in it too.")
            line("inbox", "One Inbox for every workspace: each ask says which workspace it's from.")
            line("folder", "The same projects as your other workspaces: tasks start in any of them.")
            if let number { line("command", "\u{2325}\(number) shows it from anywhere in the window.") }
        }
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            NucleoIcon(icon, size: 14).foregroundStyle(.secondary).frame(width: 16).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func create() {
        guard !name.isEmpty, !creating else { return }
        creating = true
        Task {
            var made = draft
            made.name = name
            let before = workspace.workspaces.map(\.id)
            if let error = await workspace.saveWorkspace(made) {
                problem = error; creating = false; return
            }
            let id = workspace.current
            await WorkspaceServersPicker.save(servers, in: id, all: workspace.workspaces.map(\.id), before: before, model: workspace)
            created(id)
        }
    }
}

/// How the new workspace will look: a slice of the rail with it in place (its mark, the bar beside it), and the head
/// of its sidebar.
struct NewWorkspacePreview: View {
    let workspace: Workspace
    let draft: ZerodLink.Workspace

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 6) {
                ForEach(workspace.workspaces.suffix(2)) { space in
                    WorkspaceMark(workspace: space, size: 17).frame(width: 32, height: 32)
                }
                WorkspaceMark(workspace: draft, selected: true, size: 17).frame(width: 32, height: 32)
                    .overlay(alignment: .leading) {
                        // The rail's bar, in the workspace's colour as it is there.
                        Capsule().fill(WorkspaceColors.color(draft.color) ?? Color.primary).frame(width: 3, height: 20).offset(x: -8)
                            .animation(.easeOut(duration: 0.15), value: draft.color)
                    }
            }
            .padding(.top, 14).frame(width: 48).frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.rail)
            VStack(alignment: .leading, spacing: 1) {
                SidebarTitle(title: draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "New workspace" : draft.name)
                    .foregroundStyle(draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? .tertiary : .primary)
                    .padding(.bottom, 4)
                ForEach(
                    [("New task", "compose"), ("All tasks", "list-checkbox"), ("Later", "bookmark"), ("Scratchpads", "note-3")], id: \.0
                ) {
                    SidebarItem($0.0, icon: $0.1) {}.allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 8).padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.composer)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 1) }
        }
        .frame(height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        // It fades out at its foot: a slice, not the whole window.
        .mask(
            LinearGradient(
                stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}

/// The icon grid and the colour row: the same 11 columns, spread across their tray, so neither leaves a gap at its
/// end and their cells line up (33 icons fill three rows; none and 10 colours, one).
private let pickerColumns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 11)

/// Zero's own workspace icons (WorkspaceForm.icons), the one picked raised on the card's colour.
struct WorkspaceIconPicker: View {
    @Binding var glyph: String

    var body: some View {
        LazyVGrid(columns: pickerColumns, spacing: 2) {
            ForEach(WorkspaceForm.icons, id: \.self) { name in
                let on = glyph == name
                Button {
                    glyph = name
                } label: {
                    NucleoIcon(name, fill: on ? "glyph" : "outline", size: 16).foregroundStyle(on ? .primary : .secondary)
                        .frame(width: 32, height: 32)
                        .background(on ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Hovering(radius: 6))
            }
        }
        .padding(4).background(Theme.row, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// None, or one of the system's colours: a workspace's mark on a tile of it.
struct WorkspaceColourPicker: View {
    @Binding var color: String

    var body: some View {
        LazyVGrid(columns: pickerColumns, spacing: 2) {
            swatch("", .clear)
            ForEach(WorkspaceColors.all, id: \.name) { swatch($0.name, $0.color) }
        }
        .padding(4).background(Theme.row, in: RoundedRectangle(cornerRadius: 10))
    }

    private func swatch(_ name: String, _ tint: Color) -> some View {
        let on = color == name
        return Button {
            color = name
        } label: {
            Group {
                if name.isEmpty {
                    // None: an empty ring with a stroke across it.
                    Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                        .overlay(Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1).rotationEffect(.degrees(45)))
                        .clipShape(Circle())
                } else {
                    Circle().fill(tint.gradient)
                }
            }
            .frame(width: 16, height: 16)
            .frame(width: 32, height: 32)
            .background(on ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(Hovering(radius: 6)).tip(name.isEmpty ? "None" : name.capitalized)
    }
}

/// The MCP servers a workspace's tasks get, under a heading with Configure for Settings › MCP servers: those given to
/// some workspaces only, a row each (its name, in the primary tone and ticked while it's on here); those every
/// workspace has, not choices here, named in a line under them. None connected: a quiet row.
struct WorkspaceServersPicker: View {
    let servers: [ZerodLink.McpServer]
    /// The switches as the user has set them here, by server; the rest as each server is now.
    @Binding var on: [String: Bool]
    /// The workspace's id; empty for one not made yet, which has what every workspace has.
    let workspace: String
    /// The workspaces there are (for a new one, those there were before it): a server on in all of them is every
    /// workspace's.
    let all: [String]
    let configure: () -> Void

    var body: some View {
        // As DialogPart lays out Icon and Colour: the label, 6 pt, the tray.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("MCP servers").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                ConfigureLink(action: configure)
            }
            // By where each stood as zerod last said: those every workspace has aren't choices here, only named.
            let chosen = servers.filter { !$0.isShared(among: all) }, everywhere = servers.filter { $0.isShared(among: all) }
            if servers.isEmpty {
                Text("No MCP servers connected").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, ServerChoice.inset).frame(height: 32)
                    .padding(4).background(Theme.row, in: RoundedRectangle(cornerRadius: 10))
            } else if !chosen.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(chosen.enumerated()), id: \.element.id) { index, server in
                        ServerChoice(
                            name: server.name, first: index == 0, last: index == chosen.count - 1,
                            on: Binding(
                                get: { on[server.id] ?? server.standing(in: workspace, among: all) }, set: { on[server.id] = $0 }))
                    }
                }
                .padding(4).background(Theme.row, in: RoundedRectangle(cornerRadius: 10))
            }
            if !everywhere.isEmpty {
                // Not named one by one: which they are is Settings' (Configure), this only says they come with it.
                Text("Some MCP servers are already available in every workspace.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, chosen.isEmpty ? 0 : 2)
            }
        }
    }

    /// The switches as set here, saved: each server switched on or off in `workspace` (now made) of `all`, where that
    /// differs from what it is. `before`: the workspaces the picker went by (for a new one, those there were before it).
    static func save(_ on: [String: Bool], in workspace: String, all: [String], before: [String], model: Workspace) async {
        for var server in model.mcpServers {
            let wanted = on[server.id] ?? server.standing(in: workspace, among: before)
            guard wanted != server.isOn(in: workspace) else { continue }
            server.set(wanted, in: workspace, all: all)
            _ = await model.saveMcpServer(server, secrets: [:])
        }
    }
}

/// A server to switch on for the workspace: its name, in the primary tone with a check while it's on, the secondary
/// while it's off. Flat either way: a raised tile says "the one picked", and any number can be on. The whole row
/// switches it.
private struct ServerChoice: View {
    let name: String
    /// It starts or ends the tray: its fill takes the tray's corners there (10 less the tray's 4 of padding).
    let first: Bool
    let last: Bool
    @Binding var on: Bool
    @State private var hovered = false

    /// In from the row's edge so the name starts where the trays above start their first icon: the tray's 4 pt then
    /// half of what an 11-column cell leaves round a 16 pt icon, (392 − 20) / 11 − 16, halved: 8.9.
    static let inset: CGFloat = 9

    var body: some View {
        let top: CGFloat = first ? 6 : 0, bottom: CGFloat = last ? 6 : 0
        HStack(spacing: 8) {
            Text(name).font(.system(size: 13)).foregroundStyle(on ? .primary : .secondary).lineLimit(1)
            Spacer(minLength: 8)
            NucleoIcon("check", size: 13).foregroundStyle(.primary).opacity(on ? 1 : 0)
        }
        .padding(.horizontal, Self.inset).frame(height: 32)
        .background(
            hovered ? Theme.hover : .clear,
            in: UnevenRoundedRectangle(
                topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
        )
        .contentShape(Rectangle())
        .onTapGesture { on.toggle() }
        .onHover { hovered = $0 }
    }
}

/// The MCP heading's way to Settings › MCP servers: words the label's size, secondary, primary under the pointer.
private struct ConfigureLink: View {
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Text("Configure").font(.system(size: 12)).foregroundStyle(hovered ? .primary : .secondary)
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .onHover { hovered = $0 }
    }
}
