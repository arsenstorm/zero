import Testing
@testable import ZeroCore

/// zerod's words for the agent about what it follows, read back as things and their events for the conversation.
@Test func eventsReadAsThingsAndTheirEvents() {
    let text = """
        2 new events on what you follow:

        github/acme/web/19269  —  ENG-9378 [Opus 5.5] Search shows an incident's linked tickets (open, draft)
        https://github.com/acme/web/pull/19269
          CI success: 25 passed, 0 failed, 25 total
            https://github.com/acme/web/pull/19269/checks
          review by dana (you: possibly your own action echoing back)
            Looks good.
            Ship it.
            https://github.com/acme/web/pull/19269#review-1

        slack/C01
          new message
        """
    let groups = FollowEvents.parse(text)
    #expect(groups.count == 2)
    #expect(groups[0].name == "web#19269")
    #expect(groups[0].title == "ENG-9378 [Opus 5.5] Search shows an incident's linked tickets (open, draft)")
    #expect(groups[0].url == "https://github.com/acme/web/pull/19269")
    #expect(groups[0].events.map(\.summary) == ["CI success: 25 passed, 0 failed, 25 total", "review by dana"])
    #expect(groups[0].events[0].url == "https://github.com/acme/web/pull/19269/checks" && groups[0].events[0].body.isEmpty)
    #expect(groups[0].events[1].mine && groups[0].events[1].body == "Looks good.\nShip it.")
    #expect(groups[1].name == "C01" && groups[1].title == "" && groups[1].events.map(\.summary) == ["new message"])
    #expect(FollowEvents.parse("Worker ENG-1 is waiting.").isEmpty)
}
