import Foundation
import Testing
@testable import ZeroCore

/// A client's copy of zerod's sessions follows zerod's rule: a snapshot, then only the change numbered next.
private func conversation(_ id: String, seq: UInt64 = 0) -> Conversation {
    var conversation = Conversation(id: id, provider: .codex, cwd: "/work")
    conversation.seq = seq
    return conversation
}

private func title(_ session: String, _ seq: UInt64, _ text: String) -> ZerodMirror.Message {
    .change(ZerodEvent(session: session, seq: seq, change: .title(text)))
}

@Test func aChangeTheSnapshotAlreadyHasIsSkipped() {
    var mirror = ZerodMirror()
    mirror.receive(.session(conversation("s1", seq: 5)))
    let old = mirror.receive(title("s1", 4, "old"))
    #expect(old)
    #expect(mirror.conversations["s1"]?.title == nil)
    let next = mirror.receive(title("s1", 6, "new"))
    #expect(next)
    #expect(mirror.conversations["s1"]?.title == "new")
    #expect(mirror.conversations["s1"]?.seq == 6)
}

@Test func aChangeThatSkipsAheadIsNotAppliedAndAsksForSnapshots() {
    var mirror = ZerodMirror()
    mirror.receive(.session(conversation("s1")))
    let ahead = mirror.receive(title("s1", 2, "missed one"))
    #expect(ahead == false)
    #expect(mirror.conversations["s1"]?.title == nil)
    let unknown = mirror.receive(title("unknown", 1, "no snapshot yet"))
    #expect(unknown == false)
}

@Test func aSnapshotReplacesTheCopyAndSessionsKeepTheOrderTheyCameIn() {
    var mirror = ZerodMirror()
    mirror.receive(.session(conversation("s1")))
    mirror.receive(.session(conversation("s2")))
    var newer = conversation("s1", seq: 9)
    newer.title = "Fresh"
    mirror.receive(.session(newer))
    #expect(mirror.order == ["s1", "s2"])
    #expect(mirror.conversations["s1"] == newer)
}

@Test func changesApplyAsZerodAppliesThem() {
    var copy = conversation("s1")
    let item = ConversationItem(id: "m", turn: nil, kind: .agent(text: "Hel", finalAnswer: false), status: .running)
    copy.apply(.item(item))
    copy.apply(.delta(item: "m", text: "lo"))
    copy.apply(.delta(item: "missing", text: "nothing"))
    #expect(copy.items.first?.kind == .agent(text: "Hello", finalAnswer: false))
    let approval = Approval(id: "0", item: "m", kind: .command, title: "Run ls", command: "ls", cwd: "/", reason: nil, changes: [],
                            choices: [Choice(id: "0", label: "Allow", kind: .allow)])
    copy.apply(.approval(approval))
    copy.apply(.approval(approval))
    #expect(copy.approvals.count == 1, "the same approval again replaces it")
    copy.apply(.resolved("0"))
    #expect(copy.approvals.isEmpty)
    copy.apply(.status(.working, turn: "u", error: nil))
    copy.apply(.thread("t", model: "gpt", effort: nil))
    copy.apply(.thread("t", model: nil, effort: "high"))
    #expect((copy.status, copy.turn, copy.model, copy.effort) == (.working, "u", "gpt", "high"))
    #expect(copy.seq == 9, "every change counts, even one that finds nothing")
}

private func said(_ id: String) -> ConversationItem { ConversationItem(id: id, turn: nil, kind: .agent(text: id, finalAnswer: false), status: .done) }

/// Jumped back through a long conversation: a window of it, not everything from there to the end. What comes while the
/// window stops short of the end is counted below it, never put after its last item (that would leave a gap).
@Test func aWindowAwayFromTheEndCountsWhatComesAfterItAndNewerPagesJoinIt() {
    var mirror = ZerodMirror()
    var c = conversation("s1", seq: 1)
    c.items = [said("x98"), said("x99")]
    mirror.receive(.session(c))
    mirror.receive(.earlier(session: "s1", count: 98))
    mirror.window("s1", items: [said("x10"), said("x11")], earlier: 10, later: 88)
    #expect(mirror.conversations["s1"]?.items.map(\.id) == ["x10", "x11"])
    #expect((mirror.earlier["s1"], mirror.later["s1"]) == (10, 88))
    mirror.receive(.change(ZerodEvent(session: "s1", seq: 2, change: .item(said("x100")))))
    #expect(mirror.conversations["s1"]?.items.map(\.id) == ["x10", "x11"], "not after the window")
    #expect(mirror.later["s1"] == 89)
    mirror.append("s1", items: [said("x12")], later: 88)
    #expect(mirror.conversations["s1"]?.items.map(\.id) == ["x10", "x11", "x12"])
    #expect(mirror.later["s1"] == 88)
    // A fresh snapshot is the latest again.
    mirror.receive(.session(c))
    #expect(mirror.later["s1"] == 0)
}
