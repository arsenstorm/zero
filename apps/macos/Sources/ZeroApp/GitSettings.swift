import AppKit
import SwiftUI
import ZeroCore

/// Settings › Git: agents' commits signed with a key of their own, by an identity of their own as committer (the user
/// stays the author), and pushed over HTTPS with the GitHub CLI's sign-in: nothing waits on the user's own key, so the
/// Mac can be left at home. Only the agents' processes; the user's own Git is left as it is. zerod keeps it.
struct GitPage: View {
    @State private var git = AgentGit()
    @State private var publicKey: String?
    @State private var problem: String?
    /// The key's title among the account's signing keys on GitHub, and whether it's one of them (nil until checked).
    @State private var keyTitle: String?
    @State private var onGitHub: Bool?
    @State private var choosing = false
    @State private var loaded = false
    @State private var link = try? ZerodLink()

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsSection(title: "Agents' commits") {
                Rows {
                    SettingRow(title: "Sign with the agents' own key", detail: "You stay the author; the identity below commits and signs. Your own terminal keeps your key.") {
                        Switch(isOn: binding(\.enabled))
                    }
                    SettingRow(title: git.login.isEmpty ? "Account" : git.login,
                               detail: git.email.isEmpty ? "The GitHub account that commits and signs." : "\(git.name) · \(git.email)") {
                        Button(git.login.isEmpty ? "Choose…" : "Change…") { choosing = true }
                    }
                    SettingRow(title: "Signing key", detail: problem ?? keyTitle ?? publicKey.map(Self.short) ?? "None yet: a private key without a passphrase.") {
                        HStack(spacing: 10) {
                            if publicKey != nil, !git.login.isEmpty, let onGitHub {
                                StatePill(text: onGitHub ? "On \(git.login)" : "Not on \(git.login)", color: onGitHub ? .green : .orange)
                                    .tip(onGitHub ? "One of the account's signing keys: its commits show as Verified" : "Add it to the account as a signing key, or its commits show as Unverified")
                            }
                            Button(publicKey == nil ? "Choose…" : "Replace…", action: chooseKey)
                        }
                    }
                    SettingRow(title: "Push over HTTPS", detail: "GitHub with the GitHub CLI's sign-in, in place of SSH, which may wait on your own key.") {
                        Switch(isOn: binding(\.https))
                    }
                }
            }
            SettingsSection(title: "Folders", accessory: AnyView(GhostButton(title: "Add folder", icon: "plus", action: addFolder))) {
                Rows {
                    if git.folders.isEmpty {
                        SettingRow(title: "Every folder", detail: "Agents anywhere commit this way. Add folders to keep it to them.") { EmptyView() }
                    }
                    ForEach(git.folders, id: \.self) { folder in
                        SettingRow(title: (folder as NSString).lastPathComponent, detail: (folder as NSString).abbreviatingWithTildeInPath) {
                            Button("Remove") { git.folders.removeAll { $0 == folder }; save() }
                        }
                    }
                }
            }
        }
        .task {
            guard let (kept, key) = try? await link?.agentGit() else { return }
            git = kept
            publicKey = key
            loaded = true
        }
        .task(id: "\(git.login) \(publicKey ?? "")") { await check() }
        .zeroDialog(isPresented: $choosing) {
            NameSheet(title: "GitHub account", name: git.login, action: "Use") { login in Task { await useAccount(login) } }
        }
    }

    /// The account as GitHub has it: its name and noreply email are the committer's.
    private func useAccount(_ login: String) async {
        do {
            guard let found = try await link?.gitAccount(login) else { return }
            git.login = found.login; git.name = found.name; git.email = found.email
            problem = nil
            save()
        } catch { problem = error.localizedDescription }
    }

    /// Whether the key is one of the account's signing keys on GitHub.
    private func check() async {
        guard publicKey != nil, !git.login.isEmpty, let link else { onGitHub = nil; keyTitle = nil; return }
        let title = try? await link.gitCheck(git.login)
        keyTitle = title ?? nil
        onGitHub = (title ?? nil) != nil
    }

    private func binding<Value>(_ path: WritableKeyPath<AgentGit, Value>) -> Binding<Value> {
        Binding(get: { git[keyPath: path] }, set: { git[keyPath: path] = $0; save() })
    }

    /// Kept as it changes; not before the saved settings are in, so they're never overwritten with blanks.
    private func save() {
        guard loaded else { return }
        let git = git
        Task { try? await link?.setAgentGit(git) }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.message = "Choose the private key of the account that signs"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { publicKey = try await link?.takeGitKey(path: url.path); problem = nil }
            catch { problem = error.localizedDescription }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url, !git.folders.contains(url.path) else { return }
        git.folders.append(url.path)
        save()
    }

    /// "ssh-ed25519 AAAA…k9Qx": enough to tell it from the account's other keys.
    static func short(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2 else { return key }
        let body = parts[1]
        return "\(parts[0]) \(body.prefix(8))…\(body.suffix(8))"
    }
}
