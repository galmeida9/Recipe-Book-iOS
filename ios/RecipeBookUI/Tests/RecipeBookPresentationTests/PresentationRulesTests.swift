import XCTest
@testable import RecipeBookPresentation

final class PresentationRulesTests: XCTestCase {
    private let me = BookMember(id: "me", displayName: "Me", role: .owner)
    private let ana = BookMember(id: "ana", displayName: "Ana", role: .member)

    private func book(kind: BookKind = .shared, myRole: MemberRole = .owner, members: [BookMember]) -> BookDetail {
        BookDetail(summary: BookSummary(id: "b", name: "Family", kind: kind, myRole: myRole,
                                        recipeCount: 0, memberCount: members.count),
                   currentUserID: "me", recipes: [], members: members)
    }

    // MARK: Drafts

    func testEvidenceTextIsOptionalAndNotCarriedIntoEdits() {
        XCTAssertNil(RecipeDraft().evidenceText)
        let draft = RecipeDraft(title: "Soup", evidenceText: "caption")
        XCTAssertEqual(draft.evidenceText, "caption")
        let saved = RecipeDetail(summary: RecipeSummary(id: "1", bookID: "b", title: "Soup", authorID: "me", authorName: "Me"),
                                 ingredients: [], steps: [])
        XCTAssertNil(RecipeDraft(editing: saved).evidenceText)
    }

    // MARK: Guest mode

    func testBookStorageDefaultsToAccountForExistingCallers() {
        let book = BookSummary(id: "b", name: "Soups", kind: .personal, myRole: .owner, recipeCount: 0, memberCount: 1)
        XCTAssertEqual(book.storage, .account)
        let local = BookSummary(id: "l", name: "Soups", kind: .personal, myRole: .owner, recipeCount: 0, memberCount: 1,
                                storage: .onDevice)
        XCTAssertEqual(local.storage, .onDevice)
    }

    func testSignInRequiredErrorExplainsFeatureAndKeepsLocalData() {
        for feature in SignInFeature.allCases {
            let description = RecipeBookUIError.signInRequired(feature).errorDescription ?? ""
            XCTAssertTrue(description.hasPrefix(feature.title))
            XCTAssertTrue(feature.message.contains("stay here"), "\(feature) must say local data stays")
        }
        XCTAssertNotEqual(RecipeBookUIError.signInRequired(.sharing), .signInRequired(.importing))
    }

    func testGuestDefaultsNeverSucceed() async {
        let service = UnconfiguredRecipeBookService()
        do {
            _ = try await service.continueWithoutSignIn()
            XCTFail("Unconfigured service must not enter guest mode")
        } catch {
            XCTAssertEqual(error as? RecipeBookUIError, .serviceNotConfigured)
        }
        do {
            _ = try await service.copyLocalBookToAccount(id: "b", kind: .shared)
            XCTFail("Unconfigured service must not copy")
        } catch {
            XCTAssertEqual(error as? RecipeBookUIError, .serviceNotConfigured)
        }
    }

    // MARK: Permissions

    func testMemberCanEditOnlyOwnRecipes() {
        let p = BookPermissions(book: book(myRole: .member, members: [BookMember(id: "me", displayName: "Me", role: .member), ana]))
        let mine = RecipeSummary(id: "1", bookID: "b", title: "Soup", authorID: "me", authorName: "Me")
        let theirs = RecipeSummary(id: "2", bookID: "b", title: "Cake", authorID: "ana", authorName: "Ana")
        XCTAssertTrue(p.canEdit(mine))
        XCTAssertFalse(p.canEdit(theirs))
        XCTAssertFalse(p.canDelete(theirs))
        XCTAssertFalse(p.canManageMembers)
        XCTAssertTrue(p.canAddRecipes)
    }

    func testOwnerManagesAllRecipesAndMembers() {
        let p = BookPermissions(book: book(members: [me, ana]))
        let theirs = RecipeSummary(id: "2", bookID: "b", title: "Cake", authorID: "ana", authorName: "Ana")
        XCTAssertTrue(p.canEdit(theirs))
        XCTAssertTrue(p.canManageMembers)
        XCTAssertTrue(p.canChangeRole(of: ana))
        XCTAssertTrue(p.canRemove(ana))
    }

    func testLastOwnerCannotBeDemotedOrRemoved() {
        let p = BookPermissions(book: book(members: [me, ana]))
        XCTAssertFalse(p.canChangeRole(of: me))
        XCTAssertFalse(p.canRemove(me))
    }

    func testMultipleOwnersAllowDemotion() {
        var anaOwner = ana; anaOwner.role = .owner
        let p = BookPermissions(book: book(members: [me, anaOwner]))
        XCTAssertTrue(p.canChangeRole(of: anaOwner))
        XCTAssertTrue(p.canChangeRole(of: me))
        XCTAssertEqual(p.leaveRequirement, .canLeave)
    }

    func testLastOwnerMustTransferOrDelete() {
        let p = BookPermissions(book: book(members: [me, ana]))
        XCTAssertEqual(p.leaveRequirement, .lastOwnerMustTransferOrDelete(candidates: [ana]))
    }

    func testSoleMemberAndPersonalBooks() {
        XCTAssertEqual(BookPermissions(book: book(members: [me])).leaveRequirement, .soleMemberMustDelete)
        XCTAssertEqual(BookPermissions(book: book(kind: .personal, members: [me])).leaveRequirement, .personalBookDeleteOnly)
        XCTAssertFalse(BookPermissions(book: book(kind: .personal, members: [me])).canManageMembers)
    }

    func testRegularMemberCanLeave() {
        let p = BookPermissions(book: book(myRole: .member, members: [BookMember(id: "me", displayName: "Me", role: .member), BookMember(id: "o", displayName: "O", role: .owner)]))
        XCTAssertEqual(p.leaveRequirement, .canLeave)
    }

    // MARK: Quantities

    func testQuantityNormalization() {
        XCTAssertEqual(QuantityText.normalize(""), .success(nil))
        XCTAssertEqual(QuantityText.normalize("  "), .success(nil))
        XCTAssertEqual(QuantityText.normalize("250"), .success("250"))
        XCTAssertEqual(QuantityText.normalize("1,5"), .success("1.5"))
        XCTAssertEqual(QuantityText.normalize("1/2"), .success("0.5"))
        XCTAssertEqual(QuantityText.normalize("1 1/2"), .success("1.5"))
        XCTAssertEqual(QuantityText.normalize("1/3"), .success("0.333"))
        XCTAssertEqual(QuantityText.normalize("abc"), .failure(.notANumber))
        XCTAssertEqual(QuantityText.normalize("1.2.3"), .failure(.notANumber))
        XCTAssertEqual(QuantityText.normalize("0"), .failure(.notPositive))
        XCTAssertEqual(QuantityText.normalize("1/0"), .failure(.notANumber))
    }

    func testQuantityDisplayNeverInventsAmount() {
        XCTAssertEqual(QuantityText.display(quantity: "250", unit: "g"), "250 g")
        XCTAssertEqual(QuantityText.display(quantity: "2", unit: nil), "2")
        XCTAssertNil(QuantityText.display(quantity: nil, unit: "g"))
        XCTAssertNil(QuantityText.display(quantity: " ", unit: nil))
    }

    // MARK: Draft validation

    func testDraftIssues() {
        var draft = RecipeDraft()
        XCTAssertEqual(RecipeDraftRules.issues(for: draft), [.missingTitle, .missingDestinationBook, .noSteps])

        draft.title = " Pasta "
        draft.bookID = "b"
        draft.steps = [RecipeStep(text: "  "), RecipeStep(text: "Boil water")]
        draft.ingredients = [
            IngredientLine(name: "Pasta", quantity: "400", unit: "g"),
            IngredientLine(name: "", quantity: "x"),
            IngredientLine(name: "Salt", amountNeedsReview: true),
            IngredientLine(name: "  "),
        ]
        XCTAssertEqual(RecipeDraftRules.issues(for: draft), [
            .ingredientMissingName(index: 1), .invalidQuantity(index: 1), .amountsAwaitingReview(count: 1),
        ])

        let normalized = RecipeDraftRules.normalized(draft)
        XCTAssertEqual(normalized.title, "Pasta")
        XCTAssertEqual(normalized.steps.map(\.text), ["Boil water"])
        XCTAssertEqual(normalized.ingredients.count, 3)
        XCTAssertNil(normalized.ingredients[2].quantity, "uncertain amounts must stay unknown")
    }

    // MARK: Reel links

    func testReelLinkExtraction() {
        XCTAssertEqual(ReelLink.extract(from: "Look https://www.instagram.com/reel/AbC_12-x/?igsh=xyz yum")?.absoluteString,
                       "https://www.instagram.com/reel/AbC_12-x/")
        XCTAssertEqual(ReelLink.extract(from: "instagram.com/reels/Q1w2")?.absoluteString,
                       "https://www.instagram.com/reel/Q1w2/")
        XCTAssertNil(ReelLink.extract(from: "https://www.instagram.com/p/AbC/"))
        XCTAssertNil(ReelLink.extract(from: "https://evil.example/reel/AbC/"))
        XCTAssertNil(ReelLink.extract(from: "https://instagram.com.evil.example/reel/AbC/"))
        XCTAssertNil(ReelLink.extract(from: "not a link"))
    }

    // MARK: Have / need

    func testHaveNeedSelection() {
        let items = [IngredientLine(id: "a", name: "Flour"), IngredientLine(id: "b", name: "Eggs")]
        var selection = IngredientSelection()
        XCTAssertEqual(selection.needed(from: items).map(\.id), ["a", "b"])
        selection.toggleHave("a")
        XCTAssertEqual(selection.needed(from: items).map(\.id), ["b"])
        selection.toggleHave("a")
        XCTAssertFalse(selection.has("a"))
    }

    func testShoppingOrderingAndStatus() {
        let items = [ShoppingItem(id: "1", name: "A", isBought: true), ShoppingItem(id: "2", name: "B"),
                     ShoppingItem(id: "3", name: "C")]
        XCTAssertEqual(ShoppingListRules.ordered(items).map(\.id), ["2", "3", "1"])
        XCTAssertTrue(ImportStatus.queued.isInFlight)
        XCTAssertFalse(ImportStatus.reviewRequired.isInFlight)
    }

    func testAccountIDInput() {
        XCTAssertEqual(AccountIDInput.normalize(" 3F2504E0-4F89-11D3-9A0C-0305E82C3301 "), "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        XCTAssertNil(AccountIDInput.normalize("ana@example.com"))
        XCTAssertNil(AccountIDInput.normalize(""))
    }

    // MARK: Weekly plan

    func testWeekStartIsMondayAndDaysAreOrdered() {
        let utc = TimeZone(identifier: "UTC")!
        let sunday = PlanCalendar.date(from: "2025-06-15")!
        XCTAssertEqual(PlanCalendar.weekStart(containing: sunday, in: utc), "2025-06-09")
        let monday = PlanCalendar.date(from: "2025-06-09")!
        XCTAssertEqual(PlanCalendar.weekStart(containing: monday, in: utc), "2025-06-09")
        XCTAssertEqual(PlanCalendar.days(of: "2025-06-09"),
                       ["2025-06-09", "2025-06-10", "2025-06-11", "2025-06-12", "2025-06-13", "2025-06-14", "2025-06-15"])
        XCTAssertEqual(PlanCalendar.days(of: "not-a-date"), [])
        XCTAssertEqual(PlanCalendar.shift("2025-06-09", weeks: 1), "2025-06-16")
        XCTAssertEqual(PlanCalendar.shift("2025-01-06", weeks: -1), "2024-12-30")
    }

    func testDayRulesExpandToSevenStyles() {
        XCTAssertEqual(PlanDayRule.wholeWeek(.simple).dayStyles, Array(repeating: .simple, count: 7))
        XCTAssertEqual(PlanDayRule.weekdaysAndWeekend(weekdays: .simple, weekend: .full).dayStyles,
                       [.simple, .simple, .simple, .simple, .simple, .full, .full])
        XCTAssertEqual(PlanDayRule.weekdaysAndWeekend(weekdays: nil, weekend: .complicated).plannedDayCount, 2)
        let specific = PlanDayRule.specificDays([.tuesday: .complicated, .sunday: .full])
        XCTAssertEqual(specific.dayStyles, [nil, .complicated, nil, nil, nil, nil, .full])
        XCTAssertEqual(specific.plannedDayCount, 2)
    }

    func testReplacementCandidatesPreferLabelledStyleAndExcludeCurrent() {
        func recipe(_ id: String, _ title: String, _ style: MealStyle?) -> RecipeSummary {
            RecipeSummary(id: id, bookID: "b", title: title, authorID: "me", authorName: "Me", mealStyle: style, version: 1)
        }
        let recipes = [recipe("1", "Zucchini", .simple), recipe("2", "apple tart", .full),
                       recipe("3", "Bean stew", .simple), recipe("4", "Curry", nil)]
        let day = PlanDay(date: "2025-06-09", mealStyle: .simple,
                          slot: PlanSlot(id: "s", recipeID: "3", recipeVersion: 1, servings: nil, recipe: nil))
        XCTAssertEqual(PlanRules.replacementCandidates(recipes, for: day).map(\.id), ["1", "2", "4"])
        let unstyled = PlanDay(date: "2025-06-09", mealStyle: nil, slot: nil)
        XCTAssertEqual(PlanRules.replacementCandidates(recipes, for: unstyled).map(\.id), ["2", "3", "4", "1"])
        let counts = PlanRules.styleCounts(recipes)
        XCTAssertEqual(counts.counts[.simple], 2)
        XCTAssertEqual(counts.unlabelled, 1)
    }

    func testUnknownServingsAreNeverInvented() {
        XCTAssertEqual(PlanRules.servingsText(nil), "Usual servings")
        XCTAssertEqual(PlanRules.servingsText(1), "1 serving")
        XCTAssertEqual(PlanRules.servingsText(4), "4 servings")
        XCTAssertNil(PlanReplacement(recipeID: "r", recipeVersion: 2, servings: nil).servings)
    }

    func testGeneratedShoppingItemsAreSeparatedFromManual() {
        let provenance = PlanProvenance(planID: "p", bookID: "b", weekStart: "2025-06-09", planVersion: 3,
                                        recipeTitles: ["Soup"])
        let items = [ShoppingItem(id: "m", name: "Milk"),
                     ShoppingItem(id: "g", name: "Leeks", origin: .generated(provenance)),
                     ShoppingItem(id: "g2", name: "Stock", isBought: true, origin: .generated(provenance))]
        XCTAssertEqual(ShoppingItem(id: "x", name: "X").origin, .manual)
        XCTAssertEqual(ShoppingListRules.generated(items).map(\.id), ["g", "g2"])
        XCTAssertEqual(ShoppingListRules.manual(items).map(\.id), ["m"])
        XCTAssertEqual(ShoppingListRules.generatedSourceText(provenance), "for Soup")
        let unknown = PlanProvenance(planID: "p", bookID: "b", weekStart: "2025-06-09", planVersion: 3, recipeTitles: [])
        XCTAssertEqual(ShoppingListRules.generatedSourceText(unknown), "From this meal plan")
    }

    func testStepOrderingMovesWithinBounds() {
        let steps = [RecipeStep(id: "a", text: "A"), RecipeStep(id: "b", text: "B"), RecipeStep(id: "c", text: "C")]
        XCTAssertEqual(StepOrdering.move(steps, id: "b", by: -1).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(StepOrdering.move(steps, id: "b", by: 1).map(\.id), ["a", "c", "b"])
        XCTAssertEqual(StepOrdering.move(steps, id: "a", by: -1).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(StepOrdering.move(steps, id: "missing", by: 1).map(\.id), ["a", "b", "c"])
    }

    func testWatchURLOnlyForInstagramReels() {
        XCTAssertEqual(ReelLink.watchURL(for: URL(string: "https://instagram.com/reel/AbC_1-2/?igsh=x"))?.absoluteString,
                       "https://www.instagram.com/reel/AbC_1-2/")
        XCTAssertNil(ReelLink.watchURL(for: URL(string: "https://example.com/reel/abc/")))
        XCTAssertNil(ReelLink.watchURL(for: URL(string: "https://www.instagram.com/p/abc/")))
        XCTAssertNil(ReelLink.watchURL(for: nil))
    }

    func testNewDraftFieldsDefaultToUnset() {
        let draft = RecipeDraft()
        XCTAssertNil(draft.mealStyle)
        XCTAssertNil(draft.coverImage)
        XCTAssertEqual(draft.coverImageEdit, .unchanged)
    }

    func testUnconfiguredPlannerNeverSucceeds() async {
        let service = UnconfiguredRecipeBookService()
        do {
            _ = try await service.readWeek(bookID: "b", weekStart: "2025-06-09")
            XCTFail("Unconfigured service must not read plans")
        } catch {
            XCTAssertEqual(error as? RecipeBookUIError, .serviceNotConfigured)
        }
        do {
            _ = try await service.generateWeek(bookID: "b", weekStart: "2025-06-09",
                                               dayStyles: PlanDayRule.wholeWeek(.simple).dayStyles,
                                               listID: "l", expectedVersion: nil)
            XCTFail("Unconfigured service must not generate plans")
        } catch {
            XCTAssertEqual(error as? RecipeBookUIError, .serviceNotConfigured)
        }
    }
}
