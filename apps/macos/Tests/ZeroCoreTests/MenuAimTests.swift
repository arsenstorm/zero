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
