import XCTest

/// The share sheet from Photos, unpaired in the Simulator (its sample tasks): screenshots to look at, nothing asserted
/// past it opening.
final class ShareSheetTests: XCTestCase {
    func testShareSheetFromPhotos() throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Don’t Allow"].waitForExistence(timeout: 3) { springboard.buttons["Don’t Allow"].tap() }
        if springboard.buttons["Don't Allow"].exists { springboard.buttons["Don't Allow"].tap() }
        XCTAssertTrue(photos.buttons["Select"].waitForExistence(timeout: 10))
        photos.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        sleep(2)
        let share = photos.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        let zero = photos.descendants(matching: .any).matching(NSPredicate(format: "label == 'Zero'")).firstMatch
        XCTAssertTrue(zero.waitForExistence(timeout: 8), "Zero in the share sheet")
        zero.tap()
        sleep(3)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/share-a.png"))
        photos.buttons.matching(NSPredicate(format: "label CONTAINS 'Server status dashboard'")).firstMatch.tap()
        sleep(1)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/share-b.png"))
        // On the pill, at the row's start (the row is the full width; the pill, its first 140 pt).
        photos.buttons["Pick a folder"].coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 60, dy: 0)).tap()
        sleep(3)
        XCTAssertTrue(photos.buttons["hallow"].exists, "the places, under the pill")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/share-c.png"))
        photos.buttons["hallow"].coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 60, dy: 0)).tap()
        sleep(1)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/share-d.png"))
        XCTAssertFalse(photos.buttons["site"].exists, "closed once picked")
        XCTAssertTrue(photos.buttons["hallow"].exists, "the pill says the place picked")
    }
}
