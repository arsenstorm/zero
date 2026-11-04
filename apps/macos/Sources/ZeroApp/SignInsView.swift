import AppKit
import SwiftUI
import ZeroCore

// Settings › Sign-ins: the accounts and keys each CLI runs as (zerod's signins.rs). Zero keeps them and gives each
// task's CLI its own as it starts; the CLIs still make every call to their providers. A task runs as its CLI's
// default unless it's started as another.

struct SignInsPage: View {
    let workspace: Workspace?
    @State private var adding: Provider?
    /// A Claude account with a folder of its own, being switched to a token.
    @State private var switching: ZerodLink.SignIn?

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("The accounts your agents run as. A new task takes the one with the least of its week left, so one is used up before the next, and a task that hits a limit carries on as another. Zero keeps them in your Keychain; the agents talk to their providers themselves.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let workspace {
                ForEach([Provider.claude, .codex, .opencode], id: \.self) { cli in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            if let mark = cli.mark { mark.resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 4)) }
                            Text(cli.title).font(.system(size: 13, weight: .semibold))
                        }
                        section(cli, in: workspace)
                    }
                }
                .task { await workspace.loadSignIns() }
                .sheet(item: $adding) { cli in AddSignIn(cli: cli, workspace: workspace) }
                .sheet(item: $switching) { signin in AddSignIn(cli: .claude, replacing: signin, workspace: workspace) }
            }
        }
    }

    private func section(_ cli: Provider, in workspace: Workspace) -> some View {
        let mine = workspace.signins.filter { $0.cli == cli }
        return VStack(spacing: 0) {
            ForEach(Array(mine.enumerated()), id: \.element.id) { index, signin in
                if index > 0 { Divider().padding(.leading, 16) }
                SignInRow(signin: signin, isDefault: workspace.signinDefaults[cli.rawValue] == signin.id, workspace: workspace) { switching = signin }
            }
            if !mine.isEmpty { Divider() }
            Button { adding = cli } label: {
                NucleoLabel(mine.isEmpty ? "Sign in" : "Add another", icon: "plus", size: 13).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
            }
            .buttonStyle(Hovering(radius: 0))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: mine.isEmpty ? 14 : 0, bottomLeadingRadius: 14,
                                              bottomTrailingRadius: 14, topTrailingRadius: mine.isEmpty ? 14 : 0))
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
    }
}

extension Provider: @retroactive Identifiable { public var id: String { rawValue } }

private struct SignInRow: View {
    let signin: ZerodLink.SignIn
    let isDefault: Bool
    let workspace: Workspace
    /// A Claude account with a folder of its own: switched to a token, so it shares the user's MCP sign-ins.
    let switchToToken: () -> Void
    @State private var hovered = false
    /// Its name being edited: what's typed so far.
    @State private var naming: String?
    /// Remove clicked once: a second click removes it.
    @State private var removing = false
    @FocusState private var focused: Bool

    private var detail: String {
        switch signin.kind {
        case .token: signin.plan.map { "\($0.capitalized) plan" } ?? "Subscription"
        case .apiKey: signin.variable.map { "API key · \($0)" } ?? "API key"
        case .codexHome: signin.plan.map { "ChatGPT \($0.capitalized)" } ?? "ChatGPT"
        case .claudeHome: [signin.plan.map { "\($0.capitalized) plan" }, "its own folder: your MCP sign-ins aren't shared"].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// "5 hours 12% · 7 days 64%", as its CLI last said; a window that has reset since reads as unused.
    private var used: String? {
        guard let usage = workspace.signinUsage[signin.id], !usage.windows.isEmpty else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        return usage.windows.map { window in
            let used = (window.resetsAt ?? Int.max) > now ? window.used : 0
            return "\(window.name) \(Int((used * 100).rounded()))%"
        }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let naming {
                    TextField("A name for it", text: Binding(get: { naming }, set: { self.naming = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .medium)).focused($focused)
                        .onSubmit(rename).onExitCommand { self.naming = nil }
                        .onChange(of: focused) { if !focused { rename() } }
                } else {
                    Text(signin.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                if signin.pending == true {
                    HStack(spacing: 6) { Spinner().frame(width: 10, height: 10); Text("Signing in… finish in your browser") }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Text([detail, used].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if signin.kind == .claudeHome {
                Button("Switch to a token", action: switchToToken).font(.system(size: 12, weight: .medium))
                    .tip("Signs it in again as a year-long token: its tasks then use your own Claude Code folder, MCP sign-ins and all")
            }
            if isDefault {
                Text("Default").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.row, in: Capsule())
            } else if signin.pending != true {
                Button("Make default") { Task { await workspace.makeDefault(signin) } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .opacity(hovered ? 1 : 0)
            }
            if signin.pending != true && naming == nil {
                Button { naming = signin.label; focused = true } label: {
                    NucleoIcon("pen", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .buttonStyle(Hovering(radius: 7)).tip("Rename")
                .opacity(hovered ? 1 : 0)
            }
            if removing {
                Button("Remove") { Task { await workspace.removeSignIn(signin) } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
                    .frame(height: 28).tip("Its tasks can't restart as it, and it has to be signed in again to come back")
            } else {
                Button { removing = true } label: {
                    NucleoIcon("trash", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .buttonStyle(Hovering(radius: 7)).tip("Remove")
                .opacity(hovered ? 1 : 0)
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovered = $0; if !$0 { removing = false } }
    }

    private func rename() {
        guard let label = naming else { return }
        naming = nil
        Task { await workspace.renameSignIn(signin, to: label) }
    }
}

/// Adding one: each CLI's own sign-in in the browser, or an API key.
private struct AddSignIn: View {
    let cli: Provider
    /// Signing this one in again (as a token), its id kept.
    var replacing: ZerodLink.SignIn? = nil
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var withKey = false
    @State private var label = ""
    @State private var key = ""
    @State private var provider = OpenCodeProvider.go
    @State private var problem: String?
    @State private var working = false
    @State private var claude = ClaudeSignIn()
    @State private var code = ""

    /// OpenCode's providers that take a key, and the variable OpenCode reads each from.
    enum OpenCodeProvider: String, CaseIterable, Identifiable {
        case go = "OpenCode Go and Zen", anthropic = "Anthropic", openai = "OpenAI", openrouter = "OpenRouter"
        var id: String { rawValue }
        var variable: String {
            switch self {
            case .go: "OPENCODE_API_KEY"
            case .anthropic: "ANTHROPIC_API_KEY"
            case .openai: "OPENAI_API_KEY"
            case .openrouter: "OPENROUTER_API_KEY"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(replacing.map { "Switch \($0.label) to a token" } ?? "Add a \(cli.title) sign-in").font(.system(size: 15, weight: .semibold))
            switch cli {
            case .claude: claudeForm
            case .codex: codexForm
            case .opencode: openCodeForm
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20).frame(width: 460)
        // Closed mid-way: Claude Code's sign-in stops with it.
        .onDisappear { claude.cancel() }
    }

    private var ways: some View {
        Picker("", selection: $withKey) {
            Text(cli == .claude ? "Sign in with Claude" : "Sign in with ChatGPT").tag(false)
            Text("An API key").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden()
    }

    @ViewBuilder private var claudeForm: some View {
        if replacing == nil { ways }
        if withKey {
            TextField("A name for it (Team key)", text: $label).textFieldStyle(.roundedBorder)
            SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder)
            buttons("Save", disabled: label.trimmed.isEmpty || key.trimmed.isEmpty) { await keep(.init(cli: .claude, kind: .apiKey, label: label.trimmed)) }
        } else {
            switch claude.status {
            case .signingIn, .checking:
                Text("Finish signing in on Claude's page. If it shows a code, paste it here.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("The code", text: $code).textFieldStyle(.roundedBorder).onSubmit { claude.submit(code: code) }
                buttons("Send the code", disabled: code.trimmed.isEmpty || claude.status == .checking) { claude.submit(code: code) }
            case .done:
                Text("Signed in.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            case .failed(let why):
                Text(why).font(.system(size: 12)).foregroundStyle(.red)
                buttons("Try again", disabled: false) { claude.start(replacing: replacing, label: label.trimmed, in: workspace) }
            case nil:
                Text("Claude Code opens Claude's sign-in page in your browser and makes a year-long token for the account you sign in as. Its tasks use that token, and your own Claude Code folder for everything else, so your MCP sign-ins work in them.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if replacing == nil {
                    // Claude Code doesn't say whose a token is, so the user does.
                    TextField("Whose it is (its email, or a name)", text: $label).textFieldStyle(.roundedBorder)
                }
                buttons("Sign in", disabled: false) { claude.start(replacing: replacing, label: label.trimmed, in: workspace) }
            }
        }
    }

    @ViewBuilder private var codexForm: some View {
        ways
        if withKey {
            TextField("A name for it (Team key)", text: $label).textFieldStyle(.roundedBorder)
            SecureField("sk-…", text: $key).textFieldStyle(.roundedBorder)
            buttons("Save", disabled: label.trimmed.isEmpty || key.trimmed.isEmpty) { await codex(apiKey: key.trimmed) }
        } else {
            Text("Codex opens ChatGPT's sign-in page; once you're in, the account shows here with its email and plan.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons("Sign in", disabled: false) { await codex(apiKey: nil) }
        }
    }

    @ViewBuilder private var openCodeForm: some View {
        Picker("Provider", selection: $provider) { ForEach(OpenCodeProvider.allCases) { Text($0.rawValue).tag($0) } }
        TextField("A name for it (\(provider.rawValue))", text: $label).textFieldStyle(.roundedBorder)
        SecureField("Its API key", text: $key).textFieldStyle(.roundedBorder)
        buttons("Save", disabled: key.trimmed.isEmpty) {
            await keep(.init(cli: .opencode, kind: .apiKey, label: label.trimmed.isEmpty ? provider.rawValue : label.trimmed, variable: provider.variable))
        }
    }

    private func buttons(_ title: String, disabled: Bool, action: @escaping () async -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(title) { Task { working = true; await action(); working = false } }
                .keyboardShortcut(.defaultAction).disabled(disabled || working)
        }
    }

    private func keep(_ signin: ZerodLink.SignIn) async {
        if let error = await workspace.addSignIn(signin, secret: key.trimmed) { problem = error } else { dismiss() }
    }

    private func codex(apiKey: String?) async {
        let (page, error) = await workspace.signInCodex(label: apiKey == nil ? nil : label.trimmed, apiKey: apiKey)
        if let error { problem = error; return }
        if let page { NSWorkspace.shared.open(page) }
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
