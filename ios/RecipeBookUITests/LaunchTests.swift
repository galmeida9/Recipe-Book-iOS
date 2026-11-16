import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testPendingBookImportsDoNotBlockTabNavigationOrShowAGlobalElapsedTimer() {
        let app = XCUIApplication()
        app.launchArguments = ["-RecipeBookFixtureShowcase", "library"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Family Dinners"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Imports in progress"].exists)
        let plan = app.tabBars.buttons["Plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        plan.tap()
        XCTAssertTrue(app.buttons["Planning from Family Dinners"].waitForExistence(timeout: 10))
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.isHittable)
        library.tap()
        XCTAssertTrue(app.staticTexts["Family Dinners"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Imports in progress"].exists)
    }
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
