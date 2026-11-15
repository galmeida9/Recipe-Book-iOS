import Foundation
import Testing
@testable import RecipeBookCore

@Test func launchSchemesNeverBecomeSharedReelsOrOAuthCallbacks() {
    #expect(IncomingAppURL.route(URL(string: "sidestore-com.recipebook.app.TEAM123456://")!) == .ignored)
    #expect(IncomingAppURL.route(URL(string: "recipebook://oauth?code=short&state=nonce")!) == .oauth)
    #expect(IncomingAppURL.route(URL(string: "recipebook://import")!) == .importInbox)
    #expect(IncomingAppURL.route(URL(string: "https://instagram.com/reel/TEST123/?tracking=1")!) ==
            .reel(URL(string: "https://www.instagram.com/reel/TEST123/")!))
    #expect(IncomingAppURL.route(URL(string: "recipebook://unknown")!) == .ignored)
}
