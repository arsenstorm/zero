import AppKit
import SwiftUI
import ZeroCore

/// How far back a rewind goes: the conversation and the folder's files, or one of them.
enum RewindChoice: CaseIterable {
    case both, conversation, files

    var title: String {
        switch self {
        case .both: "Conversation and files"
        case .conversation: "Conversation only"
        case .files: "Files only"
        }
    }
    var conversation: Bool { self != .files }
    var files: Bool { self != .conversation }
}

/// Going back to a message of yours, under it in the conversation, what goes dimmed after it: how many messages go and
/// the files changed since (a list that opens), how far to go back, and the two ways to go. ↑↓ move to your message
/// before or after, Return rewinds, Esc leaves it.
struct RewindBar: View {
    let workspace: Workspace
    let task: String
    let item: ConversationItem
    /// The task at work: a rewind waits for its turn to stop.
    let working: Bool
    /// Owned by the page, which dims what goes by it.
    @Binding var choice: RewindChoice
    let move: (Int) -> Void
    let cancel: () -> Void
    let rewound: (Rewound, RewindChoice) -> Void
    let branched: (String) -> Void
    @State private var preview: RewindPreview?
    @State private var open = false
    @State private var busy = false
    @State private var monitor: Any?

    private var kept: Bool { preview?.snapshot == true }
    private var changes: [RewindPreview.Change] { kept ? preview?.changes ?? [] : [] }
    private var ready: Bool { preview != nil && !busy && !working && (kept || !choice.files) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if !changes.isEmpty && choice.files { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(summary).font(.system(size: 13)).foregroundStyle(preview == nil ? .tertiary : .primary).lineLimit(1)
                    NucleoIcon("chevron-down", size: 10).rotationEffect(.degrees(open ? 0 : -90)).foregroundStyle(.secondary)
                        .opacity(!changes.isEmpty && choice.files ? 1 : 0)
                }
                .frame(height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && choice.files && !changes.isEmpty { files }
            HStack(spacing: 8) {
                segments
                Spacer(minLength: 8)
                GhostButton(title: "Branch from here", icon: "code-branch", action: branch).disabled(busy)
                    .tip("A new task from before this message; this one stays")
                RowButton(title: "Rewind to here", enabled: ready, action: go)
                    .tip(working ? "Stop its turn first" : "", shortcut: "↩")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task(id: item.id) {
            preview = nil; open = false
            let seen = await workspace.rewindPreview(task, message: item.id)
            preview = seen
            choice = seen?.snapshot == true ? .both : .conversation
        }
        .onAppear(perform: listen)
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        }
    }

    /// What it would do, for the choice made.
    private var summary: String {
        guard let preview else { return "Looking at what changed since…" }
        var parts: [String] = []
        if choice.conversation {
            let n = preview.messages ?? 1
            parts.append("Removes \(n) message\(n == 1 ? "" : "s")")
        }
        if choice.files, kept {
            let n = preview.files ?? 0
            parts.append(n == 0 ? "No files changed since" : "\(n) file\(n == 1 ? "" : "s") changed")
        }
        return parts.joined(separator: " · ")
    }

    /// The files a rewind puts back, each with its lines added and removed since.
    private var files: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(changes, id: \.path) { change in
                    HStack(spacing: 6) {
                        Text(change.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if change.insertions > 0 { Text("+\(change.insertions)").foregroundStyle(Theme.done) }
                        if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(Theme.removed) }
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    .frame(height: 22)
                }
            }
        }
        .thinScrollbar()
        .scrollIndicators(.never)
        .frame(height: min(CGFloat(changes.count), 7) * 22)
    }

    /// The three choices, side by side; one without the folder kept is disabled, and says why on hover.
    private var segments: some View {
        DialogChoice(options: RewindChoice.allCases.map { ($0.title, $0) }, selection: $choice) { option in
            option.files && !kept ? (preview == nil ? "" : "Zero didn't keep the folder for this message") : nil
        }
        .disabled(busy)
    }

    /// While it's open, the keys are its: ↑↓ another message of yours, Return rewinds, Esc leaves it.
    private func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: cancel(); return nil
            case 126: move(-1); return nil
            case 125: move(1); return nil
            case 36, 76:
                if ready { go() }
                return nil
            default: return event
            }
        }
    }

    private func go() {
        busy = true
        Task {
            let picked = choice
            if let back = await workspace.rewind(task, message: item.id, conversation: picked.conversation, code: picked.files) {
                rewound(back, picked)
            }
            busy = false
        }
    }

    private func branch() {
        busy = true
        Task {
            let made = await workspace.branch(task, message: item.id)
            busy = false
            if let id = made?.session { branched(id) }
        }
    }
}

/// A rewind just done, and the way to take it back, above the composer for a few seconds.
struct RewoundNotice: View {
    let undo: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text("Rewound").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Button("Undo", action: undo).buttonStyle(.plain).fontWeight(.medium)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).frame(height: 28)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}
