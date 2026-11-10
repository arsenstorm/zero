import SwiftUI
import ZeroCore

// Later: things to come back to, kept by zerod (later.rs). Each is a note in plain words and the artifact behind it,
// everything an agent worked out, in full. Agents save them (`zero later save`), a task is asked to (Save for later),
// or the user writes one. An item's link is zero://later/<id>.

struct LaterPage: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    @State private var writing = false
    /// The suggestions agents saved unasked, folded away until opened.
    @AppStorage("later.suggestionsOpen") private var suggestionsOpen = false

    private var shown: String? { if case .laterItem(let id) = navigation.place { id } else { nil } }

    var body: some View {
        HStack(spacing: 0) {
            SidebarColumn(title: "Later") {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Button { writing = true } label: { NucleoIcon("compose", size: 15).frame(width: 30, height: 30) }
                        .buttonStyle(Hovering()).foregroundStyle(.secondary).tip("Write one")
                }
                .padding(.bottom, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        let suggested = workspace.later.filter { $0.suggested == true && !$0.done }
                        ForEach(workspace.later.filter { $0.suggested != true || $0.done }) { item in row(item) }
                        if !suggested.isEmpty {
                            Button { suggestionsOpen.toggle() } label: {
                                HStack(spacing: 6) {
                                    Text("Suggested by agents · \(suggested.count)")
                                    NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(suggestionsOpen ? 180 : 0))
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).padding(.top, 10)
                            .tip("Saved without you asking. Keep the ones you want; the rest go a week after they were saved.")
                            if suggestionsOpen { ForEach(suggested) { item in row(item) } }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .thinScrollbar(outset: 10, remember: "sidebar.later")
                .scrollIndicators(.never)
            }
            Rectangle().fill(Theme.stroke).frame(width: 1)
            Group {
                if let shown {
                    LaterDetail(workspace: workspace, navigation: navigation, id: shown).id(shown)
                } else {
                    ContentUnavailableView {
                        NucleoLabel(workspace.later.isEmpty ? "Nothing saved for later" : "Nothing open", icon: "bookmark", size: 20)
                    } description: {
                        Text("Ask a task to save what it has for later (right-click it in the sidebar), or an agent saves it with zero later. Each keeps a short note of what's to be done and everything behind it, in full.")
                    } actions: {
                        Button("Write one") { writing = true }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
        }
        .task { await workspace.loadLater() }
        .zeroDialog(isPresented: $writing) {
            LaterWriter { note, artifact in
                Task { if let id = await workspace.saveLater(note: note, artifact: artifact) { navigation.place = .laterItem(id) } }
            }
        }
    }

    private func resume(_ item: ZerodLink.LaterItem) {
        Task { if let session = await workspace.resumeLater(item.id) { navigation.place = .task(session) } }
    }

    private func row(_ item: ZerodLink.LaterItem) -> some View {
        Button { navigation.place = .laterItem(item.id) } label: { LaterRow(item: item) }
            .buttonStyle(Hovering(selected: shown == item.id))
            .zeroContextMenu("later-\(item.id)") {[
                [MenuItem("Copy link", "link") { copy(item.link) }]
                    + (item.resume != nil && !item.done ? [MenuItem("Resume task", "circle-play") { resume(item) }] : [])
                    + (item.suggested == true ? [MenuItem("Keep", "bookmark") { Task { await workspace.editLater(item.id, ["keep": true]) } }] : [])
                    + [MenuItem(item.done ? "Not done" : "Done", item.done ? "undo" : "check") { Task { await workspace.editLater(item.id, ["done": !item.done]) } }],
                [MenuItem(item.suggested == true ? "Dismiss" : "Delete", item.suggested == true ? "xmark" : "trash") {
                    Task { await workspace.deleteLater(item.id); if shown == item.id { navigation.place = .later } }
                }],
            ]}
    }
}

/// A row: the note, then where it came from and when, done ones faded.
private struct LaterRow: View {
    let item: ZerodLink.LaterItem
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.note).font(.system(size: 13, weight: .medium)).lineLimit(2).strikethrough(item.done, color: .secondary)
            Text([item.task, item.createdAt.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .opacity(item.done ? 0.55 : 1)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
    }
}

/// One item: the note large, what to do with it, then the artifact in full; links, files and earlier versions.
private struct LaterDetail: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    let id: String
    @State private var item: ZerodLink.LaterItem?
    @State private var version: Int?
    @State private var missing = false

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.note).font(.system(size: 22, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if let task = item.task, let from = item.from {
                                Button { navigation.place = .task(from) } label: { Text(task).fontWeight(.medium).underline(pattern: .dash) }
                                    .buttonStyle(.plain).tip("Open the task it came from")
                                Text("·")
                            }
                            Text(item.createdAt.formatted(.relative(presentation: .named)))
                            if item.done { StatePill(text: "Done", color: .green) }
                            if item.suggested == true && !item.done { StatePill(text: "Suggested", color: .secondary) }
                            if item.resume != nil && !item.done { StatePill(text: "Task", color: .secondary) }
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    actions(item)
                    if !item.links.isEmpty || !item.files.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(item.links, id: \.self) { link in
                                Link(destination: URL(string: link) ?? URL(fileURLWithPath: "/")) {
                                    Text(link).fontWeight(.medium).underline(pattern: .dash).lineLimit(1)
                                }
                            }
                            ForEach(item.files, id: \.self) { file in
                                Button { NSWorkspace.shared.open(URL(fileURLWithPath: file)) } label: {
                                    Text((file as NSString).lastPathComponent).fontWeight(.medium).underline(pattern: .dash)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .font(.system(size: 12.5)).foregroundStyle(.primary)
                    }
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                    if let artifact = item.artifact, !artifact.isEmpty {
                        MarkdownText(artifact, size: 13.5)
                    } else {
                        Text("No artifact: the note is all there is.").font(.system(size: 13)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else if missing {
                ContentUnavailableView("Nothing saved as \(id)", systemImage: "", description: Text("It may have been deleted."))
            }
        }
        .thinScrollbar(remember: "later." + id)
        .scrollIndicators(.never)
        .task(id: version) { await load() }
        // Changed elsewhere (an agent editing it): read again, at the latest version.
        .onChange(of: workspace.later.first { $0.id == id }?.updated) { version = nil; Task { await load() } }
    }

    private func load() async {
        item = await workspace.laterItem(id, version: version)
        missing = item == nil
    }

    @ViewBuilder private func actions(_ item: ZerodLink.LaterItem) -> some View {
        // A task saved whole: picked up where it was, its conversation and all, not started over from a note.
        if item.resume != nil && !item.done {
            HStack(spacing: 8) {
                Button {
                    Task { if let session = await workspace.resumeLater(item.id) { navigation.place = .task(session) } }
                } label: { NucleoLabel("Resume task", icon: "media-play:glyph", size: 13) }
                    .buttonStyle(.borderedProminent)
                Button("Copy") { copy(item.note + (item.artifact.map { "\n\n" + $0 } ?? "")) }
                Spacer()
                Button("Delete", role: .destructive) { Task { await workspace.deleteLater(item.id); navigation.place = .later } }
                    .tip("Back to the sidebar, on hold, and out of Later")
            }
            .controlSize(.regular)
        } else {
            notes(item)
        }
    }

    private func notes(_ item: ZerodLink.LaterItem) -> some View {
        HStack(spacing: 8) {
            Button {
                workspace.pendingDrafts["new"] = LaterAsk.pickUp(item)
                navigation.place = .home
            } label: { NucleoLabel("Start a task from this", icon: "paper-plane", size: 13) }
                .buttonStyle(.borderedProminent)
            Menu {
                ForEach(workspace.board.filter { $0.workspace == workspace.current }) { row in
                    Button(row.task) { Task { await workspace.send(row.session, text: LaterAsk.pickUp(item)); navigation.place = .task(row.session) } }
                }
            } label: { Text("Send to a task") }
                .fixedSize()
            Button("Copy") { copy(item.note + (item.artifact.map { "\n\n" + $0 } ?? "")) }
            if item.suggested == true {
                Button("Keep") { Task { await workspace.editLater(item.id, ["keep": true]); await load() } }
                    .tip("Keep it in Later; otherwise it goes a week after it was saved")
            }
            Button(item.done ? "Not done" : "Done") { Task { await workspace.editLater(item.id, ["done": !item.done]); await load() } }
            Spacer()
            if item.versions.count > 1 {
                Menu {
                    ForEach(item.versions.reversed(), id: \.version) { v in
                        Button("Version \(v.version) · " + Date(timeIntervalSince1970: TimeInterval(v.at)).formatted(.relative(presentation: .named))) {
                            version = v.version == item.versions.last?.version ? nil : v.version
                        }
                    }
                } label: { Text("Version \(version ?? item.version)") }
                    .fixedSize()
            }
            Button(item.suggested == true ? "Dismiss" : "Delete", role: .destructive) { Task { await workspace.deleteLater(item.id); navigation.place = .later } }
        }
        .controlSize(.regular)
    }
}

/// A pill for a state, as the board's: its word on a wash of its colour.
struct StatePill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2).background(color.opacity(0.12), in: Capsule())
    }
}

/// Writing one yourself: the note, and anything behind it.
private struct LaterWriter: View {
    let save: (String, String) -> Void
    @Environment(\.closeDialog) private var dismiss
    @State private var note = ""
    @State private var artifact = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DialogTitle(text: "Save for later")
            TextField("What's to be done, in a sentence", text: $note, axis: .vertical).textFieldStyle(.dialog).lineLimit(1...3)
            TextEditor(text: $artifact).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(minHeight: 160)
                .overlay(alignment: .topLeading) {
                    if artifact.isEmpty { Text("Anything behind it, in Markdown (optional)").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.leading, 11).padding(.top, 6).allowsHitTesting(false) }
                }
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Save", kind: .primary, enabled: !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { save(note, artifact); dismiss() }
            }
        }
        .frame(width: 480)
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
