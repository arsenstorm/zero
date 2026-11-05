import Testing
@testable import ZeroCore

private func item(_ id: String, _ kind: ConversationItem.Kind) -> ConversationItem { ConversationItem(id: id, turn: "t", kind: kind, status: .done) }

/// A turn that ends on an ask: what the agent wrote before asking is the reasoning behind the question, shown in full
/// above it, not folded away with the commands. The rest of the turn's words fold as before.
@Test func theWordsBeforeAnAskShowInFull() {
    let items = [
        item("u", .user(text: "what's left?")),
        item("a1", .agent(text: "Checking main.", finalAnswer: false)),
        item("c1", .command(command: "git log", cwd: "/", output: "", exitCode: 0, durationMs: 1)),
        item("a2", .agent(text: "Here's how I'd decide: each item has to earn its place.", finalAnswer: false)),
        item("c2", .command(command: "zero ask \"Close it?\" --async", cwd: "/", output: "k3x9qa", exitCode: 0, durationMs: 1)),
        item("a3", .agent(text: "I've asked in Zero.\n\n[zero: asked k3x9qa]", finalAnswer: true)),
    ]
    let ids = TimelineBlock.of(items, working: false).map(\.id)
    #expect(ids == ["u", "work-a1", "a2", "a3"], "\(ids)")
    // Ending otherwise, the words before the last stay in the work.
    var done = items
    done[5] = item("a3", .agent(text: "Done.\n\n[zero: done]", finalAnswer: true))
    #expect(TimelineBlock.of(done, working: false).map(\.id) == ["u", "work-a1", "a3"])
}
