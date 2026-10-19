import AppKit
import Carbon.HIToolbox
import SwiftUI
import ZeroCore

struct SettingsView: View {
    @Bindable var settings: Settings
    let store: Store
    let inbox: InboxController
    @State private var microphones: [(name: String, uid: String)] = []
    @State private var newPattern = ""

    private func addPattern() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        settings.dropPatterns.append(pattern)
        newPattern = ""
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Zero at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                Toggle("Follow the active screen", isOn: $settings.followActiveScreen)
                Text("Off: Zero stays on one screen until you move it from the menu bar.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Asks") {
                Stepper("Default expiry: \(settings.defaultTTLMinutes) min", value: $settings.defaultTTLMinutes, in: 1...1440, step: 5)
                Text("Applies when an agent's `zero ask` passes no --ttl.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Take-back window")
                    Slider(value: $settings.takeBackSeconds, in: 0...5, step: 0.5)
                    Text(String(format: "%.1f s", settings.takeBackSeconds)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Toggle("Move to the next question 3 s after an answer lands", isOn: $settings.autoAdvance)
                LabeledContent("Talk hotkey") { HotKeyRecorder(settings: settings) }
                Text("Opens the inbox on the oldest waiting ask and starts dictation.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Picker("Dictate with", selection: Binding(get: { settings.inputDeviceUID ?? "" }, set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.uid) { mic in Text(mic.name).tag(mic.uid) }
                }
                .onAppear { microphones = Dictation.inputDevices() }
                if let uid = settings.inputDeviceUID, !microphones.contains(where: { $0.uid == uid }) {
                    Text("The chosen microphone isn't connected; the system default is used until it is.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Agents") {
                let names = agentNames
                if names.isEmpty {
                    Text("No agents yet.").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(names, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                Button("Close") { store.closeAgent(name) }.buttonStyle(.borderless)
                            }
                        }
                        .onMove { from, to in
                            var order = names
                            order.move(fromOffsets: from, toOffset: to)
                            settings.agentOrder = order
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 200)
                    Text("Drag to reorder the bar. Close removes an agent until it speaks again.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Adapters") {
                ForEach(store.adapters, id: \.name) { adapter in
                    LabeledContent(adapter.name.capitalized) {
                        Text(adapterStatus(adapter)).foregroundStyle(.secondary)
                    }
                }
                Text("How Zero delivers your messages into an agent's session.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Drop folders") {
                ForEach(settings.dropPatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { settings.dropPatterns.removeAll { $0 == pattern } }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("~/path/or/glob/*/.zero", text: $newPattern).textFieldStyle(.roundedBorder)
                        .onSubmit(addPattern)
                    Button("Add", action: addPattern).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.dropPatterns.append(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        }
                    }
                }
                Text("Asks arrive as files in these folders and answers go back the same way. Any folder another machine syncs with this Mac works: Zero keeps a small `zero` client in each one for the other side to call. Globs match many folders at once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Log") {
                LabeledContent("File") {
                    Text(Paths.log.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    Button("Open") { NSWorkspace.shared.open(Paths.log) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.log]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private var agentNames: [String] {
        var seen: [String] = []
        for ask in store.asks where ask.state != .expired && !seen.contains(ask.agent.name) { seen.append(ask.agent.name) }
        let open = seen.filter { name in AgentStatus.of(store.asks.filter { $0.agent.name == name }) != .closed }
        return settings.sorted(open)
    }

    private func adapterStatus(_ adapter: AgentAdapter) -> String {
        if let solo = adapter as? SoloAdapter {
            let helper = FileManager.default.isExecutableFile(atPath: solo.helper)
            let socket = FileManager.default.fileExists(atPath: Paths.dir.deletingLastPathComponent().appendingPathComponent(".config/soloterm/solo-mcp.sock").path)
            return helper ? (socket ? "Ready (MCP helper)" : "Solo app not running") : "Solo.app not found"
        }
        return "Available"
    }
}

/// Click, press a combination, done. Stores the key code and Carbon modifiers the hotkey needs.
struct HotKeyRecorder: View {
    @Bindable var settings: Settings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : settings.hotKeyLabel) {
            recording ? stop() : start()
        }
        .frame(minWidth: 120)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { return nil }
            var carbon = 0
            if flags.contains(.command) { carbon |= cmdKey }
            if flags.contains(.option) { carbon |= optionKey }
            if flags.contains(.control) { carbon |= controlKey }
            if flags.contains(.shift) { carbon |= shiftKey }
            settings.hotKeyLabel = label(flags: flags, event: event)
            settings.hotKeyModifiers = carbon
            settings.hotKeyCode = Int(event.keyCode)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func label(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→"]
        let key = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return parts.joined() + " " + key
    }
}
