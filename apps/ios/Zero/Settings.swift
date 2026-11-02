import AVFoundation
import Speech
import SwiftUI
import UserNotifications

/// The phone's own settings: the Mac it's paired with, what iOS lets it do, and unpairing.
struct SettingsView: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var notifications: UNAuthorizationStatus?
    @State private var unpairing = false
    @State private var servers: [[String: Any]]?

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Mac") {
                    LabeledContent("Connection", value: connection)
                    Button("Reconnect") { model.connect() }.disabled(model.status == .connected || model.status == .connecting)
                }
                Section {
                    LabeledContent("Notifications", value: notificationsText)
                    LabeledContent("Microphone", value: AVAudioApplication.shared.recordPermission == .granted ? "Allowed" : "Not allowed")
                    LabeledContent("Speech", value: SFSpeechRecognizer.authorizationStatus() == .authorized ? "Allowed" : "Not allowed")
                    Button("Open iOS Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                } header: { Text("Permissions") } footer: {
                    Text("Notifications tell you when a task needs you. The microphone and speech let you dictate a message.")
                }
                if let servers, !servers.isEmpty {
                    Section {
                        ForEach(servers.indices, id: \.self) { i in server(servers[i]) }
                    } header: { Text("MCP servers") } footer: {
                        Text("Given to tasks as their agent starts. Set them up on your Mac, in Settings › MCP servers.")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–")
                }
                Section {
                    Button("Unpair this phone", role: .destructive) { unpairing = true }
                } footer: {
                    Text("To pair again, open Zero's Settings › Devices on your Mac and scan its code.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair this phone?", isPresented: $unpairing, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { dismiss(); model.unpair() }
            } message: {
                Text("It stops reaching your Mac until you pair it again.")
            }
            // Back from iOS Settings: what was allowed there, read again.
            .task { servers = await model.mcpServers() }
            .task(id: phase) { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        }
    }

    private func server(_ server: [String: Any]) -> some View {
        let workspaces = server["workspaces"] as? [String] ?? []
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(server["name"] as? String ?? "").font(.body.weight(.medium))
                Spacer()
                if server["enabled"] as? Bool == false { Text("Off").font(.footnote).foregroundStyle(.secondary) }
            }
            Text(server["runs"] as? String ?? "").font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(workspaces.isEmpty ? "Every workspace" : workspaces.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var connection: String {
        switch model.status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .offline: "Can't reach it"
        case .unpaired: "Not paired"
        }
    }

    private var notificationsText: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        default: "–"
        }
    }
}
