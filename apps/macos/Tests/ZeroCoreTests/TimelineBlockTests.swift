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

/// An ask the agent made stays with its turn, under the turn's last words, answered or not: it never leaves the page
/// (and moves everything under it) when the user answers it. A turn under way shows its asks in its steps instead.
@Test func anAskStaysUnderTheTurnThatMadeIt() {
    var ask = Ask(kind: .choice, title: "Close it?", options: ["Yes", "No"], agent: AgentIdentity(name: "zerod-s1", host: "mac"))
    ask.id = "k3x9qa"
    let items = [
        item("u", .user(text: "what's left?")),
        item("c1", .command(command: "git log", cwd: "/", output: "", exitCode: 0, durationMs: 1)),
        item("c2", .command(command: "zero ask \"Close it?\" --async", cwd: "/", output: "ask k3x9qa waiting", exitCode: 0, durationMs: 1)),
        item("a3", .agent(text: "I've asked in Zero.\n\n[zero: asked k3x9qa]", finalAnswer: true)),
        item("u2", .user(text: "and now?")),
        item("a4", .agent(text: "All done.\n\n[zero: done]", finalAnswer: true)),
    ]
    let after = TimelineBlock.asks(after: TimelineBlock.of(items, working: false), in: [ask], session: "s1")
    #expect(after.mapValues { $0.map(\.id) } == ["a3": ["k3x9qa"]], "\(after)")
    ask.state = .answered
    #expect(TimelineBlock.asks(after: TimelineBlock.of(items, working: false), in: [ask], session: "s1")["a3"]?.first?.id == "k3x9qa", "answered, still there")
    #expect(TimelineBlock.asks(after: TimelineBlock.of(Array(items.prefix(3)), working: true), in: [ask], session: "s1").isEmpty, "live: in its step")
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
    if case let .quiet(_, blocks, turns) = rows[2] { #expect(turns == 2 && blocks.map(\.id) == ["r1", "a1", "r2", "a2"]) } else { Issue.record("not folded") }
}

/// Two turns whose steps both name the same ask (a retry, a second `zero ask` with its words) place it once, under the
/// first: the same ask twice in one column is the same view twice, which SwiftUI's stack can't lay out.
@Test func anAskTwoTurnsNameIsPlacedOnce() {
    var ask = Ask(kind: .choice, title: "Close it?", options: ["Yes", "No"], agent: AgentIdentity(name: "zerod-s1", host: "mac"))
    ask.id = "k3x9qa"
    let asking = { (id: String) in item(id, .command(command: "zero ask \"Close it?\" --async", cwd: "/", output: "ask k3x9qa waiting", exitCode: 0, durationMs: 1)) }
    let items = [
        item("u", .user(text: "go")), asking("c1"), item("a1", .agent(text: "Asked.\n\n[zero: asked k3x9qa]", finalAnswer: true)),
        item("u2", .user(text: "again")), asking("c2"), item("a2", .agent(text: "Asked again.\n\n[zero: asked k3x9qa]", finalAnswer: true)),
    ]
    let after = TimelineBlock.asks(after: TimelineBlock.of(items, working: false), in: [ask], session: "s1")
    #expect(after.values.flatMap { $0 }.count == 1 && after["a1"]?.first?.id == "k3x9qa", "\(after)")
}
