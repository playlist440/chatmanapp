import XCTest

/// Dragging a message to the right answers it: the gesture WhatsApp, Signal and Telegram use.
///
/// Written when the drag stopped working on a real phone. Runs on the design preview's
/// conversation, and checks the one thing the drag is for: the "Replying to" banner.
final class SwipeToReplyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func keep(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testASlowDragAnswersToo() throws {
        try drag(velocity: 80)
    }

    @MainActor
    func testScrollingOverAMessageScrollsAndDoesNotAnswer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "conversation"]
        app.launch()

        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'open tikkies'")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        sleep(2)
        let before = message.frame.minY

        // Downwards, with the slight sideways drift a real thumb has.
        let start = message.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 18, dy: 220)),
                    withVelocity: 400, thenHoldForDuration: 0.1)
        sleep(1)

        XCTAssertGreaterThan(message.frame.minY - before, 100, "The conversation didn't scroll")
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Replying to'")).firstMatch
        XCTAssertFalse(banner.exists, "Scrolling was taken for a reply")
    }

    @MainActor
    func testDraggingAMessageRightAnswersIt() throws {
        try drag(velocity: 300)
    }

    @MainActor
    private func drag(velocity: CGFloat) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "conversation"]
        app.launch()

        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'open tikkies'")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        sleep(2)
        keep("1-before", app)

        let start = message.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 140, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0.2)
        sleep(1)
        keep("2-after-drag", app)

        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Replying to'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 3), "Dragging the message did not start a reply")
    }
}
