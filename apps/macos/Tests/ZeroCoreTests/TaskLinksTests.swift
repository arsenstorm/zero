import Foundation
import Testing

@testable import ZeroCore

private func item(_ id: String, _ kind: ConversationItem.Kind) -> ConversationItem {
    ConversationItem(id: id, turn: "t", kind: kind, status: .done)
}

/// A link into a conversation: zero://task/<id>#<anchor> from anywhere, "#anchor" within the task's own words.
@Test func aTaskLinkNamesItsTaskAndAnchor() {
    let parsed = TaskLinks.parse(URL(string: "zero://task/01a1cb#bench-plan")!)
    #expect(parsed?.task == "01a1cb" && parsed?.anchor == "bench-plan")
    #expect(TaskLinks.parse(URL(string: "zero://task/01a1cb")!)?.anchor == nil)
    let relative = TaskLinks.parse(URL(string: "#bench-plan")!, current: "01a1cb")
    #expect(relative?.task == "01a1cb" && relative?.anchor == "bench-plan")
    #expect(TaskLinks.parse(URL(string: "#bench-plan")!) == nil, "no task to be within")
    #expect(TaskLinks.parse(URL(string: "zero://pad/8f3k2a#plan")!) == nil)
    #expect(TaskLinks.parse(URL(string: "https://example.com/#plan")!, current: "01a1cb") == nil)
    #expect(TaskLinks.link("01a1cb", "risks") == "zero://task/01a1cb#risks")
}

/// Shown away from its conversation (an ask's card), "#anchor" is the asking task's.
@Test func anAsksAnchorLinksAreItsTasks() {
    let body = "See [the plan](#bench-plan) and [the docs](https://example.com/#x)."
    #expect(
        TaskLinks.absolute(body, task: "01a1cb")
            == "See [the plan](zero://task/01a1cb#bench-plan) and [the docs](https://example.com/#x).")
}

/// The words an ask is about are often folded in their turn's work: the page goes to that row.
@Test func anItemIsFoundInTheRowShowingIt() {
    let items = [
        item("u", .user(text: "pick a bench")),
        item("a1", .agent(text: "## Bench plan\n\nBench 3.", finalAnswer: false)),
        item("c1", .command(command: "zero ask \"Which?\" --async", cwd: "/", output: "k3x9qa", exitCode: 0, durationMs: 1)),
        item("a2", .agent(text: "Asked.\n\n[zero: asked k3x9qa]", finalAnswer: true)),
    ]
    let rows = TimelineRow.of(TimelineBlock.of(items, working: false))
    #expect(TimelineRow.holding("a1", in: rows)?.block == "work-a1")
    #expect(TimelineRow.holding("a2", in: rows)?.block == "a2")
    #expect(TimelineRow.holding("gone", in: rows) == nil)
}

/// zerod's about and replies on an ask, read as it writes them.
@Test func anAskCarriesWhatItsAboutAndItsReplies() throws {
    let json = """
        {"id":"k3x9qa","kind":"choice","title":"Which bench?","body":"","options":["Bench 3"],
         "agent":{"name":"zerod-01a1","host":"mac","runtime":"zerod","ref":"01a1"},
         "createdAt":"2026-11-12T10:00:00Z","expiresAt":"2026-11-12T11:00:00Z","state":"waiting","output":"",
         "about":{"item":"m1:0","anchor":"bench-plan","title":"Bench plan","text":"## Bench plan\\n\\nBench 3.","at":1700000000000},
         "replies":[{"item":"m2:0","text":"Bench 5 runs staging.","at":1700000060000}]}
        """
    let ask = try jsonDecoder.decode(Ask.self, from: Data(json.utf8))
    #expect(ask.about?.title == "Bench plan" && ask.about?.anchor == "bench-plan")
    #expect(ask.about?.date == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(ask.replies?.first?.text == "Bench 5 runs staging.")
    // What the CLI sends for --about: the anchor alone.
    var sent = ask
    sent.about = Ask.About(anchor: "#risks")
    let written = String(data: try jsonEncoder.encode(sent), encoding: .utf8)!
    #expect(written.contains("\"anchor\":\"#risks\""), "\(written)")
}
