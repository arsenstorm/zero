import AppKit
import SwiftUI
import ZeroCore

/// Which chip opened the selector.
enum SelectorKind { case project, runtime }

/// One row of the selector: what a model or project is, who provides it, and what picking it does.
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
    let rows: [SelectorRow]
}

/// The open selector's transient state: the kind, the search, and which row the pointer or arrows are on.
@MainActor @Observable
final class SelectorState {
    let kind: SelectorKind
    var query = ""
    var highlighted: String?
    var previewed: String?
    @ObservationIgnored var previewTimer: DispatchWorkItem?
    init(kind: SelectorKind) { self.kind = kind }
}

/// Zero's selector, after the dqnamo model selector: a 240 pt list with a search field, rows of name and provider,
/// a soft fill on the current row, and, while a row is hovered, a 224 pt preview card beside it with the
/// description, the context window and the model's configuration. Here the preview sits to the left, because
/// the inbox lives at the screen's right edge.
struct SelectorView: View {
    @Bindable var controller: InboxController
    @Bindable var state: SelectorState
    @FocusState private var searching: Bool

    private var sections: [SelectorSection] {
        let all = controller.selectorSections(for: state.kind)
        let q = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.compactMap { section in
            let rows = section.rows.filter { ($0.title + " " + ($0.provider ?? "") + " " + ($0.detail ?? "")).lowercased().contains(q) }
            return rows.isEmpty ? nil : SelectorSection(id: section.id, title: section.title, rows: rows)
        }
    }
    private var rows: [SelectorRow] { sections.flatMap(\.rows) }
    private var preview: SelectorRow? { rows.first { $0.id == state.previewed } }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let preview, state.kind == .runtime {
                    PreviewCard(row: preview, controller: controller)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))
                } else {
                    Color.clear
                }
            }
            .frame(width: 224, alignment: .topTrailing)
            .animation(.easeOut(duration: 0.15), value: state.previewed)
            list
        }
        .onAppear {
            state.highlighted = rows.first { $0.selected }?.id ?? rows.first?.id
            searching = true
        }
        .onChange(of: state.query) { _, _ in state.highlighted = rows.first?.id }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField(state.kind == .runtime ? "Search models…" : "Search projects…", text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($searching)
                    .onSubmit { pickHighlighted() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if rows.isEmpty {
                VStack(spacing: 2) {
                    Text(state.kind == .runtime ? "No models found" : "No projects found").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("Maybe try a different search.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            if sections.count > 1 {
                                Text(section.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
                            }
                            ForEach(section.rows) { row in rowView(row) }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 320)
                // The list fades at its foot while there is more below.
                .mask(VStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24) })
            }
        }
        .frame(width: 240)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private func rowView(_ row: SelectorRow) -> some View {
        let current = state.highlighted == row.id
        return Button {
            row.pick()
            controller.closeSelector()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 13)).lineLimit(1)
                    if row.provider != nil || row.detail != nil {
                        HStack(spacing: 5) {
                            if let icon = row.providerIcon { icon.resizable().aspectRatio(contentMode: .fit).frame(width: 12, height: 12).clipShape(RoundedRectangle(cornerRadius: 3)) }
                            Text(state.kind == .project ? (row.detail ?? "") : (row.provider ?? "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 4)
                if let badge = badge(for: row) {
                    HStack(spacing: 3) {
                        Image(systemName: "brain").font(.system(size: 9, weight: .bold))
                        Text(badge).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.keycap).clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(row.selected ? Theme.row : (current ? Theme.keycap.opacity(0.6) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            state.previewTimer?.cancel()
            if inside {
                state.highlighted = row.id
                let work = DispatchWorkItem { state.previewed = row.id }
                state.previewTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            } else {
                let work = DispatchWorkItem { if state.previewed == row.id { state.previewed = nil } }
                state.previewTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            }
        }
    }

    /// A reasoning level other than the model's default shows on the row, as the reference does.
    private func badge(for row: SelectorRow) -> String? {
        guard let modelID = row.modelID, !row.levels.isEmpty else { return nil }
        let level = controller.spawnSettings[modelID]?["reasoning"] ?? row.defaultLevel
        guard let level, level != row.defaultLevel else { return nil }
        return level.capitalized
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

/// The hover card: name, provider, description, context, and the configuration Zero will start the model with.
struct PreviewCard: View {
    let row: SelectorRow
    @Bindable var controller: InboxController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).font(.system(size: 13, weight: .medium))
                    if let provider = row.provider {
                        HStack(spacing: 5) {
                            if let icon = row.providerIcon { icon.resizable().aspectRatio(contentMode: .fit).frame(width: 12, height: 12).clipShape(RoundedRectangle(cornerRadius: 3)) }
                            Text(provider).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                if let detail = row.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let context = row.context {
                    HStack(spacing: 4) {
                        Text("CONTEXT").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
                        Text(context).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            if !row.levels.isEmpty, let modelID = row.modelID {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONFIGURATION").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    Text("Reasoning").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(row.levels) { level in
                            let chosen = (controller.spawnSettings[modelID]?["reasoning"] ?? row.defaultLevel) == level.id
                            Button(level.name) { controller.setSpawnSetting(modelID: modelID, key: "reasoning", value: level.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(chosen ? Theme.keycap : Theme.row)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .help(level.detail ?? "")
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 224, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
