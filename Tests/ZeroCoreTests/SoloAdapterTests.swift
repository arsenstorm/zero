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
    // The session id lands a little after the first prompt; the title a little after the first answer.
    var session: String?
    for _ in 0..<15 {
        session = await store.identity(of: identity.name)?.session
        if session != nil { break }
        try await Task.sleep(for: .seconds(2))
    }
    print("session:", session ?? "nil")
    #expect(session != nil)
    for _ in 0..<10 {
        await store.relabel(await store.identity(of: identity.name)!)
        if await store.displayName(of: identity.name) != "Reply with the single word…" { break }
        try await Task.sleep(for: .seconds(3))
    }
    print("label:", await store.displayName(of: identity.name))
}

/// Live: a stopped Claude comes back with its conversation. `ZERO_SOLO_REVIVE=<pid>:<project>:<session>`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_SOLO_REVIVE"] != nil))
func soloAdapterRevivesWithSession() async throws {
    let parts = ProcessInfo.processInfo.environment["ZERO_SOLO_REVIVE"]!.split(separator: ":").map(String.init)
    let agent = AgentIdentity(name: "revive-test", host: "mac", soloProcessID: Int(parts[0]), soloProjectID: Int(parts[1]), session: parts[2])
    let adapter = SoloAdapter()
    let revived = try await adapter.revive(agent)
    print("revived as process", revived.soloProcessID ?? -1)
    #expect(revived.soloProcessID != agent.soloProcessID)
    let screen = await adapter.screen(of: revived) ?? ""
    print("screen has earlier answer:", screen.contains("ready"))
    #expect(screen.contains("ready"))
}

/// Live: the agent's screen comes back, keys go in. `ZERO_SOLO_SCREEN_PID=124 ZERO_SOLO_PROJECT=13 swift test --filter soloAdapterScreen`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_SOLO_SCREEN_PID"] != nil))
func soloAdapterScreenAndKeys() async throws {
    let env = ProcessInfo.processInfo.environment
    let agent = AgentIdentity(name: "t", host: "mac", soloProcessID: Int(env["ZERO_SOLO_SCREEN_PID"]!), soloProjectID: env["ZERO_SOLO_PROJECT"].flatMap(Int.init))
    let adapter = SoloAdapter()
    let screen = await adapter.screen(of: agent)
    #expect(screen?.isEmpty == false)
    try await adapter.send("/model", to: agent)
    try await Task.sleep(for: .seconds(1))
    let picker = try await adapter.press([27, 91, 66], on: agent) // down
    #expect(picker?.contains("Select model") == true)
    let after = try await adapter.press([27], on: agent) // esc
    print("after esc has picker:", after?.contains("Select model") == true)
}
