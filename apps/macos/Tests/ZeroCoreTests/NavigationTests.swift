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
        .home, .inbox, .board, .task("01a1:x"), .agent("claude-7"), .settings, .pads, .pad("5bz"),
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

/// Opening Settings on a page (the gear with Health's dot, a link) is one step: back goes to where it was opened from.
@MainActor @Test func backFromSettingsOpenedOnAPageIsWhereItWasOpenedFrom() {
    let navigation = Navigation()
    navigation.place = .task("t1")
    navigation.openSettings("General", section: "health")
    #expect(navigation.place == .settings && navigation.settingsPage == "General" && navigation.settingsSection == "health")
    navigation.goBack()
    #expect(navigation.place == .task("t1"))
    navigation.goForward()
    navigation.openSettings("Git") // in Settings already: the page is a step
    navigation.goBack()
    #expect(navigation.place == .settings && navigation.settingsPage == "General")
}

/// A worker opened by its own id (a link, an inbox card, a report) is its lead's page with it shown, as the sidebar opens
/// it: one step back goes to where you were.
@MainActor @Test func aWorkerOpenedByItsIdIsShownOnItsLeadsPage() {
    let navigation = Navigation()
    navigation.leadOf = { $0 == "w1" ? "lead" : nil }
    navigation.place = .task("other")
    navigation.place = .task("w1")
    #expect(navigation.place == .task("lead"))
    #expect(navigation.worker == "w1")
    navigation.goBack()
    #expect(navigation.place == .task("other"))
    #expect(navigation.worker == nil)
    // On the lead's page already: only the worker changes, a step of its own.
    navigation.place = .task("lead")
    navigation.place = .task("w1")
    #expect(navigation.place == .task("lead") && navigation.worker == "w1")
    navigation.goBack()
    #expect(navigation.place == .task("lead") && navigation.worker == nil)
}

/// Integrations left the rail for Settings: a window last there opens on Settings' first integration.
@MainActor @Test func theOldIntegrationsPlaceOpensSettings() {
    UserDefaults.standard.set("integrations", forKey: "place")
    let navigation = Navigation(restoring: true)
    #expect(navigation.place == .settings && navigation.settingsPage == "GitHub")
}

/// Opened again where it was (after an update or a quit): that's where the history starts, nothing behind it.
@MainActor @Test func aRestoredWindowHasNoWayBack() {
    UserDefaults.standard.set("task:zero", forKey: "place")
    UserDefaults.standard.set("w1", forKey: "placeWorker")
    let navigation = Navigation(restoring: true)
    #expect(navigation.place == .task("zero"))
    #expect(!navigation.canGoBack && !navigation.canGoForward)
    UserDefaults.standard.removeObject(forKey: "placeWorker")
}

/// The toolbar's arrows are drawn from canGoBack and canGoForward: a step taken (or retraced) redraws them, else they
/// stay as they were first drawn, dimmed, and do nothing.
@MainActor @Test func theArrowsAreToldWhenTheHistoryChanges() {
    let navigation = Navigation()
    func changes(_ step: () -> Void) -> Bool {
        var changed = false
        withObservationTracking {
            _ = (navigation.canGoBack, navigation.canGoForward)
        } onChange: {
            changed = true
        }
        step()
        return changed
    }
    #expect(changes { navigation.place = .later })
    #expect(changes { navigation.goBack() })
    #expect(changes { navigation.goForward() })
    #expect(changes { navigation.place = .pads })
    #expect(changes { navigation.openSettings("Git") })
    #expect(changes { navigation.settingsPage = "Folders" })
}

/// Every place the rail and the window go is a step: the pages, a pad, a loop, Later's items, a new workspace.
@MainActor @Test func everyPlaceIsAStep() {
    let navigation = Navigation()
    let places: [Navigation.Place] = [
        .task("t"), .board, .later, .laterItem("l"), .pads, .pad("p"), .loops, .loop("n"), .inbox, .agent("a"),
        .newWorkspace, .settings, .home,
    ]
    for place in places { navigation.place = place }
    for place in places.dropLast().reversed() {
        navigation.goBack()
        #expect(navigation.place == place)
    }
    #expect(navigation.place == .task("t"))
    navigation.goBack()
    #expect(navigation.place == .home && !navigation.canGoBack)
}

/// A trackpad's two-finger scroll, sideways, goes back (fingers to the right) or forward, once a gesture; anything
/// else is left to the views.
@Test func aSidewaysGestureIsOneStep() {
    var swipe = PageSwipe()
    #expect(swipe.scroll(began: true, momentum: false, fingers: 2, dy: 0, free: true) == nil, "too little to tell")
    #expect(swipe.scroll(began: false, momentum: false, fingers: 10, dy: 1, free: true) == 0, "sideways: Zero's")
    #expect(swipe.scroll(began: false, momentum: false, fingers: 60, dy: 0, free: true) == -1, "far enough: back")
    #expect(swipe.scroll(began: false, momentum: false, fingers: 60, dy: 0, free: true) == 0, "once a gesture")
    #expect(swipe.scroll(began: false, momentum: true, fingers: 30, dy: 0, free: true) == 0, "its momentum too")

    #expect(swipe.scroll(began: true, momentum: false, fingers: -20, dy: 0, free: true) == 0)
    #expect(swipe.scroll(began: false, momentum: false, fingers: -60, dy: 0, free: true) == 1, "fingers left: forward")
}

@Test func aScrollThatIsntSidewaysIsLeftToTheViews() {
    var swipe = PageSwipe()
    #expect(swipe.scroll(began: true, momentum: false, fingers: 4, dy: 20, free: true) == nil, "down the page")
    #expect(swipe.scroll(began: false, momentum: false, fingers: 200, dy: 0, free: true) == nil, "still a scroll")
    #expect(swipe.scroll(began: false, momentum: true, fingers: 200, dy: 0, free: true) == nil)

    // Over something that scrolls sideways (a table, code, the side panel's page), the gesture is its own.
    #expect(swipe.scroll(began: true, momentum: false, fingers: 40, dy: 0, free: false) == nil)
    #expect(swipe.scroll(began: false, momentum: false, fingers: 200, dy: 0, free: false) == nil)
}
