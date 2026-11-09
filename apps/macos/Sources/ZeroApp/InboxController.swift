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
    /// What's written in the inbox's boxes (a question's reply, its "Something else…", an agent's composer), and which
    /// question has its text option open: kept as it's typed, so an update (Zero quitting and opening again) loses
    /// none of it, as the composers' drafts are kept (Drafts).
    var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "inboxDrafts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(drafts, forKey: "inboxDrafts") }
    }
    var focusedReply: String? { didSet { if (focusedReply != nil) != (oldValue != nil) { onTyping?(focusedReply != nil) } } }
    /// Told when a text box in the inbox gains or loses focus, so Zero can be the active app while the user types.
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
    static let inboxSlot = "\u{0}inbox", newSlot = "\u{0}new", workspacesSlot = "\u{0}workspaces"
    /// The control the bar last opened from the pointer, so moving within it doesn't reopen it.
    @ObservationIgnored var barHover: String?

    /// The new-agent view: just the composer, opened from the bar's + button.
    var newAgentOpen = false
    /// The workspaces' view: the user's workspaces, the one shown ticked; opened from the bar's workspace control, as
    /// its other controls open theirs (a selector of its own beside the bar worked otherwise, and lay over these).
    var workspacesOpen = false
    /// Whose workspaces: the app's.
    weak var workspace: Workspace?

    func showWorkspaces() {
        guard !workspacesOpen else { return }
        holdTop = false
        switching = true
        cut { agentFilter = nil; newAgentOpen = false; workspacesOpen = true }
        requestScroll(animated: false)
        DispatchQueue.main.async { self.switching = false }
    }
    /// Set while the user opens something in place (a card's text, an Earlier row): the view keeps its top where it
    /// is, so the opening only grows downward. Cleared when the view or its cards change.
    var holdTop = false

    func showNewAgent() {
        guard !newAgentOpen else { return }
        holdTop = false
        switching = true
        cut { agentFilter = nil; workspacesOpen = false; newAgentOpen = true }
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
        let wasNew = newAgentOpen || workspacesOpen
        cut { newAgentOpen = false; workspacesOpen = false }
        // Hovering the control for the view already shown changes nothing: what the user opened stays open and
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
    /// Per-model configuration the user picked in the preview card, such as a reasoning level.
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
        // Each agent's asks, gathered once (not every ask filtered again for every dot).
        var byAgent: [String: [Ask]] = [:]
        var seen: [String] = [], shown = Set<String>()
        for ask in live {
            let name = ask.agent.name
            byAgent[name, default: []].append(ask)
            if !shown.contains(name), !(session(ask).map(workers.contains) ?? false) { shown.insert(name); seen.append(name) }
        }
        return settings.sorted(seen)
            .map { name -> (String, AgentStatus) in
                let own = byAgent[name] ?? []
                var status = AgentStatus.of(own)
                if let lead = own.first.flatMap(session), let row = rows.first(where: { $0.session == lead }) {
                    switch row.state {
                    case .needsYou: status = .needsYou
                    case .trouble: status = .trouble
                    case .waiting: status = .waiting
                    case .handed: status = .handed
                    case .working: status = .working
                    case .done: status = .done
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

    /// True while the last thing in an agent's timeline is a message of the user's still awaiting its answer.
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
    var textOption: [String: Int] = UserDefaults.standard.dictionary(forKey: "inboxTextOptions") as? [String: Int] ?? [:] {
        didSet { UserDefaults.standard.set(textOption, forKey: "inboxTextOptions") }
    }
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
            $0.isForYou && (!$0.state.isFinal || ($0.answeredAt ?? .distantPast) >= inboxOpenedAt)
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
        if event.keyCode == 53 { return escape(event) }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if let agent = agentFilter, store.screens[agent] != nil { return pressOnScreen(event, key: key, of: agent) }
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

    /// Escape steps back one thing at a time: a mention, the selector, an agent's screen, dictation, a text option,
    /// the last answer (taken back), the reply field, the agent's view, and last the panel itself.
    private func escape(_ event: NSEvent) -> Bool {
        let editing = event.window?.firstResponder is NSTextView
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

    /// The screen has the keyboard, whatever had focus: arrows, Enter and any character go to the agent's
    /// terminal. (With the message box still focused after sending "/resume", nothing reached the picker.)
    private func pressOnScreen(_ event: NSEvent, key: String, of agent: String) -> Bool {
        let keys: [UInt16: [UInt8]] = [126: [27, 91, 65], 125: [27, 91, 66], 123: [27, 91, 68], 124: [27, 91, 67], 36: [13], 51: [127]]
        if let bytes = keys[event.keyCode] { store.press(bytes, on: agent); return true }
        guard let scalar = key.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) else { return false }
        store.press(Array(key.utf8), on: agent)
        return true
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
