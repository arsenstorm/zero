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
