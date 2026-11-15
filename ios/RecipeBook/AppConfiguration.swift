import Foundation
import RecipeBookCore
import RecipeBookAuth
import RecipeBookPresentation

enum AppConfiguration {
    static func appGroup() throws -> String { try SharedAppGroup.current() }
    @MainActor static func service() throws -> any RecipeBookPresentation.RecipeBookService {
        let configuration = try GoogleAuthConfiguration(
            iosClientID: setting("GIDClientID"),
            serverClientID: setting("GIDServerClientID"),
            callbackScheme: setting("RecipeBookGoogleCallbackScheme"),
            registeredBundleID: setting("RecipeBookGoogleBundleID"),
            actualBundleID: Bundle.main.bundleIdentifier ?? ""
        )
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        guard urlTypes.compactMap({ $0["CFBundleURLSchemes"] as? [String] }).flatMap({ $0 }).contains(configuration.callbackScheme) else {
            throw APIError(status: 0, code: "auth_configuration", message: "Register the Google iOS client's callback scheme in this app's URL types.")
        }
        let auth = GoogleAuth(configuration: configuration)
        return try UIServiceAdapter(api: APIClient(baseURL: url("RecipeBookAPIURL"), tokens: auth), auth: auth,
                                    inbox: SharedReelInbox(appGroup: appGroup()))
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
