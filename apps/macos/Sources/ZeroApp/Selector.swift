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
    static func width(_ kind: SelectorKind) -> CGFloat { switch kind { case .runtime: 2 * paneWidth; case .project: 272; case .menu: 220 } }
    private static let paneWidth: CGFloat = 240
    /// The model list is always eight rows tall, so neither a tab change nor a hover moves anything.
    private static let modelListHeight: CGFloat = 8 * rowHeight + 8 + 7
    private static let rowHeight: CGFloat = 28
    /// Menus and short lists as Linear's (measured): 10 pt corners, rows 32 tall 6 in from the edge, a 6 pt highlight
    /// (#323234, the row's words and icon white on it), its icon 9 in from the highlight's edge, the words 8 after it.
    /// The model selector keeps its own.
    private var linear: Bool { state.kind != .runtime }
    private var radius: CGFloat { linear ? 10 : 14 }
    private var inset: CGFloat { 6 }
    private var highlightRadius: CGFloat { linear ? 6 : radius - inset }
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
                        // A line between groups, edge to edge, 5 above and below.
                        if index > 0 { Rectangle().fill(Theme.menuLine).frame(height: 1).padding(.horizontal, -inset).padding(.vertical, 5) }
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
        .frame(width: Self.width(state.kind))
        // Lighter than a page's card: a hairline edge, a little less round. (The window gives it its shadow.)
        .background(linear ? Theme.menu : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(linear ? Theme.menuStroke : Theme.stroke, lineWidth: linear ? 1 : 0.5))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.cardHeight = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.leftArrow) { switchTab(-1); return .handled }
        .onKeyPress(.rightArrow) { switchTab(1); return .handled }
        .onKeyPress(.return) { pickHighlighted(); return .handled }
        .onKeyPress(.escape) { state.close(); return .handled }
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
        if rows.count <= 8 { column } else { ScrollView(.vertical, showsIndicators: false) { column }.frame(height: Self.modelListHeight + 40).scrollEdgeFades() }
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
                Button { select(tab: section.id) } label: {
                    HStack(spacing: 6) {
                        if let icon = section.icon {
                            icon.resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
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

    private func rowView(_ row: SelectorRow) -> some View {
        let current = state.highlighted == row.id
        return Button {
            row.pick()
            state.close()
        } label: {
            let described = state.kind == .project ? describe(row) : ""
            HStack(alignment: described.isEmpty ? .center : .top, spacing: 8) {
                if let glyph = row.glyph {
                    WorkspaceGlyph(glyph: glyph, size: linear ? 16 : 14)
                        .foregroundStyle(linear ? (current ? Theme.menuHot : Theme.menuIcon) : Color.secondary).frame(width: linear ? 16 : 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.system(size: 13, weight: state.kind == .menu ? .regular : .medium)).lineLimit(1)
                        .foregroundStyle(linear ? (current ? Theme.menuHot : Theme.menuText) : Color.primary)
                    if !described.isEmpty {
                        Text(described).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                // The check's place only where something can be checked: a menu of actions has none, and kept no gap.
                if rows.contains(where: \.selected) { NucleoIcon("check", size: 13).foregroundStyle(Color.accentColor).opacity(row.selected ? 1 : 0) }
            }
            .padding(.leading, linear ? 9 : 10).padding(.trailing, 10).padding(.vertical, described.isEmpty ? 0 : 7)
            .frame(minHeight: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? (linear ? Theme.menuHover : Theme.row) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: highlightRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { state.highlighted = row.id } }
    }

    /// The right pane: the highlighted model's logo, name and purpose, centred, with its effort slider below.
    /// Moving the slider also picks the model and leaves the selector open.
    @ViewBuilder private var details: some View {
        if let row = highlightedRow {
            let picked = row.modelID.flatMap(state.level) ?? row.defaultLevel
            VStack(spacing: 0) {
                if let icon = row.providerIcon {
                    icon.resizable().aspectRatio(contentMode: .fit).frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
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
                        Text(picked.map { effortLabel($0) } ?? "").font(.system(size: 11, weight: .medium)).contentTransition(.numericText())
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
        row.pick()
        state.close()
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
    private let heat = [Color(red: 0.95, green: 0.72, blue: 0.25), Color(red: 0.95, green: 0.45, blue: 0.15), Color(red: 0.90, green: 0.22, blue: 0.18)]

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
            .gesture(DragGesture(minimumDistance: 0)
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
            } action: { _, more in moreAbove = more[0]; moreBelow = more[1] }
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

/// One item of a right-click menu: its words, a Nucleo icon's name, what it does.
struct MenuItem {
    let title: String
    var glyph: String? = nil
    let action: () -> Void
    init(_ title: String, _ glyph: String? = nil, action: @escaping () -> Void) { self.title = title; self.glyph = glyph; self.action = action }
}

extension View {
    /// A right-click menu in Zero's own look (Linear's, as every menu of Zero's), at the pointer, in place of the
    /// system's: its groups with a line between. No submenus: what one held goes in a group of its own.
    func zeroContextMenu(_ id: String, _ groups: @escaping () -> [[MenuItem]]) -> some View {
        overlay { RightClick { ZeroContextMenu.open(id, groups) } }
    }
}

@MainActor enum ZeroContextMenu {
    static func open(_ id: String, _ groups: @escaping () -> [[MenuItem]]) {
        let point = NSEvent.mouseLocation
        guard let window = NSApp.window(withWindowNumber: NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)),
              let content = window.contentView else { return }
        let inWindow = window.convertPoint(fromScreen: point)
        // SwiftUI's global frame (the window's content, from its top left): the menu hangs off the pointer.
        let anchor = CGRect(x: inWindow.x, y: content.bounds.height - inWindow.y, width: 1, height: 1)
        WorkspaceSelector.shared.toggle("menu-" + id, kind: .menu, anchor: anchor, in: window) {
            groups().filter { !$0.isEmpty }.enumerated().map { index, items in
                SelectorSection(id: "group-\(index)", title: "", icon: nil, rows: items.enumerated().map { n, item in
                    SelectorRow(id: "\(index)-\(n)", title: item.title, provider: nil, providerIcon: nil, detail: nil, context: nil, levels: [],
                                defaultLevel: nil, modelID: nil, selected: false, pick: item.action, glyph: item.glyph)
                })
            }
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

