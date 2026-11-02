import Foundation
import Testing
@testable import ZeroCore

private func row(_ id: String, _ task: String) -> BoardRow {
    let json = #"{"session":"\#(id)","task":"\#(task)","workspace":"zero","place":"p","online":true,"state":"idle","own":"idle","asks":[],"workers":0,"team":[]}"#
    return try! JSONDecoder().decode(BoardRow.self, from: Data(json.utf8))
}

@Test func sidebarOrdersAsTheMacDoes() {
    let rows = [row("a", "Zeta"), row("b", "alpha"), row("c", "Beta 10"), row("d", "Beta 9")]
    #expect(BoardRow.sorted(rows, by: .state, order: "").map(\.session) == ["a", "b", "c", "d"])
    #expect(BoardRow.sorted(rows, by: .name, order: "").map(\.session) == ["b", "d", "c", "a"])
    // Dragged: in the order kept; one never dragged goes on top.
    #expect(BoardRow.sorted(rows, by: .manual, order: "c\na\nb").map(\.session) == ["d", "c", "a", "b"])
}

@Test func howLongSomethingTookNeverSaysZero() {
    #expect(Took.text("Thought", 0.4) == "Thought for a moment")
    #expect(Took.text("Thought", 8) == "Thought for 8s")
    #expect(Took.text("Worked", 157) == "Worked for 2m 37s")
    #expect(Took.text("Thought", nil) == "Thought")
}

@Test func aZeroAskStepIsFoundByTheIdItPrinted() {
    var ask = Ask(kind: .choice, title: "Ship it?", options: ["Yes", "No"], agent: AgentIdentity(name: "zerod-s1", host: "mac"))
    ask.id = "k3x9qa"
    let step = ConversationItem(id: "c1", turn: "t", kind: .command(command: "zero ask \"Ship it?\" --option Yes --option No", cwd: "/", output: "ask k3x9qa waiting", exitCode: nil, durationMs: nil), status: .running)
    #expect(step.ask(in: [ask], session: "s1")?.id == "k3x9qa")
    let other = ConversationItem(id: "c2", turn: "t", kind: .command(command: "ls", cwd: "/", output: "ask k3x9qa", exitCode: 0, durationMs: 1), status: .done)
    #expect(other.ask(in: [ask], session: "s1") == nil, "not a zero ask: no card")
    #expect(step.ask(in: [ask], session: "s2") == nil, "another session's")
}
