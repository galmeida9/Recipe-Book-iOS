import Foundation
import RecipeBookCore
import RecipeBookPresentation

actor GuestService: RecipeBookService {
    private let store: GuestStore
    private var bookVersions: [String: Int] = [:]
    private var recipeVersions: [String: Int] = [:]
    private var listVersions: [String: Int] = [:]

    init(localDirectory: URL) throws { store = try GuestStore(directory: localDirectory) }
    init(store: GuestStore) { self.store = store }

    func loadSession() async throws -> SessionState {
        try Task.checkCancellation()
        return try store.read().mode == .guest ? .guest : .signedOut
    }
    func continueWithoutSignIn() async throws -> SessionState {
        try store.transaction { $0.mode = .guest }
        return .guest
    }
    func signOut() async throws { try store.transaction { $0.mode = .none } }
    func signIn() async throws -> SessionState { throw RecipeBookUIError.serviceNotConfigured }
    func completeSetup(displayName: String) async throws -> SessionState { throw gate(.account) }

    private func state() throws -> GuestStore.State {
        try Task.checkCancellation()
        let state = try store.read()
        guard state.mode != .none else { throw gate(.account) }
        return state
    }
    private func gate(_ feature: SignInFeature) -> RecipeBookUIError { .signInRequired(feature) }
    private func missing(_ name: String) -> APIError { guestFailure("\(name) not found.", status: 404, code: "not_found") }
    private func check(_ actual: Int, _ expected: Int?) throws {
        guard let expected else { throw guestFailure("Reload this item before editing.") }
        guard actual == expected else { throw guestFailure("This item changed. Reload before saving.", status: 412, code: "version_conflict") }
    }
    private func text(_ value: String, limit: Int, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit else { throw guestFailure("Invalid \(field).", status: 400, code: "validation") }
        return trimmed
    }
    private func ingredient(_ value: Ingredient) throws -> Ingredient {
        var next = value
        next.name = try text(value.name, limit: 200, field: "ingredient name")
        if let quantity = value.quantity { _ = try GuestQuantities.parse(quantity) }
        if let unit = value.unit { next.unit = try text(unit, limit: 40, field: "unit") }
        if let preparation = value.preparation { next.preparation = try text(preparation, limit: 300, field: "preparation") }
        return next
    }
    func books() async throws -> [BookSummary] {
        let value = try state()
        for book in value.books { bookVersions[book.id] = book.version }
        return value.books.map { value.summary($0) }
    }
    func createBook(name: String, kind: RecipeBookPresentation.BookKind) async throws -> BookSummary {
        _ = try state()
        guard kind == .personal else { throw gate(.sharing) }
        let name = try text(name, limit: 120, field: "book name")
        let book = GuestStore.Book(id: GuestStore.newID(), name: name, version: 1)
        let result = try store.transaction { state in
            state.books.append(book)
            return state.summary(book)
        }
        bookVersions[book.id] = book.version
        return result
    }
    func book(id: BookID) async throws -> BookDetail {
        let value = try state()
        guard let book = value.books.first(where: { $0.id == id }) else { throw missing("Book") }
        bookVersions[id] = book.version
        let recipes = value.recipes.filter { $0.bookID == id }
        for recipe in recipes { recipeVersions[recipe.id] = recipe.version }
        return BookDetail(summary: value.summary(book), currentUserID: value.identity,
                          recipes: recipes.map { $0.detail(identity: value.identity).summary },
                          members: [.init(id: value.identity, displayName: "On this device", role: .owner)])
    }
    func deleteBook(id: BookID) async throws {
        let value = try state()
        guard let book = value.books.first(where: { $0.id == id }) else { throw missing("Book") }
        let expected = bookVersions[id] ?? book.version
        try store.transaction { state in
            guard let current = state.books.first(where: { $0.id == id }) else { throw missing("Book") }
            try check(current.version, expected)
            state.books.removeAll { $0.id == id }
            state.recipes.removeAll { $0.bookID == id }
        }
        bookVersions[id] = nil
        for recipe in value.recipes where recipe.bookID == id { recipeVersions[recipe.id] = nil }
    }
    func recipe(id: RecipeID) async throws -> RecipeDetail {
        let value = try state()
        guard let recipe = value.recipes.first(where: { $0.id == id }),
              value.books.contains(where: { $0.id == recipe.bookID }) else { throw missing("Recipe") }
        recipeVersions[id] = recipe.version
        return recipe.detail(identity: value.identity)
    }
    func saveRecipe(_ draft: RecipeBookPresentation.RecipeDraft) async throws -> RecipeDetail {
        _ = try state()
        guard let bookID = draft.bookID else { throw guestFailure("Choose a destination book before saving.") }
        let title = try text(draft.title, limit: 200, field: "recipe title")
        guard draft.ingredients.count <= 200, draft.steps.count <= 100,
              draft.servings.map({ (1...1000).contains($0) }) ?? true,
              draft.totalMinutes.map({ (1...100_000).contains($0) }) ?? true else {
            throw guestFailure("Recipe fields exceed the supported limits.", status: 400, code: "validation")
        }
        if let url = draft.sourceURL {
            guard url.scheme != nil, url.absoluteString.count <= 2048 else { throw guestFailure("Invalid source URL.") }
        }
        guard Set(draft.ingredients.map(\.id)).count == draft.ingredients.count,
              Set(draft.steps.map(\.id)).count == draft.steps.count,
              draft.ingredients.allSatisfy({ !$0.id.isEmpty }), draft.steps.allSatisfy({ !$0.id.isEmpty }) else {
            throw guestFailure("Ingredient and step identifiers must be unique.")
        }
        let lines = try draft.ingredients.map {
            GuestStore.Line(id: $0.id, ingredient: try ingredient(.init(name: $0.name, quantity: $0.quantity,
                            unit: $0.unit, preparation: $0.preparation)),
                            originalText: $0.originalText, amountNeedsReview: $0.amountNeedsReview)
        }
        let steps = try draft.steps.map { GuestStore.Step(id: $0.id, text: try text($0.text, limit: 4000, field: "step")) }
        let id = draft.recipeID ?? GuestStore.newID()
        let expected = recipeVersions[id]
        let saved = try store.transaction { state in
            guard let bookIndex = state.books.firstIndex(where: { $0.id == bookID }) else { throw missing("Book") }
            var version = 1
            var evidenceText = draft.evidenceText
            if draft.recipeID != nil {
                guard let existing = state.recipes.first(where: { $0.id == id }), existing.bookID == bookID else {
                    throw guestFailure("Reload the recipe before editing. Recipes cannot be moved between books.")
                }
                try check(existing.version, expected)
                version = existing.version + 1
                evidenceText = evidenceText ?? existing.evidenceText
            }
            let recipe = GuestStore.Recipe(id: id, bookID: bookID, version: version, title: title,
                         servings: draft.servings, totalMinutes: draft.totalMinutes, ingredients: lines,
                         steps: steps, sourceURL: draft.sourceURL, evidenceText: evidenceText)
            state.recipes.removeAll { $0.id == id }
            state.recipes.append(recipe)
            state.books[bookIndex].version += 1
            return (recipe, state.identity, state.books[bookIndex].version)
        }
        recipeVersions[id] = saved.0.version
        bookVersions[bookID] = saved.2
        return saved.0.detail(identity: saved.1)
    }
    func deleteRecipe(id: RecipeID) async throws {
        _ = try state()
        let expected = recipeVersions[id]
        let changed = try store.transaction { state in
            guard let recipe = state.recipes.first(where: { $0.id == id }),
                  let bookIndex = state.books.firstIndex(where: { $0.id == recipe.bookID }) else { throw missing("Recipe") }
            try check(recipe.version, expected)
            state.recipes.removeAll { $0.id == id }
            state.books[bookIndex].version += 1
            return state.books[bookIndex]
        }
        recipeVersions[id] = nil
        bookVersions[changed.id] = changed.version
    }
    func suggestions(have ingredients: [String]) async throws -> [RecipeSuggestion] {
        let value = try state()
        let have = Set(ingredients.map(GuestQuantities.normalized))
        var result: [RecipeSuggestion] = []
        for recipe in value.recipes {
            guard let book = value.books.first(where: { $0.id == recipe.bookID }) else { continue }
            let names = recipe.ingredients.map { $0.ingredient.name }
            let matched = names.filter { have.contains(GuestQuantities.normalized($0)) }
            guard !matched.isEmpty else { continue }
            recipeVersions[recipe.id] = recipe.version
            result.append(.init(recipe: recipe.detail(identity: value.identity).summary, bookName: book.name,
                                matchedIngredients: matched,
                                missingIngredients: names.filter { !have.contains(GuestQuantities.normalized($0)) }))
        }
        return result.sorted {
            if $0.matchedIngredients.count != $1.matchedIngredients.count { return $0.matchedIngredients.count > $1.matchedIngredients.count }
            return $0.id < $1.id
        }
    }
    func shoppingLists() async throws -> [ShoppingListSummary] {
        let value = try state()
        for list in value.lists { listVersions[list.id] = list.version }
        return value.lists.map(\.summary)
    }
    func shoppingList(id: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        let value = try state()
        guard let list = value.lists.first(where: { $0.id == id }) else { throw missing("Shopping list") }
        listVersions[id] = list.version
        return list.presentation
    }
    func createShoppingList(name: String) async throws -> ShoppingListSummary {
        _ = try state()
        let name = try text(name, limit: 120, field: "shopping list name")
        let list = GuestStore.List(id: GuestStore.newID(), name: name, version: 1, items: [])
        try store.transaction { $0.lists.append(list) }
        listVersions[list.id] = 1
        return list.summary
    }
    private func mutateList(_ id: String, _ body: (inout GuestStore.List, GuestStore.State) throws -> Void) throws -> RecipeBookPresentation.ShoppingList {
        let value = try state()
        guard let list = value.lists.first(where: { $0.id == id }) else { throw missing("Shopping list") }
        let expected = listVersions[id] ?? list.version
        let updated = try store.transaction { state in
            guard let index = state.lists.firstIndex(where: { $0.id == id }) else { throw missing("Shopping list") }
            var list = state.lists[index]
            try check(list.version, expected)
            try body(&list, state)
            list.version += 1
            state.lists[index] = list
            return list
        }
        listVersions[id] = updated.version
        return updated.presentation
    }
    func deleteShoppingList(id: ShoppingListID) async throws {
        let value = try state()
        guard let list = value.lists.first(where: { $0.id == id }) else { throw missing("Shopping list") }
        let expected = listVersions[id] ?? list.version
        try store.transaction { state in
            guard let list = state.lists.first(where: { $0.id == id }) else { throw missing("Shopping list") }
            try check(list.version, expected)
            state.lists.removeAll { $0.id == id }
        }
        listVersions[id] = nil
    }
    func addShoppingItem(_ item: ShoppingItemDraft, to listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        let value = try ingredient(.init(name: item.name, quantity: item.quantity, unit: item.unit))
        return try mutateList(listID) { list, _ in try GuestQuantities.append(value, title: nil, to: &list.items) }
    }
    func setShoppingItem(_ itemID: ShoppingItemID, bought: Bool, in listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        try mutateList(listID) { list, _ in
            guard let index = list.items.firstIndex(where: { $0.id == itemID }) else { throw missing("Shopping item") }
            list.items[index].bought = bought
        }
    }
    func removeShoppingItem(_ itemID: ShoppingItemID, from listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        try mutateList(listID) { list, _ in
            guard list.items.contains(where: { $0.id == itemID }) else { throw missing("Shopping item") }
            list.items.removeAll { $0.id == itemID }
        }
    }
    func addRecipeIngredients(recipeID: RecipeID, ingredientIDs: [String], to listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        let expected = recipeVersions[recipeID]
        return try mutateList(listID) { list, state in
            guard let recipe = state.recipes.first(where: { $0.id == recipeID }),
                  state.books.contains(where: { $0.id == recipe.bookID }) else { throw missing("Recipe") }
            try check(recipe.version, expected)
            let selected = Set(ingredientIDs)
            guard selected.isSubset(of: Set(recipe.ingredients.map(\.id))) else { throw guestFailure("Ingredient selections do not match this recipe.") }
            for line in recipe.ingredients where selected.contains(line.id) {
                try GuestQuantities.append(line.ingredient, title: recipe.title, to: &list.items)
            }
        }
    }
    /// Used by the wrapper when an explicitly selected cloud recipe is added to a local list.
    func addSelectedIngredients(_ values: [IngredientLine], title: String, to listID: String) throws -> RecipeBookPresentation.ShoppingList {
        try mutateList(listID) { list, _ in
            for value in values {
                let next = try ingredient(.init(name: value.name, quantity: value.quantity, unit: value.unit, preparation: value.preparation))
                try GuestQuantities.append(next, title: title, to: &list.items)
            }
        }
    }
    func addMember(accountID: UserID, to bookID: BookID) async throws -> BookDetail { throw gate(.sharing) }
    func changeRole(of userID: UserID, to role: MemberRole, in bookID: BookID) async throws -> BookDetail { throw gate(.sharing) }
    func removeMember(_ userID: UserID, from bookID: BookID) async throws -> BookDetail { throw gate(.sharing) }
    func leaveBook(id: BookID, resolution: LastOwnerResolution?) async throws { throw gate(.sharing) }
    func copyLocalBookToAccount(id: BookID, kind: RecipeBookPresentation.BookKind) async throws -> BookSummary { throw gate(.sharing) }
    func importJobs() async throws -> [RecipeBookPresentation.ImportJob] { throw gate(.importing) }
    func importJob(id: ImportJobID) async throws -> RecipeBookPresentation.ImportJob { throw gate(.importing) }
    func submitImport(url: URL) async throws -> RecipeBookPresentation.ImportJob { throw gate(.importing) }
    func importReview(id: ImportJobID) async throws -> RecipeBookPresentation.RecipeDraft { throw gate(.importing) }
    func approveImport(id: ImportJobID, draft: RecipeBookPresentation.RecipeDraft) async throws -> RecipeDetail { throw gate(.importing) }
    func retryImport(id: ImportJobID) async throws -> RecipeBookPresentation.ImportJob { throw gate(.importing) }
    func discardImport(id: ImportJobID) async throws { throw gate(.importing) }
    func accountDeletionBlockers() async throws -> [BookDetail] { throw gate(.account) }
    func deleteAccount(resolutions: [BookID: LastOwnerResolution]) async throws { throw gate(.account) }
}
