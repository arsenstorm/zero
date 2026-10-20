import Foundation
import Testing
@testable import ZeroCore

/// Integration check against the running Solo app. Runs only with ZERO_SOLO_PID set to a scratch terminal's id:
/// `ZERO_SOLO_PID=112 swift test --filter SoloAdapter`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_SOLO_PID"] != nil))
func soloAdapterDeliversInput() async throws {
    let pid = Int(ProcessInfo.processInfo.environment["ZERO_SOLO_PID"]!)!
    let agent = AgentIdentity(name: "term-\(pid)", host: "mac", soloProcessID: pid)
    let adapter = SoloAdapter()
    #expect(adapter.canReach(agent))
    try await adapter.send("echo zero-ok-\(pid)", to: agent)
}

/// Read-only: Solo lists projects and agent tools through the adapter. Runs only with ZERO_SOLO=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_SOLO"] != nil))
func soloAdapterListsSpawnChoices() async throws {
    let adapter = SoloAdapter()
    let targets = try await adapter.spawnTargets()
    let runtimes = try await adapter.spawnRuntimes()
    #expect(targets.contains { $0.name == "zero" })
    #expect(runtimes.contains { $0.name == "Claude" })
}

/// Starts a real agent in the project named by ZERO_SOLO_SPAWN_PROJECT and sends it one line. Costs a launch.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_SOLO_SPAWN_PROJECT"] != nil))
func soloAdapterSpawnsAnAgent() async throws {
    let adapter = SoloAdapter()
    let project = ProcessInfo.processInfo.environment["ZERO_SOLO_SPAWN_PROJECT"]!
    let target = try await adapter.spawnTargets().first { $0.id == project }!
    let runtime = try await adapter.spawnRuntimes().first { $0.name == "Claude" }!
    let prompt = "Reply with the single word ready, then stop."
    // Through the store: a provisional agent first, rebound to the real one, then the reply and Solo's label.
    let store = await Store(logURL: nil, adapters: [adapter])
    var provisional: String?
    let identity = try await store.spawn(prompt: prompt, adapter: adapter, target: target, runtime: runtime, model: nil, started: { provisional = $0 })
    #expect(provisional?.hasPrefix("starting-") == true)
    #expect(identity.soloProcessID != nil)
    let names = await store.asks.map(\.agent.name)
    #expect(names == [identity.name])
    print("spawned", identity.name, identity.soloProcessID ?? -1, "provisional:", provisional ?? "nil")
    for _ in 0..<60 {
        try await Task.sleep(for: .seconds(2))
        if await store.asks.contains(where: { $0.kind == .note }) { break }
    }
    let note = await store.asks.last { $0.kind == .note }
    print("reply:", note?.body ?? "nil")
    #expect(note?.body.lowercased().contains("ready") == true)
    await store.relabel(identity)
    print("label:", await store.displayName(of: identity.name))
}
