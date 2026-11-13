import CoreGraphics
import Testing
@testable import ZeroCore

/// A submenu 100 pt right of the pointer, rows 0–200 tall in window coordinates (top left origin).
private let submenu = CGRect(x: 220, y: 40, width: 180, height: 160)

@Test func headingRightIntoTheSubmenuKeepsIt() {
    #expect(MenuAim.heading(from: CGPoint(x: 120, y: 50), to: CGPoint(x: 130, y: 60), menu: submenu, leading: false))
    #expect(MenuAim.heading(from: CGPoint(x: 120, y: 190), to: CGPoint(x: 130, y: 180), menu: submenu, leading: false))
}

@Test func movingStraightDownOrAwayIsNotHeading() {
    #expect(!MenuAim.heading(from: CGPoint(x: 120, y: 50), to: CGPoint(x: 120, y: 80), menu: submenu, leading: false))
    #expect(!MenuAim.heading(from: CGPoint(x: 120, y: 50), to: CGPoint(x: 110, y: 50), menu: submenu, leading: false))
    #expect(!MenuAim.heading(from: CGPoint(x: 120, y: 50), to: CGPoint(x: 120, y: 50), menu: submenu, leading: false))
}

@Test func aSubmenuOnTheLeftIsHeadedForLeftward() {
    let left = CGRect(x: 0, y: 40, width: 180, height: 160)
    #expect(MenuAim.heading(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 290, y: 105), menu: left, leading: true))
    #expect(!MenuAim.heading(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 310, y: 105), menu: left, leading: true))
}

/// The bar on the screen's right edge, the inbox's panel left of it (screen coordinates, as AppKit gives them).
private let bar = CGRect(x: 1456, y: 400, width: 44, height: 120)
private let panel = CGRect(x: 1064, y: 300, width: 380, height: 320)

@Test func theBarAndThePanelHoldTheInbox() {
    #expect(MenuAim.holds(CGPoint(x: 1478, y: 460), from: nil, bar: bar, panel: panel))
    #expect(MenuAim.holds(CGPoint(x: 1200, y: 600), from: nil, bar: bar, panel: panel))
}

@Test func headingLeftFromTheBarToThePanelHoldsIt() {
    #expect(MenuAim.holds(CGPoint(x: 1450, y: 470), from: CGPoint(x: 1460, y: 465), bar: bar, panel: panel))
}

@Test func leavingUpOrAwayLetsTheInboxGo() {
    // Up past the bar's top, up the gap past the panel's top, and in the gap with no move to read.
    #expect(!MenuAim.holds(CGPoint(x: 1478, y: 530), from: CGPoint(x: 1478, y: 515), bar: bar, panel: panel))
    #expect(!MenuAim.holds(CGPoint(x: 1450, y: 700), from: CGPoint(x: 1450, y: 690), bar: bar, panel: panel))
    #expect(!MenuAim.holds(CGPoint(x: 1450, y: 470), from: nil, bar: bar, panel: panel))
}
