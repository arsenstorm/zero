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

@Test func theButtonNearerThePointerComesOut() {
    // The slim pair: buttons' centres at 16 and 60, so everything is near one of them, split at 38.
    #expect(BarReach.at(10, height: 76, was: .both) == .inbox)
    #expect(BarReach.at(37, height: 76, was: .both) == .inbox)
    #expect(BarReach.at(39, height: 76, was: .both) == .settings)
    // A tall bar: near the top the inbox, near the foot the settings, both over the middle (the agents).
    #expect(BarReach.at(40, height: 300, was: .both) == .inbox)
    #expect(BarReach.at(150, height: 300, was: .both) == .both)
    #expect(BarReach.at(270, height: 300, was: .both) == .settings)
}

@Test func theBarsButtonsDontFlickerOnTheLineBetweenThem() {
    // Past the split by less than the slack, the button that's out stays out; further on, the other one takes over.
    #expect(BarReach.at(40, height: 76, was: .inbox) == .inbox)
    #expect(BarReach.at(42, height: 76, was: .inbox) == .settings)
    #expect(BarReach.at(36, height: 76, was: .settings) == .settings)
    #expect(BarReach.at(34, height: 76, was: .settings) == .inbox)
    // The same at the edge of a button's reach on a tall bar.
    #expect(BarReach.at(46, height: 300, was: .inbox) == .inbox)
    #expect(BarReach.at(46, height: 300, was: .both) == .both)
}
