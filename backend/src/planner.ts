import { randomUUID } from "node:crypto";
import { z } from "zod";
import { assertVersion, draftSchema, idSchema, ingredientSchema, invariant, type Ingredient } from "./contracts.js";
import { combineShopping } from "./shopping.js";

export const mealStyleSchema = z.enum(["simple", "complicated", "full"]);
export type MealStyle = z.infer<typeof mealStyleSchema>;
export const dateOnlySchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine(value => {
  const date = new Date(value + "T00:00:00Z");
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value && value >= "1900-01-01";
}, "A valid date-only calendar date is required.");
export const weekStartSchema = dateOnlySchema.refine(value => new Date(value + "T00:00:00Z").getUTCDay() === 1,
  "The week must start on an ISO Monday.");
export const dayStylesSchema = z.array(mealStyleSchema.nullable()).length(7);
export const plannerRecipeSchema = z.object({
  id: idSchema, bookId: idSchema, version: z.number().int().positive(),
  draft: draftSchema.extend({ mealStyle: mealStyleSchema.nullable().default(null) })
});
export type PlannerRecipe = z.infer<typeof plannerRecipeSchema>;
export const slotSchema = z.object({
  id: idSchema, recipeId: idSchema, recipeVersion: z.number().int().positive(),
  servings: z.number().int().min(1).max(1000).nullable()
}).strict();
export const planSchema = z.object({
  id: idSchema, bookId: idSchema, weekStart: weekStartSchema,
  days: z.array(z.object({ date: dateOnlySchema, mealStyle: mealStyleSchema.nullable(), slot: slotSchema.nullable() }).strict()).length(7),
  version: z.number().int().positive()
}).strict().superRefine((plan, context) => {
  const dates = weekDates(plan.weekStart);
  if (plan.days.some((day, index) => day.date !== dates[index] || (day.slot && day.mealStyle === null))
    || new Set(plan.days.flatMap(day => day.slot ? [day.slot.id] : [])).size !== plan.days.filter(day => day.slot).length) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Plan days must be ordered Monday through Sunday with unique selected slots." });
  }
});
export type WeeklyPlan = z.infer<typeof planSchema>;
export const provenanceSchema = z.object({
  planId: idSchema, slotId: idSchema, recipeId: idSchema, recipeVersion: z.number().int().positive(),
  ingredientIndex: z.number().int().min(0).max(199), servings: z.number().int().min(1).max(1000).nullable()
}).strict();
export const generatedItemSchema = z.object({
  id: idSchema, key: z.string().max(4000), ingredient: ingredientSchema, bought: z.boolean(),
  contributions: z.array(provenanceSchema).min(1).max(1400)
}).strict();
export type GeneratedItem = z.infer<typeof generatedItemSchema>;
export interface PlannerWarning { date: string; code: "no_eligible_recipe" | "recipe_unavailable" | "repeated_recipe"; message: string }
export interface PlanResult { plan: WeeklyPlan; generated: GeneratedItem[]; warnings: PlannerWarning[] }

export function weekDates(start: string): string[] {
  const date = new Date(start + "T00:00:00Z");
  return Array.from({ length: 7 }, (_, offset) => new Date(date.getTime() + offset * 86_400_000).toISOString().slice(0, 10));
}
export function applyStyleRule(current: readonly (MealStyle | null)[], scope: "weekdays" | "weekend" | "all" | readonly number[],
  style: MealStyle | null): (MealStyle | null)[] {
  dayStylesSchema.parse(current); mealStyleSchema.nullable().parse(style);
  const indices = scope === "all" ? [0, 1, 2, 3, 4, 5, 6] : scope === "weekdays" ? [0, 1, 2, 3, 4] : scope === "weekend" ? [5, 6] : scope;
  invariant(Array.isArray(indices) && indices.every(index => Number.isInteger(index) && index >= 0 && index < 7),
    400, "plan_days", "Select ISO weekday indices from Monday (0) to Sunday (6).");
  return current.map((value, index) => indices.includes(index) ? style : value);
}
function inventory(bookId: string, recipes: readonly PlannerRecipe[]): PlannerRecipe[] {
  return recipes.map(value => plannerRecipeSchema.parse(value)).filter(value => value.bookId === bookId).sort((a, b) => a.id.localeCompare(b.id));
}
export function generatePlan(bookId: string, start: string, styles: readonly (MealStyle | null)[], recipes: readonly PlannerRecipe[],
  existing: WeeklyPlan | null = null, expected: number | null = null, makeId: () => string = randomUUID): WeeklyPlan {
  bookId = idSchema.parse(bookId); weekStartSchema.parse(start); dayStylesSchema.parse(styles);
  if (existing) {
    planSchema.parse(existing); assertVersion(existing.version, expected!);
    invariant(existing.bookId === bookId && existing.weekStart === start, 400, "plan_identity", "Regeneration must retain the selected book and week.");
  } else invariant(expected === null, 412, "version_conflict", "This plan does not exist. Reload before saving.");
  const available = inventory(bookId, recipes);
  const uses = new Map<string, number>();
  const dates = weekDates(start);
  return planSchema.parse({
    id: existing?.id ?? makeId(), bookId, weekStart: start, version: (existing?.version ?? 0) + 1,
    days: styles.map((style, index) => {
      const eligible = available.filter(recipe => recipe.draft.mealStyle === style && style !== null);
      eligible.sort((a, b) => (uses.get(a.id) ?? 0) - (uses.get(b.id) ?? 0) || a.id.localeCompare(b.id));
      const recipe = eligible[0];
      if (recipe) uses.set(recipe.id, (uses.get(recipe.id) ?? 0) + 1);
      return { date: dates[index], mealStyle: style, slot: recipe ? {
        id: existing?.days[index]?.slot?.id ?? makeId(), recipeId: recipe.id,
        recipeVersion: recipe.version, servings: recipe.draft.servings
      } : null };
    })
  });
}
export function editPlan(plan: WeeklyPlan, date: string, replacement: { recipeId: string; recipeVersion: number; servings: number | null } | null,
  recipes: readonly PlannerRecipe[], expected: number, makeId: () => string = randomUUID): WeeklyPlan {
  planSchema.parse(plan); assertVersion(plan.version, expected);
  invariant(plan.days.some(day => day.date === date), 400, "plan_date", "Select a day in this week.");
  const available = inventory(plan.bookId, recipes);
  const recipe = replacement ? available.find(value => value.id === replacement.recipeId) : undefined;
  if (replacement) {
    invariant(recipe, 404, "recipe_not_found", "Choose a current recipe from the selected book.");
    assertVersion(recipe.version, replacement.recipeVersion);
    invariant(recipe.draft.mealStyle, 409, "meal_style_required", "Set this recipe's meal style before planning it.");
    scaledIngredients(recipe, replacement.servings);
  }
  return planSchema.parse({ ...plan, version: plan.version + 1, days: plan.days.map(day => day.date !== date ? day : {
    ...day, mealStyle: recipe?.draft.mealStyle ?? day.mealStyle,
    slot: replacement ? { id: day.slot?.id ?? makeId(), ...replacement } : null
  }) });
}
const precision = 1_000_000n;
function decimal(value: string): bigint {
  ingredientSchema.shape.quantity.parse(value);
  const [whole = "0", fraction = ""] = value.split(".");
  return BigInt(whole) * precision + BigInt(fraction.padEnd(6, "0"));
}
function formatted(value: bigint): string {
  invariant(value <= 999_999_999n * precision + precision - 1n, 400, "quantity_overflow", "Generated quantity exceeds the supported range.");
  const fraction = (value % precision).toString().padStart(6, "0").replace(/0+$/, "");
  return `${value / precision}${fraction ? "." + fraction : ""}`;
}
export function scaledIngredients(recipe: PlannerRecipe, servings: number | null): Ingredient[] {
  slotSchema.shape.servings.parse(servings);
  const base = recipe.draft.servings;
  invariant(servings === base || (base !== null && servings !== null), 409, "unknown_servings",
    "Set the recipe's normal servings before changing planned servings.");
  return recipe.draft.ingredients.map(ingredient => ({
    ...ingredient, quantity: ingredient.quantity === null || servings === base ? ingredient.quantity
      : formatted((decimal(ingredient.quantity) * BigInt(servings!) + BigInt(base!) - 1n) / BigInt(base!))
  }));
}
function canonical(ingredient: Ingredient): { ingredient: Ingredient; compatible: boolean } {
  if (ingredient.quantity === null) return { ingredient: { ...ingredient }, compatible: false };
  const normalized = combineShopping([], [ingredient, { ...ingredient, quantity: "0" }], []);
  return { ingredient: normalized[0]!.ingredient, compatible: normalized.length === 1 };
}
function unchangedOrReduced(before: Ingredient, after: Ingredient): boolean {
  return before.quantity === null || after.quantity === null ? before.quantity === after.quantity
    : decimal(after.quantity) <= decimal(before.quantity);
}
export function reconcilePlan(plan: WeeklyPlan, recipes: readonly PlannerRecipe[], previous: readonly GeneratedItem[] = [],
  makeId: () => string = randomUUID): PlanResult {
  planSchema.parse(plan); z.array(generatedItemSchema).parse(previous);
  const available = inventory(plan.bookId, recipes);
  const warnings: PlannerWarning[] = [];
  const uses = new Set<string>();
  const rows = new Map<string, GeneratedItem>();
  const days = plan.days.map(day => {
    if (!day.slot) {
      if (day.mealStyle !== null) warnings.push({ date: day.date, code: "no_eligible_recipe",
        message: "No recipe selected. Add or categorize recipes in this book, then generate or choose one." });
      return day;
    }
    const slot = day.slot;
    const recipe = available.find(value => value.id === slot.recipeId && value.version === slot.recipeVersion
      && value.draft.mealStyle === day.mealStyle);
    if (!recipe) {
      warnings.push({ date: day.date, code: "recipe_unavailable",
        message: "The selected recipe changed or is unavailable. Choose a current recipe from this book." });
      return { ...day, slot: null };
    }
    if (uses.has(recipe.id)) warnings.push({ date: day.date, code: "repeated_recipe",
      message: "This recipe repeats because the selected meal style has limited inventory." });
    uses.add(recipe.id);
    scaledIngredients(recipe, slot.servings).forEach((source, ingredientIndex) => {
      const normalized = canonical(source);
      const key = normalized.compatible ? JSON.stringify([normalized.ingredient.name.trim().toLowerCase(),
        normalized.ingredient.preparation?.trim().toLowerCase() ?? "", normalized.ingredient.unit])
        : JSON.stringify([slot.id, ingredientIndex]);
      const contribution = { planId: plan.id, slotId: slot.id, recipeId: recipe.id, recipeVersion: recipe.version, ingredientIndex, servings: slot.servings };
      const existing = rows.get(key);
      if (existing) {
        existing.ingredient = combineShopping([{ id: existing.id, ingredient: existing.ingredient, bought: false }], [normalized.ingredient], [])[0]!.ingredient;
        existing.contributions.push(contribution);
      } else rows.set(key, { id: previous.find(row => row.key === key)?.id ?? makeId(), key,
        ingredient: normalized.ingredient, bought: false, contributions: [contribution] });
    });
    return day;
  });
  invariant(rows.size <= 1000, 400, "list_limit", "Generated shopping can contain at most 1000 entries per week.");
  const generated = [...rows.values()].map(row => {
    const old = previous.find(value => value.key === row.key);
    // Unknown-unit rows only retain checks for identical ingredients and provenance.
    const compatible = canonical(row.ingredient).compatible;
    const safe = old && (compatible ? unchangedOrReduced(old.ingredient, row.ingredient)
      : JSON.stringify(old.ingredient) === JSON.stringify(row.ingredient)
        && JSON.stringify(old.contributions) === JSON.stringify(row.contributions));
    return { ...row, bought: Boolean(old?.bought && safe) };
  });
  return { plan: { ...plan, days }, generated, warnings };
}
