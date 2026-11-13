import AppKit
import SwiftUI
import ZeroCore

/// A task's Copy menu: what of it goes on the clipboard, each with its icon and, where one fits, its keys, which do the
/// same for the task that's open (TaskCopyKeys). A copy says so for a moment in the window's corner (CopiedToast).
@MainActor enum TaskCopyMenu {
    struct Copy {
        let title: String
        let glyph: String
        var key: Character? = nil
        var modifiers: EventModifiers = .command
        let text: @MainActor () async -> String?

        /// As macOS writes them: ⌥⇧⌘ then the key.
        var keys: String? {
            key.map { (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + "⌘" + String($0).uppercased() }
        }

        func run() {
            Task { @MainActor in
                guard let text = await text(), !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                CopiedToast.shown = UUID()
            }
        }
    }

    /// ⌘. stops a turn and ⌘C copies selected words, so neither is taken here.
    static func copies(_ id: String, in workspace: Workspace) -> [Copy] {
        let conversation = workspace.conversation(id)
        let row = workspace.board.first { $0.session == id }
        let title = row?.task ?? conversation.map(Workspace.label(of:)) ?? id
        let ticket = row?.ticket ?? conversation?.ticket
        let items = { workspace.live(id)?.conversation.items ?? [] }
        var all = [
            Copy(title: "Copy ID", glyph: "hashtag", key: ".", modifiers: [.command, .option]) { id },
            Copy(title: "Copy link", glyph: "link", key: ",", modifiers: [.command, .shift]) { TaskLinks.link(id) },
            Copy(title: "Copy title", glyph: "text", key: "'", modifiers: [.command, .shift]) { title },
            Copy(title: "Copy title as link", glyph: "file-link") { TaskCopy.titleLink(title, task: id) },
            Copy(title: "Copy last answer", glyph: "quote", key: "c", modifiers: [.command, .shift]) { TaskCopy.lastAnswer(items()) },
            Copy(title: "Copy conversation as Markdown", glyph: "file-content", key: "c", modifiers: [.command, .option]) {
                TaskCopy.markdown(title: title, items: items())
            },
        ]
        if let ticket, !ticket.isEmpty { all.append(Copy(title: "Copy ticket", glyph: "ticket") { ticket }) }
        // Its branch now, not the one it started on: agents make their own as they go. Offered where it began in a repo.
        if let conversation, conversation.branch != nil {
            all.append(
                Copy(title: "Copy branch name", glyph: "code-branch", key: ".", modifiers: [.command, .shift]) {
                    await branch(in: conversation.cwd)
                })
        }
        if let conversation {
            all.append(
                Copy(title: "Copy as prompt", glyph: "wand-sparkle", key: "p", modifiers: [.command, .option]) {
                    await workspace.loadFollowing()
                    var brief = TaskCopy.Brief(title: title, folder: conversation.cwd)
                    brief.ticket = ticket
                    brief.branch = await branch(in: conversation.cwd)
                    brief.now = row?.now
                    brief.answer = TaskCopy.lastAnswer(items())
                    brief.follows = workspace.followed.filter { $0.session == id }.map { "\($0.summary) (\($0.topic))" }
                    brief.pending =
                        (row?.asks.map { "Ask: \($0.title)" } ?? []) + [row?.needs.map { "Needs: \($0)" }].compactMap { $0 }
                        + (row?.issues ?? []).filter { $0.state != "done" }.map { "\($0.ticket) (\($0.state)): \($0.text)" }
                        + (row?.queued ?? []).map { "Queued message: \($0.text)" }
                    return TaskCopy.prompt(brief)
                })
        }
        return all
    }

    static func item(_ id: String, in workspace: Workspace) -> MenuItem {
        MenuItem(
            "Copy", "copy",
            children: copies(id, in: workspace).map { copy in
                var item = MenuItem(copy.title, copy.glyph) { copy.run() }
                item.shortcut = copy.keys
                return item
            })
    }

    /// The branch checked out in a folder; nil outside a repository or on no branch.
    private static func branch(in folder: String) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder, "branch", "--show-current"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && !name.isEmpty ? name : nil
        }.value
    }
}

/// The Copy menu's keys, for the task that's open: unseen buttons, as the sidebar's ⌘1 to ⌘9.
struct TaskCopyKeys: View {
    let id: String
    let workspace: Workspace
    var body: some View {
        ForEach(Array(TaskCopyMenu.copies(id, in: workspace).enumerated()), id: \.offset) { _, copy in
            if let key = copy.key {
                Button("") { copy.run() }.keyboardShortcut(KeyEquivalent(key), modifiers: copy.modifiers)
            }
        }
        .hidden()
    }
}

/// "Copied", for a moment, on a menu's card: what the message row's copy says with its tick.
struct CopiedToast: View {
    @MainActor static var shown: UUID? {
        get { Shown.shared.shown }
        set { Shown.shared.shown = newValue }
    }
    @MainActor @Observable final class Shown { static let shared = Shown(); var shown: UUID? }

    let id: UUID
    var body: some View {
        HStack(spacing: 8) {
            NucleoIcon("check", size: 14).foregroundStyle(Theme.menuIcon)
            Text("Copied").font(.system(size: 13)).foregroundStyle(Theme.menuText)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .modifier(MenuCard(radius: 12, linear: true))
        .task(id: id) {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled, Self.shown == id { Self.shown = nil }
        }
    }
}
