import XCTest

/// The Digital Crown scrolls what is on screen: the list, a conversation, and both again after
/// something else has been in front of them.
///
/// Written after scrolling on a real watch juddered and sometimes did nothing at all. The
/// screens were claiming the crown by hand through the focus system; these check that it moves
/// the content the ordinary way, in the places where it went missing. They run on the design
/// preview, which has a long list and a long conversation behind it.
final class CrownScrollTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", screen]
        app.launch()
        sleep(3)
        return app
    }

    /// Turns the crown, and says whether the element moved by at least a finger's width —
    /// or scrolled out of the list altogether, which a list does with rows it no longer shows.
    private func turning(_ delta: CGFloat, moves element: XCUIElement) -> Bool {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) isn't on screen to begin with")
        let before = element.frame.minY
        XCUIDevice.shared.rotateDigitalCrown(delta: delta, velocity: .slow)
        sleep(2)
        guard element.exists else { return true }
        return abs(element.frame.minY - before) > 20
    }

    /// Closes whatever sheet is up, the way the watch offers to.
    private func closeSheet(in app: XCUIApplication) {
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Cancel', 'Sluiten', 'Annuleer'}")).firstMatch
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        sleep(2)
    }

    @MainActor
    func testCrownScrollsTheList() throws {
        let app = launch("list")
        XCTAssertTrue(turning(0.3, moves: app.buttons["P, Papa"]), "The crown did not scroll the list")
    }

    @MainActor
    func testCrownStillScrollsTheListAfterAChat() throws {
        let app = launch("list")

        // Into a chat from the faces at the top, and back again.
        let papa = app.buttons["P, Papa"]
        XCTAssertTrue(papa.waitForExistence(timeout: 10))
        papa.tap()
        sleep(3)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)

        XCTAssertTrue(turning(0.3, moves: papa), "The crown stopped scrolling the list after a chat")
    }

    @MainActor
    func testCrownStillScrollsTheListAfterTheNewChatSheet() throws {
        let app = launch("list")
        app.buttons["Compose"].firstMatch.tap()
        sleep(2)
        closeSheet(in: app)

        XCTAssertTrue(turning(0.3, moves: app.buttons["P, Papa"]),
                      "The crown stopped scrolling the list after a sheet")
    }

    @MainActor
    func testCrownScrollsAConversationAndStillDoesAfterASheet() throws {
        let app = launch("conversation")
        let caption = app.staticTexts["Hier stonden we vanochtend"]
        XCTAssertTrue(turning(-0.5, moves: caption), "The crown did not scroll the conversation")

        app.buttons["Share something"].firstMatch.tap()
        sleep(2)
        closeSheet(in: app)

        // Upwards: closing the sheet leaves the conversation at its end, where there is
        // nothing further down to turn to.
        XCTAssertTrue(turning(-0.5, moves: caption), "The crown stopped scrolling the conversation after a sheet")
    }
}
