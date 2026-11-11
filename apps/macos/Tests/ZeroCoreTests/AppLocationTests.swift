import XCTest
@testable import ZeroCore

final class AppLocationTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")
    func moves(_ path: String, git: Bool = false) -> Bool {
        AppLocation.needsMove(URL(fileURLWithPath: path), home: home) { $0.hasSuffix("/.git") && git }
    }

    func testInApplicationsItStays() {
        XCTAssertFalse(moves("/Applications/Zero.app"))
        XCTAssertFalse(moves("/Applications/Tools/Zero.app"))
        XCTAssertFalse(moves("/Users/someone/Applications/Zero.app"))
    }

    func testAnywhereElseItMoves() {
        XCTAssertTrue(moves("/Users/someone/Downloads/Zero.app"))
        XCTAssertTrue(moves("/Volumes/Zero/Zero.app"))
        XCTAssertTrue(moves("/Users/someone/Desktop/build/Zero.app"))
        XCTAssertTrue(moves("/Users/other/Applications/Zero.app"))
    }

    func testDevelopmentBuildsStay() {
        XCTAssertFalse(moves("/Users/someone/zero/build/Zero.app", git: true))
        XCTAssertFalse(moves("/Users/someone/zero/apps/macos/.build/debug"))
    }
}
