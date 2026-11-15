import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testUnconfiguredAppShowsExplicitSetupStateWithoutFixtureData() {
        let app = XCUIApplication()
        app.launch()
        let inboxAlert = app.alerts["Unable to read shared Reel"]
        if inboxAlert.waitForExistence(timeout: 2) { inboxAlert.buttons["OK"].tap() }
        XCTAssertTrue(app.staticTexts["Service setup required"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Preview Kitchen"].exists)
    }
}
