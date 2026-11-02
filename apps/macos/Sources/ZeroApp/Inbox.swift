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
    var focusedReply: String? { didSet { if (focusedReply != nil) != (oldValue != nil) { onTyping?(focusedReply != nil) } } }
    /// Told when a text box in the inbox gains or loses focus, so Zero can be the active app while Arsen types.
    @ObservationIgnored var onTyping: ((Bool) -> Void)?
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
    /// The composer's height as last laid out: the empty inbox's card matches it, and conversations centre it.
    var composerHeight: CGFloat = 100

    /// Where each of the bar's controls sits, in its window (top-left origin), keyed by agent name or one of the
    /// two slots below. The app matches the pointer against these: a hover handler only answered over what a
    /// control draws, an 11 pt dot.
    @ObservationIgnored var barSlots: [String: CGRect] = [:]
    /// The agents the bar shows now, top to bottom: a slot of one gone from the bar is not under the pointer.
    @ObservationIgnored var barOrder: [String] = []
    static let inboxSlot = "\u{0}inbox", newSlot = "\u{0}new"
    /// The control the bar last opened from the pointer, so moving within it doesn't reopen it.
    @ObservationIgnored var barHover: String?

    /// The new-agent view: just the composer, opened from the bar's + button.
    var newAgentOpen = false
    /// Set while Arsen opens something in place (a card's text, an Earlier row): the view keeps its top where it
    /// is, so the opening only grows downward. Cleared when the view or its cards change.
    var holdTop = false

    func showNewAgent() {
        guard !newAgentOpen else { return }
        holdTop = false
        switching = true
        cut { agentFilter = nil; newAgentOpen = true }
        requestScroll(animated: false)
        DispatchQueue.main.async { self.switching = false }
    }

    /// A view switch is a cut: nothing fades or slides across it.
    private func cut(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    func show(agent: String?) {
        let wasNew = newAgentOpen
        cut { newAgentOpen = false }
        // Hovering the control for the view already shown changes nothing: what Arsen opened stays open and
        // where it is.
        guard agentFilter != agent || wasNew else { return }
        expandedEarlier = nil
        holdTop = false
        switching = true
        cut { agentFilter = agent }
        seen.formUnion(cards.map(\.id))
        ensureSelection()
        requestScroll(animated: false)
        DispatchQueue.main.async { self.switching = false }
    }
    /// The new-agent composer: choices loaded from the spawning adapter, last picks remembered.
    /// Every spawning adapter's projects, and which adapter each one belongs to; the runtimes follow the project's
    /// adapter (Solo's tools, or Claude and Codex in Rex), the pick kept by name across them.
    var spawnTargets: [SpawnChoice] = []
    var spawnRuntimes: [SpawnChoice] { spawnAdapter.flatMap { runtimesByAdapter[$0.name] } ?? [] }
    @ObservationIgnored var targetAdapter: [String: String] = [:]
    var runtimesByAdapter: [String: [SpawnChoice]] = [:]
    var spawnAdapter: AgentAdapter? {
        let owner = spawnTarget.flatMap { targetAdapter[$0] }
        return store.spawners.first { $0.name == owner } ?? store.spawners.first
    }
    var spawnTarget: String? = UserDefaults.standard.string(forKey: "lastSpawnTarget") {
        didSet {
            UserDefaults.standard.set(spawnTarget, forKey: "lastSpawnTarget")
            // Another adapter's project: the same runtime there, by name, else its first.
            if let current = spawnRuntime, !spawnRuntimes.contains(where: { $0.id == current }) {
                let name = oldRuntimeName(current)
                spawnRuntime = spawnRuntimes.first { $0.name == name }?.id ?? spawnRuntimes.first?.id
            }
        }
    }
    private func oldRuntimeName(_ id: String) -> String? { runtimesByAdapter.values.joined().first { $0.id == id }?.name }
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

    /// The model each running agent was switched to from Zero, by agent name; nothing recorded means whatever it started with.
    var agentModels: [String: String] = (UserDefaults.standard.dictionary(forKey: "agentModels") as? [String: String]) ?? [:]
    /// The "/" or "@" suggestions open under a composer: for which composer, at which word, and the pick.
    struct MentionState {
        let key: String
        let trigger: MentionTrigger
        var items: [Mention]
        var selected: Int
    }
    var mention: MentionState?
    /// Caret positions a composer should take after Zero changed its text (an accepted suggestion).
    var caretRequest: [String: Int] = [:]
    @ObservationIgnored private var mentionTask: Task<Void, Never>?

    static func isComposerKey(_ key: String) -> Bool { key == newAgentKey || key.hasPrefix("msg:") }

    /// The folder a composer's "@" looks in: the agent's project, or the project picked for a new agent.
    func projectPath(for key: String) -> String? {
        let raw: String?
        if key.hasPrefix("msg:") {
            raw = store.identity(of: String(key.dropFirst(4)))?.soloProjectID.flatMap { id in spawnTargets.first { $0.id == String(id) }?.detail }
        } else {
            raw = spawnTargets.first { $0.id == spawnTarget }?.detail
        }
        return raw.map { ($0 as NSString).expandingTildeInPath }
    }

    func updateMention(key: String, trigger: MentionTrigger?) {
        mentionTask?.cancel()
        guard let trigger, trigger.symbol == "/" ? suggestCommands : suggestFiles else { if mention?.key == key { mention = nil }; return }
        let path = projectPath(for: key)
        if trigger.symbol == "/" {
            let query = trigger.query.lowercased()
            let all = ClaudeCommands.all(projectPath: path)
            let name = { (m: Mention) in m.insert.dropFirst().lowercased() }
            let starts = all.filter { name($0).hasPrefix(query) }
            let contains = all.filter { !name($0).hasPrefix(query) && name($0).contains(query) }
            showMention(key: key, trigger: trigger, items: Array((starts + contains).prefix(8)))
        } else {
            guard let path else { mention = nil; return }
            mentionTask = Task { [weak self] in
                let files = await ProjectFiles.list(path)
                guard let self, !Task.isCancelled else { return }
                showMention(key: key, trigger: trigger,
                            items: ProjectFiles.match(trigger.query, in: files).map { Mention(kind: .file, insert: "@" + $0, detail: nil) })
            }
        }
    }

    private func showMention(key: String, trigger: MentionTrigger, items: [Mention]) {
        guard !items.isEmpty else { mention = nil; return }
        let sameWord = mention?.key == key && mention?.trigger.range.location == trigger.range.location
        mention = MentionState(key: key, trigger: trigger, items: items, selected: sameWord ? min(mention?.selected ?? 0, items.count - 1) : 0)
    }

    /// Arrows move, Tab or Return takes the highlighted suggestion, Esc closes the list.
    func mentionKey(_ key: ComposeKey, for composer: String) -> Bool {
        guard var state = mention, state.key == composer else { return false }
        switch key {
        case .up: state.selected = max(0, state.selected - 1); mention = state
        case .down: state.selected = min(state.items.count - 1, state.selected + 1); mention = state
        case .accept: acceptMention(state.selected)
        case .dismiss: mention = nil
        }
        return true
    }

    /// Replaces the whole word under the caret with the suggestion, adds a space unless one already follows,
    /// and puts the caret after that space.
    func acceptMention(_ index: Int) {
        guard let state = mention, state.items.indices.contains(index) else { return }
        let text = drafts[state.key, default: ""] as NSString
        let word = state.trigger.word
        guard NSMaxRange(word) <= text.length else { mention = nil; return }
        let spaced = NSMaxRange(word) < text.length && text.substring(with: NSRange(location: NSMaxRange(word), length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let insert = state.items[index].insert + (spaced ? "" : " ")
        drafts[state.key] = text.replacingCharacters(in: word, with: insert)
        caretRequest[state.key] = word.location + (insert as NSString).length + (spaced ? 1 : 0)
        mention = nil
    }

    /// Agents a message is on its way to, and why the last one did not arrive.
    var delivering: Set<String> = []
    var deliveryError: [String: String] = [:]
    /// The agent a runtime selector is open for; nil means the new-agent composer.
    var selectorAgent: String?

    @ObservationIgnored private var modelSwitches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var appliedModels: [String: (model: String, level: String?)] = [:]

    /// Remembers the pick and tells the agent once the picking has settled: dragging the effort slider picks on
    /// every step, so each pick restarts a short wait, switches run one after another, and only the model or
    /// level that actually changed is sent.
    func setAgentModel(_ agent: String, model: SpawnChoice) {
        agentModels[agent] = model.id
        UserDefaults.standard.set(agentModels, forKey: "agentModels")
        let previous = modelSwitches[agent]
        previous?.cancel()
        modelSwitches[agent] = Task { [weak self] in
            await previous?.value
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            let level = spawnSettings[model.id]?["reasoning"] ?? model.defaultLevel
            let last = appliedModels[agent]
            guard last?.model != model.id || last?.level != level else { return }
            do {
                try await store.switchModel(of: agent, to: last?.model == model.id ? nil : model, level: last?.level == level ? nil : level)
                appliedModels[agent] = (model.id, level)
            } catch {
                Log.write("model switch for \(agent) failed: \(error)")
            }
        }
    }

    /// The bar's dots: one per agent with live asks, workers folded into their lead (the board's team or the sessions'
    /// parent links), each in its team's most urgent state, in the user's order.
    func barAgents(settings: Settings, workspace: Workspace?) -> [(String, AgentStatus)] {
        let live = store.asks.filter { $0.state != .expired }
        let rows = workspace?.board ?? []
        // A worker: a session with a lead, by the sessions' own parent links (the board's rows don't always carry
        // their team).
        let workers = Set((workspace?.conversations ?? []).filter { $0.parent != nil }.map(\.id)
                          + rows.flatMap { row in (row.team ?? []).map(\.session).filter { $0 != row.session } })
        let session = { (ask: Ask) -> String? in ask.session }
        var seen: [String] = []
        for ask in live where !seen.contains(ask.agent.name) && !(session(ask).map(workers.contains) ?? false) { seen.append(ask.agent.name) }
        return settings.sorted(seen)
            .map { name -> (String, AgentStatus) in
                let own = live.filter { $0.agent.name == name }
                var status = AgentStatus.of(own)
                if let lead = own.first.flatMap(session), let row = rows.first(where: { $0.session == lead }) {
                    switch row.state {
                    case .needsYou: status = .needsYou
                    case .trouble: status = .trouble
                    case .blocked: status = .blocked
                    case .handed: status = .handed
                    case .working: status = .working
                    case .done: status = .done
                    case .merged: status = .merged
                    // On hold: off the bar, as a task that isn't running is.
                    case .paused: status = .offline
                    default: break
                    }
                }
                // A session that is not running is no dot of the bar's, whatever its last note said: the bar is what's active.
                return (name, status != .closed && store.offline.contains(name) ? .offline : status)
            }
            .filter { $0.1 != .closed && $0.1 != .offline }
    }

    /// The runtime an existing agent runs on, by its name ("claude-120" runs on the "Claude" tool).
    func runtime(of agent: String) -> SpawnChoice? {
        // Only its own adapter's runtimes: another's (Solo's) would name a session of Zero's after their tools.
        let own = adapter(of: agent).map { runtimesByAdapter[$0.name] ?? [] } ?? spawnRuntimes
        return own.first { $0.name.lowercased() == speaker(agent).lowercased() }
    }

    /// The adapter that reaches this agent: Solo, Rex, or whichever runs it.
    func adapter(of agent: String) -> AgentAdapter? {
        store.identity(of: agent).flatMap { identity in store.adapters.first { $0.canReach(identity) } }
    }

    /// True while the last thing in an agent's timeline is a message of Arsen's still awaiting its answer.
    func waitingOn(_ agent: String) -> Bool {
        let items = store.asks.filter { $0.agent.name == agent && $0.state != .expired }
        guard !items.contains(where: { !$0.state.isFinal }), let last = items.last, store.screens[agent] == nil else { return false }
        return last.kind == .message && ["sent", "sending", "starting", "resuming"].contains(last.status ?? "")
    }

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
        state.close = { [weak self] in self?.closeSelector() }
        state.level = { [weak self] id in self?.spawnSettings[id]?["reasoning"] }
        state.setLevel = { [weak self] id, level in self?.setSpawnSetting(modelID: id, key: "reasoning", value: level) }
        state.rebuild = { [weak self] in self?.selectorSections(for: kind) ?? [] }
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
            // One group per adapter: Solo's projects, then the folders Zero starts its own agents in.
            return store.spawners.compactMap { adapter in
                let targets = spawnTargets.filter { targetAdapter[$0.id] == adapter.name }
                guard !targets.isEmpty else { return nil }
                return SelectorSection(id: adapter.name, title: adapter is SoloAdapter ? "Solo projects" : "Zero projects",
                                       icon: choiceIcon(adapter is SoloAdapter ? "solo" : adapter.name == "Rex" ? "rex" : "zero"), rows: targets.map { choice in
                    SelectorRow(id: choice.id, title: choice.name, provider: choice.provider, providerIcon: choiceIcon(choice.icon),
                                detail: choice.detail, context: nil, levels: [], defaultLevel: nil, modelID: nil,
                                selected: choice.id == spawnTarget) { [weak self] in self?.spawnTarget = choice.id }
                })
            }
        case .menu: return []
        case .runtime:
            _ = modelsVersion
            // For a running agent: only its own runtime's models, the pick going to that agent.
            let agent = selectorAgent
            guard let adapter = agent.flatMap({ self.adapter(of: $0) }) ?? spawnAdapter else { return [] }
            let runtimes = agent.flatMap { runtime(of: $0) }.map { [$0] } ?? spawnRuntimes
            return runtimes.map { runtime in
                let models = adapter.spawnModels(for: runtime)
                let rows: [SelectorRow] = models.isEmpty
                    ? [SelectorRow(id: runtime.id, title: runtime.name, provider: runtime.provider, providerIcon: choiceIcon(runtime.icon),
                                   detail: runtime.detail, context: nil, levels: [], defaultLevel: nil, modelID: nil,
                                   selected: runtime.id == spawnRuntime) { [weak self] in if agent == nil { self?.spawnRuntime = runtime.id } }]
                    : models.map { model in
                        let selected = agent.map { agentModels[$0] == model.id } ?? (runtime.id == spawnRuntime && model.id == spawnModel)
                        return SelectorRow(id: runtime.id + "/" + model.id, title: model.name, provider: model.provider ?? runtime.provider,
                                    providerIcon: choiceIcon(model.icon ?? runtime.icon), detail: model.detail, context: model.context,
                                    levels: model.levels, defaultLevel: model.defaultLevel, modelID: model.id.isEmpty ? runtime.id + "/default" : model.id,
                                    selected: selected) { [weak self] in
                            if let agent { self?.setAgentModel(agent, model: model) } else { self?.spawnRuntime = runtime.id; self?.spawnModel = model.id }
                        }
                    }
                return SelectorSection(id: runtime.id, title: runtime.provider ?? runtime.name, icon: choiceIcon(runtime.icon), rows: rows)
            }
        }
    }
    /// Models for the chosen runtime, and the pick remembered per runtime.
    var spawnModels: [SpawnChoice] { _ = modelsVersion; return spawnAdapter.flatMap { adapter in spawnRuntimes.first { $0.id == spawnRuntime }.map { adapter.spawnModels(for: $0) } } ?? [] }
    var spawnNote: String? { spawnAdapter.flatMap { adapter in spawnRuntimes.first { $0.id == spawnRuntime }.flatMap { adapter.spawnNote(for: $0) } } }
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
    /// From Settings: whether "/" and "@" open suggestions (and "@" paths are highlighted).
    var suggestCommands = true
    var suggestFiles = false
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
        if let agentFilter {
            // Messages that never arrived (from before delivery confirmed first) are not part of the conversation.
            return store.asks.filter { $0.agent.name == agentFilter && $0.state != .expired && !(($0.status ?? "").hasPrefix("failed") && $0.kind == .message) }
        }
        return store.asks.filter {
            $0.kind != .note && $0.kind != .message && $0.state != .expired && $0.sameAs == nil
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
            // The words stay in the composer, read-only, until they have reached the agent; a failure leaves them
            // there to send again.
            let agent = String(key.dropFirst(4))
            drafts[key] = text
            guard !delivering.contains(agent) else { return }
            delivering.insert(agent)
            deliveryError[agent] = nil
            if text.hasPrefix("/") { NSApp.keyWindow?.makeFirstResponder(nil) } // the screen that opens takes the keys
            Task {
                do {
                    try await store.message(text, to: agent)
                    if drafts[key] == text { drafts[key] = nil }
                } catch {
                    deliveryError[agent] = "Couldn't reach \(speaker(agent)). Your message is still here."
                    Log.write("message to \(agent) failed: \(error)")
                }
                delivering.remove(agent)
            }
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
    var composable: Bool { newAgentOpen || (agentFilter.map { store.canMessage($0) } ?? false) }
    /// Only then does the inbox take the keyboard.
    var takesKeys: Bool { answerable || composable || screenOpen }
    /// A terminal screen is open for the agent in view: keys go to it.
    var screenOpen: Bool { agentFilter.map { store.screens[$0] != nil } ?? false }

    func composerKey(_ agent: String) -> String { "msg:" + agent }


    /// The Earlier row opened into its full card, if any.
    var expandedEarlier: String?

    /// Starts a message to `agent` with the first line of `ask` quoted, so "about this:" needs no retyping.
    func quote(_ ask: Ask, to agent: String) {
        let key = composerKey(agent)
        let text = ask.kind == .note || ask.kind == .message ? ask.body : ask.title
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let quoted = "> \(line)\n\n"
        drafts[key] = quoted + drafts[key, default: ""]
        caretRequest[key] = (quoted as NSString).length
        focusedReply = key
    }

    var canSpawn: Bool { !store.spawners.isEmpty }

    /// Bumped when a model list changes, so views that compute from the adapters re-read.
    var modelsVersion = 0

    /// `force`: read the projects again (Settings changed Zero's folders).
    func loadSpawnChoices(force: Bool = false) {
        guard let adapter = store.spawners.first else { return }
        Task {
            if spawnTargets.isEmpty || force {
                var targets: [SpawnChoice] = []
                var owners: [String: String] = [:]
                var runtimes: [String: [SpawnChoice]] = [:]
                for spawner in store.spawners {
                    let mine = (try? await spawner.spawnTargets()) ?? []
                    for target in mine { owners[target.id] = spawner.name }
                    targets += mine
                    runtimes[spawner.name] = (try? await spawner.spawnRuntimes()) ?? []
                }
                targetAdapter = owners
                runtimesByAdapter = runtimes
                spawnTargets = targets
                if spawnTarget == nil || !targets.contains(where: { $0.id == spawnTarget }) { spawnTarget = targets.first?.id }
                if spawnRuntime == nil || !spawnRuntimes.contains(where: { $0.id == spawnRuntime }) { spawnRuntime = spawnRuntimes.first?.id }
            }
            // Only when there is no list for this account yet: the refresh reads Claude Code's sign-in from the
            // Keychain, and macOS asks about that every time Claude Code rewrites the item. Settings has a button.
            if !ClaudeModels.hasCache, await adapter.refreshModels() {
                modelsVersion += 1
                if let selector { selector.sections = selectorSections(for: selector.kind) }
            }
        }
    }

    func spawn() {
        let prompt = drafts[Self.newAgentKey, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !spawning, let adapter = spawnAdapter,
              let target = spawnTargets.first(where: { $0.id == spawnTarget }),
              let runtime = spawnRuntimes.first(where: { $0.id == spawnRuntime }) else { return }
        let model = spawnModels.first { $0.id == spawnModel }
        let settings = model.flatMap { spawnSettings[$0.id] } ?? [:]
        if dictatingFor == Self.newAgentKey { stopDictation() }
        spawning = true
        spawnError = nil
        focusedReply = nil
        Task {
            do {
                let identity = try await store.spawn(prompt: prompt, adapter: adapter, target: target, runtime: runtime, model: model,
                                                     settings: settings, started: { [weak self] name in self?.show(agent: name) })
                // Up: clear the composer; the view follows the agent from its provisional name to the real one.
                drafts[Self.newAgentKey] = nil
                if agentFilter?.hasPrefix("starting-") == true { agentFilter = identity.name }
            } catch {
                spawnError = error.localizedDescription
                showNewAgent() // back to the composer, prompt still there, with the error under it
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
        if newAgentOpen, canSpawn { return Self.newAgentKey }
        return nil
    }

    /// Returns true when the key was consumed. Outside the reply field: 1–3 pick, arrows move, Enter focuses the
    /// reply, Delete dismisses a finished card, Space toggles the mic, and any other character starts the reply.
    func handle(_ event: NSEvent) -> Bool {
        ensureSelection()
        let editing = event.window?.firstResponder is NSTextView
        let key = event.charactersIgnoringModifiers ?? ""
        if event.keyCode == 53 { // escape
            if mention != nil { mention = nil; return true }
            if selector != nil { closeSelector(); return true }
            if let agent = agentFilter, store.screens[agent] != nil, !editing {
                // Cancels whatever the agent has open and closes the screen here.
                store.press([27], on: agent)
                store.closeScreen(of: agent)
                return true
            }
            if dictatingFor != nil { stopDictation(); return true }
            if let selected, textOption[selected] != nil { cancelTextOption(selected); event.window?.makeFirstResponder(nil); return true }
            if let last = lastAnswered, store.takeBack(last) { cancelAdvance(); selected = last; return true }
            if editing { focusedReply = nil; event.window?.makeFirstResponder(nil); return true }
            if agentFilter != nil { agentFilter = nil; return true }
            hide()
            return true
        }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if let agent = agentFilter, store.screens[agent] != nil {
            // The screen has the keyboard, whatever had focus: arrows, Enter and any character go to the agent's
            // terminal. (With the message box still focused after sending "/resume", nothing reached the picker.)
            let keys: [UInt16: [UInt8]] = [126: [27, 91, 65], 125: [27, 91, 66], 123: [27, 91, 68], 124: [27, 91, 67], 36: [13], 51: [127]]
            if let bytes = keys[event.keyCode] { store.press(bytes, on: agent); return true }
            if let scalar = key.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) {
                store.press(Array(key.utf8), on: agent)
                return true
            }
            return false
        }
        if editing { return false }
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
    /// Edge scrolling for the agent view; the ask list still centres by id through the reader.
    @State private var position = ScrollPosition()
    /// The stack's top within the bar's frame, kept while an opening grows it downward.
    @State private var heldTop: CGFloat = 0
    /// An agent's conversation stays at its end, its composer on the bar's centre line; the inbox and the
    /// new-agent composer simply centre on the bar. So the composer, or the empty inbox, is always in one place.
    private var pinsBottom: Bool { controller.agentFilter != nil }
    /// Each view starts from a fresh scroll position at its end: reusing the last view's carried its offset into
    /// the next, which showed it low for a moment before it settled.
    private var viewKey: String { controller.newAgentOpen ? "+new" : (controller.agentFilter ?? "inbox") }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        if controller.newAgentOpen {
                            ComposerCard(controller: controller, focus: $focus, mode: .newAgent)
                        } else if controller.agentFilter != nil {
                            AgentTimeline(controller: controller, focus: $focus)
                        } else {
                            ForEach(controller.cards) { ask in
                                CardView(ask: ask, controller: controller, focus: $focus)
                                    .id(ask.id)
                                    .transition(.asymmetric(insertion: .identity, removal: .opacity)) // the fade comes from the stack's animation, which a view switch turns off
                            }
                            if controller.cards.isEmpty { QuietCard(controller: controller) }
                        }
                    }
                    // One frosted surface under the stack, so the gaps between cards never show raw desktop. Its
                    // inset matches the 10 pt between cards, so the edges read as one more gap.
                    .padding(10)
                    // Thin, not ultra-thin: in light mode the thinnest material took whatever colour sat behind it.
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    // The composer, or the empty inbox, sits on the bar's centre line in every view, whatever is above
                    // it, so the eye never has to find it.
                    // A conversation ends with its composer centred on the bar, where the new-agent composer and the
                    // empty inbox sit; the 10 pt is the surface's inset around the composer.
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("stack")).minY } action: { top in
                        if !controller.holdTop { heldTop = top }
                    }
                    .padding(.bottom, pinsBottom ? max(0, controller.barHeight / 2 - controller.composerHeight / 2 - 10) : 0)
                    // Opening something in place: pinned at the top it had, so it grows downward only.
                    .padding(.top, controller.holdTop ? heldTop : 0)
                    .frame(minHeight: controller.barHeight, alignment: controller.holdTop ? .top : (pinsBottom ? .bottom : .center))
                    .coordinateSpace(name: "stack")
                    // Padding equal to the gap between panel edge and bar edge: scrolled to either end, the list
                    // stops level with the bar's top or bottom, and a list no taller than the bar cannot scroll.
                    .padding(.vertical, max(0, (geo.size.height - controller.barHeight) / 2))
                    // Outermost on purpose: the stack and its surface grow together when a card joins.
                    // A view switch is excluded: that is a cut.
                    .animation(reduceMotion || controller.switching ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.22),
                               value: controller.cards.map { "\($0.id)/\($0.state.rawValue)" })
                }
                // An agent's conversation sits at its end and stays there as it grows or the Earlier list sizes
                // itself. The ask list keeps centring its card.
                .scrollPosition($position)
                .defaultScrollAnchor(pinsBottom ? .bottom : nil)
                .defaultScrollAnchor(pinsBottom && !controller.holdTop ? .bottom : nil, for: .sizeChanges)
                // A panel resize (another screen, say) drops the offset to the top; the conversation goes back to its end.
                .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, _ in
                    if pinsBottom { position.scrollTo(edge: .bottom) }
                }
                .onChange(of: controller.barHeight) { _, _ in if pinsBottom { position.scrollTo(edge: .bottom) } }
                // Content that settles its height after the switch (a card measuring itself, text laying out) would
                // otherwise leave the conversation short of its end until something else redrew it: pinned again
                // whenever its height changes, so the composer stays on the bar's bottom line throughout.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                    if pinsBottom && !controller.holdTop { position.scrollTo(edge: .bottom) }
                }
                .onChange(of: controller.cards.map(\.id)) { _, _ in
                    // A new card pushes the stack: re-centre so the cards above drift up as it takes its place.
                    controller.holdTop = false
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
                .onChange(of: viewKey) { _, _ in
                    position = ScrollPosition(edge: pinsBottom ? .bottom : .top)
                    center(proxy)
                }
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
        // The composers are text views outside SwiftUI's focus system: its nil for them is not a blur.
        .onChange(of: focus) { _, id in
            if id != nil || !(controller.focusedReply.map(InboxController.isComposerKey) ?? false) { controller.focusedReply = id }
        }
    }

    /// The selected card goes to the bar's centre line, as far as the scroll limits allow; an agent's
    /// conversation goes to its end, the composer on the bar's bottom line.
    private func center(_ proxy: ScrollViewProxy) {
        if pinsBottom {
            // To the end, now and again once the conversation just switched in has been laid out. (Scrolling
            // to an id at the end through the reader never moved it; the edge request does.)
            position.scrollTo(edge: .bottom)
            DispatchQueue.main.async { position.scrollTo(edge: .bottom) }
            return
        }
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
    static let cardColor = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.11, alpha: 1) : .white }
    static let card = Color(nsColor: cardColor)
    /// A row under the pointer, a step under the sidebar's grey; the rail's active and hovered tiles.
    static let hover = dynamic(dark: NSColor(white: 0.20, alpha: 1), light: NSColor(white: 0.945, alpha: 1))
    /// A table row under the pointer: lighter than the body, so it never reads as the headings' grey.
    static let rowHover = dynamic(dark: NSColor(white: 0.21, alpha: 1), light: NSColor(white: 1, alpha: 1))
    static let railSelected = dynamic(dark: NSColor(white: 0.24, alpha: 1), light: NSColor(white: 0.84, alpha: 1))
    static let railHover = dynamic(dark: NSColor(white: 0.15, alpha: 1), light: NSColor(white: 0.885, alpha: 1))
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
    /// The sidebars' blueprint heading as drafting paper: dark ink on the panels' neutral-200 (neutral-800 with light
    /// ink in dark mode), so it reads as a surface of its own rather than a faded black.
    static let blueprint = dynamic(dark: hex(0x262626), light: hex(0xe5e5e5))
    static let onBlueprint = dynamic(dark: hex(0xfafafa), light: hex(0x0a0a0a))
    /// The workspace window's own grey, under its panel: the outer rail.
    static let rail = dynamic(dark: NSColor(white: 0.07, alpha: 1), light: NSColor(white: 0.925, alpha: 1))
    static let row = dynamic(dark: NSColor(white: 0.16, alpha: 1), light: NSColor(white: 0.94, alpha: 1))
    /// The rail's grey as a tint over the window's blur: the desktop shows through, softly.
    static let railTint = dynamic(dark: NSColor(white: 0.07, alpha: 0.55), light: NSColor(white: 0.925, alpha: 0.6))
    /// The composer's well: in light mode only a breath under the card, so it reads as a field, not a slab.
    static let composer = dynamic(dark: NSColor(white: 0.16, alpha: 1), light: NSColor(white: 0.975, alpha: 1))
    /// The composer's pills: one step under its light well rather than the key caps' heavier grey.
    static let chip = dynamic(dark: NSColor(white: 0.22, alpha: 1), light: NSColor(white: 0.93, alpha: 1))
    /// The workspace's composer, as Codex's: a white card on a hairline, its project tab a flat grey behind it, and a
    /// grey send button until there's something to send.
    static let field = dynamic(dark: NSColor(white: 0.17, alpha: 1), light: .white)
    static let fieldEdge = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.07))
    static let fieldTab = dynamic(dark: NSColor(white: 0.13, alpha: 1), light: NSColor(white: 0.955, alpha: 1))
    static let sendIdle = dynamic(dark: NSColor(white: 0.36, alpha: 1), light: NSColor(white: 0.56, alpha: 1))
    /// "Done" in a pill: the system green reads pale as small text on its own light fill; this one has weight.
    static let done = dynamic(dark: NSColor(red: 0.40, green: 0.82, blue: 0.50, alpha: 1), light: NSColor(red: 0.09, green: 0.50, blue: 0.22, alpha: 1))
    static let keycap = dynamic(dark: NSColor(white: 0.22, alpha: 1), light: NSColor(white: 0.88, alpha: 1))
    /// A fully solid knob; `.primary` is a translucent label colour.
    static let knob = dynamic(dark: .white, light: .black)
    /// Text on a solid `knob` surface (Arsen's message bubbles).
    static let onKnob = dynamic(dark: .black, light: .white)
    static let code = dynamic(dark: NSColor(white: 0, alpha: 0.35), light: NSColor(white: 0, alpha: 0.05))
    static let pill = dynamic(dark: NSColor(white: 0, alpha: 0.9), light: NSColor(white: 1, alpha: 0.96))
    // Opaque, so a border is one colour along its length whatever sits behind each segment.
    // Light strokes sit a step above the key-cap grey (L 0.92 against 0.91): an outline, not a frame.
    static let hairline = dynamic(dark: NSColor(white: 0.30, alpha: 1), light: NSColor(white: 0.88, alpha: 1))
    static let stroke = dynamic(dark: NSColor(white: 0.24, alpha: 1), light: NSColor(white: 0.89, alpha: 1))
    static let selectedStroke = dynamic(dark: NSColor(white: 0.45, alpha: 1), light: NSColor(white: 0.70, alpha: 1))
    /// Key cap fills for a chosen option: deeper in dark mode so the white digit keeps its contrast.
    static let greenCap = dynamic(dark: NSColor(red: 0.16, green: 0.55, blue: 0.27, alpha: 1), light: NSColor.systemGreen)
    static let orangeCap = dynamic(dark: NSColor(red: 0.78, green: 0.45, blue: 0.08, alpha: 1), light: NSColor.systemOrange)
    static let redCap = dynamic(dark: NSColor(red: 0.75, green: 0.22, blue: 0.20, alpha: 1), light: NSColor.systemRed)
    /// Pastel surfaces for a chosen option: delivered (mint), still sendable or on its way (apricot), and
    /// not delivered (rose).
    static let greenRow = dynamic(dark: NSColor(red: 0.13, green: 0.25, blue: 0.16, alpha: 1), light: NSColor(red: 0.87, green: 0.96, blue: 0.89, alpha: 1))
    static let orangeRow = dynamic(dark: NSColor(red: 0.30, green: 0.22, blue: 0.12, alpha: 1), light: NSColor(red: 0.99, green: 0.93, blue: 0.85, alpha: 1))
    static let redRow = dynamic(dark: NSColor(red: 0.32, green: 0.14, blue: 0.14, alpha: 1), light: NSColor(red: 0.99, green: 0.89, blue: 0.89, alpha: 1))
}

/// 45s, 31m, 2h, 3d.
func shortAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

/// What an agent's dot says, in the board's colours: blue it needs you, orange it's in trouble, teal it's over to you,
/// red it's blocked, green it said it is done, blue it is working. Closed means the user shut it: no dot until it
/// speaks again.
enum AgentStatus {
    case needsYou, trouble, handed, blocked, done, merged, working, closed, offline

    static func of(_ asks: [Ask]) -> AgentStatus {
        if asks.contains(where: { $0.state == .waiting || $0.state == .pending }) { return .needsYou }
        guard let last = asks.last(where: { $0.kind != .message }) else { return .working }
        switch last.status {
        case "blocked": return .blocked
        case "done": return .done
        case "merged": return .merged
        case "closed": return .closed
        default: return .working
        }
    }

    var color: Color {
        switch self {
        case .needsYou: return .blue
        case .trouble: return .orange
        case .handed: return .teal
        case .blocked: return .red
        case .done: return .green
        case .merged: return .purple
        case .working: return .blue
        case .closed, .offline: return .gray
        }
    }
}

/// An arc turning once a second; a plain dot under Reduce Motion.
/// A spinner driven by Core Animation: the arc turns on the render server, so a busy main thread (a Solo call
/// during a spawn, a layout pass in the bar) cannot stall it, and a view rebuild does not restart it. A SwiftUI
/// rotationEffect did both.
struct Spinner: View {
    var color: Color = .blue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion {
            Circle().fill(color)
        } else {
            SpinnerLayer(color: NSColor(color))
        }
    }
}

private struct SpinnerLayer: NSViewRepresentable {
    let color: NSColor
    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }
    func updateNSView(_ view: SpinnerView, context: Context) { view.color = color }
}

final class SpinnerView: NSView {
    var color: NSColor = .systemBlue { didSet { recolor() } }
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeStart = 0.15
        layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pointer events pass through, so the gestures on the dot or row underneath keep working.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        recolor()
        spin()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); spin() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); recolor() }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance { arc.strokeColor = color.cgColor }
    }

    /// One turn a second, clockwise, forever; re-added whenever the view comes back on screen, since Core
    /// Animation drops animations from layers that leave the hierarchy.
    private func spin() {
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: "spin")
    }
}

/// One agent, read top to bottom like a chat: a short list of what came before, its latest note, then what to do now.
struct AgentTimeline: View {
    @Bindable var controller: InboxController
    var focus: FocusState<String?>.Binding
    private static let earlierRow: CGFloat = 16, earlierGap: CGFloat = 8
    private static func earlierHeight(_ rows: Int) -> CGFloat {
        min(CGFloat(rows) * earlierRow + CGFloat(max(rows - 1, 0)) * earlierGap, 6 * earlierRow + 5 * earlierGap) // six rows at most
    }

    var body: some View {
        let open = controller.cards.filter { !$0.state.isFinal }
        let history = controller.cards.filter { $0.state.isFinal }
        // The latest exchange stays in view: your last message on the right and what the agent said since on the
        // left, with a placeholder holding the reply's place while it works. Everything before folds into
        // "Earlier", so sending again moves the previous exchange up into the list and opens a new one below.
        let start = history.lastIndex(where: { $0.kind == .message })
            ?? history.lastIndex(where: { $0.kind == .note }) ?? history.endIndex
        let recent = Array(history[start...])
        let earlier = Array(history[..<start].suffix(40))
        let waiting = controller.agentFilter.map { controller.waitingOn($0) } ?? false

        if !earlier.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Earlier").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                // Six rows at most, the newest in view, scrolling contained like a run's output, with the edges
                // fading where more is past them.
                ContainedList(height: Self.earlierHeight(earlier.count)) {
                    VStack(alignment: .leading, spacing: Self.earlierGap) {
                        ForEach(earlier) { ask in EarlierRow(ask: ask, controller: controller) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(controller.agentFilter) // each agent's list starts fresh, fades included
                // A row opened from the list shows in full beneath it, inside the same card: it is history,
                // not a new turn in the conversation.
                if let id = controller.expandedEarlier, let ask = earlier.first(where: { $0.id == id }) {
                    Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 4)
                    EarlierDetail(ask: ask).transition(.opacity)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        ForEach(recent) { ask in
            CardView(ask: ask, controller: controller, focus: focus).id(ask.id)
                // Yours rises out of the composer; a reply takes the placeholder's place.
                .transition(ask.kind == .message ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
        }
        if waiting, let agent = controller.agentFilter {
            HStack(spacing: 8) {
                Spinner().frame(width: 10, height: 10)
                Text("\(speaker(agent)) is working…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("waiting")
            .transition(.opacity)
        }
        ForEach(open) { ask in CardView(ask: ask, controller: controller, focus: focus).id(ask.id) }
        if let agent = controller.agentFilter, let screen = controller.store.screens[agent] {
            ScreenCard(agent: agent, screen: screen, controller: controller)
        }
        if let agent = controller.agentFilter, controller.store.canMessage(agent) {
            ComposerCard(controller: controller, focus: focus, mode: .agent(agent))
        }
        if open.isEmpty && recent.isEmpty && earlier.isEmpty {
            Text("Nothing from this agent yet").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(18)
                .card()
        }
    }

}

/// An Earlier row in full: the whole message, or the question with what was answered and, for a run, its output.
private struct EarlierDetail: View {
    let ask: Ask
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ask.kind == .note || ask.kind == .message {
                MarkdownText(ask.body, cwd: ask.agent.cwd ?? ask.cwd)
            } else {
                Text(ask.title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !ask.body.isEmpty, ask.body != ask.title {
                    Text(ask.body).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let detail = ask.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let command = ask.command, !command.isEmpty {
                    Text(ask.kind == .run && !ask.output.isEmpty ? "$ \(command)\n\(ask.output.suffix(2000))" : command)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(14)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if ask.kind != .run, let answer = ask.answer {
                    NucleoLabel(answer, icon: ask.state == .declined ? "circle-xmark" : "circle-check", fill: "glyph", size: 13)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(ask.state == .declined ? .red : .green)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line of an agent's history: when, what kind, who said what. A click opens it into its full card under the
/// list; on hover, a reply button starts a message quoting it.
private struct EarlierRow: View {
    let ask: Ask
    @Bindable var controller: InboxController
    @State private var hovered = false

    private var open: Bool { controller.expandedEarlier == ask.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(shortAge(ask.answeredAt ?? ask.createdAt, now: context.date))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
            }
            NucleoIcon(symbol, size: 12).foregroundStyle(.tertiary).frame(width: 14)
            Text(summary).font(.system(size: 12)).foregroundStyle(open ? .primary : .secondary).lineLimit(1)
            Spacer(minLength: 4)
            if let agent = controller.agentFilter, controller.store.canMessage(agent) {
                Button { controller.quote(ask, to: agent) } label: {
                    NucleoIcon("share-left", size: 12).foregroundStyle(.secondary)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).tip("Reply to this").opacity(hovered ? 1 : 0)
            }
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            controller.holdTop = true
            withAnimation(.easeOut(duration: 0.2)) { controller.expandedEarlier = open ? nil : ask.id }
        }
    }

    private var symbol: String {
        switch ask.kind {
        case .note where ask.status == "closed": "circle-xmark"
        case .note: "chat-bubble"
        case .message: "circle-arrow-up"
        case .run: "terminal"
        case .permission: "lock"
        case .approve: "badge-check"
        case .question, .choice: "circle-question"
        }
    }

    /// A transcript line: who said it, then the first line of what they said.
    private var summary: String {
        switch ask.kind {
        case .note where ask.status == "closed": return "Closed"
        case .note: return speaker(ask.agent.name) + ": " + (ask.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ask.body)
        case .message: return "You: " + ask.body
        case .run: return "\(ask.title) · " + (ask.state == .declined ? "rejected" : "ran, exit \(ask.exitCode ?? 0)")
        default: return "\(ask.title) · " + (ask.state == .declined ? "rejected" : (ask.answer ?? "answered"))
        }
    }
}

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
    }
}

/// The composer's box: flush with its card's sides and bottom, bottom corners on the card's radius, and a top
/// edge whose ends sweep up into the card's walls (concave fillets), so no sliver of card shows beside a corner.

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
    // Apps' own icons: Solo's, Rex's, and Zero's for its own terminals.
    let apps: [String: String?] = ["solo": "/Applications/Solo.app", "rex": NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superlogical.rex")?.path,
                "zero": Bundle.main.bundlePath]
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mentionHeight = $0 }
                    .offset(y: -mentionHeight - 6)
            }
        }
        .onAppear { controller.loadSpawnChoices() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            ComposeField(text: Binding(get: { controller.drafts[key, default: ""] }, set: { controller.drafts[key] = $0 }),
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
                         height: $fieldHeight)
                .frame(height: fieldHeight)
                .padding(.horizontal, -TokenTextView.inset.width) // text still starts under the card's 14 pt
            HStack(spacing: 6) {
                if agentName == nil {
                    // Where: grouped by adapter, each project with its path.
                    chip(icon: choiceIcon(project?.icon) ?? Image(nsImage: Nucleo.image("folder", size: 14) ?? NSImage()), title: project?.name ?? "Project",
                         open: controller.selector?.kind == .project) { controller.selectorAgent = nil; controller.openSelector(.project, anchor: projectAnchor) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { projectAnchor = $0 }
                }
                // With what: the runtime's icon and the model's name (an agent's own runtime name until a model is picked for it).
                chip(icon: choiceIcon(runtime?.icon) ?? Image(nsImage: Nucleo.image("terminal", size: 14) ?? NSImage()),
                     title: model.map { $0.id.isEmpty ? (runtime?.name ?? "Default") : $0.name + (effort.map { " · " + $0 } ?? "") + (account.map { " · " + $0 } ?? "") }
                        ?? agentName.map(speaker) ?? runtime?.name ?? "Runtime",
                     open: controller.selector?.kind == .runtime) { controller.selectorAgent = agentName; controller.openSelector(.runtime, anchor: runtimeAnchor) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { runtimeAnchor = $0 }
                Spacer(minLength: 8)
                if starting { Spinner().frame(width: 12, height: 12).padding(.trailing, 4) }
                Button { controller.toggleDictation() } label: {
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

struct CardView: View {
    let ask: Ask
    @Bindable var controller: InboxController
    var focus: FocusState<String?>.Binding

    /// Flat: no card of its own (the inbox page, a task's status). It's the one thing being looked at, so it shows in
    /// full: its words and command unfolded, never dimmed.
    var flat = false
    /// Who asked, under the question: left out where that's already plain (a task's own status).
    var showsByline = true

    init(ask: Ask, controller: InboxController, focus: FocusState<String?>.Binding, flat: Bool = false, showsByline: Bool = true) {
        self.ask = ask
        self.controller = controller
        self.focus = focus
        self.flat = flat
        self.showsByline = showsByline
        // A card already seen is shown as it is from its first frame, even in a view built afresh.
        _entered = State(initialValue: controller.seen.contains(ask.id))
    }

    private var selected: Bool { controller.selected == ask.id }
    /// A command it can't run here, for you to run yourself and say how it went: a two-step card.
    private var manual: Bool { ask.kind != .run && ask.command != nil && ask.state == .waiting }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                .background(Theme.keycap, in: Circle())
            Text(title).font(.system(size: 12.5, weight: .semibold))
        }
    }
    private var dictating: Bool { controller.dictatingFor == ask.id }
    /// With several questions open, the waiting ones your keys won't answer step back; finished cards never dim.
    /// Flat (on the inbox page, in a task's status), it's the one being looked at: never dimmed.
    private var dimmed: Bool { !flat && ask.state == .waiting && !selected && controller.cards.filter { $0.state == .waiting }.count > 1 }

    @State private var commandExpanded = false
    @State private var scriptExpanded = false
    @State private var detailExpanded = false
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
        // An approval's title is the request itself, the headline; its body is the detail beneath.
        case .permission, .approve: return nil
        default: return ask.body.isEmpty ? nil : ask.title
        }
    }

    /// Where the command runs, when that isn't simply the agent's own folder.
    private var folder: String? { ask.cwd == ask.agent.cwd ? nil : ask.cwd }

    /// The text under the question: why a run or permission is wanted, an approval's detail, a question's --body.
    private var supporting: String? {
        switch ask.kind {
        case .run, .permission, .approve: ask.body
        case .question, .choice: ask.detail
        default: nil
        }
    }

    /// Under the question: the agent's name when cards from several agents share the inbox, and the context.
    private var byline: String? {
        let who = controller.agentFilter == nil ? controller.store.displayName(of: ask.agent.name) : nil
        // Other agents asking for this same run wait on this card.
        let twins = controller.store.asks.filter { $0.sameAs == ask.id && !$0.state.isFinal }.count
        let also = twins > 0 ? "and \(twins) other agent\(twins == 1 ? "" : "s")" : nil
        let parts = [[who, also].compactMap { $0 }.joined(separator: " "), context].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        case .permission: return ask.title + "?"
        case .approve: return ask.title.hasSuffix("?") ? ask.title : ask.title + "?"
        case .note, .message: return ask.body
        default: return ask.body.isEmpty ? ask.title : ask.body
        }
    }

    private var commandIsLong: Bool {
        guard let command = ask.command else { return false }
        return command.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLines || command.count > 400
    }

    var body: some View {
        if ask.kind == .message { messageBubble } else { card }
    }

    /// Arsen's message to the agent: a bubble on the right with a small time beside it, no header and no
    /// dismiss; delivery trouble shows underneath.
    private var messageBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Yours are solid: black in light mode, white in dark, the text in the opposite.
            HuggingWidth(max: 260) {
                Text(ask.body).font(.system(size: 13)).foregroundStyle(Theme.onKnob).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(Theme.knob)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            if ask.status == "starting" {
                Text("Starting…").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.trailing, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ask.kind != .note {
                // The question leads; beneath it, who (in the inbox, where cards from
                // several agents sit together) and the agent's own title for it.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline).font(.system(size: 15, weight: .semibold))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if showsByline, let byline {
                            Text(byline).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    // No time and no dismiss: a finished card folds into Earlier, or leaves the inbox when it next opens.
                    if ask.state == .running {
                        Button("Stop") { controller.store.cancelRun(ask.id) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
                    }
                }
            }
            if ask.kind == .note {
                // An agent's words and nothing else; the time is in Earlier once the card folds away.
                MarkdownText(ask.body, cwd: ask.agent.cwd ?? ask.cwd)
                if ask.status == "blocked" { Text("Blocked").font(.system(size: 11, weight: .medium)).foregroundStyle(.red) }
            }
            // Why the agent wants it, or what it found, in its own words: six lines, the rest a click away.
            if let supporting, !supporting.isEmpty {
                // Three lines; a longer one fades out on its last line instead of being cut mid-word, and a
                // click on the text opens it in place. No button and no extra row.
                let long = supporting.count > 180 && !flat
                let folded = long && !detailExpanded
                Group {
                    // Folded, a click opens it; selecting text would take that click. Open, it is selectable.
                    if folded {
                        Text(supporting).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
                    } else {
                        Text(supporting).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, folded ? .clear : .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 16)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard long else { return }
                        controller.holdTop = true
                        withAnimation(.easeOut(duration: 0.2)) { detailExpanded.toggle() }
                    }
                    .pointerStyle(long ? .link : nil)
                    .tip(long ? (detailExpanded ? "Click to fold" : "Click to read it all") : "")
            }
            if ask.kind == .run && (ask.state == .running || ask.state == .answered) {
                terminal
            } else if let command = ask.command {
                // A command for you to run yourself (it can't be run from here: another machine's shell, sudo): a step.
                if manual { step(1, "Run this") }
                VStack(alignment: .leading, spacing: 6) {
                    Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(commandIsLong && !commandExpanded && !flat ? Self.collapsedLines : nil)
                        .fixedSize(horizontal: false, vertical: true)
                    // The script the command runs, so what Arsen approves is what he can read.
                    if let script = ask.script {
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                        Text(script.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                            .lineLimit(scriptExpanded ? nil : 12).fixedSize(horizontal: false, vertical: true)
                        if script.split(separator: "\n").count > 12 {
                            Button(scriptExpanded ? "Show less" : "Show the whole script") { controller.holdTop = true; scriptExpanded.toggle() }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    if folder != nil || commandIsLong {
                        HStack {
                            if let folder {
                                Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if commandIsLong && !flat {
                                Button(commandExpanded ? "Show less" : "Show all") { controller.holdTop = true; commandExpanded.toggle() }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 10))
                // Copied in one click, the script with it: what you run is what you read.
                .overlay(alignment: .topTrailing) { CopyCommand(text: [command, ask.script].compactMap { $0 }.joined(separator: "\n")).padding(6) }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.measured[ask.id] = ($0, optionsHeight) }
                if manual {
                    HStack {
                        step(2, "Then tell \(controller.store.displayName(of: ask.agent.name))")
                        Spacer()
                        // What it printed, from the clipboard into the reply, ready to send.
                        if let typed = ask.options.firstIndex(where: Ask.expectsText) {
                            Button {
                                controller.drafts[ask.id] = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                                controller.choose(typed, on: ask.id)
                            } label: {
                                NucleoLabel("Paste output", icon: "copy", size: 12).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(Hovering(radius: 6)).tip("Put what you copied into the reply, to send")
                        }
                    }
                }
            }
            // Options carry the state: the chosen row goes orange with a spinner while it can still be taken back,
            // then green with a tick once delivered. The rest dim. A typed answer shows as a row of its own.
            // Not for a reply: an empty options stack still cost the column's 12 pt below the text.
            if ask.kind != .note && ask.state != .expired && !(ask.kind == .run && (ask.state == .running || ask.state == .answered)) {
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
                        // A decided row takes a click only to retry an answer that didn't reach the agent.
                        let retry = decided && ask.choice == index && ask.delivery == .failed
                        Button { if retry { controller.store.deliverAnswer(ask.id) } else if !decided { controller.choose(index, on: ask.id) } } label: {
                            optionRow(decided && ask.choice == index ? (ask.answer ?? option) : option,
                                      key: "\(index + 1)", chosen: decided && ask.choice == index, decided: decided)
                        }.buttonStyle(.plain).allowsHitTesting(!decided || retry)
                    }
                }
                if decided, ask.options.isEmpty, let answer = ask.answer, ask.kind != .run {
                    Button { controller.store.deliverAnswer(ask.id) } label: { optionRow(answer, key: nil, chosen: true, decided: true) }
                        .buttonStyle(.plain).allowsHitTesting(ask.delivery == .failed)
                }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { controller.measured[ask.id] = (commandHeight, $0) } }
            }
            footer
        }
        // A reply hugs its text like a chat bubble, up to about 65% of the column, and sits left.
        .modifier(BubbleWidth(hug: ask.kind == .note, max: 220))
        .opacity(dimmed ? 0.55 : 1) // 0.45 left light-mode text with too small an L gap to read
        .padding(.horizontal, flat ? 16 : 14).padding(.vertical, ask.kind == .note ? 12 : 14)
        .background(flat ? Color.clear : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: flat ? 0 : 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(flat ? Color.clear : Theme.stroke, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
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
                ReplyBox(placeholder: "Reply to \(controller.store.displayName(of: ask.agent.name))…",
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
        // An answer Zero types into an agent that isn't waiting stays orange until it lands, and goes red if it can't.
        let failed = ask.delivery == .failed
        let settled = ask.state.isFinal && ask.delivery != .sending && !failed
        let surface: Color = chosen ? (failed ? Theme.redRow : settled ? Theme.greenRow : Theme.orangeRow) : Theme.row
        let cap: Color = chosen ? (failed ? Theme.redCap : settled ? Theme.greenCap : Theme.orangeCap) : Theme.keycap
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
                    if failed {
                        NucleoIcon("xmark", size: 13).foregroundStyle(.red)
                            .transition(.opacity)
                    } else if settled {
                        NucleoIcon("check", size: 13).foregroundStyle(.green)
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
        .tip(chosen && failed ? "Couldn't reach the agent. Click to try again." : "")
        .opacity(decided && !chosen ? 0.4 : 1)
        // Colour only: surface, key cap and icon ease between states; the row itself never moves.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ask.state)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ask.choice)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ask.delivery)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same height as the reply box, so the footer swaps text without moving anything.
    private func statusRow(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .padding(.horizontal, 10)
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
    /// The board, to fold workers into their leads: one dot per lead, in its team's most urgent state, as the sidebar
    /// lists them.
    var workspace: Workspace? = nil
    let openInbox: () -> Void
    let selectAgent: (String) -> Void
    let moveHere: () -> Void
    /// Hovering a control peeks: nil for the open asks, a name for that agent's timeline.
    let peek: (String?) -> Void
    var openNewAgent: () -> Void = {}
    var peekNewAgent: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A dot being dragged up or down the bar, and how far.
    @State private var drag: (name: String, y: CGFloat)?

    private let slot: CGFloat = 28

    init(controller: InboxController, settings: Settings, workspace: Workspace? = nil, openInbox: @escaping () -> Void,
         selectAgent: @escaping (String) -> Void, moveHere: @escaping () -> Void,
         peek: @escaping (String?) -> Void = { _ in }, openNewAgent: @escaping () -> Void = {}, peekNewAgent: @escaping () -> Void = {},
         previewHovered: String? = nil) {
        self.controller = controller; self.settings = settings; self.workspace = workspace
        self.openInbox = openInbox; self.selectAgent = selectAgent; self.moveHere = moveHere; self.peek = peek
        self.openNewAgent = openNewAgent; self.peekNewAgent = peekNewAgent
    }

    /// Every agent that has spoken and has not been closed, with its status. Expired asks don't count. A worker's
    /// agent (its session under a lead, by the board) is no dot of its own: its lead's dot carries the team's most
    /// urgent state.
    private var agents: [(String, AgentStatus)] { controller.barAgents(settings: settings, workspace: workspace) }

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
            NucleoIcon("inbox", size: 15)
                .foregroundStyle(selected == nil && !controller.newAgentOpen ? .primary : .secondary)
                .overlay(alignment: .topTrailing) {
                    if controller.pinned && selected == nil && !controller.newAgentOpen {
                        PinBadge().offset(x: 4, y: -6)
                    } else if waiting > 0 {
                        Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 3, y: -3)
                    }
                }
                .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.barSlots[InboxController.inboxSlot] = $0 }
            .onTapGesture(perform: openInbox)
            .tip("Open asks")
            if controller.canSpawn {
                NucleoIcon("plus", size: 15)
                    .foregroundStyle(controller.newAgentOpen ? .primary : .secondary)
                    .overlay(alignment: .topTrailing) {
                        if controller.pinned && controller.newAgentOpen { PinBadge().offset(x: 4, y: -6) }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.barSlots[InboxController.newSlot] = $0 }
                    .onTapGesture(perform: openNewAgent)
                    .tip("Start a new agent")
            }
            if !agents.isEmpty {
                Rectangle().fill(Theme.hairline).frame(width: 18, height: 1).padding(.vertical, 4)
                    .onChange(of: agents.map(\.0), initial: true) { controller.barOrder = $1 }
                    .onDisappear { controller.barOrder = [] }
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
                    .offset(y: drag?.name == name ? drag!.y : shift(of: name, in: agents.map(\.0)))
                    .animation(drag?.name == name || reduceMotion ? nil : .snappy(duration: 0.2), value: dropIndex(in: agents.map(\.0)))
                    // The whole slot, not just the dot, answers the pointer: full bar width, and the gap halves
                    // above and below it, so the slots meet and there is no dead space between dots.
                    .frame(width: 32, height: slot)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.barSlots[name] = $0 }
                    // Gone from the bar, gone from its slots: a pointer where it was peeks nothing.
                    .onDisappear { controller.barSlots[name] = nil }
                    .zIndex(drag?.name == name ? 1 : 0)
                    .tip(controller.store.displayName(of: name))
                    .contextMenu {
                        if let identity = controller.store.identity(of: name), identity.runtime == "rex" {
                            Button("Open in Rex") { Task { await RexAdapter.reveal(identity) } }
                        }
                        if let identity = controller.store.identity(of: name), identity.runtime == "zero", let ref = identity.ref {
                            Button("Open in Terminal") { HostAdapter.reveal(ref) }
                        }
                        Button(controller.store.canStop(name) ? "Remove and stop \(name)" : "Remove \(name)") { controller.store.closeAgent(name) }
                    }
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

/// "claude-120" speaks as "Claude", "codex-12" as "Codex"; a name without a process number speaks as itself.
func speaker(_ agent: String) -> String {
    let parts = agent.split(separator: "-")
    guard parts.count > 1, let last = parts.last, last.allSatisfy(\.isNumber) else { return agent }
    let base = parts.dropLast().joined(separator: "-")
    return base.prefix(1).uppercased() + base.dropFirst()
}

/// Markdown the way agents write it: paragraphs with inline emphasis and `code`, and fenced blocks set in
/// monospace on their own surface. ponytail: fences and inline syntax only; headings and lists read as text.
struct MarkdownText: View {
    let text: String
    /// Where "#123" points: the GitHub repository of the agent's folder.
    var repo: String?
    /// Whose "name#123" is, when the folder holds repositories rather than being one.
    var owner: String?
    /// The body text's size; headings, code and markers scale with it. The inbox's cards are smaller than a task's page.
    var size: CGFloat
    /// Quieter, for a preview: headings at the text's size, code without pills, tighter spacing.
    var compact: Bool
    /// As wide as its text, not the width it's given: a message of yours, in a bubble that hugs it.
    var hugs: Bool
    /// A message of yours: "/skill" and "@loop" in it are the tokens the composer showed, drawn as the same pills.
    var yours: Bool
    /// A click not on a link (RichText's).
    var onClick: (() -> Void)?
    /// Still being revealed (StreamingText): each frame's text is styled without being kept, as it's gone by the next.
    var streaming = false

    init(_ text: String, cwd: String? = nil, size: CGFloat = 13, compact: Bool = false, hugs: Bool = false, yours: Bool = false, onClick: (() -> Void)? = nil) {
        self.text = text
        repo = cwd.flatMap(References.repo(of:))
        owner = GitHubLinks.owner ?? cwd.flatMap(References.owner(of:))
        self.size = size
        self.compact = compact
        self.hugs = hugs
        self.yours = yours
        self.onClick = onClick
    }

    /// Set once a long text has been rendered off the main thread, so the view picks it up.
    @State private var rendered = false
    /// Texts this long render off the main thread, their plain text shown meanwhile.
    private static let long = 4000

    var body: some View {
        let _ = rendered
        if let rich = styled {
            RichText(text: rich, hugs: hugs, onClick: onClick).onChange(of: text, initial: true) { styleLong() }
        } else {
            // Its words while it's styled: a long answer never holds up the page.
            Text(ZeroEnding.split(text).0).font(.system(size: size)).lineSpacing(round(size * 0.42)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: text, initial: true) { styleLong() }
        }
    }

    /// The text styled: kept from before, styled now when short, or, for a long one still arriving, the part styled
    /// so far, which stays while the rest is styled rather than falling back to plain words with each new piece.
    private var styled: NSAttributedString? {
        if streaming { return Self.renderGrowing(text, size: size, links: links) }
        if let kept = RichMarkdown.kept(text, size: size, compact: compact, repo: repo, yours: yours) { return kept }
        if text.count < Self.long { return Self.render(text, size: size, compact: compact, links: links) }
        if let last, text.hasPrefix(last.text) { return last.rich }
        return nil
    }

    func streaming(_ on: Bool) -> MarkdownText { var copy = self; copy.streaming = on; return copy }

    /// The last long text styled here.
    @State private var last: (text: String, rich: NSAttributedString)?
    @State private var styler = Styler()

    /// One styling at a time for a long text: as it streams in, each pass styles the latest text, and passes again if
    /// more came meanwhile, rather than starting one per piece (each the whole answer) and dropping each unfinished.
    final class Styler { var latest = ""; var busy = false }

    private func styleLong() {
        styler.latest = text
        guard !streaming, text.count >= Self.long, !styler.busy else { return }
        if let kept = RichMarkdown.kept(text, size: size, compact: compact, repo: repo, yours: yours) { last = (text, kept); return }
        styler.busy = true
        let (size, compact, links, styler) = (size, compact, links, styler)
        Task { @MainActor in
            while true {
                let target = styler.latest
                let made = await Task.detached(priority: .userInitiated) { Rendered(Self.render(target, size: size, compact: compact, links: links)) }.value
                last = (target, made.text)
                rendered.toggle()
                if styler.latest == target { break }
            }
            styler.busy = false
        }
    }

    /// What finding links needs, read on the main thread so rendering can happen anywhere.
    private var links: Links { Self.links(repo: repo, owner: owner, yours: yours) }

    static func links(repo: String?, owner: String?, yours: Bool) -> Links {
        Links(repo: repo, owner: owner, slack: SlackLinks.team, channels: SlackLinks.channels, teams: Linear.shared.teams, app: LinearLinks.inApp, loops: LoopNames.known, skills: yours)
    }

    /// Styles a conversation's messages ahead of their first drawing (the window opening on it), off the main thread,
    /// so the page paints at once instead of parsing as it scrolls into view.
    static func warm(_ conversation: Conversation) async {
        let repo = References.repo(of: conversation.cwd)
        let owner = GitHubLinks.owner ?? References.owner(of: conversation.cwd)
        let (theirs, yours) = (links(repo: repo, owner: owner, yours: false), links(repo: repo, owner: owner, yours: true))
        let texts: [(String, Bool)] = conversation.items.compactMap { item in
            switch item.kind {
            case let .agent(text, _): (text, false)
            case let .user(text, images): (ImageToken.linked(text, images: images), true)
            default: nil
            }
        }
        await Task.detached(priority: .userInitiated) {
            for (text, mine) in texts { _ = render(text, size: 14.5, compact: false, links: mine ? yours : theirs) }
        }.value
    }

    struct Links: Sendable {
        let repo: String?
        let owner: String?
        /// The Slack workspace's team id: "#channel" and Slack's own links open in Slack.
        let slack: String?
        /// Channel ids by name: those open in Slack directly.
        var channels: [String: String] = [:]
        let teams: [String: String]
        let app: Bool
        /// The loops' names: "@name" in a message is one of them, drawn as a pill that opens it.
        var loops: [String] = []
        /// Words of yours: "/name" is a skill or command, a pill as the composer drew it (an agent's "/path" is a path).
        var skills = false
    }

    private struct Rendered: @unchecked Sendable { let text: NSAttributedString; init(_ text: NSAttributedString) { self.text = text } }

    /// A text still arriving, styled but not kept: its finished blocks come from the block cache, its last styled anew.
    nonisolated static func renderGrowing(_ text: String, size: CGFloat, links: Links) -> NSAttributedString {
        RichMarkdown.render(MarkdownBlock.parse(ZeroEnding.split(text).0), size: size, inline: { inline($0, links: links) },
                            key: "\(links.repo ?? "")|\(links.owner ?? "")|\(links.skills)|false", growing: true)
    }

    /// Parsed, styled and kept. Zero's own ending ("[zero: done]") is for its hook, not for reading.
    nonisolated static func render(_ text: String, size: CGFloat, compact: Bool, links: Links) -> NSAttributedString {
        RichMarkdown.cached(text, size: size, compact: compact, repo: links.repo, yours: links.skills) {
            let made = RichMarkdown.render(MarkdownBlock.parse(ZeroEnding.split(text).0), size: size, inline: { inline($0, links: links) },
                                           key: "\(links.repo ?? "")|\(links.owner ?? "")|\(links.skills)|\(compact)")
            return compact ? RichMarkdown.compact(made, size: size) : made
        }
    }

    /// Linear issues and pull requests become links, except inside `code` and links the agent already wrote.
    nonisolated static func inline(_ prose: String, links: Links) -> AttributedString {
        var result = (try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(prose)
        for run in result.runs where run.link != nil {
            if let link = run.link, let app = SlackLinks.url(link, team: links.slack) { result[run.range].link = app }
        }
        for (range, url) in References.find(in: String(result.characters), repo: links.repo, linear: links.teams, linearApp: links.app, owner: links.owner, slack: links.slack, channels: links.channels) {
            guard let span = Range(range, in: result) else { continue }
            let plain = result[span].runs.allSatisfy { $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false) }
            if plain { result[span].link = url }
        }
        if !links.loops.isEmpty, let regex = try? NSRegularExpression(pattern: "(?<![\\w@])@([a-z0-9-]+)(?![\\w-])") {
            let string = String(result.characters)
            for match in regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) {
                let name = (string as NSString).substring(with: match.range(at: 1))
                guard links.loops.contains(name), let range = Range(match.range, in: string), let span = Range(range, in: result),
                      result[span].runs.allSatisfy({ $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false) }),
                      let url = URL(string: "zero://loop/" + name) else { continue }
                result[span].link = url
            }
        }
        if links.skills, let regex = try? NSRegularExpression(pattern: "(?<![^\\s])/[^\\s]+") {
            let string = String(result.characters)
            for match in regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) {
                guard let range = Range(match.range, in: string), let span = Range(range, in: result),
                      result[span].runs.allSatisfy({ $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false) }),
                      let url = URL(string: "zero://skill/" + (string as NSString).substring(with: match.range).dropFirst().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else { continue }
                result[span].link = url
            }
        }
        return result
    }
}

/// The agent's terminal, in Zero, for the pickers slash commands open: the rendered screen below its
/// separator, keys for the pointer (the keyboard already goes straight through), and a close.
struct ScreenCard: View {
    let agent: String
    let screen: String
    @Bindable var controller: InboxController

    private static let keys: [(String, [UInt8])] = [("↑", [27, 91, 65]), ("↓", [27, 91, 66]), ("←", [27, 91, 68]), ("→", [27, 91, 67]), ("⏎", [13]), ("Esc", [27])]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Screen").font(.system(size: 12, weight: .medium))
                Text(controller.store.displayName(of: agent)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                ForEach(Self.keys, id: \.0) { label, bytes in
                    Button { controller.store.press(bytes, on: agent) } label: {
                        Text(label).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .frame(minWidth: 22, minHeight: 20).padding(.horizontal, 4)
                            .background(Theme.keycap).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Button { controller.store.closeScreen(of: agent) } label: {
                    NucleoIcon("xmark", size: 13).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).offset(x: 4)
            }
            .frame(height: 20)
            Text(visible.isEmpty ? "Waiting for the agent's screen…" : visible)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .card()
    }

    /// What the agent has open: everything below its last separator line, else the last 20 lines, with the
    /// blank run at the end gone.
    private var visible: String {
        var lines = screen.components(separatedBy: "\n")
        if let separator = lines.lastIndex(where: { $0.hasPrefix("▔▔▔") || $0.hasPrefix("───") }) {
            lines = Array(lines[(separator + 1)...])
        } else {
            lines = Array(lines.suffix(20))
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : $0 }.joined(separator: "\n")
    }
}

/// Chat-bubble width: the content is offered up to `max` points and the view takes exactly what it uses, so a
/// short line gets a short bubble. (A `maxWidth` frame claims the whole cap whenever the column offers it.)
struct BubbleWidth: ViewModifier {
    let hug: Bool
    let max: CGFloat
    func body(content: Content) -> some View {
        if hug { HuggingWidth(max: max) { content } } else { content.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct HuggingWidth: Layout {
    let max: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? max, max)
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        return CGSize(width: min(size.width, width), height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The "/" and "@" suggestions: commands and skills with what they do, files by name with their folder.
struct MentionList: View {
    let state: InboxController.MentionState
    let pick: (Int) -> Void
    let hover: (Int) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                Button { pick(index) } label: {
                    HStack(spacing: 8) {
                        NucleoIcon(item.kind == .file ? "file" : item.kind == .loop ? "animation-repeat" : "command", size: 13).foregroundStyle(.secondary).frame(width: 14)
                        Text(title(item)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let detail = detail(item) {
                            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(item.kind == .file ? .head : .tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(index == state.selected ? Theme.row : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { hover(index) } }
            }
        }
        .padding(6)
        .card()
    }

    private func title(_ item: Mention) -> String {
        item.kind == .file ? "@" + (item.insert.dropFirst() as Substring).split(separator: "/").last.map(String.init)! : item.insert
    }

    private func detail(_ item: Mention) -> String? {
        guard item.kind == .file else { return item.detail }
        let dir = (String(item.insert.dropFirst()) as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }
}

/// Copies a command in one click; a tick and "Copied" for a moment say it did.
struct CopyCommand: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            NucleoLabel(copied ? "Copied" : "Copy", icon: copied ? "circle-check" : "copy", size: 12)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).tip("Copy the command")
    }
}
