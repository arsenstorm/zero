import Foundation
import Testing
@testable import ZeroCore

private func ask(_ options: [String]) -> Ask {
    Ask(kind: .choice, title: "Ship it?", options: options, agent: AgentIdentity(name: "a", host: "mac"))
}

@Test func aSpokenAnswerPicksTheOptionItNames() {
    let shipIt = ask(["Yes (Recommended)", "No", "Something else…"])
    #expect(shipIt.spoken("yes") == .option(0))
    #expect(shipIt.spoken("No.") == .option(1))
    // Words that aren't an option go in the option that asks for words.
    #expect(shipIt.spoken("wait until Monday") == .words(2, "wait until Monday"))
    // Only fixed options: nothing to answer with.
    #expect(ask(["Yes", "No"]).spoken("maybe") == nil)
    // No options: a reply.
    #expect(ask([]).spoken("Use the staging database") == .reply("Use the staging database"))
    #expect(ask([]).spoken("  ") == nil)
}
