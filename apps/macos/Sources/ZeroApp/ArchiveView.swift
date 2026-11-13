import SwiftUI
import ZeroCore

/// The tasks archived, newest first: each with when it went, its workspace and the workers that went with it, and a
/// way back. Unarchived, a task comes back with those workers (not with one archived on its own before it). A worker
/// archived on its own is folded under its lead when that's archived too, or with the others whose lead is still here.
struct ArchiveSheet: View {
    let workspace: Workspace
    @Environment(\.closeDialog) private var dismiss
    @State private var archived: [ZerodLink.Archived]?
    @State private var search = ""
    @State private var restoring: String?
    @State private var unfolded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(text: "Archived tasks")
            TextField("Search", text: $search).textFieldStyle(.dialog).firstField()
            ScrollView {
                VStack(spacing: 1) {
                    if let archived {
                        let shown = archived.filter { search.isEmpty || $0.task.localizedCaseInsensitiveContains(search) }
                        if shown.isEmpty {
                            Text(archived.isEmpty ? "Nothing archived" : "No archived task matches").font(.system(size: 13))
                                .foregroundStyle(.tertiary).padding(.top, 20)
                        }
                        if !search.isEmpty {
                            ForEach(shown) { task in row(task) }
                        } else {
                            let leads = Set(shown.filter { $0.parent == nil }.map(\.id))
                            let under = Dictionary(grouping: shown.filter { $0.parent.map(leads.contains) ?? false }) { $0.parent! }
                            ForEach(shown.filter { $0.parent == nil }) { task in
                                row(task)
                                if let workers = under[task.id] {
                                    folded(task.id, "\(workers.count) closed \(workers.count == 1 ? "worker" : "workers")", workers)
                                }
                            }
                            let orphans = shown.filter { $0.parent != nil && !leads.contains($0.parent!) }
                            if !orphans.isEmpty {
                                folded("others", "\(orphans.count) closed workers of tasks still here", orphans, indent: 0)
                            }
                        }
                    } else {
                        Spinner().frame(width: 16, height: 16).padding(.top, 20)
                    }
                }
            }
            .thinScrollbar()
            HStack {
                Spacer()
                DialogButton(title: "Done", kind: .primary) { dismiss() }
            }
        }
        .frame(width: 520, height: 460)
        .task { archived = await workspace.archived() }
    }

    /// Closed workers, folded away until asked for.
    @ViewBuilder private func folded(_ key: String, _ title: String, _ workers: [ZerodLink.Archived], indent: CGFloat = 20) -> some View {
        let open = unfolded.contains(key)
        Button {
            if open { unfolded.remove(key) } else { unfolded.insert(key) }
        } label: {
            HStack(spacing: 6) {
                NucleoIcon("chevron-down", size: 10).rotationEffect(.degrees(open ? 0 : -90)).frame(width: 10)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.leading, indent)
        if open { ForEach(workers) { worker in row(worker).padding(.leading, indent) } }
    }

    private func row(_ task: ZerodLink.Archived) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.task).font(.system(size: 13, weight: .medium)).lineLimit(1)
                // What it last heard while archived, when it heard something: why it's still here and not back.
                if let quiet = task.quiet, let at = task.quietAt {
                    let when = Date(timeIntervalSince1970: TimeInterval(at) / 1000).formatted(.relative(presentation: .named))
                    Text("\(quiet) · \(when)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        .tip(details(task))
                } else {
                    Text(details(task)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if restoring == task.id {
                Spinner().frame(width: 14, height: 14)
            } else {
                RowButton(title: "Unarchive", enabled: restoring == nil) {
                    restoring = task.id
                    Task {
                        await workspace.unarchive(task.id)
                        archived?.removeAll { $0.id == task.id }
                        restoring = nil
                    }
                }
            }
        }
        // A list on the dialog's card, a line under each row: not tiles, nor a card in the card.
        .padding(.horizontal, 10).frame(height: 44)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func details(_ task: ZerodLink.Archived) -> String {
        var parts = [task.date.formatted(.relative(presentation: .named))]
        if task.workers > 0 { parts.append(task.workers == 1 ? "1 worker" : "\(task.workers) workers") }
        if let id = task.workspace, let name = workspace.workspaces.first(where: { $0.id == id })?.name { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}
