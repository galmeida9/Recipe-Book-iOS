import XCTest
import UIKit

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
            guard let preview else {
                XCTFail("Fixture preview could not fit the existing bounded screenshot transfer.")
                app.terminate()
                return
            }
            let screenshot = XCTAttachment(data: preview, uniformTypeIdentifier: "public.png")
            screenshot.name = "Fixture-preview-" + screen
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }
}
