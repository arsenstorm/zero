import Foundation
import Testing
@testable import ZeroCore

/// zerod's approvals in the inbox: each one a permission ask, answered there or in the workspace, heard by zerod
/// once, and withdrawn when it is settled anywhere else.
private let choices = [Choice(id: "allow", label: "Allow", kind: .allow), Choice(id: "always", label: "Always allow Bash(make)", kind: .allowAlways),
                       Choice(id: "deny", label: "Deny", kind: .deny), Choice(id: "stop", label: "Deny and stop", kind: .stop)]

private func waiting(_ approvals: [Approval] = [Approval(id: "r1", item: "t1", kind: .command, title: "Run make", command: "make", cwd: "/work",
                                                         reason: "Build it", changes: [], choices: choices)]) -> Conversation {
    var conversation = Conversation(id: "01a1aaaa00000001", provider: .claude, cwd: "/work")
    conversation.title = "Fix the build"
    conversation.status = .waiting
    conversation.approvals = approvals
    conversation.seq = 7
    return conversation
}

@MainActor
private final class Heard {
    var decisions: [(String, String, String)] = []
    var sent: [(String, String)] = []
    var behind = 0
}

@MainActor
private func workspace(_ store: Store) -> (Workspace, Heard) {
    let heard = Heard()
    let workspace = Workspace(store: store)
    workspace.onDecide = { heard.decisions.append(($0, $1, $2)) }
    workspace.onSend = { heard.sent.append(($0, $1)) }
    workspace.onBehind = { heard.behind += 1 }
    return (workspace, heard)
}

@MainActor
private func store(_ log: URL? = nil) -> Store {
    let store = Store(logURL: log, adapters: [])
    store.takeBackDelay = 0.05
    return store
}

@MainActor @Test func anApprovalBecomesOnePermissionAskWithTheProvidersChoices() throws {
    let s = store()
    let (w, _) = workspace(s)
    w.receive(.session(waiting()))
    w.receive(.session(waiting()))
    let asks = s.open
    try #require(asks.count == 1, "a snapshot seen twice asks once")
    let ask = asks[0]
    #expect(ask.kind == .permission)
    #expect(ask.title == "Run make")
    #expect(ask.body == "Build it")
    #expect(ask.command == "make")
    #expect(ask.options == ["Allow", "Always allow Bash(make)", "Deny", "Deny and stop"])
    #expect(ask.agent.runtime == "zerod")
    #expect(ask.agent.ref == "01a1aaaa00000001")
    #expect(s.displayName(of: ask.agent.name) == "Fix the build")
}

@MainActor @Test func answeringTheAskTellsZerodTheChoiceOnce() async throws {
    let s = store()
    let (w, heard) = workspace(s)
    w.receive(.session(waiting()))
    let ask = try #require(s.open.first)
    s.choose(ask.id, option: 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(heard.decisions.count == 1)
    #expect(heard.decisions.first.map { [$0.0, $0.1, $0.2] } == ["01a1aaaa00000001", "r1", "always"])
}

@MainActor @Test func anApprovalSettledElsewhereWithdrawsItsAsk() throws {
    let s = store()
    let (w, heard) = workspace(s)
    w.receive(.session(waiting()))
    let ask = try #require(s.open.first)
    w.receive(.change(ZerodEvent(session: "01a1aaaa00000001", seq: 8, change: .resolved("r1"))))
    #expect(s.open.isEmpty)
    #expect(s.ask(ask.id)?.status == "withdrawn")
    #expect(heard.decisions.isEmpty, "a withdrawn ask is not an answer")
}

@MainActor @Test func afterARelaunchTheAskStillWaitingIsTheOneAnswered() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: log) }
    let before = store(log)
    let (first, _) = workspace(before)
    first.receive(.session(waiting()))
    let ask = try #require(before.open.first)

    let after = store(log)
    let (second, heard) = workspace(after)
    second.receive(.session(waiting()))
    #expect(after.open.map(\.id) == [ask.id], "the same ask, not a second one")
    after.choose(ask.id, option: 0)
    try await Task.sleep(for: .milliseconds(200))
    #expect(heard.decisions.first?.2 == "allow")
}

@MainActor @Test func aTypedReplyDeniesAndSaysWhy() async throws {
    let s = store()
    let (w, heard) = workspace(s)
    w.receive(.session(waiting()))
    let ask = try #require(s.open.first)
    s.reply(ask.id, text: "use the Makefile in build/")
    try await Task.sleep(for: .milliseconds(200))
    #expect(heard.decisions.first?.2 == "deny")
    #expect(heard.sent.first.map { [$0.0, $0.1] } == ["01a1aaaa00000001", "use the Makefile in build/"])
}

@MainActor @Test func fallingBehindAsksForFreshSnapshots() {
    let s = store()
    let (w, heard) = workspace(s)
    w.receive(.session(waiting()))
    w.receive(.change(ZerodEvent(session: "01a1aaaa00000001", seq: 12, change: .title("skipped ahead"))))
    #expect(heard.behind == 1)
    #expect(w.conversations.first?.title == "Fix the build")
}

@MainActor @Test func sessionsAreListedInTheOrderZerodSentThem() {
    let s = store()
    let (w, _) = workspace(s)
    var other = Conversation(id: "01a1aaaa00000002", provider: .codex, cwd: "/elsewhere")
    other.status = .idle
    w.receive(.session(waiting([])))
    w.receive(.session(other))
    #expect(w.conversations.map(\.id) == ["01a1aaaa00000001", "01a1aaaa00000002"])
    #expect(s.open.isEmpty, "no approvals, no asks")
}
