import SwiftUI
import ZeroCore

// Loops: named instructions an agent follows, kept by zerod (loops.rs) and named as @name in a message or a brief.
// The page lists them, edits one (its description and words), shows the loops it names and the sessions that ran it.

/// The loops' names, for messages' renderer: "@name" in a message is a pill that opens the loop.
@MainActor enum LoopNames {
    static var known: [String] = []
}

struct LoopsPage: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    @State private var naming = false

    private var shown: String? { if case .loop(let name) = navigation.place { name } else { nil } }

    var body: some View {
        HStack(spacing: 0) {
            SidebarColumn(title: "Loops") {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Button { naming = true } label: { NucleoIcon("compose", size: 15).frame(width: 30, height: 30) }
                        .buttonStyle(Hovering()).foregroundStyle(.secondary).help("New loop")
                }
                .padding(.bottom, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(workspace.loops) { loop in
                            Button { navigation.place = .loop(loop.name) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("@" + loop.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    if !loop.description.isEmpty { Text(loop.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: loop.description.isEmpty ? 30 : 42)
                            }
                            .buttonStyle(Hovering(selected: shown == loop.name))
                            .contextMenu {
                                Button("Copy name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("@" + loop.name, forType: .string) }
                                Divider()
                                Button("Delete") { Task { await workspace.deleteLoop(loop.name); if shown == loop.name { navigation.place = .loops } } }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .thinScrollbar(outset: 10, remember: "sidebar.loops")
                .scrollIndicators(.never)
            }
            Rectangle().fill(Theme.stroke).frame(width: 1)
            Group {
                if let shown {
                    LoopEditor(workspace: workspace, navigation: navigation, name: shown).id(shown)
                } else {
                    ContentUnavailableView {
                        NucleoLabel("No loop open", icon: "animation-repeat", size: 20)
                    } description: {
                        Text("A loop is an instruction an agent follows. Name one as @name in a message, and the agent gets its words. A loop can name the loops its workers follow.")
                    } actions: {
                        Button("New loop") { naming = true }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card)
        }
        .task(id: workspace.loopsVersion) { await workspace.loadLoops() }
        .sheet(isPresented: $naming) {
            NameSheet(title: "New loop", name: "", action: "Create") { name in
                let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
                Task {
                    if let error = await workspace.saveLoop(slug, description: "", body: "") { NSSound.beep(); print(error) }
                    else { navigation.place = .loop(slug) }
                }
            }
        }
    }
}

/// One loop: its description and words, saved a moment after typing; the loops it names; the sessions that ran it.
private struct LoopEditor: View {
    let workspace: Workspace
    @Bindable var navigation: Navigation
    let name: String
    @State private var loop: ZerodLink.Loop?
    @State private var description = ""
    @State private var text = ""
    @State private var saved = (description: "", text: "")
    @State private var problem: String?
    @State private var save: Task<Void, Never>?
    @State private var scrollTo: String?
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loop {
                header(loop)
                if let problem { banner(problem) }
                MarkdownEditor(text: $text, scrollTo: $scrollTo, sectionLink: { _ in nil }, padLink: ("zero://loop/" + name, "@" + name), sections: [])
                    .onChange(of: text) { _, now in if now != saved.text { scheduleSave() } }
                    .onChange(of: description) { _, now in if now != saved.description { scheduleSave() } }
                footer(loop)
            } else if missing {
                ContentUnavailableView("No such loop", systemImage: "", description: Text("It may have been deleted."))
            }
        }
        .centredColumn(760)
        .task { await load() }
        .task(id: workspace.loopsVersion) { await refresh() }
        .onDisappear { flush() }
    }

    private func header(_ loop: ZerodLink.Loop) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text("@" + loop.name).font(.system(size: 26, weight: .semibold))
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("@" + loop.name, forType: .string) } label: {
                    NucleoLabel("Copy name", icon: "copy", size: 14).font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.plain).help("Copy @\(loop.name) to name it in a message")
            }
            TextField("What this loop is for, in a line", text: $description).textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.top, 28).padding(.bottom, 12)
    }

    /// The loops it names, and the sessions that ran it, latest first.
    private func footer(_ loop: ZerodLink.Loop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !loop.children.isEmpty {
                HStack(spacing: 6) {
                    Text("Names").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    ForEach(loop.children, id: \.self) { child in
                        Button("@" + child) { navigation.place = .loop(child) }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(TokenTextView.tokenText.asColor)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(TokenTextView.tokenFill.asColor, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            if loop.uses.isEmpty {
                Text("No session has run it yet.").font(.system(size: 12.5)).foregroundStyle(.tertiary)
            } else {
                Text("Ran by").font(.system(size: 12.5)).foregroundStyle(.secondary)
                ForEach(Array(loop.uses.reversed().prefix(12).enumerated()), id: \.offset) { _, use in
                    HStack(spacing: 8) {
                        Button(title(of: use.session)) { navigation.place = .task(use.session) }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                        Text(use.role).font(.system(size: 12)).foregroundStyle(.secondary)
                        if let state = state(of: use.session) { StateLabel(state: state) }
                        Spacer(minLength: 0)
                        Text(Date(timeIntervalSince1970: TimeInterval(use.at) / 1000).formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private func title(of session: String) -> String {
        if let row = workspace.board.first(where: { $0.session == session }) { return row.task }
        if let conversation = workspace.conversations.first(where: { $0.id == session }) { return Workspace.label(of: conversation) }
        return session
    }

    private func state(of session: String) -> BoardRow.State? {
        if let row = workspace.board.first(where: { $0.session == session }) { return row.state }
        return workspace.board.lazy.compactMap { $0.member(session) }.first?.state
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 10) {
            NucleoIcon("triangle-warning", size: 14).foregroundStyle(.orange)
            Text(message).font(.system(size: 12.5))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 8)
    }

    private func load() async {
        guard let fresh = await workspace.readLoop(name) else { missing = true; return }
        loop = fresh
        description = fresh.description
        text = fresh.body
        saved = (fresh.description, fresh.body)
    }

    /// Someone else's change (an agent's run recorded, an edit elsewhere), taken when nothing here is unsaved.
    private func refresh() async {
        guard let fresh = await workspace.readLoop(name) else { return }
        if text == saved.text && description == saved.description && save == nil {
            loop = fresh
            description = fresh.description
            text = fresh.body
            saved = (fresh.description, fresh.body)
        } else { loop = fresh } // what's typed here stays; the children and uses shown are the latest
    }

    private func scheduleSave() {
        save?.cancel()
        save = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await write()
            save = nil
        }
    }

    private func flush() {
        save?.cancel()
        save = nil
        if text != saved.text || description != saved.description { Task { await write() } }
    }

    private func write() async {
        let (description, text) = (description, text)
        if let error = await workspace.saveLoop(name, description: description, body: text) { problem = error; return }
        problem = nil
        saved = (description, text)
        if let fresh = await workspace.readLoop(name) { loop = fresh }
    }
}

private extension NSColor {
    var asColor: Color { Color(nsColor: self) }
}
