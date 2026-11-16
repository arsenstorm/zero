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
/// the files that go back (a list that opens), how far to go back on a chip, Branch, Cancel and Rewind. ↑↓ move to your
/// message before or after, Return rewinds, Esc leaves it; while the chip's menu is open, those keys are the menu's.
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

    private var ready: Bool { RewindCard.ready(preview, choice: choice, busy: busy, working: working) }

    var body: some View {
        RewindCard(
            preview: preview, choice: $choice, open: $open, busy: busy, working: working,
            folder: workspace.conversation(task)?.cwd, branch: branch, cancel: cancel, rewind: go
        )
        .task(id: item.id) {
            preview = nil; open = false
            let seen = await workspace.rewindPreview(task, message: item.id)
            preview = seen
            choice = seen?.snapshot == true ? .both : .conversation
        }
        .onAppear(perform: listen)
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if WorkspaceSelector.shared.open == RewindCard.chip { WorkspaceSelector.shared.close() }
        }
    }

    /// While it's open, the keys are its: ↑↓ another message of yours, Return rewinds, Esc leaves it.
    private func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The chip's menu open: ↑↓, Return and Esc move through it, pick and close it.
            if WorkspaceSelector.shared.open == RewindCard.chip { return event }
            // Its page's window only: a panel's keys (the control bar's, a selector's) aren't for it.
            if event.window is NSPanel { return event }
            switch event.keyCode {
            case 53: cancel(); return nil
            case 126: move(-1); return nil
            case 125: move(1); return nil
            case 36, 76:
                // Return in a box with words in it sends them: only an empty one's Return rewinds.
                if let field = event.window?.firstResponder as? NSTextView, field.isEditable, !field.string.isEmpty { return event }
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
            let shown = preview?.messages
            if let back = await workspace.rewind(
                task, message: item.id, conversation: picked.conversation, code: picked.files, messages: shown)
            {
                rewound(back, picked)
            } else {
                // Refused (the conversation went on, say): what it would remove now, for the next try.
                preview = await workspace.rewindPreview(task, message: item.id)
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

/// The bar itself, from what the preview found: what goes, the files (a table to the card's edges, opened from the
/// summary), the choice on a chip, and the ways out.
struct RewindCard: View {
    static let chip = "rewind"
    let preview: RewindPreview?
    @Binding var choice: RewindChoice
    @Binding var open: Bool
    let busy: Bool
    let working: Bool
    /// The task's folder, which the files' paths are in: a file clicked is shown in Finder.
    let folder: String?
    let branch: () -> Void
    let cancel: () -> Void
    let rewind: () -> Void

    static func ready(_ preview: RewindPreview?, choice: RewindChoice, busy: Bool, working: Bool) -> Bool {
        preview != nil && !busy && !working && (preview?.snapshot == true || !choice.files)
    }
    private var kept: Bool { preview?.snapshot == true }
    private var changes: [RewindPreview.Change] { kept ? preview?.changes ?? [] : [] }
    private var listed: Bool { open && choice.files && !changes.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .font(.system(size: 13)).lineLimit(1).frame(height: 24)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if listed { files }
            HStack(spacing: 8) {
                SettingChoice(id: Self.chip, choices: [choices.map { ($0.title, $0) }], selection: $choice)
                    .disabled(busy || choices.count < 2).padding(.leading, -8)
                Spacer(minLength: 8)
                GhostButton(title: "Branch from here", icon: "code-branch", action: branch).disabled(busy)
                    .tip("A new task from before this message; this one stays")
                DialogButton(title: "Cancel", action: cancel)
                RewindButton(enabled: Self.ready(preview, choice: choice, busy: busy, working: working), action: rewind)
                    .tip(working ? "Stop its turn first" : "", shortcut: "↩")
            }
            .padding(.horizontal, 14).padding(.top, listed ? 10 : 0).padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The choices there are: without the folder kept, only the conversation.
    private var choices: [RewindChoice] { kept || preview == nil ? RewindChoice.allCases : [.conversation] }

    /// What it would do, for the choice made: the messages that go, then the files.
    @ViewBuilder private var summary: some View {
        if let preview {
            HStack(spacing: 4) {
                if choice.conversation {
                    let n = preview.messages ?? 1
                    Text("\(n) message\(n == 1 ? "" : "s") go")
                } else {
                    Text("The conversation stays")
                }
                Text("·").foregroundStyle(.tertiary)
                if !kept {
                    Text("Zero didn't keep the files for this message").foregroundStyle(.secondary)
                } else if !choice.files {
                    Text("Files stay").foregroundStyle(.secondary)
                } else if changes.isEmpty {
                    Text("No files changed since").foregroundStyle(.secondary)
                } else {
                    disclosure(preview.files ?? changes.count)
                }
            }
        } else {
            Text("Looking at what changed").foregroundStyle(.tertiary)
        }
    }

    /// "3 files go back ⌄": opens the table; a soft fill under the pointer and while it's open.
    private func disclosure(_ n: Int) -> some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("\(n) file\(n == 1 ? "" : "s") go back")
                NucleoIcon("chevron-down", size: 10).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
            }
            .fontWeight(.medium)
            .padding(.horizontal, 7).frame(height: 24).contentShape(Capsule())
        }
        .buttonStyle(Hovering(selected: open, radius: 12, fill: Theme.hover))
        .padding(.horizontal, -7)
    }

    /// The files a rewind puts back, each with its lines added and removed since: rows and their hover fills to the
    /// card's edges (square: they never meet its corners), a line edge to edge above and below. Seven show, the rest
    /// scroll.
    private var files: some View {
        VStack(spacing: 0) {
            Hairline()
            ScrollView {
                VStack(spacing: 0) { ForEach(changes, id: \.path, content: fileRow) }
            }
            .thinScrollbar()
            .scrollIndicators(.never)
            .frame(height: min(CGFloat(changes.count), 7) * 26)
            Hairline()
        }
    }

    private func fileRow(_ change: RewindPreview.Change) -> some View {
        Button {
            if let folder { OpenTarget.open(path: URL(fileURLWithPath: folder).appendingPathComponent(change.path).path) }
        } label: {
            HStack(spacing: 6) {
                Text(change.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if change.insertions > 0 { Text("+\(change.insertions)").foregroundStyle(Theme.done) }
                if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(Theme.removed) }
            }
            .font(.system(size: 12)).monospacedDigit()
            .padding(.horizontal, 14).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(Hovering(radius: 0, fill: .clear))
        .tip("Show in Finder")
    }
}

/// The bar's Rewind: filled, as a dialog's primary is, without its Return shortcut, which is the bar's key monitor's
/// (and a message box's, when it has words in it).
private struct RewindButton: View {
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("Rewind").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.onKnob)
                .padding(.horizontal, 14).frame(height: 30)
                .background(Theme.knob, in: Capsule())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(PressableStyle()).disabled(!enabled)
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
