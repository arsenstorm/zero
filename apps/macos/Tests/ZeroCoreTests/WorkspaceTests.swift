import Foundation
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
