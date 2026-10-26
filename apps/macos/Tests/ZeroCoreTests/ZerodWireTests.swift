import Foundation
import Testing
@testable import ZeroCore

/// The wire contract with zerod: crates/zerod/tests/wire.rs writes, for each recorded session, the events zerod
/// sends and the conversation they end in. Applied here, the same events must end in the same conversation.
private let wire = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../crates/zerod/tests/wire").standardized

private let recordings = ["codex-command", "codex-file-change", "claude-command", "claude-command-approval", "claude-file-change",
                          "opencode-command", "opencode-file-change", "opencode-approval", "opencode-refused"]

@Test(arguments: recordings) func applyingZerodsEventsEndsInItsConversation(_ name: String) throws {
    let expected = try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: wire.appendingPathComponent("\(name).conversation.json")))
    let lines = try String(contentsOf: wire.appendingPathComponent("\(name).events.jsonl"), encoding: .utf8).split(separator: "\n")
    var mirror = ZerodMirror()
    mirror.receive(.session(Conversation(id: "s1", provider: expected.provider, cwd: "/work/project")))
    for line in lines {
        let followed = mirror.receive(.change(try JSONDecoder().decode(ZerodEvent.self, from: Data(line.utf8))))
        #expect(followed, "\(name): \(line.prefix(80))")
    }
    #expect(mirror.conversations["s1"] == expected)
    #expect(expected.items.isEmpty == false)
}

@Test func everyKindOfItemDecodes() throws {
    let json = """
    [{"id":"a","turn":null,"status":"running","kind":{"type":"tool","name":"Read","detail":"a.rs"}},
     {"id":"b","turn":"u","status":"done","kind":{"type":"plan","text":"- [x] one"}},
     {"id":"c","turn":null,"status":"failed","kind":{"type":"command","command":"make","cwd":"/","output":"no","exitCode":2,"durationMs":null}},
     {"id":"d","turn":null,"status":"declined","kind":{"type":"fileChange","changes":[{"path":"/a","kind":"update","movePath":"/b","diff":"-a\\n+b\\n"}]}},
     {"id":"e","turn":null,"status":"done","kind":{"type":"notice","text":"Interrupted","error":false}}]
    """
    let items = try JSONDecoder().decode([ConversationItem].self, from: Data(json.utf8))
    #expect(items[0].kind == .tool(name: "Read", detail: "a.rs"))
    #expect(items[1].kind == .plan(text: "- [x] one"))
    #expect(items[2].kind == .command(command: "make", cwd: "/", output: "no", exitCode: 2, durationMs: nil))
    #expect(items[2].status == .failed)
    #expect(items[3].kind == .fileChange([FileChange(path: "/a", kind: "update", movePath: "/b", diff: "-a\n+b\n")]))
    #expect(items[4].kind == .notice(text: "Interrupted", error: false))
}

@Test func anItemZeroDoesNotKnowYetStillDecodes() throws {
    let json = #"{"id":"x","turn":null,"status":"done","kind":{"type":"hologram","depth":3}}"#
    let item = try JSONDecoder().decode(ConversationItem.self, from: Data(json.utf8))
    #expect(item.kind == .notice(text: "An item Zero can't show yet (hologram)", error: false))
}
