#if os(iOS) && DEBUG
import SwiftUI
import RecipeBookPresentation

/// In-memory fixtures for Xcode previews ONLY. Compiled out of release builds and never used
/// by the app; it does not represent real networking, imports or cloud behaviour.
actor PreviewRecipeBookService: RecipeBookService {
    private let me = UserProfile(id: "7d3f1c2a-0000-4000-8000-000000000001", displayName: "Maria")
    private let ana = BookMember(id: "7d3f1c2a-0000-4000-8000-000000000002", displayName: "Ana", role: .member)
    private var session: SessionState
    private var bookList: [BookDetail]
    private var recipes: [RecipeID: RecipeDetail]
    private var jobs: [ImportJob]
    private var lists: [ShoppingList]

    init(session: SessionState? = nil) {
        let meMember = BookMember(id: me.id, displayName: me.displayName, role: .owner)
        let soup = RecipeDetail(
            summary: RecipeSummary(id: "r1", bookID: "b1", title: "Roasted Tomato Soup", authorID: me.id,
                                   authorName: "Maria", totalMinutes: 50, servings: 4),
            ingredients: [
                IngredientLine(id: "i1", name: "Tomatoes", quantity: "1", unit: "kg", preparation: "halved"),
                IngredientLine(id: "i2", name: "Garlic", quantity: "4", unit: "clove"),
                IngredientLine(id: "i3", name: "Olive oil", quantity: "30", unit: "ml"),
                IngredientLine(id: "i4", name: "Salt", originalText: "salt to taste"),
            ],
            steps: [
                RecipeStep(id: "s1", text: "Heat the oven to 200 °C."),
                RecipeStep(id: "s2", text: "Roast tomatoes and garlic with oil for 35 minutes."),
                RecipeStep(id: "s3", text: "Blend until smooth and season."),
            ])
        let cake = RecipeDetail(
            summary: RecipeSummary(id: "r2", bookID: "b1", title: "Lemon Yoghurt Cake", authorID: ana.id,
                                   authorName: "Ana", totalMinutes: 70, servings: 8),
            ingredients: [IngredientLine(id: "i5", name: "Flour", quantity: "250", unit: "g"),
                          IngredientLine(id: "i6", name: "Lemons", quantity: "2")],
            steps: [RecipeStep(id: "s4", text: "Mix, bake 45 minutes at 180 °C.")])
        recipes = ["r1": soup, "r2": cake]
        bookList = [
            BookDetail(summary: BookSummary(id: "b1", name: "Family Dinners", kind: .shared, myRole: .owner,
                                            recipeCount: 2, memberCount: 2),
                       currentUserID: me.id, recipes: [soup.summary, cake.summary], members: [meMember, ana]),
            BookDetail(summary: BookSummary(id: "b2", name: "My Experiments", kind: .personal, myRole: .owner,
                                            recipeCount: 0, memberCount: 1),
                       currentUserID: me.id, recipes: [], members: [meMember]),
        ]
        jobs = [
            ImportJob(id: "j1", sourceURL: URL(string: "https://www.instagram.com/reel/PREVIEW1/")!,
                      status: .reviewRequired, createdAt: Date().addingTimeInterval(-600), titleHint: "Crispy chickpeas"),
            ImportJob(id: "j2", sourceURL: URL(string: "https://www.instagram.com/reel/PREVIEW2/")!,
                      status: .failed(reason: "Preview: the Reel could not be read.", canRetry: true),
                      createdAt: Date().addingTimeInterval(-3600)),
        ]
        lists = [ShoppingList(id: "l1", name: "Weekend", items: [
            ShoppingItem(id: "si1", name: "Tomatoes", quantity: "1", unit: "kg", sourceRecipeTitle: "Roasted Tomato Soup"),
            ShoppingItem(id: "si2", name: "Bread", isBought: true),
        ])]
        self.session = session ?? .signedIn(me)
    }

    private struct NotFound: LocalizedError { var errorDescription: String? { "Not found (preview)." } }

    private func summary(of list: ShoppingList) -> ShoppingListSummary {
        ShoppingListSummary(id: list.id, name: list.name,
                            remainingCount: list.items.filter { !$0.isBought }.count, totalCount: list.items.count)
    }

    private func updateList(_ id: ShoppingListID, _ change: (inout ShoppingList) -> Void) throws -> ShoppingList {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { throw NotFound() }
        change(&lists[index])
        return lists[index]
    }

    private func updateBook(_ id: BookID, _ change: (inout BookDetail) -> Void) throws -> BookDetail {
        guard let index = bookList.firstIndex(where: { $0.id == id }) else { throw NotFound() }
        change(&bookList[index])
        bookList[index].summary.memberCount = bookList[index].members.count
        bookList[index].summary.recipeCount = bookList[index].recipes.count
        return bookList[index]
    }

    func loadSession() async throws -> SessionState { session }
    func signIn() async throws -> SessionState { session = .signedIn(me); return session }
    func completeSetup(displayName: String) async throws -> SessionState {
        session = .signedIn(UserProfile(id: me.id, displayName: displayName)); return session
    }
    func signOut() async throws { session = .signedOut }

    func books() async throws -> [BookSummary] { bookList.map(\.summary) }
    func createBook(name: String, kind: BookKind) async throws -> BookSummary {
        let summary = BookSummary(id: UUID().uuidString, name: name, kind: kind, myRole: .owner, recipeCount: 0, memberCount: 1)
        bookList.append(BookDetail(summary: summary, currentUserID: me.id, recipes: [],
                                   members: [BookMember(id: me.id, displayName: me.displayName, role: .owner)]))
        return summary
    }
    func book(id: BookID) async throws -> BookDetail {
        guard let book = bookList.first(where: { $0.id == id }) else { throw NotFound() }
        return book
    }
    func deleteBook(id: BookID) async throws { bookList.removeAll { $0.id == id } }
    func addMember(accountID: UserID, to bookID: BookID) async throws -> BookDetail {
        try updateBook(bookID) { $0.members.append(BookMember(id: accountID, displayName: "New member", role: .member)) }
    }
    func changeRole(of userID: UserID, to role: MemberRole, in bookID: BookID) async throws -> BookDetail {
        try updateBook(bookID) { book in
            if let i = book.members.firstIndex(where: { $0.id == userID }) { book.members[i].role = role }
        }
    }
    func removeMember(_ userID: UserID, from bookID: BookID) async throws -> BookDetail {
        try updateBook(bookID) { $0.members.removeAll { $0.id == userID } }
    }
    func leaveBook(id: BookID, resolution: LastOwnerResolution?) async throws { bookList.removeAll { $0.id == id } }

    func recipe(id: RecipeID) async throws -> RecipeDetail {
        guard let recipe = recipes[id] else { throw NotFound() }
        return recipe
    }
    func saveRecipe(_ draft: RecipeDraft) async throws -> RecipeDetail {
        guard let bookID = draft.bookID else { throw NotFound() }
        let id = draft.recipeID ?? UUID().uuidString
        let previous = recipes[id]?.summary
        let summary = RecipeSummary(id: id, bookID: bookID, title: draft.title,
                                    authorID: previous?.authorID ?? me.id, authorName: previous?.authorName ?? me.displayName,
                                    totalMinutes: draft.totalMinutes, servings: draft.servings)
        let detail = RecipeDetail(summary: summary, ingredients: draft.ingredients, steps: draft.steps, sourceURL: draft.sourceURL)
        recipes[id] = detail
        _ = try updateBook(bookID) { book in
            book.recipes.removeAll { $0.id == id }
            book.recipes.append(summary)
        }
        return detail
    }
    func deleteRecipe(id: RecipeID) async throws {
        guard let bookID = recipes.removeValue(forKey: id)?.summary.bookID else { return }
        _ = try updateBook(bookID) { $0.recipes.removeAll { $0.id == id } }
    }

    func suggestions(have ingredients: [String]) async throws -> [RecipeSuggestion] {
        let wanted = Set(ingredients.map { $0.lowercased() })
        return recipes.values.compactMap { recipe in
            let names = recipe.ingredients.map(\.name)
            let matched = names.filter { wanted.contains($0.lowercased()) }
            guard !matched.isEmpty else { return nil }
            let bookName = bookList.first { $0.id == recipe.summary.bookID }?.summary.name ?? ""
            return RecipeSuggestion(recipe: recipe.summary, bookName: bookName, matchedIngredients: matched,
                                    missingIngredients: names.filter { !wanted.contains($0.lowercased()) })
        }
    }

    func importJobs() async throws -> [ImportJob] { jobs }
    func importJob(id: ImportJobID) async throws -> ImportJob {
        guard let job = jobs.first(where: { $0.id == id }) else { throw NotFound() }
        return job
    }
    func submitImport(url: URL) async throws -> ImportJob {
        let job = ImportJob(id: UUID().uuidString, sourceURL: url, status: .queued, createdAt: Date())
        jobs.insert(job, at: 0)
        return job
    }
    func importReview(id: ImportJobID) async throws -> RecipeDraft {
        RecipeDraft(title: "Crispy chickpeas", servings: 2, ingredients: [
            IngredientLine(name: "Chickpeas", quantity: "400", unit: "g", originalText: "1 can chickpeas (400 g)"),
            IngredientLine(name: "Smoked paprika", originalText: "a good shake of paprika", amountNeedsReview: true),
        ], steps: [RecipeStep(text: "Dry the chickpeas."), RecipeStep(text: "Roast at 220 °C for 25 minutes.")],
        sourceURL: URL(string: "https://www.instagram.com/reel/PREVIEW1/"),
        evidenceText: "Caption (preview fixture): crispy chickpeas!! 1 can chickpeas (400 g), a good shake of paprika, roast hot until crunchy.")
    }
    func approveImport(id: ImportJobID, draft: RecipeDraft) async throws -> RecipeDetail {
        let saved = try await saveRecipe(draft)
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].status = .completed(recipeID: saved.id, bookID: saved.summary.bookID)
        }
        return saved
    }
    func retryImport(id: ImportJobID) async throws -> ImportJob {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { throw NotFound() }
        jobs[i].status = .queued
        return jobs[i]
    }
    func discardImport(id: ImportJobID) async throws { jobs.removeAll { $0.id == id } }

    func shoppingLists() async throws -> [ShoppingListSummary] { lists.map(summary(of:)) }
    func shoppingList(id: ShoppingListID) async throws -> ShoppingList {
        guard let list = lists.first(where: { $0.id == id }) else { throw NotFound() }
        return list
    }
    func createShoppingList(name: String) async throws -> ShoppingListSummary {
        let list = ShoppingList(id: UUID().uuidString, name: name, items: [])
        lists.append(list)
        return summary(of: list)
    }
    func deleteShoppingList(id: ShoppingListID) async throws { lists.removeAll { $0.id == id } }
    func addShoppingItem(_ item: ShoppingItemDraft, to listID: ShoppingListID) async throws -> ShoppingList {
        try updateList(listID) {
            $0.items.append(ShoppingItem(id: UUID().uuidString, name: item.name, quantity: item.quantity, unit: item.unit))
        }
    }
    func setShoppingItem(_ itemID: ShoppingItemID, bought: Bool, in listID: ShoppingListID) async throws -> ShoppingList {
        try updateList(listID) { list in
            if let i = list.items.firstIndex(where: { $0.id == itemID }) { list.items[i].isBought = bought }
        }
    }
    func removeShoppingItem(_ itemID: ShoppingItemID, from listID: ShoppingListID) async throws -> ShoppingList {
        try updateList(listID) { $0.items.removeAll { $0.id == itemID } }
    }
    func addRecipeIngredients(recipeID: RecipeID, ingredientIDs: [String], to listID: ShoppingListID) async throws -> ShoppingList {
        guard let recipe = recipes[recipeID] else { throw NotFound() }
        let chosen = recipe.ingredients.filter { ingredientIDs.contains($0.id) }
        return try updateList(listID) { list in
            list.items += chosen.map {
                ShoppingItem(id: UUID().uuidString, name: $0.name, quantity: $0.quantity, unit: $0.unit,
                             sourceRecipeTitle: recipe.summary.title)
            }
        }
    }

    func accountDeletionBlockers() async throws -> [BookDetail] {
        bookList.filter { book in
            if case .lastOwnerMustTransferOrDelete = BookPermissions(book: book).leaveRequirement { return true }
            return false
        }
    }
    func deleteAccount(resolutions: [BookID: LastOwnerResolution]) async throws { session = .signedOut }
}

#Preview("Signed in") {
    RecipeBookRootView(service: PreviewRecipeBookService())
}

#Preview("Signed out") {
    RecipeBookRootView(service: PreviewRecipeBookService(session: .signedOut))
}

#Preview("Awaiting invite") {
    RecipeBookRootView(service: PreviewRecipeBookService(
        session: .awaitingInvite(accountID: "7d3f1c2a-0000-4000-8000-0000000000ff")))
}

#Preview("Recipe – large text, dark") {
    NavigationStack { RecipeDetailView(route: RecipeRoute(id: "r1", title: "Roasted Tomato Soup")) }
        .environment(\.recipeBookService, PreviewRecipeBookService())
        .environment(\.dynamicTypeSize, .accessibility2)
        .preferredColorScheme(.dark)
}

#Preview("Import review") {
    NavigationStack { ImportReviewView(jobID: "j1") {} }
        .environment(\.recipeBookService, PreviewRecipeBookService())
}

#Preview("Unconfigured service") {
    RecipeBookRootView(service: UnconfiguredRecipeBookService())
}
#endif
