import Testing
@testable import ZeroCore

@Test func asksForYouLeaveOutNotesMessagesExpiredAndSharedRuns() {
    func ask(_ kind: AskKind, _ state: AskState = .waiting, sameAs: String? = nil) -> Ask {
        var ask = Ask(kind: kind, title: "t", agent: AgentIdentity(name: "a", host: "mac"))
        ask.state = state; ask.sameAs = sameAs
        return ask
    }
    #expect(ask(.question).isForYou)
    #expect(ask(.run, .running).isForYou)
    #expect(ask(.choice, .answered).isForYou)
    #expect(ask(.approve, .declined).isForYou)
    #expect(ask(.permission, .pending).isForYou)
    #expect(!ask(.note).isForYou)
    #expect(!ask(.message).isForYou)
    #expect(!ask(.question, .expired).isForYou)
    #expect(!ask(.run, sameAs: "abc123").isForYou)
}
