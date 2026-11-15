import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { query, serializable, database } from "../src/database.js";
import { RecipeBookService } from "../src/service.js";
import { AppError } from "../src/contracts.js";
import { ImportService, processImport } from "../src/imports.js";
import { ApifyProvider, type ProviderBudget, type ProviderRun } from "../src/apify.js";
import { readRecipeImage } from "../src/images.js";

const enabled = process.env["RUN_SQL_INTEGRATION"] === "true";
test("SQL: member isolation, optimistic writes, last-owner race and account departure are transactional", { skip: !enabled }, async () => {
  const issuer = "https://test.invalid/" + randomUUID();
  const names = ["alice", "bob", "outsider"];
  const principals = names.map(subject => ({ issuer, subject }));
  const services = principals.map(principal => new RecipeBookService(principal));
  const [alice, bob, outsider] = services as [RecipeBookService, RecipeBookService, RecipeBookService];
  let aliceId = "";
  let bobId = "";
  let sharedId = "";
  const budgetMonth = "test001";
  let starts = 0;
  let succeeded = false;
  class FixtureProvider extends ApifyProvider {
    override async budget(): Promise<ProviderBudget> {
      return { month: budgetMonth, spentMicros: 0, capMicros: 250_000, reserveMicros: 100_000, endsAt: new Date(Date.now() + 3_600_000) };
    }
    override async start(): Promise<ProviderRun> {
      starts++;
      await new Promise(resolve => setTimeout(resolve, 50));
      return { id: "fixture-run", status: "RUNNING", defaultDatasetId: "fixture-dataset", options: { maxTotalChargeUsd: 0.1, isMaxTotalChargeUsdSetByUser: true } };
    }
    override async run(): Promise<ProviderRun> {
      return { id: "fixture-run", status: succeeded ? "SUCCEEDED" : "RUNNING", defaultDatasetId: "fixture-dataset", options: { maxTotalChargeUsd: 0.1, isMaxTotalChargeUsdSetByUser: true } };
    }
    override async evidence() { return { caption: "Soup\nIngredients:\n100 g carrots\n\nMethod:\nSimmer", comments: [], transcript: null }; }
  }
  const provider = new FixtureProvider();
  try {
    await serializable(async transaction => {
      for (const principal of principals) {
        await query(transaction, "INSERT dbo.AccessInvites(Issuer,Subject,ExpiresAt) VALUES(@issuer,@subject,@expires)",
          { ...principal, expires: new Date(Date.now() + 3_600_000) });
      }
    });
    aliceId = (await alice.me()).id;
    bobId = (await bob.me()).id;
    await outsider.me();
    const privateBook = await alice.createBook({ name: "Private", kind: "personal" });
    let shared = await alice.createBook({ name: "Shared", kind: "shared" });
    sharedId = shared.id;
    await assert.rejects(() => bob.recipes(privateBook.id), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    shared = await alice.addMember(shared.id, bobId, shared.version);
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
      APIFY_ACCOUNT_EXCLUSIVE: "true", APIFY_ACTOR_ID: "fixture~actor", APIFY_ACTOR_BUILD: "1.2.3",
      APIFY_RUN_CAP_MICROS: "100000", APIFY_INPUT_URL_FIELD: "urls"
    });
    const imports = new ImportService(alice, provider);
    const outsiderImports = new ImportService(outsider, provider);
    const key = randomUUID();
    const importJob = await imports.create({ sourceURL: "https://instagram.com/reel/Fixture1/?tracking=1" }, key);
    const duplicate = await imports.create({ sourceURL: "https://www.instagram.com/reel/Fixture1/" }, randomUUID());
    assert.equal(importJob.id, duplicate.id);
    await assert.rejects(() => imports.create({ sourceURL: "https://www.instagram.com/reel/Different/" }, key),
      (error: unknown) => error instanceof AppError && error.code === "idempotency_conflict");
    await assert.rejects(() => outsiderImports.get(importJob.id), (error: unknown) => error instanceof AppError && error.code === "import_not_found");
    const secondJob = await imports.create({ sourceURL: "https://www.instagram.com/reel/Fixture2/" }, randomUUID());
    await Promise.all([processImport(importJob.id, provider), processImport(importJob.id, provider)]);
    assert.equal(starts, 1, "Concurrent delivery must perform one charged dispatch.");
    assert.equal((await imports.get(importJob.id)).state, "running");
    succeeded = true;
    await processImport(importJob.id, provider);
    const review = await imports.get(importJob.id);
    assert.equal(review.state, "review");
    assert.equal(review.draft!.ingredients[0]!.quantity, "100");
    const approved = await imports.approve(importJob.id, shared.id, review.draft, review.version);
    assert.equal((await imports.get(importJob.id)).recipeId, approved.id);
    assert.equal((await imports.create({ sourceURL: "https://www.instagram.com/reel/Fixture1/" }, key)).state, "completed");
    assert.equal(starts, 1);
    await assert.rejects(() => imports.create({ sourceURL: "https://www.instagram.com/reel/Fixture3/" }, randomUUID()),
      (error: unknown) => error instanceof AppError && error.code === "budget_exhausted");
    await serializable(async transaction => {
      await query(transaction, "UPDATE dbo.ImportJobs SET Deadline=@deadline WHERE Id=@id",
        { id: secondJob.id, deadline: new Date(Date.now() - 1000) });
    });
    await processImport(secondJob.id, provider);
    const failed = await imports.get(secondJob.id);
    assert.equal(failed.state, "failed");
    assert.equal(starts, 1);
    await assert.rejects(() => imports.retry(secondJob.id, failed.version),
      (error: unknown) => error instanceof AppError && error.code === "budget_exhausted");
    const budget = await serializable(transaction => query<{ spent: number; reserved: number }>(transaction,
      "SELECT SpentMicros AS spent,ReservedMicros AS reserved FROM dbo.ImportBudget WHERE Month=@month", { month: budgetMonth }));
    assert.deepEqual(budget[0], { spent: 200_000, reserved: 0 });
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
      await query(transaction, "DELETE dbo.Accounts WHERE Issuer=@issuer", { issuer });
      await query(transaction, "DELETE dbo.AccessInvites WHERE Issuer=@issuer", { issuer });
    });
    await (await database()).close();
  }
});
