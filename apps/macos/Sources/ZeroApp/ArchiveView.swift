import SwiftUI
import ZeroCore

/// The tasks archived, newest first: each with when it went, its workspace and the workers that went with it, and a
/// way back. Unarchived, a task comes back with those workers (not with one archived on its own before it).
struct ArchiveSheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var archived: [ZerodLink.Archived]?
    @State private var search = ""
    @State private var restoring: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Archived tasks").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(spacing: 1) {
                    if let archived {
                        let shown = archived.filter { search.isEmpty || $0.task.localizedCaseInsensitiveContains(search) }
                        if shown.isEmpty {
                            Text(archived.isEmpty ? "Nothing archived." : "No archived task matches.").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.top, 20)
                        }
                        ForEach(shown) { task in row(task) }
                    } else {
                        Spinner().frame(width: 16, height: 16).padding(.top, 20)
                    }
                }
            }
            .thinScrollbar()
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task { archived = await workspace.archived() }
    }

    private func row(_ task: ZerodLink.Archived) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.task).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(details(task)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if restoring == task.id {
                Spinner().frame(width: 14, height: 14)
            } else {
                Button("Unarchive") {
                    restoring = task.id
                    Task {
                        await workspace.unarchive(task.id)
                        archived?.removeAll { $0.id == task.id }
                        restoring = nil
                    }
                }
                .disabled(restoring != nil)
            }
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(Theme.row.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func details(_ task: ZerodLink.Archived) -> String {
        var parts = [task.date.formatted(.relative(presentation: .named))]
        if task.workers > 0 { parts.append(task.workers == 1 ? "1 worker" : "\(task.workers) workers") }
        if let id = task.workspace, let name = workspace.workspaces.first(where: { $0.id == id })?.name { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}
