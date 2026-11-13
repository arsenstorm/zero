import AppKit
import SwiftUI
import ZeroCore

/// Which chip opened the selector: a project list, the runtime palette, or a plain menu (the sidebar's workspaces):
/// its sections one under another with a line between, no header and no footer.
enum SelectorKind { case project, runtime, menu }

/// One row of the selector: a specific model or project, a line about it, and what picking it does.
struct SelectorRow: Identifiable {
    let id: String
    let title: String
    let provider: String?
    let providerIcon: Image?
    let detail: String?
    let context: String?
    let levels: [SpawnChoice]
    let defaultLevel: String?
    let modelID: String?
    let selected: Bool
    let pick: () -> Void
    /// A menu row's mark before its title: a Nucleo icon's name or an emoji; "" for Zero's own mark.
    var glyph: String? = nil
    /// The mark's fill and colour, where they say something (a task's state: its glyph in its colour).
    var fill = "outline"
    var tint: Color? = nil
    /// A menu row's mark as an image in place of a glyph (an app's own icon).
    var image: Image? = nil
    /// A menu row's own menu, opened beside it as the pointer comes onto it.
    var children: [SelectorRow] = []
    /// A row that takes words: picked, it becomes a field in its place ("Other model…"), and Return gives them here.
    var entry: ((String) -> Void)? = nil
}

/// A provider (Anthropic, OpenAI): one tab of the selector.
struct SelectorSection: Identifiable {
    let id: String
    let title: String
    let icon: Image?
    let rows: [SelectorRow]
}

/// The open selector's transient state: the kind, the provider tab, and the row under the pointer or arrows.
@MainActor @Observable
final class SelectorState {
    let kind: SelectorKind
    var tab: String?
    var highlighted: String?
    /// The rows, built when the selector opens; hovering must not rebuild them.
    var sections: [SelectorSection] = []
    /// The card's laid-out height: the app treats a click in the rest of its strip as a click outside.
    @ObservationIgnored var cardHeight: CGFloat = 0
    /// Each row's frame in the selector's window (top left origin), the card's and its open submenu's.
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    @ObservationIgnored var cardFrame: CGRect = .zero
    @ObservationIgnored var submenuFrame: CGRect?
    /// The menu row whose own menu is open beside it.
    var submenu: String?
    /// The row taking words (SelectorRow.entry), shown as a field.
    var entering: String?
    /// What the selector asks of whoever opened it (the inbox, or a workspace composer): to close it, a model's
    /// effort level and a new one for it, and its rows again after a level changes.
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored var level: (String) -> String? = { _ in nil }
    @ObservationIgnored var setLevel: (String, String) -> Void = { _, _ in }
    @ObservationIgnored var rebuild: () -> [SelectorSection] = { [] }
    init(kind: SelectorKind) { self.kind = kind }
}

/// Zero's selector, a compact palette: provider tabs across the top, the chosen provider's rows beneath at
/// 28 pt each (name left, a small badge right, a tick on the current one), and a single footer line that
/// describes the row under the pointer. ←→ switch provider, ↑↓ move, Return picks, Esc closes.
struct SelectorView: View {
    @Bindable var state: SelectorState
    @FocusState private var focused: Bool

    /// Models get two panes, the list and its details, centred on the inbox; projects a single list on the chip.
    static func width(_ kind: SelectorKind) -> CGFloat {
        switch kind {
        case .runtime: 2 * paneWidth;
        case .project: 272;
        case .menu: 220
        }
    }
    /// A menu as wide as its longest row needs, as Linear's are (no fixed width: a short menu is narrow), its rows'
    /// contents at most Linear's 400.
    static func width(_ state: SelectorState) -> CGFloat {
        state.kind == .menu ? menuWidth(state.sections.flatMap(\.rows)) : width(state.kind)
    }
    static func menuWidth(_ rows: [SelectorRow]) -> CGFloat {
        let font: [NSAttributedString.Key: Any] = [.font: menuNSFont]
        // A row's icon and the gap after it, then its words; a check's place where something can be checked, a
        // chevron's where a row has its own menu.
        let widest = rows.map { ($0.glyph == nil ? 0 : 24) + ($0.title as NSString).size(withAttributes: font).width }.max() ?? 0
        let check: CGFloat = rows.contains(where: \.selected) ? 8 + 13 : 0
        let chevron: CGFloat = rows.contains { !$0.children.isEmpty } ? 8 + 12 : 0
        // Edge and inset and the row's leading; the gap before the spacer, trailing, inset and edge (the row's HStack).
        return (1 + 6 + 8 + min(400, widest + check + chevron) + 8 + 12 + 6 + 1).rounded(.up)
    }
    /// Room beside a menu for the widest of its rows' own menus (and the gap between), none without.
    static func submenuRoom(_ state: SelectorState) -> CGFloat {
        guard state.kind == .menu else { return 0 }
        return state.sections.flatMap(\.rows).filter { !$0.children.isEmpty }.map { menuWidth($0.children) + submenuGap }.max() ?? 0
    }
    static let submenuGap: CGFloat = 4
    private static let paneWidth: CGFloat = 240
    /// The model list is always eight rows tall, so neither a tab change nor a hover moves anything.
    private static let modelListHeight: CGFloat = 8 * rowHeight + 8 + 7
    private static let rowHeight: CGFloat = 28
    /// Linear's menu words: 13 points at weight 450, between regular and medium.
    private static let menuStroke: CGFloat = 1.7
    private static let menuNSFont = NSFont.systemFont(ofSize: 13, weight: NSFont.Weight(0.115))
    /// Every menu row's title: the selector's, the + menu's, @ mentions' and the inbox's workspaces.
    static let menuFont = Font(menuNSFont)
    /// Room around a menu's card in its window for its shadow (Linear's: 18 points of blur, 6 down).
    static func shadowRoom(_ kind: SelectorKind) -> CGFloat { kind == .runtime ? 0 : 24 }
    /// Menus and short lists as Linear's (measured): 12 pt corners, rows 32 tall 6 in from the edge, a 6 pt highlight
    /// (#323234, the row's words and icon white on it), its icon 9 in from the highlight's edge, the words 8 after it.
    /// The model selector keeps its own.
    private var linear: Bool { state.kind != .runtime }
    /// Linear's: a 12 point card, its rows' highlight 8 (not concentric: Linear's own).
    private var radius: CGFloat { linear ? 12 : 14 }
    private var inset: CGFloat { 6 }
    private var highlightRadius: CGFloat { linear ? 8 : radius - inset }
    private var rowHeight: CGFloat { linear ? 32 : Self.rowHeight }

    private var sections: [SelectorSection] { state.sections }
    private var section: SelectorSection? { sections.first { $0.id == state.tab } ?? sections.first }
    private var rows: [SelectorRow] { state.kind == .menu ? sections.flatMap(\.rows) : section?.rows ?? [] }
    private var highlightedRow: SelectorRow? { rows.first { $0.id == state.highlighted } }

    var body: some View {
        VStack(spacing: 0) {
            if state.kind == .menu {
                VStack(spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        // A line between groups, edge to edge, in Linear's 12 points (6 above it, 5 below).
                        if index > 0 {
                            Rectangle().fill(Theme.menuLine).frame(height: 1).padding(.horizontal, -inset).padding(.top, 6)
                                .padding(.bottom, 5)
                        }
                        VStack(spacing: 0) { ForEach(section.rows) { rowView($0) } }
                    }
                }
                .padding(inset)
            } else if state.kind == .runtime {
                if sections.count > 1 { tabs } else if let section { singleHeader(section) }
            }
            if state.kind == .runtime { Divider().padding(.horizontal, 10) }
            if state.kind == .menu {
                EmptyView()
            } else if state.kind == .runtime {
                HStack(spacing: 0) {
                    list.frame(width: Self.paneWidth, height: Self.modelListHeight)
                    Divider().padding(.vertical, 10)
                    details.frame(width: Self.paneWidth - 1, height: Self.modelListHeight)
                }
                .frame(height: Self.modelListHeight) // a vertical Divider would otherwise stretch the row to the strip
            } else if sections.count > 1 {
                // A short list in sections (agents' places, say): tabs, as models have, then its rows.
                tabs
                Divider().padding(.horizontal, 10)
                shortList
            } else {
                shortList
            }
        }
        .frame(width: Self.width(state))
        .modifier(MenuCard(radius: radius, linear: linear))
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            state.cardHeight = $0.height; state.cardFrame = $0
        }
        .overlay(alignment: .topLeading) { submenu }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            move(1); return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1); return .handled
        }
        .onKeyPress(.leftArrow) {
            switchTab(-1); return .handled
        }
        .onKeyPress(.rightArrow) {
            switchTab(1); return .handled
        }
        .onKeyPress(.return) {
            pickHighlighted(); return .handled
        }
        .onKeyPress(.escape) {
            state.close(); return .handled
        }
        .onAppear {
            // Open on the provider that holds the current pick, with that pick highlighted.
            if state.tab == nil { state.tab = sections.first { $0.rows.contains { $0.selected } }?.id ?? sections.first?.id }
            state.highlighted = rows.first { $0.selected }?.id ?? rows.first?.id
            focused = true
        }
    }

    /// A short list (permissions, projects, workspaces): no heading (the chip said what it is) and no footer (each row
    /// says what it is), as tall as its rows; past eight, it scrolls.
    @ViewBuilder private var shortList: some View {
        let column = VStack(spacing: linear ? 0 : 1) { ForEach(rows) { rowView($0) } }.padding(inset)
        if rows.count <= 8 {
            column
        } else {
            ScrollView(.vertical, showsIndicators: false) { column }.frame(height: Self.modelListHeight + 40).scrollEdgeFades()
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 1) { ForEach(rows) { rowView($0) } }
                .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .scrollEdgeFades()
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(sections) { section in
                let active = section.id == (state.tab ?? sections.first?.id)
                Button {
                    select(tab: section.id)
                } label: {
                    HStack(spacing: 6) {
                        if let icon = section.icon {
                            icon.resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14).clipShape(
                                RoundedRectangle(cornerRadius: 3))
                        }
                        Text(section.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(active ? .primary : .secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(active ? Theme.row : .clear) // the row tint: a key cap's grey is too heavy on the card
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }

    private func select(tab: String) {
        state.tab = tab
        state.highlighted = rows.first { $0.selected }?.id ?? rows.first?.id
    }

    private func singleHeader(_ section: SelectorSection) -> some View {
        HStack(spacing: 6) {
            if let icon = section.icon {
                icon.resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(section.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// The open row's own menu, beside the card, its first row level with the row (past the card's edge and inset).
    @ViewBuilder private var submenu: some View {
        if state.kind == .menu, let id = state.submenu, let parent = rows.first(where: { $0.id == id }), let at = state.rowFrames[id] {
            VStack(spacing: 0) { ForEach(parent.children) { rowView($0, in: parent.children) } }
                .padding(inset)
                .frame(width: Self.menuWidth(parent.children))
                .modifier(MenuCard(radius: radius, linear: true))
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    state.submenuFrame = $0
                }
                .onDisappear { state.submenuFrame = nil }
                .offset(x: Self.width(state) + Self.submenuGap, y: at.minY - state.cardFrame.minY - inset - 1)
        }
    }

    /// A row; `siblings` given, one of a row's own menu. One taking words, picked, is a field in its place.
    @ViewBuilder private func rowView(_ row: SelectorRow, in siblings: [SelectorRow]? = nil) -> some View {
        if let entry = row.entry, state.entering == row.id {
            EntryRow(title: row.title, height: rowHeight, radius: highlightRadius) { words in
                entry(words)
                state.close()
            } cancel: {
                state.entering = nil
            }
        } else {
            buttonRow(row, in: siblings)
        }
    }

    private func buttonRow(_ row: SelectorRow, in siblings: [SelectorRow]? = nil) -> some View {
        // The row whose menu is open stays lit while the pointer is in that menu.
        let current = state.highlighted == row.id || state.submenu == row.id
        let parent = !row.children.isEmpty
        return Button {
            // A row with its own menu opens it; one taking words becomes a field; the rest act and close.
            if row.entry != nil {
                state.entering = row.id
            } else if parent {
                state.submenu = row.id
            } else {
                row.pick()
                state.close()
            }
        } label: {
            let described = state.kind == .project ? describe(row) : ""
            HStack(alignment: described.isEmpty ? .center : .top, spacing: 8) {
                if let image = row.image {
                    image.resizable().frame(width: 16, height: 16)
                } else if let glyph = row.glyph, row.fill != "outline" {
                    // A filled mark in its own colour (a task's state, as the sidebar draws it).
                    NucleoIcon(glyph, fill: row.fill, size: 16).foregroundStyle(row.tint ?? Theme.menuIcon).frame(width: 16)
                } else if let glyph = row.glyph {
                    // Linear's weight: 1.5 points at 16 (Nucleo's 1.5 on its 18 point grid drew 1.33).
                    WorkspaceGlyph(glyph: glyph, size: linear ? 16 : 14, stroke: linear ? Self.menuStroke : nil)
                        .foregroundStyle(row.tint ?? (linear ? (current ? Theme.menuHot : Theme.menuIcon) : Color.secondary)).frame(
                            width: linear ? 16 : 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(state.kind == .menu ? Self.menuFont : .system(size: 13, weight: .medium)).lineLimit(1)
                        .foregroundStyle(linear ? (current ? Theme.menuHot : Theme.menuText) : Color.primary)
                    if !described.isEmpty {
                        Text(described).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: linear ? 0 : 6)
                // The check's place only where something can be checked: a menu of actions has none, and kept no gap.
                if (siblings ?? rows).contains(where: \.selected) {
                    NucleoIcon("check", size: 13).foregroundStyle(Color.accentColor).opacity(row.selected ? 1 : 0)
                }
                if parent { NucleoIcon("chevron-right", size: 12).foregroundStyle(Theme.menuIcon) }
            }
            // Linear's: the icon 14 in from the card's edge, the words 18 from its far one.
            .padding(.leading, linear ? 8 : 10).padding(.trailing, linear ? 12 : 10).padding(.vertical, described.isEmpty ? 0 : 7)
            .frame(minHeight: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? (linear ? Theme.menuHover : Theme.row) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: highlightRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            guard inside else { return }
            state.highlighted = row.id
            // Onto a row of the menu itself: its own menu opens, any other closes.
            if siblings == nil, state.kind == .menu { state.submenu = parent ? row.id : nil }
        }
        // Where it is in the window: a right-button drag (which hover doesn't follow) finds its row by it.
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            state.rowFrames[row.id] = $0
        }
    }

    /// The right pane: the highlighted model's logo, name and purpose, centred, with its effort slider below.
    /// Moving the slider also picks the model and leaves the selector open.
    @ViewBuilder private var details: some View {
        if let row = highlightedRow {
            let picked = row.modelID.flatMap(state.level) ?? row.defaultLevel
            VStack(spacing: 0) {
                if let icon = row.providerIcon {
                    icon.resizable().aspectRatio(contentMode: .fit).frame(width: 36, height: 36).clipShape(
                        RoundedRectangle(cornerRadius: 8)
                    )
                    .padding(.bottom, 10)
                }
                // Every text row has a fixed whole-point height (two lines for the description), so switching
                // models shifts nothing: measured text heights differ by fractions between one and two lines.
                Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(height: 16)
                Text(describe(row)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(height: 28, alignment: .top)
                    .padding(.top, 4)
                Text(row.context ?? " ").font(.system(size: 11)).foregroundStyle(.tertiary).frame(height: 14).padding(.top, 4)
                if !row.levels.isEmpty {
                    HStack {
                        Text("Effort").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text(picked.map { effortLabel($0) } ?? "").font(.system(size: 11, weight: .medium)).contentTransition(
                            .numericText())
                    }
                    .frame(height: 14)
                    .padding(.top, 16)
                    EffortSlider(levels: row.levels.map(\.id), picked: picked) { level in
                        if let id = row.modelID { state.setLevel(id, level) }
                        row.pick() // after the level is saved: for a running agent the pick sends it along
                        state.sections = state.rebuild()
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14).padding(.vertical, 14)
        }
    }

    /// The highlighted row's description on one line, in a box that never changes height as the pointer moves.
    private var footer: some View {
        Text(highlightedRow.map(describe) ?? " ")
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Catalogue descriptions arrive with and without a full stop; here they all end in one.
    private func describe(_ row: SelectorRow) -> String {
        let text = (row.detail ?? row.provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return text }
        return ".!?…".contains(last) ? text : text + "."
    }

    private func move(_ delta: Int) {
        let ids = rows.map(\.id)
        guard let current = state.highlighted, let index = ids.firstIndex(of: current) else { state.highlighted = ids.first; return }
        state.highlighted = ids[max(0, min(ids.count - 1, index + delta))]
    }

    private func switchTab(_ delta: Int) {
        let ids = sections.map(\.id)
        guard ids.count > 1, let index = ids.firstIndex(of: state.tab ?? ids[0]) else { return }
        select(tab: ids[(index + delta + ids.count) % ids.count])
    }

    private func pickHighlighted() {
        guard let row = highlightedRow else { return }
        if row.entry != nil { state.entering = row.id; return }
        row.pick()
        state.close()
    }
}

/// A row's place as a field for words (SelectorRow.entry), the row's height and highlight: Return gives the words,
/// Esc goes back to the row.
private struct EntryRow: View {
    let title: String
    let height: CGFloat
    let radius: CGFloat
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var words = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $words)
            .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
            .focused($focused)
            .onSubmit {
                let typed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty { submit(typed) }
            }
            .onExitCommand(perform: cancel)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onAppear { focused = true }
    }
}

/// Effort level ids as Zero shows them; `short` is for the chip, where "Extra High" would not fit.
func effortLabel(_ id: String, short: Bool = false) -> String {
    switch id {
    case "xhigh": short ? "XHigh" : "Extra High"
    default: id.capitalized
    }
}

/// A stepped slider for effort: a thick track whose fill warms from amber to red as the level rises, points that
/// grow with the level, and a knob that swells while held and snaps to the nearest point. Not the system slider.
struct EffortSlider: View {
    let levels: [String]
    let picked: String?
    let onPick: (String) -> Void
    @State private var held = false

    private let trackHeight: CGFloat = 10
    private let knob: CGFloat = 18
    private let heat = [
        Color(red: 0.95, green: 0.72, blue: 0.25), Color(red: 0.95, green: 0.45, blue: 0.15), Color(red: 0.90, green: 0.22, blue: 0.18),
    ]

    var body: some View {
        let index = picked.flatMap { levels.firstIndex(of: $0) } ?? 0
        GeometryReader { geo in
            // Points run from one rounded end of the track to the other; the knob overhangs a little at the extremes.
            let inset = trackHeight / 2
            let step = levels.count > 1 ? (geo.size.width - trackHeight) / CGFloat(levels.count - 1) : 0
            let x = inset + step * CGFloat(index)
            let mid = geo.size.height / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.row).frame(height: trackHeight)
                // The gradient spans the whole track and is revealed up to the knob, so the colour at the knob is the level's.
                Capsule().fill(LinearGradient(colors: heat, startPoint: .leading, endPoint: .trailing)).frame(height: trackHeight)
                    .mask(alignment: .leading) { Capsule().frame(width: x + trackHeight / 2) }
                ForEach(levels.indices, id: \.self) { i in
                    let size = 3 + CGFloat(i) * 4 / CGFloat(max(levels.count - 1, 1))
                    Circle().fill(i <= index ? Color.white.opacity(0.6) : Color.primary.opacity(0.22))
                        .frame(width: size, height: size)
                        .position(x: inset + step * CGFloat(i), y: mid)
                }
                Circle().fill(Theme.knob)
                    .frame(width: knob, height: knob)
                    .scaleEffect(held ? 1.2 : 1)
                    .position(x: x, y: mid)
            }
            .animation(.snappy(duration: 0.2), value: index)
            .animation(.snappy(duration: 0.15), value: held)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        held = true
                        guard step > 0 else { return }
                        let i = Int(((value.location.x - inset) / step).rounded())
                        let level = levels[max(0, min(levels.count - 1, i))]
                        if level != picked {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            onPick(level)
                        }
                    }
                    .onEnded { _ in held = false })
        }
        .frame(height: knob + 4)
    }
}

/// A scroll view fades out at an edge with more content past it, a hint that it scrolls. Nothing in the mask
/// changes size: the strips are fixed and punch their fade out of the solid mask, and only their opacity
/// animates. (A strip that grew from 0 pt animated its first layout, and with it the whole mask, over the rows.)
struct ScrollEdgeFades: ViewModifier {
    var fade: CGFloat = 28
    @State private var moreAbove = false
    @State private var moreBelow = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { g in
                [g.contentOffset.y > 1, g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1]
            } action: { _, more in
                moreAbove = more[0]; moreBelow = more[1]
            }
            .mask(EdgeFadeMask(above: moreAbove, below: moreBelow, fade: fade))
    }
}

/// The mask behind the fades: solid, with two fixed strips that punch a gradient out of it when there is more
/// past that edge. Only their opacity animates, so the mask never moves over the content.
struct EdgeFadeMask: View {
    let above: Bool
    let below: Bool
    var fade: CGFloat = 28
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 0) {
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
                    .blendMode(.destinationOut).opacity(above ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: above)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
                    .blendMode(.destinationOut).opacity(below ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: below)
            }
        }
        .compositingGroup()
    }
}

extension View {
    func scrollEdgeFades(_ fade: CGFloat = 28) -> some View { modifier(ScrollEdgeFades(fade: fade)) }
}

/// One item of a right-click menu: its words, a Nucleo icon's name, what it does; or, with `children`, a menu of its
/// own opened beside it.
struct MenuItem {
    let title: String
    var glyph: String? = nil
    var fill = "outline"
    var tint: Color? = nil
    var image: Image? = nil
    var selected = false
    var children: [MenuItem] = []
    var action: () -> Void = {}
    init(_ title: String, _ glyph: String? = nil, image: Image? = nil, action: @escaping () -> Void) {
        self.title = title; self.glyph = glyph; self.image = image; self.action = action
    }
    init(_ title: String, _ glyph: String?, children: [MenuItem]) {
        self.title = title; self.glyph = glyph; self.children = children
    }
    /// A mark filled and coloured, and checked when it's the one in force (a task's state).
    init(_ title: String, glyph: String, tint: Color, selected: Bool, action: @escaping () -> Void) {
        self.title = title; self.glyph = glyph; self.fill = "glyph"; self.tint = tint; self.selected = selected; self.action = action
    }

    func row(_ id: String) -> SelectorRow {
        SelectorRow(
            id: id, title: title, provider: nil, providerIcon: nil, detail: nil, context: nil, levels: [], defaultLevel: nil,
            modelID: nil, selected: selected, pick: action, glyph: glyph, fill: fill, tint: tint, image: image,
            children: children.enumerated().map { $1.row("\(id)-\($0)") })
    }
}

extension View {
    /// A right-click menu in Zero's own look (Linear's, as every menu of Zero's), at the pointer, in place of the
    /// system's: its groups with a line between, a row with children opening its own menu beside it.
    func zeroContextMenu(_ id: String, _ groups: @escaping () -> [[MenuItem]]) -> some View {
        modifier(ContextMenuHost(id: id, groups: groups))
    }
}

extension EnvironmentValues {
    /// The view's right-click menu is open: what it lies over shows as under the pointer (Hovering's tile), as Linear's
    /// rows do while their menu is up.
    @Entry var menuShown = false
}

private struct ContextMenuHost: ViewModifier {
    let id: String
    let groups: () -> [[MenuItem]]
    func body(content: Content) -> some View {
        content
            .environment(\.menuShown, WorkspaceSelector.shared.open == "menu-" + id)
            .overlay { RightClick { ZeroContextMenu.open(id, groups) } }
    }
}

@MainActor enum ZeroContextMenu {
    static func open(_ id: String, _ groups: @escaping () -> [[MenuItem]]) {
        let point = NSEvent.mouseLocation
        guard let window = NSApp.window(withWindowNumber: NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)),
            let content = window.contentView
        else { return }
        let inWindow = window.convertPoint(fromScreen: point)
        // SwiftUI's global frame (the window's content, from its top left): the menu hangs off the pointer.
        let anchor = CGRect(x: inWindow.x, y: content.bounds.height - inWindow.y, width: 1, height: 1)
        WorkspaceSelector.shared.toggle("menu-" + id, kind: .menu, anchor: anchor, in: window) { sections(groups()) }
    }

    /// A menu's groups as the selector's sections, a line between each.
    static func sections(_ groups: [[MenuItem]]) -> [SelectorSection] {
        groups.filter { !$0.isEmpty }.enumerated().map { index, items in
            SelectorSection(
                id: "group-\(index)", title: "", icon: nil,
                rows: items.enumerated().map { n, item in item.row("\(index)-\(n)") })
        }
    }
}

/// A right-click on what it lies over, and nothing else: any other click goes through to the view under it.
struct RightClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> Catcher { Catcher(action: action) }
    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let event = NSApp.currentEvent?.type
            return event == .rightMouseDown || event == .rightMouseUp ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action() }
    }
}

/// A menu's card: Linear's (its surface under a hairline edge, three soft shadows), or the model selector's lighter one.
struct MenuCard: ViewModifier {
    let radius: CGFloat
    let linear: Bool
    func body(content: Content) -> some View {
        content
            .background(linear ? Theme.menu : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(
                    linear ? Theme.menuStroke : Theme.stroke, lineWidth: linear ? 1 : 0.5)
            )
            // Linear's three soft shadows (0 6 18 at 2%, 0 3 9 at 4%, 0 1 1 at 4%): a SwiftUI radius is half CSS's blur.
            .compositingGroup()
            .shadow(color: .black.opacity(linear ? 0.02 : 0), radius: 9, y: 6)
            .shadow(color: .black.opacity(linear ? 0.04 : 0), radius: 4.5, y: 3)
            .shadow(color: .black.opacity(linear ? 0.04 : 0), radius: 0.5, y: 1)
    }
}
