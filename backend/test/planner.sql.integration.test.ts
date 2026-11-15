import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { AppError } from "../src/contracts.js";
import { database, query, serializable } from "../src/database.js";
import { PlannerService, generatedSections } from "../src/planner-service.js";
import { RecipeBookService } from "../src/service.js";

// Foundation alone enables this against its explicitly owned capped database.
const enabled = process.env["RUN_PLANNER_SQL_INTEGRATION"] === "true";
const code = (code: string) => (error: unknown) => error instanceof AppError && error.code === code;
test("SQL planner: atomic reconciliation, stale versions, manual isolation and revocation", { skip: !enabled }, async () => {
  const issuer = "https://planner-fixture.invalid/" + randomUUID();
  const principals = ["owner", "member", "outsider"].map(subject => ({ issuer, subject }));
  const owner = new RecipeBookService(principals[0]!);
  const member = new RecipeBookService(principals[1]!);
  const outsider = new RecipeBookService(principals[2]!);
  const planner = new PlannerService(principals[0]!);
  const memberPlanner = new PlannerService(principals[1]!);
  const outsiderPlanner = new PlannerService(principals[2]!);
  const weekStart = "2026-11-16";
  const days = Array(7).fill("simple");
  const manual = { id: randomUUID(), ingredient: { name: "flour", quantity: "250", unit: "g", preparation: null }, bought: true };
  async function rawList(listId: string) {
    return owner.execute(async (transaction, userId) => (await query<{ items: string; version: number }>(transaction,
      "SELECT Items AS items,Version AS version FROM dbo.ShoppingLists WHERE Id=@listId AND UserId=@userId", { listId, userId }))[0]!);
  }
  try {
    await serializable(async transaction => {
      for (const principal of principals) await query(transaction,
        "INSERT dbo.AccessInvites(Issuer,Subject,ExpiresAt) VALUES(@issuer,@subject,@expires)",
        { ...principal, expires: new Date(Date.now() + 3_600_000) });
    });
    await owner.me(); const memberId = (await member.me()).id; await outsider.me();
    let book = await owner.createBook({ name: "Planner fixture", kind: "shared" });
    book = await owner.addMember(book.id, memberId, book.version);
    const recipe = await owner.saveRecipe(book.id, { title: "Fixture flour", mealStyle: "simple", servings: 2,
      ingredients: [{ name: "flour", quantity: "1", unit: "kg" }], steps: [] });
    let list = await owner.createShoppingList({ name: "Planner fixture list" });
    list = await owner.replaceShoppingItems(list.id, { items: [manual] }, list.version);
    const input = { bookId: book.id, listId: list.id, weekStart, dayStyles: days };
    let result = await planner.generate(input);
    assert.equal(result.generated.length, 1);
    assert.equal(result.generated[0]!.ingredient.quantity, "7000");
    assert.equal(result.generated[0]!.contributions.length, 7);
    assert.deepEqual(JSON.parse((await rawList(list.id)).items), [manual]);
    await assert.rejects(() => planner.generate(input), code("version_conflict"));
    await assert.rejects(() => outsiderPlanner.get(book.id, weekStart), code("book_not_found"));
    await assert.rejects(() => memberPlanner.generate(input), code("list_not_found"));

    result = await planner.check(book.id, weekStart, result.generated[0]!.id, true, result.plan.version);
    result = await planner.generate(input, result.plan.version);
    assert.equal(result.generated[0]!.bought, true);
    result = await planner.replace(book.id, weekStart, { date: weekStart,
      replacement: { recipeId: recipe.id, recipeVersion: recipe.version, servings: 4 } }, result.plan.version);
    assert.equal(result.generated[0]!.ingredient.quantity, "8000");
    assert.equal(result.generated[0]!.bought, false);
    result = await planner.replace(book.id, weekStart, { date: weekStart, replacement: null }, result.plan.version);
    assert.equal(result.generated[0]!.ingredient.quantity, "6000");

    const overflow = await owner.saveRecipe(book.id, { title: "Overflow fixture", mealStyle: "complicated", servings: 1,
      ingredients: [{ name: "flour", quantity: "999999999", unit: "kg" }], steps: [] });
    const beforeRollback = await rawList(list.id);
    await assert.rejects(() => planner.generate({ ...input, dayStyles: Array(7).fill("complicated") }, result.plan.version), code("quantity_overflow"));
    assert.deepEqual(await rawList(list.id), beforeRollback, "Failed generation must roll back both plan and generated list state.");
    assert.equal((await planner.get(book.id, weekStart))!.plan.version, result.plan.version);
    await owner.deleteRecipe(book.id, overflow.id, overflow.version);

    const races = await Promise.allSettled(["2026-11-17", "2026-11-18"].map(date => planner.replace(book.id, weekStart,
      { date, replacement: { recipeId: recipe.id, recipeVersion: recipe.version, servings: 1 } }, result.plan.version)));
    assert.equal(races.filter(value => value.status === "fulfilled").length, 1);
    const rejected = races.find(value => value.status === "rejected");
    assert.ok(rejected?.status === "rejected" && rejected.reason instanceof AppError && rejected.reason.code === "version_conflict");
    await owner.saveRecipe(book.id, { ...recipe.draft, title: "Changed fixture recipe" }, recipe.id, recipe.version);
    const sanitized = (await planner.get(book.id, weekStart))!;
    assert.equal(sanitized.generated.length, 0);
    assert.ok(sanitized.plan.days.every(day => day.slot === null));
    assert.ok(sanitized.warnings.some(warning => warning.code === "recipe_unavailable"));
    assert.deepEqual(JSON.parse((await rawList(list.id)).items), [manual]);

    const current = (await owner.recipes(book.id)).find(value => value.id === recipe.id)!;
    const memberList = await member.createShoppingList({ name: "Member generated fixture" });
    await memberPlanner.generate({ bookId: book.id, listId: memberList.id, weekStart, dayStyles: days });
    await owner.changeMember(book.id, memberId, null, book.version);
    await assert.rejects(() => memberPlanner.get(book.id, weekStart), code("book_not_found"));
    const hidden = await member.execute((transaction, userId) => generatedSections(transaction, userId, memberList.id));
    assert.deepEqual(hidden, [], "Revoked membership must not return stored ingredients or provenance.");
    await owner.deleteRecipe(book.id, current.id, current.version);
    assert.equal((await planner.get(book.id, weekStart))!.generated.length, 0);
    await planner.remove(book.id, weekStart, sanitized.plan.version);
    assert.equal(await planner.get(book.id, weekStart), null);
    assert.deepEqual(JSON.parse((await rawList(list.id)).items), [manual]);

    const next = await planner.generate(input);
    const currentList = await rawList(list.id);
    await owner.deleteShoppingList(list.id, currentList.version);
    assert.equal(await planner.get(book.id, weekStart), null, "Deleting a list cascades its plan and all generated provenance.");
    assert.equal(next.generated.length, 0);
  } finally {
    await serializable(async transaction => {
      await query(transaction, `DELETE dbo.WeeklyPlans WHERE UserId IN(SELECT Id FROM dbo.Accounts WHERE Issuer=@issuer)`, { issuer });
      await query(transaction, `DELETE dbo.ShoppingLists WHERE UserId IN(SELECT Id FROM dbo.Accounts WHERE Issuer=@issuer)`, { issuer });
      await query(transaction, `DELETE dbo.Books WHERE Id IN(
        SELECT m.BookId FROM dbo.Memberships m JOIN dbo.Accounts a ON a.Id=m.UserId WHERE a.Issuer=@issuer)`, { issuer });
      await query(transaction, "DELETE dbo.Accounts WHERE Issuer=@issuer", { issuer });
      await query(transaction, "DELETE dbo.AccessInvites WHERE Issuer=@issuer", { issuer });
    });
    await (await database()).close();
  }
});
