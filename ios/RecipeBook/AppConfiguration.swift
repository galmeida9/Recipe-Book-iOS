import Foundation
import CryptoKit
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
            var recipes = operation.payload.recipes
            for (index, data) in operation.photos.sorted(by: { $0.key < $1.key }) {
                guard recipes.indices.contains(index) else {
                    throw APIError(status: 0, code: "copy_image", message: "The saved photo snapshot does not match its recipe.")
                }
                var bytes = Array(SHA256.hash(data: Data("\(operation.idempotencyKey.uuidString.lowercased())/cover/\(index)".utf8)).prefix(16))
                bytes[6] = (bytes[6] & 0x0f) | 0x50
                bytes[8] = (bytes[8] & 0x3f) | 0x80
                let key = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                recipes[index].coverImageID = try await api.uploadCover(data, idempotencyKey: key, expectedAccountID: accountID)
            }
            struct Payload: Encodable, Sendable {
                let name: String
                let kind: RecipeBookCore.BookKind
                let recipes: [RecipeBookCore.RecipeDraft]
            }
            let payload = Payload(name: operation.payload.name, kind: operation.payload.kind, recipes: recipes)
            return try await api.copyLocalBook(payload: payload,
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
