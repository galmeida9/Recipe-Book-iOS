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
    /// Guest mode: records the choice to use the app on this device without an account.
    /// Default implementation throws (see extension below).
    func continueWithoutSignIn() async throws -> SessionState

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
    /// Explicit-consent copy of an on-device book into the signed-in account (default throws).
    func copyLocalBookToAccount(id: BookID, kind: BookKind) async throws -> BookSummary

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
    /// Queues a Reel import into an explicitly chosen book. Returns only once the job is durably
    /// queued server-side; processing continues with the app closed. Default throws.
    func submitImport(url: URL, bookID: BookID) async throws -> ImportJob
    /// Persists that the user opened a job's result (clears the book's "new" badge). Default throws;
    /// the UI ignores failures here.
    func markImportSeen(id: ImportJobID) async throws
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

    // MARK: Images
    /// Bytes for a stored image (JPEG/PNG/HEIC). Default throws.
    func imageData(_ image: ImageRef) async throws -> Data

    // MARK: Weekly plan (per book; Monday-based weeks; shopping reconciled by the domain)
    /// `nil` when no plan exists for that book and week yet.
    func readWeek(bookID: BookID, weekStart: PlanDate) async throws -> WeeklyPlan?
    /// `dayStyles` has exactly seven entries, Monday first; `nil` = don't plan that day.
    /// Generated ingredients are reconciled into `listID` by the domain.
    func generateWeek(bookID: BookID, weekStart: PlanDate, dayStyles: [MealStyle?], listID: ShoppingListID,
                      expectedVersion: Int?) async throws -> WeeklyPlan
    /// Replaces (or with `nil`, clears) one day. Throws a user-readable error on version conflict.
    func replacePlanDay(bookID: BookID, weekStart: PlanDate, date: PlanDate, replacement: PlanReplacement?,
                        planVersion: Int) async throws -> WeeklyPlan
    /// Deletes the week's plan; its generated shopping items are removed by reconciliation.
    func deleteWeek(bookID: BookID, weekStart: PlanDate, planVersion: Int) async throws

    // MARK: Account
    /// Shared books where the user is the last owner and other members remain.
    func accountDeletionBlockers() async throws -> [BookDetail]
    /// Deletes the account. Must include a resolution for every blocker book.
    func deleteAccount(resolutions: [BookID: LastOwnerResolution]) async throws
}

/// Guest (on-device) mode. Default implementations throw so existing adapters keep compiling;
/// the app layer replaces them with its real local store.
public extension RecipeBookService {
    /// Records the choice to use the app without an account and returns `.guest`.
    func continueWithoutSignIn() async throws -> SessionState { throw RecipeBookUIError.serviceNotConfigured }
    /// Called only after the user explicitly agrees. Uploads a copy of an on-device book and its
    /// recipes into a new book of `kind` in the signed-in account (`.shared` when the user is sharing it).
    /// The on-device book is kept and never auto-migrated.
    func copyLocalBookToAccount(id: BookID, kind: BookKind) async throws -> BookSummary { throw RecipeBookUIError.serviceNotConfigured }
}

/// Images and weekly planning. Default implementations throw until the app layer maps the real
/// image store and planner domain; there is no local fake.
public extension RecipeBookService {
    func imageData(_ image: ImageRef) async throws -> Data { throw RecipeBookUIError.serviceNotConfigured }
    func readWeek(bookID: BookID, weekStart: PlanDate) async throws -> WeeklyPlan? { throw RecipeBookUIError.serviceNotConfigured }
    func generateWeek(bookID: BookID, weekStart: PlanDate, dayStyles: [MealStyle?], listID: ShoppingListID,
                      expectedVersion: Int?) async throws -> WeeklyPlan { throw RecipeBookUIError.serviceNotConfigured }
    func replacePlanDay(bookID: BookID, weekStart: PlanDate, date: PlanDate, replacement: PlanReplacement?,
                        planVersion: Int) async throws -> WeeklyPlan { throw RecipeBookUIError.serviceNotConfigured }
    func deleteWeek(bookID: BookID, weekStart: PlanDate, planVersion: Int) async throws { throw RecipeBookUIError.serviceNotConfigured }
}

/// Book-scoped imports. Defaults throw until the app layer binds jobs to destination books.
public extension RecipeBookService {
    func submitImport(url: URL, bookID: BookID) async throws -> ImportJob { throw RecipeBookUIError.serviceNotConfigured }
    func markImportSeen(id: ImportJobID) async throws { throw RecipeBookUIError.serviceNotConfigured }
}

/// The narrow surface the Share Extension needs. Implemented by the app layer over the shared
/// (Keychain) credentials; throw `RecipeBookUIError.signInRequired(.importing)` when there is no
/// Google session. Never report success before the server has durably queued the import.
public protocol ReelShareService: Sendable {
    /// Account books the user may add recipes to.
    func shareDestinations() async throws -> [BookSummary]
    /// Creates a personal account book.
    func createBook(name: String) async throws -> BookSummary
    func queueImport(url: URL, bookID: BookID) async throws -> ImportJob
}

public enum RecipeBookUIError: LocalizedError, Equatable, Sendable {
    case serviceNotConfigured
    /// Thrown by a guest-mode service for cloud-only operations; the UI offers Google sign-in.
    case signInRequired(SignInFeature)

    public var errorDescription: String? {
        switch self {
        case .serviceNotConfigured:
            return "Recipe Book isn’t connected to its service yet."
        case .signInRequired(let feature):
            return "\(feature.title). \(feature.message)"
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
