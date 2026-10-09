import XCTest

/// Not a check, a record: the shelf closed and open, kept as pictures to look at.
final class ShelfLookTests: XCTestCase {
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testShelfClosedAndOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "list"]
        app.launch()
        sleep(4)
        keep("shelf-closed")
        let handle = app.buttons["Expand boards"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.tap()
        sleep(2)
        keep("shelf-open")
    }
}
