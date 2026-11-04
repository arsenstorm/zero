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
            Text("Servers every task gets, whichever its agent; or only a workspace's.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let workspace {
                VStack(spacing: 0) {
                    ForEach(Array(workspace.mcpServers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Divider().padding(.leading, 16) }
                        row(server, in: workspace)
                    }
                    if !workspace.mcpServers.isEmpty { Divider() }
                    Button { editing = ZerodLink.McpServer() } label: {
                        NucleoLabel("Add a server", icon: "plus", size: 13).font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(Hovering(radius: 0))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: workspace.mcpServers.isEmpty ? 14 : 0, bottomLeadingRadius: 14,
                                                      bottomTrailingRadius: 14, topTrailingRadius: workspace.mcpServers.isEmpty ? 14 : 0))
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
                .task { await workspace.loadMcpServers(); await workspace.loadWorkspaces() }
                .sheet(item: $editing) { server in McpServerForm(server: server, workspace: workspace) }
            }
        }
    }

    private func row(_ server: ZerodLink.McpServer, in workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.system(size: 13, weight: .medium))
                Text(server.url ?? ([server.command ?? ""] + server.args).joined(separator: " ")).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // Where it applies: every workspace, or the ones it's in, as pills.
            HStack(spacing: 4) {
                if server.workspaces.isEmpty { pill("Every workspace") }
                ForEach(server.workspaces, id: \.self) { id in pill(workspace.workspaces.first { $0.id == id }?.name ?? id) }
            }
            Toggle("", isOn: Binding(get: { server.enabled }, set: { on in
                var changed = server
                changed.enabled = on
                Task { _ = await workspace.saveMcpServer(changed, secrets: [:]) }
            })).toggleStyle(.switch).controlSize(.mini).labelsHidden().tip(server.enabled ? "On: given to tasks as they start" : "Off")
            Button("Edit") { editing = server }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
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
    @Environment(\.dismiss) private var dismiss
    @State private var remote = false
    @State private var arguments = ""
    /// Keychain values typed here, by name: saved to the Keychain, never to zerod.
    @State private var secrets: [String: String] = [:]
    @State private var problem: String?
    @State private var everywhere = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(server.id.isEmpty ? "Add an MCP server" : "Edit \(server.name)").font(.system(size: 15, weight: .semibold))
            TextField("Name (CVE lookup)", text: $server.name).textFieldStyle(.roundedBorder)
            Picker("", selection: $remote) {
                Text("Runs a command").tag(false)
                Text("At a URL").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            if remote {
                TextField("https://…/mcp", text: Binding(get: { server.url ?? "" }, set: { server.url = $0 })).textFieldStyle(.roundedBorder)
                Text("One that signs in with OAuth needs no headers: its first task shows a sign-in link.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Command (npx, uvx, a path)", text: Binding(get: { server.command ?? "" }, set: { server.command = $0 })).textFieldStyle(.roundedBorder)
                TextField("Arguments, separated by spaces", text: $arguments).textFieldStyle(.roundedBorder)
            }
            values(remote ? "Headers" : "Environment", list: remote ? $server.headers : $server.env)
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspaces").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Toggle("Every workspace", isOn: $everywhere)
                if !everywhere {
                    ForEach(workspace.workspaces) { w in
                        Toggle(w.name, isOn: Binding(get: { server.workspaces.contains(w.id) }, set: { on in
                            server.workspaces.removeAll { $0 == w.id }
                            if on { server.workspaces.append(w.id) }
                        }))
                        .padding(.leading, 16)
                    }
                }
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                if !server.id.isEmpty {
                    Button("Delete", role: .destructive) { Task { await workspace.deleteMcpServer(server); dismiss() } }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear {
            remote = server.url != nil && server.command == nil
            arguments = server.args.joined(separator: " ")
            everywhere = server.workspaces.isEmpty
        }
    }

    /// Each value: its name, where it's kept (the Keychain unless chosen otherwise) and, unless the server's command
    /// gets it itself, the value: masked for the Keychain (left empty, the kept one stays).
    private func values(_ title: String, list: Binding<[ZerodLink.McpServer.Value]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(list.wrappedValue.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("NAME", text: list[i].name).textFieldStyle(.roundedBorder).frame(width: 150)
                    Picker("", selection: list[i].from) {
                        Text("Keychain").tag(ZerodLink.McpServer.Source.keychain)
                        Text("Zero's file").tag(ZerodLink.McpServer.Source.file)
                        Text("Its command").tag(ZerodLink.McpServer.Source.command)
                    }
                    .labelsHidden().frame(width: 120)
                    switch list.wrappedValue[i].from {
                    case .keychain:
                        SecureField(server.id.isEmpty ? "Value" : "Kept (type to change)", text: Binding(get: { secrets[list.wrappedValue[i].name] ?? "" },
                                                                                                  set: { secrets[list.wrappedValue[i].name] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    case .file:
                        TextField("Value", text: Binding(get: { list.wrappedValue[i].value ?? "" }, set: { list.wrappedValue[i].value = $0 })).textFieldStyle(.roundedBorder)
                    case .command:
                        Text("Fetched by the server itself").font(.system(size: 12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { list.wrappedValue.remove(at: i) } label: { NucleoIcon("xmark", size: 11).foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            Button { list.wrappedValue.append(.init()) } label: { NucleoLabel("Add", icon: "plus", size: 12).font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private func save() {
        if remote { server.command = nil; server.args = []; server.env = [] }
        else { server.url = nil; server.headers = []; server.args = arguments.split(separator: " ").map(String.init) }
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
