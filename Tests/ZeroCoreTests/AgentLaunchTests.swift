import Foundation
import Testing
@testable import ZeroCore

@Test func launchFilesHoldTheTokenOnlyUntilScrubbed() throws {
    let email = "launch-test-\(UUID().uuidString)@example.com"
    defer { AgentLaunch.delete(email) }
    #expect(AgentLaunch.arm(email) == nil) // no token, no launch
    #expect(AgentLaunch.save("sk-ant-oat01-test", for: email))
    let path = try #require(AgentLaunch.arm(email))
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try String(contentsOfFile: path, encoding: .utf8).contains("sk-ant-oat01-test"))
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    AgentLaunch.scrub(path)
    let scrubbed = try String(contentsOfFile: path, encoding: .utf8)
    #expect(!scrubbed.contains("sk-ant") && scrubbed.contains("ZERO_MANAGED"))
    #expect(AgentLaunch.file(in: ["--model", "x", "--settings", path, "--resume", "s"]) == path)
    #expect(AgentLaunch.file(in: ["--settings", #"{"env":{}}"#]) == nil)
}
