import AppKit
import Observation
import SwiftUI
import ZeroCore

/// Selection, drafts, dictation and the keyboard map for the inbox panel.
@MainActor @Observable
final class InboxController {
    let store: Store
    let dictation = Dictation()
    var selected: String?
    var drafts: [String: String] = [:]
    var focusedReply: String?
    var dictatingFor: String?
    var agentFilter: String?
    /// True while the inbox is pinned open by a click; the pinned control shows a pin badge.
    var pinned = false
    /// Set for the frame in which the view switches (agent ↔ inbox): that change is a cut, not a morph.
    var switching = false
    /// Per ask: the command box and options heights measured while waiting, so a run's terminal keeps that
    /// exact space even if the card is rebuilt (it changes group in an agent's view once answered).
    @ObservationIgnored var measured: [String: (command: CGFloat, options: CGFloat)] = [:]

    /// Changes the view with no animation and no card entrances.
    func show(agent: String?) {
        guard agentFilter != agent else { return }
        switching = true
        agentFilter = agent
        seen.formUnion(cards.map(\.id))
        ensureSelection()
        requestScroll(animated: false)
        DispatchQueue.main.async { self.switching = false }
    }
    /// The new-agent composer: choices loaded from the spawning adapter, last picks remembered.
    var spawnTargets: [SpawnChoice] = []
    var spawnRuntimes: [SpawnChoice] = []
    var spawnTarget: String? = UserDefaults.standard.string(forKey: "lastSpawnTarget") {
        didSet { UserDefaults.standard.set(spawnTarget, forKey: "lastSpawnTarget") }
    }
    var spawnRuntime: String? = UserDefaults.standard.string(forKey: "lastSpawnRuntime") {
        didSet { UserDefaults.standard.set(spawnRuntime, forKey: "lastSpawnRuntime") }
    }
    var spawning = false
    var spawnError: String?
    /// The open selector, if any, and how the app shows and hides it (an anchored panel of its own).
    var selector: SelectorState?
    @ObservationIgnored var presentSelector: ((CGRect) -> Void)?
    @ObservationIgnored var dismissSelector: (() -> Void)?
    /// Per-model configuration Arsen picked in the preview card, such as a reasoning level.
    var spawnSettings: [String: [String: String]] = (UserDefaults.standard.dictionary(forKey: "spawnSettings") as? [String: [String: String]]) ?? [:]

    func setSpawnSetting(modelID: String, key: String, value: String) {
        spawnSettings[modelID, default: [:]][key] = value
        UserDefaults.standard.set(spawnSettings, forKey: "spawnSettings")
    }

    @ObservationIgnored private var selectorClosedAt = Date.distantPast
    @ObservationIgnored private var selectorClosedKind: SelectorKind?

    func openSelector(_ kind: SelectorKind, anchor: CGRect) {
        if let selector, selector.kind == kind { closeSelector(); return }
        // The click on the chip that should close the selector first closes it through the click-outside
        // monitor, then arrives here: within a third of a second of that close, on the same chip, it is
        // that close. A click on the other chip is a switch and opens straight away.
        if selectorClosedKind == kind, Date().timeIntervalSince(selectorClosedAt) < 0.3 { return }
        let state = SelectorState(kind: kind)
        state.sections = selectorSections(for: kind) // once: the rows read catalogues from disk
        selector = state
        presentSelector?(anchor)
    }

    func closeSelector() {
        guard let selector else { return }
        selectorClosedAt = Date()
        selectorClosedKind = selector.kind
        self.selector = nil
        dismissSelector?()
    }

    /// Rows for the selector: projects grouped by adapter, or models grouped by runtime.
    func selectorSections(for kind: SelectorKind) -> [SelectorSection] {
        switch kind {
        case .project:
            return [SelectorSection(id: "solo", title: "Solo projects", icon: choiceIcon("solo"), rows: spawnTargets.map { choice in
                SelectorRow(id: choice.id, title: choice.name, provider: choice.provider, providerIcon: choiceIcon(choice.icon),
                            detail: choice.detail, context: nil, levels: [], defaultLevel: nil, modelID: nil,
                            selected: choice.id == spawnTarget) { [weak self] in self?.spawnTarget = choice.id }
            })]
        case .runtime:
            _ = modelsVersion
            guard let adapter = store.spawners.first else { return [] }
            return spawnRuntimes.map { runtime in
                let models = adapter.spawnModels(for: runtime)
                let rows: [SelectorRow] = models.isEmpty
                    ? [SelectorRow(id: runtime.id, title: runtime.name, provider: runtime.provider, providerIcon: choiceIcon(runtime.icon),
                                   detail: runtime.detail, context: nil, levels: [], defaultLevel: nil, modelID: nil,
                                   selected: runtime.id == spawnRuntime) { [weak self] in self?.spawnRuntime = runtime.id }]
                    : models.map { model in
                        SelectorRow(id: runtime.id + "/" + model.id, title: model.name, provider: model.provider ?? runtime.provider,
                                    providerIcon: choiceIcon(model.icon ?? runtime.icon), detail: model.detail, context: model.context,
                                    levels: model.levels, defaultLevel: model.defaultLevel, modelID: model.id.isEmpty ? runtime.id + "/default" : model.id,
                                    selected: runtime.id == spawnRuntime && model.id == spawnModel) { [weak self] in
                            self?.spawnRuntime = runtime.id
                            self?.spawnModel = model.id
                        }
                    }
                return SelectorSection(id: runtime.id, title: runtime.provider ?? runtime.name, icon: choiceIcon(runtime.icon), rows: rows)
            }
        }
    }
    /// Models for the chosen runtime, and the pick remembered per runtime.
    var spawnModels: [SpawnChoice] { _ = modelsVersion; return store.spawners.first.flatMap { adapter in spawnRuntimes.first { $0.id == spawnRuntime }.map { adapter.spawnModels(for: $0) } } ?? [] }
    var spawnNote: String? { store.spawners.first.flatMap { adapter in spawnRuntimes.first { $0.id == spawnRuntime }.flatMap { adapter.spawnNote(for: $0) } } }
    var spawnModel: String? {
        get { spawnRuntime.flatMap { UserDefaults.standard.string(forKey: "lastSpawnModel.\($0)") } ?? spawnModels.first?.id }
        set { if let spawnRuntime { UserDefaults.standard.set(newValue, forKey: "lastSpawnModel.\(spawnRuntime)") } }
    }
    static let newAgentKey = "new:"
    /// Ask id → index of the text option whose input is open on that card.
    var textOption: [String: Int] = [:]
    /// Bumped when the view should scroll the selected card to the bar's centre line (never on hover selection).
    var scrollRequest = 0
    @ObservationIgnored var scrollAnimated = false
    /// Settings: move on to the next waiting card a few seconds after an answer turns green.
    @ObservationIgnored var autoAdvance = true
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    /// The card last answered, so Esc can take it back even after the selection has moved on.
    @ObservationIgnored var lastAnswered: String?
    /// The bar's current height, so the list's scroll limits can sit level with its top and bottom.
    var barHeight: CGFloat = 200
    /// When the inbox last opened: answered cards stay visible until the next open, then they're gone.
    var inboxOpenedAt = Date()
    /// Cards that have been shown once; a card not in here slides in the first time it appears.
    @ObservationIgnored var seen: Set<String> = []
    @ObservationIgnored var hide: () -> Void = {}

    func requestScroll(animated: Bool = false) { scrollAnimated = animated; scrollRequest += 1 }

    /// Called when a card turns final: three seconds later, if nothing has been selected by hand since,
    /// the next waiting card becomes active and glides to the bar.
    func scheduleAdvance(after id: String) {
        advanceTask?.cancel()
        guard autoAdvance, selected == id else { return }
        advanceTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, selected == id,
                  let next = cards.first(where: { $0.state == .waiting }) else { return }
            selected = next.id
            requestScroll(animated: true)
        }
    }

    private func cancelAdvance() { advanceTask?.cancel(); advanceTask = nil }

    init(store: Store) { self.store = store }

    /// Chat order, oldest at the top. Inbox: open asks, plus what was answered since the inbox opened.
    /// Agent view: that agent's timeline. Expired asks never show.
    var cards: [Ask] {
        if let agentFilter { return store.asks.filter { $0.agent.name == agentFilter && $0.state != .expired } }
        return store.asks.filter {
            $0.kind != .note && $0.kind != .message && $0.state != .expired
                && (!$0.state.isFinal || ($0.answeredAt ?? .distantPast) >= inboxOpenedAt)
        }
    }

    /// One line on where an agent is, from its latest ask or note.
    func summary(of agent: String) -> String {
        guard let latest = store.asks.last(where: { $0.agent.name == agent }) else { return "No asks yet" }
        let when = (latest.answeredAt ?? latest.createdAt).formatted(.relative(presentation: .named))
        switch latest.state {
        case .waiting, .pending: return "Needs you · \(latest.title)"
        case .running: return "Running your command"
        case .answered: return latest.kind == .note ? "\(latest.body) · \(when)" : "Answered \(when)"
        case .declined: return "Rejected \(when)"
        case .expired: return "Ask expired \(when)"
        }
    }

    /// Keeps the selection on a waiting card in the current view: the oldest one unless a waiting card is already
    /// selected. A selection left on an answered card would make every shortcut a no-op.
    func ensureSelection() {
        let visible = cards
        let waiting = visible.filter { $0.state == .waiting }
        if let selected, let current = visible.first(where: { $0.id == selected }),
           current.state == .waiting || waiting.isEmpty { return }
        selected = waiting.first?.id ?? visible.last?.id
        requestScroll()
    }

    func select(_ id: String) { cancelAdvance(); selected = id }

    func move(_ delta: Int) {
        ensureSelection()
        let ids = cards.map(\.id)
        guard let selected, let index = ids.firstIndex(of: selected) else { return }
        cancelAdvance()
        self.selected = ids[max(0, min(ids.count - 1, index + delta))]
        requestScroll()
    }

    /// Picks an option; a text option opens its input on the card instead of answering straight away.
    func choose(_ index: Int, on id: String? = nil) {
        guard let id = id ?? selected, let ask = store.ask(id), index < ask.options.count else { return }
        if Ask.expectsText(ask.options[index]) {
            textOption[id] = index
            focusedReply = id
        } else {
            lastAnswered = id
            store.choose(id, option: index)
        }
    }

    func cancelTextOption(_ id: String) {
        textOption[id] = nil
        drafts[id] = nil
        if focusedReply == id { focusedReply = nil }
    }

    func send(_ key: String) {
        let text = drafts[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if dictatingFor == key { stopDictation() }
        drafts[key] = nil
        focusedReply = nil
        if key == Self.newAgentKey {
            drafts[key] = text
            spawn()
        } else if key.hasPrefix("msg:") {
            let agent = String(key.dropFirst(4))
            Task { await store.message(text, to: agent) }
        } else if let index = textOption[key] {
            textOption[key] = nil
            lastAnswered = key
            store.answer(key, option: index, text: text)
        } else {
            lastAnswered = key
            store.reply(key, text: text)
        }
    }

    func dismiss(_ id: String) {
        let index = cards.firstIndex { $0.id == id } ?? 0
        store.dismiss(id)
        let remaining = cards
        if selected == id { selected = remaining.indices.contains(index) ? remaining[index].id : remaining.last?.id }
    }

    /// True when the cards in view include something to answer.
    var answerable: Bool { cards.contains { $0.state == .waiting } }
    /// True in an agent's view when an adapter can carry a message into that agent's session.
    var composable: Bool { agentFilter.map { store.canMessage($0) } ?? false }
    /// Only then does the inbox take the keyboard.
    var takesKeys: Bool { answerable || composable }

    func composerKey(_ agent: String) -> String { "msg:" + agent }

    var canSpawn: Bool { !store.spawners.isEmpty }

    /// Bumped when a model list changes, so views that compute from the adapters re-read.
    var modelsVersion = 0

    func loadSpawnChoices() {
        guard let adapter = store.spawners.first else { return }
        Task {
            if spawnTargets.isEmpty {
                let targets = (try? await adapter.spawnTargets()) ?? []
                let runtimes = (try? await adapter.spawnRuntimes()) ?? []
                spawnTargets = targets
                spawnRuntimes = runtimes
                if spawnTarget == nil || !targets.contains(where: { $0.id == spawnTarget }) { spawnTarget = targets.first?.id }
                if spawnRuntime == nil || !runtimes.contains(where: { $0.id == spawnRuntime }) { spawnRuntime = runtimes.first?.id }
            }
            if await adapter.refreshModels() {
                modelsVersion += 1
                if let selector { selector.sections = selectorSections(for: selector.kind) }
            }
        }
    }

    func spawn() {
        let prompt = drafts[Self.newAgentKey, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !spawning, let adapter = store.spawners.first,
              let target = spawnTargets.first(where: { $0.id == spawnTarget }),
              let runtime = spawnRuntimes.first(where: { $0.id == spawnRuntime }) else { return }
        let model = spawnModels.first { $0.id == spawnModel }
        let settings = model.flatMap { spawnSettings[$0.id] } ?? [:]
        if dictatingFor == Self.newAgentKey { stopDictation() }
        spawning = true
        spawnError = nil
        focusedReply = nil
        // Cleared now, not when the spawn finishes: Return in an AppKit text field selects its text, and the
        // prompt sat there highlighted for the seconds Solo takes. It comes back if the spawn fails.
        drafts[Self.newAgentKey] = nil
        Task {
            do {
                let identity = try await store.spawn(prompt: prompt, adapter: adapter, target: target, runtime: runtime, model: model, settings: settings)
                show(agent: identity.name)
            } catch {
                spawnError = error.localizedDescription
                drafts[Self.newAgentKey] = prompt
            }
            spawning = false
        }
    }

    /// Where typing or dictation goes: the selected waiting card's own input (a free-text question, or its
    /// text option, which opens), else the agent composer.
    var typingTarget: String? {
        ensureSelection()
        if let selected, let ask = store.ask(selected), ask.state == .waiting {
            if ask.options.isEmpty || textOption[selected] != nil { return selected }
            if let index = ask.options.firstIndex(where: Ask.expectsText) { textOption[selected] = index; return selected }
        }
        if let agentFilter, store.canMessage(agentFilter) { return composerKey(agentFilter) }
        if agentFilter == nil, canSpawn { return Self.newAgentKey }
        return nil
    }

    /// Returns true when the key was consumed. Outside the reply field: 1–3 pick, arrows move, Enter focuses the
    /// reply, Delete dismisses a finished card, Space toggles the mic, and any other character starts the reply.
    func handle(_ event: NSEvent) -> Bool {
        ensureSelection()
        let editing = event.window?.firstResponder is NSTextView
        let key = event.charactersIgnoringModifiers ?? ""
        if event.keyCode == 53 { // escape
            if selector != nil { closeSelector(); return true }
            if dictatingFor != nil { stopDictation(); return true }
            if let selected, textOption[selected] != nil { cancelTextOption(selected); event.window?.makeFirstResponder(nil); return true }
            if let last = lastAnswered, store.takeBack(last) { cancelAdvance(); selected = last; return true }
            if editing { focusedReply = nil; event.window?.makeFirstResponder(nil); return true }
            if agentFilter != nil { agentFilter = nil; return true }
            hide()
            return true
        }
        if editing || !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        switch event.keyCode {
        case 126: move(-1); return true
        case 125: move(1); return true
        case 36: focusedReply = typingTarget; return true
        case 51: if let selected, store.ask(selected)?.state.isFinal == true { dismiss(selected) }; return true
        default: break
        }
        switch key {
        case "1", "2", "3": choose(Int(key)! - 1); return true
        case " ": toggleDictation(); return true
        default:
            guard let target = typingTarget, let scalar = key.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar) else { return false }
            drafts[target, default: ""] += key
            focusedReply = target
            return true
        }
    }

    func toggleDictation() { dictatingFor == nil ? startDictation() : stopDictation() }

    func startDictation() {
        guard let key = typingTarget else { return }
        dictatingFor = key
        focusedReply = key
        let base = drafts[key, default: ""].trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await dictation.start { [weak self] text in
                    self?.drafts[key] = base.isEmpty ? text : base + " " + text
                }
            } catch {
                drafts[key] = "mic: \(error.localizedDescription)"
                dictatingFor = nil
            }
        }
    }

    func stopDictation() {
        dictatingFor = nil
        Task { await dictation.stop() }
    }
}

/// The active card sits on the bar's centre line. Half a panel of padding above and below the list lets any card
/// be scrolled to the centre, including the first and last.
struct InboxView: View {
    @Bindable var controller: InboxController
    @FocusState private var focus: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        if controller.agentFilter != nil {
                            AgentTimeline(controller: controller, focus: $focus)
                        } else {
                            ForEach(controller.cards) { ask in
                                CardView(ask: ask, controller: controller, focus: $focus)
                                    .id(ask.id)
                                    .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeIn(duration: 0.15))))
                            }
                            if controller.canSpawn {
                                NewAgentCard(controller: controller, focus: $focus, quiet: controller.cards.isEmpty)
                            } else if controller.cards.isEmpty {
                                Text("All quiet.").font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(18).card()
                            }
                        }
                    }
                    // One frosted surface under the stack, so the gaps between cards never show raw desktop.
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    // Padding equal to the gap between panel edge and bar edge: scrolled to either end, the list
                    // stops level with the bar's top or bottom, and a list no taller than the bar cannot scroll.
                    .padding(.vertical, max(0, (geo.size.height - controller.barHeight) / 2))
                    // Outermost on purpose: the stack and its surface grow together when a card joins.
                    // A view switch is excluded: that is a cut.
                    .animation(reduceMotion || controller.switching ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.22),
                               value: controller.cards.map { "\($0.id)/\($0.state.rawValue)" })
                }
                .onChange(of: controller.cards.map(\.id)) { _, _ in
                    // A new card pushes the stack: re-centre so the cards above drift up as it takes its place.
                    controller.ensureSelection()
                    if controller.switching || reduceMotion {
                        center(proxy)
                    } else {
                        withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.22)) { center(proxy) }
                    }
                }
                // Content dissolves into the edges instead of being sliced by them.
                .mask(VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 40)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 40)
                })
                .onAppear { center(proxy) }
                .onChange(of: controller.scrollRequest) {
                    if controller.scrollAnimated && !reduceMotion {
                        withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.25)) { center(proxy) }
                    } else {
                        center(proxy)
                    }
                }
                .onChange(of: controller.selected.flatMap { controller.store.ask($0)?.state }) { _, state in
                    if let state, state.isFinal, let id = controller.selected { controller.scheduleAdvance(after: id) }
                }
            }
        }
        .frame(width: 380)
        .onChange(of: controller.focusedReply) { _, id in focus = id }
        .onChange(of: focus) { _, id in controller.focusedReply = id }
    }

    /// The selected card goes to the bar's centre line, as far as the scroll limits allow.
    private func center(_ proxy: ScrollViewProxy) {
        guard let id = controller.selected else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

extension View {
    /// Card chrome: surface, radius and the hairline that separates it from the desktop.
    func card() -> some View {
        background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Surfaces for both appearances, resolved by AppKit at draw time so the system setting applies live.
enum Theme {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static let card = dynamic(dark: NSColor(white: 0.11, alpha: 1), light: NSColor(white: 1, alpha: 1))
    static let row = dynamic(dark: NSColor(white: 0.16, alpha: 1), light: NSColor(white: 0.94, alpha: 1))
    static let keycap = dynamic(dark: NSColor(white: 0.22, alpha: 1), light: NSColor(white: 0.86, alpha: 1))
    /// A fully solid knob; `.primary` is a translucent label colour.
    static let knob = dynamic(dark: .white, light: .black)
    static let code = dynamic(dark: NSColor(white: 0, alpha: 0.35), light: NSColor(white: 0, alpha: 0.05))
    static let pill = dynamic(dark: NSColor(white: 0, alpha: 0.9), light: NSColor(white: 1, alpha: 0.96))
    // Opaque, so a border is one colour along its length whatever sits behind each segment.
    static let hairline = dynamic(dark: NSColor(white: 0.30, alpha: 1), light: NSColor(white: 0.82, alpha: 1))
    static let stroke = dynamic(dark: NSColor(white: 0.24, alpha: 1), light: NSColor(white: 0.86, alpha: 1))
    static let selectedStroke = dynamic(dark: NSColor(white: 0.45, alpha: 1), light: NSColor(white: 0.65, alpha: 1))
    /// Key cap fills for a chosen option: deeper in dark mode so the white digit keeps its contrast.
    static let greenCap = dynamic(dark: NSColor(red: 0.16, green: 0.55, blue: 0.27, alpha: 1), light: NSColor.systemGreen)
    static let orangeCap = dynamic(dark: NSColor(red: 0.78, green: 0.45, blue: 0.08, alpha: 1), light: NSColor.systemOrange)
    /// Pastel surfaces for a chosen option: delivered (mint) and still sendable (apricot).
    static let greenRow = dynamic(dark: NSColor(red: 0.13, green: 0.25, blue: 0.16, alpha: 1), light: NSColor(red: 0.87, green: 0.96, blue: 0.89, alpha: 1))
    static let orangeRow = dynamic(dark: NSColor(red: 0.30, green: 0.22, blue: 0.12, alpha: 1), light: NSColor(red: 0.99, green: 0.93, blue: 0.85, alpha: 1))
}

/// 45s, 31m, 2h, 3d.
func shortAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

/// What an agent's dot says: orange it needs you, red it said it is blocked, green it said it is done, blue it is
/// working. Closed means Arsen shut it: no dot until it speaks again.
enum AgentStatus {
    case needsYou, blocked, done, working, closed

    static func of(_ asks: [Ask]) -> AgentStatus {
        if asks.contains(where: { $0.state == .waiting || $0.state == .pending }) { return .needsYou }
        guard let last = asks.last(where: { $0.kind != .message }) else { return .working }
        switch last.status {
        case "blocked": return .blocked
        case "done": return .done
        case "closed": return .closed
        default: return .working
        }
    }

    var color: Color {
        switch self {
        case .needsYou: return .orange
        case .blocked: return .red
        case .done: return .green
        case .working: return .blue
        case .closed: return .gray
        }
    }
}

/// An arc turning once a second; a plain dot under Reduce Motion.
struct Spinner: View {
    var color: Color = .blue
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion {
            Circle().fill(color)
        } else {
            Circle().trim(from: 0.15, to: 1).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
                .rotationEffect(.degrees(turning ? 360 : 0))
                // Scoped to `turning`: a withAnimation(.repeatForever) in onAppear would leak into every layout change.
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
                .onAppear { turning = true }
        }
    }
}

/// One agent, read top to bottom like a chat: a short list of what came before, its latest note, then what to do now.
struct AgentTimeline: View {
    @Bindable var controller: InboxController
    var focus: FocusState<String?>.Binding

    var body: some View {
        let open = controller.cards.filter { !$0.state.isFinal }
        let history = controller.cards.filter { $0.state.isFinal }
        // Everything before the agent's latest note folds into "Earlier"; the note and your messages since stay as cards.
        let split: ([Ask], [Ask]) = {
            if let i = history.lastIndex(where: { $0.kind == .note }) { return (Array(history[..<i]), Array(history[i...])) }
            return (history.filter { $0.kind != .message }, history.filter { $0.kind == .message })
        }()
        let earlier = Array(split.0.suffix(8))
        let recent = split.1
        if !earlier.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Earlier").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(earlier) { ask in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(shortAge(ask.answeredAt ?? ask.createdAt, now: context.date))
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                        }
                        Text(summary(ask)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        ForEach(recent) { ask in CardView(ask: ask, controller: controller, focus: focus).id(ask.id) }
        ForEach(open) { ask in CardView(ask: ask, controller: controller, focus: focus).id(ask.id) }
        if let agent = controller.agentFilter, controller.store.canMessage(agent) {
            Composer(controller: controller, agent: agent, focus: focus)
        }
        if open.isEmpty && recent.isEmpty && earlier.isEmpty {
            Text("Nothing from this agent yet").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(18)
                .card()
        }
    }

    private func summary(_ ask: Ask) -> String {
        switch ask.kind {
        case .note: return ask.body
        case .message: return "You: " + ask.body
        case .run: return "\(ask.title) · " + (ask.state == .declined ? "rejected" : "ran, exit \(ask.exitCode ?? 0)")
        default: return "\(ask.title) · " + (ask.state == .declined ? "rejected" : (ask.answer ?? "answered"))
        }
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
                    Image(systemName: dictating ? "waveform" : "mic").foregroundStyle(dictating ? .red : .secondary)
                }.buttonStyle(.plain)
                Button(action: onSend) {
                    Image(systemName: "paperplane").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

/// The composer's box: flush with its card's sides and bottom, bottom corners on the card's radius, and a top
/// edge whose ends sweep up into the card's walls (concave fillets), so no sliver of card shows beside a corner.
struct ComposerBoxShape: Shape {
    var fillet: CGFloat = 12
    var cardRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        var path = topEdge(in: rect)
        let w = rect.maxX, h = rect.maxY, R = cardRadius
        path.addLine(to: CGPoint(x: w, y: h - R))
        path.addArc(center: CGPoint(x: w - R, y: h - R), radius: R, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: R, y: h))
        path.addArc(center: CGPoint(x: R, y: h - R), radius: R, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Wall to wall: down the left fillet, across, up the right fillet. Stroked on its own as the box's hairline.
    func topEdge(in rect: CGRect) -> Path {
        let w = rect.maxX, r = fillet
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addArc(center: CGPoint(x: r, y: 0), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: w - r, y: r))
        path.addArc(center: CGPoint(x: w - r, y: 0), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        return path
    }
}

struct ComposerTopEdge: Shape {
    func path(in rect: CGRect) -> Path { ComposerBoxShape().topEdge(in: rect) }
}

/// An icon the app bundles for an adapter's choice (claude, openai, solo), by resource name. Built once.
@MainActor private var iconCache: [String: Image] = [:]
@MainActor func choiceIcon(_ name: String?) -> Image? {
    guard let name else { return nil }
    if let cached = iconCache[name] { return cached }
    let built = buildChoiceIcon(name)
    if let built { iconCache[name] = built }
    return built
}

private func buildChoiceIcon(_ name: String) -> Image? {
    if name == "solo" {
        let icon = NSWorkspace.shared.icon(forFile: "/Applications/Solo.app").copy() as! NSImage
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

/// Start a new agent from the inbox. One composer box: the prompt on top, and beneath it a toolbar with where
/// and with what it runs (chips opening Zero's own pickers) and the mic and send on the right. When nothing is
/// open it is the whole inbox, headed "All quiet."
struct NewAgentCard: View {
    @Bindable var controller: InboxController
    var focus: FocusState<String?>.Binding
    let quiet: Bool
    @State private var projectAnchor = CGRect.zero
    @State private var runtimeAnchor = CGRect.zero

    private var runtime: SpawnChoice? { controller.spawnRuntimes.first { $0.id == controller.spawnRuntime } }
    private var model: SpawnChoice? { controller.spawnModels.first { $0.id == controller.spawnModel } }
    private var project: SpawnChoice? { controller.spawnTargets.first { $0.id == controller.spawnTarget } }
    /// The model's effort level, when it has levels: the one picked for it, else its default.
    private var effort: String? {
        guard let model, !model.levels.isEmpty else { return nil }
        return (controller.spawnSettings[model.id]?["reasoning"] ?? model.defaultLevel).map { effortLabel($0, short: true) }
    }

    var body: some View {
        let key = InboxController.newAgentKey
        // The box's flat top edge is 12 pt below where the box begins, so 2 pt here puts it 14 pt under the text,
        // the same as the card's padding above the headline.
        VStack(alignment: .leading, spacing: 2) {
            if quiet {
                VStack(alignment: .leading, spacing: 3) {
                    Text("All quiet.").font(.system(size: 15, weight: .semibold))
                    Text("Nothing needs you. Start something.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            // Flush with the card's sides and bottom; the card's own 14 pt inside, so the prompt's text starts
            // exactly under the headline. The top edge's fillets add their 12 pt above the content.
            VStack(alignment: .leading, spacing: 12) {
                TextField("What should a new agent work on?",
                          text: Binding(get: { controller.drafts[key, default: ""] }, set: { controller.drafts[key] = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...8)
                    .focused(focus, equals: key)
                    .onSubmit { controller.spawn() }
                HStack(spacing: 6) {
                    // Where: grouped by adapter, each project with its path.
                    chip(icon: choiceIcon(project?.icon) ?? Image(systemName: "folder"), title: project?.name ?? "Project",
                         open: controller.selector?.kind == .project) { controller.openSelector(.project, anchor: projectAnchor) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { projectAnchor = $0 }
                    // With what: runtime and model in one pick; the chip shows the runtime's icon and the model's name.
                    chip(icon: choiceIcon(runtime?.icon) ?? Image(systemName: "apple.terminal"),
                         title: model.map { $0.id.isEmpty ? (runtime?.name ?? "Default") : $0.name + (effort.map { " · " + $0 } ?? "") } ?? runtime?.name ?? "Runtime",
                         open: controller.selector?.kind == .runtime) { controller.openSelector(.runtime, anchor: runtimeAnchor) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { runtimeAnchor = $0 }
                    Spacer(minLength: 8)
                    if controller.spawning {
                        Spinner().frame(width: 12, height: 12).padding(.trailing, 4)
                    }
                    Button { controller.toggleDictation() } label: {
                        Image(systemName: controller.dictatingFor == key ? "waveform" : "mic")
                            .foregroundStyle(controller.dictatingFor == key ? .red : .secondary)
                    }.buttonStyle(.plain)
                    Button { controller.spawn() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                            .foregroundStyle(controller.drafts[key, default: ""].isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 10 + 12)
            .background(ComposerBoxShape().fill(Theme.row))
            .overlay(ComposerTopEdge().stroke(Theme.stroke, lineWidth: 1))
            .padding(.horizontal, -14).padding(.bottom, -14)
            if let error = controller.spawnError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 14)
            }
        }
        .padding(14)
        .card()
        .onAppear { controller.loadSpawnChoices() }
    }

    /// A small pill: icon, current value, chevron. Opens one of Zero's selectors; reads pressed while it is open.
    private func chip(icon: Image, title: String, open: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.keycap.opacity(open ? 1 : 0.8)).clipShape(Capsule())
            .overlay(Capsule().strokeBorder(open ? Theme.selectedStroke : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Your message to an agent, when nothing is waiting: typing lands here, Enter sends it through the adapter.
struct Composer: View {
    @Bindable var controller: InboxController
    let agent: String
    var focus: FocusState<String?>.Binding

    var body: some View {
        let key = controller.composerKey(agent)
        ReplyBox(placeholder: "Message \(agent)…",
                 text: Binding(get: { controller.drafts[key, default: ""] }, set: { controller.drafts[key] = $0 }),
                 key: key, focus: focus, dictating: controller.dictatingFor == key,
                 onMic: { controller.toggleDictation() }, onSend: { controller.send(key) })
            .padding(4)
            .card()
    }
}

struct CardView: View {
    let ask: Ask
    @Bindable var controller: InboxController
    var focus: FocusState<String?>.Binding

    private var selected: Bool { controller.selected == ask.id }
    private var dictating: Bool { controller.dictatingFor == ask.id }
    /// With several questions open, the waiting ones your keys won't answer step back; finished cards never dim.
    private var dimmed: Bool { ask.state == .waiting && !selected && controller.cards.filter { $0.state == .waiting }.count > 1 }

    @State private var commandExpanded = false
    /// False until the entrance has played; cards already seen start true.
    @State private var entered = false
    /// Heights of the command box and the options while waiting; the terminal takes exactly their space.
    private var commandHeight: CGFloat { controller.measured[ask.id]?.command ?? 36 }
    private var optionsHeight: CGFloat { controller.measured[ask.id]?.options ?? 126 }
    private static let collapsedLines = 8

    /// The header carries who and why: agent, the agent's own title as context, and the live state.
    private var context: String? {
        switch ask.kind {
        case .note, .message: return nil
        case .run: return ask.title == "Run a command" ? nil : ask.title
        default: return ask.body.isEmpty ? nil : ask.title
        }
    }

    /// The headline is the question itself; for a run ask it is always the same question.
    private var headline: String {
        switch ask.kind {
        case .run:
            switch ask.state {
            case .running: return "Running command…"
            case .answered: return (ask.exitCode ?? 0) == 0 ? "Ran command" : "Command failed (exit \(ask.exitCode ?? 0))"
            case .declined: return "Command rejected"
            default: return "Allow this command?"
            }
        case .note, .message: return ask.body
        default: return ask.body.isEmpty ? ask.title : ask.body
        }
    }

    private var commandIsLong: Bool {
        guard let command = ask.command else { return false }
        return command.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLines || command.count > 400
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Who and what on the left, when on the right.
            HStack(spacing: 8) {
                Text(ask.kind == .message ? "You" : ask.agent.name).font(.system(size: 12, weight: .medium))
                if let context {
                    Text(context).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if ask.state == .running {
                    Button("Stop") { controller.store.cancelRun(ask.id) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
                } else if ask.state.isFinal {
                    // Finished: the clock time it landed, not an age that keeps counting.
                    Text((ask.answeredAt ?? ask.createdAt).formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(statusLine(now: timeline.date)).font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if ask.state.isFinal && ask.kind != .note {
                    Button { controller.dismiss(ask.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }.buttonStyle(.plain).offset(x: 4)
                }
            }
            .frame(height: 20)
            Text(headline).font(.system(size: ask.kind == .note || ask.kind == .message ? 13 : 15,
                                        weight: ask.kind == .note || ask.kind == .message ? .regular : .semibold))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if ask.kind == .run && !ask.body.isEmpty {
                Text(ask.body).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if ask.kind == .run && (ask.state == .running || ask.state == .answered) {
                terminal
            } else if let command = ask.command {
                VStack(alignment: .leading, spacing: 6) {
                    Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(commandIsLong && !commandExpanded ? Self.collapsedLines : nil)
                        .fixedSize(horizontal: false, vertical: true)
                    if ask.cwd != nil || commandIsLong {
                        HStack {
                            if let cwd = ask.cwd {
                                Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if commandIsLong {
                                Button(commandExpanded ? "Show less" : "Show all") { commandExpanded.toggle() }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 10))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.measured[ask.id] = ($0, optionsHeight) }
            }
            // Options carry the state: the chosen row goes orange with a spinner while it can still be taken back,
            // then green with a tick once delivered. The rest dim. A typed answer shows as a row of its own.
            if ask.state != .expired && !(ask.kind == .run && (ask.state == .running || ask.state == .answered)) {
                let decided = ask.state != .waiting
                VStack(spacing: 12) {
                ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                    if !decided, controller.textOption[ask.id] == index {
                        ReplyBox(placeholder: option,
                                 text: Binding(get: { controller.drafts[ask.id, default: ""] }, set: { controller.drafts[ask.id] = $0 }),
                                 key: ask.id, focus: focus, dictating: dictating,
                                 onMic: { controller.select(ask.id); controller.toggleDictation() }, onSend: { controller.send(ask.id) })
                            .background(Theme.row).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        // Not `.disabled`: that greys the whole label, chosen row included. Decided rows just ignore clicks.
                        Button { controller.choose(index, on: ask.id) } label: {
                            optionRow(decided && ask.choice == index ? (ask.answer ?? option) : option,
                                      key: "\(index + 1)", chosen: decided && ask.choice == index, decided: decided)
                        }.buttonStyle(.plain).allowsHitTesting(!decided)
                    }
                }
                if decided, ask.options.isEmpty, let answer = ask.answer, ask.kind != .run {
                    optionRow(answer, key: nil, chosen: true, decided: true)
                }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { controller.measured[ask.id] = (commandHeight, $0) } }
            }
            footer
        }
        .opacity(dimmed ? 0.45 : 1)
        .padding(14)
        .background(ask.kind == .message ? Theme.row : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
        .padding(.leading, ask.kind == .message ? 36 : 0)
        .contentShape(Rectangle())
        .onHover { if $0, ask.state == .waiting { controller.select(ask.id) } }
        .onTapGesture { controller.select(ask.id) }
        // First showing: it joins at the bottom of the stack, so it rises 8 pt with a fade, 200 ms on the
        // (0.32, 0.72, 0, 1) ease-out, the same curve the stack grows with. Seen cards appear as they are.
        .offset(y: entered ? 0 : 8)
        .opacity(entered ? 1 : 0)
        .onAppear {
            if controller.seen.contains(ask.id) || reduceMotion {
                entered = true
            } else {
                controller.seen.insert(ask.id)
                withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.2)) { entered = true }
            }
        }
    }

    /// Same language as the pill: orange needs you, red blocked, green done, blue working.
    private var stateColor: Color {
        if ask.kind == .message { return (ask.status ?? "").hasPrefix("failed") ? .red : .gray }
        if ask.kind == .note { return AgentStatus.of([ask]).color }
        switch ask.state {
        case .waiting, .pending: return .orange
        case .declined: return .gray
        default: return .blue
        }
    }

    @ViewBuilder private var footer: some View {
        switch ask.state {
        case .waiting:
            // Only a free-text question has its own reply box; option cards answer through their options.
            if ask.options.isEmpty {
                ReplyBox(placeholder: "Reply to \(ask.agent.name)…",
                         text: Binding(get: { controller.drafts[ask.id, default: ""] }, set: { controller.drafts[ask.id] = $0 }),
                         key: ask.id, focus: focus, dictating: dictating,
                         onMic: { controller.select(ask.id); controller.toggleDictation() }, onSend: { controller.send(ask.id) })
                    .background(Theme.row).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        case .pending:
            EmptyView()
        case .running, .answered:
            EmptyView()
        case .declined:
            EmptyView() // the chosen row already shows the rejection, and any text that came with it
        case .expired:
            statusRow("Expired", color: .secondary)
        }
    }

    /// Once a run starts, the command box takes exactly the space it and the options had, fixed, like a small
    /// terminal: the command on the first line, the output scrolling beneath it and following the newest line.
    private var terminal: some View {
        TerminalView(command: ask.command ?? "", output: ask.output)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: commandHeight + 12 + optionsHeight)
            .background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func optionRow(_ text: String, key: String?, chosen: Bool, decided: Bool) -> some View {
        let settled = ask.state.isFinal
        let tint: Color = chosen ? (settled ? .green : .orange) : .clear
        let surface: Color = chosen ? (settled ? Theme.greenRow : Theme.orangeRow) : Theme.row
        let cap: Color = chosen ? (settled ? Theme.greenCap : Theme.orangeCap) : Theme.keycap
        return HStack(spacing: 10) {
            if let key {
                Text(key).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                    .foregroundStyle(chosen ? .white : .primary)
                    .background(cap).clipShape(RoundedRectangle(cornerRadius: 5))
            }
            // A text option reads like a placeholder: pick it and the input appears with the same wording.
            Text(text).font(.system(size: 13))
                .foregroundStyle(!chosen && Ask.expectsText(text) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer()
            if chosen {
                ZStack {
                    if settled {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                            .transition(.opacity)
                    } else {
                        Spinner(color: .orange).frame(width: 12, height: 12).transition(.opacity)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(decided && !chosen ? 0.4 : 1)
        // Colour only: surface, key cap and icon ease between states; the row itself never moves.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ask.state)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ask.choice)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same height as the reply box, so the footer swaps text without moving anything.
    private func statusRow(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .padding(.horizontal, 10)
    }

    private func statusLine(now: Date) -> String {
        if ask.kind == .message { return "\(ask.status ?? "sent") · \(shortAge(ask.createdAt, now: now))" }
        return shortAge(ask.createdAt, now: now)
    }
}

/// The small pin that marks whichever control the inbox is pinned on.
struct PinBadge: View {
    var body: some View { Text("📌").font(.system(size: 9)).frame(width: 12, height: 12) }
}

/// The bar's outline: rounded on the left, and merging into the screen edge on the right through two concave
/// fillets above and below, like a tab grown out of the edge.
struct PillShape: InsettableShape {
    var radius: CGFloat = 22
    var fillet: CGFloat = 10
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> PillShape {
        var shape = self
        shape.inset += amount
        return shape
    }

    /// Insets apply on the left, top and bottom only; the right side pushes out past the screen edge so the
    /// closing segment, and any stroke on it, stays off screen.
    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX + inset, y0 = rect.minY + inset, h = rect.maxY - inset, w = rect.maxX + inset
        let r = fillet, R = radius
        var path = Path()
        path.move(to: CGPoint(x: w, y: y0))
        path.addArc(center: CGPoint(x: w - r, y: y0), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: x0 + R, y: y0 + r))
        path.addArc(center: CGPoint(x: x0 + R, y: y0 + r + R), radius: R, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: x0, y: h - r - R))
        path.addArc(center: CGPoint(x: x0 + R, y: h - r - R), radius: R, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: w - r, y: h - r))
        path.addArc(center: CGPoint(x: w - r, y: h), radius: r, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The edge pill: the count of open asks (a plain tray when none), then one dot per agent heard from recently.
/// Dots grow by transform only, so their centre never moves: 1.0 resting, 1.18 while hovered or selected.
struct PillView: View {
    let controller: InboxController
    let settings: Settings
    let openInbox: () -> Void
    let selectAgent: (String) -> Void
    let moveHere: () -> Void
    /// Hovering a control peeks: nil for the open asks, a name for that agent's timeline.
    let peek: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A dot being dragged up or down the bar, and how far.
    @State private var drag: (name: String, y: CGFloat)?
    private let slot: CGFloat = 28

    init(controller: InboxController, settings: Settings, openInbox: @escaping () -> Void,
         selectAgent: @escaping (String) -> Void, moveHere: @escaping () -> Void,
         peek: @escaping (String?) -> Void = { _ in }, previewHovered: String? = nil) {
        self.controller = controller; self.settings = settings
        self.openInbox = openInbox; self.selectAgent = selectAgent; self.moveHere = moveHere; self.peek = peek
    }

    /// Every agent that has spoken and has not been closed, with its status. Expired asks don't count.
    private var agents: [(String, AgentStatus)] {
        let live = controller.store.asks.filter { $0.state != .expired }
        var seen: [String] = []
        for ask in live where !seen.contains(ask.agent.name) { seen.append(ask.agent.name) }
        return settings.sorted(seen)
            .map { name in (name, AgentStatus.of(live.filter { $0.agent.name == name })) }
            .filter { $0.1 != .closed }
    }

    private func scale(_ name: String) -> CGFloat { controller.agentFilter == name ? 13 / 11 : 1 }

    /// Where the dragged dot would land right now.
    private func dropIndex(in names: [String]) -> Int? {
        guard let drag, let from = names.firstIndex(of: drag.name) else { return nil }
        return max(0, min(names.count - 1, from + Int((drag.y / slot).rounded())))
    }

    /// While dragging, the dots between the start slot and the drop slot step aside by one slot.
    private func shift(of name: String, in names: [String]) -> CGFloat {
        guard let drag, drag.name != name, let from = names.firstIndex(of: drag.name),
              let to = dropIndex(in: names), let i = names.firstIndex(of: name) else { return 0 }
        if from < to, i > from, i <= to { return -slot }
        if from > to, i >= to, i < from { return slot }
        return 0
    }

    var body: some View {
        let waiting = controller.store.open.count
        let selected = controller.agentFilter
        VStack(spacing: 2) {
            Image(systemName: "tray").font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected == nil ? .primary : .secondary)
                .overlay(alignment: .topTrailing) {
                    if controller.pinned && selected == nil {
                        PinBadge().offset(x: 4, y: -6)
                    } else if waiting > 0 {
                        Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 3, y: -3)
                    }
                }
                .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .onHover { if $0 { peek(nil) } }
            .onTapGesture(perform: openInbox)
            .help("Open asks")
            if !agents.isEmpty {
                Rectangle().fill(Theme.hairline).frame(width: 18, height: 1).padding(.vertical, 4)
            }
            ForEach(agents, id: \.0) { name, status in
                Group {
                    if status == .working { Spinner() } else { Circle().fill(status.color) }
                }
                    .frame(width: 11, height: 11)
                    .overlay(alignment: .topTrailing) {
                        if controller.pinned && selected == name { PinBadge().offset(x: 4, y: -6) }
                    }
                    .scaleEffect(scale(name))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: scale(name))
                    .frame(width: 32, height: slot)
                    .contentShape(Rectangle())
                    .offset(y: drag?.name == name ? drag!.y : shift(of: name, in: agents.map(\.0)))
                    .animation(drag?.name == name || reduceMotion ? nil : .snappy(duration: 0.2), value: dropIndex(in: agents.map(\.0)))
                    .zIndex(drag?.name == name ? 1 : 0)
                    .onHover { if $0, drag == nil { peek(name) } }
                    .help(name)
                    .contextMenu { Button("Close \(name)") { controller.store.closeAgent(name) } }
                    // One gesture for click and drag, so they never compete: a press that moves under 4 pt selects;
                    // a longer one drags the dot with the pointer and drops it into the nearest slot.
                    // Global space: the dot moves with the drag, so a local translation would cancel itself out.
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if abs(value.translation.height) >= 4 || drag != nil { drag = (name, value.translation.height) }
                        }
                        .onEnded { value in
                            guard drag != nil else { selectAgent(name); return }
                            let names = agents.map(\.0)
                            if let from = names.firstIndex(of: name), let to = dropIndex(in: names) {
                                var order = names
                                order.remove(at: from)
                                order.insert(name, at: to)
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                                    settings.agentOrder = order
                                    drag = nil
                                }
                            } else {
                                drag = nil
                            }
                        })
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 8 + 10).padding(.horizontal, 6)
        .background(PillShape().fill(Theme.pill))
        .overlay(PillShape().strokeBorder(Theme.stroke, lineWidth: 1))
        // The bar's drawn height, which the inbox uses for its scroll limits.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.barHeight = $0 }
        // Outermost on purpose: placed inside, only the dots would animate and the shape would snap.
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: agents.map(\.0))
        .pointerStyle(.link)
        .contextMenu {
            Button("Open Log") { NSWorkspace.shared.open(Paths.log) }
            Divider()
            Button("Settings…") { (NSApp.delegate as? AppDelegate)?.openSettings() }
            Button("Quit Zero") { NSApp.terminate(nil) }
        }
    }
}
