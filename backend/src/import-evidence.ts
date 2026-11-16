import { z } from "zod";
import { draftSchema, invariant, type Evidence, type RecipeDraft } from "./contracts.js";
import { extractedRecipeSchema, sourcesSchema } from "./recipe-extraction.js";

export const evidenceSchema = z.object({
  caption: z.string().max(40_000).nullable(),
  comments: z.array(z.string().max(10_000)).max(100),
  transcript: z.string().max(100_000).nullable(),
  warnings: z.array(z.string().max(500)).max(100).optional(),
  extraction: extractedRecipeSchema.optional(),
  sources: sourcesSchema.optional()
}).strict();

export function evidenceToReview(evidence: Evidence, sourceURL: string): RecipeDraft {
  const valid = evidenceSchema.parse(evidence);
  invariant(valid.caption || valid.transcript || valid.comments.length, 422, "evidence_missing",
    "This provider did not return caption, comments or transcript evidence.");
  // Only explicitly labelled ingredient/step sections are converted. Unlabelled
  // evidence remains available for manual review rather than invented structure.
  const primary = [valid.caption, valid.transcript].filter((value): value is string => value !== null).join("\n");
  const ingredients: RecipeDraft["ingredients"] = [];
  const steps: string[] = [];
  let section: "ingredients" | "steps" | null = null;
  for (const raw of primary.split(/\r?\n/)) {
    const line = raw.trim();
    if (/^ingredients\s*:?\s*$/i.test(line)) { section = "ingredients"; continue; }
    if (/^(?:instructions|directions|method|steps)\s*:?\s*$/i.test(line)) { section = "steps"; continue; }
    if (!line) { section = null; continue; }
    if (!section) continue;
    const text = line.replace(/^(?:[-*•]\s+|\d+[.)]\s+)/, "").trim();
    if (!text) continue;
    if (section === "steps") {
      if (text.length <= 4000 && steps.length < 100) steps.push(text);
    } else if (text.length <= 200 && ingredients.length < 200) {
      const match = /^(0|[1-9]\d{0,8})(\.\d{1,6})?\s+(kg|g|ml|l|pieces?)\s+(.+)$/i.exec(text);
      ingredients.push(match
        ? { name: match[4]!, quantity: match[1]! + (match[2] ?? ""), unit: match[3]!.toLowerCase(), preparation: null }
        : { name: text, quantity: null, unit: null, preparation: null });
    }
  }
  const firstLine = primary.split(/\r?\n/).find(line => line.trim() && !/^(ingredients|instructions|method|steps)/i.test(line.trim()));
  return draftSchema.parse({
    title: firstLine?.trim().slice(0, 200) ?? "Imported Reel",
    ingredients, steps, servings: null, sourceURL
  });
}
