import Foundation
import Testing
@testable import ZeroCore

/// The side panel's tabs, widths and address bar.

@Test func aNewTabReusesTheBlankOne() {
    var tabs = PanelTabs()
    tabs.newTab()
    let blank = tabs.selected
    tabs.selected = nil
    tabs.newTab()
    #expect(tabs.tabs.count == 1)
    #expect(tabs.selected == blank)
}

@Test func openingAPageFillsTheBlankTabShownOrGoesToItsTab() {
    var tabs = PanelTabs()
    tabs.newTab()
    tabs.open("https://a.example")
    #expect(tabs.tabs.map(\.url) == ["https://a.example"])
    tabs.open("https://b.example")
    tabs.open("https://a.example")
    #expect(tabs.tabs.count == 2)
    #expect(tabs.shown?.url == "https://a.example")
}

@Test func closingShowsTheNextTabThenDetailsAndKeepsThePage() {
    var tabs = PanelTabs()
    tabs.open("https://a.example"); tabs.open("https://b.example"); tabs.open("https://c.example")
    let (a, b) = (tabs.tabs[0].id, tabs.tabs[1].id)
    tabs.selected = b
    tabs.close(b)
    #expect(tabs.shown?.url == "https://c.example")
    tabs.close(tabs.selected!)
    #expect(tabs.selected == a)
    tabs.close(a)
    #expect(tabs.selected == nil)
    #expect(tabs.closed.map(\.url) == ["https://a.example", "https://c.example", "https://b.example"])
}

@Test func onlyTheLastFiveClosedAreKept() {
    var tabs = PanelTabs()
    for index in 0..<7 { tabs.open("https://\(index).example") }
    for tab in tabs.tabs { tabs.close(tab.id) }
    #expect(tabs.closed.count == 5)
    #expect(tabs.closed.first?.url == "https://6.example")
}

@Test func thePanelKeepsBothMinimums() {
    // A wide page: 46%, at most 560.
    #expect(PanelWidth.width(page: 1137, wanted: nil) == 523)
    #expect(PanelWidth.width(page: 2000, wanted: nil) == 560)
    // Dragged too wide: the conversation keeps 400.
    #expect(PanelWidth.width(page: 1137, wanted: 900) == 736)
    // Dragged too narrow, or a page too narrow for both: the panel keeps 320.
    #expect(PanelWidth.width(page: 1137, wanted: 100) == 320)
    #expect(PanelWidth.width(page: 600, wanted: nil) == 320)
    #expect(PanelWidth.windowLeast(sidebar: 250) == 1024)
}

@Test func theAddressBarTellsAddressesFromSearches() {
    #expect(PanelAddress.url(from: "github.com/acme") == "https://github.com/acme")
    #expect(PanelAddress.url(from: "localhost:5173/checkout") == "http://localhost:5173/checkout")
    #expect(PanelAddress.url(from: "http://example.com") == "http://example.com")
    #expect(PanelAddress.url(from: "retry policy") == "https://www.google.com/search?q=retry%20policy")
    #expect(PanelAddress.url(from: "  ") == nil)
}

@MainActor @Test func tabsAndWidthAreKeptAcrossLaunches() {
    let defaults = UserDefaults(suiteName: "panel-tests-\(UUID().uuidString)")!
    let panels = Panels(defaults: defaults)
    panels.change("t1") { $0.open("https://a.example", title: "A") }
    panels.wanted = 480
    let again = Panels(defaults: defaults)
    #expect(again.tabs("t1").tabs.map(\.title) == ["A"])
    #expect(again.wanted == 480)
    #expect(again.tabs("other").tabs.isEmpty)
}

@Test func controlTabGoesRoundTheTabsDetailsFirst() {
    var tabs = PanelTabs()
    tabs.open("https://a.example"); tabs.open("https://b.example")
    let (a, b) = (tabs.tabs[0].id, tabs.tabs[1].id)
    tabs.selected = nil
    tabs.step(1); #expect(tabs.selected == a)
    tabs.step(1); #expect(tabs.selected == b)
    tabs.step(1); #expect(tabs.selected == nil)
    tabs.step(-1); #expect(tabs.selected == b)
}

@Test func tabsGoToIconsOnlyWhenTitlesWontRead() {
    // The default panel at 1440 (523 wide): two tabs keep their titles, five don't.
    #expect(!PanelWidth.compactTabs(strip: 483, tabs: 2))
    #expect(PanelWidth.compactTabs(strip: 483, tabs: 5))
    // The narrowest panel: a second tab is already too many.
    #expect(PanelWidth.compactTabs(strip: 280, tabs: 2))
    #expect(!PanelWidth.compactTabs(strip: 280, tabs: 1))
}

/// Links clicked in the panel: an app's link (Linear's app on or off, Slack's, Zero's own) goes to the app, as the
/// conversation's do; a web page opens in a tab.
@MainActor @Test func panelLinksGoToTheirAppsAndOnlyWebPagesToATab() {
    let acme = Slack.State(team: .init(id: "T0AB", name: "Acme", domain: "acme"), channels: [:])
    func app(_ link: String, linear: Bool = true) -> String? {
        LinkRoute.app(URL(string: link)!, linearApp: linear, slack: [acme])?.absoluteString
    }
    #expect(app("https://linear.app/acme/issue/SHOP-142") == "linear://acme/issue/SHOP-142")
    #expect(app("https://linear.app/acme/issue/SHOP-142", linear: false) == nil)
    #expect(
        app("https://acme.slack.com/archives/C0123/p1700000000123456") == "slack://channel?team=T0AB&id=C0123&message=1700000000.123456")
    #expect(app("https://other.slack.com/archives/C0123") == nil)
    #expect(app("zero://task/01aa") == "zero://task/01aa")
    #expect(app("mailto:a@example.com") == "mailto:a@example.com")
    #expect(app("https://github.com/acme/shop/pull/412") == nil)
    #expect(app("https://example.com") == nil)
}
