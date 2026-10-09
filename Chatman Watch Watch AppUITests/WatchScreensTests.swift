import XCTest

/// The groups and the archive are screens of their own, with the watch's own way back.
///
/// The archive used to be the list with a flag turned over, and swiping in from the edge —
/// how every watch screen is left — did nothing there. Run on the design preview.
final class WatchScreensTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String = "list") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", screen]
        app.launch()
        sleep(3)
        return app
    }

    /// Swipes in from the left edge, the watch's way back — a few points in, where a thumb
    /// actually starts.
    private func swipeBack(in app: XCUIApplication) {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))
        sleep(2)
    }

    @MainActor
    func testGroupsOpenOnTheirOwnScreenAndSwipeBack() throws {
        let app = launch()
        let door = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Groups'")).firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 10), "No way to the groups at the top of the list")
        door.tap()

        // A group, which only this screen lists: the main list keeps groups behind the door.
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Groep 0'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5), "The groups screen doesn't list the groups")

        swipeBack(in: app)
        XCTAssertTrue(group.waitForNonExistence(timeout: 5), "Swiping back didn't leave the groups")
    }

    @MainActor
    func testTheArchiveSwipesBack() throws {
        // Opened straight into the archive: the way in is a pull on the list, which a test
        // can't time reliably, and the way out is what this is about.
        let app = launch("archive")

        let archived = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Oude groep'")).firstMatch
        XCTAssertTrue(archived.waitForExistence(timeout: 10), "The archive doesn't show what was put away")

        swipeBack(in: app)
        XCTAssertTrue(archived.waitForNonExistence(timeout: 5), "Swiping back didn't leave the archive")
    }
}
