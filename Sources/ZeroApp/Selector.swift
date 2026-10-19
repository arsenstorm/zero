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

    /// Models need room for their effort pills; projects do not.
    static func width(_ kind: SelectorKind) -> CGFloat { kind == .runtime ? 400 : 272 }
    private static let rowHeight: CGFloat = 30

    private var sections: [SelectorSection] { state.sections }
    private var section: SelectorSection? { sections.first { $0.id == state.tab } ?? sections.first }
    private var rows: [SelectorRow] { section?.rows ?? [] }
    private var highlightedRow: SelectorRow? { rows.first { $0.id == state.highlighted } }

    var body: some View {
        VStack(spacing: 0) {
            if sections.count > 1 { tabs } else if let section { singleHeader(section) }
            Divider().padding(.horizontal, 10)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) { ForEach(rows) { rowView($0) } }
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(max(rows.count, 1)) * Self.rowHeight + 8 + CGFloat(max(rows.count - 1, 0)), 8 * Self.rowHeight + 8 + 7))
            .onScrollGeometryChange(for: [Bool].self) { g in
                [g.contentOffset.y > 1, g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1]
            } action: { _, more in moreAbove = more[0]; moreBelow = more[1] }
            .mask(edgeFades)
            .animation(.easeOut(duration: 0.15), value: moreAbove)
            .animation(.easeOut(duration: 0.15), value: moreBelow)
            Divider().padding(.horizontal, 10)
            footer
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
                if !row.levels.isEmpty, row.selected || current { levels(row) }
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

    /// A row's effort levels as pills; the current one is filled. Picking one also picks the row, and leaves the
    /// selector open so the level can be changed again.
    private func levels(_ row: SelectorRow) -> some View {
        let picked = row.modelID.flatMap { controller.spawnSettings[$0]?["reasoning"] } ?? row.defaultLevel
        return HStack(spacing: 1) {
            ForEach(row.levels, id: \.id) { level in
                Button {
                    row.pick()
                    if let id = row.modelID { controller.setSpawnSetting(modelID: id, key: "reasoning", value: level.id) }
                    state.sections = controller.selectorSections(for: state.kind)
                } label: {
                    Text(effortLabel(level.id)).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(level.id == picked ? .primary : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(level.id == picked ? Theme.keycap : .clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
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
