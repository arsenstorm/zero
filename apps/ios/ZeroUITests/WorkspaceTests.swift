import XCTest

/// Workspaces on the phone (`-homeTest`: three workspaces, tasks and notes in two, no Mac): chosen from the menu's
/// heading, Tasks and Later then show that workspace's alone; the Inbox is every workspace's.
final class WorkspaceTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-homeTest"]
        app.launch()
    }

    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/vb/ws-\(name).png"))
    }

    func testTasksAndLaterFollowTheWorkspaceChosen() {
        app.buttons["Tasks"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Zero's first task"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["A client's task"].exists, "another workspace's task isn't listed")

        app.buttons["Menu"].firstMatch.tap()
        let heading = app.buttons["Zero"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 2), "the menu's heading is the workspace shown")
        shot("menu")
        heading.tap()
        let client = app.buttons["Client work"].firstMatch
        XCTAssertTrue(client.waitForExistence(timeout: 2), "the workspaces, listed in the menu")
        shot("choosing")
        client.tap()

        XCTAssertTrue(app.staticTexts["A client's task"].waitForExistence(timeout: 3), "its tasks")
        XCTAssertFalse(app.staticTexts["Zero's first task"].exists, "and not Zero's")
        shot("tasks")

        app.buttons["Later"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["A client's note"].waitForExistence(timeout: 3), "its notes")
        XCTAssertFalse(app.staticTexts["A note of Zero's"].exists, "and not Zero's")
    }
}
