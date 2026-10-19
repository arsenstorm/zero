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
