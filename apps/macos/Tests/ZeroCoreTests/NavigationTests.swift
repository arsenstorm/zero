import Foundation
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
    let places: [Navigation.Place] = [
        .home, .inbox, .board, .task("01a1:x"), .agent("claude-7"), .settings, .integrations, .integration("github"), .pads, .pad("5bz"),
    ]
    for place in places { #expect(Navigation.Place(key: place.key) == place) }
    #expect(Navigation.Place(key: "nowhere") == nil)
}

@MainActor @Test func aWorkspaceOpensOnTheTaskLastOpenInIt() {
    UserDefaults.standard.removeObject(forKey: "lastTasks")
    let navigation = Navigation()
    navigation.place = .task("a")
    navigation.remember("a", worker: nil, in: "zero")
    navigation.place = .task("b")
    navigation.worker = "b-1"
    navigation.remember("b", worker: "b-1", in: "work")
    navigation.arrive(in: "zero") { _ in true }
    #expect(navigation.place == .task("a") && navigation.worker == nil)
    navigation.arrive(in: "work") { _ in true }
    #expect(navigation.place == .task("b") && navigation.worker == "b-1", "the worker that was shown, too")
    navigation.arrive(in: "zero") { $0 != "a" }
    #expect(navigation.place == .home, "archived (or moved away): a new task instead")
    navigation.arrive(in: "personal") { _ in true }
    #expect(navigation.place == .home, "never opened one there: a new task")
    navigation.place = .settings
    navigation.arrive(in: "work") { _ in true }
    #expect(navigation.place == .settings, "away from tasks: left where it is")
}

/// Settings' pages are steps too: back from Git is the page before it, then the task Settings was opened from.
@MainActor @Test func backGoesThroughSettingsPagesBeforeLeavingSettings() {
    let navigation = Navigation()
    navigation.place = .task("t1")
    navigation.place = .settings
    navigation.settingsPage = "Folders"
    navigation.settingsPage = "Git"
    navigation.goBack()
    #expect(navigation.place == .settings && navigation.settingsPage == "Folders")
    navigation.goForward()
    #expect(navigation.place == .settings && navigation.settingsPage == "Git")
    navigation.goBack(); navigation.goBack()
    #expect(navigation.place == .settings, "the page Settings opened on")
    navigation.goBack()
    #expect(navigation.place == .task("t1"))
}
