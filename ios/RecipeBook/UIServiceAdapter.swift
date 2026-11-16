#if os(iOS)
import Foundation
import RecipeBookCore
import RecipeBookAuth
import RecipeBookPresentation

actor UIServiceAdapter: RecipeBookPresentation.RecipeBookService {
    private let api: APIClient
    private let auth: any AuthenticationSession
    private let inbox: SharedReelInbox
    private var currentAccount: SessionAccount?
    private var sessionGeneration = 0
    private var bookCache: [UUID: RecipeBookCore.Book] = [:]
    private var recipeCache: [UUID: RecipeBookCore.Recipe] = [:]
    private var listCache: [UUID: RecipeBookCore.ShoppingList] = [:]
    private var jobCache: [UUID: RecipeBookCore.ImportJob] = [:]
    private var importKeys: [URL: UUID] = [:]

    init(api: APIClient, auth: any AuthenticationSession, inbox: SharedReelInbox) {
        self.api = api
        self.auth = auth
        self.inbox = inbox
    }
    func loadSession() async throws -> SessionState {
        try Task.checkCancellation()
        let generation = sessionGeneration
        guard await auth.hasSession() else { return .signedOut }
        let account: SessionAccount
        do { account = try await api.account() }
        catch let error as APIError where error.status == 401 || error.code == "account_deleted" {
            guard generation == sessionGeneration else { throw CancellationError() }
            try await signOut()
            return .signedOut
        }
        guard generation == sessionGeneration else { throw CancellationError() }
        if let previous = currentAccount, previous.id != account.id {
            bookCache.removeAll(); recipeCache.removeAll(); listCache.removeAll(); jobCache.removeAll(); importKeys.removeAll()
        }
        currentAccount = account
        if account.access == "awaitingInvite" { return .awaitingInvite(accountID: string(account.id)) }
        guard account.access == "active" else { throw failure("The server returned an invalid account access state.") }
        let profile = UserProfile(id: string(account.id), displayName: account.displayName ?? "")
        return profile.displayName.isEmpty ? .needsSetup(profile) : .signedIn(profile)
    }
    func signIn() async throws -> SessionState {
        sessionGeneration += 1
        try await auth.signIn()
        return try await loadSession()
    }
    func completeSetup(displayName: String) async throws -> SessionState {
        _ = try await api.completeSetup(displayName: displayName)
        return try await loadSession()
    }
    func signOut() async throws {
        sessionGeneration += 1
        try await auth.signOut()
        currentAccount = nil
        bookCache.removeAll(); recipeCache.removeAll(); listCache.removeAll(); jobCache.removeAll(); importKeys.removeAll()
    }

    func books() async throws -> [BookSummary] {
        let values = try await api.books()
        bookCache = [:]
        recipeCache = [:]
        var result: [BookSummary] = []
        for value in values {
            try Task.checkCancellation()
            bookCache[value.id] = value
            let recipes = try await api.recipes(bookId: value.id)
            let members = try await api.members(bookId: value.id)
            recipes.forEach { recipeCache[$0.id] = $0 }
            result.append(summary(value, recipes: recipes.count, members: members.count, coverImageID: recipes.compactMap(\.draft.coverImageID).first))
        }
        return result
    }
    func createBook(name: String, kind: RecipeBookPresentation.BookKind) async throws -> BookSummary {
        let value = try await api.createBook(name: name, kind: kind == .shared ? .shared : .personal)
        bookCache[value.id] = value
        return summary(value, recipes: 0, members: 1)
    }
    func book(id: BookID) async throws -> BookDetail {
        let uuid = try identifier(id)
        let values = try await api.books()
        guard let value = values.first(where: { $0.id == uuid }) else { throw notFound("Book") }
        bookCache[value.id] = value
        let recipes = try await api.recipes(bookId: uuid)
        let members = try await api.members(bookId: uuid)
        recipeCache = recipeCache.filter { $0.value.bookId != uuid }
        recipes.forEach { recipeCache[$0.id] = $0 }
        let account = try await account()
        return BookDetail(
            summary: summary(value, recipes: recipes.count, members: members.count, coverImageID: recipes.compactMap(\.draft.coverImageID).first),
            currentUserID: string(account.id),
            recipes: recipes.map { recipeSummary($0, members: members) },
            members: members.map { BookMember(id: string($0.userId), displayName: $0.displayName ?? string($0.userId), role: role($0.role)) }
        )
    }
    func deleteBook(id: BookID) async throws {
        let cached = try await cachedBook(id)
        _ = try await api.deleteBook(cached)
        bookCache[cached.id] = nil
        recipeCache = recipeCache.filter { $0.value.bookId != cached.id }
    }
    func addMember(accountID: UserID, to bookID: BookID) async throws -> BookDetail {
        let cached = try await cachedBook(bookID)
        let updated = try await api.addMember(book: cached, userId: identifier(accountID))
        bookCache[updated.id] = updated
        return try await book(id: bookID)
    }
    func changeRole(of userID: UserID, to nextRole: MemberRole, in bookID: BookID) async throws -> BookDetail {
        let cached = try await cachedBook(bookID)
        let updated = try await api.changeRole(book: cached, userId: identifier(userID), role: nextRole == .owner ? .owner : .member)
        bookCache[updated.id] = updated
        return try await book(id: bookID)
    }
    func removeMember(_ userID: UserID, from bookID: BookID) async throws -> BookDetail {
        let cached = try await cachedBook(bookID)
        _ = try await api.leaveBook(book: cached, userId: identifier(userID))
        return try await book(id: bookID)
    }
    func leaveBook(id: BookID, resolution: LastOwnerResolution?) async throws {
        switch resolution {
        case .deleteBook:
            try await deleteBook(id: id)
            return
        case .transferOwnership(let userID):
            _ = try await changeRole(of: userID, to: .owner, in: id)
        case nil: break
        }
        let cached = try await cachedBook(id)
        let account = try await account()
        _ = try await api.leaveBook(book: cached, userId: account.id)
        bookCache[cached.id] = nil
        recipeCache = recipeCache.filter { $0.value.bookId != cached.id }
    }
    func recipe(id: RecipeID) async throws -> RecipeDetail {
        let uuid = try identifier(id)
        let cached = try await locateRecipe(uuid)
        let detail = try await book(id: string(cached.bookId))
        guard let value = recipeCache[uuid] else { throw notFound("Recipe") }
        let members = detail.members
        return recipeDetail(value, authorName: members.first(where: { $0.id == string(value.authorId) })?.displayName ?? string(value.authorId))
    }
    func saveRecipe(_ draft: RecipeBookPresentation.RecipeDraft) async throws -> RecipeDetail {
        guard let destination = draft.bookID else { throw failure("Choose a destination book before saving.") }
        let bookID = try identifier(destination)
        let existing: RecipeBookCore.Recipe?
        if let recipeID = draft.recipeID {
            let uuid = try identifier(recipeID)
            guard let value = recipeCache[uuid], value.bookId == bookID else {
                throw failure("Reload the recipe before editing. Recipes cannot be moved between books.")
            }
            existing = value
        } else { existing = nil }
        var payload = coreDraft(draft)
        switch draft.coverImageEdit {
        case .unchanged: payload.coverImageID = existing?.draft.coverImageID
        case .remove: payload.coverImageID = nil
        case .replace(let jpegData): payload.coverImageID = try await api.uploadCover(jpegData)
        }
        let saved = try await api.saveRecipe(bookId: bookID, draft: payload, existing: existing)
        recipeCache[saved.id] = saved
        return recipeDetail(saved, authorName: saved.authorId == currentAccount?.id ? currentAccount?.displayName ?? string(saved.authorId) : string(saved.authorId))
    }
    func deleteRecipe(id: RecipeID) async throws {
        let uuid = try identifier(id)
        guard let value = recipeCache[uuid] else { throw failure("Reload the recipe before deleting.") }
        _ = try await api.deleteRecipe(value)
        recipeCache[uuid] = nil
    }
    func suggestions(have ingredients: [String]) async throws -> [RecipeSuggestion] {
        // The server supplies only accessible saved recipes. Ingredient matching
        // is presentation-only, never external discovery or a persistent pantry.
        let values = try await api.suggestions(have: ingredients)
        let books = try await api.books()
        let have = Set(ingredients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var suggestions: [RecipeSuggestion] = []
        for value in values {
            let names = value.draft.ingredients.map(\.name)
            let matched = names.filter { have.contains($0.lowercased()) }
            if matched.isEmpty { continue }
            recipeCache[value.id] = value
            suggestions.append(RecipeSuggestion(
                recipe: recipeSummary(value, members: []),
                bookName: books.first(where: { $0.id == value.bookId })?.name ?? string(value.bookId),
                matchedIngredients: matched, missingIngredients: names.filter { !have.contains($0.lowercased()) }
            ))
        }
        return suggestions.sorted { $0.matchedIngredients.count > $1.matchedIngredients.count }
    }
    func importJobs() async throws -> [RecipeBookPresentation.ImportJob] {
        let values = try await api.importJobs()
        for value in values { jobCache[value.id] = value }
        return try values.map(presentationJob)
    }
    func importJob(id: ImportJobID) async throws -> RecipeBookPresentation.ImportJob {
        let value = try await api.importJob(id: identifier(id))
        jobCache[value.id] = value
        return try presentationJob(value)
    }
    func submitImport(url: URL) async throws -> RecipeBookPresentation.ImportJob {
        guard let canonical = ReelURL.canonicalize(url) else { throw failure("Share or paste an HTTPS Instagram Reel link.") }
        let pending = try inbox.pending().filter { $0.url == canonical }
        let key = importKeys[canonical] ?? pending.first.flatMap { UUID(uuidString: $0.id) } ?? UUID()
        importKeys[canonical] = key
        let value = try await api.importReel(url: canonical, idempotencyKey: key)
        jobCache[value.id] = value
        let result = try presentationJob(value)
        // Only a committed server job acknowledges the share files. Cancellation
        // and provider errors retain them for explicit retry.
        for entry in pending { try inbox.acknowledge(id: entry.id) }
        return result
    }
    func importReview(id: ImportJobID) async throws -> RecipeBookPresentation.RecipeDraft {
        let value = try await api.importJob(id: identifier(id))
        jobCache[value.id] = value
        guard value.state == .review, let draft = value.draft else { throw failure("This import is not ready for review.") }
        return RecipeBookPresentation.RecipeDraft(
            title: draft.title, servings: draft.servings, totalMinutes: draft.totalMinutes,
            ingredients: ingredientLines(draft.ingredients, prefix: string(value.id)),
            steps: steps(draft.steps, prefix: string(value.id)), sourceURL: draft.sourceURL,
            evidenceText: value.evidence.map { evidence in
                [
                    evidence.caption.map { "Caption:\n\($0)" },
                    evidence.comments.isEmpty ? nil : "Comments:\n" + evidence.comments.joined(separator: "\n\n"),
                    evidence.transcript.map { "Transcript:\n\($0)" },
                    evidence.warnings.map { "Review warnings:\n" + $0.joined(separator: "\n") },
                    evidence.sources.map { sources in sources.map { "\($0.id) (\($0.kind)): \($0.text)" }.joined(separator: "\n\n") }
                ].compactMap { $0 }.joined(separator: "\n\n")
            },
            mealStyle: draft.mealStyle.flatMap { RecipeBookPresentation.MealStyle(rawValue: $0.rawValue) },
            coverImage: draft.coverImageID.map { ImageRef(id: string($0)) }
        )
    }
    func approveImport(id: ImportJobID, draft: RecipeBookPresentation.RecipeDraft) async throws -> RecipeDetail {
        guard let destination = draft.bookID else { throw failure("Choose a destination book before saving.") }
        let uuid = try identifier(id)
        guard let value = jobCache[uuid] else { throw failure("Reload the import review before saving.") }
        var payload = coreDraft(draft)
        switch draft.coverImageEdit {
        case .unchanged: payload.coverImageID = value.draft?.coverImageID
        case .remove: payload.coverImageID = nil
        case .replace(let jpegData): payload.coverImageID = try await api.uploadCover(jpegData)
        }
        let saved = try await api.approveImport(value, bookId: identifier(destination), draft: payload)
        recipeCache[saved.id] = saved
        jobCache[uuid] = nil
        return recipeDetail(saved, authorName: currentAccount?.displayName ?? string(saved.authorId))
    }
    func retryImport(id: ImportJobID) async throws -> RecipeBookPresentation.ImportJob {
        let uuid = try identifier(id)
        guard let value = jobCache[uuid] else { throw failure("Reload the import before retrying.") }
        let updated = try await api.retryImport(value)
        jobCache[uuid] = updated
        return try presentationJob(updated)
    }
    func discardImport(id: ImportJobID) async throws {
        let uuid = try identifier(id)
        guard let value = jobCache[uuid] else { throw failure("Reload the import before discarding.") }
        _ = try await api.discardImport(value)
        jobCache[uuid] = nil
    }
    func shoppingLists() async throws -> [ShoppingListSummary] {
        let values = try await api.shoppingLists()
        for value in values { listCache[value.id] = value }
        return values.map(listSummary)
    }
    func shoppingList(id: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        let uuid = try identifier(id)
        let values = try await api.shoppingLists()
        guard let value = values.first(where: { $0.id == uuid }) else { throw notFound("Shopping list") }
        listCache[uuid] = value
        return try await presentationList(value)
    }
    func createShoppingList(name: String) async throws -> ShoppingListSummary {
        let value = try await api.createShoppingList(name: name)
        listCache[value.id] = value
        return listSummary(value)
    }
    func deleteShoppingList(id: ShoppingListID) async throws {
        let value = try await cachedList(id)
        _ = try await api.deleteShoppingList(value)
        listCache[value.id] = nil
    }
    func addShoppingItem(_ item: ShoppingItemDraft, to listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        let value = try await cachedList(listID)
        let added = RecipeBookCore.ShoppingItem(ingredient: Ingredient(name: item.name, quantity: item.quantity, unit: item.unit))
        return try await replaceList(value, items: value.items + [added])
    }
    func setShoppingItem(_ itemID: ShoppingItemID, bought: Bool, in listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        let value = try await cachedList(listID)
        let uuid = try identifier(itemID)
        if let section = value.generated?.first(where: { $0.items.contains(where: { $0.id == uuid }) }) {
            _ = try await api.checkGenerated(bookId: section.bookId, start: section.weekStart, itemId: uuid, bought: bought, version: section.planVersion)
            return try await shoppingList(id: listID)
        }
        guard value.items.contains(where: { $0.id == uuid }) else { throw notFound("Shopping item") }
        let items = value.items.map { $0.id == uuid ? RecipeBookCore.ShoppingItem(id: $0.id, ingredient: $0.ingredient, bought: bought) : $0 }
        return try await replaceList(value, items: items)
    }
    func removeShoppingItem(_ itemID: ShoppingItemID, from listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        let value = try await cachedList(listID)
        let uuid = try identifier(itemID)
        guard value.items.contains(where: { $0.id == uuid }) else { throw notFound("Shopping item") }
        return try await replaceList(value, items: value.items.filter { $0.id != uuid })
    }
    func addRecipeIngredients(recipeID: RecipeID, ingredientIDs: [String], to listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        let uuid = try identifier(recipeID)
        guard let recipe = recipeCache[uuid] else { throw failure("Reload the recipe before selecting ingredients.") }
        let known = ingredientLines(recipe.draft.ingredients, prefix: string(recipe.id))
        let selected = Set(ingredientIDs)
        guard selected.isSubset(of: Set(known.map(\.id))) else { throw failure("Ingredient selections do not match this recipe.") }
        let omitted = known.enumerated().filter { !selected.contains($0.element.id) }.map(\.offset)
        let list = try await cachedList(listID)
        let updated = try await api.addRecipeToShoppingList(list: list, recipeId: uuid, recipeVersion: recipe.version, alreadyHave: omitted)
        listCache[updated.id] = updated
        return try await presentationList(updated)
    }
    func accountDeletionBlockers() async throws -> [BookDetail] {
        let summaries = try await books()
        var result: [BookDetail] = []
        for summary in summaries where summary.kind == .shared && summary.myRole == .owner {
            let detail = try await book(id: summary.id)
            if detail.members.filter({ $0.role == .owner }).count == 1 { result.append(detail) }
        }
        return result
    }
    func deleteAccount(resolutions: [BookID: LastOwnerResolution]) async throws {
        let blockers = try await accountDeletionBlockers()
        guard blockers.allSatisfy({ resolutions[$0.id] != nil }) else {
            throw failure("Transfer ownership or explicitly delete every shared book where you are the last owner.")
        }
        for blocker in blockers {
            try Task.checkCancellation()
            guard let resolution = resolutions[blocker.id] else { throw failure("An ownership resolution is missing.") }
            switch resolution {
            case .deleteBook: try await deleteBook(id: blocker.id)
            case .transferOwnership(let userID): _ = try await changeRole(of: userID, to: .owner, in: blocker.id)
            }
        }
        _ = try await api.deleteAccount()
        try await signOut()
    }

    private func account() async throws -> SessionAccount {
        if let currentAccount { return currentAccount }
        let value = try await api.account()
        currentAccount = value
        return value
    }
    private func cachedBook(_ id: String) async throws -> RecipeBookCore.Book {
        let uuid = try identifier(id)
        if let value = bookCache[uuid] { return value }
        _ = try await book(id: id)
        guard let value = bookCache[uuid] else { throw notFound("Book") }
        return value
    }
    private func locateRecipe(_ uuid: UUID) async throws -> RecipeBookCore.Recipe {
        if let value = recipeCache[uuid] { return value }
        let books = try await api.books()
        for book in books {
            let recipes = try await api.recipes(bookId: book.id)
            for recipe in recipes { recipeCache[recipe.id] = recipe }
            if let value = recipeCache[uuid] { return value }
        }
        throw notFound("Recipe")
    }
    private func cachedList(_ id: String) async throws -> RecipeBookCore.ShoppingList {
        let uuid = try identifier(id)
        if let value = listCache[uuid] { return value }
        _ = try await shoppingList(id: id)
        guard let value = listCache[uuid] else { throw notFound("Shopping list") }
        return value
    }
    private func replaceList(_ list: RecipeBookCore.ShoppingList, items: [RecipeBookCore.ShoppingItem]) async throws -> RecipeBookPresentation.ShoppingList {
        let updated = try await api.replaceShoppingItems(list: list, items: items)
        listCache[updated.id] = updated
        return try await presentationList(updated)
    }
    private func coreDraft(_ value: RecipeBookPresentation.RecipeDraft) -> RecipeBookCore.RecipeDraft {
        RecipeBookCore.RecipeDraft(
            title: value.title,
            ingredients: value.ingredients.map { Ingredient(name: $0.name, quantity: $0.quantity, unit: $0.unit, preparation: $0.preparation) },
            steps: value.steps.map(\.text), servings: value.servings, totalMinutes: value.totalMinutes, sourceURL: value.sourceURL,
            mealStyle: value.mealStyle.flatMap { RecipeBookCore.MealStyle(rawValue: $0.rawValue) }
        )
    }
    private func recipeDetail(_ value: RecipeBookCore.Recipe, authorName: String) -> RecipeDetail {
        RecipeDetail(
            summary: RecipeSummary(id: string(value.id), bookID: string(value.bookId), title: value.draft.title,
                                   authorID: string(value.authorId), authorName: authorName,
                                   totalMinutes: value.draft.totalMinutes, servings: value.draft.servings,
                                   mealStyle: value.draft.mealStyle.flatMap { RecipeBookPresentation.MealStyle(rawValue: $0.rawValue) },
                                   coverImage: value.draft.coverImageID.map { ImageRef(id: string($0)) }, version: value.version),
            ingredients: ingredientLines(value.draft.ingredients, prefix: string(value.id)),
            steps: steps(value.draft.steps, prefix: string(value.id)), sourceURL: value.draft.sourceURL
        )
    }
    private func recipeSummary(_ value: RecipeBookCore.Recipe, members: [Membership]) -> RecipeSummary {
        RecipeSummary(id: string(value.id), bookID: string(value.bookId), title: value.draft.title,
                      authorID: string(value.authorId), authorName: members.first(where: { $0.userId == value.authorId })?.displayName ?? string(value.authorId),
                      totalMinutes: value.draft.totalMinutes, servings: value.draft.servings,
                      mealStyle: value.draft.mealStyle.flatMap { RecipeBookPresentation.MealStyle(rawValue: $0.rawValue) },
                      coverImage: value.draft.coverImageID.map { ImageRef(id: string($0)) }, version: value.version)
    }
    private func ingredientLines(_ values: [Ingredient], prefix: String) -> [IngredientLine] {
        values.enumerated().map { IngredientLine(id: "\(prefix)-ingredient-\($0.offset)", name: $0.element.name,
                                                quantity: $0.element.quantity, unit: $0.element.unit, preparation: $0.element.preparation,
                                                amountNeedsReview: $0.element.quantity == nil) }
    }
    private func steps(_ values: [String], prefix: String) -> [RecipeStep] {
        values.enumerated().map { RecipeStep(id: "\(prefix)-step-\($0.offset)", text: $0.element) }
    }
    private func summary(_ value: RecipeBookCore.Book, recipes: Int, members: Int, coverImageID: UUID? = nil) -> BookSummary {
        BookSummary(id: string(value.id), name: value.name, kind: value.kind == .shared ? .shared : .personal,
                    myRole: role(value.role), recipeCount: recipes, memberCount: members,
                    coverImage: coverImageID.map { ImageRef(id: string($0)) })
    }
    private func role(_ value: BookRole) -> MemberRole { value == .owner ? .owner : .member }
    private func listSummary(_ value: RecipeBookCore.ShoppingList) -> ShoppingListSummary {
        let generated = value.generated?.flatMap(\.items) ?? []
        return ShoppingListSummary(id: string(value.id), name: value.name, remainingCount: value.items.filter { !$0.bought }.count + generated.filter { !$0.bought }.count, totalCount: value.items.count + generated.count)
    }
    private func presentationList(_ value: RecipeBookCore.ShoppingList) async throws -> RecipeBookPresentation.ShoppingList {
        var currentRecipes: [UUID: RecipeBookCore.Recipe] = [:]
        for bookID in Set((value.generated ?? []).map(\.bookId)) {
            for recipe in try await api.recipes(bookId: bookID) { currentRecipes[recipe.id] = recipe }
        }
        let manual = value.items.map {
            RecipeBookPresentation.ShoppingItem(id: string($0.id), name: $0.ingredient.name, quantity: $0.ingredient.quantity,
                                               unit: $0.ingredient.unit, isBought: $0.bought)
        }
        let generated = (value.generated ?? []).flatMap { section in section.items.map { item in
            RecipeBookPresentation.ShoppingItem(id: string(item.id), name: item.ingredient.name, quantity: item.ingredient.quantity,
                unit: item.ingredient.unit, isBought: item.bought,
                origin: .generated(PlanProvenance(planID: string(section.planId), bookID: string(section.bookId),
                    weekStart: section.weekStart, planVersion: section.planVersion, recipeTitles:
                        Array(Set(item.contributions.compactMap { contribution in
                            guard let recipe = currentRecipes[contribution.recipeId],
                                  recipe.bookId == section.bookId, recipe.version == contribution.recipeVersion else { return nil }
                            return recipe.draft.title
                        })).sorted())))
        }}
        return RecipeBookPresentation.ShoppingList(id: string(value.id), name: value.name, items: manual + generated)
    }
    func imageData(_ image: ImageRef) async throws -> Data { try await api.coverData(id: identifier(image.id)) }
    func readWeek(bookID: BookID, weekStart: PlanDate) async throws -> RecipeBookPresentation.WeeklyPlan? {
        guard let value = try await api.week(bookId: identifier(bookID), start: weekStart) else { return nil }
        return try await presentationWeek(value)
    }
    func generateWeek(bookID: BookID, weekStart: PlanDate, dayStyles: [RecipeBookPresentation.MealStyle?], listID: ShoppingListID, expectedVersion: Int?) async throws -> RecipeBookPresentation.WeeklyPlan {
        let value = try await api.generateWeek(bookId: identifier(bookID), start: weekStart,
            styles: dayStyles.map { $0.flatMap { RecipeBookCore.MealStyle(rawValue: $0.rawValue) } },
            listId: identifier(listID), version: expectedVersion)
        return try await presentationWeek(value)
    }
    func replacePlanDay(bookID: BookID, weekStart: PlanDate, date: PlanDate, replacement: PlanReplacement?, planVersion: Int) async throws -> RecipeBookPresentation.WeeklyPlan {
        if let replacement, replacement.recipeVersion == nil { throw failure("Reload the replacement recipe before changing the plan.") }
        let value = try await api.replacePlanDay(bookId: identifier(bookID), start: weekStart, date: date,
            recipeId: try replacement.map { try identifier($0.recipeID) }, recipeVersion: replacement?.recipeVersion,
            servings: replacement?.servings, version: planVersion)
        return try await presentationWeek(value)
    }
    func deleteWeek(bookID: BookID, weekStart: PlanDate, planVersion: Int) async throws {
        try await api.deleteWeek(bookId: identifier(bookID), start: weekStart, version: planVersion)
    }
    private func presentationWeek(_ value: StoredPlanResult) async throws -> RecipeBookPresentation.WeeklyPlan {
        // Hydrate only current accessible inventory, never stale cache snapshots.
        let recipes = try await api.recipes(bookId: value.plan.bookId)
        return RecipeBookPresentation.WeeklyPlan(id: string(value.plan.id), bookID: string(value.plan.bookId),
            weekStart: value.plan.weekStart, days: value.plan.days.map { day in
                RecipeBookPresentation.PlanDay(date: day.date, mealStyle: day.mealStyle.flatMap { RecipeBookPresentation.MealStyle(rawValue: $0.rawValue) },
                    slot: day.slot.map { slot in
                        let recipe = recipes.first { $0.id == slot.recipeId && $0.version == slot.recipeVersion }
                        return RecipeBookPresentation.PlanSlot(id: string(slot.id), recipeID: string(slot.recipeId), recipeVersion: slot.recipeVersion,
                            servings: slot.servings, recipe: recipe.map { recipeSummary($0, members: []) })
                    })
            }, version: value.plan.version, warnings: value.warnings.map(\.message), shoppingListID: string(value.listId))
    }
    private func presentationJob(_ value: RecipeBookCore.ImportJob) throws -> RecipeBookPresentation.ImportJob {
        let status: ImportStatus
        switch value.state {
        case .queued: status = .queued
        case .running: status = .processing
        case .review: status = .reviewRequired
        case .failed: status = .failed(reason: value.error ?? "The import failed.", canRetry: false)
        case .completed:
            guard let recipeID = value.recipeId, let bookID = value.bookId else { throw failure("Completed import identifiers are missing.") }
            status = .completed(recipeID: string(recipeID), bookID: string(bookID))
        case .discarded: throw failure("This import was discarded.")
        }
        guard let date = ISO8601DateFormatter().date(from: value.createdAt)
            ?? Self.fractionalDate(value.createdAt) else { throw failure("Import timestamp is invalid.") }
        return RecipeBookPresentation.ImportJob(id: string(value.id), sourceURL: value.sourceURL, status: status, createdAt: date, titleHint: value.draft?.title)
    }
    private static func fractionalDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
    private func string(_ value: UUID) -> String { value.uuidString.lowercased() }
    private func identifier(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw failure("A valid account or item UUID is required.") }
        return id
    }
    private func failure(_ message: String) -> APIError { APIError(status: 0, code: "client_state", message: message) }
    private func notFound(_ name: String) -> APIError { APIError(status: 404, code: "not_found", message: "\(name) not found.") }
}
#endif
