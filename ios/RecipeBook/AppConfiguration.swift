import Foundation
import RecipeBookCore
import RecipeBookAuth
import RecipeBookPresentation

enum AppConfiguration {
    static var importsEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "RecipeBookImportsEnabled") as? String == "YES" }
    static func appGroup() throws -> String { try SharedAppGroup.current() }
    @MainActor static func service() throws -> any RecipeBookPresentation.RecipeBookService {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("RecipeBook", isDirectory: true)
            .appendingPathComponent("OnDevice", isDirectory: true)
        let cloud = CloudServices()
        return try GuestAwareService(localDirectory: directory,
                                     cloudFactory: { try await cloud.makeService() },
                                     cloudCopy: { try await cloud.copy($0) })
    }
    @MainActor private final class CloudServices {
        private var currentAPI: APIClient?

        func makeService() throws -> any RecipeBookPresentation.RecipeBookService {
            currentAPI = nil
            let apiURL = try AppConfiguration.url("RecipeBookAPIURL")
            let configuration = try GoogleAuthConfiguration(apiBaseURL: apiURL)
            let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
            guard urlTypes.compactMap({ $0["CFBundleURLSchemes"] as? [String] }).flatMap({ $0 }).contains("recipebook") else {
                throw APIError(status: 0, code: "auth_configuration", message: "Register the stable recipebook callback scheme in this app's URL types.")
            }
            let group = try AppConfiguration.setting("RecipeBookAppGroup")
            let auth = try GoogleAuth(configuration: configuration)
            let api = try APIClient(baseURL: apiURL, tokens: auth)
            let service = UIServiceAdapter(api: api, auth: auth,
                                          inbox: SharedReelInbox(appGroup: group, resolveGroup: { try SharedAppGroup.current() }))
            currentAPI = api
            return service
        }
        func copy(_ operation: LocalBookCopy) async throws -> RecipeBookCore.Book {
            try Task.checkCancellation()
            guard let accountID = UUID(uuidString: operation.accountID) else {
                throw APIError(status: 0, code: "client_state", message: "The copy operation requires a valid account UUID.")
            }
            guard let api = currentAPI else { throw RecipeBookUIError.serviceNotConfigured }
            // Capture the current adapter's API/auth pair before suspending. The server also
            // checks this account header inside its transaction, including after token refresh.
            return try await api.copyLocalBook(payload: operation.payload,
                                               idempotencyKey: operation.idempotencyKey, expectedAccountID: accountID)
        }
    }
    private static func setting(_ key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else {
            throw APIError(status: 0, code: "configuration", message: "\(key) must be configured before connecting Recipe Book.")
        }
        return value
    }
    private static func url(_ key: String) throws -> URL {
        guard let value = URL(string: try setting(key)) else {
            throw APIError(status: 0, code: "configuration", message: "\(key) is not a valid URL.")
        }
        return value
    }
}
