import { z } from "zod";

export const idSchema = z.string().uuid().transform(value => value.toLowerCase());
export const ingredientSchema = z.object({
  name: z.string().trim().min(1).max(200),
  quantity: z.string().regex(/^(?:0|[1-9]\d{0,8})(?:\.\d{1,6})?$/).nullable().default(null),
  unit: z.string().trim().min(1).max(40).nullable().default(null),
  preparation: z.string().trim().min(1).max(300).nullable().default(null)
}).strict();
export const draftSchema = z.object({
  title: z.string().trim().min(1).max(200),
  ingredients: z.array(ingredientSchema).max(200),
  steps: z.array(z.string().trim().min(1).max(4000)).max(100),
  servings: z.number().int().min(1).max(1000).nullable().default(null),
  totalMinutes: z.number().int().min(1).max(100_000).nullable().default(null),
  sourceURL: z.string().url().max(2048).nullable().default(null)
  ,mealStyle: z.enum(["simple", "complicated", "full"]).nullable().default(null)
  ,coverImageID: z.string().uuid().transform(value => value.toLowerCase()).nullable().default(null)
}).strict();
export const shoppingItemSchema = z.object({
  id: idSchema,
  ingredient: ingredientSchema,
  bought: z.boolean()
}).strict();

export type Ingredient = z.infer<typeof ingredientSchema>;
export type RecipeDraft = z.infer<typeof draftSchema>;
export type ShoppingItem = z.infer<typeof shoppingItemSchema>;
export type Role = "owner" | "member";
export type BookKind = "personal" | "shared";
export interface Book { id: string; name: string; kind: BookKind; role: Role; version: number }
export interface Recipe { id: string; bookId: string; authorId: string; draft: RecipeDraft; version: number }
export interface ShoppingList { id: string; name: string; items: ShoppingItem[]; version: number }
export interface Evidence { caption: string | null; comments: string[]; transcript: string | null }
export type ImportState = "queued" | "running" | "review" | "failed" | "completed" | "discarded";
export interface ImportJob {
  id: string;
  state: ImportState;
  sourceURL: string;
  draft: RecipeDraft | null;
  evidence: Evidence | null;
  error: string | null;
  version: number;
  createdAt: string;
  recipeId: string | null;
  bookId: string | null;
}
export interface Principal { issuer: string; subject: string }

export class AppError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message);
    this.name = "AppError";
  }
}
export function invariant(condition: unknown, status: number, code: string, message: string): asserts condition {
  if (!condition) throw new AppError(status, code, message);
}
export function requiredSetting(name: string): string {
  const value = process.env[name]?.trim();
  invariant(value, 503, "configuration", `Required server setting ${name} is not configured.`);
  return value;
}
export function expectedVersion(header: string | null): number {
  invariant(header && /^[1-9]\d{0,8}$/.test(header), 428, "version_required", "A valid If-Match version is required.");
  return Number(header);
}
export function assertVersion(actual: number, expected: number): void {
  invariant(actual === expected, 412, "version_conflict", "This item changed. Reload before saving.");
}
export function canonicalReelURL(input: string): string {
  let url: URL;
  try { url = new URL(input); }
  catch { throw new AppError(400, "invalid_reel", "An HTTPS Instagram Reel URL is required."); }
  // URL normalizes :443, so reject explicit ports against the original authority too.
  invariant(/^https:\/\/(?:www\.)?instagram\.com\//i.test(input)
    && url.protocol === "https:"
    && ["instagram.com", "www.instagram.com"].includes(url.hostname)
    && !url.username && !url.password && !url.port
    && /^\/reel\/[A-Za-z0-9_-]+\/?$/.test(url.pathname),
  400, "invalid_reel", "An HTTPS Instagram Reel URL is required.");
  const code = url.pathname.split("/")[2];
  return `https://www.instagram.com/reel/${code}/`;
}
