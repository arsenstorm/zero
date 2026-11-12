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
    // The agent's words to the user stay out of the fold, each where it was: a group holds the events between them.
    #expect(rows.map(\.id) == ["u", "a0", "quiet-r1", "a1", "quiet-r2", "a2", "r3", "work-c3", "a3", "r4", "a4"], "\(rows.map(\.id))")
    if case let .quiet(_, blocks, turns) = rows[2] {
        #expect(turns == 1 && blocks.map(\.id) == ["r1"])
    } else {
        Issue.record("not folded")
    }
}

/// Only events fold, and the steps of the turns they started: what the agent said to the user stays in the
/// conversation, in order, the group split around it. Turns that ended with nothing to read fold together.
@Test func theAgentsWordsNeverFoldIntoAGroupOfEvents() {
    let report = { (id: String) in item(id, .user(text: "<!-- from: w1 -->\nWorker ENG-1 is waiting: CI still running.")) }
    let items = [
        item("u", .user(text: "drive ENG-1")),
        item("a0", .agent(text: "On it.\n\n[zero: working]", finalAnswer: true)),
        report("r1"), item("c1", .command(command: "git log", cwd: "/", output: "", exitCode: 0, durationMs: 1)),
        item("a1", .agent(text: "[zero: waiting]", finalAnswer: true)),
        report("r2"), item("a2", .agent(text: "[zero: waiting]", finalAnswer: true)),
        report("r3"), item("c3", .command(command: "ls", cwd: "/", output: "", exitCode: 0, durationMs: 1)),
        item("a3", .agent(text: "CI passed; nothing for you yet.\n\n[zero: waiting]", finalAnswer: true)),
        report("r4"), item("a4", .agent(text: "Nothing new.\n\n[zero: waiting]", finalAnswer: true)),
    ]
    let rows = TimelineRow.of(TimelineBlock.of(items, working: false))
    #expect(rows.map(\.id) == ["u", "a0", "quiet-r3", "a3", "r4", "a4"], "\(rows.map(\.id))")
    if case let .quiet(_, blocks, turns) = rows[2] {
        #expect(turns == 3, "the events up to the words, the steps of their turns with them")
        #expect(!blocks.map(\.id).contains("a3"))
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

/// Folds remembered by turn: as an answer streams, only its own turn changes, and each word ran the fold's pattern over
/// every turn on the page. Remembered or not, the rows are the same; a turn that changes is looked at again.
@Test func foldsRememberedByTurnGiveTheSameRows() {
    let report = { (id: String) in item(id, .user(text: "<!-- from: w1 -->\nWorker ENG-1 is waiting: CI still running.")) }
    var items = [
        item("u", .user(text: "drive ENG-1")),
        report("r1"), item("a1", .agent(text: "Nothing new on ENG-1.\n\n[zero: waiting]", finalAnswer: true)),
        report("r2"), item("a2", .agent(text: "Nothing new.", finalAnswer: true)),
        item("u2", .user(text: "and now?")), item("a3", .agent(text: "Still", finalAnswer: false)),
    ]
    let folds = TimelineRow.Folds()
    let rows = { TimelineRow.of(TimelineBlock.of(items, working: true), folds: folds).map(\.id) }
    #expect(rows() == TimelineRow.of(TimelineBlock.of(items, working: true)).map(\.id))
    #expect(rows() == ["u", "quiet-r1", "a1", "quiet-r2", "a2", "u2", "work-a3"], "\(rows())")
    // A folded turn that turns out to have asked the user: no longer folded.
    items[4] = item("a2", .agent(text: "Asked.\n\n[zero: asked k3x9qa]", finalAnswer: true))
    #expect(rows() == TimelineRow.of(TimelineBlock.of(items, working: true)).map(\.id))
    #expect(rows() == ["u", "quiet-r1", "a1", "r2", "a2", "u2", "work-a3"], "\(rows())")
}

/// Where reading has got to in an answer's source, found in its styled text by its words: Markdown's marks aren't in
/// the styled text, a list's bullets are only there, and a link shows only its words. Never ahead of what's read.
@Test func revealMarksFindTheReadPartInTheStyledText() {
    let source = "## Title\n\nSome **bold** words and a [link](https://x.dev/a) here.\n\n- one item\n- `two`"
    let styled = "Title\nSome bold words and a link here.\n• one item\n• two"
    let marks = RevealMarks(source: source, styled: styled)
    let at = { (prefix: String) in marks.styled(through: prefix.count) }
    #expect(at("## Title") == "Title".utf16.count)
    #expect(at("## Title\n\nSome **bold**") == "Title\nSome bold".utf16.count)
    // The link's address isn't shown: reading through it stays at what's shown before it, then catches up.
    #expect(
        at("## Title\n\nSome **bold** words and a [link](https://x.dev/a) here.") == "Title\nSome bold words and a link here.".utf16.count)
    #expect(at(source) == styled.utf16.count)
    #expect(at("") == 0)
}

/// The word map keeps its place past a run of styled words the source doesn't have (a link shown by its title), and
/// past words keyed differently (a script with combining marks); a code fence's language isn't matched into the code.
@Test func revealMarksKeepTheirPlace() {
    let source = "See [the pad](zero://pad/abc#notes) now. नमस्ते दुनिया and more words after it here."
    let styled = "See Release notes › Shipping and versions › Checklist now. नमस्ते दुनिया and more words after it here."
    let marks = RevealMarks(source: source, styled: styled)
    #expect(
        marks.styled(through: (source as String).count - 1)
            > ("See Release notes › Shipping and versions › Checklist now." as String).utf16.count)
    let fenced = "Code:\n```swift\nlet x = swift\n```\nDone."
    let shown = "Code:\nlet x = swift\nDone."
    let fence = RevealMarks(source: fenced, styled: shown)
    // Through the fence line only: nothing of the code yet.
    #expect(fence.styled(through: "Code:\n```swift".count) <= "Code:".utf16.count)
}

/// A table's columns sized to their content: short ones keep their width, long ones share the rest by their length,
/// never narrower than their longest word; all of them fill the table.
@Test func tableColumnsSizeToTheirContent() {
    // A short first column and a long second: the short one keeps its width, the long one takes the rest.
    let short = TableColumns.widths(natural: [80, 2000], least: [70, 120], total: 700)
    #expect(short == [80, 620], "\(short)")
    // All fit: the room left over goes to each by its length.
    let fits = TableColumns.widths(natural: [100, 300], least: [50, 50], total: 800)
    #expect(fits == [200, 600], "\(fits)")
    // Two long, one short: the long ones split what's left by length, the short one keeps its own.
    let mixed = TableColumns.widths(natural: [90, 1200, 600], least: [60, 100, 100], total: 690)
    #expect(mixed[0] == 90 && abs(mixed[1] - 400) < 0.5 && abs(mixed[2] - 200) < 0.5, "\(mixed)")
    // Never under its longest word.
    let words = TableColumns.widths(natural: [1000, 5000], least: [300, 100], total: 700)
    #expect(words[0] >= 300 - 0.5, "\(words)")
}
