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
    var answers: [(String, String, [String: [String]])] = []
    var decisions: [(String, String, String)] = []
    var sent: [(String, String)] = []
    var behind = 0
}

@MainActor
private func workspace(_ store: Store) -> (Workspace, Heard) {
    let heard = Heard()
    let workspace = Workspace(store: store)
    workspace.onDecide = { heard.decisions.append(($0, $1, $2)) }
    workspace.onAnswer = { heard.answers.append(($0, $1, $2)) }
    workspace.onSend = { heard.sent.append(($0, $1)) }
    workspace.onBehind = { heard.behind += 1 }
    return (workspace, heard)
}

/// Waits until `test` holds, up to five seconds: answers land after the inbox's take-back window, later under load.
@MainActor
private func eventually(_ test: () -> Bool) async {
    for _ in 0..<500 where !test() { try? await Task.sleep(for: .milliseconds(10)) }
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
    await eventually { !heard.decisions.isEmpty }
    try await Task.sleep(for: .milliseconds(100))
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
    await eventually { !heard.decisions.isEmpty }
    #expect(heard.decisions.first?.2 == "allow")
}

@MainActor @Test func aTypedReplyDeniesAndSaysWhy() async throws {
    let s = store()
    let (w, heard) = workspace(s)
    w.receive(.session(waiting()))
    let ask = try #require(s.open.first)
    s.reply(ask.id, text: "use the Makefile in build/")
    await eventually { !heard.sent.isEmpty }
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

private func asking(_ fields: [Field]) -> Conversation {
    var conversation = waiting([])
    conversation.questions = [Question(id: "q1", item: "t1", fields: fields)]
    return conversation
}

private let cache = Field(id: "0", header: "Cache", question: "Redis or Postgres?", options: [QuestionOption(label: "Redis", description: "in the stack"),
                                                                                         QuestionOption(label: "Postgres", description: nil)],
                          multiple: false, other: true, secret: false)
private let checks = Field(id: "1", header: "Checks", question: "Which checks?", options: [QuestionOption(label: "Lint", description: nil),
                                                                                       QuestionOption(label: "Tests", description: nil)],
                           multiple: false, other: false, secret: false)

@MainActor @Test func eachFieldOfAQuestionIsAnAskAndTheAgentHearsOnceAllAreAnswered() async throws {
    let s = store()
    let (w, heard) = workspace(s)
    w.receive(.session(asking([cache, checks])))
    let asks = s.open.sorted { $0.title < $1.title }
    try #require(asks.count == 2)
    #expect(asks.map(\.title) == ["Redis or Postgres?", "Which checks?"])
    #expect(asks[0].options == ["Redis", "Postgres", "Something else…"], "free text where the agent takes it")
    #expect(asks[1].options == ["Lint", "Tests"])
    #expect(asks[0].detail == "Redis: in the stack")
    s.answer(asks[0].id, option: 2, text: "SQLite, it's a prototype")
    await eventually { s.ask(asks[0].id)?.state.isFinal == true }
    #expect(heard.answers.isEmpty, "one field still open")
    s.choose(asks[1].id, option: 1)
    await eventually { !heard.answers.isEmpty }
    try #require(heard.answers.count == 1)
    #expect(heard.answers[0].1 == "q1")
    #expect(heard.answers[0].2 == ["0": ["SQLite, it's a prototype"], "1": ["Tests"]])
}

@MainActor @Test func aSecretIsNeverAskedInTheInbox() {
    let s = store()
    let (w, _) = workspace(s)
    var token = cache
    token.secret = true
    w.receive(.session(asking([token])))
    #expect(s.open.isEmpty, "the inbox's log would keep it; the workspace window asks for it instead")
    #expect(s.asks.last?.kind == .note)
    #expect(s.asks.last?.status == "blocked")
}

@MainActor @Test func everySessionHasADotThatFollowsItsAttention() {
    let s = store()
    let (w, _) = workspace(s)
    var session = Conversation(id: "01a1aaaa00000003", provider: .codex, cwd: "/work")
    session.status = .working
    session.seq = 1
    w.receive(.session(session))
    let name = "zerod-01a1aaaa00000003"
    #expect(s.asks.last { $0.agent.name == name }?.status == nil, "working: blue")
    session.status = .idle
    session.items = [ConversationItem(id: "a", turn: nil, kind: .agent(text: "Done.", finalAnswer: true), status: .done)]
    session.seq = 2
    w.receive(.session(session))
    #expect(s.asks.last { $0.agent.name == name }?.status == "done")
    w.receive(.session(session))
    #expect(s.asks.filter { $0.agent.name == name }.count == 2, "the same attention again posts nothing")
    session.stalled = "No word from Codex for 10 minutes"
    session.status = .working
    session.seq = 3
    w.receive(.session(session))
    let stuck = s.asks.last { $0.agent.name == name }
    #expect((stuck?.status, stuck?.body) == ("blocked", "No word from Codex for 10 minutes"))
    session.status = .offline
    session.stalled = nil
    session.seq = 4
    w.receive(.session(session))
    #expect(s.isClosed(name), "an offline session leaves the bar until it works again")
}
