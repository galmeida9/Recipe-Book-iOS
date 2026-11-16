import Foundation

public enum BookKind: String, Codable, Sendable { case personal, shared }
public enum BookRole: String, Codable, Sendable { case owner, member }
public enum ImportState: String, Codable, Sendable {
    case queued, running, review, failed, completed, discarded
}

public struct Book: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: BookKind
    public let role: BookRole
    public let version: Int
}

public struct Membership: Codable, Identifiable, Sendable {
    public var id: UUID { userId }
    public let userId: UUID
    public let role: BookRole
    public let displayName: String?
}

public struct Ingredient: Codable, Equatable, Sendable {
    public var name: String
    // Decimal strings avoid binary floating-point arithmetic in shared contracts.
    public var quantity: String?
    public var unit: String?
    public var preparation: String?

    public init(name: String, quantity: String? = nil, unit: String? = nil, preparation: String? = nil) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.preparation = preparation
    }
}

public struct RecipeDraft: Codable, Sendable {
    public var title: String
    public var ingredients: [Ingredient]
    public var steps: [String]
    public var servings: Int?
    public var totalMinutes: Int?
    public var sourceURL: URL?
    public var mealStyle: MealStyle?
    public var coverImageID: UUID?

    public init(title: String, ingredients: [Ingredient], steps: [String], servings: Int? = nil, totalMinutes: Int? = nil, sourceURL: URL? = nil,
                mealStyle: MealStyle? = nil, coverImageID: UUID? = nil) {
        self.title = title
        self.ingredients = ingredients
        self.steps = steps
        self.servings = servings
        self.totalMinutes = totalMinutes
        self.sourceURL = sourceURL
        self.mealStyle = mealStyle
        self.coverImageID = coverImageID
    }
}

public struct Recipe: Codable, Identifiable, Sendable {
    public let id: UUID
    public let bookId: UUID
    public let authorId: UUID
    public let draft: RecipeDraft
    public let version: Int
}

public struct ImportEvidence: Codable, Sendable {
    public let caption: String?
    public let comments: [String]
    public let transcript: String?
    public let warnings: [String]?
    public let sources: [ImportEvidenceSource]?
}

public struct ImportEvidenceSource: Codable, Sendable {
    public let id: String
    public let kind: String
    public let text: String
}

public struct ImportJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let state: ImportState
    public let sourceURL: URL
    public let draft: RecipeDraft?
    public let evidence: ImportEvidence?
    public let error: String?
    public let version: Int
    public let createdAt: String
    public let recipeId: UUID?
    public let bookId: UUID?
    public let destinationBookId: UUID?
    public let stage: String?
    public let isUnseen: Bool?
    public let canRetry: Bool?
    public let retryReason: String?
}

public struct ShoppingItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let ingredient: Ingredient
    public let bought: Bool
    public init(id: UUID = UUID(), ingredient: Ingredient, bought: Bool = false) {
        self.id = id
        self.ingredient = ingredient
        self.bought = bought
    }
}

public struct ShoppingList: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let items: [ShoppingItem]
    public let version: Int
    public var generated: [GeneratedSection]?
}

public struct SessionAccount: Codable, Sendable {
    public let id: UUID
    public let displayName: String?
    public let access: String?
}
