import SwiftUI
import ZeroCore

// Settings › MCP servers: servers set up once in Zero and given to every task's CLI (Claude Code, Codex, OpenCode) as
// it starts, on top of the CLI's own; each for every workspace or only those it's put in. A value (an API key, a
// header) is kept in the Keychain unless said otherwise. Below them, Claude Code's own (read from its config), with a
// Sign in for one that needs it (Claude Code's own sign-in, run by zerod) and, for one not in Zero yet, Manage in Zero:
// every CLI and account gets it from then on, Claude accounts' folders copied from the user's config only once.

struct McpServersPage: View {
    let workspace: Workspace?
    @State private var editing: ZerodLink.McpServer?
    /// The values of one of Claude Code's servers being brought into Zero, for the Keychain.
    @State private var given: [String: String] = [:]
    @State private var claudes: [ClaudeMcpServers.Server] = []
    /// Servers whose sign-in page was opened: waiting for Claude Code to say they're signed in.
    @State private var signingIn: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let workspace {
                SettingsSection(title: "Servers") {
                    VStack(spacing: 0) {
                        ForEach(Array(workspace.mcpServers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { Hairline().padding(.horizontal, 18) }
                            row(server, in: workspace)
                        }
                        if !workspace.mcpServers.isEmpty { Hairline() }
                        Button {
                            given = [:]; editing = ZerodLink.McpServer()
                        } label: {
                            NucleoLabel("Add a server", icon: "plus", size: 13).font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 44).contentShape(
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
                .zeroDialog(item: $editing) { server in McpServerForm(server: server, workspace: workspace, given: given) }
                if !claudes.isEmpty {
                    SettingsSection(title: "Claude Code's servers") {
                        VStack(spacing: 0) {
                            ForEach(Array(claudes.enumerated()), id: \.element.id) { index, server in
                                if index > 0 { Hairline().padding(.horizontal, 18) }
                                claudeRow(server, in: workspace)
                            }
                        }
                        .bleedingCard()
                    }
                }
            }
        }
        .task { claudes = ClaudeMcpServers.list() }
        // While a sign-in's page is open, Claude Code's word on it is read again every two seconds.
        .task(id: signingIn) {
            while !signingIn.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                claudes = ClaudeMcpServers.list()
                signingIn = signingIn.filter { id in claudes.contains { $0.id == id && $0.needsSignIn } }
            }
        }
    }

    /// One of Claude Code's own: read-only (`claude mcp` changes it), with its sign-in state.
    private func claudeRow(_ server: ClaudeMcpServers.Server, in workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.system(size: 13, weight: .medium))
                Text(server.detail).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            pill(server.project.map { ($0 as NSString).lastPathComponent } ?? "Every project")
            if signingIn.contains(server.id) {
                pill("Waiting for sign-in…")
            } else if server.needsSignIn {
                pill("Needs sign-in")
                RowButton(title: "Sign in") {
                    Task {
                        guard let page = await workspace.mcpSignIn(server.name, cwd: server.project) else { return }
                        NSWorkspace.shared.open(page)
                        signingIn.insert(server.id)
                    }
                }
            }
            // Under its own name, so the sign-in Claude Code keeps for it carries on.
            if !workspace.mcpServers.contains(where: { $0.name == server.name }) {
                RowButton(title: "Manage in Zero") {
                    given = server.values
                    editing = server.zeros
                }
                .tip("Given to every task, every account and every CLI from then on")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
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
            Switch(
                isOn: Binding(
                    get: { server.enabled },
                    set: { on in
                        var changed = server
                        changed.enabled = on
                        Task { _ = await workspace.saveMcpServer(changed, secrets: [:]) }
                    })
            ).tip(server.enabled ? "On: given to tasks as they start" : "Off")
            RowButton(title: "Edit…") {
                given = [:]; editing = server
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.row, in: Capsule())
    }
}

/// A server's settings: how it runs (a command, or a URL), its values and where each is kept, and its workspaces.
private struct McpServerForm: View {
    @State var server: ZerodLink.McpServer
    let workspace: Workspace
    /// Values it starts with, for the Keychain (one of Claude Code's servers brought in).
    var given: [String: String] = [:]
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
            TextField("Name (CVE lookup)", text: $server.name).textFieldStyle(.dialog).firstField()
            DialogChoice(options: [("Runs a command", false), ("At a URL", true)], selection: $remote)
            if remote {
                TextField("https://…/mcp", text: Binding(get: { server.url ?? "" }, set: { server.url = $0 })).textFieldStyle(.dialog)
                Text("One that signs in with OAuth needs no headers: Zero asks you to sign in when a task first needs it.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Command (npx, uvx, a path)", text: Binding(get: { server.command ?? "" }, set: { server.command = $0 }))
                    .textFieldStyle(.dialog)
                TextField("Arguments, separated by spaces", text: $arguments).textFieldStyle(.dialog)
                SettingRow(title: "Start when first used", detail: "Answers from what it said last time; starts on the first call.") {
                    Switch(isOn: $server.lazy)
                }
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
            if server.id.isEmpty { secrets = given }
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
            server.command = nil; server.args = []; server.env = []; server.lazy = false
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
