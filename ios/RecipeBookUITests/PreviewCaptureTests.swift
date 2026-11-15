import XCTest

final class PreviewCaptureTests: XCTestCase {
    @MainActor
    func testCaptureDisclosedFixtureScreens() {
        let screens = [
            ("sign-in", "Continue with Google"),
            ("library", "Family Dinners"),
            ("recipe-detail", "Roasted Tomato Soup"),
            ("shopping", "Weekend")
        ]
        for (screen, expected) in screens {
            let app = XCUIApplication()
            app.launchArguments = ["-RecipeBookFixtureShowcase", screen]
            app.launch()
            guard app.staticTexts["Fixture preview — no live backend or Google sign-in"].waitForExistence(timeout: 15) else {
                XCTFail("Fixture disclosure missing for \(screen): " + String(app.debugDescription.prefix(4_000)))
                app.terminate()
                return
            }
            let title = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            guard title.waitForExistence(timeout: 15) else {
                XCTFail("The implemented \(screen) screen did not load: " + String(app.debugDescription.prefix(4_000)))
                app.terminate()
                return
            }
            if screen == "recipe-detail" || screen == "shopping" {
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Tomatoes")).firstMatch.waitForExistence(timeout: 15))
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Fixture-preview-" + screen
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }
}
