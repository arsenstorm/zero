import Testing
@testable import ZeroCore

@Test func aKeptBarOrderNeverLosesAPart() {
    #expect(BarPart.order([]) == [.inbox, .workspaces, .agents])
    #expect(BarPart.order(["agents", "inbox"]) == [.agents, .inbox, .workspaces])
    #expect(BarPart.order(["gone", "agents", "agents"]) == [.agents, .inbox, .workspaces])
}

@Test func theBarShowsTheAgentsItsModeSays() {
    let pinned: Set = ["zerod-a"]
    #expect(BarAgents.all.shows("zerod-b", needsYou: false, pinned: pinned))
    #expect(BarAgents.needsYou.shows("zerod-b", needsYou: true, pinned: pinned))
    #expect(!BarAgents.needsYou.shows("zerod-a", needsYou: false, pinned: pinned))
    #expect(BarAgents.pinned.shows("zerod-a", needsYou: false, pinned: pinned))
    #expect(!BarAgents.pinned.shows("zerod-b", needsYou: true, pinned: pinned))
    #expect(!BarAgents.none.shows("zerod-a", needsYou: true, pinned: pinned))
    #expect(BoardRow.State.handed.needsYou && !BoardRow.State.working.needsYou)
}

@Test func pinningTwiceUnpins() {
    let once = BarPins.toggle("zerod-a", in: "zerod-b")
    #expect(BarPins.set(once) == ["zerod-a", "zerod-b"])
    #expect(BarPins.set(BarPins.toggle("zerod-a", in: once)) == ["zerod-b"])
}
