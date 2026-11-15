import Foundation
import RecipeBookCore
import RecipeBookPresentation

func guestFailure(_ message: String, status: Int = 0, code: String = "client_state") -> APIError {
    APIError(status: status, code: code, message: message)
}

/// The copy transport must POST this exact payload with `idempotencyKey` as Idempotency-Key.
/// It must use the authenticated account identified by accountID, not whichever account is current later.
struct LocalBookCopy: Codable, Sendable {
    struct Payload: Codable, Sendable {
        let name: String
        let kind: RecipeBookCore.BookKind
        let recipes: [RecipeBookCore.RecipeDraft]
    }
    let accountID: String
    let localBookID: String
    let localVersion: Int
    let idempotencyKey: UUID
    let payload: Payload
}

/// Synchronous transactions prevent actor reentrancy between a version check and atomic persistence.
/// The process-wide lock also coordinates independently reopened services using the same directory.
final class GuestStore: @unchecked Sendable {
    enum Mode: String, Codable { case none, guest, account }
    struct Line: Codable {
        var id: String
        var ingredient: Ingredient
        var originalText: String?
        var amountNeedsReview: Bool
        var presentation: IngredientLine {
            IngredientLine(id: id, name: ingredient.name, quantity: ingredient.quantity,
                           unit: ingredient.unit, preparation: ingredient.preparation,
                           originalText: originalText, amountNeedsReview: amountNeedsReview)
        }
    }
    struct Step: Codable { var id: String; var text: String }
    struct Recipe: Codable {
        var id: String
        var bookID: String
        var version: Int
        var title: String
        var servings: Int?
        var totalMinutes: Int?
        var ingredients: [Line]
        var steps: [Step]
        var sourceURL: URL?
        var evidenceText: String?
        var coreDraft: RecipeBookCore.RecipeDraft {
            .init(title: title, ingredients: ingredients.map(\.ingredient), steps: steps.map(\.text),
                  servings: servings, totalMinutes: totalMinutes, sourceURL: sourceURL)
        }
        func detail(identity: String) -> RecipeDetail {
            RecipeDetail(summary: RecipeSummary(id: id, bookID: bookID, title: title,
                         authorID: identity, authorName: "On this device", totalMinutes: totalMinutes,
                         servings: servings), ingredients: ingredients.map(\.presentation),
                         steps: steps.map { RecipeStep(id: $0.id, text: $0.text) }, sourceURL: sourceURL)
        }
    }
    struct Book: Codable { var id: String; var name: String; var version: Int }
    struct Item: Codable {
        var id: String
        var ingredient: Ingredient
        var bought: Bool
        var sourceRecipeTitle: String?
    }
    struct List: Codable {
        var id: String
        var name: String
        var version: Int
        var items: [Item]
        var presentation: RecipeBookPresentation.ShoppingList {
            .init(id: id, name: name, items: items.map {
                .init(id: $0.id, name: $0.ingredient.name, quantity: $0.ingredient.quantity,
                      unit: $0.ingredient.unit, isBought: $0.bought, sourceRecipeTitle: $0.sourceRecipeTitle)
            })
        }
        var summary: ShoppingListSummary {
            .init(id: id, name: name, remainingCount: items.filter { !$0.bought }.count, totalCount: items.count)
        }
    }
    struct CopyRecord: Codable {
        let operation: LocalBookCopy
        var result: RecipeBookCore.Book?
    }
    struct State: Codable {
        var schema = 1
        var identity = GuestStore.newID()
        var mode: Mode = .none
        var books: [Book] = []
        var recipes: [Recipe] = []
        var lists: [List] = []
        var copies: [CopyRecord] = []
        func summary(_ book: Book) -> BookSummary {
            .init(id: book.id, name: book.name, kind: .personal, myRole: .owner,
                  recipeCount: recipes.filter { $0.bookID == book.id }.count, memberCount: 1, storage: .onDevice)
        }
    }
    private static let lock = NSLock()
    private let file: URL

    init(directory: URL) throws {
        guard directory.isFileURL else { throw guestFailure("Local storage requires a file directory.") }
        file = directory.appendingPathComponent("guest-store.json")
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) { _ = try readUnlocked() }
            else { try writeUnlocked(State()) }
        } catch { throw storageError(error) }
    }
    static func newID() -> String { "device-" + UUID().uuidString.lowercased() }
    static func isLocal(_ id: String) -> Bool { id.hasPrefix("device-") }
    func read() throws -> State {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try readUnlocked()
    }
    func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
        try Task.checkCancellation()
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var next = try readUnlocked()
        let result = try body(&next)
        try Task.checkCancellation()
        try writeUnlocked(next)
        return result
    }
    private func readUnlocked() throws -> State {
        do {
            let value = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard value.schema == 1 else { throw guestFailure("Unsupported on-device data version.") }
            return value
        } catch { throw storageError(error) }
    }
    private func writeUnlocked(_ state: State) throws {
        do { try JSONEncoder().encode(state).write(to: file, options: .atomic) }
        catch { throw storageError(error) }
    }
    private func storageError(_ error: Error) -> APIError {
        guestFailure("Unable to read or save on-device recipes. Data has not been reset. \(error.localizedDescription)",
                     code: "local_storage")
    }
}

/// Backend-compatible fixed-point decimal arithmetic (six places), never binary floating point.
enum GuestQuantities {
    static let scale: Int64 = 1_000_000
    static func parse(_ value: String) throws -> Int64 {
        guard value.range(of: #"^(?:0|[1-9]\d{0,8})(?:\.\d{1,6})?$"#, options: .regularExpression) != nil else {
            throw guestFailure("Invalid ingredient quantity.", status: 400, code: "quantity")
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard let whole = Int64(parts[0]), let decimal = Int64(fraction + String(repeating: "0", count: 6 - fraction.count)) else {
            throw guestFailure("Invalid ingredient quantity.", status: 400, code: "quantity")
        }
        return whole * scale + decimal
    }
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    static func unit(_ text: String?) -> (dimension: String, factor: Int64, output: String)? {
        switch text?.lowercased() {
        case "g": return ("mass", 1, "g")
        case "kg": return ("mass", 1000, "g")
        case "ml": return ("volume", 1, "ml")
        case "l": return ("volume", 1000, "ml")
        case "piece", "pieces": return ("count", 1, "piece")
        default: return nil
        }
    }
    static func compatible(_ a: Ingredient, _ b: Ingredient) -> Bool {
        guard a.quantity != nil, b.quantity != nil, let x = unit(a.unit), let y = unit(b.unit) else { return false }
        return x.dimension == y.dimension && normalized(a.name) == normalized(b.name)
            && normalized(a.preparation ?? "") == normalized(b.preparation ?? "")
    }
    static func append(_ ingredient: Ingredient, title: String?, to items: inout [GuestStore.Item]) throws {
        if let quantity = ingredient.quantity { _ = try parse(quantity) }
        if let index = items.firstIndex(where: { !$0.bought && compatible($0.ingredient, ingredient) }),
           let a = items[index].ingredient.quantity, let b = ingredient.quantity,
           let x = unit(items[index].ingredient.unit), let y = unit(ingredient.unit) {
            let sum = try parse(a) * x.factor + parse(b) * y.factor
            guard sum / scale <= 999_999_999 else {
                throw guestFailure("Combined quantity exceeds the supported range.", status: 400, code: "quantity_overflow")
            }
            let fraction = String(format: "%06lld", sum % scale).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            items[index].ingredient.quantity = "\(sum / scale)" + (fraction.isEmpty ? "" : "." + fraction)
            items[index].ingredient.unit = y.output
        } else {
            items.append(.init(id: GuestStore.newID(), ingredient: ingredient, bought: false, sourceRecipeTitle: title))
        }
        guard items.count <= 1000 else { throw guestFailure("A shopping list can contain at most 1000 entries.", status: 400, code: "list_limit") }
    }
}
