import Foundation

/// The single command/data interface the SwiftUI module needs. The app layer implements it on top
/// of RecipeBookCore (`APIClient`, OIDC, `SharedReelInbox`). Every method reflects a real backend
/// operation; implementations must throw rather than pretend success.
///
/// Calls may be cancelled (views use `.task`); implementations should honour `Task` cancellation.
public protocol RecipeBookService: Sendable {
    // MARK: Session & access
    func loadSession() async throws -> SessionState
    /// Starts the hosted OIDC sign-in owned by the app layer (Google is the only customer sign-in
    /// option) and returns the resulting state. Missing configuration must throw, never succeed.
    func signIn() async throws -> SessionState
    func completeSetup(displayName: String) async throws -> SessionState
    func signOut() async throws

    // MARK: Books & membership
    func books() async throws -> [BookSummary]
    func createBook(name: String, kind: BookKind) async throws -> BookSummary
    func book(id: BookID) async throws -> BookDetail
    func deleteBook(id: BookID) async throws
    /// Owner-only. Adds an existing, active account (by account ID) as a regular member.
    func addMember(accountID: UserID, to bookID: BookID) async throws -> BookDetail
    /// Owner-only. Appointing several owners is allowed; demoting the last owner is not.
    func changeRole(of userID: UserID, to role: MemberRole, in bookID: BookID) async throws -> BookDetail
    /// Owner-only.
    func removeMember(_ userID: UserID, from bookID: BookID) async throws -> BookDetail
    /// `resolution` is required when the caller is the last owner of a shared book.
    func leaveBook(id: BookID, resolution: LastOwnerResolution?) async throws

    // MARK: Recipes
    func recipe(id: RecipeID) async throws -> RecipeDetail
    /// Creates when `draft.recipeID == nil`, otherwise updates. `draft.bookID` is always set.
    func saveRecipe(_ draft: RecipeDraft) async throws -> RecipeDetail
    func deleteRecipe(id: RecipeID) async throws

    // MARK: Suggestions (accessible saved recipes only)
    func suggestions(have ingredients: [String]) async throws -> [RecipeSuggestion]

    // MARK: Instagram Reel imports
    func importJobs() async throws -> [ImportJob]
    func importJob(id: ImportJobID) async throws -> ImportJob
    func submitImport(url: URL) async throws -> ImportJob
    /// Draft extracted for a `reviewRequired` job. Uncertain amounts are `nil` + `amountNeedsReview`.
    func importReview(id: ImportJobID) async throws -> RecipeDraft
    /// Saves the reviewed draft into `draft.bookID`, which the user picked explicitly.
    func approveImport(id: ImportJobID, draft: RecipeDraft) async throws -> RecipeDetail
    func retryImport(id: ImportJobID) async throws -> ImportJob
    func discardImport(id: ImportJobID) async throws

    // MARK: Personal shopping lists
    func shoppingLists() async throws -> [ShoppingListSummary]
    func shoppingList(id: ShoppingListID) async throws -> ShoppingList
    func createShoppingList(name: String) async throws -> ShoppingListSummary
    func deleteShoppingList(id: ShoppingListID) async throws
    func addShoppingItem(_ item: ShoppingItemDraft, to listID: ShoppingListID) async throws -> ShoppingList
    func setShoppingItem(_ itemID: ShoppingItemID, bought: Bool, in listID: ShoppingListID) async throws -> ShoppingList
    func removeShoppingItem(_ itemID: ShoppingItemID, from listID: ShoppingListID) async throws -> ShoppingList
    /// Adds only the selected (needed) ingredients of a recipe.
    func addRecipeIngredients(recipeID: RecipeID, ingredientIDs: [String], to listID: ShoppingListID) async throws -> ShoppingList

    // MARK: Account
    /// Shared books where the user is the last owner and other members remain.
    func accountDeletionBlockers() async throws -> [BookDetail]
    /// Deletes the account. Must include a resolution for every blocker book.
    func deleteAccount(resolutions: [BookID: LastOwnerResolution]) async throws
}

public enum RecipeBookUIError: LocalizedError, Equatable, Sendable {
    case serviceNotConfigured

    public var errorDescription: String? {
        switch self {
        case .serviceNotConfigured:
            return "Recipe Book isn’t connected to its service yet."
        }
    }
}

/// Default used when no service is injected. Fails every call; it never fabricates data.
public struct UnconfiguredRecipeBookService: RecipeBookService {
    public init() {}

    public func loadSession() async throws -> SessionState { throw RecipeBookUIError.serviceNotConfigured }
    public func signIn() async throws -> SessionState { throw RecipeBookUIError.serviceNotConfigured }
    public func completeSetup(displayName: String) async throws -> SessionState { throw RecipeBookUIError.serviceNotConfigured }
    public func signOut() async throws { throw RecipeBookUIError.serviceNotConfigured }
    public func books() async throws -> [BookSummary] { throw RecipeBookUIError.serviceNotConfigured }
    public func createBook(name: String, kind: BookKind) async throws -> BookSummary { throw RecipeBookUIError.serviceNotConfigured }
    public func book(id: BookID) async throws -> BookDetail { throw RecipeBookUIError.serviceNotConfigured }
    public func deleteBook(id: BookID) async throws { throw RecipeBookUIError.serviceNotConfigured }
    public func addMember(accountID: UserID, to bookID: BookID) async throws -> BookDetail { throw RecipeBookUIError.serviceNotConfigured }
    public func changeRole(of userID: UserID, to role: MemberRole, in bookID: BookID) async throws -> BookDetail { throw RecipeBookUIError.serviceNotConfigured }
    public func removeMember(_ userID: UserID, from bookID: BookID) async throws -> BookDetail { throw RecipeBookUIError.serviceNotConfigured }
    public func leaveBook(id: BookID, resolution: LastOwnerResolution?) async throws { throw RecipeBookUIError.serviceNotConfigured }
    public func recipe(id: RecipeID) async throws -> RecipeDetail { throw RecipeBookUIError.serviceNotConfigured }
    public func saveRecipe(_ draft: RecipeDraft) async throws -> RecipeDetail { throw RecipeBookUIError.serviceNotConfigured }
    public func deleteRecipe(id: RecipeID) async throws { throw RecipeBookUIError.serviceNotConfigured }
    public func suggestions(have ingredients: [String]) async throws -> [RecipeSuggestion] { throw RecipeBookUIError.serviceNotConfigured }
    public func importJobs() async throws -> [ImportJob] { throw RecipeBookUIError.serviceNotConfigured }
    public func importJob(id: ImportJobID) async throws -> ImportJob { throw RecipeBookUIError.serviceNotConfigured }
    public func submitImport(url: URL) async throws -> ImportJob { throw RecipeBookUIError.serviceNotConfigured }
    public func importReview(id: ImportJobID) async throws -> RecipeDraft { throw RecipeBookUIError.serviceNotConfigured }
    public func approveImport(id: ImportJobID, draft: RecipeDraft) async throws -> RecipeDetail { throw RecipeBookUIError.serviceNotConfigured }
    public func retryImport(id: ImportJobID) async throws -> ImportJob { throw RecipeBookUIError.serviceNotConfigured }
    public func discardImport(id: ImportJobID) async throws { throw RecipeBookUIError.serviceNotConfigured }
    public func shoppingLists() async throws -> [ShoppingListSummary] { throw RecipeBookUIError.serviceNotConfigured }
    public func shoppingList(id: ShoppingListID) async throws -> ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    public func createShoppingList(name: String) async throws -> ShoppingListSummary { throw RecipeBookUIError.serviceNotConfigured }
    public func deleteShoppingList(id: ShoppingListID) async throws { throw RecipeBookUIError.serviceNotConfigured }
    public func addShoppingItem(_ item: ShoppingItemDraft, to listID: ShoppingListID) async throws -> ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    public func setShoppingItem(_ itemID: ShoppingItemID, bought: Bool, in listID: ShoppingListID) async throws -> ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    public func removeShoppingItem(_ itemID: ShoppingItemID, from listID: ShoppingListID) async throws -> ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    public func addRecipeIngredients(recipeID: RecipeID, ingredientIDs: [String], to listID: ShoppingListID) async throws -> ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    public func accountDeletionBlockers() async throws -> [BookDetail] { throw RecipeBookUIError.serviceNotConfigured }
    public func deleteAccount(resolutions: [BookID: LastOwnerResolution]) async throws { throw RecipeBookUIError.serviceNotConfigured }
}
