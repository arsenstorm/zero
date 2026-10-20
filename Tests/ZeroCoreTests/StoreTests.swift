import Foundation
import Testing
@testable import ZeroCore

private let agent = AgentIdentity(name: "test", host: "mac")

@MainActor
private func store() -> Store {
    let s = Store(logURL: nil)
    s.takeBackDelay = 0.1
    return s
}

@MainActor @Test func chooseTakeBackThenAnswer() async throws {
    let s = store()
    let a = s.create(Ask(kind: .choice, title: "Pick", options: ["Yes", "No"], agent: agent))
    s.choose(a.id, option: 0)
    #expect(s.ask(a.id)?.state == .pending)
    #expect(s.takeBack(a.id))
    #expect(s.ask(a.id)?.state == .waiting)
    s.choose(a.id, option: 1)
    try await Task.sleep(for: .seconds(0.3))
    #expect(s.ask(a.id)?.state == .answered)
    #expect(s.ask(a.id)?.answer == "No")
}

@MainActor @Test func approveSecondOptionDeclines() async throws {
    let s = store()
    let a = s.create(Ask(kind: .approve, title: "Go?", options: ["Yes", "No", "No, and say why…"], agent: agent))
    s.choose(a.id, option: 1)
    try await Task.sleep(for: .seconds(0.3))
    #expect(s.ask(a.id)?.state == .declined)
    let b = s.create(Ask(kind: .approve, title: "Go?", options: ["Yes", "No", "No, and say why…"], agent: agent))
    s.answer(b.id, option: 2, text: "use pnpm")
    try await Task.sleep(for: .seconds(0.3))
    #expect(s.ask(b.id)?.state == .declined)
    #expect(s.ask(b.id)?.answer == "No, and say why: use pnpm")
}

@MainActor @Test func typedReplyAnswers() async throws {
    let s = store()
    let a = s.create(Ask(kind: .question, title: "Which?", agent: agent))
    s.reply(a.id, text: "the second one")
    try await Task.sleep(for: .seconds(0.3))
    #expect(s.ask(a.id)?.answer == "the second one")
    #expect(s.ask(a.id)?.state == .answered)
}

@MainActor @Test func expires() async throws {
    let s = store()
    let a = s.create(Ask(kind: .question, title: "Slow", agent: agent, ttl: 1))
    try await Task.sleep(for: .seconds(1.3))
    #expect(s.ask(a.id)?.state == .expired)
}

@MainActor @Test func runStreamsOutputAndExitCode() async throws {
    let s = store()
    var chunks = ""
    s.onOutput = { _, c in chunks += c }
    let a = s.create(Ask(kind: .run, title: "Run", options: ["Run", "Decline"], command: "printf hi; exit 3", cwd: "/tmp", agent: agent))
    s.choose(a.id, option: 0)
    for _ in 0..<100 where s.ask(a.id)?.state != .answered {
        try await Task.sleep(for: .seconds(0.1))
    }
    #expect(s.ask(a.id)?.state == .answered)
    #expect(s.ask(a.id)?.exitCode == 3)
    #expect(s.ask(a.id)?.output.contains("hi") == true)
    #expect(chunks.contains("hi"))
}

@Test func codexNamesReadCodenameFirst() {
    #expect(SoloAdapter.codexDisplayName("GPT-5.6-Luna") == "Luna 5.6")
    #expect(SoloAdapter.codexDisplayName("GPT-6.1-Sol") == "Sol 6.1")
    #expect(SoloAdapter.codexDisplayName("GPT-5.5") == "GPT 5.5")
    #expect(SoloAdapter.codexDisplayName("Daybreak Blue") == "Daybreak Blue")
}

@MainActor @Test func asyncAnswersAreDeliveredAndShowWhenTheyCannotBe() async throws {
    let s = store()
    var unwaited = Ask(kind: .choice, title: "Pick", options: ["Yes", "No"], agent: agent)
    unwaited.waits = false
    let a = s.create(unwaited)
    s.choose(a.id, option: 0)
    try await Task.sleep(for: .seconds(0.3))
    #expect(s.ask(a.id)?.state == .answered)
    #expect(s.ask(a.id)?.delivery == .failed) // no adapter can reach "test"
    let b = s.create(Ask(kind: .choice, title: "Pick", options: ["Yes", "No"], agent: agent))
    s.choose(b.id, option: 0)
    try await Task.sleep(for: .seconds(0.3))
    #expect(s.ask(b.id)?.delivery == nil) // a waiting agent reads its own answer
}

/// Solo as far as cleanup sees it: "gone" is closed there, and stops are recorded.
private final class FakeRuntime: AgentAdapter, @unchecked Sendable {
    let name = "fake"
    var closed: Set<String> = []
    var stopped: [String] = []
    func canReach(_ agent: AgentIdentity) -> Bool { true }
    func send(_ text: String, to agent: AgentIdentity) async throws {}
    func gone(among agents: [AgentIdentity]) async -> Set<String> { Set(agents.map(\.name)).intersection(closed) }
    func stop(_ agent: AgentIdentity) async { stopped.append(agent.name) }
}

@MainActor @Test func agentsClosedInTheRuntimeLeaveTheBarAndRemovedOnesStop() async throws {
    let runtime = FakeRuntime()
    let s = Store(logURL: nil, adapters: [runtime])
    _ = s.create(Ask(kind: .note, title: "Hi", agent: AgentIdentity(name: "a", host: "mac")))
    _ = s.create(Ask(kind: .note, title: "Hi", agent: AgentIdentity(name: "b", host: "mac")))
    runtime.closed = ["a"]
    await s.refreshLiveness()
    #expect(s.isClosed("a") && !s.isClosed("b"))
    #expect(runtime.stopped.isEmpty) // already gone: nothing to stop
    s.closeAgent("b")
    try await Task.sleep(for: .seconds(0.1))
    #expect(runtime.stopped == ["b"])
}
