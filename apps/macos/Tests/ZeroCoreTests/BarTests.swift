import Testing
@testable import ZeroCore

@Test func aKeptBarOrderNeverLosesAPart() {
    #expect(BarPart.order([]) == [.inbox, .agents])
    #expect(BarPart.order(["agents", "inbox"]) == [.agents, .inbox])
    // The workspace control, gone from the bar, is dropped from an order kept from before.
    #expect(BarPart.order(["gone", "workspaces", "agents", "agents"]) == [.agents, .inbox])
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
    #expect(BarReach.at(10, height: 76, was: .neither) == .inbox)
    #expect(BarReach.at(37, height: 76, was: .neither) == .inbox)
    #expect(BarReach.at(39, height: 76, was: .neither) == .settings)
    // A tall bar: near the top the inbox, near the foot the settings, neither over the middle (the agents).
    #expect(BarReach.at(40, height: 300, was: .neither) == .inbox)
    #expect(BarReach.at(150, height: 300, was: .neither) == .neither)
    #expect(BarReach.at(270, height: 300, was: .neither) == .settings)
    // The inbox's reach ends where the first slot starts (the body's top padding, 46 pt down).
    #expect(BarReach.at(44, height: 300, was: .neither) == .inbox)
    #expect(BarReach.at(46, height: 300, was: .neither) == .neither)
}

@Test func theBarsButtonsDontFlickerOnTheLineBetweenThem() {
    // Past the split by less than the slack, the button that's out stays out; further on, the other one takes over.
    #expect(BarReach.at(40, height: 76, was: .inbox) == .inbox)
    #expect(BarReach.at(42, height: 76, was: .inbox) == .settings)
    #expect(BarReach.at(36, height: 76, was: .settings) == .settings)
    #expect(BarReach.at(34, height: 76, was: .settings) == .inbox)
    // The same at the edge of a button's reach on a tall bar.
    #expect(BarReach.at(46, height: 300, was: .inbox) == .inbox)
    #expect(BarReach.at(46, height: 300, was: .neither) == .neither)
}

private func dot(_ name: String, in workspace: String?, running: Bool = false, waiting: Bool = false) -> BarGroups.Dot {
    BarGroups.Dot(name: name, workspace: workspace, running: running, waiting: waiting)
}

@Test func theGroupsKeepTheRailsOrderWhicheverTheWindowShows() {
    // The window's workspace in its own place, not first; an agent outside Zero (no workspace) goes with the window's.
    let dots = [dot("a", in: "site"), dot("b", in: "zero"), dot("c", in: "notes"), dot("t", in: nil), dot("d", in: "site")]
    let groups = BarGroups.make(dots, workspaces: ["zero", "notes", "site"], window: "site", from: .all)
    #expect(groups.map(\.workspace) == ["zero", "notes", "site"])
    #expect(groups.map(\.dots) == [["b"], ["c"], ["a", "t", "d"]])
    #expect(groups.map(\.window) == [false, false, true])
    // Switching the window changes which group is the window's, never the order.
    let switched = BarGroups.make(dots, workspaces: ["zero", "notes", "site"], window: "zero", from: .all)
    #expect(switched.map(\.workspace) == ["zero", "notes", "site"])
    #expect(switched.map(\.window) == [true, false, false])
    // A workspace the rail doesn't list yet follows the listed ones.
    let unknown = BarGroups.make([dot("x", in: "new"), dot("b", in: "zero")], workspaces: ["zero"], window: "zero", from: .all)
    #expect(unknown.map(\.workspace) == ["zero", "new"])
}

@Test func onlyTheWindowsWorkspaceIsOpenTheOthersFoldWhateverWaitsThere() {
    let dots = [
        dot("w", in: "zero"),
        dot("a", in: "infra", running: true), dot("b", in: "infra", running: true), dot("c", in: "infra"),
        dot("d", in: "site", running: true), dot("e", in: "site", waiting: true),
    ]
    let groups = BarGroups.make(dots, workspaces: ["zero", "site", "infra"], window: "zero", from: .all)
    #expect(groups.map(\.folds) == [false, true, true])
    // Folded, a workspace still tells what waits on the user there (its mark's dot) and what runs (its tip).
    #expect(groups.map(\.waiting) == [false, true, false])
    #expect(groups[2].running == 2)
    // The window's workspace never folds, whatever waits there.
    #expect(!BarGroups.make([dot("w", in: "zero", waiting: true)], workspaces: ["zero"], window: "zero", from: .all)[0].folds)
}

@Test func aWorkspaceWithNoAgentsHasNoGroup() {
    // The window's workspace has none either: only the one with agents shows, under its mark (not the window's).
    let groups = BarGroups.make([dot("a", in: "site")], workspaces: ["zero", "site", "notes"], window: "zero", from: .all)
    #expect(groups.map(\.workspace) == ["site"])
    #expect(!groups[0].window)
}

@Test func showingTheWindowsWorkspaceOnlyLeavesTheOthersOut() {
    let dots = [dot("a", in: "site"), dot("b", in: "zero"), dot("t", in: nil)]
    let groups = BarGroups.make(dots, workspaces: ["zero", "site"], window: "zero", from: .window)
    #expect(groups.map(\.workspace) == ["zero"])
    #expect(groups[0].dots == ["b", "t"])
}

@Test func theBarMarksItsGroupsOnlyWhenThereIsMoreThanTheWindowsOwn() {
    let window = BarGroups.make([dot("a", in: "zero")], workspaces: ["zero", "site"], window: "zero", from: .all)
    #expect(!BarGroups.marked(window))
    let two = BarGroups.make([dot("a", in: "zero"), dot("b", in: "site")], workspaces: ["zero", "site"], window: "zero", from: .all)
    #expect(BarGroups.marked(two))
    // Another workspace's agents alone: marked, so they don't pass for the window's.
    let other = BarGroups.make([dot("b", in: "site")], workspaces: ["zero", "site"], window: "zero", from: .all)
    #expect(BarGroups.marked(other))
}

@Test func aGroupSaysWhatItHoldsInWords() {
    let groups = BarGroups.make(
        [
            dot("a", in: "infra", running: true), dot("b", in: "infra", running: true), dot("c", in: "site", running: true),
            dot("d", in: "site", waiting: true), dot("e", in: "notes"),
        ],
        workspaces: ["zero", "site", "infra", "notes"], window: "zero", from: .all)
    #expect(BarGroups.summary(name: "Website", groups[0]) == "Website · needs you · 1 working")
    #expect(BarGroups.summary(name: "Infra", groups[1]) == "Infra · 2 working")
    #expect(BarGroups.summary(name: "Notes", groups[2]) == "Notes · nothing working")
}

@Test func aChangeIsDrawnThroughBothStatesAtOnceNothingLeavingBeforeItsSlotCloses() {
    let order = ["zero", "site", "notes"]
    let was = BarGroups.make(
        [dot("a", in: "zero"), dot("b", in: "zero"), dot("c", in: "zero"), dot("n", in: "notes")], workspaces: order, window: "zero",
        from: .all)
    // b moves to site (a new group), notes' last agent leaves, d arrives in zero, and the window switches to site.
    let now = BarGroups.make(
        [dot("a", in: "zero"), dot("d", in: "zero"), dot("c", in: "zero"), dot("b", in: "site")], workspaces: order, window: "site",
        from: .all)
    let both = BarGroups.union(was, now, workspaces: order, fieldsFrom: was)
    #expect(both.map(\.workspace) == ["zero", "site", "notes"])
    // Now's order, with what left kept after what it followed.
    #expect(both.map(\.dots) == [["a", "b", "d", "c"], ["b"], ["n"]])
    // The groups' own fields from the state asked for: the window as it was, then as it is.
    #expect(both.map(\.window) == [true, false, false])
    #expect(BarGroups.union(was, now, workspaces: order, fieldsFrom: now).map(\.window) == [false, true, false])
}
