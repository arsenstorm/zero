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

/// Swift's decoder skips keys it doesn't know, so a field zerod adds would pass the test above unseen: every key in
/// zerod's conversations has to be one the Swift model declares.
@Test(arguments: recordings) func theAppKnowsEveryFieldZerodSends(_ name: String) throws {
    let data = try Data(contentsOf: wire.appendingPathComponent("\(name).conversation.json"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    // The model's own properties, by reflection, so the list can't drift from the code.
    let known = Set(Swift.Mirror(reflecting: Conversation(id: "", provider: .codex, cwd: "")).children.compactMap(\.label))
    #expect(Set(json.keys).subtracting(known).isEmpty, "zerod sends \(Set(json.keys).subtracting(known)) that the app doesn't read")
    // Fields zerod leaves out until they have something in them.
    let whenSet: Set<String> = ["attributes"]
    #expect(known.subtracting(json.keys).isSubset(of: whenSet), "the app expects \(known.subtracting(json.keys).subtracting(whenSet)) that zerod no longer sends")
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

/// zerod's attention table (crates/zerod/tests/wire.rs): conversations in every state the bar shows, decoded here,
/// with the attention zerod gives each. The app's dot must say the same.
@Test func theAppsAttentionIsZerods() throws {
    struct Case: Decodable { let name: String; let attention: Attention; let conversation: Conversation }
    let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: wire.appendingPathComponent("attention.json")))
    #expect(cases.count == 10)
    for c in cases { #expect(c.conversation.attention == c.attention, "\(c.name)") }
    let question = try #require(cases.first { $0.name == "question" }?.conversation.questions.first)
    #expect(question.fields.first?.options.map(\.label) == ["Redis", "Postgres"])
    #expect(cases.first { $0.name == "limited" }?.conversation.usage?.resetsAt == 1793030000)
    #expect(cases.first { $0.name == "failed" }?.conversation.failure?.kind == .signIn)
}

@Test func aSwitchPutsTheConversationOnAnotherProvider() throws {
    let change = try JSONDecoder().decode(Change.self, from: Data(#"{"type":"switched","provider":"codex","model":"gpt-6-sol","effort":null}"#.utf8))
    var conversation = Conversation(id: "s", provider: .claude, cwd: "/")
    conversation.apply(.thread("claude-thread", model: "opus", effort: "high"))
    conversation.apply(change)
    #expect((conversation.provider, conversation.thread, conversation.model, conversation.effort) == (.codex, nil, "gpt-6-sol", nil))
    #expect(conversation.items.last == ConversationItem(id: "switched-2", turn: nil, kind: .notice(text: "Continued in Codex", error: false), status: .done),
            "the same item zerod adds, by the same id")
}

@Test func aTaskGoesToItsTerminalAndBack() throws {
    var conversation = Conversation(id: "s", provider: .claude, cwd: "/")
    conversation.apply(try JSONDecoder().decode(Change.self, from: Data(#"{"type":"terminal","terminal":{"id":"term-1","mark":3}}"#.utf8)))
    #expect(conversation.terminal == Opened(id: "term-1", mark: 3))
    conversation.apply(try JSONDecoder().decode(Change.self, from: Data(#"{"type":"terminal","terminal":null}"#.utf8)))
    #expect(conversation.terminal == nil)
}
