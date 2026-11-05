import Foundation
import Testing
@testable import ZeroCore

@Test func rexIdsAndLabelsAreReadFromItsOutput() {
    #expect(RexAdapter.blockID(in: #"{"block_ids":["block:01a16439-704d-7121-ac95-65fb4ece04a5"]}"#) == "block:01a16439-704d-7121-ac95-65fb4ece04a5")
    #expect(AgentCommand.label(for: "Fix the login redirect on the billing page please") == "Fix the login redirect on the")
    #expect(AgentCommand.label(for: "  ") == "Zero agent")
}

@Test func resumingDropsTheOldResumeAndAddsTheSession() throws {
    var agent = AgentIdentity(name: "claude-abc123", host: "mac", cwd: "/tmp")
    agent.session = "new-session"
    agent.launch = ["claude", "--model", "haiku", "--resume", "old-session"]
    #expect(try AgentCommand.resume(agent) == ["claude", "--model", "haiku", "--resume", "new-session"])
}

/// Starts a real Claude agent in the folder named by ZERO_SPAWN (in Zero's own terminals; in Rex too when
/// ZERO_REX_SPAWN is set), reads its reply, stops it, resumes it, and closes its terminal. Costs a launch and two
/// short turns on Haiku each. Zero's terminals need zero-host running (`.build/debug/zero-host`).
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_SPAWN"] != nil))
func ownTerminalAgentStartsRepliesStopsAndResumes() async throws {
    let folder = ProcessInfo.processInfo.environment["ZERO_SPAWN"]!
    let resumed = try await startReplyStopResume(HostAdapter(), runtime: "zero:claude", in: folder)
    _ = await HostLink.call(HostLink.Request(op: "close", id: resumed.ref))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_REX_SPAWN"] != nil))
func rexAgentStartsRepliesStopsAndResumes() async throws {
    let folder = ProcessInfo.processInfo.environment["ZERO_REX_SPAWN"]!
    let resumed = try await startReplyStopResume(RexAdapter(), runtime: "rex:claude", in: folder)
    if let group = resumed.refGroup { _ = await RexAdapter.rex(["kill", group]) }
}

private func startReplyStopResume(_ adapter: some TerminalAdapter, runtime: String, in folder: String) async throws -> AgentIdentity {
    let prompt = "Reply with the single word ok and nothing else"
    let model = SpawnChoice(id: "claude-haiku-5-5", name: "Haiku", provider: "Anthropic")
    var agent = try await adapter.spawn(prompt: prompt, target: SpawnChoice(id: folder, name: "test"),
                                        runtime: SpawnChoice(id: runtime, name: "Claude", provider: "Anthropic"), model: model,
                                        settings: ["reasoning": "low"])
    let reply = await adapter.reply(from: agent, to: prompt)
    #expect(reply?.lowercased().contains("ok") == true, "reply: \(reply ?? "none")")
    #expect(await adapter.offline(among: [agent]).isEmpty)
    agent.session = await adapter.session(for: agent, firstPrompt: prompt)
    #expect(agent.session != nil)
    await adapter.stop(agent)
    try await Task.sleep(for: .seconds(4))
    #expect(await adapter.offline(among: [agent]) == [agent.name])
    let resumed = try await adapter.connect(agent)
    #expect(resumed.ref != agent.ref)
    #expect(await adapter.offline(among: [resumed]).isEmpty)
    return resumed
}
