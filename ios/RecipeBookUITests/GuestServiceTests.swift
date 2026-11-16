import Foundation
import XCTest
import RecipeBookCore
import RecipeBookPresentation
import UIKit

private actor GuestCloudProbe: RecipeBookService {
    let profile: UserProfile
    var state: SessionState
    private(set) var extendedCalls: [String] = []
    init(id: String, state: SessionState? = nil) {
        profile = .init(id: id, displayName: id)
        self.state = state ?? .signedIn(.init(id: id, displayName: id))
    }
    func loadSession() async throws -> SessionState { state }
    func signIn() async throws -> SessionState { state }
    func completeSetup(displayName: String) async throws -> SessionState { state }
    func signOut() async throws { state = .signedOut }
    func books() async throws -> [BookSummary] {
        [.init(id: profile.id + "-book", name: profile.id, kind: .personal, myRole: .owner, recipeCount: 0, memberCount: 1)]
    }
    func shoppingLists() async throws -> [ShoppingListSummary] { [] }
    func suggestions(have ingredients: [String]) async throws -> [RecipeSuggestion] { [] }
    func createBook(name: String, kind: RecipeBookPresentation.BookKind) async throws -> BookSummary { throw RecipeBookUIError.serviceNotConfigured }
    func book(id: BookID) async throws -> BookDetail { throw RecipeBookUIError.serviceNotConfigured }
    func deleteBook(id: BookID) async throws { throw RecipeBookUIError.serviceNotConfigured }
    func addMember(accountID: UserID, to bookID: BookID) async throws -> BookDetail { throw RecipeBookUIError.serviceNotConfigured }
    func changeRole(of userID: UserID, to role: MemberRole, in bookID: BookID) async throws -> BookDetail { throw RecipeBookUIError.serviceNotConfigured }
    func removeMember(_ userID: UserID, from bookID: BookID) async throws -> BookDetail { throw RecipeBookUIError.serviceNotConfigured }
    func leaveBook(id: BookID, resolution: LastOwnerResolution?) async throws { throw RecipeBookUIError.serviceNotConfigured }
    func recipe(id: RecipeID) async throws -> RecipeDetail { throw RecipeBookUIError.serviceNotConfigured }
    func saveRecipe(_ draft: RecipeBookPresentation.RecipeDraft) async throws -> RecipeDetail { throw RecipeBookUIError.serviceNotConfigured }
    func deleteRecipe(id: RecipeID) async throws { throw RecipeBookUIError.serviceNotConfigured }
    func importJobs() async throws -> [RecipeBookPresentation.ImportJob] { throw RecipeBookUIError.serviceNotConfigured }
    func importJob(id: ImportJobID) async throws -> RecipeBookPresentation.ImportJob { throw RecipeBookUIError.serviceNotConfigured }
    func submitImport(url: URL) async throws -> RecipeBookPresentation.ImportJob { throw RecipeBookUIError.serviceNotConfigured }
    func importReview(id: ImportJobID) async throws -> RecipeBookPresentation.RecipeDraft { throw RecipeBookUIError.serviceNotConfigured }
    func approveImport(id: ImportJobID, draft: RecipeBookPresentation.RecipeDraft) async throws -> RecipeDetail { throw RecipeBookUIError.serviceNotConfigured }
    func retryImport(id: ImportJobID) async throws -> RecipeBookPresentation.ImportJob { throw RecipeBookUIError.serviceNotConfigured }
    func discardImport(id: ImportJobID) async throws { throw RecipeBookUIError.serviceNotConfigured }
    func shoppingList(id: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    func createShoppingList(name: String) async throws -> ShoppingListSummary { throw RecipeBookUIError.serviceNotConfigured }
    func deleteShoppingList(id: ShoppingListID) async throws { throw RecipeBookUIError.serviceNotConfigured }
    func addShoppingItem(_ item: ShoppingItemDraft, to listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    func setShoppingItem(_ itemID: ShoppingItemID, bought: Bool, in listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    func removeShoppingItem(_ itemID: ShoppingItemID, from listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    func addRecipeIngredients(recipeID: RecipeID, ingredientIDs: [String], to listID: ShoppingListID) async throws -> RecipeBookPresentation.ShoppingList { throw RecipeBookUIError.serviceNotConfigured }
    func accountDeletionBlockers() async throws -> [BookDetail] { throw RecipeBookUIError.serviceNotConfigured }
    func deleteAccount(resolutions: [BookID: LastOwnerResolution]) async throws { throw RecipeBookUIError.serviceNotConfigured }
    func imageData(_ image: ImageRef) async throws -> Data {
        extendedCalls.append("image:\(image.id)")
        throw guestFailure("Cloud image request.", code: "cloud_image")
    }
    func readWeek(bookID: BookID, weekStart: PlanDate) async throws -> RecipeBookPresentation.WeeklyPlan? {
        extendedCalls.append("read:\(bookID)")
        return nil
    }
    func generateWeek(bookID: BookID, weekStart: PlanDate, dayStyles: [RecipeBookPresentation.MealStyle?],
                      listID: ShoppingListID, expectedVersion: Int?) async throws -> RecipeBookPresentation.WeeklyPlan {
        extendedCalls.append("generate:\(bookID):\(listID)")
        throw guestFailure("Cloud plan request.", code: "cloud_plan")
    }
    func replacePlanDay(bookID: BookID, weekStart: PlanDate, date: PlanDate, replacement: PlanReplacement?,
                        planVersion: Int) async throws -> RecipeBookPresentation.WeeklyPlan {
        extendedCalls.append("replace:\(bookID)")
        throw guestFailure("Cloud plan request.", code: "cloud_plan")
    }
    func deleteWeek(bookID: BookID, weekStart: PlanDate, planVersion: Int) async throws {
        extendedCalls.append("delete:\(bookID)")
        throw guestFailure("Cloud plan request.", code: "cloud_plan")
    }
}

private actor GuestFactoryProbe {
    var count = 0
    var accountID = "account-one"
    var failure = false
    var nextState: SessionState?
    func configure(accountID: String? = nil, failure: Bool = false, state: SessionState? = nil) {
        if let accountID { self.accountID = accountID }
        self.failure = failure
        nextState = state
    }
    func make() throws -> any RecipeBookService {
        count += 1
        if failure { throw guestFailure("Cloud unavailable.", status: 503, code: "database_unavailable") }
        return GuestCloudProbe(id: accountID, state: nextState)
    }
}

private actor GuestCopyProbe {
    var operations: [LocalBookCopy] = []
    func copy(_ operation: LocalBookCopy) throws -> RecipeBookCore.Book {
        operations.append(operation)
        if operations.count == 1 { throw guestFailure("Response lost.", status: 503, code: "transport") }
        return try JSONDecoder().decode(RecipeBookCore.Book.self, from: Data("""
        {"id":"e0000000-0000-0000-0000-000000000001","name":"Copied","kind":"\(operation.payload.kind.rawValue)","role":"owner","version":1}
        """.utf8))
    }
}

private actor GuestCopyTokens: AccessTokenProvider {
    func accessToken() async throws -> String { "synthetic-guest-copy-test-token" }
}

private final class GuestCopyRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var status = 200
    func reset(status: Int = 200) { lock.withLock { requests = []; self.status = status } }
    func receive(_ request: URLRequest) -> Int {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: 1024)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        return lock.withLock { requests.append(captured); return status }
    }
    func recorded() -> [URLRequest] { lock.withLock { requests } }
}

private final class GuestCopyHTTP: URLProtocol, @unchecked Sendable {
    static let state = GuestCopyRequests()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "guest-copy.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.state.receive(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let json = status == 200
            ? #"{"id":"e0000000-0000-0000-0000-000000000001","name":"Copy","kind":"shared","role":"owner","version":1}"#
            : #"{"code":"account_changed","message":"Sign in to the account that requested this copy."}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class GuestServiceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = root
            .appendingPathComponent(".guest-service-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func service(_ directory: URL, _ factory: GuestFactoryProbe, copy: GuestCopyProbe? = nil) throws -> GuestAwareService {
        if let copy {
            return try GuestAwareService(localDirectory: directory, cloudFactory: { try await factory.make() },
                                         cloudCopy: { try await copy.copy($0) })
        }
        return try GuestAwareService(localDirectory: directory, cloudFactory: { try await factory.make() })
    }
    private func assertGate<T: Sendable>(_ feature: SignInFeature, _ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected contextual sign-in requirement.") }
        catch let error as RecipeBookUIError { XCTAssertEqual(error, .signInRequired(feature)) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testExplicitSelectionAndGuestOperationsNeverConstructCloud() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let service = try service(directory, factory)
        let initial = try await service.loadSession()
        XCTAssertEqual(initial, .signedOut)
        await assertGate(.account) { try await service.books() }
        let selected = try await service.continueWithoutSignIn()
        XCTAssertEqual(selected, .guest)
        let book = try await service.createBook(name: "Personal", kind: .personal)
        XCTAssertEqual(book.storage, .onDevice)
        let recipe = try await service.saveRecipe(.init(bookID: book.id, title: "Soup",
                    ingredients: [.init(name: "Carrots", quantity: "2", unit: "pieces")], steps: [.init(text: "Cook")]))
        let suggestions = try await service.suggestions(have: [" carrots "])
        XCTAssertEqual(suggestions.map(\.id), [recipe.id])
        let list = try await service.createShoppingList(name: "Groceries")
        let shopping = try await service.addRecipeIngredients(recipeID: recipe.id, ingredientIDs: recipe.ingredients.map(\.id), to: list.id)
        _ = try await service.setShoppingItem(shopping.items[0].id, bought: true, in: list.id)
        _ = try await service.removeShoppingItem(shopping.items[0].id, from: list.id)
        await assertGate(.sharing) { try await service.createBook(name: "Shared", kind: .shared) }
        await assertGate(.sharing) { try await service.addMember(accountID: "someone", to: book.id) }
        await assertGate(.sharing) { try await service.changeRole(of: "someone", to: .owner, in: book.id) }
        await assertGate(.sharing) { try await service.removeMember("someone", from: book.id) }
        await assertGate(.sharing) { try await service.leaveBook(id: book.id, resolution: nil) }
        await assertGate(.sharing) { try await service.copyLocalBookToAccount(id: book.id, kind: .shared) }
        await assertGate(.importing) { try await service.importJobs() }
        await assertGate(.importing) { try await service.submitImport(url: URL(string: "https://www.instagram.com/reel/Test/")!) }
        await assertGate(.importing) { try await service.importJob(id: "job") }
        await assertGate(.importing) { try await service.importReview(id: "job") }
        await assertGate(.importing) { try await service.approveImport(id: "job", draft: .init(title: "Import")) }
        await assertGate(.importing) { try await service.retryImport(id: "job") }
        await assertGate(.importing) { try await service.discardImport(id: "job") }
        await assertGate(.account) { try await service.accountDeletionBlockers() }
        await assertGate(.account) { try await service.deleteAccount(resolutions: [:]) }
        await assertGate(.account) { try await service.completeSetup(displayName: "Guest") }
        let reopened = try self.service(directory, factory)
        let reopenedSession = try await reopened.loadSession()
        XCTAssertEqual(reopenedSession, .guest)
        try await service.signOut()
        let signedOut = try await reopened.loadSession()
        XCTAssertEqual(signedOut, .signedOut)
        let count = await factory.count
        XCTAssertEqual(count, 0)
    }
    func testDurableCRUDStableEditorIDsAndAllManualFields() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let service = try service(directory, factory)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Recipes", kind: .personal)
        let original = IngredientLine(id: "stable-ingredient", name: "Flour", quantity: "0.25", unit: "kg",
                                     preparation: "sifted", originalText: "quarter kilo", amountNeedsReview: true)
        let draft = RecipeBookPresentation.RecipeDraft(bookID: book.id, title: "Bread", servings: 3, totalMinutes: 40,
                    ingredients: [original], steps: [.init(id: "stable-step", text: "Bake")],
                    sourceURL: URL(string: "https://example.invalid/recipe"), evidenceText: "Manual evidence")
        let saved = try await service.saveRecipe(draft)
        let list = try await service.createShoppingList(name: "Needed")
        let added = try await service.addRecipeIngredients(recipeID: saved.id, ingredientIDs: [original.id], to: list.id)
        _ = try await service.setShoppingItem(added.items[0].id, bought: true, in: list.id)
        let firstDetail = try await service.book(id: book.id)
        let reopened = try self.service(directory, factory)
        let detail = try await reopened.book(id: book.id)
        XCTAssertEqual(detail.currentUserID, firstDetail.currentUserID)
        let loaded = try await reopened.recipe(id: saved.id)
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded.ingredients, [original])
        let loadedList = try await reopened.shoppingList(id: list.id)
        XCTAssertEqual(loadedList.items[0].id, added.items[0].id)
        XCTAssertTrue(loadedList.items[0].isBought)
        XCTAssertEqual(loadedList.items[0].sourceRecipeTitle, "Bread")
        var editing = RecipeBookPresentation.RecipeDraft(editing: loaded)
        editing.title = "Bread updated"
        let updated = try await reopened.saveRecipe(editing)
        XCTAssertEqual(updated.ingredients[0].id, original.id)
        XCTAssertEqual(updated.steps[0].id, "stable-step")
        let stored = try GuestStore(directory: directory).read()
        XCTAssertEqual(stored.recipes[0].evidenceText, "Manual evidence")
        try await reopened.deleteRecipe(id: saved.id)
        let suggestions = try await reopened.suggestions(have: ["flour"])
        XCTAssertTrue(suggestions.isEmpty)
        try await reopened.deleteShoppingList(id: list.id)
        try await reopened.deleteBook(id: book.id)
        let final = try self.service(directory, factory)
        let books = try await final.books()
        let lists = try await final.shoppingLists()
        XCTAssertTrue(books.isEmpty)
        XCTAssertTrue(lists.isEmpty)
    }
    func testExactAggregationAlreadyHavePreparationsUnknownAndBoughtEntries() async throws {
        let service = try GuestService(localDirectory: directory())
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Recipes", kind: .personal)
        let lines: [IngredientLine] = [
            .init(id: "a", name: " Flour ", quantity: "0.1", unit: "kg"),
            .init(id: "b", name: "flour", quantity: "0.000001", unit: "g"),
            .init(id: "c", name: "flour", quantity: "2", unit: "ml"),
            .init(id: "d", name: "flour", quantity: nil, unit: "g"),
            .init(id: "e", name: "flour", quantity: "4", unit: "g", preparation: "sifted"),
            .init(id: "f", name: "eggs", quantity: "1", unit: "pieces"),
            .init(id: "g", name: "eggs", quantity: "2", unit: "piece"),
            .init(id: "omit", name: "already have", quantity: "1", unit: "g")
        ]
        let recipe = try await service.saveRecipe(.init(bookID: book.id, title: "Baking", ingredients: lines))
        let list = try await service.createShoppingList(name: "Needed")
        var result = try await service.addRecipeIngredients(recipeID: recipe.id, ingredientIDs: lines.filter { $0.id != "omit" }.map(\.id), to: list.id)
        XCTAssertEqual(result.items.count, 5)
        XCTAssertEqual(result.items[0].quantity, "100.000001")
        XCTAssertEqual(result.items[0].unit, "g")
        XCTAssertEqual(result.items[1].unit, "ml")
        XCTAssertNil(result.items[2].quantity)
        XCTAssertEqual(result.items[3].quantity, "4")
        XCTAssertEqual(result.items[4].quantity, "3")
        XCTAssertEqual(result.items[4].unit, "piece")
        let boughtID = result.items[0].id
        result = try await service.setShoppingItem(boughtID, bought: true, in: list.id)
        result = try await service.addShoppingItem(.init(name: "flour", quantity: "0.2", unit: "g"), to: list.id)
        XCTAssertEqual(result.items.count, 6)
        XCTAssertEqual(result.items[0].quantity, "100.000001")
        XCTAssertTrue(result.items[0].isBought)
        XCTAssertEqual(result.items.last?.quantity, "0.2")
        let before = result
        do {
            _ = try await service.addRecipeIngredients(recipeID: recipe.id, ingredientIDs: ["not-a-line"], to: list.id)
            XCTFail("Invalid selections must fail.")
        } catch let error as APIError { XCTAssertEqual(error.code, "client_state") }
        let after = try await service.shoppingList(id: list.id)
        XCTAssertEqual(after, before)
    }
    func testQuantityOverflowIsAtomicAndDecimalValidationMatchesBackend() throws {
        XCTAssertEqual(try GuestQuantities.parse("999999999.999999"), 999_999_999_999_999)
        for invalid in ["-1", "01", "1.0000001", "1e2", "NaN", "1000000000", " 1", "1."] {
            XCTAssertThrowsError(try GuestQuantities.parse(invalid))
        }
        var items = [GuestStore.Item(id: "one", ingredient: .init(name: "rice", quantity: "999999999", unit: "g"),
                                    bought: false, sourceRecipeTitle: nil)]
        XCTAssertThrowsError(try GuestQuantities.append(.init(name: "rice", quantity: "1", unit: "g"), title: nil, to: &items))
        XCTAssertEqual(items[0].ingredient.quantity, "999999999")
    }
    func testLitresAndFreeFormUnknownUnitsNeverMixWithMass() throws {
        var items: [GuestStore.Item] = []
        try GuestQuantities.append(.init(name: "water", quantity: "0.1", unit: "l"), title: nil, to: &items)
        try GuestQuantities.append(.init(name: " Water ", quantity: "0.2", unit: "ml"), title: nil, to: &items)
        XCTAssertEqual(items[0].ingredient.quantity, "100.2")
        XCTAssertEqual(items[0].ingredient.unit, "ml")
        try GuestQuantities.append(.init(name: "water", quantity: "5", unit: "g"), title: nil, to: &items)
        try GuestQuantities.append(.init(name: "water", quantity: "1", unit: "tbsp"), title: nil, to: &items)
        try GuestQuantities.append(.init(name: "water", quantity: "2", unit: "tbsp"), title: nil, to: &items)
        try GuestQuantities.append(.init(name: "water", quantity: nil, unit: "ml"), title: nil, to: &items)
        try GuestQuantities.append(.init(name: "water", quantity: nil, unit: "ml"), title: nil, to: &items)
        XCTAssertEqual(items.count, 6)
    }
    func testStaleRecipeAndListWritesRequireReloadAndNeverOverwrite() async throws {
        let directory = try directory()
        let a = try GuestService(localDirectory: directory)
        _ = try await a.continueWithoutSignIn()
        let book = try await a.createBook(name: "Recipes", kind: .personal)
        let recipe = try await a.saveRecipe(.init(bookID: book.id, title: "Original"))
        let list = try await a.createShoppingList(name: "Needed")
        let b = try GuestService(localDirectory: directory)
        _ = try await b.recipe(id: recipe.id)
        _ = try await b.shoppingList(id: list.id)
        var draft = RecipeBookPresentation.RecipeDraft(editing: recipe)
        draft.title = "A's update"
        _ = try await a.saveRecipe(draft)
        _ = try await a.addShoppingItem(.init(name: "rice"), to: list.id)
        do { _ = try await b.saveRecipe(draft); XCTFail("Stale recipe must fail.") }
        catch let error as APIError { XCTAssertEqual(error.status, 412) }
        do { _ = try await b.addShoppingItem(.init(name: "beans"), to: list.id); XCTFail("Stale list must fail.") }
        catch let error as APIError { XCTAssertEqual(error.status, 412) }
        let actual = try await b.recipe(id: recipe.id)
        XCTAssertEqual(actual.summary.title, "A's update")
        let actualList = try await b.shoppingList(id: list.id)
        XCTAssertEqual(actualList.items.map(\.name), ["rice"])
        _ = try await b.addShoppingItem(.init(name: "beans"), to: list.id)
    }
    func testSignInSignOutRetainsLocalDataAndIsolatesAccountAdapters() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let service = try service(directory, factory)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Device", kind: .personal)
        let list = try await service.createShoppingList(name: "Device groceries")
        _ = try await service.signIn()
        let first = try await service.books()
        XCTAssertEqual(Set(first.map(\.id)), [book.id, "account-one-book"])
        let signedInLists = try await service.shoppingLists()
        XCTAssertEqual(signedInLists.map(\.id), [list.id])
        try await service.signOut()
        _ = try await service.continueWithoutSignIn()
        let deviceOnly = try await service.books()
        XCTAssertEqual(deviceOnly.map(\.id), [book.id])
        await factory.configure(accountID: "account-two")
        _ = try await service.signIn()
        let second = try await service.books()
        XCTAssertEqual(Set(second.map(\.id)), [book.id, "account-two-book"])
        let count = await factory.count
        XCTAssertEqual(count, 2)
        let reopened = try self.service(directory, factory)
        _ = try await reopened.loadSession()
        let retained = try await reopened.book(id: book.id)
        XCTAssertEqual(retained.summary.storage, .onDevice)
    }
    func testNoAutomaticGuestFallbackForUnavailableCloudInviteOrSetup() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let service = try service(directory, factory)
        await factory.configure(failure: true)
        do { _ = try await service.signIn(); XCTFail("Cloud failure must surface.") }
        catch let error as APIError { XCTAssertEqual(error.status, 503) }
        let unchanged = try await service.loadSession()
        XCTAssertEqual(unchanged, .signedOut)
        await factory.configure(state: .awaitingInvite(accountID: "waiting"))
        let waiting = try await service.signIn()
        XCTAssertEqual(waiting, .awaitingInvite(accountID: "waiting"))
        await assertGate(.account) { try await service.books() }
        _ = try await service.continueWithoutSignIn()
        let localBook = try await service.createBook(name: "Offline", kind: .personal)
        await factory.configure(failure: true)
        do { _ = try await service.signIn(); XCTFail("Failure must surface, not return guest success.") }
        catch let error as APIError { XCTAssertEqual(error.status, 503) }
        let retainedGuest = try await service.loadSession()
        XCTAssertEqual(retainedGuest, .guest)
        let retainedBooks = try await service.books()
        XCTAssertEqual(retainedBooks.map(\.id), [localBook.id])
        await factory.configure(state: .needsSetup(.init(id: "setup", displayName: "")))
        let setup = try await service.signIn()
        XCTAssertEqual(setup, .needsSetup(.init(id: "setup", displayName: "")))
        _ = try await service.continueWithoutSignIn()
        let guest = try await service.loadSession()
        XCTAssertEqual(guest, .guest)
    }
    func testCorruptStoreIsSurfacedAndNotSilentlyReset() throws {
        let directory = try directory()
        _ = try GuestStore(directory: directory)
        let file = directory.appendingPathComponent("guest-store.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file, options: .atomic)
        do { _ = try GuestStore(directory: directory); XCTFail("Corruption must remain visible.") }
        catch let error as APIError { XCTAssertEqual(error.code, "local_storage") }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testCopyJournalPersistsExactSnapshotAndKeyAcrossRetryReopenAndAccounts() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let copy = GuestCopyProbe()
        let service = try service(directory, factory, copy: copy)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Local", kind: .personal)
        _ = try await service.saveRecipe(.init(bookID: book.id, title: "Soup",
                    ingredients: [.init(name: "carrots", quantity: "2", unit: "pieces", preparation: "diced")],
                    steps: [.init(text: "Cook")], sourceURL: URL(string: "https://example.invalid/soup"), mealStyle: .simple))
        _ = try await service.signIn()
        do { _ = try await service.copyLocalBookToAccount(id: book.id, kind: .shared); XCTFail("Lost response must surface.") }
        catch let error as APIError { XCTAssertEqual(error.code, "transport") }
        let reopened = try self.service(directory, factory, copy: copy)
        let result = try await reopened.copyLocalBookToAccount(id: book.id, kind: .shared)
        XCTAssertEqual(result.storage, .account)
        var operations = await copy.operations
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0].idempotencyKey, operations[1].idempotencyKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(operations[0].payload), try encoder.encode(operations[1].payload))
        XCTAssertEqual(operations[1].payload.recipes[0].ingredients[0].preparation, "diced")
        XCTAssertEqual(operations[1].payload.recipes[0].mealStyle, .simple)
        XCTAssertEqual(operations[1].payload.recipes[0].sourceURL?.absoluteString, "https://example.invalid/soup")
        _ = try await reopened.copyLocalBookToAccount(id: book.id, kind: .shared)
        operations = await copy.operations
        XCTAssertEqual(operations.count, 2, "Completed operations must return the recorded result.")
        let local = try await reopened.book(id: book.id)
        XCTAssertEqual(local.recipes.count, 1)
        XCTAssertEqual(local.summary.storage, .onDevice)
        try await reopened.signOut()
        await factory.configure(accountID: "account-two")
        _ = try await reopened.signIn()
        _ = try await reopened.copyLocalBookToAccount(id: book.id, kind: .shared)
        operations = await copy.operations
        XCTAssertEqual(operations.count, 3)
        XCTAssertNotEqual(operations[2].idempotencyKey, operations[0].idempotencyKey)
        XCTAssertEqual(operations[2].accountID, "account-two")
        let saved = try await reopened.recipe(id: local.recipes[0].id)
        var editing = RecipeBookPresentation.RecipeDraft(editing: saved)
        editing.title = "Changed soup"
        _ = try await reopened.saveRecipe(editing)
        _ = try await reopened.copyLocalBookToAccount(id: book.id, kind: .shared)
        operations = await copy.operations
        XCTAssertEqual(operations.count, 4)
        XCTAssertNotEqual(operations[3].idempotencyKey, operations[2].idempotencyKey)
        XCTAssertGreaterThan(operations[3].localVersion, operations[2].localVersion)
        XCTAssertEqual(operations[3].payload.recipes[0].title, "Changed soup")
        XCTAssertEqual(operations[0].payload.recipes[0].title, "Soup", "Previously journaled snapshots are immutable.")
    }
    func testCopyTransportSendsOnlySnapshotAndBindsExpectedAccountWithoutLeakingHeaders() async throws {
        GuestCopyHTTP.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuestCopyHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = try APIClient(baseURL: URL(string: "https://guest-copy.invalid/api")!,
                                tokens: GuestCopyTokens(), session: session)
        let accountID = UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!
        let key = UUID()
        let payload = LocalBookCopy.Payload(name: "Copy", kind: .shared, recipes: [
            .init(title: "Soup", ingredients: [.init(name: "carrots", quantity: "2", unit: "pieces")], steps: ["Cook"])
        ])
        let copied = try await api.copyLocalBook(payload: payload, idempotencyKey: key, expectedAccountID: accountID)
        XCTAssertEqual(copied.kind, .shared)
        _ = try await api.account()
        let requests = GuestCopyHTTP.state.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/api/local-book-copies")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString.lowercased())
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Recipe-Account-ID"), accountID.uuidString.lowercased())
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["name", "kind", "recipes"])
        let recipes = try XCTUnwrap(json["recipes"] as? [[String: Any]])
        XCTAssertEqual(recipes[0]["title"] as? String, "Soup")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-Recipe-Account-ID"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
    }
    func testCopyWithPhotosFailsExplicitlyBeforeJournalOrTransportAndPreservesOriginal() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let copy = GuestCopyProbe()
        let service = try service(directory, factory, copy: copy)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "With photos", kind: .personal)
        let bytes = try jpeg()
        let source = URL(string: "https://example.invalid/original")!
        let recipe = try await service.saveRecipe(.init(bookID: book.id, title: "Original", sourceURL: source,
            mealStyle: .full, coverImageEdit: .replace(jpegData: bytes)))
        _ = try await service.signIn()
        let file = directory.appendingPathComponent("guest-store.json")
        let before = try Data(contentsOf: file)
        do {
            _ = try await service.copyLocalBookToAccount(id: book.id, kind: .shared)
            XCTFail("Photo copying must fail explicitly, not strip the cover.")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "local_copy_photos_unsupported")
            XCTAssertTrue(error.message.contains("not supported yet"))
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        let retained = try await service.recipe(id: recipe.id)
        XCTAssertEqual(retained, recipe)
        XCTAssertEqual(retained.sourceURL, source)
        XCTAssertEqual(retained.summary.mealStyle, .full)
        let photo = try XCTUnwrap(retained.summary.coverImage)
        let retainedBytes = try await service.imageData(photo)
        XCTAssertEqual(retainedBytes, bytes)
        let operations = await copy.operations
        XCTAssertTrue(operations.isEmpty)
        XCTAssertTrue(try GuestStore(directory: directory).read().copies.isEmpty)
    }
    func testOldPhotoStrippedPendingCopyIsNotRetriedOrRewritten() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let copy = GuestCopyProbe()
        let service = try service(directory, factory, copy: copy)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Legacy photo copy", kind: .personal)
        let source = URL(string: "https://example.invalid/legacy")!
        _ = try await service.saveRecipe(.init(bookID: book.id, title: "Original", sourceURL: source,
            mealStyle: .simple, coverImageEdit: .replace(jpegData: jpeg())))
        _ = try await service.signIn()
        let key = UUID()
        let store = try GuestStore(directory: directory)
        try store.transaction { state in
            let version = try XCTUnwrap(state.books.first(where: { $0.id == book.id })?.version)
            let oldDraft = RecipeBookCore.RecipeDraft(title: "Original", ingredients: [], steps: [], sourceURL: source, mealStyle: .simple)
            let oldOperation = LocalBookCopy(accountID: "account-one", localBookID: book.id, localVersion: version,
                idempotencyKey: key, payload: .init(name: book.name, kind: .shared, recipes: [oldDraft]))
            state.copies.append(.init(operation: oldOperation, result: nil))
        }
        let file = directory.appendingPathComponent("guest-store.json")
        let before = try Data(contentsOf: file)
        let reopened = try self.service(directory, factory, copy: copy)
        do {
            _ = try await reopened.copyLocalBookToAccount(id: book.id, kind: .shared)
            XCTFail("An older photo-stripped journal must not bypass the guard.")
        } catch let error as APIError { XCTAssertEqual(error.code, "local_copy_photos_unsupported") }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try store.read().copies[0].operation.idempotencyKey, key)
        let operations = await copy.operations
        XCTAssertTrue(operations.isEmpty)
    }
    func testCopyTransportSurfacesAccountMismatchWithoutRetryOrFallback() async throws {
        GuestCopyHTTP.state.reset(status: 409)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuestCopyHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = try APIClient(baseURL: URL(string: "https://guest-copy.invalid/api")!,
                                tokens: GuestCopyTokens(), session: session)
        do {
            _ = try await api.copyLocalBook(payload: LocalBookCopy.Payload(name: "Copy", kind: .personal, recipes: []),
                                            idempotencyKey: UUID(), expectedAccountID: UUID())
            XCTFail("The account mismatch must surface.")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.code, "account_changed")
        }
        XCTAssertEqual(GuestCopyHTTP.state.recorded().count, 1)
    }
    func testGuestPlannerGeneratesReplacesAndDeletesWithoutTouchingManualItems() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let service = try service(directory, factory)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Weekly", kind: .personal)
        let soup = try await service.saveRecipe(.init(bookID: book.id, title: "Soup", servings: 2,
            ingredients: [.init(name: "carrot", quantity: "0.1", unit: "kg")],
            sourceURL: URL(string: "https://example.invalid/soup"), mealStyle: .simple))
        let stew = try await service.saveRecipe(.init(bookID: book.id, title: "Stew", servings: 4,
            ingredients: [.init(name: "carrot", quantity: "0.2", unit: "kg")], mealStyle: .full))
        let list = try await service.createShoppingList(name: "Week")
        let manual = try await service.addShoppingItem(.init(name: "carrot", quantity: "7", unit: "g"), to: list.id)
        let manualID = manual.items[0].id
        let empty = try await service.readWeek(bookID: book.id, weekStart: "2026-11-16")
        XCTAssertNil(empty)
        var plan = try await service.generateWeek(bookID: book.id, weekStart: "2026-11-16",
            dayStyles: [.simple, nil, nil, nil, nil, nil, nil], listID: list.id, expectedVersion: nil)
        XCTAssertEqual(plan.days.count, 7)
        XCTAssertEqual(plan.days[0].slot?.recipeID, soup.id)
        XCTAssertEqual(plan.days[0].slot?.recipe?.mealStyle, .simple)
        var shopping = try await service.shoppingList(id: list.id)
        XCTAssertEqual(shopping.items.count, 2)
        XCTAssertEqual(shopping.items[0].id, manualID)
        XCTAssertEqual(shopping.items[0].quantity, "7")
        XCTAssertEqual(shopping.items[1].quantity, "100")
        guard case .generated(let provenance) = shopping.items[1].origin else { return XCTFail("Missing generated provenance.") }
        XCTAssertEqual(provenance.bookID, book.id)
        XCTAssertEqual(provenance.planID, plan.id)
        XCTAssertEqual(provenance.planVersion, plan.version)
        XCTAssertEqual(provenance.recipeTitles, ["Soup"])
        shopping = try await service.setShoppingItem(shopping.items[1].id, bought: true, in: list.id)
        XCTAssertTrue(shopping.items[1].isBought)
        let checkedPlan = try await service.readWeek(bookID: book.id, weekStart: "2026-11-16")
        plan = try XCTUnwrap(checkedPlan)
        plan = try await service.replacePlanDay(bookID: book.id, weekStart: plan.weekStart, date: plan.days[0].date,
            replacement: .init(recipeID: stew.id, recipeVersion: stew.summary.version, servings: 8), planVersion: plan.version)
        shopping = try await service.shoppingList(id: list.id)
        XCTAssertEqual(shopping.items[1].quantity, "400")
        XCTAssertFalse(shopping.items[1].isBought, "Newly required amounts must not remain checked off.")
        XCTAssertEqual(shopping.items[0], manual.items[0])
        let reopened = try self.service(directory, factory)
        let savedPlan = try await reopened.readWeek(bookID: book.id, weekStart: plan.weekStart)
        XCTAssertEqual(savedPlan, plan)
        let savedShopping = try await reopened.shoppingList(id: list.id)
        XCTAssertEqual(savedShopping, shopping)
        try await reopened.deleteWeek(bookID: book.id, weekStart: plan.weekStart, planVersion: plan.version)
        let after = try await reopened.shoppingList(id: list.id)
        XCTAssertEqual(after.items, manual.items)
        let removed = try await reopened.readWeek(bookID: book.id, weekStart: plan.weekStart)
        XCTAssertNil(removed)
        let count = await factory.count
        XCTAssertEqual(count, 0)
    }
    func testPlannerRecipeEditsAndDeletionReconcileAtomicallyAndRejectStaleChecking() async throws {
        let directory = try directory()
        let a = try GuestService(localDirectory: directory)
        _ = try await a.continueWithoutSignIn()
        let book = try await a.createBook(name: "Week", kind: .personal)
        let recipe = try await a.saveRecipe(.init(bookID: book.id, title: "Rice", servings: 2,
            ingredients: [.init(name: "rice", quantity: "100", unit: "g")], mealStyle: .simple))
        let list = try await a.createShoppingList(name: "Shopping")
        _ = try await a.addShoppingItem(.init(name: "manual"), to: list.id)
        let plan = try await a.generateWeek(bookID: book.id, weekStart: "2026-11-16",
            dayStyles: [.simple, nil, nil, nil, nil, nil, nil], listID: list.id, expectedVersion: nil)
        let b = try GuestService(localDirectory: directory)
        let before = try await b.shoppingList(id: list.id)
        let generatedID = try XCTUnwrap(before.items.first(where: \.isGenerated)?.id)
        _ = try await a.shoppingList(id: list.id)
        _ = try await a.setShoppingItem(generatedID, bought: true, in: list.id)
        do {
            _ = try await b.setShoppingItem(generatedID, bought: true, in: list.id)
            XCTFail("Checking generated rows must check the observed plan version.")
        } catch PlannerError.versionConflict {}
        do {
            _ = try await b.replacePlanDay(bookID: book.id, weekStart: plan.weekStart, date: plan.days[0].date,
                                           replacement: nil, planVersion: plan.version)
            XCTFail("Stale replacement must fail.")
        } catch PlannerError.versionConflict {}
        var draft = RecipeBookPresentation.RecipeDraft(editing: recipe)
        draft.title = "Rice changed"
        _ = try await a.saveRecipe(draft)
        let envelope = try GuestStore(directory: directory).read()
        XCTAssertTrue(envelope.plans[0].generated.isEmpty)
        XCTAssertNil(envelope.plans[0].plan.days[0].slot)
        XCTAssertEqual(envelope.lists[0].items.count, 1)
        XCTAssertGreaterThan(envelope.plans[0].plan.version, plan.version)
        let currentValue = try await b.readWeek(bookID: book.id, weekStart: plan.weekStart)
        let current = try XCTUnwrap(currentValue)
        XCTAssertFalse(current.warnings.isEmpty)
        let updatedValue = try await a.recipe(id: recipe.id)
        let updated = try await a.replacePlanDay(bookID: book.id, weekStart: plan.weekStart, date: plan.days[0].date,
            replacement: .init(recipeID: recipe.id, recipeVersion: updatedValue.summary.version, servings: 2), planVersion: current.version)
        XCTAssertNotNil(updated.days[0].slot)
        try await a.deleteRecipe(id: recipe.id)
        let final = try await a.shoppingList(id: list.id)
        XCTAssertEqual(final.items.map(\.name), ["manual"])
    }
    func testPlannerRegenerationMovesGeneratedSectionAndPreservesBothManualLists() async throws {
        let a = try GuestService(localDirectory: directory())
        _ = try await a.continueWithoutSignIn()
        let book = try await a.createBook(name: "Week", kind: .personal)
        _ = try await a.saveRecipe(.init(bookID: book.id, title: "Eggs",
            ingredients: [.init(name: "egg", quantity: "1", unit: "piece")], mealStyle: .simple))
        let first = try await a.createShoppingList(name: "First")
        let second = try await a.createShoppingList(name: "Second")
        _ = try await a.addShoppingItem(.init(name: "first manual"), to: first.id)
        _ = try await a.addShoppingItem(.init(name: "second manual"), to: second.id)
        let plan = try await a.generateWeek(bookID: book.id, weekStart: "2026-11-16",
            dayStyles: [.simple, nil, nil, nil, nil, nil, nil], listID: first.id, expectedVersion: nil)
        let regenerated = try await a.generateWeek(bookID: book.id, weekStart: plan.weekStart,
            dayStyles: [.simple, .simple, nil, nil, nil, nil, nil], listID: second.id, expectedVersion: plan.version)
        XCTAssertEqual(regenerated.id, plan.id)
        let firstList = try await a.shoppingList(id: first.id)
        let secondList = try await a.shoppingList(id: second.id)
        XCTAssertEqual(firstList.items.map(\.name), ["first manual"])
        XCTAssertEqual(secondList.items.count, 2)
        XCTAssertEqual(secondList.items[0].name, "second manual")
        XCTAssertEqual(secondList.items[1].quantity, "2")
        try await a.deleteBook(id: book.id)
        let retained = try await a.shoppingList(id: second.id)
        XCTAssertEqual(retained.items.map(\.name), ["second manual"])
    }
    private func jpeg(width: CGFloat = 12, height: CGFloat = 8) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }
    func testGuestImageReopenReplacementRemovalAndSourceLinkRetention() async throws {
        let directory = try directory()
        let factory = GuestFactoryProbe()
        let service = try service(directory, factory)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Images", kind: .personal)
        let bytes = try jpeg()
        let source = URL(string: "https://example.invalid/original-recipe")!
        let recipe = try await service.saveRecipe(.init(bookID: book.id, title: "Recipe", sourceURL: source,
            mealStyle: .complicated, coverImageEdit: .replace(jpegData: bytes)))
        let reference = try XCTUnwrap(recipe.summary.coverImage)
        let reopened = try self.service(directory, factory)
        let loaded = try await reopened.recipe(id: recipe.id)
        XCTAssertEqual(loaded.sourceURL, source)
        XCTAssertEqual(loaded.summary.mealStyle, .complicated)
        let savedBytes = try await reopened.imageData(reference)
        XCTAssertEqual(savedBytes, bytes)
        var draft = RecipeBookPresentation.RecipeDraft(editing: loaded)
        draft.title = "Edited title"
        let unchanged = try await reopened.saveRecipe(draft)
        XCTAssertEqual(unchanged.summary.coverImage, reference)
        draft = .init(editing: unchanged)
        let replacementBytes = try jpeg(width: 14)
        draft.coverImageEdit = .replace(jpegData: replacementBytes)
        let replacement = try await reopened.saveRecipe(draft)
        let replacementRef = try XCTUnwrap(replacement.summary.coverImage)
        XCTAssertNotEqual(replacementRef, reference)
        do { _ = try await reopened.imageData(reference); XCTFail("Retired images must no longer be accessible.") }
        catch let error as APIError { XCTAssertEqual(error.status, 404) }
        XCTAssertEqual(try GuestStore(directory: directory).read().images.count, 1)
        draft = .init(editing: replacement)
        draft.coverImageEdit = .remove
        let removed = try await reopened.saveRecipe(draft)
        XCTAssertNil(removed.summary.coverImage)
        XCTAssertEqual(removed.sourceURL, source)
        XCTAssertEqual(removed.summary.mealStyle, .complicated)
        XCTAssertTrue(try GuestStore(directory: directory).read().images.isEmpty)
        do { _ = try await reopened.imageData(.init(id: "device-../../outside")); XCTFail("Arbitrary paths are never image references.") }
        catch let error as APIError { XCTAssertEqual(error.status, 404) }
        await assertGate(.account) { try await reopened.imageData(.init(id: "https://example.invalid/image.jpg")) }
        let count = await factory.count
        XCTAssertEqual(count, 0)
    }
    func testInvalidGuestImagesDoNotPartiallyPersistRecipeOrCover() async throws {
        let directory = try directory()
        let service = try GuestService(localDirectory: directory)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Images", kind: .personal)
        let bytes = try jpeg()
        let recipe = try await service.saveRecipe(.init(bookID: book.id, title: "Valid", coverImageEdit: .replace(jpegData: bytes)))
        for invalid in [Data(), Data("not an image".utf8), Data(repeating: 0, count: 2 * 1024 * 1024 + 1), try jpeg(width: 1601)] {
            var draft = RecipeBookPresentation.RecipeDraft(editing: recipe)
            draft.title = "Must not save"
            draft.coverImageEdit = .replace(jpegData: invalid)
            do { _ = try await service.saveRecipe(draft); XCTFail("Invalid image must fail.") }
            catch let error as APIError { XCTAssertEqual(error.code, "image") }
        }
        let retained = try await service.recipe(id: recipe.id)
        XCTAssertEqual(retained, recipe)
        try await service.deleteRecipe(id: recipe.id)
        XCTAssertTrue(try GuestStore(directory: directory).read().images.isEmpty)
    }
    func testOldGuestEnvelopeDecodesNewOptionalPlannerAndImageFieldsWithoutReset() async throws {
        let directory = try directory()
        let service = try GuestService(localDirectory: directory)
        _ = try await service.continueWithoutSignIn()
        let book = try await service.createBook(name: "Old data", kind: .personal)
        let recipe = try await service.saveRecipe(.init(bookID: book.id, title: "Old recipe"))
        let file = directory.appendingPathComponent("guest-store.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json.removeValue(forKey: "storedPlans")
        json.removeValue(forKey: "imageBytes")
        var recipes = try XCTUnwrap(json["recipes"] as? [[String: Any]])
        recipes[0].removeValue(forKey: "mealStyle")
        recipes[0].removeValue(forKey: "coverImageID")
        json["recipes"] = recipes
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        let reopened = try GuestService(localDirectory: directory)
        let saved = try await reopened.recipe(id: recipe.id)
        XCTAssertEqual(saved.id, recipe.id)
        XCTAssertNil(saved.summary.mealStyle)
        XCTAssertNil(saved.summary.coverImage)
        let empty = try await reopened.readWeek(bookID: book.id, weekStart: "2026-11-16")
        XCTAssertNil(empty)
    }
    func testAccountPlannerAndImagesDelegateButGuestAndLocalReferencesNeverDo() async throws {
        let directory = try directory()
        let cloud = GuestCloudProbe(id: "cloud-account")
        let service = try GuestAwareService(localDirectory: directory, cloudFactory: { cloud })
        _ = try await service.continueWithoutSignIn()
        await assertGate(.account) { try await service.readWeek(bookID: "cloud-book", weekStart: "2026-11-16") }
        await assertGate(.account) { try await service.imageData(.init(id: "cloud-image")) }
        let localBook = try await service.createBook(name: "Local", kind: .personal)
        _ = try await service.signIn()
        let empty = try await service.readWeek(bookID: "cloud-book", weekStart: "2026-11-16")
        XCTAssertNil(empty)
        do {
            _ = try await service.generateWeek(bookID: "cloud-book", weekStart: "2026-11-16",
                dayStyles: Array(repeating: .simple, count: 7), listID: "cloud-list", expectedVersion: nil)
            XCTFail("Cloud failure should surface.")
        } catch let error as APIError { XCTAssertEqual(error.code, "cloud_plan") }
        do {
            _ = try await service.replacePlanDay(bookID: "cloud-book", weekStart: "2026-11-16", date: "2026-11-16",
                                                 replacement: nil, planVersion: 1)
            XCTFail("Cloud failure should surface.")
        } catch let error as APIError { XCTAssertEqual(error.code, "cloud_plan") }
        do {
            try await service.deleteWeek(bookID: "cloud-book", weekStart: "2026-11-16", planVersion: 1)
            XCTFail("Cloud failure should surface.")
        } catch let error as APIError { XCTAssertEqual(error.code, "cloud_plan") }
        do {
            _ = try await service.imageData(.init(id: "cloud-image"))
            XCTFail("Cloud failure should surface.")
        } catch let error as APIError { XCTAssertEqual(error.code, "cloud_image") }
        let localWeek = try await service.readWeek(bookID: localBook.id, weekStart: "2026-11-16")
        XCTAssertNil(localWeek)
        do { _ = try await service.imageData(.init(id: GuestStore.newID())); XCTFail("Local image must remain local.") }
        catch let error as APIError { XCTAssertEqual(error.status, 404) }
        let calls = await cloud.extendedCalls
        XCTAssertEqual(calls, ["read:cloud-book", "generate:cloud-book:cloud-list", "replace:cloud-book",
                               "delete:cloud-book", "image:cloud-image"])
    }
}
