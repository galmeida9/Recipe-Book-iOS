#if os(iOS)
import Foundation
import UIKit
import Security
@preconcurrency import AppAuth
import RecipeBookCore
import RecipeBookSharedAuth

public protocol AuthenticationSession: AccessTokenProvider {
    func hasSession() async -> Bool
    func signIn() async throws
    func signOut() async throws
}
public struct GoogleAuthConfiguration: Sendable {
    public let apiBaseURL: URL
    public let callbackURL: URL
    public init(apiBaseURL: URL, callbackURL: URL = URL(string: "recipebook://oauth")!) throws {
        guard apiBaseURL.scheme == "https", apiBaseURL.host != nil, apiBaseURL.user == nil,
              apiBaseURL.password == nil, apiBaseURL.query == nil, apiBaseURL.fragment == nil,
              callbackURL.absoluteString == "recipebook://oauth" else {
            throw APIError(status: 0, code: "auth_configuration", message: "Configure the HTTPS Recipe Book API and stable recipebook://oauth callback.")
        }
        self.apiBaseURL = apiBaseURL
        self.callbackURL = callbackURL
    }
}
struct GoogleCredential: Sendable {
    let idToken: String
    let expiresAt: Date
    let subject: String
}
@MainActor
protocol GoogleSessionDriver: AnyObject {
    var hasStoredSession: Bool { get }
    var hasCurrentUser: Bool { get }
    func signIn() async throws -> GoogleCredential
    func restore() async throws -> GoogleCredential
    func refresh() async throws -> GoogleCredential
    func signOut() throws
}
@MainActor
public final class GoogleAuth: AuthenticationSession {
    private let driver: any GoogleSessionDriver
    private var credential: GoogleCredential?
    private var generation = 0
    private var signingIn = false
    private var explicitlySignedOut = false
    private var refreshTask: Task<GoogleCredential, Error>?
    public convenience init(configuration: GoogleAuthConfiguration) throws {
        self.init(configuration: configuration, driver: try AppAuthDriver(configuration: configuration))
    }
    init(configuration: GoogleAuthConfiguration, driver: any GoogleSessionDriver) { self.driver = driver }
    public func hasSession() -> Bool { !explicitlySignedOut && (credential != nil || driver.hasStoredSession) }
    public func signIn() async throws {
        guard !signingIn, refreshTask == nil else { throw busy() }
        try Task.checkCancellation()
        signingIn = true
        generation += 1
        let current = generation
        defer { signingIn = false }
        do {
            let value = try await driver.signIn()
            try Task.checkCancellation()
            guard current == generation else { throw CancellationError() }
            try validate(value)
            credential = value
            explicitlySignedOut = false
        } catch {
            credential = nil
            explicitlySignedOut = true
            try driver.signOut()
            throw mapped(error)
        }
    }
    public func signOut() throws {
        generation += 1
        explicitlySignedOut = true
        credential = nil
        refreshTask?.cancel()
        try driver.signOut()
    }
    public func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard !explicitlySignedOut, !signingIn else { throw signedOut() }
        if let credential, credential.expiresAt > Date().addingTimeInterval(60) { return credential.idToken }
        if let refreshTask {
            let current = generation
            let value = try await refreshTask.value
            guard current == generation, !explicitlySignedOut else { throw CancellationError() }
            return value.idToken
        }
        guard driver.hasStoredSession else { throw signedOut() }
        let current = generation
        let previousSubject = credential?.subject
        let task = Task { @MainActor in
            do {
                let value = try await (driver.hasCurrentUser ? driver.refresh() : driver.restore())
                guard current == generation else { try driver.signOut(); throw CancellationError() }
                try Task.checkCancellation()
                try validate(value)
                guard previousSubject == nil || value.subject == previousSubject else {
                    throw APIError(status: 401, code: "google_session", message: "The refreshed Google identity changed. Sign in again.")
                }
                credential = value
                return value
            } catch {
                if current != generation { try driver.signOut() }
                throw mapped(error)
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        let value = try await task.value
        guard current == generation, !explicitlySignedOut else { throw CancellationError() }
        return value.idToken
    }
    public static func handle(_ url: URL, bundle: Bundle = .main) -> Bool {
        guard url.scheme == "recipebook", url.host == "oauth", url.path.isEmpty else { return false }
        return AppAuthDriver.active?.flow?.resumeExternalUserAgentFlow(with: url) ?? false
    }
    private func validate(_ value: GoogleCredential) throws {
        guard !value.idToken.isEmpty, value.expiresAt > Date(), !value.subject.isEmpty else {
            throw APIError(status: 401, code: "google_session", message: "Google returned no current ID token. Sign in again.")
        }
    }
    private func signedOut() -> APIError { APIError(status: 401, code: "signed_out", message: "Sign in to Recipe Book with Google.") }
    private func busy() -> APIError { APIError(status: 0, code: "auth_busy", message: "A sign-in operation is still finishing. Try again after it closes.") }
    private func mapped(_ error: Error) -> Error {
        let value = error as NSError
        if value.domain == OIDOAuthTokenErrorDomain {
            return APIError(status: 401, code: "sign_in_required", message: "Your Google sign-in expired. Sign in again.")
        }
        return error
    }
}

@MainActor
private final class AppAuthDriver: GoogleSessionDriver {
    static weak var active: AppAuthDriver?
    var flow: (any OIDExternalUserAgentSession)?
    private let configuration: GoogleAuthConfiguration
    private let keychainService: String
    private var state: OIDAuthState?
    private struct Discovery: Decodable { let clientID: String; let callbackURL: String }
    init(configuration: GoogleAuthConfiguration) throws {
        self.configuration = configuration
        keychainService = (Bundle.main.bundleIdentifier ?? "RecipeBook") + ".web-oauth"
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
            kSecAttrAccount: "google-broker", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
            guard state?.lastAuthorizationResponse.request.configuration.tokenEndpoint ==
                    configuration.apiBaseURL.appendingPathComponent("auth/google/token") else {
                throw APIError(status: 401, code: "auth_configuration", message: "Stored sign-in belongs to a different backend. Sign in again.")
            }
        } else if status != errSecItemNotFound {
            throw APIError(status: 0, code: "keychain", message: "Unable to read secure Google sign-in storage.")
        }
        Self.active = self
    }
    var hasStoredSession: Bool { state?.isAuthorized == true }
    var hasCurrentUser: Bool { state != nil }
    func signIn() async throws -> GoogleCredential {
        let (data, response) = try await URLSession.shared.data(from: configuration.apiBaseURL.appendingPathComponent("auth/google/config"))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw APIError(status: 0, code: "auth_configuration", message: "The app owner must configure Google sign-in on the backend before login is available.")
        }
        let discovery = try JSONDecoder().decode(Discovery.self, from: data)
        guard discovery.clientID.range(of: #"^\d+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil,
              discovery.callbackURL == configuration.callbackURL.absoluteString else {
            throw APIError(status: 0, code: "auth_configuration", message: "The backend returned an invalid public sign-in configuration.")
        }
        let service = OIDServiceConfiguration(authorizationEndpoint: configuration.apiBaseURL.appendingPathComponent("auth/google/authorize"),
                                              tokenEndpoint: configuration.apiBaseURL.appendingPathComponent("auth/google/token"))
        let request = OIDAuthorizationRequest(configuration: service, clientId: discovery.clientID, clientSecret: nil,
            scopes: [OIDScopeOpenID, OIDScopeProfile, OIDScopeEmail], redirectURL: configuration.callbackURL,
            responseType: OIDResponseTypeCode, additionalParameters: nil)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).filter(\.isKeyWindow)
        guard windows.count == 1, var controller = windows.first?.rootViewController else {
            throw APIError(status: 0, code: "auth_window", message: "Bring Recipe Book to the foreground before signing in.")
        }
        while let presented = controller.presentedViewController { controller = presented }
        return try await withCheckedThrowingContinuation { continuation in
            flow = OIDAuthState.authState(byPresenting: request, presenting: controller, prefersEphemeralSession: true) { result, error in
                Task { @MainActor in
                    self.flow = nil
                    if let error { continuation.resume(throwing: error); return }
                    guard let result else { continuation.resume(throwing: CancellationError()); return }
                    do {
                        self.state = result
                        let value = try self.snapshot(result)
                        try self.persist(result)
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
    func restore() async throws -> GoogleCredential { try await refresh() }
    func refresh() async throws -> GoogleCredential {
        guard let state else { throw APIError(status: 401, code: "signed_out", message: "Sign in with Google.") }
        let previous = try snapshot(state).subject
        if try snapshot(state).expiresAt <= Date().addingTimeInterval(60) { state.setNeedsTokenRefresh() }
        return try await withCheckedThrowingContinuation { continuation in
            state.performAction { _, _, error in
                Task { @MainActor in
                    if let error { continuation.resume(throwing: error); return }
                    do {
                        let value = try self.snapshot(state)
                        guard value.subject == previous else { throw APIError(status: 401, code: "google_session", message: "The Google account changed during refresh.") }
                        try self.persist(state)
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
    func signOut() throws {
        flow?.cancel()
        flow = nil
        state = nil
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
                                   kSecAttrAccount: "google-broker"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIError(status: 0, code: "keychain", message: "Unable to clear secure sign-in storage.")
        }
        try SharedGoogleSession(baseURL: configuration.apiBaseURL).clear()
    }
    private func snapshot(_ state: OIDAuthState) throws -> GoogleCredential {
        guard let token = state.lastTokenResponse?.idToken, let parsed = OIDIDToken(idTokenString: token) else {
            throw APIError(status: 401, code: "google_id_token", message: "Google returned no valid backend ID token.")
        }
        return GoogleCredential(idToken: token, expiresAt: parsed.expiresAt, subject: parsed.subject)
    }
    private func persist(_ state: OIDAuthState) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        let key: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: "google-broker"]
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw APIError(status: 0, code: "keychain", message: "Unable to save secure Google sign-in storage.")
            }
        } else if status != errSecSuccess {
            throw APIError(status: 0, code: "keychain", message: "Unable to update secure Google sign-in storage.")
        }
        try SharedGoogleSession(baseURL: configuration.apiBaseURL).save(state)
    }
}
#endif
