import Foundation
import Testing

@testable import ZeroCore

private func item(_ id: String, _ kind: ConversationItem.Kind) -> ConversationItem {
    ConversationItem(id: id, turn: "t", kind: kind, status: .done)
}

@Test func aTitleLinkEscapesItsBrackets() {
    #expect(TaskCopy.titleLink("Fix [U-1] menu", task: "01a") == "[Fix \\[U-1\\] menu](zero://task/01a)")
}

/// The latest final answer, its Zero ending left out; none before the agent answered.
@Test func theLastAnswerIsTheLatestFinalOneWithoutItsEnding() {
    let items = [
        item("1", .agent(text: "First", finalAnswer: true)),
        item("2", .agent(text: "Thinking aloud", finalAnswer: false)),
        item("3", .agent(text: "Done it.\n\n[zero: done]", finalAnswer: true)),
        item("4", .agent(text: "mid-turn", finalAnswer: false)),
    ]
    #expect(TaskCopy.lastAnswer(items) == "Done it.")
    #expect(TaskCopy.lastAnswer([item("1", .user(text: "hi"))]) == nil)
}

/// Messages and answers under headings, notices quoted, the steps between folded to a line each, reasoning left out.
@Test func aConversationAsMarkdownFoldsItsSteps() {
    let items = [
        item("1", .user(text: "Fix the menu")),
        item("2", .reasoning(text: "hmm")),
        item("3", .command(command: "swift build\n--verbose", cwd: "/r", output: "ok", exitCode: 0, durationMs: 1)),
        item("4", .command(command: "ls", cwd: "/r", output: "", exitCode: 0, durationMs: 1, description: "List files")),
        item("5", .fileChange([FileChange(path: "/r/a/Menu.swift", kind: "update", movePath: nil, diff: "")])),
        item("6", .tool(name: "zero_note", detail: "built\nmore")),
        item("7", .agent(text: "Fixed.\n[zero: done]", finalAnswer: true)),
        item("8", .notice(text: "Paused", error: false)),
        item("9", .user(text: "<!-- from: zero -->\nA PR merged")),
    ]
    #expect(
        TaskCopy.markdown(title: "Menu", items: items) == """
            # Menu

            ### You

            Fix the menu

            - `swift build`
            - List files
            - Edited Menu.swift
            - zero_note: built

            ### Agent

            Fixed.

            > Paused

            ### From Zero

            A PR merged
            """)
}

/// What's known goes in, what isn't leaves no empty heading.
@Test func aPromptCarriesWhatIsKnownAndNothingEmpty() {
    var brief = TaskCopy.Brief(title: "Copy menu", folder: "/r/zero")
    brief.ticket = "U-12"
    brief.branch = "main"
    brief.now = "Builders written"
    brief.pending = ["Ask: Ship it?"]
    brief.follows = ["PR #3 open (github/o/r/pull/3)"]
    brief.answer = "Done."
    let prompt = TaskCopy.prompt(brief)
    #expect(prompt.contains("# Copy menu\n\n- Ticket: U-12\n- Folder: /r/zero\n- Branch: main"))
    #expect(prompt.contains("## Where it stands\n\nBuilders written"))
    #expect(prompt.contains("## Pending\n\n- Ask: Ship it?"))
    #expect(prompt.contains("## Followed\n\n- PR #3 open (github/o/r/pull/3)"))
    #expect(prompt.hasSuffix("## The last answer\n\nDone."))

    let bare = TaskCopy.prompt(TaskCopy.Brief(title: "T", folder: "/f"))
    #expect(bare.hasSuffix("# T\n\n- Folder: /f"))
}
