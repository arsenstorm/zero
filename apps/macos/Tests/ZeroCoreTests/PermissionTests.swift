import Foundation
import Testing
@testable import ZeroCore

@Test func permissionRequestsBecomeAsksWithTheAgentsReason() throws {
    let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("permission-\(UUID()).jsonl")
    let lines = [
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Old words."}]}}"#,
        #"{"type":"user","message":{"content":"go"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"The cache is stale, so I'll clear it."},{"type":"tool_use","name":"Bash"}]}}"#,
    ]
    try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
    let hook = """
        {"tool_name":"Bash","tool_input":{"command":"rm -rf tmp/cache","description":"Clear the cache"},"cwd":"/tmp","transcript_path":"\(transcript.path)"}
        """
    let ask = try #require(Ask.permission(hook: Data(hook.utf8), agent: AgentIdentity(name: "a", host: "mac"), ttl: 60))
    #expect(ask.kind == .permission)
    #expect(ask.title == "Clear the cache")
    #expect(ask.command == "rm -rf tmp/cache")
    #expect(ask.body == "The cache is stale, so I'll clear it.")
    #expect(ask.options == ["Allow", "Deny", "Deny, and say why…"])
    let edit = Ask.permission(
        hook: Data(#"{"tool_name":"Edit","tool_input":{"file_path":"/a/b.swift"}}"#.utf8), agent: AgentIdentity(name: "a", host: "mac"),
        ttl: 60)
    #expect(edit?.title == "Edit a file" && edit?.command == "/a/b.swift" && edit?.body == "")
}
