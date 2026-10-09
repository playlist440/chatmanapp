import XCTest

/// The pinned faces fold as the list scrolls down and come back as it scrolls up, point for
/// point. Kept as pictures to look at, with one check: half a scroll is not a whole fold.
///
/// Measured by width. Folding is drawn, not laid out, except for the column each face stands
/// in, which narrows with it; the height of the row never changes, on purpose.
final class PinnedFoldTests: XCTestCase {
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// Drags the list slowly and holds before letting go, so it doesn't coast.
    private func drag(_ app: XCUIApplication, by points: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: points)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
        sleep(1)
    }

    @MainActor
    func testFacesFoldWithTheScroll() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "list"]
        app.launch()
        sleep(4)
        // The first pinned face. By position, not by name: folded, the name is put away.
        let papa = app.scrollViews.firstMatch.buttons.element(boundBy: 0)
        XCTAssertTrue(papa.waitForExistence(timeout: 5))
        let whole = papa.frame.width
        keep("1-top")

        drag(app, by: -40)
        keep("2-a-little-down")
        let partly = papa.frame.width

        drag(app, by: -200)
        keep("3-further-down")
        let folded = papa.frame.width

        drag(app, by: 60)
        keep("4-a-little-up")
        let unfolding = papa.frame.width

        XCTAssertLessThan(partly, whole, "Scrolling down a little didn't start folding the faces")
        XCTAssertGreaterThan(partly, folded, "A little scrolling folded the faces all the way")
        XCTAssertGreaterThan(unfolding, folded, "Scrolling back up didn't unfold the faces")
    }
}
