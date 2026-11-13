import AppKit
import SwiftUI
import ZeroCore

/// Your messages waiting for after the agent's current turn, as a tab behind the composer: each with edit, delete and
/// Steer (now, mid-turn); its words go back into the composer on a click. Held since you stopped the agent, the tab
/// says so with Send.
struct QueueStrip: View {
    let queued: [Queued]
    /// Sent on by zerod already, waiting only for playback to reach them: shown, not changed.
    var sent: Set<String> = []
    let held: Bool
    /// Paused by you, with how many events wait for your Resume: the strip says so, with Resume.
    var paused: Int?
    /// The agent at it, as the page shows it (ConversationView.shownWorking): a row steers it mid-turn; not, a row
    /// is sent now.
    var working = true
    /// A question card tucked behind it: a hairline along its top, so the sunk card's tab and this one read as two.
    var overCard = false
    /// The pointer on it: the question card behind it comes up, as for the composer.
    var hover: (Bool) -> Void = { _ in }
    let steer: (Queued) -> Void
    let edit: (Queued) -> Void
    let remove: (Queued) -> Void
    let release: () -> Void
    var resume: () -> Void = {}
    @State private var hovered: String?
    /// A control under the pointer: it takes the hover, and the row gives its own up. The row gives it up across the
    /// whole cluster of controls, gaps included, so crossing from one to the next doesn't flash the row.
    @State private var control: String?
    @State private var overControls: String?

    /// The height of a tab's heading: the queue's, and a docked card's.
    static let heading: CGFloat = 28

    var body: some View {
        // The project tab's place and shape, behind the composer's top edge; inside it the panel's parts: a strip
        // naming it, and the queue as rows on their own surface.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                NucleoIcon(paused != nil ? "circle-pause" : held ? "media-stop" : "clock", fill: "glyph", size: 13)
                Text(title).font(.system(size: 12, weight: .medium)).tracking(-0.2)
                Spacer()
                if paused != nil {
                    Button("Resume", action: resume).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        .tip("What came meanwhile goes to the agent first, then your messages")
                } else if held {
                    Button("Send", action: release).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        .tip("You stopped the agent; let the queue go on")
                }
            }
            .foregroundStyle(.secondary)
            // As a docked card's heading sits (its shell's 2 and 14), so "Queued" and "Question" line up, sunk or not.
            .padding(.horizontal, 16).frame(height: Self.heading)
            VStack(spacing: 0) {
                // By place, not id: a message just queued shows at once as Zero's own copy, then as zerod's (a new id),
                // in the same place; by id, the row went and another came in its stead.
                ForEach(Array(queued.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 2) {
                        Button {
                            edit(item)
                        } label: {
                            Text(Self.gist(item)).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).tip("Back into the composer").disabled(sent.contains(item.id))
                        // Edit and delete on squares that take the row's hover when the pointer is on them; then Steer
                        // as a pill, on a hairline so it reads on the hovered row too, solid under the pointer. The
                        // arrow turns the corner: out of the queue and up to the agent.
                        if sent.contains(item.id) {
                            // Sent on by zerod, its turn under way: said so, in its buttons' place (a grey row with
                            // none read as broken), and why the composer says the agent is working.
                            Text("Next").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary).padding(.trailing, 10)
                        } else {
                            HStack(spacing: 2) {
                                square("pen", help: "Edit in the composer", id: item.id + "/edit") { edit(item) }
                                square("trash", help: "Delete", id: item.id + "/delete") { remove(item) }
                                let lit = control == item.id + "/steer"
                                // Paused, nothing to steer: it waits for Resume.
                                if paused == nil {
                                    Button {
                                        steer(item)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(working ? "Steer" : "Send").font(.system(size: 12, weight: .medium))
                                            NucleoIcon("arrow-turn-up-2", size: 12)
                                        }
                                        .foregroundStyle(lit ? AnyShapeStyle(Theme.onKnob) : AnyShapeStyle(.primary))
                                        .padding(.leading, 10).padding(.trailing, 8).frame(height: 24)
                                        .background(lit ? Theme.knob : Theme.chip, in: Capsule())
                                        .overlay(Capsule().strokeBorder(lit ? Color.clear : Theme.stroke))
                                    }
                                    .buttonStyle(PressableStyle()).tip(working ? "Send it now, mid-turn" : "Send it now").padding(
                                        .leading, 4
                                    )
                                    .onHover { inside in
                                        if inside { control = item.id + "/steer" } else if control == item.id + "/steer" { control = nil }
                                    }
                                }
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                            .onHover { inside in if inside { overControls = item.id } else if overControls == item.id { overControls = nil }
                            }
                        }
                    }
                    .padding(.leading, 14).padding(.trailing, 4).frame(height: 32)
                    // The last row runs on under the composer's card by exactly what the card covers, hover and all.
                    .padding(.bottom, index == queued.count - 1 ? 12 : 0)
                    // The tab's own grey: a step down from the surface, never deeper than the strip above the rows.
                    .background { if hovered == item.id && overControls != item.id { Rectangle().fill(Theme.fieldTab) } }
                    .onHover { inside in if inside { hovered = item.id } else if hovered == item.id { hovered = nil } }
                }
            }
            .frame(maxWidth: .infinity)
            // Not the composer's white: the queue is behind the composer, a step back from it.
            .background(Theme.composer)
            // Concentric: the Steer pill's 12 plus its 4 inset is the surface's 16; plus the surface's 2, the tab's 18.
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous))
            .padding(.horizontal, 2)
        }
        // Codex's tab: flat grey, no edge, a little in from the card's sides; the card's shadow gives it depth. The
        // card sits 4 down inside its own column (the composer's top padding), so 16 here puts 12 of the tab under it:
        // the last row's 12 exactly, leaving the same 4 under its pill as over the first row's.
        .background(Theme.fieldTab, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
        // Over a sunk card (the same grey): its top edge drawn, corners and all, so the two tabs don't merge into one.
        .overlay(alignment: .top) {
            if overCard {
                UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous).strokeBorder(Theme.stroke)
                    .mask(alignment: .top) { Rectangle().frame(height: 19) }.allowsHitTesting(false)
            }
        }
        .onHover(perform: hover)
        .padding(.horizontal, 13).padding(.bottom, -16)
    }

    private var title: String {
        guard let paused else { return held ? "Held" : "Queued" }
        return paused == 0 ? "Paused" : "Paused · \(paused) held while paused"
    }

    private func square(_ symbol: String, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIcon(symbol, size: 13).foregroundStyle(.secondary).frame(width: 24, height: 24)
                .background(control == id ? Theme.fieldTab : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle()).tip(help)
        .onHover { inside in if inside { control = id } else if control == id { control = nil } }
    }

    /// The message as one line, all of it (cut at the row's end), not its first line: that can be only "for this:".
    private static func gist(_ item: Queued) -> String {
        let line =
            item.text.replacingOccurrences(of: #"\s*\[Image #\d+\]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        let count = item.images?.count ?? 0
        let pictures = count == 0 ? "" : (count == 1 ? "an image" : "\(count) images")
        return line.isEmpty
            ? (pictures.isEmpty ? item.text : pictures.prefix(1).uppercased() + pictures.dropFirst())
            : (pictures.isEmpty ? line : "\(line) · \(pictures)")
    }
}

/// The composer's + menu, as Codex's: what can go with a message, each with a line about it; a scratchpad opens a
/// list of them to find one in.
struct AddMenu: View {
    enum Page { case add, pads }
    @Binding var page: Page
    let pads: [PadSummary]
    let files: () -> Void
    let pad: (PadSummary) -> Void
    @State private var query = ""
    @State private var hovered: String?
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch page {
            case .add:
                Text("Add").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4).padding(
                    .bottom, 4)
                row(
                    "files", icon: "file", title: "Files and folders", detail: "Images go with it, anything else as its path", action: files
                )
                row("pads", icon: "note-3", title: "Scratchpad", detail: "Point the agent at one of your pads") { page = .pads }
            case .pads:
                HStack(spacing: 8) {
                    Button {
                        page = .add
                    } label: {
                        NucleoIcon("arrow-left", size: 13).foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(
                            Rectangle())
                    }
                    .buttonStyle(.plain).tip("Back")
                    TextField("Find a scratchpad", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                        .onSubmit { if let first = found.first { pad(first) } }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle()).onTapGesture { searching = true }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(found) { summary in
                            row(summary.id, icon: "note-3", title: summary.title, detail: summary.folder.isEmpty ? nil : summary.folder) {
                                pad(summary)
                            }
                        }
                        if found.isEmpty {
                            Text(pads.isEmpty ? "Loading…" : "No scratchpad matches").font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 10).frame(height: 32)
                        }
                    }
                }
                .thinScrollbar()
                .scrollIndicators(.never)
                .frame(height: 8 * 33)
                .onAppear { searching = true }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MenuCard(radius: 12, linear: true))
    }

    /// Most recently changed first; matched on title and folder.
    private var found: [PadSummary] {
        let words = query.lowercased().split(separator: " ")
        return pads.filter { pad in words.allSatisfy { (pad.title + " " + pad.folder).lowercased().contains($0) } }.sorted {
            $0.updated > $1.updated
        }
    }

    private func row(_ id: String, icon: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                NucleoIcon(icon, size: 15).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(SelectorView.menuFont).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(hovered == id ? Theme.menuHover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hovered = id } else if hovered == id { hovered = nil } }
    }
}

/// The selector open from a workspace composer's chip, the control bar's own: one at a time, over the window the
/// chip is in, and a second click on its chip closes it.
@MainActor @Observable
final class WorkspaceSelector {
    static let shared = WorkspaceSelector()
    /// The chip whose selector is open.
    private(set) var open: String?
    @ObservationIgnored private var closed: (chip: String, at: Date)?

    /// `window`: the one the chip is in, when it isn't the key window (the control bar's panel never is).
    func toggle(
        _ chip: String, kind: SelectorKind, anchor: CGRect, in window: NSWindow? = nil, rows: @escaping () -> [SelectorSection],
        level: @escaping (String) -> String? = { _ in nil }, setLevel: @escaping (String, String) -> Void = { _, _ in }
    ) {
        if open == chip { close(); return }
        // The click that closed it through the click-outside monitor arrives here next: it was that close.
        if let closed, closed.chip == chip, Date().timeIntervalSince(closed.at) < 0.3 { return }
        show(chip, kind: kind, anchor: anchor, in: window, rows: rows, level: level, setLevel: setLevel)
    }

    /// Opens it whatever is open, its own included: a right click always brings a menu up where it was made, as Linear
    /// and a Mac do, the open one going in the same frame.
    func show(
        _ chip: String, kind: SelectorKind, anchor: CGRect, in window: NSWindow? = nil, rows: @escaping () -> [SelectorSection],
        level: @escaping (String) -> String? = { _ in nil }, setLevel: @escaping (String, String) -> Void = { _, _ in }
    ) {
        guard let window = window ?? NSApp.keyWindow, let app = NSApp.delegate as? AppDelegate else { return }
        let state = SelectorState(kind: kind)
        state.sections = rows()
        state.rebuild = rows
        state.level = level
        state.setLevel = setLevel
        state.close = { [weak self] in self?.close() }
        open = chip
        app.presentSelector(state, chip: anchor, in: window, returning: window)
    }

    func close() {
        guard let open else { return }
        closed = (open, Date())
        self.open = nil
        (NSApp.delegate as? AppDelegate)?.hideSelector()
    }
}

extension View {
    /// A menu's button opens it as the button goes down, as a Mac's menus do, not a click's release later. Pair with
    /// `unlessClicked` on the Button's own action, which the keyboard and VoiceOver still press.
    func opensOnPress(_ open: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in
                if NSApp.currentEvent?.type == .leftMouseDown { open() }
            })
    }
}

/// A menu button's action but for a click's release: the press already opened it (opensOnPress).
func unlessClicked(_ action: @escaping () -> Void) -> () -> Void {
    { if NSApp.currentEvent?.type != .leftMouseUp { action() } }
}

/// A chip in the composer's row, the control bar's: an icon, what's chosen, and a chevron, on a small pill; it opens
/// Zero's selector, and reads pressed while that's open.
struct ComposerChip: View {
    let id: String
    let label: String
    var symbol: String?
    /// A picture of its own (a provider's mark), before a Nucleo symbol.
    var icon: Image?
    var kind = SelectorKind.project
    /// What's chosen in full colour (the model), as Codex shows it; the rest in grey.
    var prominent = false
    /// A colour for its icon and words, for a choice that should stand out (Unrestricted, orange as in the details).
    var tint: Color? = nil
    /// Picked while a turn runs: kept for the next turn, a clock after its words says so.
    var pending = false
    /// Its icon alone, `label` on hover (the new task page's permissions).
    var iconOnly = false
    let rows: () -> [SelectorSection]
    var level: (String) -> String? = { _ in nil }
    var setLevel: (String, String) -> Void = { _, _ in }
    @State private var anchor = CGRect.zero
    @State private var hovered = false
    @Environment(\.roomyComposer) private var roomy

    var body: some View {
        let open = WorkspaceSelector.shared.open == id
        let toggle = { WorkspaceSelector.shared.toggle(id, kind: kind, anchor: anchor, rows: rows, level: level, setLevel: setLevel) }
        Button(action: unlessClicked(toggle)) {
            HStack(spacing: 5) {
                if let icon {
                    icon.resizable().aspectRatio(contentMode: .fit).frame(width: roomy ? 16 : 14, height: roomy ? 16 : 14).clipShape(
                        RoundedRectangle(cornerRadius: 3))
                } else if let symbol {
                    NucleoIcon(symbol, size: roomy ? 15 : 13).foregroundStyle(
                        tint.map(AnyShapeStyle.init) ?? (roomy ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.secondary)))
                }
                if !iconOnly {
                    Text(label).font(.system(size: roomy ? 14.5 : 13)).lineLimit(1)
                        .foregroundStyle(
                            tint.map(AnyShapeStyle.init)
                                ?? (prominent || roomy ? AnyShapeStyle(.primary.opacity(roomy ? 0.8 : 1)) : AnyShapeStyle(.secondary)))
                }
                if pending { NucleoIcon("clock", size: 11).foregroundStyle(.secondary) }
                // Roomy, as Devin's: plain words, no chevron.
                if !roomy && !iconOnly {
                    NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
                }
            }
            // As tall as the + and Send beside it, so the row's pills are one size; an icon alone, as wide as tall.
            .padding(.horizontal, iconOnly ? 0 : roomy ? 6 : 8).frame(minWidth: iconOnly ? (roomy ? 32 : 28) : nil).frame(
                height: roomy ? 32 : 28
            )
            // Plain words, as Codex's controls are; a soft fill under the pointer, and while its selector is open.
            // On frost, a see-through darkening, which takes the tint under it: an opaque grey read pale blue beside the
            // glow showing through.
            .background(open || hovered ? (roomy ? Theme.frostFill : Theme.hover) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .opensOnPress(toggle)
        .tip(iconOnly ? label : "")
        .onHover { hovered = $0 }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            anchor = $0
        }
    }
}

/// The selector's rows for what a workspace composer chooses.
extension EnvironmentValues {
    /// The new task page's composer: bigger, quieter controls, as Devin's.
    @Entry var roomyComposer = false
}

@MainActor enum ComposerRows {
    /// Each provider's models from its own catalogue, as the control bar's model selector has them; a provider
    /// without one is a single row. `selected` says which (provider, model id) is chosen; `pick` takes one.
    static func models(_ providers: [Provider], selected: (Provider, String) -> Bool, pick: @escaping (Provider, SpawnChoice) -> Void)
        -> [SelectorSection]
    {
        providers.map { provider in
            let catalogue = catalogue(provider)
            let rows =
                catalogue.isEmpty
                ? [
                    SelectorRow(
                        id: provider.rawValue, title: provider.title, provider: nil, providerIcon: provider.mark, detail: nil, context: nil,
                        levels: [], defaultLevel: nil, modelID: nil, selected: selected(provider, "")
                    ) { pick(provider, SpawnChoice(id: "", name: provider.title)) }
                ]
                : catalogue.map { model in
                    SelectorRow(
                        id: provider.rawValue + "/" + model.id, title: model.name, provider: model.provider,
                        providerIcon: choiceIcon(model.icon) ?? provider.mark,
                        detail: model.detail, context: model.context, levels: model.levels, defaultLevel: model.defaultLevel,
                        modelID: provider.rawValue + "/" + model.id, selected: selected(provider, model.id)
                    ) { pick(provider, model) }
                } + (provider == .claude ? [otherClaudeModel(pick: pick)] : [])
            return SelectorSection(id: provider.rawValue, title: provider.title, icon: provider.mark, rows: rows)
        }
    }

    /// Any Claude model by its full name ("claude-opus-5"), typed in place, given to Claude Code as `--model` and
    /// remembered: it's a row of its own from then on.
    private static func otherClaudeModel(pick: @escaping (Provider, SpawnChoice) -> Void) -> SelectorRow {
        SelectorRow(
            id: "claude/other", title: "Other model…", provider: "Anthropic", providerIcon: Provider.claude.mark,
            detail: "Any Claude model by its full name, such as claude-opus-5. It's listed here from then on.", context: nil,
            levels: [], defaultLevel: nil, modelID: nil, selected: false, pick: {},
            entry: { name in
                ClaudeModels.remember(name, typed: true)
                kept[.claude] = nil
                pick(.claude, catalogue(.claude).first { $0.id == name } ?? SpawnChoice(id: name, name: ModelNames.readable(name)))
            })
    }

    /// A task's choices: its own provider's models, then each provider that can take it over (ConversationView.takeOver).
    /// `chosen` is the (provider, model id) in effect; no id means the provider's first.
    static func taskModels(_ conversation: Conversation, chosen: (Provider, String?), pick: @escaping (Provider, SpawnChoice) -> Void)
        -> [SelectorSection]
    {
        let providers = [conversation.provider] + ConversationView.takeOver.filter { $0 != conversation.provider }
        return models(
            providers,
            selected: { provider, id in
                provider == chosen.0 && (id == (chosen.1 ?? "") || (chosen.1 == nil && id == (catalogue(provider).first?.id ?? "")))
            }, pick: pick)
    }

    /// The models a provider's CLI offers the signed-in account, from its own cache, and those the user added to Zero.
    static func catalogue(_ provider: Provider) -> [SpawnChoice] {
        // Kept for a few seconds: the control bar names every task's model on every redraw, each a read of the CLI's
        // cache (and a look at Claude Code's config). Its lists change rarely; a pick shows within seconds.
        // ponytail: a short TTL, not invalidation; drop it on the CLIs' cache changes if a stale list is ever seen.
        if let kept = kept[provider], Date().timeIntervalSince(kept.at) < 3, kept.added == CustomModels.shared.models { return kept.list }
        let list = CustomModels.shared.adding(to: own(provider), for: provider)
        kept[provider] = (Date(), CustomModels.shared.models, list)
        return list
    }
    private static var kept: [Provider: (at: Date, added: [CustomModels.Model], list: [SpawnChoice])] = [:]

    private static func own(_ provider: Provider) -> [SpawnChoice] {
        switch provider {
        case .claude: AgentModels.spawnModels(for: SpawnChoice(id: "claude", name: "Claude"))
        case .codex: AgentModels.spawnModels(for: SpawnChoice(id: "codex", name: "Codex"))
        // Its own list, read in the background: the rows fill in once it's in.
        case .opencode:
            {
                OpenCodeModels.shared.refresh(); return OpenCodeModels.shared.models
            }()
        }
    }

    /// A single list: title, the line under it, whether it's chosen, and what picking it does.
    /// A menu's groups (SelectorKind.menu): each a section, drawn one under another with a line between.
    static func menu(_ groups: [[(id: String, title: String, glyph: String, selected: Bool, pick: () -> Void)]]) -> [SelectorSection] {
        groups.enumerated().map { index, rows in
            SelectorSection(
                id: "group-\(index)", title: "", icon: nil,
                rows: rows.map { row in
                    SelectorRow(
                        id: row.id, title: row.title, provider: nil, providerIcon: nil, detail: nil, context: nil, levels: [],
                        defaultLevel: nil, modelID: nil, selected: row.selected, pick: row.pick, glyph: row.glyph)
                })
        }
    }

    static func list(
        _ title: String, icon: Image? = nil, _ rows: [(id: String, title: String, detail: String?, selected: Bool, pick: () -> Void)]
    ) -> [SelectorSection] {
        [
            SelectorSection(
                id: title, title: title, icon: icon,
                rows: rows.map { row in
                    SelectorRow(
                        id: row.id, title: row.title, provider: nil, providerIcon: nil, detail: row.detail, context: nil, levels: [],
                        defaultLevel: nil, modelID: nil, selected: row.selected, pick: row.pick)
                })
        ]
    }
}

extension Provider {
    /// Its mark, as the control bar's chips show it.
    @MainActor var mark: Image? {
        switch self {
        case .claude: choiceIcon("claude")
        case .codex: choiceIcon("openai")
        case .opencode: choiceIcon("opencode")
        }
    }

    /// Its mark alone, made for a circle (the usage rings): OpenAI's knot without its tile, in the text's colour.
    @MainActor var glyph: Image? { self == .codex ? choiceIcon("openai-glyph") : mark }

    /// How big its glyph is drawn to fill a circle as Claude's does at 11: a dense knot or block looks bigger.
    var glyphSize: CGSize {
        switch self {
        case .claude: CGSize(width: 11, height: 11)
        case .codex: CGSize(width: 10, height: 10)
        case .opencode: CGSize(width: 7.5, height: 9.5)
        }
    }
}
