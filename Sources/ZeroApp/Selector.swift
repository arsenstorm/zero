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

    /// The highlighted row's description, in a box two lines tall with the text centred in it: descriptions fit
    /// two lines, a one-liner sits in the middle, and the box never changes height as the pointer moves.
    private var footer: some View {
        Text(highlightedRow.map(describe) ?? " ")
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30, alignment: .center)
            .padding(.horizontal, 16).padding(.vertical, 7)
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
