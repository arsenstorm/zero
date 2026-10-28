import Foundation
import Testing
@testable import ZeroCore

/// The real zerod (target/debug/zerod, which `cargo test` builds; `make test` runs cargo first), launched the way
/// the app launches it, in a home and socket of the test's own.
private let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../target/debug/zerod").standardized.path

/// Ends the daemon on `socket` and its home: it says its pid when greeted.
private func shutDown(_ socket: String, _ home: URL) {
    if let connection = try? UnixSocket.connect(path: socket) {
        try? connection.write(line: #"{"id":0,"op":"hello"}"#)
        if let line = connection.readLine(), let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let pid = (reply["result"] as? [String: Any])?["pid"] as? Int32 { kill(pid, SIGTERM) }
        connection.close()
    }
    try? FileManager.default.removeItem(at: home)
}

private func launch(_ name: String) async throws -> (socket: String, home: URL) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zerod-swift-\(name)-\(getpid())")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let socket = home.appendingPathComponent("z.sock").path
    let started = await ZerodLink.launch(binary: binary, home: home.appendingPathComponent("data").path, socket: socket)
    try #require(started, "zerod didn't start from \(binary); build it with cargo build -p zerod")
    return (socket, home)
}

@Test func zerodAnswersRequestsAndRefusesBadOnesWithItsReason() async throws {
    let (socket, home) = try await launch("requests")
    let link = try ZerodLink(path: socket)
    defer { link.close(); shutDown(socket, home) }
    #expect(try await link.hello() == 1)
    #expect(try await link.list().isEmpty)
    await #expect(throws: ZerodError(message: "relative isn't a folder")) {
        _ = try await link.start(provider: .codex, cwd: "relative", prompt: "hi")
    }
    await #expect(throws: ZerodError(message: "No session nope")) { try await link.decide(session: "nope", approval: "0", choice: "0") }
    // Requests run concurrently in zerod and answer by id, so they can be in flight together.
    async let first = link.hello()
    async let second = link.list()
    #expect(try await (first, second.count) == (1, 0))
}

@Test func launchingAgainFindsTheDaemonAlreadyRunning() async throws {
    let (socket, home) = try await launch("again")
    defer { shutDown(socket, home) }
    #expect(await ZerodLink.launch(binary: binary, home: home.appendingPathComponent("data").path, socket: socket))
    let link = try ZerodLink(path: socket)
    defer { link.close() }
    #expect(try await link.hello() == 1)
}

@Test func aSubscriberGetsEverySessionAsASnapshotWithItsHistory() async throws {
    // A session kept from before, as zerod finds it after a restart: a recorded Claude transcript. Nothing is started.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zerod-swift-subscribe-\(getpid())")
    try? FileManager.default.removeItem(at: home)
    let kept = home.appendingPathComponent("data/sessions/01a1000000000000")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    try #"{"id":"01a1000000000000","provider":"claude","cwd":"/work/project","thread":null}"#.write(to: kept.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    let recording = URL(fileURLWithPath: binary).deletingLastPathComponent().appendingPathComponent("../../crates/zerod/tests/fixtures/claude-command.jsonl").standardized
    try FileManager.default.copyItem(at: recording, to: kept.appendingPathComponent("transcript.jsonl"))
    let socket = home.appendingPathComponent("z.sock").path
    try #require(await ZerodLink.launch(binary: binary, home: home.appendingPathComponent("data").path, socket: socket))
    let link = try ZerodLink(path: socket)
    defer { link.close(); shutDown(socket, home) }
    let heard = Heard()
    link.onMessage = { heard.add($0) }
    try await link.subscribe()
    for _ in 0..<200 where heard.conversations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    let conversation = try #require(heard.conversations.first)
    #expect(conversation.id == "01a1000000000000")
    #expect(conversation.provider == .claude)
    #expect(conversation.status == .offline)
    #expect(conversation.items.last?.kind == .agent(text: "The command printed `Darwin`.", finalAnswer: true))

    // A session named over the socket, as `zero label` does, and asked for its answer, as `zero result` does.
    try await link.label(session: conversation.id, label: "Uname check", ticket: "GH-1")
    #expect(try await link.get(conversation.id).label == "Uname check")
    #expect(try await link.result(of: conversation.id) == "The command printed `Darwin`.")
    #expect(try await link.workers(of: conversation.id).isEmpty)
    let settled = try await link.wait(on: [conversation.id], timeout: 1)
    #expect(settled.first?["attention"] as? String == "offline")
    await #expect(throws: ZerodError(message: "No session nope to lead it")) { _ = try await link.spawn(lead: "nope", provider: .codex, prompt: "x") }

    // Offline, it is on the board only once its agent hands the user something.
    #expect(try await link.board().isEmpty)
    var note = Ask(kind: .note, title: "Update", body: "Printed the kernel name", agent: AgentIdentity(name: "zerod-" + conversation.id, host: "mac"))
    note.status = "done"
    note.needs = "check it says Darwin"
    _ = try await link.create(note)
    let row = try #require(try await link.board().first)
    #expect((row.session, row.task, row.ticket, row.state, row.now, row.needs) == (conversation.id, "Uname check", "GH-1", .ready, "Printed the kernel name", "check it says Darwin"))
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [Conversation] = []
    var conversations: [Conversation] { lock.withLock { snapshots } }
    func add(_ message: ZerodMirror.Message) {
        guard case .session(let conversation) = message else { return }
        lock.withLock { snapshots.append(conversation) }
    }
}

private final class InboxHeard: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ZerodLink.InboxMessage] = []
    func add(_ message: ZerodLink.InboxMessage) { lock.withLock { messages.append(message) } }
    var all: [ZerodLink.InboxMessage] { lock.withLock { messages } }
}

@Test func theInboxIsFollowedAndAnsweredThroughZerod() async throws {
    let (socket, home) = try await launch("inbox")
    let link = try ZerodLink(path: socket)
    defer { link.close(); shutDown(socket, home) }
    let heard = InboxHeard()
    link.onInbox = { heard.add($0) }
    try await link.configure(takeBack: 0.05, ttl: 600, patterns: [])
    try await link.followInbox()
    let ask = try await link.create(Ask(kind: .choice, title: "Ship it?", options: ["Yes", "No"], agent: AgentIdentity(name: "codex-1", host: "mac")))
    try await link.choose(ask.id, option: 0)
    for _ in 0..<300 {
        if heard.all.contains(where: { if case let .ask(a) = $0 { a.id == ask.id && a.state == .answered } else { false } }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard case .asks = heard.all.first else { Issue.record("no snapshot first"); return }
    let answered = heard.all.compactMap { if case let .ask(a) = $0, a.id == ask.id { a } else { nil } }.last
    #expect((answered?.state, answered?.answer) == (.answered, "Yes"))
}
