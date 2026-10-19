import AppKit
import SwiftUI
import ZeroCore

/// Which chip opened the selector.
enum SelectorKind { case project, runtime }

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
}

/// A provider (Anthropic, OpenAI, Solo): one tab of the selector.
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
    init(kind: SelectorKind) { self.kind = kind }
}

/// Zero's selector, a compact palette: provider tabs across the top, the chosen provider's rows beneath at
/// 28 pt each (name left, a small badge right, a tick on the current one), and a single footer line that
/// describes the row under the pointer. ←→ switch provider, ↑↓ move, Return picks, Esc closes.
struct SelectorView: View {
    @Bindable var controller: InboxController
    @Bindable var state: SelectorState
    @FocusState private var focused: Bool
    @State private var moreAbove = false
    @State private var moreBelow = false

    /// Models get two panes, the list and its details, centred on the inbox; projects a single list on the chip.
    static func width(_ kind: SelectorKind) -> CGFloat { kind == .runtime ? 2 * paneWidth : 272 }
    private static let paneWidth: CGFloat = 240
    /// The model list is always eight rows tall, so neither a tab change nor a hover moves anything.
    private static let modelListHeight: CGFloat = 8 * rowHeight + 8 + 7
    private static let rowHeight: CGFloat = 28

    private var sections: [SelectorSection] { state.sections }
    private var section: SelectorSection? { sections.first { $0.id == state.tab } ?? sections.first }
    private var rows: [SelectorRow] { section?.rows ?? [] }
    private var highlightedRow: SelectorRow? { rows.first { $0.id == state.highlighted } }

    var body: some View {
        VStack(spacing: 0) {
            if sections.count > 1 { tabs } else if let section { singleHeader(section) }
            Divider().padding(.horizontal, 10)
            if state.kind == .runtime {
                HStack(spacing: 0) {
                    list.frame(width: Self.paneWidth, height: Self.modelListHeight)
                    Divider().padding(.vertical, 10)
                    details.frame(width: Self.paneWidth - 1, height: Self.modelListHeight)
                }
                .frame(height: Self.modelListHeight) // a vertical Divider would otherwise stretch the row to the strip
            } else {
                list.frame(height: min(CGFloat(max(rows.count, 1)) * Self.rowHeight + 8 + CGFloat(max(rows.count - 1, 0)), Self.modelListHeight))
                Divider().padding(.horizontal, 10)
                footer
            }
        }
        .frame(width: Self.width(state.kind))
        .card()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.cardHeight = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.leftArrow) { switchTab(-1); return .handled }
        .onKeyPress(.rightArrow) { switchTab(1); return .handled }
        .onKeyPress(.return) { pickHighlighted(); return .handled }
        .onKeyPress(.escape) { controller.closeSelector(); return .handled }
        .onAppear {
            // Open on the provider that holds the current pick, with that pick highlighted.
            if state.tab == nil { state.tab = sections.first { $0.rows.contains { $0.selected } }?.id ?? sections.first?.id }
            state.highlighted = rows.first { $0.selected }?.id ?? rows.first?.id
            focused = true
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 1) { ForEach(rows) { rowView($0) } }
                .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .onScrollGeometryChange(for: [Bool].self) { g in
            [g.contentOffset.y > 1, g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1]
        } action: { _, more in moreAbove = more[0]; moreBelow = more[1] }
        .mask(edgeFades)
        .animation(.easeOut(duration: 0.15), value: moreAbove)
        .animation(.easeOut(duration: 0.15), value: moreBelow)
    }

    /// The list fades out at an edge with more rows past it, a hint that it scrolls.
    private var edgeFades: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: moreAbove ? 28 : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: moreBelow ? 28 : 0)
        }
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
                    .background(active ? Theme.keycap : .clear)
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
            controller.closeSelector()
        } label: {
            HStack(spacing: 8) {
                Text(row.title).font(.system(size: 13, weight: row.selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 6)
                // Effort: shown on the chosen row and the one under the pointer, so a pick and its level sit together.
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(row.selected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Theme.row : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { state.highlighted = row.id } }
    }

    /// The right pane: the highlighted model's logo, name and purpose, centred, with its effort slider below.
    /// Moving the slider also picks the model and leaves the selector open.
    @ViewBuilder private var details: some View {
        if let row = highlightedRow {
            let picked = row.modelID.flatMap { controller.spawnSettings[$0]?["reasoning"] } ?? row.defaultLevel
            VStack(spacing: 0) {
                if let icon = row.providerIcon {
                    icon.resizable().aspectRatio(contentMode: .fit).frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 10)
                }
                Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                // Two lines reserved for the description and one for the tokens, so switching models shifts nothing.
                Text(describe(row)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
                    .padding(.top, 4)
                Text(row.context ?? " ").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 4)
                if !row.levels.isEmpty {
                    HStack {
                        Text("Effort").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text(picked.map(effortLabel) ?? "").font(.system(size: 11, weight: .medium)).contentTransition(.numericText())
                    }
                    .padding(.top, 16)
                    EffortSlider(levels: row.levels.map(\.id), picked: picked) { level in
                        row.pick()
                        if let id = row.modelID { controller.setSpawnSetting(modelID: id, key: "reasoning", value: level) }
                        state.sections = controller.selectorSections(for: state.kind)
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

    private func describe(_ row: SelectorRow) -> String { row.detail ?? row.provider ?? "" }


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
        controller.closeSelector()
    }
}

/// Effort level ids as Zero shows them.
func effortLabel(_ id: String) -> String {
    switch id {
    case "xhigh": "XHigh"
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
