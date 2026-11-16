import Foundation

// Portable presentation rules. They decide what the UI offers; the backend remains the authority.

// MARK: - Permissions

public enum LeaveRequirement: Equatable, Sendable {
    /// Personal books cannot be left, only deleted.
    case personalBookDeleteOnly
    /// Leaving does not affect ownership.
    case canLeave
    /// The user is the only member left; the book can only be deleted.
    case soleMemberMustDelete
    /// Last owner with other members: pick a new owner or delete the book. No automatic promotion.
    case lastOwnerMustTransferOrDelete(candidates: [BookMember])
}

public struct BookPermissions: Equatable, Sendable {
    public let book: BookDetail

    public init(book: BookDetail) { self.book = book }

    private var me: UserID { book.currentUserID }
    public var isOwner: Bool { book.summary.myRole == .owner }
    public var isShared: Bool { book.summary.kind == .shared }
    public var owners: [BookMember] { book.members.filter { $0.role == .owner } }

    /// All members of a book may add recipes.
    public var canAddRecipes: Bool { true }
    public var canManageMembers: Bool { isShared && isOwner }
    public var canDeleteBook: Bool { isOwner }

    /// Owners manage every recipe; members only their own.
    public func canEdit(_ recipe: RecipeSummary) -> Bool { isOwner || recipe.authorID == me }
    public func canDelete(_ recipe: RecipeSummary) -> Bool { canEdit(recipe) }

    public func canChangeRole(of member: BookMember) -> Bool {
        guard canManageMembers else { return false }
        if member.role == .owner { return owners.count > 1 }
        return true
    }

    public func canRemove(_ member: BookMember) -> Bool {
        canManageMembers && member.id != me && !(member.role == .owner && owners.count <= 1)
    }

    public var leaveRequirement: LeaveRequirement {
        guard isShared else { return .personalBookDeleteOnly }
        let others = book.members.filter { $0.id != me }
        if others.isEmpty { return .soleMemberMustDelete }
        if isOwner && owners.allSatisfy({ $0.id == me }) {
            return .lastOwnerMustTransferOrDelete(candidates: others)
        }
        return .canLeave
    }
}

// MARK: - Quantities

public enum QuantityInputError: Error, Equatable, Sendable {
    case notANumber
    case notPositive
}

public enum QuantityText {
    /// Normalises user input to the decimal-string format used by the core contract.
    /// Empty input returns `nil` (amount unknown). Accepts "1,5", "1.5", "1/2" and "1 1/2".
    public static func normalize(_ input: String) -> Result<String?, QuantityInputError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }
        guard let value = parse(trimmed) else { return .failure(.notANumber) }
        guard value > 0 else { return .failure(.notPositive) }
        return .success(format(value))
    }

    static func parse(_ text: String) -> Decimal? {
        let parts = text.split(separator: " ").map(String.init)
        if parts.count == 2, let whole = plainDecimal(parts[0]), let fraction = fraction(parts[1]) {
            return whole + fraction
        }
        guard parts.count == 1 else { return nil }
        return plainDecimal(text) ?? fraction(text)
    }

    private static func plainDecimal(_ text: String) -> Decimal? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        let allowed = CharacterSet(charactersIn: "0123456789.")
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy(allowed.contains),
              normalized.filter({ $0 == "." }).count <= 1,
              normalized != "." else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func fraction(_ text: String) -> Decimal? {
        let pieces = text.split(separator: "/")
        guard pieces.count == 2,
              let n = Int(pieces[0]), let d = Int(pieces[1]), d != 0 else { return nil }
        return Decimal(n) / Decimal(d)
    }

    private static func format(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 3, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    /// Human-readable amount, e.g. "250 g", "2", "1 clove". Returns `nil` when unknown.
    public static func display(quantity: String?, unit: String?) -> String? {
        let q = quantity?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let u = unit?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch (q, u) {
        case let (q?, u?): return "\(q) \(u)"
        case let (q?, nil): return q
        case (nil, _): return nil
        }
    }
}

// MARK: - Draft validation

public enum DraftIssue: Equatable, Hashable, Sendable {
    case missingTitle
    case missingDestinationBook
    case ingredientMissingName(index: Int)
    case invalidQuantity(index: Int)
    case amountsAwaitingReview(count: Int)
    case noSteps

    public var message: String {
        switch self {
        case .missingTitle: return "Add a title."
        case .missingDestinationBook: return "Choose which book to save this recipe in."
        case .ingredientMissingName(let i): return "Ingredient \(i + 1) needs a name."
        case .invalidQuantity(let i): return "Ingredient \(i + 1) has an amount that isn’t a number."
        case .amountsAwaitingReview(let n):
            return n == 1 ? "1 uncertain amount needs your review." : "\(n) uncertain amounts need your review."
        case .noSteps: return "Add at least one step."
        }
    }
}

public enum RecipeDraftRules {
    /// Removes blank rows and trims text. Does not invent any values.
    public static func normalized(_ draft: RecipeDraft) -> RecipeDraft {
        var copy = draft
        copy.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.ingredients = draft.ingredients.compactMap { line in
            var line = line
            line.name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
            line.quantity = line.quantity?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            line.unit = line.unit?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            line.preparation = line.preparation?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            let isBlank = line.name.isEmpty && line.quantity == nil && line.unit == nil
                && line.preparation == nil && (line.originalText ?? "").isEmpty
            return isBlank ? nil : line
        }
        copy.steps = draft.steps.compactMap { step in
            let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : RecipeStep(id: step.id, text: text)
        }
        return copy
    }

    /// Blocking issues for saving. Uncertain imported amounts must be reviewed (edited or
    /// explicitly confirmed as unknown) before saving.
    public static func issues(for draft: RecipeDraft) -> [DraftIssue] {
        let draft = normalized(draft)
        var issues: [DraftIssue] = []
        if draft.title.isEmpty { issues.append(.missingTitle) }
        if draft.bookID == nil { issues.append(.missingDestinationBook) }
        for (index, line) in draft.ingredients.enumerated() {
            if line.name.isEmpty { issues.append(.ingredientMissingName(index: index)) }
            if let q = line.quantity, case .failure = QuantityText.normalize(q) {
                issues.append(.invalidQuantity(index: index))
            }
        }
        let pending = draft.ingredients.filter(\.amountNeedsReview).count
        if pending > 0 { issues.append(.amountsAwaitingReview(count: pending)) }
        if draft.steps.isEmpty { issues.append(.noSteps) }
        return issues
    }
}

// MARK: - Instagram Reel links

public enum ReelLink {
    private static let hosts: Set<String> = ["instagram.com", "www.instagram.com", "m.instagram.com"]

    /// Extracts a public Instagram Reel URL from pasted or shared text. Tracking query
    /// parameters are dropped. Returns `nil` for anything that is not a Reel link.
    public static func extract(from text: String) -> URL? {
        let candidates = text.components(separatedBy: .whitespacesAndNewlines)
        for raw in candidates {
            var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"'.,;"))
            if token.lowercased().hasPrefix("instagram.com") || token.lowercased().hasPrefix("www.instagram.com") {
                token = "https://" + token
            }
            guard let components = URLComponents(string: token),
                  let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = components.host?.lowercased(), hosts.contains(host) else { continue }
            let segments = components.path.split(separator: "/").map(String.init)
            guard segments.count >= 2, segments[0] == "reel" || segments[0] == "reels",
                  segments[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { continue }
            var clean = URLComponents()
            clean.scheme = "https"
            clean.host = "www.instagram.com"
            clean.path = "/reel/\(segments[1])/"
            return clean.url
        }
        return nil
    }
}

// MARK: - Import status presentation

public extension ImportStatus {
    var title: String {
        switch self {
        case .queued: return "Queued"
        case .processing: return "Processing"
        case .reviewRequired: return "Ready for review"
        case .failed: return "Failed"
        case .completed: return "Saved"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "clock"
        case .processing: return "gearshape.2"
        case .reviewRequired: return "checklist"
        case .failed: return "exclamationmark.triangle"
        case .completed: return "checkmark.circle"
        }
    }

    /// Jobs still changing on the server; the UI polls these.
    var isInFlight: Bool {
        switch self {
        case .queued, .processing: return true
        default: return false
        }
    }
}

// MARK: - Have / need selection

/// Recipe-to-shopping-list selection. Everything starts as "need"; ticking "already have"
/// excludes it. Nothing is remembered as a pantry.
public struct IngredientSelection: Equatable, Sendable {
    public private(set) var alreadyHave: Set<String> = []

    public init(alreadyHave: Set<String> = []) { self.alreadyHave = alreadyHave }

    public func has(_ id: String) -> Bool { alreadyHave.contains(id) }

    public mutating func toggleHave(_ id: String) {
        if alreadyHave.contains(id) { alreadyHave.remove(id) } else { alreadyHave.insert(id) }
    }

    public func needed(from ingredients: [IngredientLine]) -> [IngredientLine] {
        ingredients.filter { !alreadyHave.contains($0.id) }
    }
}

// MARK: - Shopping list ordering

public enum ShoppingListRules {
    /// Items still to buy first, bought items after; original order otherwise preserved.
    public static func ordered(_ items: [ShoppingItem]) -> [ShoppingItem] {
        items.filter { !$0.isBought } + items.filter(\.isBought)
    }
}

// MARK: - Input helpers

public enum AccountIDInput {
    /// Account IDs are UUIDs. Returns the canonical (lowercased) form, or `nil` if invalid.
    public static func normalize(_ text: String) -> UserID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
