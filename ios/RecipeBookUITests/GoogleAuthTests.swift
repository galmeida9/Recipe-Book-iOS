import Foundation
import XCTest
@testable import RecipeBookAuth
import RecipeBookCore

@MainActor
private final class GoogleDriverFixture: GoogleSessionDriver {
    var hasStoredSession = true
    var hasCurrentUser = false
    var hold = false
    var pending: CheckedContinuation<GoogleCredential, Error>?
    var restoreCount = 0
    var refreshCount = 0
    var error: Error?
    var credential = GoogleCredential(idToken: "synthetic-google-ID-token", expiresAt: Date().addingTimeInterval(3600),
                                      subject: "10000001")
    func signIn() async throws -> GoogleCredential { try await result() }
    func restore() async throws -> GoogleCredential { restoreCount += 1; return try await result() }
    func refresh() async throws -> GoogleCredential { refreshCount += 1; return try await result() }
    func signOut() { hasStoredSession = false; hasCurrentUser = false }
    func finish() {
        hasStoredSession = true
        hasCurrentUser = true
        pending?.resume(returning: credential)
        pending = nil
    }
    private func result() async throws -> GoogleCredential {
        if let error { throw error }
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        hasStoredSession = true
        hasCurrentUser = true
        return credential
    }
}

@MainActor
final class GoogleAuthTests: XCTestCase {
    private func configuration() throws -> GoogleAuthConfiguration {
        try GoogleAuthConfiguration(apiBaseURL: URL(string: "https://fixture.invalid/api")!)
    }
    func testConfigurationUsesStableCallbackWithoutSigningTeamRegistration() throws {
        _ = try configuration()
        XCTAssertEqual(try configuration().callbackURL.absoluteString, "recipebook://oauth")
        XCTAssertThrowsError(try GoogleAuthConfiguration(apiBaseURL: URL(string: "http://fixture.invalid/api")!))
    }
    func testRestorationReturnsIDTokenAndReusesFreshCredential() async throws {
        let driver = GoogleDriverFixture()
        let auth = GoogleAuth(configuration: try configuration(), driver: driver)
        async let first = auth.accessToken()
        async let second = auth.accessToken()
        let values = try await (first, second)
        XCTAssertEqual(values.0, "synthetic-google-ID-token")
        XCTAssertEqual(values.1, values.0)
        XCTAssertEqual(driver.restoreCount, 1)
        XCTAssertEqual(driver.refreshCount, 0)
        try auth.signOut()
        XCTAssertFalse(auth.hasSession())
    }
    func testSignOutDuringSignInRejectsLateSDKSessionAndOverlappingSignIn() async throws {
        let driver = GoogleDriverFixture()
        driver.hold = true
        let auth = GoogleAuth(configuration: try configuration(), driver: driver)
        let work = Task { try await auth.signIn() }
        for _ in 0..<100 where driver.pending == nil { await Task.yield() }
        _ = try XCTUnwrap(driver.pending)
        try auth.signOut()
        do { try await auth.signIn(); XCTFail("A prior SDK operation must finish first.") }
        catch let error as APIError { XCTAssertEqual(error.code, "auth_busy") }
        driver.finish()
        do { try await work.value; XCTFail("Late sign-in must not restore the signed-out user.") }
        catch is CancellationError {}
        XCTAssertFalse(auth.hasSession())
        XCTAssertFalse(driver.hasStoredSession)
    }
    func testSignOutDuringRestoreDoesNotLeakLateIDToken() async throws {
        let driver = GoogleDriverFixture()
        driver.hold = true
        let auth = GoogleAuth(configuration: try configuration(), driver: driver)
        let work = Task { try await auth.accessToken() }
        for _ in 0..<100 where driver.pending == nil { await Task.yield() }
        _ = try XCTUnwrap(driver.pending)
        try auth.signOut()
        driver.finish()
        do { _ = try await work.value; XCTFail("Late restore must not return an ID token.") }
        catch is CancellationError {}
        XCTAssertFalse(auth.hasSession())
        XCTAssertFalse(driver.hasStoredSession)
    }
    func testKeychainFailuresRemainVisibleAndExpiredTokensAreRejected() async throws {
        let driver = GoogleDriverFixture()
        driver.error = APIError(status: 0, code: "keychain", message: "Synthetic storage failure")
        let auth = GoogleAuth(configuration: try configuration(), driver: driver)
        do { _ = try await auth.accessToken(); XCTFail("Keychain failure must not fabricate a token.") }
        catch let error as APIError { XCTAssertEqual(error.code, "keychain") }
        driver.error = nil
        driver.credential = GoogleCredential(idToken: "synthetic-ID-token", expiresAt: Date().addingTimeInterval(-60),
                                            subject: "10000001")
        do { _ = try await auth.accessToken(); XCTFail("Expired ID tokens must fail.") }
        catch let error as APIError { XCTAssertEqual(error.status, 401) }
    }
}
