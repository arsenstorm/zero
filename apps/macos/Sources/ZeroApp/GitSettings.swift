import AppKit
import SwiftUI
import ZeroCore

/// Agents' Git settings as zerod keeps them (git.rs), shared by Settings › Git (who agents commit as) and GitHub ›
/// Agents' access (their token and how they push).
@MainActor @Observable final class AgentGitSettings {
    var git = AgentGit()
    var publicKey: String?
    var tokenStatus: GitTokenStatus?
    /// The saved settings are in: nothing is saved before, so they're never overwritten with blanks.
    private(set) var loaded = false
    @ObservationIgnored let link = try? ZerodLink()

    func load() async {
        guard let (kept, key) = try? await link?.agentGit() else { return }
        git = kept
        publicKey = key
        loaded = true
        await refreshToken()
    }

    func refreshToken() async { tokenStatus = try? await link?.gitTokenStatus() }

    func save() {
        guard loaded else { return }
        let git = git
        Task { try? await link?.setAgentGit(git) }
    }

    func binding<Value>(_ path: WritableKeyPath<AgentGit, Value>) -> Binding<Value> {
        Binding(
            get: { self.git[keyPath: path] },
            set: {
                self.git[keyPath: path] = $0; self.save()
            })
    }
}

/// Settings › Git: who agents commit as. Off, nothing else shows: their commits are as yours.
struct GitPage: View {
    @State private var model = AgentGitSettings()
    @State private var problem: String?
    /// The key's title among the account's signing keys on GitHub, and whether it's one of them (nil until checked).
    @State private var keyTitle: String?
    @State private var onGitHub: Bool?
    @State private var choosing = false
    @State private var editingCoauthor = false
    private var git: AgentGit { model.git }

    var body: some View {
        Sections {
            SettingsSection(title: "Agents' commits") {
                Rows {
                    SettingRow(
                        title: "Agents commit as their own account",
                        detail: "Their commits are signed and verified; your terminal keeps your key."
                    ) {
                        Switch(isOn: model.binding(\.enabled))
                    }
                    if git.enabled {
                        SettingRow(
                            title: git.login.isEmpty ? "Account" : git.login,
                            detail: git.email.isEmpty ? "The GitHub account that commits and signs." : "\(git.name) · \(git.email)"
                        ) {
                            RowButton(title: git.login.isEmpty ? "Choose…" : "Change…") { choosing = true }
                        }
                        SettingRow(
                            title: "Signing key",
                            detail: problem ?? keyTitle ?? model.publicKey.map(Self.short)
                                ?? "None yet: a private key without a passphrase."
                        ) {
                            HStack(spacing: 10) {
                                if model.publicKey != nil, !git.login.isEmpty, let onGitHub {
                                    StatePill(
                                        text: onGitHub ? "On \(git.login)" : "Not on \(git.login)", color: onGitHub ? Theme.done : .orange
                                    )
                                    .tip(
                                        onGitHub
                                            ? "One of the account's signing keys: its commits show as Verified"
                                            : "Add it to the account as a signing key, or its commits show as Unverified")
                                }
                                RowButton(title: model.publicKey == nil ? "Choose…" : "Replace…", action: chooseKey)
                            }
                        }
                        SettingRow(
                            title: "Credit you as co-author",
                            detail: "Agents become the author and add you as Co-authored-by. Off: you stay the author."
                        ) { Switch(isOn: model.binding(\.agentsAuthor)) }
                        if git.agentsAuthor {
                            SettingRow(
                                title: "Your name and email",
                                detail: git.coauthorName.isEmpty || git.coauthorEmail.isEmpty
                                    ? "From each repository's Git config."
                                    : "\(git.coauthorName) · \(git.coauthorEmail)"
                            ) { RowButton(title: "Set…") { editingCoauthor = true } }
                        }
                    }
                }
            }
            // The folders limit the GitHub token and HTTPS pushes too (GitHub › Agents' access): shown while any is on.
            if git.enabled || git.scopedToken || git.https {
                SettingsSection(
                    title: "Only in these folders", accessory: AnyView(GhostButton(title: "Add folder", icon: "plus", action: addFolder))
                ) {
                    Rows {
                        if git.folders.isEmpty {
                            SettingRow(title: "Every folder", detail: "Agents anywhere work this way. Add folders to keep it to them.") {
                                EmptyView()
                            }
                        }
                        ForEach(git.folders, id: \.self) { folder in
                            SettingRow(
                                title: (folder as NSString).lastPathComponent, detail: (folder as NSString).abbreviatingWithTildeInPath
                            ) {
                                RowButton(title: "Remove") {
                                    model.git.folders.removeAll { $0 == folder }; model.save()
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await model.load() }
        .task(id: "\(git.login) \(model.publicKey ?? "")") { await check() }
        .zeroDialog(isPresented: $choosing) {
            NameSheet(title: "GitHub account", name: git.login, action: "Use") { login in Task { await useAccount(login) } }
        }
        .zeroDialog(isPresented: $editingCoauthor) {
            CoauthorSheet(name: git.coauthorName, email: git.coauthorEmail) { name, email in
                model.git.coauthorName = name; model.git.coauthorEmail = email; model.save()
            }
        }
    }

    /// The account as GitHub has it: its name and noreply email are the committer's.
    private func useAccount(_ login: String) async {
        do {
            guard let found = try await model.link?.gitAccount(login) else { return }
            model.git.login = found.login; model.git.name = found.name; model.git.email = found.email
            problem = nil
            model.save()
        } catch { problem = error.localizedDescription }
    }

    /// Whether the key is one of the account's signing keys on GitHub.
    private func check() async {
        guard model.publicKey != nil, !git.login.isEmpty, let link = model.link else { onGitHub = nil; keyTitle = nil; return }
        let title = try? await link.gitCheck(git.login)
        keyTitle = title ?? nil
        onGitHub = (title ?? nil) != nil
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.message = "Choose the private key of the account that signs"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { model.publicKey = try await model.link?.takeGitKey(path: url.path); problem = nil } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url, !git.folders.contains(url.path) else { return }
        model.git.folders.append(url.path)
        model.save()
    }

    /// "ssh-ed25519 AAAA…k9Qx": enough to tell it from the account's other keys.
    static func short(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2 else { return key }
        let body = parts[1]
        return "\(parts[0]) \(body.prefix(8))…\(body.suffix(8))"
    }
}

/// GitHub › Agents' access: a GitHub token of their own (in the Keychain), and pushing over HTTPS with the GitHub
/// CLI's sign-in rather than SSH.
struct AgentsGitHubAccess: View {
    @State private var model = AgentGitSettings()
    @State private var editingToken = false
    @State private var enableAfterToken = false
    private var git: AgentGit { model.git }
    private var tokenSaved: Bool { model.tokenStatus?.configured == true }

    var body: some View {
        SettingsSection(title: "Agents' access") {
            Rows {
                SettingRow(
                    title: "Give agents their own GitHub token",
                    detail: "Limits what their gh commands and pushes can reach. Only in the folders Settings › Git keeps it to."
                ) {
                    Switch(
                        isOn: Binding(
                            get: { git.scopedToken },
                            set: { enabled in
                                if enabled && (!tokenSaved || model.tokenStatus?.error != nil) {
                                    enableAfterToken = true
                                    editingToken = true
                                } else {
                                    model.git.scopedToken = enabled; model.save()
                                }
                            }))
                }
                if tokenSaved {
                    SettingRow(title: "Token", detail: tokenDetail) {
                        HStack(spacing: 8) {
                            RowButton(title: "Remove") {
                                Keychain.saveString(nil, service: "Zero GitHub token", account: "agents")
                                model.git.scopedToken = false; model.save()
                                Task { await model.refreshToken() }
                            }
                            RowButton(title: "Replace…") { editingToken = true }
                        }
                    }
                }
                SettingRow(title: "Push with the GitHub CLI's sign-in", detail: "Rather than SSH, which may wait on your own key.") {
                    // The token pushes over HTTPS itself: on and locked while agents have it.
                    Switch(
                        isOn: Binding(
                            get: { git.https || git.scopedToken },
                            set: {
                                model.git.https = $0; model.save()
                            })
                    )
                    .disabled(git.scopedToken).tip(git.scopedToken ? "Agents' own token pushes over HTTPS" : "")
                }
            }
        }
        .task { await model.load() }
        .zeroDialog(isPresented: $editingToken) {
            GitTokenSheet {
                let shouldEnable = enableAfterToken
                enableAfterToken = false
                Task {
                    await model.refreshToken()
                    if shouldEnable && tokenSaved && model.tokenStatus?.error == nil {
                        model.git.scopedToken = true; model.save()
                    }
                }
            }
        }
        .onChange(of: editingToken) { _, open in
            if !open { enableAfterToken = false }
        }
    }

    private var tokenDetail: String {
        guard let status = model.tokenStatus else { return "No token saved." }
        if let error = status.error { return error }
        let account = status.login.map { "@\($0)" } ?? "Saved token"
        return status.expires.map { "\(account) · expires \($0)" } ?? account
    }
}

private struct CoauthorSheet: View {
    @Environment(\.closeDialog) private var dismiss
    @State var name: String
    @State var email: String
    let save: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(
                text: "Your name and email",
                detail: "Leave both blank to use each repository's user.name and user.email."
            )
            DialogPart(title: "Name") { TextField("Name", text: $name).textFieldStyle(.dialog).firstField() }
            DialogPart(title: "Email") { TextField("Email", text: $email).textFieldStyle(.dialog) }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(
                    title: "Save", kind: .primary,
                    enabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        == email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    save(name.trimmingCharacters(in: .whitespacesAndNewlines), email.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
            }
        }
        .frame(width: 440)
    }
}

private struct GitTokenSheet: View {
    @Environment(\.closeDialog) private var dismiss
    @State private var token = ""
    let saved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(
                text: "Agents' GitHub token",
                detail:
                    "Paste a fine-grained token for the repositories agents may use. Give it Contents and Pull requests read and write, Checks and Actions read, and no Administration. Zero keeps it in your Keychain."
            )
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            } label: {
                TaskDetails.linked("Create a token on GitHub").font(.system(size: 12.5))
            }
            .buttonStyle(.plain)
            SecureField("Token", text: $token).textFieldStyle(.dialog).firstField()
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Save", kind: .primary, enabled: !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Keychain.saveString(
                        token.trimmingCharacters(in: .whitespacesAndNewlines), service: "Zero GitHub token", account: "agents")
                    token = ""
                    saved()
                    dismiss()
                }
            }
        }
        .frame(width: 440)
    }
}
