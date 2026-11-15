import Foundation

public enum MealStyle: String, Codable, CaseIterable, Sendable { case simple, complicated, full }
public enum PlanRule: Sendable { case weekdays, weekend, all, specific([Int]) }
public enum PlannerError: Error, LocalizedError {
    case invalidInput, versionConflict, recipeUnavailable, missingMealStyle, unknownServings, quantityOverflow
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Select a valid Monday-based week, day and ingredient quantity."
        case .versionConflict: "This plan or recipe changed. Reload before saving."
        case .recipeUnavailable: "Choose a current recipe from the selected book."
        case .missingMealStyle: "Set this recipe's meal style before planning it."
        case .unknownServings: "Set the recipe's normal servings before changing planned servings."
        case .quantityOverflow: "Generated quantity exceeds the supported range."
        }
    }
}
public struct PlannerRecipe: Sendable {
    public let id: UUID
    public let bookId: UUID
    public let version: Int
    public let mealStyle: MealStyle?
    public let ingredients: [Ingredient]
    public let servings: Int?
    public init(id: UUID, bookId: UUID, version: Int, mealStyle: MealStyle?, ingredients: [Ingredient], servings: Int?) {
        self.id = id; self.bookId = bookId; self.version = version; self.mealStyle = mealStyle
        self.ingredients = ingredients; self.servings = servings
    }
}
public struct PlanSlot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let recipeId: UUID
    public let recipeVersion: Int
    public let servings: Int?
    public init(id: UUID = UUID(), recipeId: UUID, recipeVersion: Int, servings: Int?) {
        self.id = id; self.recipeId = recipeId; self.recipeVersion = recipeVersion; self.servings = servings
    }
}
public struct PlanDay: Codable, Equatable, Sendable {
    public let date: String
    public var mealStyle: MealStyle?
    public var slot: PlanSlot?
    public init(date: String, mealStyle: MealStyle?, slot: PlanSlot?) {
        self.date = date; self.mealStyle = mealStyle; self.slot = slot
    }
}
public struct WeeklyPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let bookId: UUID
    public let weekStart: String
    public var days: [PlanDay]
    public var version: Int
    public init(id: UUID = UUID(), bookId: UUID, weekStart: String, days: [PlanDay], version: Int) {
        self.id = id; self.bookId = bookId; self.weekStart = weekStart; self.days = days; self.version = version
    }
}
public struct GeneratedContribution: Codable, Equatable, Sendable {
    public let planId: UUID
    public let slotId: UUID
    public let recipeId: UUID
    public let recipeVersion: Int
    public let ingredientIndex: Int
    public let servings: Int?
}
public struct GeneratedShoppingItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let key: String
    public var ingredient: Ingredient
    public var bought: Bool
    public var contributions: [GeneratedContribution]
}
public struct PlannerWarning: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable { case no_eligible_recipe, recipe_unavailable, repeated_recipe }
    public let date: String
    public let code: Code
    public let message: String
}
public struct PlanResult: Codable, Sendable {
    public var plan: WeeklyPlan
    public var generated: [GeneratedShoppingItem]
    public let warnings: [PlannerWarning]
    public init(plan: WeeklyPlan, generated: [GeneratedShoppingItem], warnings: [PlannerWarning]) {
        self.plan = plan; self.generated = generated; self.warnings = warnings
    }
}
/// Reference-only plan plus generated provenance, persisted in the guest store's atomic envelope.
public struct StoredPlanResult: Codable, Sendable {
    public var plan: WeeklyPlan
    public var generated: [GeneratedShoppingItem]
    public let listId: UUID
    public let warnings: [PlannerWarning]
    public init(plan: WeeklyPlan, generated: [GeneratedShoppingItem], listId: UUID, warnings: [PlannerWarning] = []) {
        self.plan = plan; self.generated = generated; self.listId = listId; self.warnings = warnings
    }
}
public enum CookingPlanner {
    private static let precision: Int64 = 1_000_000
    private static let maximum: Int64 = 999_999_999_999_999
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    public static func weekDates(_ start: String) throws -> [String] {
        let parts = start.split(separator: "-", omittingEmptySubsequences: false)
        guard start.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              start.allSatisfy({ $0 == "-" || ("0"..."9").contains(String($0)) }),
              let year = Int(parts[0]), (1900...9999).contains(year), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day, calendar.component(.weekday, from: date) == 2 else {
            throw PlannerError.invalidInput
        }
        return try (0..<7).map { offset in
            guard let next = calendar.date(byAdding: .day, value: offset, to: date) else { throw PlannerError.invalidInput }
            let components = calendar.dateComponents([.year, .month, .day], from: next)
            guard let year = components.year, (1900...9999).contains(year),
                  let month = components.month, let day = components.day else { throw PlannerError.invalidInput }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
    }
    public static func applying(_ rule: PlanRule, style: MealStyle?, to current: [MealStyle?]) throws -> [MealStyle?] {
        guard current.count == 7 else { throw PlannerError.invalidInput }
        let indices: [Int]
        switch rule {
        case .weekdays: indices = Array(0..<5)
        case .weekend: indices = [5, 6]
        case .all: indices = Array(0..<7)
        case .specific(let days): indices = days
        }
        guard indices.allSatisfy({ (0..<7).contains($0) }) else { throw PlannerError.invalidInput }
        return current.enumerated().map { indices.contains($0.offset) ? style : $0.element }
    }
    private static func validate(_ plan: WeeklyPlan) throws {
        let dates = try weekDates(plan.weekStart)
        let slots = plan.days.compactMap(\.slot)
        guard plan.version > 0, plan.days.map(\.date) == dates,
              plan.days.allSatisfy({ $0.slot == nil || $0.mealStyle != nil }),
              Set(slots.map(\.id)).count == slots.count,
              slots.allSatisfy({ $0.recipeVersion > 0 && ($0.servings == nil || (1...1000).contains($0.servings!)) }) else {
            throw PlannerError.invalidInput
        }
    }
    private static func inventory(_ recipes: [PlannerRecipe], bookId: UUID) throws -> [PlannerRecipe] {
        guard recipes.allSatisfy({ $0.version > 0 && $0.ingredients.count <= 200
            && ($0.servings == nil || (1...1000).contains($0.servings!)) }) else { throw PlannerError.invalidInput }
        return recipes.filter { $0.bookId == bookId }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public static func generate(bookId: UUID, weekStart: String, styles: [MealStyle?], recipes: [PlannerRecipe],
                                existing: WeeklyPlan? = nil, expectedVersion: Int? = nil) throws -> WeeklyPlan {
        let dates = try weekDates(weekStart)
        guard styles.count == 7 else { throw PlannerError.invalidInput }
        if let existing {
            try validate(existing)
            guard existing.version == expectedVersion else { throw PlannerError.versionConflict }
            guard existing.bookId == bookId && existing.weekStart == weekStart else { throw PlannerError.invalidInput }
        } else if expectedVersion != nil { throw PlannerError.versionConflict }
        let available = try inventory(recipes, bookId: bookId)
        var uses: [UUID: Int] = [:]
        let days = styles.enumerated().map { index, style in
            let eligible = available.filter { style != nil && $0.mealStyle == style }.sorted {
                let left = uses[$0.id, default: 0], right = uses[$1.id, default: 0]
                return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
            }
            let recipe = eligible.first
            if let recipe { uses[recipe.id, default: 0] += 1 }
            let slot = recipe.map { PlanSlot(id: existing?.days[index].slot?.id ?? UUID(), recipeId: $0.id,
                                             recipeVersion: $0.version, servings: $0.servings) }
            return PlanDay(date: dates[index], mealStyle: style, slot: slot)
        }
        return WeeklyPlan(id: existing?.id ?? UUID(), bookId: bookId, weekStart: weekStart, days: days,
                          version: (existing?.version ?? 0) + 1)
    }
    public static func replacing(_ plan: WeeklyPlan, date: String, replacement: PlanSlot?, recipes: [PlannerRecipe],
                                 expectedVersion: Int) throws -> WeeklyPlan {
        try validate(plan)
        guard plan.version == expectedVersion else { throw PlannerError.versionConflict }
        guard let index = plan.days.firstIndex(where: { $0.date == date }) else { throw PlannerError.invalidInput }
        var updated = plan
        if let replacement {
            guard let recipe = try inventory(recipes, bookId: plan.bookId).first(where: { $0.id == replacement.recipeId }) else {
                throw PlannerError.recipeUnavailable
            }
            guard recipe.version == replacement.recipeVersion else { throw PlannerError.versionConflict }
            guard let style = recipe.mealStyle else { throw PlannerError.missingMealStyle }
            _ = try scaledIngredients(recipe, servings: replacement.servings)
            updated.days[index].mealStyle = style
            updated.days[index].slot = PlanSlot(id: plan.days[index].slot?.id ?? UUID(), recipeId: recipe.id,
                                               recipeVersion: recipe.version, servings: replacement.servings)
        } else { updated.days[index].slot = nil }
        updated.version += 1
        return updated
    }
    private static func decimal(_ value: String) throws -> Int64 {
        guard value.range(of: #"^(?:0|[1-9]\d{0,8})(?:\.\d{1,6})?$"#, options: .regularExpression) != nil else {
            throw PlannerError.invalidInput
        }
        let parts = value.split(separator: ".")
        guard let whole = Int64(parts[0]) else { throw PlannerError.invalidInput }
        let fraction = parts.count == 1 ? "" : String(parts[1])
        guard let micros = Int64(fraction + String(repeating: "0", count: 6 - fraction.count)) else { throw PlannerError.invalidInput }
        return whole * precision + micros
    }
    private static func format(_ value: Int64) throws -> String {
        guard value >= 0 && value <= maximum else { throw PlannerError.quantityOverflow }
        var fraction = String(format: "%06lld", value % precision)
        while fraction.last == "0" { fraction.removeLast() }
        return "\(value / precision)" + (fraction.isEmpty ? "" : "." + fraction)
    }
    public static func scaledIngredients(_ recipe: PlannerRecipe, servings: Int?) throws -> [Ingredient] {
        guard servings == nil || (1...1000).contains(servings!) else { throw PlannerError.invalidInput }
        guard recipe.servings == nil || (1...1000).contains(recipe.servings!) else { throw PlannerError.invalidInput }
        guard servings == recipe.servings || (servings != nil && recipe.servings != nil) else { throw PlannerError.unknownServings }
        return try recipe.ingredients.map { source in
            var ingredient = source
            if let quantity = source.quantity {
                let micros = try decimal(quantity)
                if servings != recipe.servings {
                    ingredient.quantity = try format((micros * Int64(servings!) + Int64(recipe.servings!) - 1) / Int64(recipe.servings!))
                }
            }
            return ingredient
        }
    }
    private static func canonical(_ source: Ingredient) throws -> (Ingredient, Bool) {
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw PlannerError.invalidInput }
        var ingredient = source
        ingredient.name = name
        ingredient.unit = source.unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        ingredient.preparation = source.preparation?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ingredient.unit == nil || (!(ingredient.unit?.isEmpty ?? true) && ingredient.unit!.count <= 40),
              ingredient.preparation == nil || (!(ingredient.preparation?.isEmpty ?? true) && ingredient.preparation!.count <= 300) else {
            throw PlannerError.invalidInput
        }
        guard let quantity = ingredient.quantity else { return (ingredient, false) }
        let micros = try decimal(quantity)
        let factor: Int64, output: String
        switch ingredient.unit?.lowercased() {
        case "g": factor = 1; output = "g"
        case "kg": factor = 1000; output = "g"
        case "ml": factor = 1; output = "ml"
        case "l": factor = 1000; output = "ml"
        case "piece", "pieces": factor = 1; output = "piece"
        default: return (ingredient, false)
        }
        ingredient.quantity = try format(micros * factor)
        ingredient.unit = output
        return (ingredient, true)
    }
    private static func key(_ values: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])
        guard let result = String(data: data, encoding: .utf8) else { throw PlannerError.invalidInput }
        return result
    }
    public static func reconcile(_ plan: WeeklyPlan, recipes: [PlannerRecipe],
                                 previous: [GeneratedShoppingItem] = []) throws -> PlanResult {
        try validate(plan)
        let available = try inventory(recipes, bookId: plan.bookId)
        guard Set(previous.map(\.key)).count == previous.count, Set(previous.map(\.id)).count == previous.count else {
            throw PlannerError.invalidInput
        }
        var result = plan
        var warnings: [PlannerWarning] = []
        var rows: [GeneratedShoppingItem] = []
        var uses: Set<UUID> = []
        for index in plan.days.indices {
            let day = plan.days[index]
            guard let slot = day.slot else {
                if day.mealStyle != nil { warnings.append(PlannerWarning(date: day.date, code: .no_eligible_recipe,
                    message: "No recipe selected. Add or categorize recipes in this book, then generate or choose one.")) }
                continue
            }
            guard let recipe = available.first(where: {
                $0.id == slot.recipeId && $0.version == slot.recipeVersion && $0.mealStyle == day.mealStyle
            }) else {
                result.days[index].slot = nil
                warnings.append(PlannerWarning(date: day.date, code: .recipe_unavailable,
                    message: "The selected recipe changed or is unavailable. Choose a current recipe from this book."))
                continue
            }
            if uses.contains(recipe.id) { warnings.append(PlannerWarning(date: day.date, code: .repeated_recipe,
                message: "This recipe repeats because the selected meal style has limited inventory.")) }
            uses.insert(recipe.id)
            for (ingredientIndex, source) in try scaledIngredients(recipe, servings: slot.servings).enumerated() {
                let (ingredient, compatible) = try canonical(source)
                let rowKey = try compatible ? key([ingredient.name.lowercased(), ingredient.preparation?.lowercased() ?? "", ingredient.unit!])
                    : key([slot.id.uuidString.lowercased(), ingredientIndex])
                let contribution = GeneratedContribution(planId: plan.id, slotId: slot.id, recipeId: recipe.id,
                                                         recipeVersion: recipe.version, ingredientIndex: ingredientIndex, servings: slot.servings)
                if let rowIndex = rows.firstIndex(where: { $0.key == rowKey }) {
                    let quantity = try decimal(rows[rowIndex].ingredient.quantity!) + decimal(ingredient.quantity!)
                    rows[rowIndex].ingredient.quantity = try format(quantity)
                    rows[rowIndex].contributions.append(contribution)
                } else {
                    rows.append(GeneratedShoppingItem(id: previous.first(where: { $0.key == rowKey })?.id ?? UUID(), key: rowKey,
                                                       ingredient: ingredient, bought: false, contributions: [contribution]))
                }
            }
        }
        guard rows.count <= 1000 else { throw PlannerError.quantityOverflow }
        for index in rows.indices {
            guard let old = previous.first(where: { $0.key == rows[index].key }), old.bought else { continue }
            let compatible = try canonical(rows[index].ingredient).1
            if compatible, let before = old.ingredient.quantity, let after = rows[index].ingredient.quantity {
                rows[index].bought = try decimal(after) <= decimal(before)
            } else {
                rows[index].bought = old.ingredient == rows[index].ingredient && old.contributions == rows[index].contributions
            }
        }
        return PlanResult(plan: result, generated: rows, warnings: warnings)
    }
}
