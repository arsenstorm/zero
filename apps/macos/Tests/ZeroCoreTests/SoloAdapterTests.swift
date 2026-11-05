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

/// Live: a stopped Claude comes back with its conversation. `ZERO_SOLO_REVIVE=<pid>:<project>:<session>`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_SOLO_REVIVE"] != nil))
func soloAdapterRevivesWithSession() async throws {
    let parts = ProcessInfo.processInfo.environment["ZERO_SOLO_REVIVE"]!.split(separator: ":").map(String.init)
    let agent = AgentIdentity(name: "revive-test", host: "mac", soloProcessID: Int(parts[0]), soloProjectID: Int(parts[1]), session: parts[2])
    let adapter = SoloAdapter()
    let revived = try await adapter.connect(agent)
    #expect(revived.soloProcessID != agent.soloProcessID)
    let screen = await adapter.screen(of: revived) ?? ""
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

@Test func draftsAreReadFromTheInputBoxOnly() {
    let rule = String(repeating: "─", count: 40)
    let typing = "❯ old prompt in the scrollback\n⏺ reply\n\(rule)\n❯ let's leave this\n\(rule)\n  ⏵⏵ auto mode on"
    #expect(SoloAdapter.draft(in: typing) == "let's leave this")
    #expect(SoloAdapter.draft(in: "\(rule)\n❯ \n\(rule)") == "")
    #expect(SoloAdapter.draft(in: "\(rule)\n❯ Try \"refactor x\"\n\(rule)") == "")
    #expect(SoloAdapter.draft(in: "no box here") == nil)
}
