import Foundation
import Testing
@testable import ZeroCore

@Test func rexIdsAndLabelsAreReadFromItsOutput() {
    #expect(RexAdapter.blockID(in: #"{"block_ids":["block:01a16439-704d-7121-ac95-65fb4ece04a5"]}"#) == "block:01a16439-704d-7121-ac95-65fb4ece04a5")
    #expect(RexAdapter.label(for: "Fix the login redirect on the billing page please") == "Fix the login redirect on the")
    #expect(RexAdapter.label(for: "  ") == "Zero agent")
}

/// Starts a real Claude agent through Rex in the folder named by ZERO_REX_SPAWN, reads its reply, stops it,
/// resumes it, and closes its session. Costs a launch and two short turns on Haiku.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ZERO_REX_SPAWN"] != nil))
func rexAgentStartsRepliesStopsAndResumes() async throws {
    let folder = ProcessInfo.processInfo.environment["ZERO_REX_SPAWN"]!
    let rex = RexAdapter()
    let prompt = "Reply with the single word ok and nothing else"
    let runtime = SpawnChoice(id: "rex:claude", name: "Claude", provider: "Anthropic")
    let model = SpawnChoice(id: "claude-haiku-5-5", name: "Haiku", provider: "Anthropic")
    var agent = try await rex.spawn(prompt: prompt, target: SpawnChoice(id: folder, name: "test"), runtime: runtime, model: model,
                                    settings: ["reasoning": "low"])
    let reply = await rex.reply(from: agent, to: prompt)
    #expect(reply?.lowercased().contains("ok") == true, "reply: \(reply ?? "none")")
    #expect(await rex.offline(among: [agent]).isEmpty)
    agent.session = await rex.session(for: agent, firstPrompt: prompt)
    #expect(agent.session != nil)
    await rex.stop(agent)
    try await Task.sleep(for: .seconds(4))
    #expect(await rex.offline(among: [agent]) == [agent.name])
    let resumed = try await rex.connect(agent)
    #expect(resumed.ref != agent.ref)
    #expect(await rex.offline(among: [resumed]).isEmpty)
    if let group = resumed.refGroup { _ = await RexAdapter.rex(["kill", group]) }
}
