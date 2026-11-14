import XCTest

/// The composer's drag down, as a finger does it (on the Simulator): the keyboard follows the finger frame by frame
/// and closes past a short distance, from the text and from the controls; a short drag leaves it up; a drag never
/// fires a button. Runs the app's composer test page (`-composerTest`, ComposerTestPage).
final class ComposerDragTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-composerTest"]
        app.launch()
    }

    private var keyboardUp: Bool { app.keyboards.firstMatch.exists && app.keyboards.firstMatch.frame.minY < app.frame.maxY - 50 }

    private func wait(_ seconds: Double = 3, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return done()
    }

    /// Opens the composer from its closed capsule, the keyboard up.
    private func open() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap()
        XCTAssertTrue(wait { self.keyboardUp }, "the keyboard came up")
        _ = wait(1.5) { false }
    }

    /// A finger's drag down: `hold`, how long it rests before lifting (a flick lifts at once).
    private func drag(from start: XCUICoordinate, by distance: CGFloat, speed: CGFloat = 400, hold: TimeInterval = 0.1) {
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: XCUIGestureVelocity(speed),
            thenHoldForDuration: hold)
    }

    func testDragFromTheTextTakesTheKeyboardDown() {
        open()
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.exists)
        drag(from: field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), by: 420)
        XCTAssertTrue(wait { !self.keyboardUp }, "the keyboard closed")
    }

    func testDragFromTheControlsTakesTheKeyboardDownAndFiresNothing() {
        open()
        let plus = app.buttons["Add photos"]
        XCTAssertTrue(plus.exists)
        drag(from: plus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), by: 420)
        XCTAssertTrue(wait { !self.keyboardUp }, "the keyboard closed")
        XCTAssertFalse(
            wait(1.5) { self.app.otherElements["PhotosPicker"].exists || self.app.navigationBars["Photos"].exists }, "no photo picker")
    }

    /// A task just opened, the composer opened the first time: the conversation lifts with the keyboard, its last row
    /// above the composer (it didn't, the first time only).
    func testFirstOpenLiftsTheConversation() {
        _ = wait(2) { false }
        open()
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Answer 11'")).firstMatch
        let field = app.textViews["composer.field"]
        XCTAssertTrue(last.exists && field.exists)
        XCTAssertLessThan(last.frame.maxY, field.frame.minY, "the last row is above the composer")
    }

    /// An ask of the task answered in its inbox: what it brings (the agent told, its reply) comes into view, as a
    /// message sent does; the page didn't move for it.
    func testAnsweringAnAskBringsItsEventIntoView() {
        _ = wait(2) { false }
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'waiting on you'")).firstMatch.tap()
        let yes = app.staticTexts["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 3), "the ask's options")
        yes.tap()
        let event = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'answered your ask'")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5), "the answered event")
        _ = wait(1.5) { false }
        XCTAssertTrue(event.isHittable, "the answered event is on screen")
        XCTAssertGreaterThanOrEqual(event.frame.minY - app.navigationBars.firstMatch.frame.maxY, 24, "a gap below the bar")
        XCTAssertLessThan(event.frame.maxY, app.frame.maxY - 120, "above the composer")
    }

    /// A message sent is lifted to the top and stays there as the keyboard closes (it slid down 16 pt: the room under
    /// it was short).
    func testSentMessageStaysLiftedAsTheKeyboardCloses() {
        _ = wait(2) { false }
        open()
        app.typeText("A message to lift")
        app.buttons["Send"].tap()
        let sent = app.staticTexts["A message to lift"]
        XCTAssertTrue(sent.waitForExistence(timeout: 3))
        _ = wait(1.5) { false }
        let lifted = sent.frame.minY
        XCTAssertLessThan(lifted, 250, "lifted to the top")
        let bar = app.navigationBars.firstMatch.frame.maxY
        XCTAssertGreaterThanOrEqual(lifted - bar, 24, "a gap below the bar, not against its edge")
        XCTAssertLessThan(lifted - bar, 48, "at the top, with the gap")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(wait { !self.keyboardUp })
        _ = wait(1) { false }
        XCTAssertEqual(sent.frame.minY, lifted, accuracy: 3, "it stayed where it was lifted")
    }

    /// The keyboard opens while the reply reads out: the page moves once, with the keyboard, to keep the words read
    /// so far above it, and not again as the reading goes on (it scrolled again after the keyboard had settled, to
    /// keep unread lines above it).
    func testKeyboardDuringAReadOutMovesThePageOnce() {
        _ = wait(2) { false }
        open()
        app.typeText("Read me something long")
        app.buttons["Send"].tap()
        let sent = app.staticTexts["Read me something long"]
        XCTAssertTrue(sent.waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(wait { !self.keyboardUp })
        _ = wait(1.2) { false }
        open()
        _ = wait(0.7) { false }
        let settled = sent.frame.minY
        _ = wait(1.5) { false }
        XCTAssertEqual(sent.frame.minY, settled, accuracy: 2, "the page held still while the reading went on")
    }

    /// The conversation scrolled behind the composer: nothing of it shows beside the capsule (the page is solid
    /// under the composer). Saves a screenshot for its pixels to be checked.
    func testNothingShowsBesideTheComposer() {
        _ = wait(2) { false }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 140)), withVelocity: XCUIGestureVelocity(300),
            thenHoldForDuration: 0.3)
        _ = wait(1) { false }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/uitest-composer-backing.png"))
    }

    /// A reply with a table, read out: screenshots as it reads (rows coming one by one) and at the end (its edge
    /// faded where it scrolls on), for their pixels to be checked.
    func testTableReadsOutRowByRowAndFadesAtItsEdge() {
        _ = wait(2) { false }
        open()
        app.typeText("Show me a table")
        app.buttons["Send"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        for index in 0..<12 {
            _ = wait(0.15) { false }
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/uitest-table-\(index).png"))
        }
        _ = wait(4) { false }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/uitest-table-end.png"))
    }

    /// A message sent stays on screen without a break while zerod's copy takes the place of the phone's own (it
    /// vanished for 117 ms when zerod's copy didn't carry the phone's id).
    func testSentMessageNeverVanishes() {
        _ = wait(2) { false }
        open()
        app.typeText("Never gone")
        app.buttons["Send"].tap()
        let sent = app.staticTexts["Never gone"]
        XCTAssertTrue(sent.waitForExistence(timeout: 1))
        var missing = 0
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            if !sent.exists { missing += 1 }
        }
        XCTAssertEqual(missing, 0, "the message was off the screen \(missing) times")
    }

    /// A message queued while the agent works shows in the strip at once, and the strip goes when it's sent on.
    func testQueuedMessageShowsAtOnce() {
        app.terminate()
        app.launchArguments = ["-composerTest", "-working"]
        app.launch()
        _ = wait(2) { false }
        open()
        app.typeText("Queued one")
        app.buttons["Queue for after this turn"].tap()
        let queued = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Queued one'")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 0.3), "in the strip at once")
        XCTAssertTrue(app.staticTexts["Queued"].exists, "the strip")
        _ = wait(3) { false }
        let strip = app.staticTexts["Queued"]
        XCTAssertTrue(!strip.exists || strip.frame.height < 1 || !strip.isHittable, "the strip gone once it's sent on")
    }

    /// After a message sent is lifted, one of yours that zerod sends on by itself (one queued) isn't: the room under
    /// the lifted one doesn't move to it, so at the page's end it sits at the foot, not at the top over a screen of
    /// nothing.
    func testRoomStaysWithTheLiftedMessage() {
        app.terminate()
        app.launchArguments = ["-composerTest", "-addLater"]
        app.launch()
        _ = wait(2) { false }
        open()
        app.typeText("Lifted one")
        app.buttons["Send"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let added = app.staticTexts["Sent on by zerod"]
        XCTAssertTrue(
            wait(20) {
                if added.exists { return true }
                app.swipeUp(velocity: .fast)
                return false
            })
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        _ = wait(1.5) { false }
        XCTAssertGreaterThan(added.frame.minY, app.frame.height * 0.5, "at the page's foot, not lifted with room under it")
    }

    /// The deepest text on the page (the end of the conversation as laid out), and where it is.
    private var deepest: CGFloat {
        app.scrollViews.firstMatch.staticTexts.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
    }

    /// A long real conversation (zerod's `recent` for a lead task: folded turns, pages before it) opens at its end, the
    /// last message and its row just above the composer, whether it's held already or comes a moment after the page.
    private func opensAtTheEnd(_ arguments: [String]) throws {
        let fixture = "/tmp/zero-fixture/recent.json"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture), "no fixture")
        app.terminate()
        app.launchArguments = ["-composerTest", "-fixture", fixture] + arguments
        app.launch()
        _ = wait(4) { false }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/open-a.png"))
        let opened = deepest
        let composer = app.staticTexts["Reply"].frame.minY
        XCTAssertGreaterThan(opened, composer - 90, "the end just above the composer, not further up the page")
        XCTAssertLessThan(opened, composer, "the end above the composer, not under it")
        app.swipeUp(velocity: .fast)
        _ = wait(1.5) { false }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/open-b.png"))
        XCTAssertEqual(deepest, opened, accuracy: 2, "nothing further down")
    }

    /// Images in earlier answers coming after the page opened (as the Mac's do, over the relay): the page holds still
    /// at its end, rather than sliding down by each one (55 to 115 pt on the phone). Needs the fixture to hold some.
    func testOpenedPageHoldsStillAsImagesAboveArrive() throws {
        let fixture = "/tmp/zero-fixture/with-images.json"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture), "no fixture")
        app.terminate()
        app.launchArguments = ["-composerTest", "-fixture", fixture, "-slowImages"]
        app.launch()
        // Its last line (the fixture's last answer), read at once: `deepest` walks the whole page and took longer than
        // the images do to come.
        let last = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'when you' AND label CONTAINS 'big refactor'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 4))
        let opened = last.frame.minY
        _ = wait(4) { false }
        XCTAssertEqual(last.frame.minY, opened, accuracy: 2, "the end where it was as the images came")
    }

    /// A sent video's tile plays it: fetched from the Mac in parts (a stand-in here), how far shown meanwhile, then
    /// playing. Needs a video at /tmp/zero-fixture/video.mp4.
    func testSentVideoPlaysWhenTapped() throws {
        let video = "/tmp/zero-fixture/video.mp4"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: video), "no video")
        app.terminate()
        app.launchArguments = ["-composerTest", "-fixture", "/tmp/zero-fixture/recent-now.json", "-sendVideo", video, "-fetchVideos"]
        app.launch()
        let length = app.staticTexts["0:09"].firstMatch
        XCTAssertTrue(length.waitForExistence(timeout: 10), "the video's tile, with its length")
        _ = wait(3) { false }
        length.tap()
        let loading = app.descendants(matching: .any)["Loading the video"]
        XCTAssertTrue(loading.waitForExistence(timeout: 3), "how far it's come, while it comes")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/vb/play-a.png"))
        XCTAssertTrue(wait(20) { !loading.exists }, "it came")
        XCTAssertFalse(app.staticTexts["Couldn't get the video from your Mac"].exists)
        _ = wait(2) { false }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/vb/play-b.png"))
    }

    func testOpensAtTheEndWhenTheConversationComesAfter() throws { try opensAtTheEnd([]) }
    func testOpensAtTheEndWhenTheConversationIsHeld() throws { try opensAtTheEnd(["-fixtureFirst"]) }

    /// A turn ending with no answer at the page's end: "Thinking…" goes and the page stays where it is.
    func testTurnEndingWithNoAnswerDoesNotDropThePage() {
        app.terminate()
        app.launchArguments = ["-composerTest", "-working", "-endLater"]
        app.launch()
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Answer 11.'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 4))
        let thinking = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Thinking'")).firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 2), "the turn's live row")
        let before = last.frame.minY
        XCTAssertTrue(wait(8) { !thinking.exists }, "the turn ended")
        _ = wait(1) { false }
        XCTAssertEqual(last.frame.minY, before, accuracy: 2, "the page held still as the live row went")
    }

    /// ↓ is a solid circle: the text it sits over doesn't read through it (a material let "Sim↓ator" show).
    func testDownIsSolidOverText() {
        _ = wait(2) { false }
        app.swipeDown(velocity: .slow)
        let down = app.buttons["To the end"]
        XCTAssertTrue(down.waitForExistence(timeout: 3))
        _ = wait(1) { false }
        let image = down.screenshot().image
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("no screenshot")
        }
        let scale = CGFloat(cg.width) / image.size.width
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let at = Int(y * scale) * cg.bytesPerRow + Int(x * scale) * 4
            return (0..<3).map { Int(bytes[at + $0]) }
        }
        // Inside the circle, around the arrow: one colour wherever the text under it runs.
        let w = image.size.width, h = image.size.height
        let points = [
            pixel(w * 0.25, h * 0.5), pixel(w * 0.75, h * 0.5), pixel(w * 0.5, h * 0.22), pixel(w * 0.5, h * 0.78),
            pixel(w * 0.3, h * 0.3), pixel(w * 0.7, h * 0.7),
        ]
        for point in points {
            XCTAssertEqual(point, points[0], "the circle's fill is even: \(points)")
        }
        // And it works where it is now, over the composer's fade.
        down.tap()
        XCTAssertTrue(wait(2) { !down.exists }, "at the end, ↓ gone")
    }

    /// The fade above the composer only while the conversation runs under it: none at the end, all of it scrolled up.
    func testFadeOnlyWhileContentRunsUnderIt() {
        _ = wait(2) { false }
        let fade = app.otherElements["test.fade"]
        XCTAssertTrue(fade.waitForExistence(timeout: 3))
        func alpha() -> Double { Double(fade.value as? String ?? "") ?? -1 }
        XCTAssertEqual(alpha(), 0, "at the end: no fade")
        app.swipeDown(velocity: .slow)
        _ = wait(1.5) { false }
        XCTAssertEqual(alpha(), 1, "scrolled up: the fade")
        app.buttons["To the end"].tap()
        XCTAssertTrue(wait(2) { alpha() == 0 }, "back at the end: gone again (\(alpha()))")
    }

    /// As Messages' input bar: a swipe of 30 pt on the text closes the keyboard, the finger still down; 20 pt doesn't.
    func testSwipeOfThirtyPointsCloses() {
        open()
        let field = app.textViews["composer.field"]
        drag(from: field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), by: 32, speed: 60, hold: 0.5)
        XCTAssertTrue(wait { !self.keyboardUp }, "the keyboard closed")
    }

    /// Open, type a few lines, close by dragging, open again, close with a tap on the conversation: for a screen
    /// recording to look through for jumps (it asserts only that each step happens).
    func testWalkthrough() {
        open()
        app.typeText("A first line of words to read")
        app.typeText("\nand a second line, and a third that wraps around the box's edge to make it grow")
        _ = wait(1) { false }
        drag(from: app.textViews["composer.field"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), by: 420)
        XCTAssertTrue(wait { !self.keyboardUp })
        _ = wait(1) { false }
        open()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(wait { !self.keyboardUp })
        _ = wait(1) { false }
    }

    /// The control: from the conversation just above the composer, which works on the phone.
    func testDragFromTheConversationTakesTheKeyboardDown() {
        open()
        let field = app.textViews["composer.field"]
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -60))
        drag(from: start, by: 480)
        XCTAssertTrue(wait { !self.keyboardUp }, "the keyboard closed")
    }

    func testShortDragLeavesTheKeyboardUp() {
        open()
        let field = app.textViews["composer.field"]
        // A slip while placing the caret: the keyboard stays.
        drag(from: field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), by: 20, speed: 120, hold: 0.6)
        _ = wait(1) { false }
        XCTAssertTrue(keyboardUp, "the keyboard stayed up")
    }
}
