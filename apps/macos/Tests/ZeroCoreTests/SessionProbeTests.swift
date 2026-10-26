import Foundation
import Testing
@testable import ZeroCore

/// Probe against the real ~/.claude and Solo. `ZERO_SESSION_PROBE=1 swift test --filter sessionProbe`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_SESSION_PROBE"] != nil))
func sessionProbeFindsLocalFile() async throws {
    let prompt = "Reply with the single word ready, then stop."
    let cwd = "/Users/arsen/Documents/personal/zero"
    print("encoded:", String(decoding: try JSONEncoder().encode(prompt), as: UTF8.self))
    print("folder exists:", FileManager.default.fileExists(atPath: ClaudeSessions.folder(for: cwd).path))
    print("local find:", ClaudeSessions.find(prompt: prompt, cwd: cwd) ?? "nil")
    let agent = AgentIdentity(name: "p", host: "mac", soloProcessID: 121, soloProjectID: 13)
    print("adapter session:", await SoloAdapter().session(for: agent, firstPrompt: prompt) ?? "nil")
}
