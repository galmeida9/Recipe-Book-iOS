import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol AccessTokenProvider: Sendable {
    /// Return an unexpired access token for the configured API audience, not an ID token.
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

    public init(baseURL: URL, tokens: any AccessTokenProvider, session: URLSession = .shared) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw APIError(status: 0, code: "configuration", message: "An HTTPS API base URL is required.")
        }
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session
    }

    public func account() async throws -> SessionAccount { try await request("GET", "account") }
    public func completeSetup(displayName: String) async throws -> SessionAccount {
        try await request("PATCH", "account", body: Setup(displayName: displayName))
    }
    public func books() async throws -> [Book] { try await request("GET", "books") }
    public func createBook(name: String, kind: BookKind) async throws -> Book {
        try await request("POST", "books", body: CreateBook(name: name, kind: kind))
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
    public func importReel(url: URL, idempotencyKey: UUID) async throws -> ImportJob {
        try await request("POST", "imports", body: CreateImport(sourceURL: url), idempotencyKey: idempotencyKey)
    }
    public func importJob(id: UUID) async throws -> ImportJob { try await request("GET", "imports/\(id)") }
    public func importJobs() async throws -> [ImportJob] { try await request("GET", "imports") }
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
    private struct CreateImport: Encodable { let sourceURL: URL }
    private struct ApproveImport: Encodable { let bookId: UUID; let draft: RecipeDraft }
    private struct CreateList: Encodable { let name: String }
    private struct ReplaceItems: Encodable { let items: [ShoppingItem] }
    private struct AddRecipe: Encodable { let recipeId: UUID; let recipeVersion: Int; let alreadyHave: [Int] }
    private struct ErrorEnvelope: Decodable { let code: String; let message: String }
    private struct EmptyBody: Encodable {}

    private func request<T: Decodable>(_ method: String, _ path: String, version: Int? = nil) async throws -> T {
        try await request(method, path, body: Optional<EmptyBody>.none, version: version)
    }

    private func request<T: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?, version: Int? = nil, idempotencyKey: UUID? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let version { request.setValue(String(version), forHTTPHeaderField: "If-Match") }
        if let idempotencyKey { request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key") }
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
