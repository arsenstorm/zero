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
    /// The app resizes the panel when the tab changes, keeping the edge nearest the chip in place.
    @ObservationIgnored var onHeightChange: ((CGFloat) -> Void)?
    init(kind: SelectorKind) { self.kind = kind }
}

/// Zero's selector, a compact palette: provider tabs across the top, the chosen provider's rows beneath at
/// 28 pt each (name left, a small badge right, a tick on the current one), and a single footer line that
/// describes the row under the pointer. ←→ switch provider, ↑↓ move, Return picks, Esc closes.
struct SelectorView: View {
    @Bindable var controller: InboxController
    @Bindable var state: SelectorState
    @FocusState private var focused: Bool

    static let width: CGFloat = 272
    private static let rowHeight: CGFloat = 30
    private static let tabsHeight: CGFloat = 44

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
            .frame(height: min(CGFloat(max(rows.count, 1)) * Self.rowHeight + 8 + CGFloat(max(rows.count - 1, 0)), 10 * Self.rowHeight + 8))
            Divider().padding(.horizontal, 10)
            footer
        }
        .frame(width: Self.width)
        .card()
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

    /// The natural height for a kind, so the panel can be sized before the view exists.
    static func height(for sections: [SelectorSection], tab: String?) -> CGFloat {
        let section = sections.first { $0.id == tab } ?? sections.first { $0.rows.contains { $0.selected } } ?? sections.first
        let rows = section?.rows.count ?? 0
        let list = min(CGFloat(max(rows, 1)) * rowHeight + 8 + CGFloat(max(rows - 1, 0)), 10 * rowHeight + 8)
        // The footer holds the tab's longest description in full: about 46 characters per line at 11 pt.
        let longest = section?.rows.map { ($0.detail ?? $0.provider ?? "").count + (($0.context?.count ?? -10) + 10) }.max() ?? 0
        let lines = max(1, Int((Double(longest) / 46).rounded(.up)))
        return tabsHeight + 1 + list + 1 + 18 + CGFloat(lines) * 14
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
        .padding(.horizontal, 10)
        .frame(height: Self.tabsHeight)
    }

    private func select(tab: String) {
        state.tab = tab
        state.highlighted = rows.first { $0.selected }?.id ?? rows.first?.id
        state.onHeightChange?(Self.height(for: sections, tab: tab))
    }

    private func singleHeader(_ section: SelectorSection) -> some View {
        HStack(spacing: 6) {
            if let icon = section.icon {
                icon.resizable().aspectRatio(contentMode: .fit).frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(section.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: Self.tabsHeight)
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

    /// The highlighted row's description in full. Every row's description is laid out underneath, invisible,
    /// so the footer is always as tall as the tab's longest one and never changes height as the pointer moves.
    private var footer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(rows) { row in
                Text(describe(row)).hidden()
            }
            Text(highlightedRow.map(describe) ?? " ")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func describe(_ row: SelectorRow) -> String {
        var parts: [String] = []
        if let detail = row.detail { parts.append(detail) }
        if let context = row.context { parts.append(context + " context") }
        if parts.isEmpty, let provider = row.provider { parts.append(provider) }
        return parts.joined(separator: " · ")
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
        controller.closeSelector()
    }
}
