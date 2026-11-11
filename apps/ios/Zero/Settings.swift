import AVFoundation
import Speech
import SwiftUI
import UserNotifications

/// The phone's own settings, a page of its own (the menu's Settings): the Mac it's paired with, what iOS lets it do,
/// and unpairing.
struct SettingsView: View {
    let model: PhoneModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var notifications: UNAuthorizationStatus?
    @State private var unpairing = false

    var body: some View {
        PageScroll {
            PageGroup(title: "Your Mac") {
                PageRow(title: "Connection", value: connection, icon: "laptop-outline")
                // Only while it can't be reached: greyed out the rest of the time, it read as broken.
                if model.status != .connected && model.status != .connecting {
                    PageAction(title: "Reconnect", icon: "arrow-rotate-clockwise-outline") { model.connect() }
                }
            }
            PageGroup(title: "Permissions") {
                PageRow(title: "Notifications", value: notificationsText, icon: "inbox-outline")
                PageRow(
                    title: "Microphone", value: AVAudioApplication.shared.recordPermission == .granted ? "Allowed" : "Not allowed",
                    icon: "microphone-outline")
                PageRow(
                    title: "Speech", value: SFSpeechRecognizer.authorizationStatus() == .authorized ? "Allowed" : "Not allowed",
                    icon: "waveform-lines-outline")
                PageAction(title: "Open iOS Settings", icon: "gear-outline", trailing: "arrow-up-right-outline") {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                }
            }
            PageGroup(title: "About") {
                PageRow(
                    title: "Version",
                    value:
                        "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"))",
                    icon: "circle-info-outline")
                // The one difference between an official build and one from source (apps/ios/icons.sh).
                PageRow(
                    title: "Icons",
                    value: NSDataAsset(name: "icons").map { String(decoding: $0.data, as: UTF8.self) } == "Nucleo"
                        ? "Nucleo" : "Lucide (open-source build)",
                    icon: "image-glyph")
                // Last, under the version: in a group of its own it had a heading's gap above it and nothing to head.
                PageAction(title: "Unpair this phone", icon: "link-slash-outline", destructive: true) { unpairing = true }
                    // On the row: iOS points its confirmation at the view it's attached to (on the page, it
                    // pointed at the page's middle).
                    .confirmationDialog("Unpair this phone?", isPresented: $unpairing, titleVisibility: .visible) {
                        Button("Unpair", role: .destructive) { model.unpair() }
                    } message: {
                        Text("It stops reaching your Mac until you pair it again.")
                    }
            }
        }
        // Back from iOS Settings: what was allowed there, read again.
        .task(id: phase) { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
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
