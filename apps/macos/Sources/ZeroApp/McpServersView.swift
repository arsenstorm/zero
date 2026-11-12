import SwiftUI
import ZeroCore

// Settings › MCP servers: servers set up once in Zero and given to every task's CLI (Claude Code, Codex, OpenCode) as
// it starts, on top of the CLI's own; each for every workspace or only those it's put in. A value (an API key, a
// header) is kept in the Keychain unless said otherwise. Below them, Claude Code's and Codex's own (read from their
// config), with a Sign in for one of Claude Code's that needs it (its own sign-in, run by zerod), and "Manage in Zero"
// for a local one: moved into Zero's list, started when first used (McpHandOver), and given back from its Edit.

struct McpServersPage: View {
    let workspace: Workspace?
    @State private var editing: ZerodLink.McpServer?
    @State private var claudes: [ClaudeMcpServers.Server] = []
    @State private var codexes: [ClaudeMcpServers.Server] = []
    /// The CLI server whose "Manage in Zero" is being confirmed.
    @State private var moving: ClaudeMcpServers.Server?
    /// Servers whose sign-in page was opened: waiting for Claude Code to say they're signed in.
    @State private var signingIn: Set<String> = []

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
                .zeroDialog(item: $moving) { server in HandOverForm(server: server, workspace: workspace) }
                // Back from a dialog that may have moved one either way: the CLIs' lists read again.
                .onChange(of: editing == nil && moving == nil) { _, closed in if closed { Task { await readClis() } } }
                ForEach([("Claude Code's servers", claudes), ("Codex's servers", codexes)], id: \.0) { title, servers in
                    if !servers.isEmpty {
                        SettingsSection(title: title) {
                            VStack(spacing: 0) {
                                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                                    if index > 0 { Divider().padding(.leading, 18) }
                                    claudeRow(server, in: workspace)
                                }
                            }
                            .bleedingCard()
                        }
                    }
                }
            }
        }
        .task { await readClis() }
        // While a sign-in's page is open, Claude Code's word on it is read again every two seconds.
        .task(id: signingIn) {
            while !signingIn.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                claudes = ClaudeMcpServers.list()
                signingIn = signingIn.filter { id in claudes.contains { $0.id == id && $0.needsSignIn } }
            }
        }
    }

    private func readClis() async {
        claudes = ClaudeMcpServers.list()
        codexes = await CodexMcpServers.list()
    }

    /// One of a CLI's own: read-only (`claude mcp`, `codex mcp` change it), with its sign-in state, and Manage in Zero
    /// for a local one.
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
                Button("Sign in") {
                    Task {
                        guard let page = await workspace.mcpSignIn(server.name, cwd: server.project) else { return }
                        NSWorkspace.shared.open(page)
                        signingIn.insert(server.id)
                    }
                }
            }
            if server.movable { Button("Manage in Zero") { moving = server } }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
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
    /// The CLI it was moved from by Manage in Zero, to give it back to.
    private var origin: McpHandOver.Origin? { server.id.isEmpty ? nil : McpHandOver.origin(of: server.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(text: server.id.isEmpty ? "Add an MCP server" : "Edit \(server.name)")
            TextField("Name (CVE lookup)", text: $server.name).textFieldStyle(.dialog)
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
                if let origin {
                    DialogButton(title: "Give back to \(origin.cli.title)") {
                        let saved = workspace.mcpServers.first { $0.id == server.id } ?? server
                        Task { if let error = await workspace.giveBack(saved) { problem = error } else { dismiss() } }
                    }
                    .tip("Back in \(origin.cli.title)'s own config, out of Zero's list")
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

/// "Manage in Zero" confirmed: what changes (the CLI in a plain terminal loses it), where its values go, then the move.
private struct HandOverForm: View {
    let server: ClaudeMcpServers.Server
    let workspace: Workspace
    @Environment(\.closeDialog) private var dismiss
    @State private var inFile = false
    @State private var problem: String?
    @State private var moving = false

    var body: some View {
        let cli = server.cli.title
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(text: "Manage \(server.name) in Zero")
            note(
                "Zero gives it to every task's CLI and starts it when a task first calls it, not as each task starts. "
                    + "It's taken out of \(cli)'s own config, so \(cli) in a plain terminal won't have it any more. "
                    + "Its Edit in Zero's list gives it back.")
            if let project = server.project {
                note("It was only in \((project as NSString).lastPathComponent); in Zero it's for every workspace until you choose some.")
            }
            if !server.env.isEmpty {
                DialogPart(title: "Its environment: " + server.env.keys.sorted().joined(separator: ", ")) {
                    DialogChoice(options: [("Keychain", false), ("Zero's file", true)], selection: $inFile)
                }
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: moving ? "Moving…" : "Manage in Zero", kind: .primary, enabled: !moving) {
                    moving = true
                    Task {
                        problem = await workspace.manageInZero(server, inFile: inFile)
                        moving = false
                        if problem == nil { dismiss() }
                    }
                }
            }
        }
        .frame(width: 460)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
