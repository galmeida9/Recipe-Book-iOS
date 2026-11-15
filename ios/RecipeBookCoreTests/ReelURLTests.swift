import Testing
import Foundation
@testable import RecipeBookCore

@Test func canonicalReelURL() {
    #expect(ReelURL.canonicalize(URL(string: "https://instagram.com/reel/Ab_12/?igsh=test")!)?.absoluteString == "https://www.instagram.com/reel/Ab_12/")
    #expect(ReelURL.canonicalize(URL(string: "https://instagram.com.evil.test/reel/Ab/")!) == nil)
    #expect(ReelURL.canonicalize(URL(string: "https://instagram.com:443/reel/Ab/")!) == nil)
    #expect(ReelURL.canonicalize(URL(string: "https://instagram.com/p/Ab/")!) == nil)
}
