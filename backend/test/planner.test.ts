import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { AppError } from "../src/contracts.js";
import { applyStyleRule, editPlan, generatePlan, reconcilePlan, scaledIngredients, weekStartSchema,
  type MealStyle, type PlannerRecipe } from "../src/planner.js";

const bookId = randomUUID();
const monday = "2026-11-16";
const code = (code: string) => (error: unknown) => error instanceof AppError && error.code === code;
function recipe(style: MealStyle | null = "simple", quantity: string | null = "1", unit: string | null = "kg"): PlannerRecipe {
  return { id: randomUUID(), bookId, version: 1, draft: {
    title: "Recipe", ingredients: [{ name: "flour", quantity, unit, preparation: null }],
    steps: [], servings: 2, totalMinutes: 90, sourceURL: null, mealStyle: style
  } };
}
const allSimple: MealStyle[] = Array(7).fill("simple");
test("rules use ISO weekdays, weekends, whole week and selected weekdays", () => {
  const empty = Array(7).fill(null);
  assert.deepEqual(applyStyleRule(empty, "weekdays", "simple"), ["simple", "simple", "simple", "simple", "simple", null, null]);
  assert.deepEqual(applyStyleRule(empty, "weekend", "full"), [null, null, null, null, null, "full", "full"]);
  assert.deepEqual(applyStyleRule(empty, "all", "complicated"), Array(7).fill("complicated"));
  assert.deepEqual(applyStyleRule(allSimple, [0, 3], null), [null, "simple", "simple", null, "simple", "simple", "simple"]);
  assert.throws(() => applyStyleRule(empty, [7], "simple"), code("plan_days"));
});
test("date-only Monday validation rejects impossible dates, Sunday and timestamps", () => {
  for (const date of ["2026-11-15", "2026-02-30", "2026-11-16T00:00:00Z", "0000-01-01"]) {
    assert.equal(weekStartSchema.safeParse(date).success, false);
  }
  assert.equal(weekStartSchema.parse(monday), monday);
  const plan = generatePlan(bookId, "2026-12-28", Array(7).fill(null), []);
  assert.equal(plan.days[6]!.date, "2027-01-03");
});
test("generation uses explicit styles and selected book only; avoids repeats when possible", () => {
  const recipes = Array.from({ length: 7 }, () => recipe());
  const plan = generatePlan(bookId, monday, allSimple, recipes);
  assert.equal(new Set(plan.days.map(day => day.slot!.recipeId)).size, 7);
  const foreign = { ...recipe("full"), bookId: randomUUID() };
  const uncategorized = recipe(null);
  const result = reconcilePlan(generatePlan(bookId, monday, Array(7).fill("full"), [foreign, uncategorized]), [foreign, uncategorized]);
  assert.ok(result.plan.days.every(day => day.slot === null));
  assert.equal(result.warnings.filter(warning => warning.code === "no_eligible_recipe").length, 7);
  assert.equal(result.generated.length, 0);
});
test("small books repeat fairly and disclose repeats without inventing inventory", () => {
  const recipes = [recipe(), recipe()];
  const result = reconcilePlan(generatePlan(bookId, monday, allSimple, recipes), recipes);
  const counts = recipes.map(recipe => result.plan.days.filter(day => day.slot?.recipeId === recipe.id).length).sort();
  assert.deepEqual(counts, [3, 4]);
  assert.equal(result.warnings.filter(warning => warning.code === "repeated_recipe").length, 5);
});
test("regeneration is replacement, not additive, with stable slot and row identifiers", () => {
  const recipes = [recipe()];
  const first = reconcilePlan(generatePlan(bookId, monday, allSimple, recipes), recipes);
  const next = reconcilePlan(generatePlan(bookId, monday, allSimple, recipes, first.plan, 1), recipes, first.generated);
  assert.equal(next.plan.id, first.plan.id);
  assert.deepEqual(next.plan.days.map(day => day.slot!.id), first.plan.days.map(day => day.slot!.id));
  assert.deepEqual(next.generated, first.generated);
  assert.equal(next.generated[0]!.ingredient.quantity, "7000");
  assert.equal(next.generated[0]!.contributions.length, 7);
  assert.throws(() => generatePlan(bookId, monday, allSimple, recipes, next.plan, 1), code("version_conflict"));
});
test("replacement is book/version guarded and scales ingredients without altering the input/manual rows", () => {
  const original = recipe("simple", "0.1");
  const replacement = recipe("full", "0.2");
  const recipes = [original, replacement];
  const first = reconcilePlan(generatePlan(bookId, monday, ["simple", null, null, null, null, null, null], recipes), recipes);
  const manual = { id: randomUUID(), ingredient: { ...original.draft.ingredients[0]! }, bought: true };
  const unchanged = JSON.stringify([manual, recipes, first]);
  const changed = editPlan(first.plan, monday, { recipeId: replacement.id, recipeVersion: 1, servings: 4 }, recipes, 1);
  const result = reconcilePlan(changed, recipes, first.generated);
  assert.equal(result.generated[0]!.ingredient.quantity, "400");
  assert.equal(result.plan.days[0]!.mealStyle, "full");
  assert.equal(JSON.stringify([manual, recipes, first]), unchanged);
  assert.throws(() => editPlan(first.plan, monday, { recipeId: randomUUID(), recipeVersion: 1, servings: 2 }, recipes, 1), code("recipe_not_found"));
  assert.throws(() => editPlan(first.plan, monday, { recipeId: replacement.id, recipeVersion: 2, servings: 2 }, recipes, 1), code("version_conflict"));
  assert.throws(() => editPlan(first.plan, "2026-11-23", null, recipes, 1), code("plan_date"));
});
test("generated checks survive equal/reduced compatible quantities but reset on increased quantities", () => {
  const recipes = [recipe()];
  const first = reconcilePlan(generatePlan(bookId, monday, ["simple", null, null, null, null, null, null], recipes), recipes);
  first.generated[0]!.bought = true;
  const equal = reconcilePlan(first.plan, recipes, first.generated);
  assert.equal(equal.generated[0]!.bought, true);
  const smaller = editPlan(first.plan, monday, { recipeId: recipes[0]!.id, recipeVersion: 1, servings: 1 }, recipes, 1);
  assert.equal(reconcilePlan(smaller, recipes, first.generated).generated[0]!.bought, true);
  const larger = editPlan(first.plan, monday, { recipeId: recipes[0]!.id, recipeVersion: 1, servings: 3 }, recipes, 1);
  assert.equal(reconcilePlan(larger, recipes, first.generated).generated[0]!.bought, false);
  assert.equal(reconcilePlan(editPlan(first.plan, monday, null, recipes, 1), recipes, first.generated).generated.length, 0);
});
test("unknown quantities/units never merge and reset checks on provenance changes", () => {
  const recipeA = recipe("simple", null, null);
  recipeA.draft.ingredients.push({ ...recipeA.draft.ingredients[0]! });
  const recipeB = recipe("simple", "1", "cup");
  recipeB.draft.ingredients.push({ ...recipeB.draft.ingredients[0]! });
  const recipes = [recipeA, recipeB];
  const plan = generatePlan(bookId, monday, ["simple", "simple", null, null, null, null, null], recipes);
  const first = reconcilePlan(plan, recipes);
  assert.equal(first.generated.length, 4);
  first.generated.forEach(row => { row.bought = true; });
  const day = plan.days.find(day => day.slot?.recipeId === recipeA.id)!;
  const changed = editPlan(plan, day.date, { recipeId: recipeB.id, recipeVersion: 1, servings: 2 }, recipes, 1);
  const after = reconcilePlan(changed, recipes, first.generated);
  assert.ok(after.generated.filter(row => row.contributions[0]!.slotId === day.slot!.id).every(row => !row.bought));
  const increased = editPlan(plan, day.date, { recipeId: recipeA.id, recipeVersion: 1, servings: 4 }, recipes, 1);
  assert.ok(reconcilePlan(increased, recipes, first.generated).generated
    .filter(row => row.contributions[0]!.slotId === day.slot!.id).every(row => !row.bought));
});
test("only compatible name/preparation/unit dimensions combine, with exact decimals", () => {
  const recipeA = recipe("simple", "0.1", "kg");
  recipeA.draft.ingredients.push(
    { name: " FLOUR ", quantity: "0.2", unit: "g", preparation: null },
    { name: "flour", quantity: "1", unit: "ml", preparation: null },
    { name: "flour", quantity: "1", unit: "g", preparation: "sifted" });
  const result = reconcilePlan(generatePlan(bookId, monday, ["simple", null, null, null, null, null, null], [recipeA]), [recipeA]);
  assert.equal(result.generated.length, 3);
  assert.equal(result.generated[0]!.ingredient.quantity, "100.2");
  assert.equal(result.generated[0]!.ingredient.unit, "g");
  assert.equal(result.generated[0]!.contributions.length, 2);
});
test("deleted/edited/inaccessible inventory removes slots and snapshots before returning", () => {
  const recipeA = recipe();
  const plan = generatePlan(bookId, monday, allSimple, [recipeA]);
  const previous = reconcilePlan(plan, [recipeA]).generated;
  for (const available of [[], [{ ...recipeA, version: 2 }], [{ ...recipeA, bookId: randomUUID() }], [{ ...recipeA, draft: { ...recipeA.draft, mealStyle: null } }]]) {
    const result = reconcilePlan(plan, available, previous);
    assert.ok(result.plan.days.every(day => day.slot === null));
    assert.equal(result.generated.length, 0);
    assert.equal(result.warnings.length, 7);
    assert.ok(result.warnings.every(warning => !warning.message.includes(recipeA.draft.title)));
  }
});
test("unknown servings stay unknown and scaling rounds up exact micro-units", () => {
  const recipeA = recipe("simple", "1", "g");
  recipeA.draft.servings = 3;
  assert.equal(scaledIngredients(recipeA, 1)[0]!.quantity, "0.333334");
  recipeA.draft.servings = null;
  assert.equal(scaledIngredients(recipeA, null)[0]!.quantity, "1");
  assert.throws(() => scaledIngredients(recipeA, 1), code("unknown_servings"));
  recipeA.draft.servings = 1;
  recipeA.draft.ingredients[0]!.quantity = "999999999";
  assert.throws(() => scaledIngredients(recipeA, 1000), code("quantity_overflow"));
});
