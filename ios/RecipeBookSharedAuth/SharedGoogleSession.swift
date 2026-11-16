#if os(iOS)
import Foundation
import Security
@preconcurrency import AppAuthCore
import RecipeBookCore

@MainActor
public final class SharedGoogleSession: AccessTokenProvider {
    private struct Envelope: Codable { let id: UUID; let state: Data }
    private let baseURL: URL
    private let group: String
    private let lockURL: URL
    private static let service = "RecipeBook.GoogleBroker.Shared.v1"

    public init(baseURL: URL, bundle: Bundle = .main) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw Self.failure("The shared API URL is invalid.") }
        self.baseURL = baseURL
        group = try SharedAppGroup.current(bundle: bundle)
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw Self.failure("iOS did not authorize shared sign-in. Keep both signed targets and their matching App Group.")
        }
        lockURL = directory.appendingPathComponent("google-session.lock")
    }

    public func hasSession() throws -> Bool { try coordinated { try read() != nil } }

    public func save(_ state: OIDAuthState) throws {
        try validate(state)
        let envelope = Envelope(id: UUID(), state: try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true))
        try coordinated { try write(envelope) }
    }

    public func clear() throws {
        try coordinated {
            let status = SecItemDelete(key as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure("Unable to clear shared secure sign-in.") }
        }
    }

    public func accessToken() async throws -> String {
        let envelope = try coordinated { try read() }
        guard let envelope, let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: envelope.state) else {
            throw APIError(status: 401, code: "sign_in_required", message: "Open Recipe Book and continue with Google before sharing.")
        }
        try validate(state)
        guard let initial = state.lastTokenResponse?.idToken, let parsed = OIDIDToken(idTokenString: initial) else {
            throw Self.failure("Shared Google sign-in has no valid identity token.")
        }
        let subject = parsed.subject
        if parsed.expiresAt <= Date().addingTimeInterval(60) { state.setNeedsTokenRefresh() }
        return try await withCheckedThrowingContinuation { continuation in
            state.performAction { _, _, error in
                Task { @MainActor in
                    if let error { continuation.resume(throwing: error); return }
                    do {
                        try Task.checkCancellation()
                        try self.validate(state)
                        guard let token = state.lastTokenResponse?.idToken, let current = OIDIDToken(idTokenString: token),
                              current.expiresAt > Date(), current.subject == subject else {
                            throw Self.failure("The shared Google session expired or changed. Open Recipe Book and sign in again.")
                        }
                        let updated = Envelope(id: envelope.id, state: try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true))
                        try self.coordinated {
                            guard try self.read()?.id == envelope.id else {
                                throw Self.failure("Sign-in changed while the share sheet was open. Reopen the sheet.")
                            }
                            try self.write(updated)
                        }
                        continuation.resume(returning: token)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    private var key: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service,
         kSecAttrAccount: "google-broker", kSecAttrAccessGroup: group]
    }
    private func read() throws -> Envelope? {
        var query = key
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.failure("iOS denied shared Keychain access. Both targets need an authorized matching App Group.")
        }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }
    private func write(_ value: Envelope) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Self.failure("Unable to save shared secure sign-in.") }
        } else if status != errSecSuccess { throw Self.failure("Unable to update shared secure sign-in.") }
    }
    private func validate(_ state: OIDAuthState) throws {
        guard state.lastAuthorizationResponse.request.configuration.tokenEndpoint == baseURL.appendingPathComponent("auth/google/token"),
              state.isAuthorized else { throw Self.failure("The shared sign-in belongs to another backend or is no longer authorized.") }
    }
    private func coordinated<T>(_ operation: () throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: lockURL, options: [], error: &coordinationError) { _ in
            result = Result { try operation() }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Self.failure("Shared sign-in coordination did not complete.") }
        return try result.get()
    }
    private static func failure(_ message: String) -> APIError {
        APIError(status: 401, code: "shared_sign_in", message: message)
    }
}
#endif
