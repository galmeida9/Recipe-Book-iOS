import Foundation
import RecipeBookCore
import RecipeBookPresentation

/// Bootstrap injects a new account adapter lazily. Neither initialization nor guest operations
/// construct authentication, drain a share inbox, or contact a service.
actor GuestAwareService: RecipeBookService {
    typealias CloudFactory = @Sendable () async throws -> any RecipeBookService
    typealias CloudCopy = @Sendable (LocalBookCopy) async throws -> RecipeBookCore.Book

    private let store: GuestStore
    private let local: GuestService
    private let cloudFactory: CloudFactory
    private let cloudCopy: CloudCopy?
    private var cloudTask: Task<any RecipeBookService, Error>?
    private var session: SessionState = .signedOut
    private var generation = 0

    init(localDirectory: URL, cloudFactory: @escaping CloudFactory, cloudCopy: CloudCopy? = nil) throws {
        let store = try GuestStore(directory: localDirectory)
        self.store = store
        local = GuestService(store: store)
        self.cloudFactory = cloudFactory
        self.cloudCopy = cloudCopy
    }
    private func adapter() async throws -> any RecipeBookService {
        try Task.checkCancellation()
        let epoch = generation
        let task: Task<any RecipeBookService, Error>
        if let existing = cloudTask { task = existing }
        else {
            let factory = cloudFactory
            task = Task { try await factory() }
            cloudTask = task
        }
        do {
            let result = try await task.value
            guard epoch == generation else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        } catch {
            if epoch == generation { cloudTask = nil }
            throw error
        }
    }
    private func retireCloud() {
        generation += 1
        cloudTask?.cancel()
        cloudTask = nil
        session = .signedOut
    }
    func loadSession() async throws -> SessionState {
        try Task.checkCancellation()
        switch try store.read().mode {
        case .none: session = .signedOut
        case .guest: session = .guest
        case .account:
            let epoch = generation
            let service = try await adapter()
            let value = try await service.loadSession()
            guard epoch == generation else { throw CancellationError() }
            session = value
            if value == .signedOut {
                try store.transaction { $0.mode = .none }
                retireCloud()
            }
        }
        return session
    }
    func continueWithoutSignIn() async throws -> SessionState {
        try store.transaction { $0.mode = .guest }
        retireCloud()
        session = .guest
        return .guest
    }
    func signIn() async throws -> SessionState {
        // A failed sign-in leaves the user's previous explicit local choice untouched.
        retireCloud()
        let epoch = generation
        let service = try await adapter()
        let result = try await service.signIn()
        guard epoch == generation else { throw CancellationError() }
        try store.transaction { $0.mode = result == .signedOut ? .none : .account }
        session = result
        return result
    }
    func completeSetup(displayName: String) async throws -> SessionState {
        guard try store.read().mode == .account else { throw RecipeBookUIError.signInRequired(.account) }
        let epoch = generation
        let service = try await adapter()
        let result = try await service.completeSetup(displayName: displayName)
        guard epoch == generation else { throw CancellationError() }
        session = result
        return result
    }
    func signOut() async throws {
        let isAccount = try store.read().mode == .account
        let previous = cloudTask
        try store.transaction { $0.mode = .none }
        retireCloud()
        if isAccount {
            // Signing out from guest mode never invokes the cloud factory or auth.
            let service: any RecipeBookService
            if let previous { service = try await previous.value }
            else { service = try await cloudFactory() }
            try await service.signOut()
        }
    }
    private func requireLocalAccess() async throws {
        switch try store.read().mode {
        case .guest: return
        case .none: throw RecipeBookUIError.signInRequired(.account)
        case .account:
            if case .signedIn = session { return }
            let value = try await loadSession()
            guard case .signedIn = value else { throw RecipeBookUIError.signInRequired(.account) }
        }
    }
    private func withCloud<T: Sendable>(
        _ feature: SignInFeature,
        _ action: @Sendable (any RecipeBookService) async throws -> T
    ) async throws -> T {
        guard try store.read().mode == .account else { throw RecipeBookUIError.signInRequired(feature) }
        if case .signedIn = session {} else {
            let value = try await loadSession()
            guard case .signedIn = value else { throw RecipeBookUIError.signInRequired(feature) }
        }
        let epoch = generation
        let service = try await adapter()
        let result = try await action(service)
        guard epoch == generation else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }
    func books() async throws -> [BookSummary] {
        try await requireLocalAccess()
        let device = try await local.books()
        if try store.read().mode == .guest { return device }
        let account = try await withCloud(.account) { try await $0.books() }
        return device + account
    }
    func createBook(name: String, kind: RecipeBookPresentation.BookKind) async throws -> BookSummary {
        if try store.read().mode == .guest { return try await local.createBook(name: name, kind: kind) }
        return try await withCloud(kind == .shared ? .sharing : .account) { try await $0.createBook(name: name, kind: kind) }
    }
    func book(id: BookID) async throws -> BookDetail {
        if GuestStore.isLocal(id) { try await requireLocalAccess(); return try await local.book(id: id) }
        return try await withCloud(.account) { try await $0.book(id: id) }
    }
    func deleteBook(id: BookID) async throws {
        if GuestStore.isLocal(id) { try await requireLocalAccess(); try await local.deleteBook(id: id); return }
        try await withCloud(.account) { try await $0.deleteBook(id: id) }
    }
    func recipe(id: RecipeID) async throws -> RecipeDetail {
        if GuestStore.isLocal(id) { try await requireLocalAccess(); return try await local.recipe(id: id) }
        return try await withCloud(.account) { try await $0.recipe(id: id) }
    }
    func saveRecipe(_ draft: RecipeBookPresentation.RecipeDraft) async throws -> RecipeDetail {
        guard let bookID = draft.bookID else { throw guestFailure("Choose a destination book before saving.") }
        if let id = draft.recipeID, GuestStore.isLocal(id) != GuestStore.isLocal(bookID) {
            throw guestFailure("Recipes cannot be moved between on-device and account books. Use explicit book copy.")
        }
        if GuestStore.isLocal(bookID) { try await requireLocalAccess(); return try await local.saveRecipe(draft) }
        return try await withCloud(.account) { try await $0.saveRecipe(draft) }
    }
    func deleteRecipe(id: RecipeID) async throws {
        if GuestStore.isLocal(id) { try await requireLocalAccess(); try await local.deleteRecipe(id: id); return }
        try await withCloud(.account) { try await $0.deleteRecipe(id: id) }
    }
    func suggestions(have ingredients: [String]) async throws -> [RecipeSuggestion] {
        try await requireLocalAccess()
        let device = try await local.suggestions(have: ingredients)
        if try store.read().mode == .guest { return device }
        let account = try await withCloud(.suggestions) { try await $0.suggestions(have: ingredients) }
        return (device + account).sorted { $0.matchedIngredients.count > $1.matchedIngredients.count }
    }
    private func requireAccountBook(_ id: String) throws {
        if GuestStore.isLocal(id) { throw RecipeBookUIError.signInRequired(.sharing) }
    }
    func addMember(accountID: UserID, to bookID: BookID) async throws -> BookDetail {
        try requireAccountBook(bookID)
        return try await withCloud(.sharing) { try await $0.addMember(accountID: accountID, to: bookID) }
    }
    func changeRole(of userID: UserID, to role: MemberRole, in bookID: BookID) async throws -> BookDetail {
        try requireAccountBook(bookID)
        return try await withCloud(.sharing) { try await $0.changeRole(of: userID, to: role, in: bookID) }
    }
    func removeMember(_ userID: UserID, from bookID: BookID) async throws -> BookDetail {
        try requireAccountBook(bookID)
        return try await withCloud(.sharing) { try await $0.removeMember(userID, from: bookID) }
    }
    func leaveBook(id: BookID, resolution: LastOwnerResolution?) async throws {
        try requireAccountBook(id)
        try await withCloud(.sharing) { try await $0.leaveBook(id: id, resolution: resolution) }
    }
    func shoppingLists() async throws -> [ShoppingListSummary] {
        try await requireLocalAccess()
        let device = try await local.shoppingLists()
        if try store.read().mode == .guest { return device }
        let account = try await withCloud(.account) { try await $0.shoppingLists() }
        return device + account
    }
    func shoppingList(id: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        if GuestStore.isLocal(id) { try await requireLocalAccess(); return try await local.shoppingList(id: id) }
        return try await withCloud(.account) { try await $0.shoppingList(id: id) }
    }
    func createShoppingList(name: String) async throws -> ShoppingListSummary {
        // Personal on-device lists remain usable with either session; no implicit synchronization.
        try await requireLocalAccess()
        return try await local.createShoppingList(name: name)
    }
    func deleteShoppingList(id: ShoppingListID) async throws {
        if GuestStore.isLocal(id) { try await requireLocalAccess(); try await local.deleteShoppingList(id: id); return }
        try await withCloud(.account) { try await $0.deleteShoppingList(id: id) }
    }
    func addShoppingItem(_ item: ShoppingItemDraft, to listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        if GuestStore.isLocal(listID) { try await requireLocalAccess(); return try await local.addShoppingItem(item, to: listID) }
        return try await withCloud(.account) { try await $0.addShoppingItem(item, to: listID) }
    }
    func setShoppingItem(_ itemID: ShoppingItemID, bought: Bool, in listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        if GuestStore.isLocal(listID) { try await requireLocalAccess(); return try await local.setShoppingItem(itemID, bought: bought, in: listID) }
        return try await withCloud(.account) { try await $0.setShoppingItem(itemID, bought: bought, in: listID) }
    }
    func removeShoppingItem(_ itemID: ShoppingItemID, from listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        if GuestStore.isLocal(listID) { try await requireLocalAccess(); return try await local.removeShoppingItem(itemID, from: listID) }
        return try await withCloud(.account) { try await $0.removeShoppingItem(itemID, from: listID) }
    }
    func addRecipeIngredients(recipeID: RecipeID, ingredientIDs: [String], to listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList {
        if GuestStore.isLocal(listID) {
            try await requireLocalAccess()
            if GuestStore.isLocal(recipeID) {
                return try await local.addRecipeIngredients(recipeID: recipeID, ingredientIDs: ingredientIDs, to: listID)
            }
            let recipe = try await withCloud(.account) { try await $0.recipe(id: recipeID) }
            let selected = Set(ingredientIDs)
            guard selected.isSubset(of: Set(recipe.ingredients.map(\.id))) else { throw guestFailure("Ingredient selections do not match this recipe.") }
            return try await local.addSelectedIngredients(recipe.ingredients.filter { selected.contains($0.id) },
                                                         title: recipe.summary.title, to: listID)
        }
        if GuestStore.isLocal(recipeID) {
            guard try store.read().mode == .account else { throw RecipeBookUIError.signInRequired(.account) }
            // A local ID must never be sent to an API that assumes an account-owned recipe.
            throw guestFailure("Choose an on-device shopping list for this on-device recipe.")
        }
        return try await withCloud(.account) { try await $0.addRecipeIngredients(recipeID: recipeID, ingredientIDs: ingredientIDs, to: listID) }
    }
    func importJobs() async throws -> [RecipeBookPresentation.ImportJob] {
        try await withCloud(.importing) { try await $0.importJobs() }
    }
    func importJob(id: ImportJobID) async throws -> RecipeBookPresentation.ImportJob {
        try await withCloud(.importing) { try await $0.importJob(id: id) }
    }
    func submitImport(url: URL) async throws -> RecipeBookPresentation.ImportJob {
        try await withCloud(.importing) { try await $0.submitImport(url: url) }
    }
    func importReview(id: ImportJobID) async throws -> RecipeBookPresentation.RecipeDraft {
        try await withCloud(.importing) { try await $0.importReview(id: id) }
    }
    func approveImport(id: ImportJobID, draft: RecipeBookPresentation.RecipeDraft) async throws -> RecipeDetail {
        guard try store.read().mode == .account else { throw RecipeBookUIError.signInRequired(.importing) }
        if let bookID = draft.bookID, GuestStore.isLocal(bookID) { throw guestFailure("Choose an account book for a cloud import.") }
        return try await withCloud(.importing) { try await $0.approveImport(id: id, draft: draft) }
    }
    func retryImport(id: ImportJobID) async throws -> RecipeBookPresentation.ImportJob {
        try await withCloud(.importing) { try await $0.retryImport(id: id) }
    }
    func discardImport(id: ImportJobID) async throws { try await withCloud(.importing) { try await $0.discardImport(id: id) } }
    func accountDeletionBlockers() async throws -> [BookDetail] { try await withCloud(.account) { try await $0.accountDeletionBlockers() } }
    func deleteAccount(resolutions: [BookID: LastOwnerResolution]) async throws {
        try await withCloud(.account) { try await $0.deleteAccount(resolutions: resolutions) }
        try store.transaction { $0.mode = .none }
        retireCloud()
    }
    func copyLocalBookToAccount(id: BookID, kind: RecipeBookPresentation.BookKind) async throws -> BookSummary {
        // Authorize before preparing any journal operation. Guest mode never touches the factory.
        guard try store.read().mode == .account else { throw RecipeBookUIError.signInRequired(.sharing) }
        let live = try await loadSession()
        guard case .signedIn(let profile) = live else { throw RecipeBookUIError.signInRequired(.sharing) }
        guard let cloudCopy else { throw RecipeBookUIError.serviceNotConfigured }
        let epoch = generation
        let record = try store.transaction { state in
            guard let book = state.books.first(where: { $0.id == id }) else { throw guestFailure("On-device book not found.", status: 404, code: "not_found") }
            let coreKind: RecipeBookCore.BookKind = kind == .shared ? .shared : .personal
            if let existing = state.copies.first(where: {
                $0.operation.accountID == profile.id && $0.operation.localBookID == id
                    && $0.operation.localVersion == book.version && $0.operation.payload.kind == coreKind
            }) { return existing }
            let operation = LocalBookCopy(accountID: profile.id, localBookID: id, localVersion: book.version,
                            idempotencyKey: UUID(), payload: .init(name: book.name, kind: coreKind,
                            recipes: state.recipes.filter { $0.bookID == id }.sorted { $0.id < $1.id }.map(\.coreDraft)))
            let record = GuestStore.CopyRecord(operation: operation, result: nil)
            state.copies.append(record)
            return record
        }
        let result: RecipeBookCore.Book
        if let completed = record.result { result = completed }
        else {
            result = try await cloudCopy(record.operation)
            // Persist committed responses even if the user switched accounts during the request.
            // This record is keyed to the original account; never expose it to a different session.
            guard result.kind == record.operation.payload.kind else { throw guestFailure("The copy response has an unexpected book kind.") }
            try store.transaction { state in
                guard let index = state.copies.firstIndex(where: { $0.operation.idempotencyKey == record.operation.idempotencyKey }) else {
                    throw guestFailure("The on-device copy journal is missing.")
                }
                state.copies[index].result = result
            }
        }
        guard epoch == generation, session == .signedIn(profile) else { throw CancellationError() }
        return .init(id: result.id.uuidString.lowercased(), name: result.name,
                     kind: result.kind == .shared ? .shared : .personal, myRole: result.role == .owner ? .owner : .member,
                     recipeCount: record.operation.payload.recipes.count, memberCount: 1, storage: .account)
    }
}
