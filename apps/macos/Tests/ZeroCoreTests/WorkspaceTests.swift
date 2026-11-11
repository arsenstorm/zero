import Foundation
import Observation
import Testing
@testable import ZeroCore

/// The workspace's copy of zerod's sessions: in the order zerod sent them, and fresh snapshots asked for when it falls
/// behind. (Approvals and questions reach the inbox through zerod itself: crates/zerod/tests/bridge.rs.)
private func session(_ id: String, _ provider: Provider = .claude) -> Conversation {
    var conversation = Conversation(id: id, provider: provider, cwd: "/work")
    conversation.title = "Fix the build"
    conversation.status = .idle
    conversation.seq = 7
    return conversation
}

@MainActor @Test func fallingBehindAsksForFreshSnapshots() {
    let w = Workspace()
    var behind = 0
    w.onBehind = { behind += 1 }
    w.receive(.session(session("01a1aaaa00000001")))
    w.receive(.change(ZerodEvent(session: "01a1aaaa00000001", seq: 12, change: .title("skipped ahead"))))
    #expect(behind == 1)
    #expect(w.conversations.first?.title == "Fix the build")
}

@MainActor @Test func sessionsAreListedInTheOrderZerodSentThem() {
    let w = Workspace()
    w.receive(.session(session("01a1aaaa00000001")))
    w.receive(.session(session("01a1aaaa00000002", .codex)))
    #expect(w.conversations.map(\.id) == ["01a1aaaa00000001", "01a1aaaa00000002"])
}

/// A conversation not on screen (a page kept behind the one shown, the window closed) isn't redrawn as its agent works:
/// the mirror has every change, and the live object catches up the moment it shows again.
@MainActor @Test func aHiddenConversationCatchesUpWhenShown() {
    let w = Workspace()
    let id = "01a1aaaa00000001"
    w.receive(.session(session(id)))
    let live = w.live(id)!
    w.watch(id, true)
    w.watch(id, false)
    w.receive(
        .session(
            {
                var c = session(id); c.title = "Renamed"; c.seq = 8; return c
            }()))
    #expect(live.conversation.title == "Fix the build")
    w.watch(id, true)
    #expect(live.conversation.title == "Renamed")
}

/// Tasks' names on their own: what a conversation shows of other tasks (a worker's report, by its name) changes when a
/// name does, not with every state or usage change anywhere.
@MainActor @Test func namesChangeOnlyWithANameChange() {
    let w = Workspace()
    let id = "01a1aaaa00000001"
    w.receive(.session(session(id)))
    #expect(w.names[id] == Workspace.label(of: w.conversation(id)!))
    var changed = false
    withObservationTracking {
        _ = w.names
    } onChange: {
        changed = true
    }
    w.receive(
        .session(
            {
                var c = session(id); c.status = .working; c.seq = 8; return c
            }()))
    #expect(!changed)
    w.receive(
        .session(
            {
                var c = session(id); c.title = "Renamed"; c.seq = 9; return c
            }()))
    #expect(changed)
}
