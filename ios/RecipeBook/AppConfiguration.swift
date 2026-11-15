import Foundation
import RecipeBookCore
import RecipeBookAuth
import RecipeBookPresentation

enum AppConfiguration {
    static func appGroup() throws -> String { try SharedAppGroup.current() }
    static func service() throws -> any RecipeBookPresentation.RecipeBookService {
        let auth = try HostedAuth(configuration: AuthConfiguration(
            authorizationURL: url("RecipeBookAuthorizeURL"),
            tokenURL: url("RecipeBookTokenURL"),
            clientID: setting("RecipeBookClientID"),
            redirectURL: URL(string: "recipebook://oauth")!,
            scopes: setting("RecipeBookScopes").split(separator: " ").map(String.init)
        ), keychainService: try setting("RecipeBookKeychainService"))
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
