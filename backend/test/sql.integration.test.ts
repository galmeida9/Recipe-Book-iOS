import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID, createHash } from "node:crypto";
import { query, serializable, database } from "../src/database.js";
import { RecipeBookService, pendingAccountLimit } from "../src/service.js";
import { googleIssuer } from "../src/auth.js";
import { SQLFlowStore } from "../src/oauth.js";
import { AppError } from "../src/contracts.js";
import { ImportService, processImport, importDelivery, failImportDelivery } from "../src/imports.js";
import { type ProviderBudget, type ProviderRun } from "../src/apify.js";
import { ImportPipelineProvider, type Pipeline } from "../src/import-pipeline.js";
import { validateExtraction } from "../src/recipe-extraction.js";
import { readRecipeImage } from "../src/images.js";
import { GeminiExtractor } from "../src/gemini.js";

const enabled = process.env["RUN_SQL_INTEGRATION"] === "true";
async function verifyOAuthCodeBindings() {
  const store = new SQLFlowStore();
  const state = randomUUID();
  const second = randomUUID();
  const challenge = createHash("sha256").update("synthetic-verifier").digest("base64url");
  const code = randomUUID();
  try {
    await store.create(state, "synthetic-nonce", challenge);
    await store.bind(state, code);
    await assert.rejects(() => store.bind(state, code));
    await assert.rejects(() => store.consume(code, "wrong-challenge"));
    const outcomes = await Promise.allSettled([store.consume(code, challenge), store.consume(code, challenge)]);
    assert.equal(outcomes.filter(value => value.status === "fulfilled").length, 1, "Authorization code is consumed exactly once.");
    const success = outcomes.find(value => value.status === "fulfilled");
    assert.ok(success?.status === "fulfilled" && success.value === "synthetic-nonce");
    await store.create(second, "synthetic-nonce", challenge);
    await store.bind(second, code);
    await serializable(transaction => query(transaction, "UPDATE dbo.OAuthFlows SET ExpiresAt=DATEADD(SECOND,-1,SYSUTCDATETIME()) WHERE StateHash=@state",
      { state: createHash("sha256").update(second).digest("hex") }));
    await assert.rejects(() => store.consume(code, challenge));
  } finally {
    await serializable(async transaction => {
      for (const value of [state, second]) await query(transaction, "DELETE dbo.OAuthFlows WHERE StateHash=@state",
        { state: createHash("sha256").update(value).digest("hex") });
    });
  }
}
async function verifyGoogleAccountLifecycle() {
  const subject = () => BigInt("0x" + randomUUID().replaceAll("-", "")).toString();
  const subjects = [subject(), subject(), subject(), subject()];
  const services = subjects.map(value => new RecipeBookService({ issuer: googleIssuer, subject: value }));
  const [pending, firstInvited, racerA, racerB] = services as [RecipeBookService, RecipeBookService, RecipeBookService, RecipeBookService];
  const capacityIssuer = "https://capacity-fixture.invalid/" + randomUUID();
  try {
    const initial = await pending.me();
    assert.equal(initial.access, "awaitingInvite");
    assert.equal((await pending.me()).id, initial.id, "Repeated first Google login links the same pending app identity.");
    await assert.rejects(() => pending.books(), (error: unknown) => error instanceof AppError && error.code === "invite_required");
    await serializable(transaction => query(transaction,
      "INSERT dbo.AccessInvites(Issuer,Subject,ExpiresAt) VALUES(@issuer,@subject,@expires)",
      { issuer: googleIssuer, subject: subjects[0]!, expires: new Date(Date.now() + 3_600_000) }));
    assert.equal((await pending.me()).id, initial.id);
    assert.equal((await pending.me()).access, "active");
    await pending.createBook({ name: "Synthetic Google private book", kind: "personal" });
    await serializable(transaction => query(transaction,
      "UPDATE dbo.AccessInvites SET Revoked=1 WHERE Issuer=@issuer AND Subject=@subject",
      { issuer: googleIssuer, subject: subjects[0]! }));
    assert.equal((await pending.me()).access, "awaitingInvite");
    await assert.rejects(() => pending.books(), (error: unknown) => error instanceof AppError && error.code === "invite_required");
    await serializable(transaction => query(transaction,
      "UPDATE dbo.AccessInvites SET Revoked=0 WHERE Issuer=@issuer AND Subject=@subject",
      { issuer: googleIssuer, subject: subjects[0]! }));
    await pending.deleteAccount();
    await assert.rejects(() => pending.me(), (error: unknown) => error instanceof AppError && error.code === "account_deleted");
    await serializable(async transaction => {
      const count = await query<{ count: number }>(transaction, "SELECT COUNT(*) AS count FROM dbo.Accounts WHERE Active=0 AND Deleted=0");
      const fill = pendingAccountLimit - count[0]!.count - 1;
      assert.ok(fill >= 0, "Owned test database lacks space for the pending-capacity test.");
      for (let index = 0; index < fill; index++) {
        await query(transaction, "INSERT dbo.Accounts(Id,Issuer,Subject,Active) VALUES(@id,@issuer,@subject,0)",
          { id: randomUUID(), issuer: capacityIssuer, subject: String(index) });
      }
    });
    const outcomes = await Promise.allSettled([racerA.me(), racerB.me()]);
    assert.equal(outcomes.filter(value => value.status === "fulfilled").length, 1);
    const rejected = outcomes.find(value => value.status === "rejected");
    assert.ok(rejected?.status === "rejected" && rejected.reason instanceof AppError && rejected.reason.code === "onboarding_capacity");
    await serializable(transaction => query(transaction,
      "INSERT dbo.AccessInvites(Issuer,Subject,ExpiresAt) VALUES(@issuer,@subject,@expires)",
      { issuer: googleIssuer, subject: subjects[1]!, expires: new Date(Date.now() + 3_600_000) }));
    assert.equal((await firstInvited.me()).access, "active", "An invited first Google login must work even at pending capacity.");
  } finally {
    await serializable(async transaction => {
      await query(transaction, "DELETE dbo.Accounts WHERE Issuer=@issuer", { issuer: capacityIssuer });
      for (const value of subjects) {
        await query(transaction, "DELETE dbo.Books WHERE Id IN(SELECT m.BookId FROM dbo.Memberships m JOIN dbo.Accounts a ON a.Id=m.UserId WHERE a.Issuer=@issuer AND a.Subject=@subject)",
          { issuer: googleIssuer, subject: value });
        await query(transaction, "DELETE dbo.Accounts WHERE Issuer=@issuer AND Subject=@subject", { issuer: googleIssuer, subject: value });
        await query(transaction, "DELETE dbo.AccessInvites WHERE Issuer=@issuer AND Subject=@subject", { issuer: googleIssuer, subject: value });
      }
    });
  }
}
test("SQL: member isolation, optimistic writes, last-owner race and account departure are transactional", { skip: !enabled }, async () => {
  const issuer = "https://test.invalid/" + randomUUID();
  const names = ["alice", "bob", "outsider"];
  const principals = names.map(subject => ({ issuer, subject }));
  const services = principals.map(principal => new RecipeBookService(principal));
  const [alice, bob, outsider] = services as [RecipeBookService, RecipeBookService, RecipeBookService];
  let aliceId = "";
  let bobId = "";
  let sharedId = "";
  const budgetMonth = "t" + randomUUID().slice(0, 6);
  const retryBudgetMonth = "r" + randomUUID().slice(0, 6);
  const ambiguousBudgetMonth = "a" + randomUUID().slice(0, 6);
  const revokedBudgetMonth = "v" + randomUUID().slice(0, 6);
  const recoveryBudgetMonth = "m" + randomUUID().slice(0, 6);
  let activeBudgetMonth = budgetMonth;
  let starts = 0;
  let succeeded = false;
  let lostResponse = false;
  let modelFails = false;
  class FixtureProvider extends ImportPipelineProvider {
    override async budget(): Promise<ProviderBudget> {
      return { month: activeBudgetMonth, spentMicros: 0, capMicros: 250_000, reserveMicros: 100_000, endsAt: new Date(Date.now() + 3_600_000) };
    }
    override async startStage(_sourceURL: string, pipeline: Pipeline): Promise<ProviderRun> {
      starts++;
      if (lostResponse) throw new Error("Synthetic charged POST response was lost");
      await new Promise(resolve => setTimeout(resolve, 50));
      return { id: "fixture-" + pipeline.stage, status: "RUNNING", defaultDatasetId: "fixture-dataset", options: { maxTotalChargeUsd: 0.04, isMaxTotalChargeUsdSetByUser: true } };
    }
    override async run(id: string): Promise<ProviderRun> {
      return { id, status: succeeded ? "SUCCEEDED" : "RUNNING", defaultDatasetId: "fixture-dataset", options: { maxTotalChargeUsd: 0.04, isMaxTotalChargeUsdSetByUser: true } };
    }
    override async completeStage(_run: ProviderRun, sourceURL: string, pipeline: Pipeline) {
      if (modelFails && pipeline.stage === "model") throw new AppError(502, "provider_model_unavailable", "Synthetic definitive model gateway denial");
      const evidence = { caption: "100 g carrots; Simmer carrots.", comments: [], transcript: "Simmer carrots." };
      const next = pipeline.stage === "metadata" ? { ...pipeline, stage: "audio" as const, evidence }
        : pipeline.stage === "audio" ? { ...pipeline, stage: "model" as const, evidence } : null;
      const review = next ? null : validateExtraction({
        title: "Carrots", source_url: sourceURL, servings: null, total_minutes: null, requires_review: true, warnings: [],
        ingredients: [{ name: "carrots", quantity: 100, unit: "g", notes: null, evidence_ids: ["C0"] }],
        steps: [{ instruction: "Simmer carrots.", duration_minutes_min: null, duration_minutes_max: null, temperature_c: null, evidence_ids: ["C0"] }]
      }, sourceURL, [{ id: "C0", kind: "caption", text: evidence.caption }]);
      return { next, evidence, review };
    }
  }
  const provider = new FixtureProvider();
  try {
    await verifyOAuthCodeBindings();
    await verifyGoogleAccountLifecycle();
    await serializable(async transaction => {
      for (const principal of principals) {
        await query(transaction, "INSERT dbo.AccessInvites(Issuer,Subject,ExpiresAt) VALUES(@issuer,@subject,@expires)",
          { ...principal, expires: new Date(Date.now() + 3_600_000) });
      }
    });
    aliceId = (await alice.me()).id;
    bobId = (await bob.me()).id;
    await outsider.me();
    const copyKey = randomUUID();
    const localPayload = { name: "Synthetic local copy", kind: "personal", recipes: [{
      title: "Copied source", ingredients: [], steps: ["Keep source order."], mealStyle: "simple",
      sourceURL: "https://www.instagram.com/reel/CopiedSource/"
    }] };
    const copies = await Promise.all([alice.copyLocalBook(localPayload, copyKey, aliceId), alice.copyLocalBook(localPayload, copyKey, aliceId)]);
    assert.equal(copies[0]!.id, copies[1]!.id, "Concurrent immutable-snapshot copy creates exactly one account book.");
    const copiedRecipe = (await alice.recipes(copies[0]!.id))[0]!;
    assert.equal(copiedRecipe.draft.mealStyle, "simple");
    assert.equal(copiedRecipe.draft.sourceURL, localPayload.recipes[0]!.sourceURL);
    await assert.rejects(() => alice.copyLocalBook({ ...localPayload, name: "Changed snapshot" }, copyKey, aliceId),
      (error: unknown) => error instanceof AppError && error.code === "idempotency_conflict");
    await assert.rejects(() => alice.copyLocalBook(localPayload, randomUUID(), bobId),
      (error: unknown) => error instanceof AppError && error.code === "account_changed");
    const coverId = randomUUID();
    await serializable(transaction => query(transaction, `INSERT dbo.RecipeImages(Id,RecipeId,OwnerId,BlobName,ContentType,SizeBytes)
      VALUES(@id,NULL,@userId,@blobName,'image/jpeg',1)`, { id: coverId, userId: aliceId, blobName: "synthetic-copy-" + coverId }));
    const photoPayload = { ...localPayload, recipes: [{ ...localPayload.recipes[0]!, coverImageID: coverId }] };
    await assert.rejects(() => bob.copyLocalBook(photoPayload, randomUUID(), bobId),
      (error: unknown) => error instanceof AppError && error.code === "image_owner");
    const photoCopyKey = randomUUID();
    const photoCopy = await alice.copyLocalBook(photoPayload, photoCopyKey, aliceId);
    assert.equal((await alice.recipes(photoCopy.id))[0]!.draft.coverImageID, coverId);
    assert.equal((await alice.copyLocalBook(photoPayload, photoCopyKey, aliceId)).id, photoCopy.id,
      "A photo-bearing copied snapshot retries without attaching a photo to a second recipe.");
    const sourceEdited = await alice.saveRecipe(photoCopy.id, { ...copiedRecipe.draft, sourceURL: null },
      (await alice.recipes(photoCopy.id))[0]!.id, 1);
    assert.equal(sourceEdited.draft.sourceURL, localPayload.recipes[0]!.sourceURL, "Recipe editing cannot silently discard original Instagram attribution.");
    const privateBook = await alice.createBook({ name: "Private", kind: "personal" });
    let shared = await alice.createBook({ name: "Shared", kind: "shared" });
    sharedId = shared.id;
    await assert.rejects(() => bob.recipes(privateBook.id), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    shared = await alice.addMember(shared.id, bobId, shared.version);
    async function verifyCachedModelRecovery() {
    activeBudgetMonth = recoveryBudgetMonth;
    const modelKey = randomUUID();
    const modelSource = await createImport("https://www.instagram.com/reel/CachedModelRecovery/", modelKey);
    for (let stage = 0; stage < 5; stage++) await processImport(modelSource.id, provider);
    modelFails = true;
    await assert.rejects(() => processImport(modelSource.id, provider), /definitive model gateway denial/);
    modelFails = false;
    const originalFailure = await imports.get(modelSource.id);
    assert.equal(originalFailure.state, "failed");
    const beforeRecoveryStarts = starts;
    Object.assign(process.env, {
      IMPORT_RUNTIME_PROBE_ENABLED: "true", MODEL_PROVIDER: "gemini-free",
      GEMINI_FREE_TIER_VERIFIED: "true", GEMINI_NO_BILLING_VERIFIED: "true", GEMINI_PUBLIC_EVIDENCE_ACKNOWLEDGED: "true",
      GEMINI_API_KEY: "synthetic-only"
    });
    class DirectFixture extends FixtureProvider {
      override async budget() { return { ...await super.budget(), reserveMicros: 70_000 }; }
      override async extractDirect(sourceURL: string, pipeline: Pipeline) {
        assert(pipeline.evidence?.transcript, "The resumed model receives the actual persisted transcript.");
        return new GeminiExtractor(async () => Response.json({
          modelVersion: "gemini-2.5-flash-lite", candidates: [{ finishReason: "STOP", content: { parts: [{ text: JSON.stringify({
            title: "Carrots", source_url: sourceURL, servings: null, total_minutes: null, requires_review: true, warnings: [],
            ingredients: [{ name: "carrots", quantity: 100, unit: "g", notes: null, evidence_ids: ["C0"] }],
            steps: [{ instruction: "Simmer carrots.", duration_minutes_min: null, duration_minutes_max: null, temperature_c: null, evidence_ids: ["C0"] }]
          }) }] } }]
        })).extract(sourceURL, pipeline.evidence!);
      }
    }
    const direct = new DirectFixture();
    const recovery = new ImportService(alice, direct, "operator-proof");
    const recoveryKey = randomUUID();
    const resumed = await recovery.resumeCachedModel(modelSource.id, recoveryKey);
    assert.notEqual(resumed.id, modelSource.id, "Recovery is a separate immutable journal, not a rewrite of the failed charge history.");
    await processImport(resumed.id, direct);
    const recovered = await recovery.get(resumed.id);
    assert.equal(recovered.state, "review");
    assert.equal(recovered.destinationBookId, shared.id);
    assert.equal(recovered.draft!.sourceURL, originalFailure.sourceURL);
    assert.equal((await recovery.resumeCachedModel(modelSource.id, recoveryKey)).id, resumed.id);
    const originalAudit = await serializable(transaction => query<{ state: string }>(transaction,
      "SELECT State AS state FROM dbo.ImportJobs WHERE Id=@id", { id: modelSource.id }));
    assert.equal(originalAudit[0]!.state, "failed");
    assert.equal((await imports.get(modelSource.id)).id, resumed.id, "An old visible job link resolves to its completed recovery.");
    assert.equal((await createImport(modelSource.sourceURL, modelKey)).id, resumed.id, "Sharing the same source/book again reuses recovery without another charge.");
    await assert.rejects(() => imports.discard(modelSource.id, originalFailure.version),
      (error: unknown) => error instanceof AppError && error.code === "import_recovered");
    assert.equal(starts, beforeRecoveryStarts, "Model-only recovery never starts another metadata/audio/relay run.");
    const listed = await imports.list(shared.id);
    assert(!listed.some(item => item.id === modelSource.id), "Superseded failures stay in the audit history, not the book's active cards.");
    assert(listed.some(item => item.id === resumed.id));
    const operatorOnly = await recovery.create({ sourceURL: "https://www.instagram.com/reel/HiddenOperatorFixture/", bookId: shared.id }, randomUUID());
    assert(!(await imports.list()).some(item => item.id === operatorOnly.id), "Operator fixtures never pollute a real account's Library.");
    await assert.rejects(() => imports.get(operatorOnly.id), (error: unknown) => error instanceof AppError && error.code === "import_not_found");
    assert.equal((await recovery.get(operatorOnly.id)).state, "queued", "Admin audit visibility is preserved.");
    const retainedOutput = {
      model: "gpt-4.1-mini-2025-04-14", requestId: "synthetic-retained-result", inputTokens: 100, outputTokens: 100,
      response: JSON.stringify({
        title: "Carrots", source_url: modelSource.sourceURL, servings: null, total_minutes: null, requires_review: true, warnings: [],
        ingredients: [{ name: "carrots", quantity: 100, unit: "g", notes: null, evidence_ids: ["C0"] }],
        steps: [{ instruction: "Simmer carrots.", duration_minutes_min: null, duration_minutes_max: null, temperature_c: null, evidence_ids: ["C0"] }]
      })
    };
    await serializable(transaction => query(transaction,
      "UPDATE dbo.ImportJobs SET State='failed',Error='Synthetic retained-validation failure',ModelResultJson=@model,Version=Version+1 WHERE Id=@id",
      { id: resumed.id, model: JSON.stringify(retainedOutput) }));
    const failedRetained = await imports.get(resumed.id);
    assert.equal(failedRetained.canRetry, true);
    const budgetBeforeRetry = await serializable(transaction => query(transaction,
      "SELECT SpentMicros,ReservedMicros FROM dbo.ImportBudget WHERE Month=@month", { month: recoveryBudgetMonth }));
    const localReview = await imports.retry(resumed.id, failedRetained.version);
    assert.equal(localReview.state, "review");
    assert.equal((await imports.retry(resumed.id, failedRetained.version)).state, "review", "A repeated local Retry acknowledgement is idempotent.");
    assert.equal(starts, beforeRecoveryStarts, "Local validation retry never charges another provider stage.");
    assert.deepEqual(await serializable(transaction => query(transaction,
      "SELECT SpentMicros,ReservedMicros FROM dbo.ImportBudget WHERE Month=@month", { month: recoveryBudgetMonth })), budgetBeforeRetry);
    }
    const recipe = await alice.saveRecipe(shared.id, { title: "Soup", ingredients: [], steps: [] });
    await assert.rejects(() => outsider.recipes(shared.id), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    await assert.rejects(() => bob.saveRecipe(shared.id, recipe.draft, recipe.id, recipe.version),
      (error: unknown) => error instanceof AppError && error.code === "recipe_author");
    const own = await bob.saveRecipe(shared.id, { title: "Bread", ingredients: [], steps: [] });
    await bob.saveRecipe(shared.id, { ...own.draft, title: "New bread" }, own.id, own.version);
    await assert.rejects(() => bob.deleteRecipe(shared.id, own.id, own.version),
      (error: unknown) => error instanceof AppError && error.code === "version_conflict");
    const list = await alice.createShoppingList({ name: "Private shopping" });
    await assert.rejects(() => bob.replaceShoppingItems(list.id, { items: [] }, list.version),
      (error: unknown) => error instanceof AppError && error.code === "list_not_found");
    await assert.rejects(() => alice.addRecipeToList(list.id, { recipeId: own.id, recipeVersion: own.version, alreadyHave: [] }, list.version),
      (error: unknown) => error instanceof AppError && error.code === "version_conflict");
    const measured = await alice.saveRecipe(shared.id, { title: "Measured", ingredients: [
      { name: "flour", quantity: "0.1", unit: "kg" }, { name: "flour", quantity: "0.2", unit: "g" }, { name: "salt", quantity: null, unit: null }
    ], steps: [] });
    const shopping = await alice.addRecipeToList(list.id, { recipeId: measured.id, recipeVersion: measured.version, alreadyHave: [2] }, list.version);
    assert.equal(shopping.items.length, 1);
    assert.equal(shopping.items[0]!.ingredient.quantity, "100.2");
    assert.equal(shopping.items[0]!.ingredient.unit, "g");
    await assert.rejects(() => alice.replaceShoppingItems(list.id, { items: [] }, list.version),
      (error: unknown) => error instanceof AppError && error.code === "version_conflict");

    const imageId = randomUUID();
    await serializable(async transaction => {
      await query(transaction, `INSERT dbo.RecipeImages(Id,RecipeId,BlobName,ContentType,SizeBytes)
        VALUES(@id,@recipeId,@blobName,'image/png',1)`, { id: imageId, recipeId: recipe.id, blobName: "synthetic-" + imageId });
    });
    await assert.rejects(() => readRecipeImage(outsider, imageId), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    await alice.changeMember(shared.id, bobId, null, shared.version);
    shared = (await alice.books()).find(book => book.id === shared.id)!;
    await assert.rejects(() => readRecipeImage(bob, imageId), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    shared = await alice.addMember(shared.id, bobId, shared.version);

    Object.assign(process.env, {
      APIFY_ENABLED: "true", APIFY_FREE_PLAN_VERIFIED: "true", APIFY_NO_OVERAGES_VERIFIED: "true",
      APIFY_CUSTOMER_IMPORTS_ENABLED: "true",
      APIFY_ACCOUNT_EXCLUSIVE: "true", APIFY_BACKEND_LEDGER_VERIFIED: "true", APIFY_PIPELINE_REVIEW_ACKNOWLEDGED: "true", APIFY_PIPELINE_PRICING_VERIFIED: "true",
      APIFY_METADATA_BUILD: "1.2.3", APIFY_AUDIO_BUILD: "1.2.3", APIFY_MODEL_BUILD: "1.2.3",
      APIFY_METADATA_CAP_MICROS: "30000", APIFY_AUDIO_CAP_MICROS: "40000", APIFY_MODEL_CAP_MICROS: "30000"
    });
    const imports = new ImportService(alice, provider);
    const outsiderImports = new ImportService(outsider, provider);
    const key = randomUUID();
    const createImport = (sourceURL: string, requestKey = randomUUID()) => imports.create({ sourceURL, bookId: shared.id }, requestKey);
    const importJob = await createImport("https://instagram.com/reel/Fixture1/?tracking=1", key);
    const duplicate = await createImport("https://www.instagram.com/reel/Fixture1/");
    assert.equal(importJob.id, duplicate.id);
    await assert.rejects(() => imports.create({ sourceURL: importJob.sourceURL, bookId: privateBook.id }, key),
      (error: unknown) => error instanceof AppError && error.code === "idempotency_conflict");
    await assert.rejects(() => outsiderImports.create({ sourceURL: importJob.sourceURL, bookId: shared.id }, randomUUID()),
      (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    await assert.rejects(() => imports.create({ sourceURL: importJob.sourceURL, bookId: shared.id }, randomUUID(), bobId),
      (error: unknown) => error instanceof AppError && error.code === "account_changed");
    await assert.rejects(() => createImport("https://www.instagram.com/reel/Different/", key),
      (error: unknown) => error instanceof AppError && error.code === "idempotency_conflict");
    await assert.rejects(() => outsiderImports.get(importJob.id), (error: unknown) => error instanceof AppError && error.code === "import_not_found");
    const secondJob = await createImport("https://www.instagram.com/reel/Fixture2/");
    await Promise.all([processImport(importJob.id, provider), processImport(importJob.id, provider)]);
    assert.equal(starts, 1, "Concurrent delivery must perform one charged dispatch.");
    assert.equal((await imports.get(importJob.id)).state, "running");
    succeeded = true;
    for (let stage = 0; stage < 5; stage++) await Promise.all([processImport(importJob.id, provider), processImport(importJob.id, provider)]);
    const review = await imports.get(importJob.id);
    assert.equal(review.state, "review");
    assert.equal(review.destinationBookId, shared.id);
    assert.equal(review.isUnseen, true);
    assert.equal((await imports.markSeen(review.id, review.version)).isUnseen, false);
    assert.equal((await imports.markSeen(review.id, review.version)).isUnseen, false, "Seen acknowledgement is persisted and idempotent.");
    await assert.rejects(() => imports.approve(importJob.id, privateBook.id, review.draft, review.version),
      (error: unknown) => error instanceof AppError && error.code === "destination_changed");
    assert.equal(review.draft!.ingredients[0]!.quantity, "100");
    const approved = await imports.approve(importJob.id, shared.id, review.draft, review.version);
    assert.equal((await imports.get(importJob.id)).recipeId, approved.id);
    assert.equal((await createImport("https://www.instagram.com/reel/Fixture1/", key)).state, "completed");
    assert.equal(starts, 3, "Concurrent stage transitions never duplicate a charged POST.");
    await assert.rejects(() => createImport("https://www.instagram.com/reel/Fixture3/"),
      (error: unknown) => error instanceof AppError && error.code === "budget_exhausted");
    await serializable(async transaction => {
      await query(transaction, "UPDATE dbo.ImportJobs SET Deadline=@deadline WHERE Id=@id",
        { id: secondJob.id, deadline: new Date(Date.now() - 1000) });
    });
    const expiredDelivery = (await importDelivery(secondJob.id))!;
    await processImport(secondJob.id, provider, expiredDelivery.deadline);
    const failed = await imports.get(secondJob.id);
    assert.equal(failed.state, "failed");
    assert.equal(starts, 3);
    await assert.rejects(() => imports.retry(secondJob.id, failed.version),
      (error: unknown) => error instanceof AppError && error.code === "budget_exhausted");
    const budget = await serializable(transaction => query<{ spent: number; reserved: number }>(transaction,
      "SELECT SpentMicros AS spent,ReservedMicros AS reserved FROM dbo.ImportBudget WHERE Month=@month", { month: budgetMonth }));
    assert.deepEqual(budget[0], { spent: 200_000, reserved: 0 });
    activeBudgetMonth = retryBudgetMonth;
    const retried = await imports.retry(secondJob.id, failed.version);
    assert.equal(retried.state, "queued");
    await processImport(secondJob.id, provider, expiredDelivery.deadline);
    await failImportDelivery(secondJob.id, provider, expiredDelivery.deadline);
    assert.equal((await imports.get(secondJob.id)).state, "queued", "Stale deliveries and poison cannot mutate a new attempt.");
    assert.equal(await importDelivery(secondJob.id, expiredDelivery.deadline), null);
    assert.equal(starts, 3, "A stale attempt cannot start another charged run.");
    const retryDelivery = (await importDelivery(secondJob.id))!;
    await processImport(secondJob.id, provider, retryDelivery.deadline);
    assert.equal(starts, 4);
    for (let stage = 0; stage < 5; stage++) await processImport(secondJob.id, provider, retryDelivery.deadline);
    assert.equal((await imports.get(secondJob.id)).state, "review");
    const undelivered = await createImport("https://www.instagram.com/reel/Undelivered/");
    await serializable(transaction => query(transaction, "UPDATE dbo.ImportJobs SET Deadline=@deadline WHERE Id=@id",
      { id: undelivered.id, deadline: new Date(Date.now() - 1000) }));
    assert.equal((await imports.get(undelivered.id)).state, "failed", "An expired queue message must not leave a job queued forever.");
    assert.equal(starts, 6, "Lazy expiry does not restart or call the provider.");
    const retryBudget = await serializable(transaction => query<{ spent: number; reserved: number }>(transaction,
      "SELECT SpentMicros AS spent,ReservedMicros AS reserved FROM dbo.ImportBudget WHERE Month=@month", { month: retryBudgetMonth }));
    assert.deepEqual(retryBudget[0], { spent: 200_000, reserved: 0 });
    activeBudgetMonth = ambiguousBudgetMonth;
    const ambiguous = await createImport("https://www.instagram.com/reel/AmbiguousAudio/");
    await processImport(ambiguous.id, provider);
    await processImport(ambiguous.id, provider);
    lostResponse = true;
    await assert.rejects(() => processImport(ambiguous.id, provider), /response was lost/);
    lostResponse = false;
    const ambiguousFailure = await imports.get(ambiguous.id);
    assert.equal(ambiguousFailure.state, "failed");
    const chargedStarts = starts;
    await processImport(ambiguous.id, provider);
    await assert.rejects(() => imports.retry(ambiguous.id, ambiguousFailure.version),
      (error: unknown) => error instanceof AppError && error.code === "retry_unsafe");
    assert.equal(starts, chargedStarts, "A lost second-stage POST is never charged again.");
    const betweenStages = await createImport("https://www.instagram.com/reel/ExpiredBetweenStages/");
    await processImport(betweenStages.id, provider);
    await processImport(betweenStages.id, provider);
    await serializable(transaction => query(transaction, "UPDATE dbo.ImportJobs SET Deadline=@deadline WHERE Id=@id",
      { id: betweenStages.id, deadline: new Date(Date.now() - 1000) }));
    const expiredBetweenStages = await imports.get(betweenStages.id);
    await assert.rejects(() => imports.retry(betweenStages.id, expiredBetweenStages.version),
      (error: unknown) => error instanceof AppError && error.code === "retry_unsafe");
    activeBudgetMonth = revokedBudgetMonth;
    const bobImports = new ImportService(bob, provider);
    const revokedJob = await bobImports.create({ sourceURL: "https://www.instagram.com/reel/RevokedBook/", bookId: shared.id }, randomUUID());
    const beforeRevocationStarts = starts;
    await alice.changeMember(shared.id, bobId, null, shared.version);
    shared = (await alice.books()).find(book => book.id === shared.id)!;
    await assert.rejects(() => bobImports.get(revokedJob.id),
      (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    assert.equal((await bobImports.list()).length, 0, "Revoked book jobs do not leak through the global list.");
    await processImport(revokedJob.id, provider);
    assert.equal(starts, beforeRevocationStarts, "Revoked destination membership prevents the next charged stage.");
    const revokedState = await serializable(transaction => query<{ state: string }>(transaction,
      "SELECT State AS state FROM dbo.ImportJobs WHERE Id=@id", { id: revokedJob.id }));
    assert.equal(revokedState[0]!.state, "failed");
    shared = await alice.addMember(shared.id, bobId, shared.version);
    await verifyCachedModelRecovery();
    const promoted = await alice.changeMember(shared.id, bobId, "owner", shared.version);
    assert.ok("version" in promoted);
    shared = (await alice.books()).find(book => book.id === shared.id)!;
    const outcomes = await Promise.allSettled([
      alice.changeMember(shared.id, aliceId, "member", shared.version),
      bob.changeMember(shared.id, bobId, "member", shared.version)
    ]);
    assert.equal(outcomes.filter(value => value.status === "fulfilled").length, 1);
    const owners = (await alice.members(shared.id)).filter(member => member.role === "owner");
    assert.equal(owners.length, 1);
    const lastOwner = owners[0]!.userId === aliceId ? alice : bob;
    await assert.rejects(() => lastOwner.deleteAccount(), (error: unknown) => error instanceof AppError && error.code === "last_owner");
    shared = (await alice.books()).find(book => book.id === shared.id)!;
    const ownerService = shared.role === "owner" ? alice : bob;
    await ownerService.deleteBook(shared.id, shared.version);
    sharedId = "";
    await assert.rejects(() => alice.recipes(shared.id), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    await serializable(async transaction => {
      await query(transaction, "UPDATE dbo.AccessInvites SET Revoked=1 WHERE Issuer=@issuer AND Subject='bob'", { issuer });
    });
    assert.equal((await bob.me()).access, "awaitingInvite");
    await assert.rejects(() => bob.books(), (error: unknown) => error instanceof AppError && error.code === "invite_required");
  } finally {
    await serializable(async transaction => {
      if (sharedId) await query(transaction, "DELETE dbo.Books WHERE Id=@id", { id: sharedId });
      await query(transaction, "DELETE dbo.Books WHERE Id IN(SELECT m.BookId FROM dbo.Memberships m JOIN dbo.Accounts a ON a.Id=m.UserId WHERE a.Issuer=@issuer)", { issuer });
      await query(transaction, "DELETE dbo.ShoppingLists WHERE UserId IN(SELECT Id FROM dbo.Accounts WHERE Issuer=@issuer)", { issuer });
      await query(transaction, "DELETE dbo.ImportRequests WHERE UserId IN(SELECT Id FROM dbo.Accounts WHERE Issuer=@issuer)", { issuer });
      await query(transaction, "DELETE dbo.ImportJobs WHERE UserId IN(SELECT Id FROM dbo.Accounts WHERE Issuer=@issuer)", { issuer });
      await query(transaction, "DELETE dbo.ImportBudget WHERE Month=@month", { month: budgetMonth });
      await query(transaction, "DELETE dbo.ImportBudget WHERE Month=@month", { month: retryBudgetMonth });
      await query(transaction, "DELETE dbo.ImportBudget WHERE Month=@month", { month: ambiguousBudgetMonth });
      await query(transaction, "DELETE dbo.ImportBudget WHERE Month=@month", { month: revokedBudgetMonth });
      await query(transaction, "DELETE dbo.ImportBudget WHERE Month=@month", { month: recoveryBudgetMonth });
      await query(transaction, "DELETE dbo.Accounts WHERE Issuer=@issuer", { issuer });
      await query(transaction, "DELETE dbo.AccessInvites WHERE Issuer=@issuer", { issuer });
    });
    await (await database()).close();
  }
});
