import Testing
@testable import ZeroCore

@MainActor @Test func cliCallsJoinTheAgentZeroStartedOnTheSameProcess() {
    let store = Store(logURL: nil, adapters: [])
    _ = store.create(Ask(kind: .note, title: "Started", agent: AgentIdentity(name: "claude-7", host: "mac", soloProcessID: 7, soloProjectID: 13)))
    let note = store.create(Ask(kind: .note, title: "Update", body: "Specs green", agent: AgentIdentity(name: "solo-7", host: "mac", soloProcessID: 7)))
    #expect(note.agent.name == "claude-7")
    #expect(note.agent.soloProjectID == 13)
}
