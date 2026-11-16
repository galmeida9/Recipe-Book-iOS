import XCTest
import UIKit

final class PreviewCaptureTests: XCTestCase {
    @MainActor
    func testCaptureDisclosedFixtureScreens() throws {
        for (screen, expected) in [
            ("sign-in", "Continue with Google"), ("library", "Family Dinners"),
            ("recipe-detail", "Roasted Tomato Soup"), ("shopping", "Weekend")
        ] {
            try capture(screen, expected: expected)
        }
    }

    @MainActor
    func testCaptureDisclosedPlanScreen() throws {
        try capture("plan", expected: "Roasted Tomato Soup")
    }

    @MainActor
    private func capture(_ screen: String, expected: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-RecipeBookFixtureShowcase", screen]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Fixture preview — no live backend or Google sign-in"].waitForExistence(timeout: 15))
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "Fixture content missing for \(screen)")
        if screen == "recipe-detail" || screen == "shopping" {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Tomatoes")).firstMatch.waitForExistence(timeout: 15))
        }
        if screen == "plan" {
            XCTAssertTrue(app.buttons["Planning from Family Dinners"].waitForExistence(timeout: 15))
        }
        let original = app.screenshot().image
        var preview: Data?
        for width in [600.0, 480.0, 360.0, 300.0] {
            let size = CGSize(width: width, height: original.size.height * width / original.size.width)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                original.draw(in: CGRect(origin: .zero, size: size))
            }
            if let data = image.pngData(), data.count <= 200 * 1024 {
                preview = data
                break
            }
        }
        let data = try XCTUnwrap(preview, "Fixture preview exceeded the existing bounded screenshot transfer.")
        let screenshot = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        screenshot.name = "Fixture-preview-" + screen
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
