import AppKit
import Observation
import SwiftUI
import ZeroCore

/// The empty inbox: the composer's colour, edge and height, centred on the bar, with the bar's inbox icon. New agents start
/// from the bar's + button.
struct QuietCard: View {
    let controller: InboxController
    var body: some View {
        VStack(spacing: 6) {
            NucleoIcon("inbox", size: 26).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("Inbox empty").font(.system(size: 15, weight: .semibold))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: controller.composerHeight)
        .background(Theme.composer)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// The text box used for replies and messages: the text column stops at ~80% of the width and wraps there,
/// growing a line at a time; the mic and send buttons stay pinned to the bottom-right corner.
struct ReplyBox: View {
    let placeholder: String
    @Binding var text: String
    let key: String
    var focus: FocusState<String?>.Binding
    let dictating: Bool
    let onMic: () -> Void
    let onSend: () -> Void
    /// Focused as it appears (an option opening into it).
    var autofocus = false
    @State private var pasting: Any?
    /// Told when this box gains or loses focus: a question card on the composer stays up while it's typed in (the
    /// pointer, hidden while typing, no longer holds it there).
    @Environment(\.dockFocus) private var dockFocus

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...8)
                .focused(focus, equals: key)
                .onSubmit(onSend)
                .padding(.trailing, 56)
                // Same inner height as an option row's key cap, so a row turning into an input doesn't change size.
                .frame(minHeight: 18, alignment: .leading)
            HStack(spacing: 10) {
                Button(action: onMic) {
                    NucleoIcon(dictating ? "waveform-lines" : "microphone", size: 15).foregroundStyle(dictating ? .red : .secondary)
                }.buttonStyle(.plain)
                Button(action: onSend) {
                    NucleoIcon("paper-plane", size: 15).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        // The whole box is the field: a click on its padding focuses it too.
        .contentShape(Rectangle()).onTapGesture { focus.wrappedValue = key }
        // An image pasted (⌘V) while it's focused: kept as the composer's are, its path in the words, for the agent to
        // open. The field alone drops an image.
        .onAppear {
            let (focus, key, text) = (focus, key, $text)
            pasting = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focus.wrappedValue == key, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                    event.charactersIgnoringModifiers == "v", let urls = Attachments.fromPasteboard(), !urls.isEmpty
                else { return event }
                let words = text.wrappedValue
                text.wrappedValue = words + (words.isEmpty || words.hasSuffix(" ") ? "" : " ") + urls.map(\.path).joined(separator: " ")
                return nil
            }
        }
        .onDisappear {
            if let pasting { NSEvent.removeMonitor(pasting) }; if focus.wrappedValue == key { dockFocus?(false) }
        }
        .onChange(of: focus.wrappedValue == key) { _, on in dockFocus?(on) }
        // A moment after appearing: in the same update, the field can't take focus yet and it's dropped.
        .task { if autofocus { try? await Task.sleep(for: .milliseconds(50)); focus.wrappedValue = key } }
    }
}

/// The composer's box: flush with its card's sides and bottom, bottom corners on the card's radius, and a top
/// edge whose ends sweep up into the card's walls (concave fillets), so no sliver of card shows beside a corner.

/// An icon the app bundles for an adapter's choice (claude, openai), by resource name. Built once.
@MainActor private var iconCache: [String: Image] = [:]

@MainActor func choiceIcon(_ name: String?) -> Image? {
    guard let name else { return nil }
    if let cached = iconCache[name] { return cached }
    let built = buildChoiceIcon(name)
    if let built { iconCache[name] = built }
    return built
}

private func buildChoiceIcon(_ name: String) -> Image? {
    // Zero's own icon, for its own terminals.
    let apps: [String: String?] = ["zero": Bundle.main.bundlePath]
    if let entry = apps[name] {
        guard let path = entry else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return Image(nsImage: icon)
    }
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else { return nil }
    if name == "openai" { return Image(nsImage: onWhiteTile(image)) }
    return Image(nsImage: image)
}

/// OpenAI's mark as OpenAI now shows it: black on a white rounded square. The asset's shape is used as a mask,
/// so it renders black whatever colour the file was drawn in.
private func onWhiteTile(_ mark: NSImage) -> NSImage {
    let size = NSSize(width: 64, height: 64)
    let tile = NSImage(size: size)
    tile.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()
    if let context = NSGraphicsContext.current?.cgContext, let cg = mark.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let inset = CGRect(x: 10, y: 10, width: 44, height: 44)
        context.saveGState()
        context.clip(to: inset, mask: cg)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(inset)
        context.restoreGState()
    }
    tile.unlockFocus()
    return tile
}

/// The composer, the same card everywhere: the prompt or message and pills for where and with what. Behind the
/// bar's + button it starts an agent (project, runtime and model); in a conversation it messages that agent (its
/// model only, since a conversation does not change project). It hangs from the bar's bottom line in every view,
/// so it does not move as views switch.
struct ComposerCard: View {
    enum Mode { case newAgent, agent(String) }
    @Bindable var controller: InboxController
    var focus: FocusState<String?>.Binding
    let mode: Mode
    @State private var projectAnchor = CGRect.zero
    @State private var runtimeAnchor = CGRect.zero
    @State private var fieldHeight = ComposeField.lineHeight * 2
    @State private var mentionHeight: CGFloat = 0

    private var agentName: String? { if case .agent(let name) = mode { return name } else { return nil } }
    private var key: String { agentName.map { controller.composerKey($0) } ?? InboxController.newAgentKey }
    private var runtime: SpawnChoice? {
        agentName.flatMap { controller.runtime(of: $0) } ?? controller.spawnRuntimes.first { $0.id == controller.spawnRuntime }
    }
    private var model: SpawnChoice? {
        if let agentName {
            guard let id = controller.agentModels[agentName], let runtime else { return nil }
            return controller.adapter(of: agentName)?.spawnModels(for: runtime).first { $0.id == id }
        }
        return controller.spawnModels.first { $0.id == controller.spawnModel }
    }
    private var project: SpawnChoice? { controller.spawnTargets.first { $0.id == controller.spawnTarget } }
    /// The model's effort level, when it has levels: the one picked for it, else its default.
    private var effort: String? {
        guard let model, !model.levels.isEmpty else { return nil }
        return (controller.spawnSettings[model.id]?["reasoning"] ?? model.defaultLevel).map { effortLabel($0, short: true) }
    }
    /// The account the agent runs as, when it isn't the active one: the part of the address before the @.
    private var account: String? {
        agentName.flatMap { controller.store.identity(of: $0)?.account }.map { String($0.split(separator: "@").first ?? Substring($0)) }
    }
    private var placeholder: String {
        agentName.map { "Message \(controller.store.displayName(of: $0))…" } ?? "What should a new agent work on?"
    }
    /// Busy: the agent being started, or the message on its way to the agent.
    private var starting: Bool { agentName.map { controller.delivering.contains($0) } ?? controller.spawning }
    private var error: String? { agentName.map { controller.deliveryError[$0] } ?? controller.spawnError }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            composer
                .padding(14)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: { height in
                    if height > 0, abs(controller.composerHeight - height) > 0.5 { controller.composerHeight = height }
                }
                // The whole box focuses the text, not just its line: a click in the padding or between the chips
                // starts typing. The chips and buttons keep their own clicks.
                .contentShape(RoundedRectangle(cornerRadius: 18))
                .onTapGesture {
                    // Already the focused box but not holding the keyboard (another app took it): set it again.
                    if controller.focusedReply == key { controller.focusedReply = nil }
                    DispatchQueue.main.async { controller.focusedReply = key }
                }
                .background(Theme.composer)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
        }
        // Suggestions for "/" and "@" sit just above the composer, over whatever is there.
        .overlay(alignment: .top) {
            if let state = controller.mention, state.key == key, controller.focusedReply == key {
                MentionList(state: state, pick: { controller.acceptMention($0) }, hover: { controller.mention?.selected = $0 })
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        mentionHeight = $0
                    }
                    .offset(y: -mentionHeight - 6)
            }
        }
        .onAppear { controller.loadSpawnChoices() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            ComposeField(
                text: Binding(get: { controller.drafts[key, default: ""] }, set: { controller.drafts[key] = $0 }),
                placeholder: placeholder, focused: controller.focusedReply == key,
                editable: !starting, // the words stay put, read-only, while they go out
                caret: controller.caretRequest[key], onCaretApplied: { controller.caretRequest[key] = nil },
                onFocus: { focused in
                    if focused { controller.focusedReply = key } else if controller.focusedReply == key { controller.focusedReply = nil }
                },
                onSubmit: submit,
                onTrigger: { controller.updateMention(key: key, trigger: $0) },
                onKey: { controller.mentionKey($0, for: key) },
                highlightFiles: controller.suggestFiles,
                height: $fieldHeight
            )
            .frame(height: fieldHeight)
            .padding(.horizontal, -TokenTextView.inset.width) // text still starts under the card's 14 pt
            HStack(spacing: 6) {
                if agentName == nil {
                    // Where: grouped by adapter, each project with its path.
                    chip(
                        icon: choiceIcon(project?.icon) ?? Image(nsImage: Nucleo.image("folder", size: 14) ?? NSImage()),
                        title: project?.name ?? "Project",
                        open: controller.selector?.kind == .project
                    ) {
                        controller.selectorAgent = nil; controller.openSelector(.project, anchor: projectAnchor)
                    }
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        projectAnchor = $0
                    }
                }
                // With what: the runtime's icon and the model's name (an agent's own runtime name until a model is picked for it).
                chip(
                    icon: choiceIcon(runtime?.icon) ?? Image(nsImage: Nucleo.image("terminal", size: 14) ?? NSImage()),
                    title: model.map {
                        $0.id.isEmpty
                            ? (runtime?.name ?? "Default")
                            : $0.name + (effort.map { " · " + $0 } ?? "") + (account.map { " · " + $0 } ?? "")
                    }
                        ?? agentName.map { controller.store.zeroTask?($0)?.runs ?? speaker($0) } ?? runtime?.name ?? "Runtime",
                    open: controller.selector?.kind == .runtime
                ) {
                    controller.selectorAgent = agentName; controller.openSelector(.runtime, anchor: runtimeAnchor)
                }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    runtimeAnchor = $0
                }
                Spacer(minLength: 8)
                if starting { Spinner().frame(width: 12, height: 12).padding(.trailing, 4) }
                Button {
                    controller.toggleDictation()
                } label: {
                    NucleoIcon(controller.dictatingFor == key ? "waveform-lines" : "microphone", size: 15)
                        .foregroundStyle(controller.dictatingFor == key ? .red : .secondary)
                }.buttonStyle(.plain)
                Button(action: submit) {
                    NucleoIcon("circle-arrow-up", fill: "glyph", size: 20)
                        .foregroundStyle(controller.drafts[key, default: ""].isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                }.buttonStyle(.plain)
            }
            if let error {
                NucleoLabel(error, icon: "circle-warning", size: 12).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func submit() {
        if agentName == nil { controller.spawn() } else { controller.send(key) }
    }

    /// A small pill: icon, current value, chevron. Opens one of Zero's selectors; reads pressed while it is open.
    private func chip(icon: Image, title: String, open: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.chip).clipShape(Capsule())
            .overlay(Capsule().strokeBorder(open ? Theme.selectedStroke : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
