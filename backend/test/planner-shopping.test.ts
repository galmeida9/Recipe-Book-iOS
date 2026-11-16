import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import sql from "mssql";
import { draftSchema } from "../src/contracts.js";
import { RecipeBookService } from "../src/service.js";
import { generatePlan, reconcilePlan } from "../src/planner.js";

test("shopping read sanitizes stale generated rows, then returns final version and unchanged manual items", async t => {
  const userId = randomUUID(), bookId = randomUUID(), listId = randomUUID();
  const manual = [{ id: randomUUID(), ingredient: { name: "flour", quantity: "10", unit: "g", preparation: null }, bought: true }];
  const recipe = { id: randomUUID(), bookId, version: 1,
    draft: draftSchema.parse({ title: "Private recipe", mealStyle: "simple", ingredients: [{ name: "flour", quantity: "1", unit: "g" }], steps: [] }) };
  const first = reconcilePlan(generatePlan(bookId, "2026-11-16", Array(7).fill("simple"), [recipe]), [recipe]);
  const service = new RecipeBookService({ issuer: "https://shopping-test.invalid", subject: "synthetic" });
  t.mock.method(service, "execute", async function<T>(work: (transaction: sql.Transaction, userId: string) => Promise<T>): Promise<T> {
    return work(new sql.Transaction(), userId);
  });
  let version = 3;
  const calls: string[] = [];
  t.mock.method(sql.Request.prototype, "query", async function(this: sql.Request, text: string) {
    calls.push(text);
    let rows: unknown[];
    if (text.includes("PlanData AS planData")) {
      rows = [{ id: first.plan.id, bookId, listId, planData: JSON.stringify(first.plan), generated: JSON.stringify(first.generated), version: 1 }];
    } else if (text.includes("FROM dbo.Recipes")) rows = [];
    else if (text.includes("FROM dbo.Books")) rows = [{ id: bookId, name: "Book", kind: "shared", version: 1 }];
    else if (text.includes("FROM dbo.Memberships")) rows = [{ role: "member", bookId }];
    else if (text.includes("UPDATE dbo.WeeklyPlans")) {
      assert.equal(this.parameters["generated"]?.value, "[]");
      rows = [];
    } else if (text.includes("UPDATE dbo.ShoppingLists")) {
      version++; rows = [];
    } else if (text.includes("Items AS items")) rows = [{ id: listId, name: "Shopping", items: JSON.stringify(manual), version }];
    else if (text.includes("FROM dbo.ShoppingLists")) rows = [{ id: listId }];
    else throw new Error("Unexpected query in planner shopping fixture.");
    return { recordset: rows };
  });
  const lists = await service.shoppingLists();
  assert.equal(lists[0]!.version, 4, "Version is read after reconciliation bumps the list.");
  assert.deepEqual(lists[0]!.items, manual);
  assert.deepEqual(lists[0]!.generated, [{ planId: first.plan.id, bookId, weekStart: "2026-11-16", planVersion: 2, items: [] }]);
  assert.ok(calls.findIndex(text => text.includes("UPDATE dbo.ShoppingLists")) < calls.findIndex(text => text.includes("Items AS items")));
  assert.ok(!calls.some(text => text.includes("SET Items=")), "Reading generated items never rewrites manual data.");
});
test("account deletion removes owned plans before leaving books or tombstoning the account", async t => {
  const userId = randomUUID();
  const service = new RecipeBookService({ issuer: "https://shopping-test.invalid", subject: "synthetic" });
  t.mock.method(service, "execute", async function<T>(work: (transaction: sql.Transaction, userId: string) => Promise<T>): Promise<T> {
    return work(new sql.Transaction(), userId);
  });
  const calls: string[] = [];
  t.mock.method(sql.Request.prototype, "query", async function(this: sql.Request, text: string) {
    calls.push(text);
    if (text.includes("DELETE dbo.WeeklyPlans")) assert.equal(this.parameters["userId"]?.value, userId);
    return { recordset: [] };
  });
  assert.deepEqual(await service.deleteAccount(), { id: userId });
  assert.match(calls[0]!, /DELETE dbo\.WeeklyPlans WHERE UserId=@userId/);
  assert.ok(calls.some(text => text.includes("Deleted=1")));
});
