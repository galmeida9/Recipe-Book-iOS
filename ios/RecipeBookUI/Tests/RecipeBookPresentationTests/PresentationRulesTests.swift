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

    func testBookImportActivityCountsOnlyBoundUnfinishedJobs() {
        let url = URL(string: "https://www.instagram.com/reel/A/")!
        func job(_ id: String, _ status: ImportStatus, book: BookID?, unseen: Bool = false) -> ImportJob {
            ImportJob(id: id, sourceURL: url, status: status, createdAt: Date(), bookID: book, isUnseen: unseen)
        }
        let activity = BookImportActivity.byBook([
            job("1", .queued, book: "a"),
            job("2", .processing, book: "a"),
            job("3", .reviewRequired, book: "a", unseen: true),
            job("4", .reviewRequired, book: "a", unseen: false),
            job("5", .failed(reason: "x", canRetry: false), book: "b"),
            job("6", .completed(recipeID: "r", bookID: "c"), book: "c"),
            job("7", .processing, book: nil),
        ])
        XCTAssertEqual(activity["a"], BookImportActivity(inProgress: 2, newReady: 1, failed: 0))
        XCTAssertEqual(activity["b"], BookImportActivity(failed: 1))
        XCTAssertNil(activity["c"], "Completed jobs don't badge a book")
        XCTAssertEqual(activity.count, 2, "Unbound jobs aren't attributed to any book")
        XCTAssertEqual(activity["a"]?.accessibilityText, "2 recipes importing, 1 new recipe to review")
        XCTAssertNil(BookImportActivity().accessibilityText)
    }

    func testBookScopedImportDefaultsNeverSucceed() async {
        let service = UnconfiguredRecipeBookService()
        do {
            _ = try await service.submitImport(url: URL(string: "https://www.instagram.com/reel/A/")!, bookID: "b")
            XCTFail("Unconfigured service must not queue imports")
        } catch {
            XCTAssertEqual(error as? RecipeBookUIError, .serviceNotConfigured)
        }
        do {
            try await service.markImportSeen(id: "j")
            XCTFail("Unconfigured service must not acknowledge imports")
        } catch {
            XCTAssertEqual(error as? RecipeBookUIError, .serviceNotConfigured)
        }
        XCTAssertFalse(ImportJob(id: "j", sourceURL: URL(string: "https://www.instagram.com/reel/A/")!,
                                 status: .reviewRequired, createdAt: Date()).isUnseen)
    }

    func testPendingCardsShowOnlyThisBooksUnfinishedJobs() {
        let url = URL(string: "https://www.instagram.com/reel/A/")!
        let old = ImportJob(id: "old", sourceURL: url, status: .reviewRequired,
                            createdAt: Date(timeIntervalSince1970: 0), isUnseen: true)
        let mine = ImportJob(id: "mine", sourceURL: url, status: .processing,
                             createdAt: Date(timeIntervalSince1970: 20), bookID: "a")
        let earlier = ImportJob(id: "earlier", sourceURL: url, status: .failed(reason: "x", canRetry: true),
                                createdAt: Date(timeIntervalSince1970: 10), bookID: "a")
        let done = ImportJob(id: "done", sourceURL: url, status: .completed(recipeID: "r", bookID: "a"),
                             createdAt: Date(), bookID: "a")
        let other = ImportJob(id: "other", sourceURL: url, status: .queued, createdAt: Date(), bookID: "b")
        let jobs = [old, mine, earlier, done, other]

        XCTAssertEqual(BookImportActivity.pendingCards(for: "a", in: jobs).map(\.id), ["earlier", "mine"])
        XCTAssertEqual(BookImportActivity.pendingCards(for: "b", in: jobs).map(\.id), ["other"])
        // An unbound job (e.g. an old test import) shows in no book and badges none.
        XCTAssertFalse(BookImportActivity.byBook(jobs).values.contains { $0.newReady > 0 })
    }

    func testAcknowledgedJobShowsInItsBookBeforeTheNextRefresh() {
        let url = URL(string: "https://www.instagram.com/reel/A/")!
        let queued = ImportJob(id: "new", sourceURL: url, status: .queued, createdAt: Date(), bookID: "a")
        let shown = BookImportActivity.upserting(queued, into: [])
        XCTAssertEqual(BookImportActivity.pendingCards(for: "a", in: shown).map(\.id), ["new"])
        XCTAssertEqual(BookImportActivity.byBook(shown)["a"]?.inProgress, 1)

        var processing = queued
        processing.status = .processing
        processing.stageDetail = "Transcribing audio"
        let updated = BookImportActivity.upserting(processing, into: shown)
        XCTAssertEqual(updated.count, 1, "Same job id replaces, never duplicates")
        XCTAssertEqual(updated.first?.stageDetail, "Transcribing audio")
    }

    // MARK: Book import sections

    func testSeenUnsavedDraftsMoveFromImportingToRecipesAsNeedsReview() {
        let url = URL(string: "https://www.instagram.com/reel/A/")!
        func job(_ id: String, _ status: ImportStatus, unseen: Bool = false) -> ImportJob {
            ImportJob(id: id, sourceURL: url, status: status, createdAt: Date(), bookID: "a", isUnseen: unseen)
        }
        let sections = BookImportSections(cards: [
            job("queued", .queued),
            job("failed", .failed(reason: "Reel removed", canRetry: false)),
            job("new", .reviewRequired, unseen: true),
            job("opened", .reviewRequired, unseen: false),
        ])
        XCTAssertEqual(sections.importing.map(\.id), ["queued", "failed", "new"])
        XCTAssertEqual(sections.needsReview.map(\.id), ["opened"], "Opened but unsaved drafts stay in the book")
        XCTAssertNil(job("x", .failed(reason: "r", canRetry: false)).retryReason)
    }

    func testFirstOpenAcknowledgesAlongsideLoadingAndReopenOnlyLoads() async throws {
        actor Calls { var log: [String] = []; func add(_ s: String) { log.append(s) } }
        let url = URL(string: "https://www.instagram.com/reel/A/")!
        var job = ImportJob(id: "j", sourceURL: url, status: .reviewRequired, createdAt: Date(), bookID: "a", isUnseen: true)
        let calls = Calls()
        let draft = RecipeDraft(bookID: "a", title: "Soup")

        let ack = ImportReviewOpening.acknowledge(job, markSeen: { await calls.add("seen \($0)") })
        XCTAssertNotNil(ack)
        await ack?.value
        let ackLog = await calls.log
        XCTAssertEqual(ackLog, ["seen j"])

        // A slow acknowledgement never holds up the review.
        let started = Date()
        let first = try await ImportReviewOpening.load(job, markSeen: { _ in try await Task.sleep(for: .seconds(30)) },
                                                       review: { _ in draft })
        XCTAssertEqual(first, draft)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        // Cancelled review: the draft is now seen, sits in Recipes as Needs Review, and reopens
        // without another acknowledgement.
        job.isUnseen = false
        XCTAssertEqual(BookImportSections(cards: [job]).needsReview.map(\.id), ["j"])
        XCTAssertNil(ImportReviewOpening.acknowledge(job, markSeen: { await calls.add("seen \($0)") }))
        let reopened = try await ImportReviewOpening.load(job, markSeen: { await calls.add("seen \($0)") },
                                                          review: { _ in draft })
        XCTAssertEqual(reopened, draft)
        let reopenLog = await calls.log
        XCTAssertEqual(reopenLog, ["seen j"])

        // A failed acknowledgement doesn't block reviewing.
        job.isUnseen = true
        let loaded = try await ImportReviewOpening.load(job, markSeen: { _ in throw RecipeBookUIError.serviceNotConfigured },
                                                        review: { _ in draft })
        XCTAssertEqual(loaded, draft)
    }

    // MARK: Measurements

    func testAutomaticUnitsFollowRegionAndNorwayIsMetric() {
        XCTAssertEqual(UnitSystem.automatic.resolved(for: Locale(identifier: "nb_NO")), .metric)
        XCTAssertEqual(UnitSystem.automatic.resolved(for: Locale(identifier: "en_GB")), .metric)
        XCTAssertEqual(UnitSystem.automatic.resolved(for: Locale(identifier: "en_US")), .imperial)
        XCTAssertEqual(UnitSystem.imperial.resolved(for: Locale(identifier: "nb_NO")), .imperial)
        XCTAssertEqual(UnitSystem.metric.resolved(for: Locale(identifier: "en_US")), .metric)
    }

    func testWeightsConvertOnlyAcrossSystemsAndAreMarked() {
        func show(_ q: String?, _ u: String?, _ s: UnitSystem) -> String? {
            MeasurementDisplay.display(quantity: q, unit: u, system: s, locale: Locale(identifier: "nb_NO"))
        }
        XCTAssertEqual(show("8", "oz", .metric), "≈ 227 g")
        XCTAssertEqual(show("3", "lb", .metric), "≈ 1,36 kg", "Converted values use the viewer's decimal comma")
        XCTAssertEqual(show("2", "pounds", .automatic), "≈ 907 g")
        XCTAssertEqual(show("250", "g", .imperial), "≈ 8,8 oz")
        XCTAssertEqual(show("1", "kg", .imperial), "≈ 2,2 lb")
        XCTAssertEqual(MeasurementDisplay.display(quantity: "3", unit: "lb", system: .metric,
                                                  locale: Locale(identifier: "en_US")), "≈ 1.36 kg")
        // Same system: shown exactly as written, never rescaled or reformatted.
        XCTAssertEqual(show("1500", "g", .metric), "1500 g")
        XCTAssertEqual(show("1.5", "kg", .metric), "1.5 kg")
        XCTAssertEqual(show("1 1/2", "lb", .imperial), "1 1/2 lb")
    }

    func testOnlyStandardNamedVolumesConvertAndImperialUsesUSMeasures() {
        func show(_ q: String?, _ u: String?, _ s: UnitSystem) -> String? {
            MeasurementDisplay.display(quantity: q, unit: u, system: s, locale: Locale(identifier: "en_US"))
        }
        XCTAssertEqual(show("200", "ml", .imperial), "≈ 6.8 US fl oz")
        XCTAssertEqual(show("5", "dl", .imperial), "≈ 2.11 US cups")
        XCTAssertEqual(show("236.6", "ml", .imperial), "≈ 1 US cup")
        XCTAssertEqual(show("2", "US cups", .metric), "≈ 473 ml")
        XCTAssertEqual(show("1", "UK pint", .metric), "≈ 568 ml")
        XCTAssertEqual(show("4", "US fl oz", .metric), "≈ 118 ml")
        XCTAssertEqual(show("1", "UK fl oz", .metric), "≈ 28 ml", "UK and US fluid ounces differ")
        XCTAssertEqual(show("1", "UK pint", .imperial), "1 UK pint", "Shown as written in its own system")
    }

    func testAmbiguousCountAndUnknownUnitsAreNeverConverted() {
        func show(_ q: String?, _ u: String?, _ s: UnitSystem) -> String? {
            MeasurementDisplay.display(quantity: q, unit: u, system: s, locale: Locale(identifier: "en_US"))
        }
        XCTAssertEqual(show("1", "cup", .metric), "1 cup", "No US/UK cup assumption and no density guess")
        XCTAssertEqual(show("4", "fl oz", .metric), "4 fl oz")
        XCTAssertEqual(show("1", "pint", .metric), "1 pint")
        XCTAssertEqual(show("2", "tbsp", .metric), "2 tbsp")
        XCTAssertEqual(show("3", "cloves", .metric), "3 cloves")
        XCTAssertEqual(show("1", "knob", .metric), "1 knob")
        XCTAssertEqual(show("a few", "oz", .metric), "a few oz", "Unparseable amounts are shown as written")
        XCTAssertNil(show(nil, "g", .metric), "Unknown amounts are never invented")
    }

    func testStepTemperaturesShowBothScalesAndLeaveOtherNumbersAlone() {
        let metric = UnitSystem.metric, imperial = UnitSystem.imperial
        XCTAssertEqual(MeasurementDisplay.stepText("Bake at 350°F for 20 minutes.", system: metric),
                       "Bake at 350°F (≈ 177 °C) for 20 minutes.")
        XCTAssertEqual(MeasurementDisplay.stepText("Heat the oven to 200 °C, then 180°C.", system: imperial),
                       "Heat the oven to 200 °C (≈ 392 °F), then 180°C (≈ 356 °F).")
        XCTAssertEqual(MeasurementDisplay.stepText("Bake at 200 °C.", system: metric), "Bake at 200 °C.")
        XCTAssertEqual(MeasurementDisplay.stepText("Bake at 200 degrees for 3 min, step 2.", system: imperial),
                       "Bake at 200 degrees for 3 min, step 2.", "No degree sign, no guess")
        XCTAssertEqual(MeasurementDisplay.stepText("See https://x.example/a350F", system: metric),
                       "See https://x.example/a350F")
    }

    func testUnitPickerOffersKnownUnitsAndKeepsAnyOtherSourceUnit() {
        let none = MeasurementDisplay.pickerOptions(current: nil)
        XCTAssertNil(none.retainedSourceUnit)
        XCTAssertEqual(none.groups.map(\.kind), [.weight, .volume, .count])
        XCTAssertEqual(none.groups[0].units.map(\.symbol), ["g", "kg", "oz", "lb"], "Imperial weights can be picked")
        XCTAssertTrue(none.groups[1].units.map(\.symbol).contains("tbsp"))
        XCTAssertTrue(none.groups[1].units.map(\.symbol).contains("US cup"))
        XCTAssertFalse(none.groups[1].units.map(\.symbol).contains("cup"), "No unlabelled cup")
        XCTAssertTrue(none.groups[2].units.map(\.symbol).contains("clove"))

        XCTAssertNil(MeasurementDisplay.pickerOptions(current: "g").retainedSourceUnit)
        XCTAssertNil(MeasurementDisplay.pickerOptions(current: "oz").retainedSourceUnit)
        XCTAssertEqual(MeasurementDisplay.pickerOptions(current: "grams").retainedSourceUnit, "grams",
                       "Aliases aren't silently rewritten to a symbol")
        XCTAssertEqual(MeasurementDisplay.pickerOptions(current: "cup").retainedSourceUnit, "cup")
        XCTAssertNil(MeasurementDisplay.pickerOptions(current: "  ").retainedSourceUnit)
    }

    func testDraftNormalizationKeepsHiddenPreparationAndSourceUnits() {
        var draft = RecipeDraft(bookID: "b")
        draft.title = "Soup"
        draft.ingredients = [
            IngredientLine(id: "i", name: "Onion", quantity: "1", unit: "pc", preparation: "finely chopped"),
            IngredientLine(id: "j", name: "Butter", quantity: "8", unit: "oz"),
        ]
        let saved = RecipeDraftRules.normalized(draft).ingredients
        XCTAssertEqual(saved.first?.preparation, "finely chopped")
        XCTAssertEqual(saved.last?.quantity, "8", "Viewer units never rewrite saved amounts")
        XCTAssertEqual(saved.last?.unit, "oz")
    }
}
