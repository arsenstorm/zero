import XCTest

/// The same drags in Messages and in Zero's composer, for screen recordings to measure side by side (the keyboard's top
/// edge in every frame): slow drags of 20, 50 and 80 pt from the text, held before lifting (how much of the finger's
/// travel the keyboard followed), then a quick 420 pt one (the far release). Each step is marked in the test's output.
final class AppleComparisonTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func mark(_ what: String) { print("COMPARE \(what) \(Date().timeIntervalSince1970)") }

    private func keyboardUp(_ app: XCUIApplication) -> Bool {
        app.keyboards.firstMatch.exists && app.keyboards.firstMatch.frame.minY < app.frame.maxY - 50
    }

    /// The drags, from `start` (the text's middle), the keyboard opened again by `open` before each.
    private func drags(_ app: XCUIApplication, start: () -> XCUICoordinate, open: () -> Void) {
        for distance in [20.0, 50.0, 80.0] {
            open()
            pause(1.2)
            mark("slow \(Int(distance)) start, keyboard top \(app.keyboards.firstMatch.frame.minY)")
            let start = start()
            start.press(
                forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: XCUIGestureVelocity(100),
                thenHoldForDuration: 0.6)
            mark("slow \(Int(distance)) lifted, keyboard up \(keyboardUp(app))")
            pause(1.2)
            mark("slow \(Int(distance)) settled, keyboard up \(keyboardUp(app))")
        }
        open()
        pause(1.2)
        mark("far start, keyboard top \(app.keyboards.firstMatch.frame.minY)")
        let start = start()
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: XCUIGestureVelocity(400),
            thenHoldForDuration: 0.1)
        mark("far lifted, keyboard up \(keyboardUp(app))")
        pause(1.5)
        mark("far settled, keyboard up \(keyboardUp(app))")
    }

    func testMessages() {
        let app = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        app.launch()
        pause(2)
        // A conversation (the Simulator's own sample ones): its input bar works without sending anything.
        if !app.textViews["messageBodyField"].exists {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '+1'")).firstMatch.tap()
            pause(1.5)
        }
        // Its field isn't exposed to the tests: aimed at by where it sits, its middle 81 pt above the keyboard's frame
        // as the tests report it (653 pt; the keyboard as drawn starts at 624, the field's middle is at 572: measured in
        // the recording), or above the screen's foot with the keyboard down.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let text = { origin.withOffset(CGVector(dx: 250, dy: app.keyboards.firstMatch.frame.minY - 81)) }
        drags(app, start: text) {
            if !self.keyboardUp(app) { origin.withOffset(CGVector(dx: 250, dy: app.frame.maxY - 62)).tap() }
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        }
        // And from its conversation, 150 pt above the field.
        if !keyboardUp(app) { origin.withOffset(CGVector(dx: 250, dy: app.frame.maxY - 62)).tap() }
        pause(1.5)
        mark("conversation start")
        let above = origin.withOffset(CGVector(dx: 250, dy: app.keyboards.firstMatch.frame.minY - 230))
        above.press(
            forDuration: 0.05, thenDragTo: above.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: XCUIGestureVelocity(400),
            thenHoldForDuration: 0.1)
        mark("conversation lifted, keyboard up \(keyboardUp(app))")
        pause(1.5)
    }

    /// When Messages' swipe on its field fires: an 80 pt drag held 3 s before lifting.
    func testMessagesHold() {
        let app = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        app.launch()
        pause(2)
        if !app.textViews["messageBodyField"].exists {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '+1'")).firstMatch.tap()
            pause(1.5)
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        if !keyboardUp(app) { origin.withOffset(CGVector(dx: 250, dy: app.frame.maxY - 62)).tap() }
        pause(2)
        let start = origin.withOffset(CGVector(dx: 250, dy: app.keyboards.firstMatch.frame.minY - 81))
        mark("hold start")
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 80)), withVelocity: XCUIGestureVelocity(100),
            thenHoldForDuration: 3)
        mark("hold lifted, keyboard up \(keyboardUp(app))")
        pause(2)
    }

    /// The distance Messages' swipe on its field needs: 25 to 45 pt, slowly, held before lifting.
    func testMessagesThreshold() {
        let app = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        app.launch()
        pause(2)
        if !app.textViews["messageBodyField"].exists {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '+1'")).firstMatch.tap()
            pause(1.5)
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for distance in [25.0, 30.0, 35.0, 40.0, 45.0] {
            if !keyboardUp(app) { origin.withOffset(CGVector(dx: 250, dy: app.frame.maxY - 62)).tap() }
            pause(1.2)
            let start = origin.withOffset(CGVector(dx: 250, dy: app.keyboards.firstMatch.frame.minY - 81))
            start.press(
                forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: XCUIGestureVelocity(60),
                thenHoldForDuration: 0.5)
            pause(0.8)
            mark("threshold \(Int(distance)): keyboard up \(keyboardUp(app))")
        }
    }

    /// The same distances in Zero's composer.
    func testZeroThreshold() {
        let app = XCUIApplication()
        app.launchArguments = ["-composerTest"]
        app.launch()
        pause(1.5)
        for distance in [20.0, 25.0, 30.0, 35.0, 40.0, 45.0] {
            if !keyboardUp(app) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap() }
            pause(1.2)
            let start = app.textViews["composer.field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(
                forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: XCUIGestureVelocity(60),
                thenHoldForDuration: 0.5)
            pause(0.8)
            mark("threshold \(Int(distance)): keyboard up \(keyboardUp(app))")
        }
    }

    /// The scenario, step by step, for frame-by-frame recordings of both apps: open, type three lines, swipe closed
    /// from the field, open, drag closed from the conversation, open, send (Zero only: Messages can't send here).
    private func scenario(_ app: XCUIApplication, field: () -> XCUICoordinate, open: () -> Void, send: (() -> Void)?) {
        open(); pause(1.2); mark("opened")
        app.typeText("A first line of words")
        app.typeText("\nand a second, and a third that wraps around the edge so the box grows")
        pause(1.2); mark("typed")
        let start = field()
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: XCUIGestureVelocity(300),
            thenHoldForDuration: 0.1)
        pause(1.2); mark("swiped closed, keyboard up \(keyboardUp(app))")
        open(); pause(1.2); mark("opened again")
        let above = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        above.press(
            forDuration: 0.05, thenDragTo: above.withOffset(CGVector(dx: 0, dy: 520)), withVelocity: XCUIGestureVelocity(500),
            thenHoldForDuration: 0.1)
        pause(1.2); mark("dragged closed, keyboard up \(keyboardUp(app))")
        open(); pause(1.2); mark("opened a third time")
        if let send { send(); pause(1.5); mark("sent") }
    }

    func testScenarioMessages() {
        let app = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        app.launch()
        pause(2)
        if !app.textViews["messageBodyField"].exists {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '+1'")).firstMatch.tap()
            pause(1.5)
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        scenario(
            app, field: { origin.withOffset(CGVector(dx: 250, dy: app.keyboards.firstMatch.frame.minY - 81)) },
            open: {
                if !self.keyboardUp(app) { origin.withOffset(CGVector(dx: 250, dy: app.frame.maxY - 62)).tap() }
                _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            }, send: nil)
    }

    func testScenarioZero() {
        let app = XCUIApplication()
        app.launchArguments = ["-composerTest"]
        app.launch()
        pause(2)
        scenario(
            app, field: { app.textViews["composer.field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) },
            open: {
                if !self.keyboardUp(app) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap() }
                _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            }, send: { app.buttons["Send"].tap() })
    }

    func testZero() {
        let app = XCUIApplication()
        app.launchArguments = ["-composerTest"]
        app.launch()
        pause(1.5)
        drags(app, start: { app.textViews["composer.field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }) {
            if !self.keyboardUp(app) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap() }
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        }
    }
}
