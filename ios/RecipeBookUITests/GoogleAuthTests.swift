import Foundation
import XCTest
@testable import RecipeBookAuth
import RecipeBookCore
import RecipeBookSharedAuth
@preconcurrency import AppAuthCore

private final class TokenTransportFixture: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        var mode = 0
    }
    private static let state = State()
    static func reset(mode: Int) { state.lock.withLock { state.count = 0; state.mode = mode } }
    static var requests: Int { state.lock.withLock { state.count } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "token-transport.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.lock.withLock { Self.state.count += 1; return Self.state.mode }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
            if mode == 1 {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }
            if mode == 2 {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            let status = mode == 3 ? 503 : 200
            let body = status == 200 ? #"{"access_token":"synthetic-only","token_type":"Bearer","expires_in":3600}"#
                : #"{"error":"temporarily_unavailable","error_description":"Synthetic cold service"}"#
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

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
    func testLiveOwnedTokenEndpointRejectsInertCodeThroughActualAppAuthTransport() async throws {
        let previous = OIDURLSessionProvider.session()
        defer { OIDURLSessionProvider.setSession(previous) }
        // Exercise the same SDK default session as the known-working login.
        let session = URLSession.shared
        OIDURLSessionProvider.setSession(session)
        let base = URL(string: "https://recipe-api-nb2yqx3agzmou.azurewebsites.net/api/")!
        let config = try GoogleAuthConfiguration(apiBaseURL: base)
        let discovery = try await GoogleAuthDiscovery.load(configuration: config, session: session)
        let request = OIDTokenRequest(configuration: OIDServiceConfiguration(
            authorizationEndpoint: base.appendingPathComponent("auth/google/authorize"),
            tokenEndpoint: base.appendingPathComponent("auth/google/token")),
            grantType: "authorization_code", authorizationCode: "synthetic-inert-native-probe-" + UUID().uuidString,
            redirectURL: config.callbackURL, clientID: discovery.clientID, clientSecret: nil, scopes: nil,
            refreshToken: nil, codeVerifier: String(repeating: "v", count: 43), additionalParameters: nil)
        let start = Date()
        let failure: NSError = await withCheckedContinuation { continuation in
            OIDAuthorizationService.perform(request) { _, error in
                continuation.resume(returning: (error as NSError?) ?? NSError(domain: "SyntheticUnexpectedSuccess", code: 0))
            }
        }
        XCTAssertEqual(failure.domain, OIDOAuthTokenErrorDomain, "Actual iOS transport must receive the OAuth response, not time out.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 90)
        print("LIVE_AUTH_TRANSPORT: actual iOS AppAuth received the owned endpoint's expected inert-code OAuth rejection in \(Date().timeIntervalSince(start)) seconds; no customer identity or Google code was used.")
    }
    func testMainAppSharedCredentialSetupDoesNotReplaceTheWorkingAppAuthSDKSession() {
        let previous = OIDURLSessionProvider.session()
        defer { OIDURLSessionProvider.setSession(previous) }
        OIDURLSessionProvider.setSession(URLSession.shared)
        SharedGoogleSession.configureNetworking()
        XCTAssertTrue(OIDURLSessionProvider.session() === URLSession.shared)
    }
    private func transportRequest() -> OIDTokenRequest {
        OIDTokenRequest(configuration: OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://token-transport.invalid/authorize")!,
            tokenEndpoint: URL(string: "https://token-transport.invalid/token")!),
            grantType: "refresh_token", authorizationCode: nil, redirectURL: nil,
            clientID: "synthetic-public-client", clientSecret: nil, scopes: nil,
            refreshToken: "synthetic-inert-refresh", codeVerifier: nil, additionalParameters: nil)
    }
    private func performTransportRequest() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.perform(transportRequest()) { response, error in
                if let error { continuation.resume(throwing: GoogleTokenNetworkPolicy.mapped(error)) }
                else if let token = response?.accessToken { continuation.resume(returning: token) }
                else { continuation.resume(throwing: URLError(.badServerResponse)) }
            }
        }
    }
    func testAppAuthRetainsConfiguredSessionAcrossDelayedCallbackWithoutRetryingTokenPOST() async throws {
        let previous = OIDURLSessionProvider.session()
        defer { OIDURLSessionProvider.setSession(previous) }
        let configuration = GoogleTokenNetworkPolicy.configuration(isExtension: false)
        configuration.protocolClasses = [TokenTransportFixture.self]
        autoreleasepool { OIDURLSessionProvider.setSession(URLSession(configuration: configuration)) }
        TokenTransportFixture.reset(mode: 0)
        let token = try await performTransportRequest()
        XCTAssertEqual(token, "synthetic-only")
        XCTAssertEqual(TokenTransportFixture.requests, 1)
        XCTAssertEqual(OIDURLSessionProvider.session().configuration.timeoutIntervalForResource, 120)
    }
    func testAppAuthTimeoutCancellationAndHTTP503CompleteOnceWithoutCodeReplay() async throws {
        let previous = OIDURLSessionProvider.session()
        defer { OIDURLSessionProvider.setSession(previous) }
        let configuration = GoogleTokenNetworkPolicy.configuration(isExtension: false)
        configuration.protocolClasses = [TokenTransportFixture.self]
        OIDURLSessionProvider.setSession(URLSession(configuration: configuration))
        for mode in [1, 2, 3] {
            TokenTransportFixture.reset(mode: mode)
            do { _ = try await performTransportRequest(); XCTFail("Synthetic transport failure must remain a failure.") }
            catch {
                if mode == 1 { XCTAssertEqual((error as? APIError)?.code, "auth_transport_-1001") }
                if mode == 2 { XCTAssertTrue(error is CancellationError) }
                if mode == 3 { XCTAssertFalse(error is CancellationError) }
            }
            func testDiscoveryTimeoutAndCancellationAreBoundedAndDoNotRetry() async throws {
                let configuration = GoogleTokenNetworkPolicy.configuration(isExtension: false)
                configuration.protocolClasses = [TokenTransportFixture.self]
                let session = URLSession(configuration: configuration)
                let api = try GoogleAuthConfiguration(apiBaseURL: URL(string: "https://token-transport.invalid/api")!)
                for mode in [1, 2] {
                    TokenTransportFixture.reset(mode: mode)
                    do { _ = try await GoogleAuthDiscovery.load(configuration: api, session: session); XCTFail("Discovery failure must finish explicitly.") }
                    catch {
                        if mode == 1 { XCTAssertEqual((error as? APIError)?.code, "auth_transport_-1001") }
                        else { XCTAssertTrue(error is CancellationError) }
                    }
                    XCTAssertEqual(TokenTransportFixture.requests, 1)
                }
            }
            XCTAssertEqual(TokenTransportFixture.requests, 1)
        }
    }
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
    func testFailedInteractiveTokenConnectionDoesNotDeleteAnExistingStoredGoogleSession() async throws {
        let driver = GoogleDriverFixture()
        let auth = GoogleAuth(configuration: try configuration(), driver: driver)
        _ = try await auth.accessToken()
        driver.error = NSError(domain: "org.openid.appauth.general", code: -5,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)])
        do { try await auth.signIn(); XCTFail("The timed-out exchange must not be reported as a successful sign-in.") }
        catch let error as APIError { XCTAssertEqual(error.code, "auth_transport_-1001") }
        XCTAssertTrue(auth.hasSession())
        XCTAssertTrue(driver.hasStoredSession)
        driver.error = nil
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "synthetic-google-ID-token")
    }
}
