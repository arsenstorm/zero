import SwiftUI
import ZeroCore

// Settings › MCP servers: servers set up once in Zero and given to every task's CLI (Claude Code, Codex, OpenCode) as
// it starts, on top of the CLI's own; each for every workspace or only those it's put in. A value (an API key, a
// header) is kept in the Keychain unless said otherwise.

struct McpServersPage: View {
    let workspace: Workspace?
    @State private var editing: ZerodLink.McpServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let workspace {
                SettingsSection(title: "Servers") {
                    VStack(spacing: 0) {
                        ForEach(Array(workspace.mcpServers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { Divider().padding(.leading, 18) }
                            row(server, in: workspace)
                        }
                        if !workspace.mcpServers.isEmpty { Divider() }
                        Button {
                            editing = ZerodLink.McpServer()
                        } label: {
                            NucleoLabel("Add a server", icon: "plus", size: 13).font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 40).contentShape(
                                    Rectangle())
                        }
                        .buttonStyle(Hovering(radius: 0))
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: workspace.mcpServers.isEmpty ? 14 : 0, bottomLeadingRadius: 14,
                                bottomTrailingRadius: 14, topTrailingRadius: workspace.mcpServers.isEmpty ? 14 : 0))
                    }
                    .bleedingCard()
                }
                .task {
                    await workspace.loadMcpServers(); await workspace.loadWorkspaces()
                }
                .zeroDialog(item: $editing) { server in McpServerForm(server: server, workspace: workspace) }
            }
        }
    }

    private func row(_ server: ZerodLink.McpServer, in workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.system(size: 13, weight: .medium))
                Text(server.url ?? ([server.command ?? ""] + server.args).joined(separator: " ")).font(
                    .system(size: 11.5, design: .monospaced)
                )
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // Where it applies: every workspace, or the ones it's in, as pills.
            HStack(spacing: 4) {
                if server.workspaces.isEmpty { pill("Every workspace") }
                ForEach(server.workspaces, id: \.self) { id in pill(workspace.workspaces.first { $0.id == id }?.name ?? id) }
            }
            Toggle(
                "",
                isOn: Binding(
                    get: { server.enabled },
                    set: { on in
                        var changed = server
                        changed.enabled = on
                        Task { _ = await workspace.saveMcpServer(changed, secrets: [:]) }
                    })
            ).toggleStyle(.switch).controlSize(.mini).labelsHidden().tip(server.enabled ? "On: given to tasks as they start" : "Off")
            Button("Edit") { editing = server }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.row, in: Capsule())
    }
}

/// A server's settings: how it runs (a command, or a URL), its values and where each is kept, and its workspaces.
private struct McpServerForm: View {
    @State var server: ZerodLink.McpServer
    let workspace: Workspace
    @Environment(\.closeDialog) private var dismiss
    @State private var remote = false
    @State private var arguments = ""
    /// Keychain values typed here, by name: saved to the Keychain, never to zerod.
    @State private var secrets: [String: String] = [:]
    @State private var problem: String?
    @State private var everywhere = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(text: server.id.isEmpty ? "Add an MCP server" : "Edit \(server.name)")
            TextField("Name (CVE lookup)", text: $server.name).textFieldStyle(.dialog)
            DialogChoice(options: [("Runs a command", false), ("At a URL", true)], selection: $remote)
            if remote {
                TextField("https://…/mcp", text: Binding(get: { server.url ?? "" }, set: { server.url = $0 })).textFieldStyle(.dialog)
                Text("One that signs in with OAuth needs no headers: its first task shows a sign-in link.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Command (npx, uvx, a path)", text: Binding(get: { server.command ?? "" }, set: { server.command = $0 }))
                    .textFieldStyle(.dialog)
                TextField("Arguments, separated by spaces", text: $arguments).textFieldStyle(.dialog)
            }
            values(remote ? "Headers" : "Environment", list: remote ? $server.headers : $server.env)
            DialogPart(title: "Workspaces") {
                Toggle("Every workspace", isOn: $everywhere).toggleStyle(.dialogCheckbox)
                if !everywhere {
                    ForEach(workspace.workspaces) { w in
                        Toggle(
                            w.name,
                            isOn: Binding(
                                get: { server.workspaces.contains(w.id) },
                                set: { on in
                                    server.workspaces.removeAll { $0 == w.id }
                                    if on { server.workspaces.append(w.id) }
                                })
                        )
                        .toggleStyle(.dialogCheckbox)
                        .padding(.leading, 24)
                    }
                }
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                if !server.id.isEmpty {
                    DialogButton(title: "Delete", kind: .destructive) {
                        Task {
                            await workspace.deleteMcpServer(server); dismiss()
                        }
                    }
                }
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Save", kind: .primary, enabled: !server.name.trimmingCharacters(in: .whitespaces).isEmpty) { save() }
            }
        }
        .frame(width: 520)
        .onAppear {
            remote = server.url != nil && server.command == nil
            arguments = server.args.joined(separator: " ")
            everywhere = server.workspaces.isEmpty
        }
    }

    /// Each value: its name, where it's kept (the Keychain unless chosen otherwise) and, unless the server's command
    /// gets it itself, the value: masked for the Keychain (left empty, the kept one stays).
    private func values(_ title: String, list: Binding<[ZerodLink.McpServer.Value]>) -> some View {
        DialogPart(title: title) {
            ForEach(list.wrappedValue.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("NAME", text: list[i].name).textFieldStyle(.dialog).frame(width: 150)
                    SettingChoice(
                        id: "mcp-value-\(i)",
                        choices: [[("Keychain", ZerodLink.McpServer.Source.keychain), ("Zero's file", .file), ("Its command", .command)]],
                        selection: list[i].from)
                    switch list.wrappedValue[i].from {
                    case .keychain:
                        SecureField(
                            server.id.isEmpty ? "Value" : "Kept (type to change)",
                            text: Binding(
                                get: { secrets[list.wrappedValue[i].name] ?? "" },
                                set: { secrets[list.wrappedValue[i].name] = $0 })
                        )
                        .textFieldStyle(.dialog)
                    case .file:
                        TextField(
                            "Value", text: Binding(get: { list.wrappedValue[i].value ?? "" }, set: { list.wrappedValue[i].value = $0 })
                        ).textFieldStyle(.dialog)
                    case .command:
                        Text("Fetched by the server itself").font(.system(size: 12)).foregroundStyle(.tertiary).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        list.wrappedValue.remove(at: i)
                    } label: {
                        NucleoIcon("xmark", size: 11).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            Button {
                list.wrappedValue.append(.init())
            } label: {
                NucleoLabel("Add", icon: "plus", size: 12).font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private func save() {
        if remote {
            server.command = nil; server.args = []; server.env = []
        } else {
            server.url = nil; server.headers = []; server.args = arguments.split(separator: " ").map(String.init)
        }
        if everywhere { server.workspaces = [] }
        server.env.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        server.headers.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let kept = Set((server.env + server.headers).filter { $0.from == .keychain }.map(\.name))
        let typed = secrets.filter { kept.contains($0.key) }
        Task {
            if let error = await workspace.saveMcpServer(server, secrets: typed) { problem = error } else { dismiss() }
        }
    }
}
