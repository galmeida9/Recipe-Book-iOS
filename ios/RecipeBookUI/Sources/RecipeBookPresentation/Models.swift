import Foundation

// UI-facing presentation values. The app layer maps RecipeBookCore models into these;
// they carry no networking or persistence behaviour.

public typealias UserID = String
public typealias BookID = String
public typealias RecipeID = String
public typealias ImportJobID = String
public typealias ShoppingListID = String
public typealias ShoppingItemID = String

// MARK: - Session / access

public struct UserProfile: Equatable, Hashable, Sendable, Identifiable {
    public var id: UserID
    public var displayName: String

    public init(id: UserID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Access state rendered by `RecipeBookRootView`.
public enum SessionState: Equatable, Sendable {
    /// Not signed in. The hosted OIDC flow itself is owned by the app layer.
    case signedOut
    /// Signed in, but the app administrator has not granted this account access yet (invite-only).
    /// App access is separate from book membership. The account ID is shown so the user can send
    /// it to the administrator.
    case awaitingInvite(accountID: UserID)
    /// Invited, but first-run setup (display name) is incomplete.
    case needsSetup(UserProfile)
    case signedIn(UserProfile)
    /// The user chose to continue without signing in. Personal books, recipes and shopping lists
    /// are stored on this device by the app layer; sharing, imports and account features ask the
    /// user to sign in first.
    case guest
}

/// Cloud-only capabilities that need a signed-in account. Used for contextual sign-in prompts.
public enum SignInFeature: String, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    case sharing
    case importing
    case suggestions
    case account

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sharing: return "Sign in to share books"
        case .importing: return "Sign in to import Reels"
        case .suggestions: return "Sign in for suggestions"
        case .account: return "Sign in to use your account"
        }
    }

    public var message: String {
        switch self {
        case .sharing:
            return "Shared books are stored in your Recipe Book account so other people can view and add recipes. Recipes on this iPhone stay here until you choose to copy them."
        case .importing:
            return "Reel imports are processed by the Recipe Book service, so they need an account. Your recipes on this iPhone stay here."
        case .suggestions:
            return "Suggestions from this service need an account. Your recipes on this iPhone stay here."
        case .account:
            return "Sign in to sync recipes to your account and share books. Recipes on this iPhone stay here."
        }
    }
}

// MARK: - Books & membership

public enum BookKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case personal
    case shared
}

public enum MemberRole: String, Equatable, Hashable, Sendable, CaseIterable {
    case owner
    case member
}

/// Where a book's data lives. Books on the device are never uploaded without explicit consent.
public enum BookStorage: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Stored only on this device (guest data). Always a personal book.
    case onDevice
    /// Stored in the user's Recipe Book account.
    case account
}

public struct BookSummary: Equatable, Hashable, Sendable, Identifiable {
    public var id: BookID
    public var name: String
    public var kind: BookKind
    public var myRole: MemberRole
    public var recipeCount: Int
    public var memberCount: Int
    public var storage: BookStorage

    public init(id: BookID, name: String, kind: BookKind, myRole: MemberRole, recipeCount: Int, memberCount: Int,
                storage: BookStorage = .account) {
        self.id = id
        self.name = name
        self.kind = kind
        self.myRole = myRole
        self.recipeCount = recipeCount
        self.memberCount = memberCount
        self.storage = storage
    }
}

public struct BookMember: Equatable, Hashable, Sendable, Identifiable {
    public var id: UserID
    public var displayName: String
    public var role: MemberRole

    public init(id: UserID, displayName: String, role: MemberRole) {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}

public struct RecipeSummary: Equatable, Hashable, Sendable, Identifiable {
    public var id: RecipeID
    public var bookID: BookID
    public var title: String
    public var authorID: UserID
    public var authorName: String
    public var totalMinutes: Int?
    public var servings: Int?

    public init(id: RecipeID, bookID: BookID, title: String, authorID: UserID, authorName: String,
                totalMinutes: Int? = nil, servings: Int? = nil) {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.authorID = authorID
        self.authorName = authorName
        self.totalMinutes = totalMinutes
        self.servings = servings
    }
}

public struct BookDetail: Equatable, Sendable, Identifiable {
    public var summary: BookSummary
    public var currentUserID: UserID
    public var recipes: [RecipeSummary]
    public var members: [BookMember]

    public var id: BookID { summary.id }

    public init(summary: BookSummary, currentUserID: UserID, recipes: [RecipeSummary], members: [BookMember]) {
        self.summary = summary
        self.currentUserID = currentUserID
        self.recipes = recipes
        self.members = members
    }
}

// MARK: - Recipes

/// Metric unit suggestions offered by the editor. Units stay free-form strings to match the core
/// contract (e.g. "clove" is valid).
public enum MetricUnits {
    public static let common: [String] = ["g", "kg", "ml", "l", "tsp", "tbsp", "pc", "pinch"]
}

public struct IngredientLine: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Decimal string (e.g. "250", "0.5"). `nil` means the amount is unknown; never guess one.
    public var quantity: String?
    public var unit: String?
    public var preparation: String?
    /// Source text exactly as written (manual entry or import evidence), if available.
    public var originalText: String?
    /// Importer was not confident about the amount; the user must confirm or leave it empty.
    public var amountNeedsReview: Bool

    public init(id: String = UUID().uuidString, name: String, quantity: String? = nil, unit: String? = nil,
                preparation: String? = nil, originalText: String? = nil, amountNeedsReview: Bool = false) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.preparation = preparation
        self.originalText = originalText
        self.amountNeedsReview = amountNeedsReview
    }
}

public struct RecipeStep: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String

    public init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }
}

public struct RecipeDetail: Equatable, Sendable, Identifiable {
    public var summary: RecipeSummary
    public var ingredients: [IngredientLine]
    /// Ordered steps; array order is the cooking order.
    public var steps: [RecipeStep]
    public var sourceURL: URL?

    public var id: RecipeID { summary.id }

    public init(summary: RecipeSummary, ingredients: [IngredientLine], steps: [RecipeStep], sourceURL: URL? = nil) {
        self.summary = summary
        self.ingredients = ingredients
        self.steps = steps
        self.sourceURL = sourceURL
    }
}

/// Editable recipe used by the manual editor and import review.
public struct RecipeDraft: Equatable, Sendable {
    /// `nil` when creating a new recipe.
    public var recipeID: RecipeID?
    /// Destination book. Must be chosen explicitly before saving.
    public var bookID: BookID?
    public var title: String
    public var servings: Int?
    public var totalMinutes: Int?
    public var ingredients: [IngredientLine]
    public var steps: [RecipeStep]
    public var sourceURL: URL?
    /// Raw source evidence for imports (caption, comments, transcript), shown read-only during review.
    /// Display only: the UI never derives recipe values from it.
    public var evidenceText: String?

    public init(recipeID: RecipeID? = nil, bookID: BookID? = nil, title: String = "", servings: Int? = nil,
                totalMinutes: Int? = nil, ingredients: [IngredientLine] = [], steps: [RecipeStep] = [],
                sourceURL: URL? = nil, evidenceText: String? = nil) {
        self.recipeID = recipeID
        self.bookID = bookID
        self.title = title
        self.servings = servings
        self.totalMinutes = totalMinutes
        self.ingredients = ingredients
        self.steps = steps
        self.sourceURL = sourceURL
        self.evidenceText = evidenceText
    }

    public init(editing recipe: RecipeDetail) {
        self.init(recipeID: recipe.id, bookID: recipe.summary.bookID, title: recipe.summary.title,
                  servings: recipe.summary.servings, totalMinutes: recipe.summary.totalMinutes,
                  ingredients: recipe.ingredients, steps: recipe.steps, sourceURL: recipe.sourceURL)
    }
}

// MARK: - Suggestions

/// A suggestion drawn only from saved recipes the user can already access.
public struct RecipeSuggestion: Equatable, Sendable, Identifiable {
    public var recipe: RecipeSummary
    public var bookName: String
    public var matchedIngredients: [String]
    public var missingIngredients: [String]

    public var id: RecipeID { recipe.id }

    public init(recipe: RecipeSummary, bookName: String, matchedIngredients: [String], missingIngredients: [String]) {
        self.recipe = recipe
        self.bookName = bookName
        self.matchedIngredients = matchedIngredients
        self.missingIngredients = missingIngredients
    }
}

// MARK: - Imports

public enum ImportStatus: Equatable, Sendable {
    case queued
    case processing
    case reviewRequired
    case failed(reason: String, canRetry: Bool)
    case completed(recipeID: RecipeID, bookID: BookID)
}

public struct ImportJob: Equatable, Sendable, Identifiable {
    public var id: ImportJobID
    public var sourceURL: URL
    public var status: ImportStatus
    public var createdAt: Date
    public var titleHint: String?

    public init(id: ImportJobID, sourceURL: URL, status: ImportStatus, createdAt: Date, titleHint: String? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.status = status
        self.createdAt = createdAt
        self.titleHint = titleHint
    }
}

// MARK: - Shopping (personal lists only)

public struct ShoppingListSummary: Equatable, Hashable, Sendable, Identifiable {
    public var id: ShoppingListID
    public var name: String
    public var remainingCount: Int
    public var totalCount: Int

    public init(id: ShoppingListID, name: String, remainingCount: Int, totalCount: Int) {
        self.id = id
        self.name = name
        self.remainingCount = remainingCount
        self.totalCount = totalCount
    }
}

public struct ShoppingItem: Equatable, Hashable, Sendable, Identifiable {
    public var id: ShoppingItemID
    public var name: String
    public var quantity: String?
    public var unit: String?
    public var isBought: Bool
    public var sourceRecipeTitle: String?

    public init(id: ShoppingItemID, name: String, quantity: String? = nil, unit: String? = nil,
                isBought: Bool = false, sourceRecipeTitle: String? = nil) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.isBought = isBought
        self.sourceRecipeTitle = sourceRecipeTitle
    }
}

public struct ShoppingList: Equatable, Sendable, Identifiable {
    public var id: ShoppingListID
    public var name: String
    public var items: [ShoppingItem]

    public init(id: ShoppingListID, name: String, items: [ShoppingItem]) {
        self.id = id
        self.name = name
        self.items = items
    }
}

public struct ShoppingItemDraft: Equatable, Sendable {
    public var name: String
    public var quantity: String?
    public var unit: String?

    public init(name: String, quantity: String? = nil, unit: String? = nil) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
    }
}

// MARK: - Leaving / account deletion

/// How the last owner of a shared book resolves leaving. There is no automatic promotion.
public enum LastOwnerResolution: Equatable, Hashable, Sendable {
    case transferOwnership(to: UserID)
    case deleteBook
}
