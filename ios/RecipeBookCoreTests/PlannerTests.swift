import Foundation
import Testing
@testable import RecipeBookCore

private let plannerBook = UUID()
private let plannerMonday = "2026-11-16"
private func plannerRecipe(style: MealStyle? = .simple, quantity: String? = "1", unit: String? = "kg",
                           servings: Int? = 2, book: UUID = plannerBook, version: Int = 1) -> PlannerRecipe {
    PlannerRecipe(id: UUID(), bookId: book, version: version, mealStyle: style,
                  ingredients: [Ingredient(name: "flour", quantity: quantity, unit: unit)], servings: servings)
}
private func singleDay(_ recipe: PlannerRecipe) throws -> WeeklyPlan {
    try CookingPlanner.generate(bookId: plannerBook, weekStart: plannerMonday,
                                styles: [.simple, nil, nil, nil, nil, nil, nil], recipes: [recipe])
}

@Test func plannerRulesAndDateOnlyISOWeeks() throws {
    let empty: [MealStyle?] = Array(repeating: nil, count: 7)
    #expect(try CookingPlanner.applying(.weekdays, style: .simple, to: empty) == [.simple, .simple, .simple, .simple, .simple, nil, nil])
    #expect(try CookingPlanner.applying(.weekend, style: .full, to: empty) == [nil, nil, nil, nil, nil, .full, .full])
    #expect(try CookingPlanner.applying(.all, style: .complicated, to: empty) == Array(repeating: .complicated, count: 7))
    #expect(try CookingPlanner.applying(.specific([0, 3]), style: .full, to: empty) == [.full, nil, nil, .full, nil, nil, nil])
    #expect(try CookingPlanner.weekDates("2026-12-28").last == "2027-01-03")
    for invalid in ["2026-11-15", "2026-02-30", "2026-11-16T00:00:00Z", "0000-01-01"] {
        #expect(throws: PlannerError.self) { try CookingPlanner.weekDates(invalid) }
    }
}
@Test func plannerUsesExplicitStylesAndSelectedInventory() throws {
    let recipes = (0..<7).map { _ in plannerRecipe() }
    let plan = try CookingPlanner.generate(bookId: plannerBook, weekStart: plannerMonday,
                                          styles: Array(repeating: .simple, count: 7), recipes: recipes)
    #expect(Set(plan.days.compactMap { $0.slot?.recipeId }).count == 7)
    let irrelevant = [plannerRecipe(style: nil), plannerRecipe(style: .full, book: UUID())]
    let empty = try CookingPlanner.generate(bookId: plannerBook, weekStart: plannerMonday,
                                           styles: Array(repeating: .full, count: 7), recipes: irrelevant)
    let result = try CookingPlanner.reconcile(empty, recipes: irrelevant)
    #expect(result.generated.isEmpty)
    #expect(result.warnings.count == 7)
    #expect(result.plan.days.allSatisfy { $0.slot == nil })
}
@Test func plannerRegenerationIsIdempotentAndReportsLimitedInventory() throws {
    let recipes = [plannerRecipe()]
    let plan = try CookingPlanner.generate(bookId: plannerBook, weekStart: plannerMonday,
                                          styles: Array(repeating: .simple, count: 7), recipes: recipes)
    let first = try CookingPlanner.reconcile(plan, recipes: recipes)
    #expect(first.warnings.filter { $0.code == .repeated_recipe }.count == 6)
    #expect(first.generated.first?.ingredient.quantity == "7000")
    #expect(first.generated.first?.contributions.count == 7)
    let regenerated = try CookingPlanner.generate(bookId: plannerBook, weekStart: plannerMonday,
        styles: Array(repeating: .simple, count: 7), recipes: recipes, existing: plan, expectedVersion: 1)
    let second = try CookingPlanner.reconcile(regenerated, recipes: recipes, previous: first.generated)
    #expect(second.generated == first.generated)
    #expect(regenerated.days.compactMap(\.slot).map(\.id) == plan.days.compactMap(\.slot).map(\.id))
    #expect(throws: PlannerError.self) {
        try CookingPlanner.generate(bookId: plannerBook, weekStart: plannerMonday, styles: Array(repeating: .simple, count: 7),
                                    recipes: recipes, existing: regenerated, expectedVersion: 1)
    }
}
@Test func plannerGeneratedChecksResetOnIncreaseButPreserveEqualOrReducedAmounts() throws {
    let recipe = plannerRecipe()
    let plan = try singleDay(recipe)
    var first = try CookingPlanner.reconcile(plan, recipes: [recipe])
    first.generated[0].bought = true
    #expect(try CookingPlanner.reconcile(plan, recipes: [recipe], previous: first.generated).generated[0].bought)
    let smaller = try CookingPlanner.replacing(plan, date: plannerMonday,
        replacement: PlanSlot(recipeId: recipe.id, recipeVersion: 1, servings: 1), recipes: [recipe], expectedVersion: 1)
    #expect(try CookingPlanner.reconcile(smaller, recipes: [recipe], previous: first.generated).generated[0].bought)
    let larger = try CookingPlanner.replacing(plan, date: plannerMonday,
        replacement: PlanSlot(recipeId: recipe.id, recipeVersion: 1, servings: 3), recipes: [recipe], expectedVersion: 1)
    let increased = try CookingPlanner.reconcile(larger, recipes: [recipe], previous: first.generated)
    #expect(!increased.generated[0].bought)
    #expect(increased.generated[0].ingredient.quantity == "1500")
    let removed = try CookingPlanner.replacing(plan, date: plannerMonday, replacement: nil, recipes: [recipe], expectedVersion: 1)
    #expect(try CookingPlanner.reconcile(removed, recipes: [recipe], previous: first.generated).generated.isEmpty)
}
@Test func plannerReplacementIsBookAndVersionGuardedAndLeavesManualStateUntouched() throws {
    let recipe = plannerRecipe()
    let plan = try singleDay(recipe)
    let manual = ShoppingItem(ingredient: recipe.ingredients[0], bought: true)
    let before = try JSONEncoder().encode(manual)
    let foreign = plannerRecipe(book: UUID())
    #expect(throws: PlannerError.self) {
        try CookingPlanner.replacing(plan, date: plannerMonday,
            replacement: PlanSlot(recipeId: foreign.id, recipeVersion: 1, servings: 2), recipes: [foreign], expectedVersion: 1)
    }
    #expect(throws: PlannerError.self) {
        try CookingPlanner.replacing(plan, date: plannerMonday,
            replacement: PlanSlot(recipeId: recipe.id, recipeVersion: 2, servings: 2), recipes: [recipe], expectedVersion: 1)
    }
    _ = try CookingPlanner.reconcile(plan, recipes: [recipe])
    #expect(try JSONEncoder().encode(manual) == before)
}
@Test func plannerUnknownAmountsNeverMergeAndUnknownServingsAreNotInvented() throws {
    let unknown = plannerRecipe(quantity: nil, unit: nil, servings: nil)
    let plan = try CookingPlanner.generate(bookId: plannerBook, weekStart: plannerMonday,
        styles: Array(repeating: .simple, count: 7), recipes: [unknown])
    let result = try CookingPlanner.reconcile(plan, recipes: [unknown])
    #expect(result.generated.count == 7)
    #expect(result.plan.days.allSatisfy { $0.slot?.servings == nil })
    #expect(throws: PlannerError.self) { try CookingPlanner.scaledIngredients(unknown, servings: 1) }
    let fractional = plannerRecipe(quantity: "1", unit: "g", servings: 3)
    #expect(try CookingPlanner.scaledIngredients(fractional, servings: 1)[0].quantity == "0.333334")
    #expect(throws: PlannerError.self) {
        try CookingPlanner.scaledIngredients(plannerRecipe(quantity: "999999999", servings: 1), servings: 1000)
    }
}
@Test func plannerStaleOrRevokedInventoryDoesNotReturnSnapshots() throws {
    let recipe = plannerRecipe()
    let plan = try singleDay(recipe)
    let generated = try CookingPlanner.reconcile(plan, recipes: [recipe]).generated
    let changed = PlannerRecipe(id: recipe.id, bookId: recipe.bookId, version: 2, mealStyle: recipe.mealStyle,
                                ingredients: recipe.ingredients, servings: recipe.servings)
    for inventory in [[], [changed]] {
        let result = try CookingPlanner.reconcile(plan, recipes: inventory, previous: generated)
        #expect(result.generated.isEmpty)
        #expect(result.plan.days[0].slot == nil)
        #expect(result.warnings.contains { $0.code == .recipe_unavailable })
    }
}
@Test func plannerPersistedEnvelopeRoundTripsPreferencesReplacementAndProvenance() throws {
    let recipe = plannerRecipe()
    let result = try CookingPlanner.reconcile(singleDay(recipe), recipes: [recipe])
    let stored = StoredPlanResult(plan: result.plan, generated: result.generated, listId: UUID())
    let data = try JSONEncoder().encode(stored)
    let decoded = try JSONDecoder().decode(StoredPlanResult.self, from: data)
    #expect(decoded.plan == stored.plan)
    #expect(decoded.generated == stored.generated)
    #expect(decoded.listId == stored.listId)
    #expect(!String(decoding: data, as: UTF8.self).contains("title"))
}
