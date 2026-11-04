import AppKit
import SwiftUI
import ZeroCore

// Settings › Accounts: the accounts and keys each CLI runs as (zerod's signins.rs). Zero keeps them and gives each
// task's CLI one as it starts (the one with the least of its week left, so one is used up before the next); the CLIs
// still make every call to their providers. Added in place, in the card, rather than in a sheet.

struct SignInsPage: View {
    let workspace: Workspace?
    @State private var adding: Provider?
    /// A Claude account with a folder of its own, being switched to a token.
    @State private var switching: ZerodLink.SignIn?

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Tasks use up one account's week before the next, and carry on as another at a limit.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
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
            }
        }
    }

    private func section(_ cli: Provider, in workspace: Workspace) -> some View {
        let mine = workspace.signins.filter { $0.cli == cli }
        return VStack(spacing: 0) {
            ForEach(Array(mine.enumerated()), id: \.element.id) { index, signin in
                if index > 0 { Divider().padding(.leading, 16) }
                SignInRow(signin: signin, workspace: workspace) { switching = signin; adding = nil }
            }
            if !mine.isEmpty { Divider() }
            if adding == cli || switching?.cli == cli {
                AddAccount(cli: cli, replacing: switching, workspace: workspace) { adding = nil; switching = nil }
            } else {
            Button { adding = cli; switching = nil } label: {
                NucleoLabel(mine.isEmpty ? "Sign in" : "Add another", icon: "plus", size: 13).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 40).contentShape(Rectangle())
            }
            .buttonStyle(Hovering(radius: 0))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: mine.isEmpty ? 14 : 0, bottomLeadingRadius: 14,
                                              bottomTrailingRadius: 14, topTrailingRadius: mine.isEmpty ? 14 : 0))
            }
        }
        .settingsCard()
    }
}

extension Provider: @retroactive Identifiable { public var id: String { rawValue } }

private struct SignInRow: View {
    let signin: ZerodLink.SignIn
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
                    TextField("A name for it", text: Binding(get: { naming }, set: { self.naming = $0 }), prompt: Text("Whose account is this? (its email, or a name)"))
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
        // Claude doesn't say whose a token is: a new one asks, in its own row.
        .onAppear { if signin.kind == .token && signin.label == "Claude account" && naming == nil { naming = ""; focused = true } }
    }

    private func rename() {
        guard let label = naming else { return }
        naming = nil
        Task { await workspace.renameSignIn(signin, to: label) }
    }
}

/// Adding one, in place in its card: how (its CLI's own sign-in in the browser, or an API key), then only what that
/// step needs. Closes itself once the account is added (or its sign-in is under way in the browser).
private struct AddAccount: View {
    let cli: Provider
    /// Signing this one in again (as a token), its id kept.
    var replacing: ZerodLink.SignIn? = nil
    let workspace: Workspace
    let done: () -> Void
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
        case go = "OpenCode Go", anthropic = "Anthropic", openai = "OpenAI", openrouter = "OpenRouter"
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if replacing != nil {
                    Text("Sign \(replacing!.label) in again as a token").font(.system(size: 13, weight: .medium))
                } else if cli == .opencode {
                    ForEach(OpenCodeProvider.allCases) { option in choice(option.rawValue, on: provider == option) { provider = option } }
                } else {
                    choice(cli == .claude ? "Sign in with Claude" : "Sign in with ChatGPT", on: !withKey) { withKey = false }
                    choice("API key", on: withKey) { withKey = true }
                }
                Spacer()
                Button { claude.cancel(); done() } label: { NucleoIcon("xmark", size: 12).foregroundStyle(.secondary).frame(width: 26, height: 26) }
                    .buttonStyle(Hovering(radius: 7)).tip("Cancel")
            }
            if cli == .opencode || withKey { keyForm } else if cli == .claude { claudeSteps } else { codexStep }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        // Closed mid-way: Claude Code's sign-in stops with it.
        .onDisappear { claude.cancel() }
    }

    /// How to add it: one of a few, the chosen one filled.
    private func choice(_ title: String, on: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) { Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 26) }
            .buttonStyle(Hovering(selected: on, radius: 7)).foregroundStyle(on ? .primary : .secondary)
    }

    private func field(_ prompt: String, text: Binding<String>, secret: Bool = false) -> some View {
        Group {
            if secret { SecureField("", text: text, prompt: Text(prompt)) } else { TextField("", text: text, prompt: Text(prompt)) }
        }
        .textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private var claudeSteps: some View {
        switch claude.status {
        case .signingIn, .checking:
            HStack(spacing: 8) {
                Spinner().frame(width: 12, height: 12)
                Text("Finish signing in on Claude's page in your browser.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                field("Its code, if Claude shows one", text: $code).onSubmit { claude.submit(code: code) }
                RowButton(title: "Send", enabled: !code.trimmed.isEmpty && claude.status != .checking) { claude.submit(code: code) }
            }
        case .done:
            Color.clear.frame(height: 0).onAppear(perform: done)
        case .failed(let why):
            HStack {
                Text(why).font(.system(size: 12)).foregroundStyle(.red).lineLimit(1)
                Spacer()
                RowButton(title: "Try again") { claude.start(replacing: replacing, in: workspace) }
            }
        case nil:
            HStack {
                Text("Opens Claude's sign-in page; its tasks get a year-long token.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                RowButton(title: "Sign in") { claude.start(replacing: replacing, in: workspace) }
            }
        }
    }

    private var codexStep: some View {
        HStack {
            Text("Opens ChatGPT's sign-in page; the account shows here once you're in.").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            RowButton(title: "Sign in", enabled: !working) { Task { await codex(apiKey: nil) } }
        }
    }

    private var keyForm: some View {
        HStack(spacing: 8) {
            field(cli == .opencode ? provider.rawValue : "A name for it", text: $label).frame(width: 170)
            field("Its API key", text: $key, secret: true).onSubmit(save)
            RowButton(title: "Save", enabled: !key.trimmed.isEmpty && !working, action: save)
        }
    }

    private func save() {
        guard !key.trimmed.isEmpty else { return }
        working = true
        Task {
            switch cli {
            case .codex: await codex(apiKey: key.trimmed)
            case .claude: await keep(.init(cli: .claude, kind: .apiKey, label: label.trimmed.isEmpty ? "Anthropic API key" : label.trimmed))
            case .opencode: await keep(.init(cli: .opencode, kind: .apiKey, label: label.trimmed.isEmpty ? provider.rawValue : label.trimmed, variable: provider.variable))
            }
            working = false
        }
    }

    private func keep(_ signin: ZerodLink.SignIn) async {
        if let error = await workspace.addSignIn(signin, secret: key.trimmed) { problem = error } else { done() }
    }

    private func codex(apiKey: String?) async {
        let (page, error) = await workspace.signInCodex(label: apiKey == nil ? nil : (label.trimmed.isEmpty ? "OpenAI API key" : label.trimmed), apiKey: apiKey)
        if let error { problem = error; return }
        if let page { NSWorkspace.shared.open(page) }
        done()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
