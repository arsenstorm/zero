import AppKit
import SwiftUI
import ZeroCore

// Settings › Accounts: the accounts and keys each CLI runs as (zerod's signins.rs). Zero keeps them and gives each
// task's CLI one as it starts (the one with the least of its week left, so one is used up before the next); the CLIs
// still make every call to their providers. Added in place, in the card, rather than in a sheet.

struct SignInsPage: View {
    let workspace: Workspace?
    /// The account being added (or switched to a token), in its dialog.
    @State private var adding: Adding?
    /// The CLI a model is being added for, in its dialog.
    @State private var addingModel: Provider?

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let workspace {
                ForEach([Provider.claude, .codex, .opencode], id: \.self) { cli in
                    SettingsSection(title: cli.title,
                                    icon: cli.mark.map { AnyView($0.resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 4))) },
                                    accessory: AnyView(HStack(spacing: 4) {
                                        GhostButton(title: "Add model", icon: "plus", open: addingModel == cli) { addingModel = addingModel == cli ? nil : cli }
                                        AddAccountButton(cli: cli) { way in adding = Adding(cli: cli, way: way) }
                                    })) {
                        section(cli, in: workspace)
                    }
                }
                .zeroDialog(item: $adding) { adding in AddAccount(cli: adding.cli, way: adding.way, replacing: adding.replacing, workspace: workspace) }
                .zeroDialog(item: $addingModel) { cli in AddModel(cli: cli) }
            }
        }
        .task { await CustomModels.shared.load() }
        // Open, the page asks each account's CLI for its usage, every two minutes: not only as its tasks last heard it.
        .task {
            guard let workspace else { return }
            await workspace.loadSignIns()
            while !Task.isCancelled {
                await workspace.readUsage()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func section(_ cli: Provider, in workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            accounts(cli, in: workspace)
            AddedModels(cli: cli, workspace: workspace)
        }
    }

    private func accounts(_ cli: Provider, in workspace: Workspace) -> some View {
        let mine = workspace.signins.filter { $0.cli == cli }
        return VStack(spacing: 0) {
            ForEach(Array(mine.enumerated()), id: \.element.id) { index, signin in
                if index > 0 { Divider().padding(.leading, 18) }
                SignInRow(signin: signin, workspace: workspace) { adding = Adding(cli: cli, way: .signIn, replacing: signin) }
            }
            if mine.isEmpty {
                Text("None yet").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 44)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .bleedingCard()
    }
}

/// An account being added, in its dialog: for which CLI, how, and the account it signs in again (as a token), if any.
private struct Adding: Identifiable {
    let cli: Provider
    let way: AddWay
    var replacing: ZerodLink.SignIn? = nil
    var id: String { "\(cli.rawValue)-\(way)-\(replacing?.id ?? "")" }
}

/// How an account is added: its CLI's own sign-in in the browser, or a key (OpenCode's: for which provider).
private enum AddWay: Equatable, CustomStringConvertible {
    case signIn, key(AddAccount.OpenCodeProvider?)
    var description: String { switch self { case .signIn: "signIn"; case .key(let provider): "key-\(provider?.rawValue ?? "")" } }
}

/// The heading's ghost button: Zero's menu of the ways to add one of this CLI's accounts.
private struct AddAccountButton: View {
    let cli: Provider
    let pick: (AddWay) -> Void
    @State private var anchor = CGRect.zero

    private var id: String { "add-\(cli.rawValue)" }

    var body: some View {
        GhostButton(title: "Add account", icon: "plus", open: WorkspaceSelector.shared.open == id) {
            WorkspaceSelector.shared.toggle(id, kind: .menu, anchor: anchor, rows: { rows })
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
    }

    private var rows: [SelectorSection] {
        if cli == .opencode {
            return ComposerRows.menu([AddAccount.OpenCodeProvider.allCases.map { option in
                (option.rawValue, "\(option.rawValue) key", "key", false, { pick(.key(option)) })
            }])
        }
        return ComposerRows.menu([[
            ("signIn", cli == .claude ? "Sign in with Claude" : "Sign in with ChatGPT", "circle-user", false, { pick(.signIn) }),
            ("key", cli == .claude ? "Anthropic API key" : "OpenAI API key", "key", false, { pick(.key(nil)) }),
        ]])
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
    /// Remove picked: confirmed in the row, where its usage was.
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
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if removing {
                Button("Cancel") { removing = false }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Button("Remove") { Task { await workspace.removeSignIn(signin) } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
                    .tip("Its tasks can't restart as it, and it has to be signed in again to come back")
            } else if let usage = workspace.signinUsage[signin.id], !usage.windows.isEmpty {
                UsageColumns(usage: usage)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(minHeight: 56)
        // The row is its own menu: rename, switch, remove. Nothing kept beside the usage for them.
        .rowMenu("signin-\(signin.id)", enabled: naming == nil && !removing && signin.pending != true) {
            var rows: [(id: String, title: String, glyph: String, selected: Bool, pick: () -> Void)] = [
                ("rename", "Rename", "pen", false, { naming = signin.label; focused = true }),
            ]
            if signin.kind == .claudeHome { rows.append(("token", "Switch to a token", "key", false, switchToToken)) }
            return ComposerRows.menu([rows, [("remove", "Remove…", "trash", false, { removing = true })]])
        }
        // Claude doesn't say whose a token is: a new one asks, in its own row.
        .onAppear { if signin.kind == .token && signin.label == "Claude account" && naming == nil { naming = ""; focused = true } }
    }

    private func rename() {
        guard let label = naming else { return }
        naming = nil
        Task { await workspace.renameSignIn(signin, to: label) }
    }
}

/// How much of each of an account's windows its CLI last said was used: a column each, the 5-hour then the week, at
/// fixed widths so every row lines up (a window it gave no figure for keeps its place). A window that has reset since
/// is unused. When it resets is on hover.
private struct UsageColumns: View {
    let usage: Usage
    private static let slots = [("5 hours", "5h"), ("7 days", "Week")]

    var body: some View {
        let now = Int(Date().timeIntervalSince1970)
        HStack(spacing: 18) {
            ForEach(Self.slots, id: \.0) { name, short in
                if let window = usage.windows.first(where: { $0.name == name }) {
                    let live = (window.resetsAt ?? Int.max) > now
                    column(short, used: live ? min(1, window.used) : 0)
                        .tip(live ? window.resetsAt.map { "Resets \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(.dateTime.weekday(.abbreviated).hour().minute()))" } ?? "" : "Reset since it was read")
                } else {
                    Color.clear.frame(width: Self.width, height: 1)
                }
            }
        }
    }

    private static let width: CGFloat = 84

    private func column(_ name: String, used: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(width: 46, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(used >= 1 ? Color.red : used >= 0.9 ? Color.orange : Color.primary.opacity(0.5)).frame(width: 46 * used, height: 4)
                    }
                Text("\(Int((used * 100).rounded()))%").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: Self.width)
    }
}

/// Adding one, in a dialog: its CLI's own sign-in in the browser (under way as it opens), or a key. Closes itself once
/// the account is added (or its sign-in is under way in the browser).
private struct AddAccount: View {
    let cli: Provider
    let way: AddWay
    /// Signing this one in again (as a token), its id kept.
    var replacing: ZerodLink.SignIn? = nil
    let workspace: Workspace
    @Environment(\.closeDialog) private var dismiss
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

    private var keyed: Bool { if case .key = way { true } else { false } }

    private var title: String {
        if let replacing { return "Sign \(replacing.label) in again as a token" }
        if case .key(let option) = way { return option.map { "\($0.rawValue) key" } ?? (cli == .claude ? "Anthropic API key" : "OpenAI API key") }
        return cli == .claude ? "Sign in with Claude" : "Sign in with ChatGPT"
    }

    private var explanation: String {
        switch (cli, keyed) {
        case (.claude, false): "Claude's sign-in page opens in your browser. Its tasks get a year-long token, kept in your Keychain."
        case (.codex, false): "ChatGPT's sign-in page opens in your browser; the account shows here once you're in."
        case (.claude, true): "Billed per use, and kept in your Keychain."
        case (.codex, true): "Billed per use. Codex keeps it, in a home of this account's own."
        case (.opencode, _): "Given to OpenCode as \(provider.variable), and kept in your Keychain."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                DialogTitle(text: title)
                Text(explanation).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if keyed { keyForm } else if cli == .claude { claudeSteps } else { codexStep }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                DialogButton(title: "Cancel", action: cancel)
                if keyed {
                    DialogButton(title: "Save", kind: .primary, enabled: !key.trimmed.isEmpty && !working, action: save)
                } else if case .failed = claude.status {
                    DialogButton(title: "Try again", kind: .primary) { claude.start(replacing: replacing, in: workspace) }
                } else if cli == .codex && problem != nil {
                    DialogButton(title: "Try again", kind: .primary) { problem = nil; Task { await codex(apiKey: nil) } }
                }
            }
        }
        .frame(width: 440)
        // Opened from the menu: the sign-in starts at once.
        .onAppear {
            if case .key(let option?) = way { provider = option }
            guard way == .signIn else { return }
            if cli == .claude { claude.start(replacing: replacing, in: workspace) } else { Task { await codex(apiKey: nil) } }
        }
        // Closed mid-way: Claude Code's sign-in stops with it.
        .onDisappear { claude.cancel() }
    }

    private func cancel() { claude.cancel(); dismiss() }
    private func done() { dismiss() }

    private func field(_ prompt: String, text: Binding<String>, secret: Bool = false) -> some View {
        Group {
            if secret { SecureField("", text: text, prompt: Text(prompt)) } else { TextField("", text: text, prompt: Text(prompt)) }
        }
        .textFieldStyle(.dialog)
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
            Text(why).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var codexStep: some View {
        if problem == nil {
            HStack(spacing: 8) {
                Spinner().frame(width: 12, height: 12)
                Text("Opening ChatGPT's sign-in page…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var keyForm: some View {
        VStack(spacing: 8) {
            field(cli == .opencode ? "A name for it (\(provider.rawValue))" : "A name for it", text: $label)
            field("Its API key", text: $key, secret: true).onSubmit(save)
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

/// The models added to Zero for a CLI, under its accounts (added from the heading's Add model): one its own list
/// doesn't have yet (a new release), by the id the CLI is started with and a name for the picker. Zero-wide: every
/// account of this CLI offers it, but those its provider refused it.
private struct AddedModels: View {
    let cli: Provider
    let workspace: Workspace

    private var mine: [CustomModels.Model] { CustomModels.shared.models.filter { $0.cli == cli } }

    var body: some View {
        if !mine.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(mine.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Divider().padding(.leading, 18) }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).font(.system(size: 13, weight: .medium))
                            Text(model.id).font(.system(size: 11.5).monospaced()).foregroundStyle(.secondary)
                            if let note = availability(model) { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Remove") { Task { await CustomModels.shared.remove(model) } }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18).frame(minHeight: 52)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .bleedingCard()
        }
    }

    /// Which of this CLI's accounts can't use it, as their provider said when a task tried: tasks on it go to the others.
    private func availability(_ model: CustomModels.Model) -> String? {
        let accounts = workspace.signins.filter { $0.cli == cli }
        let refused = accounts.filter { workspace.signinRefused[$0.id]?.contains(model.id) == true }
        guard !refused.isEmpty else { return nil }
        if refused.count == accounts.count { return "None of your accounts can use it" }
        return "Not on " + refused.map(\.label).joined(separator: ", ") + ": tasks on it run as your other accounts"
    }
}

/// A model added to Zero for a CLI, in a dialog as an account is: its id as the CLI takes it, and its name.
private struct AddModel: View {
    let cli: Provider
    @Environment(\.closeDialog) private var dismiss
    @State private var id = ""
    @State private var name = ""

    private var example: String {
        switch cli { case .claude: "claude-mythos-5-2"; case .codex: "gpt-5.5-codex"; case .opencode: "provider/model" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                DialogTitle(text: "Add a \(cli.title) model")
                Text("For a model \(cli.title) doesn't list yet. It's offered on every \(cli.title) account; an account that turns out not to have it is left out.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                TextField("", text: $id, prompt: Text("Its id, as \(cli.title) takes it (\(example))")).textFieldStyle(.dialog).onSubmit(save)
                TextField("", text: $name, prompt: Text("Its name in the picker (Mythos 5.2)")).textFieldStyle(.dialog).onSubmit(save)
            }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Add", kind: .primary, enabled: !id.trimmed.isEmpty, action: save)
            }
        }
        // The dialog's own width, as Add account's: unset, it took the window's.
        .frame(width: 440)
    }

    private func save() {
        let id = id.trimmed, name = name.trimmed
        guard !id.isEmpty else { return }
        Task { await CustomModels.shared.add(CustomModels.Model(cli: cli, id: id, name: name.isEmpty ? id : name)) }
        dismiss()
    }
}
