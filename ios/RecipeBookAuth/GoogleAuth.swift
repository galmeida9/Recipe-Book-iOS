#if os(iOS)
import Foundation
import UIKit
@preconcurrency import GoogleSignIn
import RecipeBookCore

public protocol AuthenticationSession: AccessTokenProvider {
    func hasSession() async -> Bool
    func signIn() async throws
    func signOut() async throws
}

public struct GoogleAuthConfiguration: Sendable {
    public let iosClientID: String
    public let serverClientID: String
    public let callbackScheme: String

    public init(iosClientID: String, serverClientID: String, callbackScheme: String,
                registeredBundleID: String, actualBundleID: String) throws {
        let pattern = #"^\d+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#
        guard iosClientID.range(of: pattern, options: .regularExpression) != nil,
              serverClientID.range(of: pattern, options: .regularExpression) != nil,
              iosClientID != serverClientID,
              callbackScheme == iosClientID.split(separator: ".").reversed().joined(separator: ".") else {
            throw APIError(status: 0, code: "auth_configuration",
                           message: "Configure separate Google iOS and web/server client IDs and the iOS client's reversed callback scheme.")
        }
        guard !registeredBundleID.isEmpty, !registeredBundleID.contains("$("),
              registeredBundleID == actualBundleID else {
            throw APIError(status: 0, code: "auth_bundle",
                           message: "The Google iOS client must register this signed app's exact bundle ID (\(actualBundleID)). Check SideStore re-signing before configuring Google.")
        }
        self.iosClientID = iosClientID
        self.serverClientID = serverClientID
        self.callbackScheme = callbackScheme
    }
}

struct GoogleCredential: Sendable {
    let idToken: String
    let expiresAt: Date
    let iosClientID: String
    let serverClientID: String?
}

@MainActor
protocol GoogleSessionDriver: AnyObject {
    var hasStoredSession: Bool { get }
    var hasCurrentUser: Bool { get }
    func signIn() async throws -> GoogleCredential
    func restore() async throws -> GoogleCredential
    func refresh() async throws -> GoogleCredential
    func signOut()
}

@MainActor
public final class GoogleAuth: AuthenticationSession {
    private let configuration: GoogleAuthConfiguration
    private let driver: any GoogleSessionDriver
    private var credential: GoogleCredential?
    private var generation = 0
    private var signingIn = false
    private var explicitlySignedOut = false
    private var refreshTask: Task<GoogleCredential, Error>?

    public convenience init(configuration: GoogleAuthConfiguration) {
        self.init(configuration: configuration, driver: GoogleSDKDriver(configuration: configuration))
    }
    init(configuration: GoogleAuthConfiguration, driver: any GoogleSessionDriver) {
        self.configuration = configuration
        self.driver = driver
    }
    public func hasSession() -> Bool {
        !explicitlySignedOut && (credential != nil || driver.hasStoredSession)
    }
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
            driver.signOut()
            credential = nil
            explicitlySignedOut = true
            throw mapped(error)
        }
    }
    public func signOut() throws {
        generation += 1
        explicitlySignedOut = true
        credential = nil
        // Keep a canceled SDK operation busy until it finishes; its late callback
        // must not overwrite or sign out a newer session.
        refreshTask?.cancel()
        driver.signOut()
        guard !driver.hasStoredSession else {
            throw APIError(status: 0, code: "keychain", message: "Google sign-in storage could not be cleared. Check the signed app's Keychain access.")
        }
    }
    public func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard !explicitlySignedOut, !signingIn else {
            throw APIError(status: 401, code: "signed_out", message: "Sign in to Recipe Book with Google.")
        }
        if let credential, credential.expiresAt > Date().addingTimeInterval(60) { return credential.idToken }
        if let refreshTask {
            let current = generation
            let value = try await refreshTask.value
            guard current == generation, !explicitlySignedOut else { throw CancellationError() }
            return value.idToken
        }
        guard driver.hasStoredSession else {
            throw APIError(status: 401, code: "signed_out", message: "Sign in to Recipe Book with Google.")
        }
        let current = generation
        let task = Task { @MainActor in
            do {
                let value = try await (driver.hasCurrentUser ? driver.refresh() : driver.restore())
                guard current == generation else {
                    driver.signOut()
                    throw CancellationError()
                }
                try Task.checkCancellation()
                try validate(value)
                credential = value
                return value
            } catch {
                if current != generation { driver.signOut() }
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
        guard let scheme = bundle.object(forInfoDictionaryKey: "RecipeBookGoogleCallbackScheme") as? String,
              scheme.hasPrefix("com.googleusercontent.apps."), !scheme.contains("$("), url.scheme == scheme else { return false }
        return GIDSignIn.sharedInstance.handle(url)
    }
    private func validate(_ value: GoogleCredential) throws {
        guard !value.idToken.isEmpty, value.expiresAt > Date(),
              value.iosClientID == configuration.iosClientID, value.serverClientID == configuration.serverClientID else {
            throw APIError(status: 401, code: "google_session", message: "The saved Google sign-in does not match this app's configured clients. Sign in again.")
        }
    }
    private func busy() -> APIError {
        APIError(status: 0, code: "auth_busy", message: "A Google sign-in operation is still finishing. Try again after it closes.")
    }
    private func mapped(_ error: Error) -> Error {
        let value = error as NSError
        guard value.domain == kGIDSignInErrorDomain else { return error }
        switch value.code {
        case -5: return CancellationError()
        case -4: return APIError(status: 401, code: "sign_in_required", message: "Your Google session expired. Sign in again.")
        case -2: return APIError(status: 0, code: "keychain", message: "Google sign-in cannot access Keychain. Check this app's signing/profile and re-sign it with its extension.")
        default: return error
        }
    }
}

@MainActor
private final class GoogleSDKDriver: GoogleSessionDriver {
    private let sdk = GIDSignIn.sharedInstance
    init(configuration: GoogleAuthConfiguration) {
        sdk.configuration = GIDConfiguration(clientID: configuration.iosClientID, serverClientID: configuration.serverClientID)
        // Do not call App Check configure/debug-provider APIs or enable Firebase.
    }
    var hasStoredSession: Bool { sdk.hasPreviousSignIn() }
    var hasCurrentUser: Bool { sdk.currentUser != nil }
    func signIn() async throws -> GoogleCredential {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).filter(\.isKeyWindow)
        guard windows.count == 1, var controller = windows.first?.rootViewController else {
            throw APIError(status: 0, code: "auth_window", message: "Bring Recipe Book's window to the foreground before signing in.")
        }
        while let presented = controller.presentedViewController { controller = presented }
        return try snapshot((await sdk.signIn(withPresenting: controller)).user)
    }
    func restore() async throws -> GoogleCredential { try snapshot(await sdk.restorePreviousSignIn()) }
    func refresh() async throws -> GoogleCredential {
        guard let user = sdk.currentUser else {
            throw APIError(status: 401, code: "sign_in_required", message: "Sign in again with Google.")
        }
        return try snapshot(await user.refreshTokensIfNeeded())
    }
    func signOut() { sdk.signOut() }
    private func snapshot(_ user: GIDGoogleUser) throws -> GoogleCredential {
        guard let token = user.idToken, let expiration = token.expirationDate else {
            throw APIError(status: 401, code: "google_id_token", message: "Google returned no backend ID token. Check the web/server client configuration.")
        }
        return GoogleCredential(idToken: token.tokenString, expiresAt: expiration,
                                iosClientID: user.configuration.clientID, serverClientID: user.configuration.serverClientID)
    }
}
#endif
