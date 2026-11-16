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
    func testUnconfiguredAppOffersExplicitSignInOrGuestWithoutFixtureData() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.alerts["Unable to read shared Reel"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Continue with Google"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Continue Without Signing In"].exists)
        XCTAssertFalse(app.alerts["Unable to read shared Reel"].exists)
        XCTAssertFalse(app.staticTexts["Preview Kitchen"].exists)
    }
}
