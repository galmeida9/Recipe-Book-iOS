import test from "node:test";
import assert from "node:assert/strict";
import { AppError, assertVersion, canonicalReelURL, draftSchema } from "../src/contracts.js";
import { canEditRecipe, preserveLastOwner, requireOwner, requireShared } from "../src/policies.js";
import { combineShopping } from "../src/shopping.js";
import { evidenceToReview } from "../src/import-evidence.js";
import { reserveBudget } from "../src/imports.js";

const ingredient = (name: string, quantity: string | null, unit: string | null, preparation: string | null = null) => ({ name, quantity, unit, preparation });
const code = (value: string) => (error: unknown) => error instanceof AppError && error.code === value;

test("only owners and the contributor edit/delete contributed recipes", () => {
  assert.equal(canEditRecipe("owner", "alice", "bob"), true);
  assert.equal(canEditRecipe("member", "alice", "bob"), false);
  assert.equal(canEditRecipe("member", "alice", "alice"), true);
  assert.throws(() => requireOwner("member"), code("owner_required"));
  assert.throws(() => requireShared("personal"), code("personal_book"));
});
test("last owner cannot leave/demote; no auto-promotion", () => {
  assert.throws(() => preserveLastOwner("owner", null, 1), code("last_owner"));
  assert.throws(() => preserveLastOwner("owner", "member", 1), code("last_owner"));
  preserveLastOwner("owner", null, 2);
  preserveLastOwner("member", null, 1);
  preserveLastOwner("owner", "owner", 1);
});
test("stale optimistic writes fail rather than overwrite", () => {
  assert.throws(() => assertVersion(2, 1), code("version_conflict"));
  assertVersion(2, 2);
});
test("decimal shopping arithmetic is exact and mass/volume never mix", () => {
  let counter = 0;
  const result = combineShopping([], [
    ingredient("Flour", "0.1", "kg"), ingredient("flour", "0.2", "g"),
    ingredient("Flour", "50", "ml"), ingredient("Flour", null, "g"),
    ingredient("Flour", "2", "cup"), ingredient("Flour", "1", "g", "sifted")
  ], [], () => String(++counter));
  assert.equal(result.length, 5);
  assert.equal(result[0]!.ingredient.quantity, "100.2");
  assert.equal(result[0]!.ingredient.unit, "g");
});
test("already-have checkboxes apply only to the current operation; bought items do not absorb new items", () => {
  const bought = { id: "bought", ingredient: ingredient("milk", "500", "ml"), bought: true };
  const first = combineShopping([bought], [ingredient("milk", "1", "l"), ingredient("salt", "2", "g")], [1], () => "new");
  assert.equal(first.length, 2);
  assert.equal(first[0]!.ingredient.quantity, "500");
  assert.equal(first[1]!.ingredient.quantity, "1");
  assert.equal(combineShopping(first, [ingredient("salt", "2", "g")], []).length, 3);
  assert.throws(() => combineShopping([], [ingredient("salt", "2", "g")], [1]), code("already_have"));
});
test("same-name incompatible preparations and unknown quantities remain separate", () => {
  const result = combineShopping([], [ingredient("tomato", null, null), ingredient("tomato", null, null), ingredient("tomato", "1", "piece"), ingredient("tomato", "1", "piece", "canned")], []);
  assert.equal(result.length, 4);
});
test("invalid quantities and overflow are explicit failures", () => {
  assert.equal(draftSchema.safeParse({ title: "t", ingredients: [ingredient("salt", "-1", "g")], steps: [] }).success, false);
  assert.throws(() => combineShopping([], [ingredient("flour", "999999999", "kg"), ingredient("flour", "1", "g")], []), code("quantity_overflow"));
});
test("Instagram normalization rejects SSRF authority tricks, other content, ports and schemes", () => {
  assert.equal(canonicalReelURL("https://instagram.com/reel/A_b-1/?igsh=tracking"), "https://www.instagram.com/reel/A_b-1/");
  for (const url of ["http://instagram.com/reel/a/", "https://instagram.com.evil/reel/a/", "https://user@instagram.com/reel/a/", "https://instagram.com:443/reel/a/", "https://instagram.com/p/a/", "https://instagram.com/reel/a/extra"]) {
    assert.throws(() => canonicalReelURL(url), code("invalid_reel"));
  }
});
test("evidence becomes an editable structured draft only where explicit; missing values remain null", () => {
  const draft = evidenceToReview({
    caption: "My soup\nIngredients:\n200 g carrots\nsalt to taste\n\nMethod:\n1. Simmer gently",
    comments: ["I used a little pepper"], transcript: null
  }, "https://www.instagram.com/reel/a/");
  assert.equal(draft.title, "My soup");
  assert.deepEqual(draft.ingredients[0], ingredient("carrots", "200", "g"));
  assert.equal(draft.ingredients[1]!.quantity, null);
  assert.equal(draft.servings, null);
  assert.deepEqual(draft.steps, ["Simmer gently"]);
  const unstructured = evidenceToReview({ caption: "Try this recipe!", comments: [], transcript: null }, "https://www.instagram.com/reel/a/");
  assert.deepEqual(unstructured.ingredients, []);
  assert.deepEqual(unstructured.steps, []);
  assert.throws(() => evidenceToReview({ caption: null, comments: [], transcript: null }, "https://www.instagram.com/reel/a/"), code("evidence_missing"));
});
test("shared budget counts in-flight reservations and fails visibly at the boundary", () => {
  assert.equal(reserveBudget(4_000_000, 500_000, 4_750_000, 250_000), 750_000);
  assert.throws(() => reserveBudget(4_000_000, 500_000, 4_750_000, 250_001), code("budget_exhausted"));
  assert.throws(() => reserveBudget(-1, 0, 5_000_000, 1), code("budget_invalid"));
});
