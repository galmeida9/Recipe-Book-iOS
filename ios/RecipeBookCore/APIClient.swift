import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol AccessTokenProvider: Sendable {
    /// Return the unexpired Google ID token for the configured backend audience, never a Google API access token.
    func accessToken() async throws -> String
}

public struct APIError: Error, LocalizedError, Sendable {
    public let status: Int
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }
}

public actor APIClient {
    private let baseURL: URL
    private let tokens: any AccessTokenProvider
    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(baseURL: URL, tokens: any AccessTokenProvider, session: URLSession? = nil) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw APIError(status: 0, code: "configuration", message: "An HTTPS API base URL is required.")
        }
        self.baseURL = baseURL
        self.tokens = tokens
        if let session { self.session = session }
        else { self.session = .shared }
        requestTimeout = session?.configuration.timeoutIntervalForRequest ?? 60
    }

    public func account() async throws -> SessionAccount { try await request("GET", "account") }
    public func completeSetup(displayName: String) async throws -> SessionAccount {
        try await request("PATCH", "account", body: Setup(displayName: displayName))
    }
    public func books() async throws -> [Book] { try await request("GET", "books") }
    public func uploadCover(_ data: Data, idempotencyKey: UUID = UUID(), expectedAccountID: UUID? = nil) async throws -> UUID {
        struct Upload: Encodable { let jpegBase64: String }
        struct Uploaded: Decodable { let id: UUID }
        let value: Uploaded = try await request("POST", "recipe-images", body: Upload(jpegBase64: data.base64EncodedString()),
            idempotencyKey: idempotencyKey, expectedAccountID: expectedAccountID)
        return value.id
    }
    public func coverData(id: UUID) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("recipe-images/\(id.uuidString.lowercased())"))
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 2_097_152, response.value(forHTTPHeaderField: "Content-Type") == "image/jpeg" else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "image_unavailable", message: "Cover photo is unavailable. Reload the recipe.")
        }
        return data
    }
    public func week(bookId: UUID, start: String) async throws -> StoredPlanResult? {
        try await request("GET", planPath(bookId, start))
    }
    public func generateWeek(bookId: UUID, start: String, styles: [MealStyle?], listId: UUID, version: Int?) async throws -> StoredPlanResult {
        struct Input: Encodable { let bookId: UUID; let listId: UUID; let weekStart: String; let dayStyles: [MealStyle?] }
        return try await request("POST", "plans", body: Input(bookId: bookId, listId: listId, weekStart: start, dayStyles: styles), version: version)
    }
    public func replacePlanDay(bookId: UUID, start: String, date: String, recipeId: UUID?, recipeVersion: Int?, servings: Int?, version: Int) async throws -> StoredPlanResult {
        struct Replacement: Encodable {
            let recipeId: UUID; let recipeVersion: Int; let servings: Int?
            enum CodingKeys: String, CodingKey { case recipeId, recipeVersion, servings }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(recipeId, forKey: .recipeId)
                try values.encode(recipeVersion, forKey: .recipeVersion)
                try values.encode(servings, forKey: .servings)
            }
        }
        struct Input: Encodable {
            let date: String; let replacement: Replacement?
            enum CodingKeys: String, CodingKey { case date, replacement }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(date, forKey: .date)
                try values.encode(replacement, forKey: .replacement)
            }
        }
        var replacement: Replacement?
        if let recipeId {
            guard let recipeVersion else { throw APIError(status: 0, code: "recipe_version", message: "Reload the replacement recipe.") }
            replacement = Replacement(recipeId: recipeId, recipeVersion: recipeVersion, servings: servings)
        }
        return try await request("PATCH", planPath(bookId, start), body: Input(date: date, replacement: replacement), version: version)
    }
    public func deleteWeek(bookId: UUID, start: String, version: Int) async throws {
        struct Result: Decodable { let removed: Bool }
        let _: Result = try await request("DELETE", planPath(bookId, start), version: version)
    }
    public func checkGenerated(bookId: UUID, start: String, itemId: UUID, bought: Bool, version: Int) async throws -> StoredPlanResult {
        struct Input: Encodable { let bought: Bool }
        return try await request("PATCH", "plans/items/\(itemId.uuidString.lowercased())?bookId=\(bookId.uuidString.lowercased())&weekStart=\(start)", body: Input(bought: bought), version: version)
    }
    private func planPath(_ bookId: UUID, _ start: String) throws -> String {
        _ = try CookingPlanner.weekDates(start)
        return "plans?bookId=\(bookId.uuidString.lowercased())&weekStart=\(start)"
    }
    public func createBook(name: String, kind: BookKind) async throws -> Book {
        try await request("POST", "books", body: CreateBook(name: name, kind: kind))
    }
    public func copyLocalBook<Payload: Encodable & Sendable>(payload: Payload, idempotencyKey: UUID, expectedAccountID: UUID) async throws -> Book {
        try await request("POST", "local-book-copies", body: payload, idempotencyKey: idempotencyKey,
                          expectedAccountID: expectedAccountID)
    }
    public func deleteBook(_ book: Book) async throws -> SessionAccount {
        try await request("DELETE", "books/\(book.id)", version: book.version)
    }
    public func members(bookId: UUID) async throws -> [Membership] {
        try await request("GET", "books/\(bookId)/members")
    }
    public func addMember(book: Book, userId: UUID) async throws -> Book {
        try await request("POST", "books/\(book.id)/members", body: AddMember(userId: userId), version: book.version)
    }
    public func changeRole(book: Book, userId: UUID, role: BookRole) async throws -> Book {
        try await request("PATCH", "books/\(book.id)/members/\(userId)", body: ChangeRole(role: role), version: book.version)
    }
    public func leaveBook(book: Book, userId: UUID) async throws -> SessionAccount {
        try await request("DELETE", "books/\(book.id)/members/\(userId)", version: book.version)
    }
    public func deleteAccount() async throws -> SessionAccount { try await request("DELETE", "account") }
    public func recipes(bookId: UUID) async throws -> [Recipe] {
        try await request("GET", "books/\(bookId)/recipes")
    }
    public func saveRecipe(bookId: UUID, draft: RecipeDraft, existing: Recipe? = nil) async throws -> Recipe {
        if let existing {
            return try await request("PUT", "books/\(bookId)/recipes/\(existing.id)", body: draft, version: existing.version)
        }
        return try await request("POST", "books/\(bookId)/recipes", body: draft)
    }
    public func deleteRecipe(_ recipe: Recipe) async throws -> SessionAccount {
        try await request("DELETE", "books/\(recipe.bookId)/recipes/\(recipe.id)", version: recipe.version)
    }
    public func suggestions(have: [String] = []) async throws -> [Recipe] {
        try await request("POST", "suggestions", body: Suggest(have: have))
    }
    public func importReel(url: URL, bookId: UUID, idempotencyKey: UUID, expectedAccountID: UUID) async throws -> ImportJob {
        try await request("POST", "imports", body: CreateImport(sourceURL: url, bookId: bookId),
                          idempotencyKey: idempotencyKey, expectedAccountID: expectedAccountID)
    }
    public func importJob(id: UUID) async throws -> ImportJob { try await request("GET", "imports/\(id)") }
    public func importJobs() async throws -> [ImportJob] { try await request("GET", "imports") }
    public func markImportSeen(_ job: ImportJob) async throws -> ImportJob {
        try await request("POST", "imports/\(job.id)/seen", version: job.version)
    }
    public func retryImport(_ job: ImportJob) async throws -> ImportJob {
        try await request("POST", "imports/\(job.id)/retry", version: job.version)
    }
    public func discardImport(_ job: ImportJob) async throws -> SessionAccount {
        try await request("DELETE", "imports/\(job.id)", version: job.version)
    }
    public func approveImport(_ job: ImportJob, bookId: UUID, draft: RecipeDraft) async throws -> Recipe {
        try await request("POST", "imports/\(job.id)/approve", body: ApproveImport(bookId: bookId, draft: draft), version: job.version)
    }
    public func shoppingLists() async throws -> [ShoppingList] { try await request("GET", "shopping-lists") }
    public func createShoppingList(name: String) async throws -> ShoppingList {
        try await request("POST", "shopping-lists", body: CreateList(name: name))
    }
    public func deleteShoppingList(_ list: ShoppingList) async throws -> SessionAccount {
        try await request("DELETE", "shopping-lists/\(list.id)", version: list.version)
    }
    public func replaceShoppingItems(list: ShoppingList, items: [ShoppingItem]) async throws -> ShoppingList {
        try await request("PUT", "shopping-lists/\(list.id)", body: ReplaceItems(items: items), version: list.version)
    }
    public func addRecipeToShoppingList(list: ShoppingList, recipeId: UUID, recipeVersion: Int, alreadyHave: [Int]) async throws -> ShoppingList {
        try await request("POST", "shopping-lists/\(list.id)/recipes", body: AddRecipe(recipeId: recipeId, recipeVersion: recipeVersion, alreadyHave: alreadyHave), version: list.version)
    }

    private struct CreateBook: Encodable { let name: String; let kind: BookKind }
    private struct Setup: Encodable { let displayName: String }
    private struct Suggest: Encodable { let have: [String] }
    private struct AddMember: Encodable { let userId: UUID }
    private struct ChangeRole: Encodable { let role: BookRole }
    private struct CreateImport: Encodable { let sourceURL: URL; let bookId: UUID }
    private struct ApproveImport: Encodable { let bookId: UUID; let draft: RecipeDraft }
    private struct CreateList: Encodable { let name: String }
    private struct ReplaceItems: Encodable { let items: [ShoppingItem] }
    private struct AddRecipe: Encodable { let recipeId: UUID; let recipeVersion: Int; let alreadyHave: [Int] }
    private struct ErrorEnvelope: Decodable { let code: String; let message: String }
    private struct EmptyBody: Encodable {}

    private func request<T: Decodable>(_ method: String, _ path: String, version: Int? = nil) async throws -> T {
        try await request(method, path, body: Optional<EmptyBody>.none, version: version)
    }

    private func request<T: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?, version: Int? = nil, idempotencyKey: UUID? = nil, expectedAccountID: UUID? = nil) async throws -> T {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var components = URLComponents(url: baseURL.appendingPathComponent(String(parts[0])), resolvingAgainstBaseURL: false)!
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        guard let url = components.url else { throw APIError(status: 0, code: "configuration", message: "Invalid API request URL.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = method
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let version { request.setValue(String(version), forHTTPHeaderField: "If-Match") }
        if let idempotencyKey { request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key") }
        if let expectedAccountID { request.setValue(expectedAccountID.uuidString.lowercased(), forHTTPHeaderField: "X-Recipe-Account-ID") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw APIError(status: 0, code: "transport", message: "Invalid HTTP response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw APIError(status: response.statusCode, code: error?.code ?? "http_error", message: error?.message ?? "Request failed.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
