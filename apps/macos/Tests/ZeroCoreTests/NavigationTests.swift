import Testing
@testable import ZeroCore

@MainActor @Test func backAndForwardRetraceWhereTheWindowWent() {
    let navigation = Navigation()
    #expect(!navigation.canGoBack && !navigation.canGoForward)
    navigation.place = .board
    navigation.place = .task("a")
    navigation.place = .task("a") // staying put isn't a step
    navigation.goBack()
    #expect(navigation.place == .board)
    navigation.goBack()
    #expect(navigation.place == .home)
    navigation.goBack() // nothing further back
    #expect(navigation.place == .home)
    #expect(!navigation.canGoBack && navigation.canGoForward)
    navigation.goForward()
    #expect(navigation.place == .board)
    navigation.place = .settings // a new step drops what was ahead
    navigation.goForward()
    #expect(navigation.place == .settings)
    navigation.goBack()
    #expect(navigation.place == .board)
}

@Test func aPlaceIsKeptAsAWordAndComesBackTheSame() {
    let places: [Navigation.Place] = [.home, .inbox, .board, .task("01a1:x"), .agent("claude-7"), .settings, .integrations, .integration("github"), .pads, .pad("5bz")]
    for place in places { #expect(Navigation.Place(key: place.key) == place) }
    #expect(Navigation.Place(key: "nowhere") == nil)
}
