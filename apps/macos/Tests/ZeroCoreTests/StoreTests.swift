import Foundation
import Testing
@testable import ZeroCore

/// The app's copy of zerod's inbox: snapshots replace it, changes update it, and what zerod says about agents decides
/// what the inbox offers. (The inbox itself is crates/zerod/tests/inbox.rs.)
@MainActor @Test func theStoreFollowsZerodsInbox() {
    let store = Store(adapters: [])
    var created: [String] = []
    store.onCreate = { created.append($0.id) }
    let codex = AgentIdentity(name: "codex-1", host: "mac")
    var ask = Ask(kind: .run, title: "Tests", options: ["Run", "Reject"], command: "make test", agent: codex)
    store.receive(.asks([], offline: ["codex-1"], reachable: ["codex-1"]))
    #expect(!store.canStop("codex-1") && store.canMessage("codex-1"))
    store.receive(.ask(ask))
    #expect(created == [ask.id], "a new ask arrives once")
    store.choose(ask.id, option: 0)
    #expect(store.ask(ask.id)?.state == .pending, "shown at once, before zerod's word")
    ask.state = .running
    store.receive(.ask(ask))
    store.receive(.output(id: ask.id, chunk: "ok\n"))
    #expect(store.ask(ask.id)?.output == "ok\n")
    #expect(created.count == 1)
    store.receive(.agents(offline: [], reachable: ["codex-1"]))
    #expect(store.canStop("codex-1"))
    store.receive(.removed(ask.id))
    #expect(store.asks.isEmpty)
}

/// Views read what's live, not the history: a run's output redraws only what shows it, and an ask changing in one
/// session doesn't redraw another session's.
@MainActor @Test func theStoreKeepsWhatsLiveApart() {
    let store = Store(adapters: [])
    var one = AgentIdentity(name: "zerod-one", host: "mac"), two = AgentIdentity(name: "zerod-two", host: "mac")
    (one.ref, two.ref) = ("one", "two")
    var run = Ask(kind: .run, title: "Tests", options: ["Run", "Reject"], command: "make test", agent: one)
    var twin = Ask(kind: .run, title: "Tests", options: ["Run", "Reject"], command: "make test", agent: two)
    twin.sameAs = run.id
    var old = Ask(kind: .note, title: "Note", agent: two)
    old.state = .answered
    store.receive(.asks([old, run, twin], offline: [], reachable: []))
    #expect(store.open.map(\.id) == [run.id, twin.id] && store.twins == [run.id: 1])
    #expect(store.agentOrder == ["zerod-two", "zerod-one"] && store.byAgent["zerod-two"]?.count == 2)
    #expect(store.asks(of: "one").map(\.id) == [run.id] && store.identity(of: "zerod-one") == one)

    func fires(_ read: @escaping () -> Void, after change: () -> Void) -> Bool {
        nonisolated(unsafe) var fired = false
        withObservationTracking(read) { fired = true }
        change()
        return fired
    }
    #expect(
        !fires(
            {
                _ = store.asks; _ = store.open; _ = store.asks(of: "one")
            }, after: { store.receive(.output(id: run.id, chunk: "ok\n")) }))
    #expect(fires({ _ = store.output(of: run.id) }, after: { store.receive(.output(id: run.id, chunk: "done\n")) }))
    #expect(store.output(of: run.id) == "ok\ndone\n" && store.ask(run.id)?.output == "ok\ndone\n")
    #expect(
        !fires(
            { _ = store.asks(of: "one") },
            after: {
                twin.state = .answered; store.receive(.ask(twin))
            }))
    #expect(store.twins.isEmpty && store.open.map(\.id) == [run.id])
    #expect(
        fires(
            { _ = store.asks(of: "one") },
            after: {
                run.state = .answered; store.receive(.ask(run))
            }))
    #expect(store.open.isEmpty && store.asks(of: "one").first?.state == .answered)
}
