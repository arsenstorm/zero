import Testing
@testable import ZeroCore

private let follow = SettingsEntry(
    id: "follow", page: "Control bar", section: "Placement", title: "Follow the active screen",
    detail: "The bar moves to the screen you use.", keywords: ["display", "monitor"])
private let dock = SettingsEntry(
    id: "dock", page: "Control bar", section: "Placement", title: "Show the bar in Zero's window",
    detail: "Rather than at the screen's edge.", keywords: ["dock", "full screen"])
private let welcome = SettingsEntry(
    id: "welcome", page: "General", section: "Help", title: "Show welcome again", detail: "The welcome screens, as at first launch.",
    keywords: ["onboarding"])
private let compact = SettingsEntry(
    id: "compact", page: "Agents", section: "Advanced", title: "Summarise conversations at",
    detail: "Smaller turns, less usage.", keywords: ["compact", "context"])
private let entries = [welcome, follow, dock, compact]

@Test func eachWordTypedStartsAWordOfTheSetting() {
    #expect(follow.rank("scr") == 0)
    #expect(follow.rank("active scr") == 0)
    #expect(follow.rank("ctive") == nil)
    #expect(follow.rank("active dock") == nil)
}

@Test func caseAndAccentsDontCount() {
    #expect(compact.rank("SUMMARISE") == 0)
    #expect(welcome.rank("wélcome") == 0)
}

@Test func titlesRankBeforeKeywordsAndSectionsBeforeDetails() {
    #expect(follow.rank("follow") == 0)
    #expect(follow.rank("monitor") == 1)
    #expect(follow.rank("placement") == 1)
    #expect(follow.rank("control bar") == 1)
    #expect(follow.rank("moves") == 2)
    #expect(follow.rank("follow moves") == 2)
}

@Test func nothingTypedFindsNothing() {
    #expect(follow.rank("") == nil)
    #expect(follow.rank("  ") == nil)
    #expect(SettingsSearch.results(entries, for: " ").isEmpty)
}

@Test func resultsComeByPageTheBestMatchsPageFirst() {
    // "screen" is in Follow's title, but only in the details of Welcome and Dock.
    let results = SettingsSearch.results(entries, for: "screen")
    #expect(results.map(\.page) == ["Control bar", "General"])
    #expect(results[0].entries == [follow, dock])
    #expect(results[1].entries == [welcome])
}

@Test func equalMatchesKeepTheIndexsOrder() {
    #expect(SettingsSearch.results(entries, for: "show").map(\.entries) == [[welcome], [dock]])
}

@Test func aKeywordFindsWhatItsTitleDoesnt() {
    #expect(SettingsSearch.results(entries, for: "compact").map(\.entries) == [[compact]])
}
