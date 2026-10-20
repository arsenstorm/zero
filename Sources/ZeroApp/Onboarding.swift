import AVFoundation
import Speech
import SwiftUI
import UserNotifications

/// Zero's first run: what it is, the agents it works with, the permissions it needs, a few habits, and one real
/// ask to answer. Its own centred window; Zero stays a menu bar app once it closes.
struct OnboardingView: View {
    @Bindable var settings: Settings
    /// Sends the sample ask and opens the inbox on it.
    let tryIt: () -> Void
    let finish: () -> Void

    enum Step: Int, CaseIterable { case welcome, agents, permissions, habits, tryIt }
    @State private var step = Step.welcome
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page.id(step)
                    .transition(.asymmetric(insertion: .offset(x: forward ? 16 : -16).combined(with: .opacity),
                                            removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44).padding(.top, 52)
            footer.padding(.horizontal, 28).padding(.bottom, 24)
        }
        .frame(width: 560, height: 600)
        .background(Theme.card)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            VStack(spacing: 18) {
                ZeroMark().frame(width: 104, height: 100).padding(.top, 36)
                Text("Welcome to Zero").font(.system(size: 26, weight: .semibold))
                Text("One inbox on your Mac for everything your agents need from you: a question, a go-ahead, a command to run on your side.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                VStack(alignment: .leading, spacing: 14) {
                    point("rectangle.portrait", "The bar", "Sits at the edge of your screen. One dot per agent: blue working, orange needs you, green done.")
                    point("tray", "The inbox", "Opens from the bar. Answer with 1, 2 or 3, type a reply, or start a new agent.")
                }
                .padding(.top, 14).frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity)
        case .agents:
            StepPage(title: "Your agents", detail: "Zero works with the coding agents on this Mac. The Zero plugin teaches them to ask you here instead of waiting in a terminal you are not watching.") {
                AgentsStep()
            }
        case .permissions:
            StepPage(title: "Permissions", detail: "Each one is optional, and Zero needs no other access.") {
                PermissionsStep()
            }
        case .habits:
            StepPage(title: "Make it yours", detail: "Change these later in **Zero menu bar icon → Settings**.") {
                VStack(spacing: 0) {
                    OnboardingRow(icon: "keyboard", title: "Talk hotkey", detail: "Opens the inbox on the oldest ask and starts dictation.") {
                        HotKeyRecorder(settings: settings, minWidth: nil)
                    }
                    Divider()
                    OnboardingRow(icon: "power", title: "Launch Zero at login", detail: "So agents can always reach you.") {
                        Toggle("", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 })).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    OnboardingRow(icon: "display.2", title: "Follow the active screen", detail: "The bar moves to the screen you are working on.") {
                        Toggle("", isOn: $settings.followActiveScreen).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        case .tryIt:
            StepPage(title: "Try it", detail: "Zero sends you an ask the way an agent would. Answer it in the inbox with 1.") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("zero approve \"Zero is set up. Finish onboarding?\"")
                        .font(.system(size: 12, design: .monospaced)).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Agents send this from their terminal. It waits until you answer, then carries on.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    SolidButton(title: "Send test ask", action: tryIt).padding(.top, 6)
                }
            }
        }
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s == step ? Theme.knob : Theme.keycap).frame(width: s == step ? 16 : 6, height: 6)
                }
            }
            .animation(.snappy(duration: 0.2), value: step)
            Spacer()
            if step != .welcome {
                Button("Back") { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 14)
            }
            SolidButton(title: step == .tryIt ? "Done" : "Continue") { step == .tryIt ? finish() : go(1) }
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.22)) { step = next }
    }
}

/// A title, a line under it, and the step's content.
private struct StepPage<Content: View>: View {
    let title: String
    /// Markdown, so a menu path can be bold.
    let detail: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZeroMark(small: true).frame(width: 34, height: 33).padding(.bottom, 20)
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6).padding(.bottom, 24)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line of a step: an icon, what it is, why, and its control on the right.
struct OnboardingRow<Trailing: View>: View {
    let icon: String
    /// A bundled picture (an agent's logo) in place of the symbol.
    var picture: Image? = nil
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let picture { picture.resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5)) }
                else { Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.secondary) }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // A fixed slot, so a spinner turning into a button or a tick moves nothing beside it.
            trailing().frame(width: 128, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}

/// A small solid button for a row: black in light mode, white in dark; greyed and inert when disabled.
private struct RowButton: View {
    let title: String
    var enabled = true
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? AnyShapeStyle(Theme.onKnob) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 12).frame(height: 26)
                .background(enabled ? AnyShapeStyle(Theme.knob) : AnyShapeStyle(Theme.keycap)).clipShape(Capsule())
        }
        .buttonStyle(PressableStyle()).disabled(!enabled)
    }
}

/// Black in light mode, white in dark: the one primary action on a page.
struct SolidButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onKnob)
                .padding(.horizontal, 16).frame(height: 32)
                .background(Theme.knob).clipShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// "Allowed" with a tick once done; a small solid button until then.
private struct StatusControl: View {
    let done: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        if done {
            Label("Allowed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
        } else {
            RowButton(title: label, action: action)
        }
    }
}

private struct AgentsStep: View {
    @State private var claude: String?? = .none // nil while looking; .some(nil) when absent
    @State private var codex: String?? = .none
    @State private var plugin: Bool?
    @State private var pluginError: String?

    var body: some View {
        VStack(spacing: 0) {
            OnboardingRow(icon: "sparkle", picture: choiceIcon("claude"), title: "Claude Code", detail: claudeDetail) {
                if case .some(.some) = claude {
                    if let plugin {
                        if plugin {
                            Label("Plugin added", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                        } else {
                            RowButton(title: "Add plugin") {
                                self.plugin = nil
                                Task { pluginError = await ClaudePlugin.install(); self.plugin = await ClaudePlugin.isInstalled() }
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let pluginError { Text(pluginError).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            Divider()
            OnboardingRow(icon: "chevron.left.forwardslash.chevron.right", picture: choiceIcon("openai"), title: "Codex", detail: codexDetail) {
                if case .some(.some) = codex { RowButton(title: "Coming soon", enabled: false) }
            }
        }
        .task {
            claude = .some(await ShellTool.version("claude"))
            codex = .some(await ShellTool.version("codex"))
            plugin = await ClaudePlugin.isInstalled()
        }
    }

    private var claudeDetail: String {
        switch claude {
        case .none: return "Looking…"
        case .some(.none): return "Not found on this Mac. Install Claude Code, then return to this step."
        case .some(.some(let version)): return "Version \(version.versionNumber). " + (plugin == true ? "Agents Zero starts ask you here." : "The Zero plugin makes agents ask you here.")
        }
    }

    private var codexDetail: String {
        switch codex {
        case .none: return "Looking…"
        case .some(.none): return "Not found on this Mac."
        case .some(.some(let version)): return "Version \(version.versionNumber). Zero starts Codex agents."
        }
    }
}

private struct PermissionsStep: View {
    @State private var notifications = false
    @State private var microphone = false
    @State private var speech = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingRow(icon: "bell.badge", title: "Notifications", detail: "So an ask reaches you while you are in another app.") {
                StatusControl(done: notifications, label: "Allow") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        await refresh()
                    }
                }
            }
            Divider()
            OnboardingRow(icon: "mic", title: "Microphone", detail: "To dictate a reply instead of typing it.") {
                StatusControl(done: microphone, label: "Allow") {
                    Task { _ = await AVCaptureDevice.requestAccess(for: .audio); await refresh() }
                }
            }
            Divider()
            OnboardingRow(icon: "waveform", title: "Speech recognition", detail: "Turns what you say into text, on this Mac.") {
                StatusControl(done: speech, label: "Allow") {
                    SFSpeechRecognizer.requestAuthorization { _ in Task { @MainActor in await refresh() } }
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speech = SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}

/// The cube, drawn from the bundled mark as a template so it takes the text colour in either appearance.
struct ZeroMark: View {
    var small = false
    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
    private static let large = load("mark"), compact = load("mark-small")
    var body: some View {
        if let image = small ? Self.compact : Self.large { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).foregroundStyle(.primary) }
    }
}

/// Finds a command the way Arsen's terminal would, and its version line.
enum ShellTool {
    static func version(_ tool: String) async -> String? {
        await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v \(tool) >/dev/null && \(tool) --version 2>/dev/null | head -1"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? "installed" : line
        }.value
    }
}

private extension String {
    /// "2.1.304 (Claude Code)" and "codex-cli 0.160.1" both read "2.1.304", "0.160.1".
    var versionNumber: String {
        range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(self[$0]) } ?? self
    }
}
