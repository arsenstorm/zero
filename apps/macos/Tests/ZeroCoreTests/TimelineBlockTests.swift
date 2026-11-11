import Testing
@testable import ZeroCore

private func item(_ id: String, _ kind: ConversationItem.Kind) -> ConversationItem {
    ConversationItem(id: id, turn: "t", kind: kind, status: .done)
}

/// A turn that ends on an ask: what the agent wrote just before asking is the reasoning behind the question, shown in
/// full above it, not folded away with the commands. The rest of the turn's words fold as before.
@Test func theWordsJustBeforeAnAskShowInFull() {
    let items = [
        item("u", .user(text: "what's left?")),
        item("a1", .agent(text: "Checking main.", finalAnswer: false)),
        item("c1", .command(command: "zero ask \"Close it?\" --async", cwd: "/", output: "k3x9qa", exitCode: 0, durationMs: 1)),
        item("a2", .agent(text: "Here's how I'd decide: each item has to earn its place.", finalAnswer: false)),
        item("a3", .agent(text: "I've asked in Zero.\n\n[zero: asked k3x9qa]", finalAnswer: true)),
    ]
    let ids = TimelineBlock.of(items, working: false).map(\.id)
    #expect(ids == ["u", "work-a1", "a2", "a3"], "\(ids)")
    // Ending otherwise, the words before the last stay in the work.
    var done = items
    done[4] = item("a3", .agent(text: "Done.\n\n[zero: done]", finalAnswer: true))
    #expect(TimelineBlock.of(done, working: false).map(\.id) == ["u", "work-a1", "a3"])
}

/// Words with steps after them stay where they were as the turn ends on an ask: above those steps, not moved below.
@Test func wordsBeforeStepsStayAboveThemWhenTheTurnEndsOnAnAsk() {
    let items = [
        item("u", .user(text: "what's left?")),
        item("a1", .agent(text: "Second note", finalAnswer: false)),
        item("c1", .command(command: "git log", cwd: "/", output: "", exitCode: 0, durationMs: 1)),
        item("c2", .command(command: "zero ask \"Close it?\" --async", cwd: "/", output: "k3x9qa", exitCode: 0, durationMs: 1)),
        item("a2", .agent(text: "I've asked in Zero.\n\n[zero: asked k3x9qa]", finalAnswer: true)),
    ]
    let blocks = TimelineBlock.of(items, working: false)
    #expect(blocks.map(\.id) == ["u", "work-a1", "a2"], "\(blocks.map(\.id))")
    if case let .work(_, work, _, _, _) = blocks[1] { #expect(work.map(\.id) == ["a1", "c1", "c2"]) }
}

/// Turns a worker's report or an event started, that asked the user nothing and set no issue row, fold into one row,
/// consecutive ones together: what changed for the user stands out. The last turn, being read, never folds.
@Test func turnsZeroStartedThatChangedNothingFoldTogether() {
    let report = { (id: String) in item(id, .user(text: "<!-- from: w1 -->\nWorker ENG-1 is waiting: CI still running.")) }
    let items = [
        item("u", .user(text: "drive ENG-1")),
        item("a0", .agent(text: "On it.\n\n[zero: working]", finalAnswer: true)),
        report("r1"), item("a1", .agent(text: "Nothing new on ENG-1.\n\n[zero: waiting]", finalAnswer: true)),
        report("r2"), item("a2", .agent(text: "Nothing new on ENG-1.\n\n[zero: waiting]", finalAnswer: true)),
        report("r3"), item("c3", .command(command: "zero issue ENG-1 you \"Merge it\"", cwd: "/", output: "", exitCode: 0, durationMs: 1)),
        item("a3", .agent(text: "ENG-1 is ready for you.\n\n[zero: done]", finalAnswer: true)),
        report("r4"), item("a4", .agent(text: "Nothing new.\n\n[zero: waiting]", finalAnswer: true)),
    ]
    let rows = TimelineRow.of(TimelineBlock.of(items, working: false))
    #expect(rows.map(\.id) == ["u", "a0", "quiet-r2", "r3", "work-c3", "a3", "r4", "a4"], "\(rows.map(\.id))")
    if case let .quiet(_, blocks, turns) = rows[2] {
        #expect(turns == 2 && blocks.map(\.id) == ["r1", "a1", "r2", "a2"])
    } else {
        Issue.record("not folded")
    }
}

/// A turn started by the user's own answer to an ask (Zero passes it on, so it reads as Zero's) is the user's: it
/// stays out, not folded as an update that needed nothing from them.
@Test func aTurnTheUsersAnswerStartedDoesNotFold() {
    let items = [
        item("u", .user(text: "go")),
        item("a0", .agent(text: "Asked.\n\n[zero: asked k3x9qa]", finalAnswer: true)),
        item("r1", .user(text: "<!-- from: zero -->\nThe user answered your ask k3x9qa (\"Ship it?\"): Clears")),
        item("a1", .agent(text: "Committed.\n\n[zero: done]", finalAnswer: true)),
        item("u2", .user(text: "next thing")),
        item("a2", .agent(text: "On it.\n\n[zero: done]", finalAnswer: true)),
    ]
    let rows = TimelineRow.of(TimelineBlock.of(items, working: false))
    #expect(!rows.contains { if case .quiet = $0 { true } else { false } }, "\(rows.map(\.id))")
}

/// A command with no words for what it does reads as its line that says something, not a heredoc's interpreter.
@Test func aCommandReadsAsItsLineThatSaysSomething() {
    #expect(CommandText.line("python3 - <<'EOF'\nfrom PIL import Image\nEOF") == "python3 - · from PIL import Image")
    #expect(CommandText.line("cd /work/zero && cat <<EOF > a.txt\nhello\nEOF") == "cat > a.txt · hello")
    #expect(CommandText.line("git status\n") == "git status")
    #expect(CommandText.line("") == "")
}

/// A run of steps between two notes, folded, says what they were.
@Test func aFoldedRunOfStepsSaysWhatTheyWere() {
    let steps = [
        item("r", .reasoning(text: "Looking")),
        item("c1", .command(command: "ls", cwd: "/", output: "", exitCode: 0, durationMs: 1)),
        item("c2", .command(command: "make", cwd: "/", output: "", exitCode: 0, durationMs: 1)),
        item("f", .fileChange([FileChange(path: "/a", kind: "update", movePath: nil, diff: "")])),
    ]
    #expect(StepSummary.text(steps) == "Thought, ran 2 commands, edited a file")
    #expect(StepSummary.text([item("t", .tool(name: "Read", detail: "a.rs"))]) == "Used a tool")
}
