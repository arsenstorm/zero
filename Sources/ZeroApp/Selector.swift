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

struct SelectorSection: Identifiable {
    let id: String
    let title: String
    let icon: Image?
    let rows: [SelectorRow]
}

/// The open selector's transient state: the kind and which row the pointer or arrows are on.
@MainActor @Observable
final class SelectorState {
    let kind: SelectorKind
    var highlighted: String?
    init(kind: SelectorKind) { self.kind = kind }
}

/// Zero's selector: a plain dropdown under the chip. Sections per provider, each headed by its icon and name;
/// rows of a specific model (or project) with one line about it; a tick on the current one. Arrows move,
/// Return picks, Esc closes. No search and no preview: the lists are short and the rows say enough.
struct SelectorView: View {
    @Bindable var controller: InboxController
    @Bindable var state: SelectorState
    @FocusState private var focused: Bool

    private var sections: [SelectorSection] { controller.selectorSections(for: state.kind) }
    private var rows: [SelectorRow] { sections.flatMap(\.rows) }
    static let width: CGFloat = 300

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    HStack(spacing: 6) {
                        if let icon = section.icon {
                            icon.resizable().aspectRatio(contentMode: .fit).frame(width: 13, height: 13).clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.top, section.id == sections.first?.id ? 10 : 14).padding(.bottom, 6)
                    ForEach(section.rows) { row in rowView(row) }
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(width: Self.width)
        .frame(height: min(SelectorView.height(for: sections), 460))
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { pickHighlighted(); return .handled }
        .onKeyPress(.escape) { controller.closeSelector(); return .handled }
        .onAppear {
            state.highlighted = rows.first { $0.selected }?.id ?? rows.first?.id
            focused = true
        }
    }

    /// The list's natural height: headers, rows with or without a detail line, paddings. Capped by the caller.
    static func height(for sections: [SelectorSection]) -> CGFloat {
        var height: CGFloat = 6
        for (index, section) in sections.enumerated() {
            height += (index == 0 ? 10 : 14) + 16 + 6
            for row in section.rows { height += row.detail == nil ? 30 : 46 }
        }
        return height
    }

    private func rowView(_ row: SelectorRow) -> some View {
        let current = state.highlighted == row.id
        return Button {
            row.pick()
            controller.closeSelector()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let detail = row.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                if let context = row.context {
                    Text(context).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Theme.keycap).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .opacity(row.selected ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, row.detail == nil ? 6 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Theme.row : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { state.highlighted = row.id } }
    }

    private func move(_ delta: Int) {
        let ids = rows.map(\.id)
        guard let current = state.highlighted, let index = ids.firstIndex(of: current) else { state.highlighted = ids.first; return }
        state.highlighted = ids[max(0, min(ids.count - 1, index + delta))]
    }

    private func pickHighlighted() {
        guard let row = rows.first(where: { $0.id == state.highlighted }) else { return }
        row.pick()
        controller.closeSelector()
    }
}
