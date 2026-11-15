import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testInstallationCheckReportsActualBundleWithoutConnectingServices() {
        let app = XCUIApplication()
        app.launchArguments = ["-RecipeBookInstallationCheck"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Installation check only"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Signed bundle ID: com.recipebook.app")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Continue with Google"].exists)
    }
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
