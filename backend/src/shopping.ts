import { randomUUID } from "node:crypto";
import { invariant, type Ingredient, type ShoppingItem } from "./contracts.js";

const scale = 1_000_000n;
const units: Record<string, { dimension: string; factor: bigint; output: string }> = {
  g: { dimension: "mass", factor: 1n, output: "g" },
  kg: { dimension: "mass", factor: 1000n, output: "g" },
  ml: { dimension: "volume", factor: 1n, output: "ml" },
  l: { dimension: "volume", factor: 1000n, output: "ml" },
  piece: { dimension: "count", factor: 1n, output: "piece" },
  pieces: { dimension: "count", factor: 1n, output: "piece" }
};
function decimal(value: string): bigint {
  invariant(/^(?:0|[1-9]\d{0,8})(?:\.\d{1,6})?$/.test(value), 400, "quantity", "Invalid ingredient quantity.");
  const [whole = "0", fraction = ""] = value.split(".");
  return BigInt(whole) * scale + BigInt(fraction.padEnd(6, "0"));
}
function format(value: bigint): string {
  const whole = value / scale;
  invariant(whole <= 999_999_999n, 400, "quantity_overflow", "Combined quantity exceeds the supported range.");
  const fraction = (value % scale).toString().padStart(6, "0").replace(/0+$/, "");
  return `${whole}${fraction ? "." + fraction : ""}`;
}
function key(ingredient: Ingredient): string | null {
  if (ingredient.quantity === null) return null;
  const unit = ingredient.unit === null ? undefined : units[ingredient.unit.toLowerCase()];
  if (!unit) return null;
  return JSON.stringify([
    ingredient.name.trim().toLowerCase(),
    ingredient.preparation?.trim().toLowerCase() ?? "",
    unit.dimension
  ]);
}
export function combineShopping(
  existing: readonly ShoppingItem[], ingredients: readonly Ingredient[], alreadyHave: readonly number[],
  makeId: () => string = randomUUID
): ShoppingItem[] {
  invariant(alreadyHave.every(index => Number.isInteger(index) && index >= 0 && index < ingredients.length),
    400, "already_have", "Already-have selections must reference this recipe's ingredients.");
  const omitted = new Set(alreadyHave);
  const result = existing.map(item => ({ ...item, ingredient: { ...item.ingredient } }));
  ingredients.forEach((ingredient, index) => {
    if (omitted.has(index)) return;
    const matchKey = key(ingredient);
    const match = matchKey === null ? undefined : result.find(item => !item.bought && key(item.ingredient) === matchKey);
    if (!match) {
      result.push({ id: makeId(), ingredient: { ...ingredient }, bought: false });
      return;
    }
    const sourceUnit = units[ingredient.unit!.toLowerCase()]!;
    const targetUnit = units[match.ingredient.unit!.toLowerCase()]!;
    const quantity = decimal(match.ingredient.quantity!) * targetUnit.factor
      + decimal(ingredient.quantity!) * sourceUnit.factor;
    match.ingredient.quantity = format(quantity);
    match.ingredient.unit = sourceUnit.output;
  });
  invariant(result.length <= 1000, 400, "list_limit", "A shopping list can contain at most 1000 entries.");
  return result;
}
