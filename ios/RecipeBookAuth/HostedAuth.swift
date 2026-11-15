#if os(iOS)
import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import RecipeBookCore

public struct AuthConfiguration: Sendable {
    public let authorizationURL: URL
    public let tokenURL: URL
    public let clientID: String
    public let redirectURL: URL
    public let scopes: [String]

    public init(authorizationURL: URL, tokenURL: URL, clientID: String, redirectURL: URL, scopes: [String]) throws {
        guard authorizationURL.scheme == "https", authorizationURL.host != nil,
              tokenURL.scheme == "https", tokenURL.host != nil,
              !clientID.isEmpty, redirectURL.scheme == "recipebook", redirectURL.host == "oauth",
              !scopes.isEmpty else {
            throw APIError(status: 0, code: "auth_configuration", message: "Hosted OAuth endpoints, client, callback and API scope must be configured.")
        }
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.redirectURL = redirectURL
        self.scopes = scopes
    }
}

private struct StoredTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}
private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
    let token_type: String
}

public actor HostedAuth: AccessTokenProvider {
    private let configuration: AuthConfiguration
    private let keychainService: String
    private var tokens: StoredTokens?
    private var refreshTask: Task<String, Error>?
    private var generation = 0

    public init(configuration: AuthConfiguration, keychainService: String) throws {
        self.configuration = configuration
        self.keychainService = keychainService
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
            kSecAttrAccount: "oauth", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            tokens = try JSONDecoder().decode(StoredTokens.self, from: data)
        } else if status != errSecItemNotFound {
            throw APIError(status: 0, code: "keychain", message: "Unable to read secure sign-in storage.")
        }
    }

    public func hasSession() -> Bool { tokens != nil }

    public func signIn() async throws {
        let verifier = try Self.randomValue()
        let state = try Self.randomValue()
        let nonce = try Self.randomValue()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizationURL = components.url else {
            throw APIError(status: 0, code: "auth_configuration", message: "Unable to create the sign-in URL.")
        }
        let callback = try await HostedBrowser.shared.open(authorizationURL)
        guard callback.scheme == configuration.redirectURL.scheme,
              callback.host == configuration.redirectURL.host,
              callback.path == configuration.redirectURL.path,
              let parameters = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              parameters.filter({ $0.name == "state" }).count == 1,
              parameters.first(where: { $0.name == "state" })?.value == state else {
            throw APIError(status: 0, code: "auth_callback", message: "The sign-in callback could not be verified.")
        }
        if parameters.contains(where: { $0.name == "error" }) {
            throw APIError(status: 0, code: "auth_denied", message: "Sign-in was declined by the identity provider.")
        }
        guard parameters.filter({ $0.name == "code" }).count == 1,
              let code = parameters.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw APIError(status: 0, code: "auth_code", message: "The identity provider returned no authorization code.")
        }
        generation += 1
        let current = generation
        let response = try await exchange([
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": configuration.redirectURL.absoluteString
        ])
        guard generation == current else { throw CancellationError() }
        try store(response, previousRefresh: nil)
    }

    public func signOut() throws {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService,
            kSecAttrAccount: "oauth"
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIError(status: 0, code: "keychain", message: "Unable to clear secure sign-in storage.")
        }
        tokens = nil
    }

    public func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard let tokens else {
            throw APIError(status: 401, code: "signed_out", message: "Sign in to Recipe Book.")
        }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = tokens.refreshToken else {
            throw APIError(status: 401, code: "sign_in_required", message: "Your session expired. Sign in again.")
        }
        let current = generation
        let task = Task { () throws -> String in
            let response = try await self.exchange(["grant_type": "refresh_token", "refresh_token": refresh])
            try Task.checkCancellation()
            guard self.generation == current else { throw CancellationError() }
            try self.store(response, previousRefresh: refresh)
            return response.access_token
        }
        refreshTask = task
        defer { if generation == current { refreshTask = nil } }
        return try await task.value
    }

    private func exchange(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = (fields.merging(["client_id": configuration.clientID, "scope": configuration.scopes.joined(separator: " ")]) { _, new in new })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw APIError(status: 401, code: "token_exchange", message: "Sign-in could not be refreshed or completed. Sign in again.")
        }
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard result.token_type.lowercased() == "bearer", result.expires_in > 0, !result.access_token.isEmpty else {
            throw APIError(status: 401, code: "token_response", message: "The identity provider returned an invalid access token.")
        }
        return result
    }

    private func store(_ response: TokenResponse, previousRefresh: String?) throws {
        let value = StoredTokens(accessToken: response.access_token, refreshToken: response.refresh_token ?? previousRefresh,
                                 expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)))
        let data = try JSONEncoder().encode(value)
        let key: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: "oauth"]
        let update = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = key
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw APIError(status: 0, code: "keychain", message: "Unable to save secure sign-in storage.")
            }
        } else if update != errSecSuccess {
            throw APIError(status: 0, code: "keychain", message: "Unable to update secure sign-in storage.")
        }
        tokens = value
    }
    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw APIError(status: 0, code: "random", message: "Unable to generate a secure sign-in challenge.")
        }
        return Data(bytes).base64URLEncoded()
    }
}

@MainActor
private final class HostedBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = HostedBrowser()
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func open(_ url: URL) async throws -> URL {
        guard session == nil else {
            throw APIError(status: 0, code: "auth_busy", message: "A sign-in is already in progress.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "recipebook") { [weak self] callback, error in
                    Task { @MainActor in self?.finish(callback: callback, error: error) }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() {
                    finish(callback: nil, error: APIError(status: 0, code: "auth_browser", message: "Unable to open hosted sign-in."))
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.session?.cancel()
                self.finish(callback: nil, error: CancellationError())
            }
        }
    }
    private func finish(callback: URL?, error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        session = nil
        if let callback { continuation?.resume(returning: callback) }
        else { continuation?.resume(throwing: error ?? CancellationError()) }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
#endif
