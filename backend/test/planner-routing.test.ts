import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { HttpRequest, InvocationContext } from "@azure/functions";
import { AppError, draftSchema } from "../src/contracts.js";
import { api, dispatch } from "../src/functions.js";
import { PlannerService } from "../src/planner-service.js";
import { RecipeBookService } from "../src/service.js";
import { generatePlan, reconcilePlan, type PlannerRecipe } from "../src/planner.js";

const principal = { issuer: "https://planner-routing.invalid", subject: "synthetic" };
const bookId = randomUUID(), listId = randomUUID(), itemId = randomUUID();
const weekStart = "2026-11-16";
const generateBody = { bookId, listId, weekStart, dayStyles: ["simple", null, null, null, null, "full", "full"] };
const recipe: PlannerRecipe = { id: randomUUID(), bookId, version: 1,
  draft: draftSchema.parse({ title: "Test", mealStyle: "simple", ingredients: [], steps: [], servings: 2 }) };
const result = { ...reconcilePlan(generatePlan(bookId, weekStart, Array(7).fill("simple"), [recipe]), [recipe]), listId };
function request(method: string, path = "plans", input?: unknown, ifMatch?: string, query = true): HttpRequest {
  return new HttpRequest({
    method, url: `https://fixture.invalid/api/${path}${query ? `?bookId=${bookId}&weekStart=${weekStart}` : ""}`,
    params: { path }, headers: { "content-type": "application/json", ...(ifMatch === undefined ? {} : { "if-match": ifMatch }) },
    ...(input === undefined ? {} : { body: { string: JSON.stringify(input) } })
  });
}
const code = (code: string) => (error: unknown) => error instanceof AppError && error.code === code;

test("shared recipe contract defaults old recipes to unclassified and requires explicit supported styles", () => {
  const legacy = { title: "Slow recipe", totalMinutes: 180, ingredients: [], steps: [] };
  assert.equal(draftSchema.parse(legacy).mealStyle, null, "Duration must never imply full meal.");
  for (const style of ["simple", "complicated", "full", null]) {
    assert.equal(draftSchema.parse({ ...legacy, mealStyle: style }).mealStyle, style);
  }
  assert.equal(draftSchema.safeParse({ ...legacy, mealStyle: "quick" }).success, false);
});
test("GET plans returns the requested book/week or JSON null for an absent plan", async t => {
  const service = new RecipeBookService(principal), planner = new PlannerService(service);
  const get = t.mock.method(planner, "get", async () => null);
  const response = await dispatch(request("GET"), service, planner);
  assert.equal(response.status, 200);
  assert.equal(response.jsonBody, null);
  assert.deepEqual(get.mock.calls[0]!.arguments, [bookId, weekStart]);
});
test("POST plans forwards explicit styles and optional generation If-Match", async t => {
  const service = new RecipeBookService(principal), planner = new PlannerService(service);
  const generate = t.mock.method(planner, "generate", async () => result);
  for (const expected of [undefined, "3"]) {
    const response = await dispatch(request("POST", "plans", generateBody, expected, false), service, planner);
    assert.equal(response.jsonBody, result);
  }
  assert.deepEqual(generate.mock.calls.map(call => call.arguments), [[generateBody, null], [generateBody, 3]]);
  await assert.rejects(() => dispatch(request("POST", "plans", generateBody, "garbage"), service, planner), code("version_required"));
  assert.equal(generate.mock.callCount(), 2);
});
test("PATCH plans forwards replacement/clearing and rejects a missing version before a write", async t => {
  const service = new RecipeBookService(principal), planner = new PlannerService(service);
  const replace = t.mock.method(planner, "replace", async () => result);
  const replacement = { date: weekStart, replacement: { recipeId: recipe.id, recipeVersion: 1, servings: 4 } };
  for (const input of [replacement, { date: weekStart, replacement: null }]) {
    await dispatch(request("PATCH", "plans", input, "4"), service, planner);
    assert.deepEqual(replace.mock.calls.at(-1)!.arguments, [bookId, weekStart, input, 4]);
  }
  await assert.rejects(() => dispatch(request("PATCH", "plans", replacement), service, planner), code("version_required"));
  assert.equal(replace.mock.callCount(), 2);
});
test("generated check route requires a boolean, UUID, book/week and plan version", async t => {
  const service = new RecipeBookService(principal), planner = new PlannerService(service);
  const check = t.mock.method(planner, "check", async () => result);
  const path = `plans/items/${itemId}`;
  assert.equal((await dispatch(request("PATCH", path, { bought: true }, "5"), service, planner)).jsonBody, result);
  assert.deepEqual(check.mock.calls[0]!.arguments, [bookId, weekStart, itemId, true, 5]);
  await assert.rejects(() => dispatch(request("PATCH", path, { bought: "true" }, "5"), service, planner));
  await assert.rejects(() => dispatch(request("PATCH", path, { bought: false }), service, planner), code("version_required"));
  await assert.rejects(() => dispatch(request("PATCH", path, { bought: false }, "5", false), service, planner));
  await assert.rejects(() => dispatch(request("PATCH", "plans/items/not-a-uuid", { bought: false }, "5"), service, planner));
  assert.equal(check.mock.callCount(), 1);
});
test("DELETE plans returns explicit success after version-guarded removal, not route_not_found", async t => {
  const service = new RecipeBookService(principal), planner = new PlannerService(service);
  const remove = t.mock.method(planner, "remove", async () => {});
  const response = await dispatch(request("DELETE", "plans", undefined, "6"), service, planner);
  assert.deepEqual(response.jsonBody, { removed: true });
  assert.deepEqual(remove.mock.calls[0]!.arguments, [bookId, weekStart, 6]);
  await assert.rejects(() => dispatch(request("DELETE"), service, planner), code("version_required"));
  assert.equal(remove.mock.callCount(), 1);
});
test("planner routes reject unknown paths and invalid identity before executing", async t => {
  const service = new RecipeBookService(principal), planner = new PlannerService(service);
  const get = t.mock.method(planner, "get", async () => null);
  await assert.rejects(() => dispatch(request("GET", "plans/unexpected"), service, planner), code("route_not_found"));
  await assert.rejects(() => dispatch(request("GET", "plans", undefined, undefined, false), service, planner));
  const sunday = new HttpRequest({ method: "GET", url: `https://fixture.invalid/api/plans?bookId=${bookId}&weekStart=2026-11-15`, params: { path: "plans" } });
  await assert.rejects(() => dispatch(sunday, service, planner));
  assert.equal(get.mock.callCount(), 0);
});
test("planner access remains behind bearer authentication", async () => {
  const saved = process.env["GOOGLE_SERVER_CLIENT_ID"];
  process.env["GOOGLE_SERVER_CLIENT_ID"] = "123456789-plannerfixture.apps.googleusercontent.com";
  try {
    const response = await api(request("GET"), new InvocationContext({ functionName: "fixture" }));
    assert.equal(response.status, 401);
  } finally {
    if (saved === undefined) delete process.env["GOOGLE_SERVER_CLIENT_ID"];
    else process.env["GOOGLE_SERVER_CLIENT_ID"] = saved;
  }
});
test("local-book-copies still forwards idempotency and expected-account binding", async t => {
  const service = new RecipeBookService(principal);
  const key = randomUUID(), account = randomUUID(), input = { name: "Local", kind: "personal", recipes: [] };
  const book = { id: bookId, name: "Local", kind: "personal" as const, role: "owner" as const, version: 1 };
  const copy = t.mock.method(service, "copyLocalBook", async () => book);
  const req = request("POST", "local-book-copies", input);
  req.headers.set("idempotency-key", key);
  req.headers.set("x-recipe-account-id", account);
  assert.equal((await dispatch(req, service)).jsonBody, book);
  assert.deepEqual(copy.mock.calls[0]!.arguments, [input, key, account]);
});
