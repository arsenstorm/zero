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
