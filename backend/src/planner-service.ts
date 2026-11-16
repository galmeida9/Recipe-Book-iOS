import type sql from "mssql";
import { z } from "zod";
import { assertVersion, idSchema, invariant, type Principal } from "./contracts.js";
import { query } from "./database.js";
import { bookAccess, RecipeBookService } from "./service.js";
import { dayStylesSchema, generatedItemSchema, planSchema, plannerRecipeSchema, weekStartSchema, dateOnlySchema,
  generatePlan, editPlan, reconcilePlan, type GeneratedItem, type PlanResult, type PlannerRecipe, type WeeklyPlan } from "./planner.js";

export const generateWeekSchema = z.object({
  bookId: idSchema, listId: idSchema, weekStart: weekStartSchema, dayStyles: dayStylesSchema
}).strict();
export const replaceSlotSchema = z.object({
  date: dateOnlySchema,
  replacement: z.object({ recipeId: idSchema, recipeVersion: z.number().int().positive(),
    servings: z.number().int().min(1).max(1000).nullable() }).strict().nullable()
}).strict();
interface PlanRow { id: string; bookId: string; listId: string; planData: string; generated: string; version: number }
export interface StoredPlanResult extends PlanResult { listId: string }
export interface GeneratedSection { planId: string; bookId: string; weekStart: string; planVersion: number; items: GeneratedItem[] }

async function recipes(transaction: sql.Transaction, bookId: string): Promise<PlannerRecipe[]> {
  const rows = await query<{ id: string; bookId: string; draft: string; version: number }>(transaction, `
    SELECT CONVERT(varchar(36),Id) AS id,CONVERT(varchar(36),BookId) AS bookId,Draft AS draft,Version AS version
    FROM dbo.Recipes WHERE BookId=@bookId ORDER BY Id`, { bookId });
  return rows.map(row => plannerRecipeSchema.parse({ ...row, draft: JSON.parse(row.draft) }));
}
function decoded(row: PlanRow): { plan: WeeklyPlan; generated: GeneratedItem[] } {
  const plan = planSchema.parse(JSON.parse(row.planData));
  invariant(plan.id === row.id.toLowerCase() && plan.bookId === row.bookId.toLowerCase() && plan.version === row.version,
    500, "plan_storage", "Stored plan identity is inconsistent.");
  return { plan, generated: z.array(generatedItemSchema).parse(JSON.parse(row.generated)) };
}
async function ownedList(transaction: sql.Transaction, listId: string, userId: string): Promise<void> {
  const rows = await query(transaction,
    "SELECT Id FROM dbo.ShoppingLists WITH(UPDLOCK,HOLDLOCK) WHERE Id=@listId AND UserId=@userId", { listId, userId });
  invariant(rows[0], 404, "list_not_found", "Shopping list not found.");
}
async function bumpList(transaction: sql.Transaction, listId: string): Promise<void> {
  await query(transaction, "UPDATE dbo.ShoppingLists SET Version=Version+1 WHERE Id=@listId", { listId });
}
async function load(transaction: sql.Transaction, userId: string, bookId: string, start: string): Promise<PlanRow | undefined> {
  return (await query<PlanRow>(transaction, `
    SELECT CONVERT(varchar(36),Id) AS id,CONVERT(varchar(36),BookId) AS bookId,CONVERT(varchar(36),ListId) AS listId,
    PlanData AS planData,Generated AS generated,Version AS version FROM dbo.WeeklyPlans WITH(UPDLOCK,HOLDLOCK)
    WHERE UserId=@userId AND BookId=@bookId AND WeekStart=CONVERT(date,@start,23)`, { userId, bookId, start }))[0];
}
async function save(transaction: sql.Transaction, userId: string, listId: string, result: PlanResult, insert: boolean): Promise<StoredPlanResult> {
  const parameters = { id: result.plan.id, userId, bookId: result.plan.bookId, listId, start: result.plan.weekStart,
    plan: JSON.stringify(result.plan), generated: JSON.stringify(result.generated), version: result.plan.version };
  if (insert) await query(transaction, `
    INSERT dbo.WeeklyPlans(Id,UserId,BookId,ListId,WeekStart,PlanData,Generated,Version)
    VALUES(@id,@userId,@bookId,@listId,CONVERT(date,@start,23),@plan,@generated,@version)`, parameters);
  else await query(transaction, `
    UPDATE dbo.WeeklyPlans SET PlanData=@plan,Generated=@generated,Version=@version WHERE Id=@id AND UserId=@userId`, parameters);
  await bumpList(transaction, listId);
  return { ...result, listId: listId.toLowerCase() };
}

/** Uses the foundation account gate and book lock; never stores recipe titles or images. */
export class PlannerService {
  private readonly service: RecipeBookService;
  constructor(principal: Principal | RecipeBookService) {
    this.service = principal instanceof RecipeBookService ? principal : new RecipeBookService(principal);
  }
  get(bookId: string, start: string): Promise<StoredPlanResult | null> {
    bookId = idSchema.parse(bookId); start = weekStartSchema.parse(start);
    return this.service.execute(async (transaction, userId) => {
      await bookAccess(transaction, bookId, userId);
      const row = await load(transaction, userId, bookId, start);
      if (!row) return null;
      const stored = decoded(row);
      const result = reconcilePlan(stored.plan, await recipes(transaction, bookId), stored.generated);
      // Sanitize on every read, including after recipe edits/deletion. Keep only
      // reference-only unavailable slots on disk so the warning survives reload.
      if (JSON.stringify(result.generated) !== JSON.stringify(stored.generated)) {
        stored.plan.version++;
        result.plan.version = stored.plan.version;
        await query(transaction, "UPDATE dbo.WeeklyPlans SET Generated=@generated,PlanData=@plan,Version=@version WHERE Id=@id",
          { id: row.id, generated: JSON.stringify(result.generated), plan: JSON.stringify(stored.plan), version: stored.plan.version });
        await bumpList(transaction, row.listId);
      }
      return { ...result, listId: row.listId.toLowerCase() };
    });
  }
  generate(input: unknown, expected: number | null = null): Promise<StoredPlanResult> {
    const body = generateWeekSchema.parse(input);
    return this.service.execute(async (transaction, userId) => {
      await bookAccess(transaction, body.bookId, userId);
      await ownedList(transaction, body.listId, userId);
      const row = await load(transaction, userId, body.bookId, body.weekStart);
      invariant(!row || row.listId.toLowerCase() === body.listId, 409, "plan_list",
        "This week already uses another shopping list. Remove the plan before changing its list.");
      const stored = row ? decoded(row) : null;
      const available = await recipes(transaction, body.bookId);
      const plan = generatePlan(body.bookId, body.weekStart, body.dayStyles, available, stored?.plan, expected);
      return save(transaction, userId, body.listId, reconcilePlan(plan, available, stored?.generated), !row);
    });
  }
  replace(bookId: string, start: string, input: unknown, expected: number): Promise<StoredPlanResult> {
    bookId = idSchema.parse(bookId); start = weekStartSchema.parse(start);
    const body = replaceSlotSchema.parse(input);
    return this.service.execute(async (transaction, userId) => {
      await bookAccess(transaction, bookId, userId);
      const row = await load(transaction, userId, bookId, start);
      invariant(row, 404, "plan_not_found", "Plan not found.");
      await ownedList(transaction, row.listId, userId);
      const stored = decoded(row);
      const available = await recipes(transaction, bookId);
      const plan = editPlan(stored.plan, body.date, body.replacement, available, expected);
      return save(transaction, userId, row.listId, reconcilePlan(plan, available, stored.generated), false);
    });
  }
  remove(bookId: string, start: string, expected: number): Promise<void> {
    bookId = idSchema.parse(bookId); start = weekStartSchema.parse(start);
    return this.service.execute(async (transaction, userId) => {
      await bookAccess(transaction, bookId, userId);
      const row = await load(transaction, userId, bookId, start);
      invariant(row, 404, "plan_not_found", "Plan not found."); assertVersion(row.version, expected);
      await ownedList(transaction, row.listId, userId);
      await query(transaction, "DELETE dbo.WeeklyPlans WHERE Id=@id AND UserId=@userId", { id: row.id, userId });
      await bumpList(transaction, row.listId);
    });
  }
  check(bookId: string, start: string, itemId: string, bought: boolean, expected: number): Promise<StoredPlanResult> {
    bookId = idSchema.parse(bookId); start = weekStartSchema.parse(start); itemId = idSchema.parse(itemId); z.boolean().parse(bought);
    return this.service.execute(async (transaction, userId) => {
      await bookAccess(transaction, bookId, userId);
      const row = await load(transaction, userId, bookId, start);
      invariant(row, 404, "plan_not_found", "Plan not found."); assertVersion(row.version, expected);
      await ownedList(transaction, row.listId, userId);
      const stored = decoded(row);
      const result = reconcilePlan(stored.plan, await recipes(transaction, bookId), stored.generated);
      invariant(JSON.stringify(result.generated) === JSON.stringify(stored.generated), 412, "version_conflict",
        "Generated quantities changed. Reload before marking them bought.");
      const item = result.generated.find(value => value.id === itemId);
      invariant(item, 404, "generated_not_found", "Generated item not found.");
      item.bought = bought; result.plan.version++;
      return save(transaction, userId, row.listId, result, false);
    });
  }
}

/** Foundation calls inside its list-read transaction, before returning manual + generated sections. */
export async function generatedSections(transaction: sql.Transaction, userId: string, listId: string): Promise<GeneratedSection[]> {
  await ownedList(transaction, listId, userId);
  const rows = await query<PlanRow>(transaction, `
    SELECT CONVERT(varchar(36),p.Id) AS id,CONVERT(varchar(36),p.BookId) AS bookId,CONVERT(varchar(36),p.ListId) AS listId,
    p.PlanData AS planData,p.Generated AS generated,p.Version AS version
    FROM dbo.WeeklyPlans p WITH(UPDLOCK,HOLDLOCK) WHERE p.UserId=@userId AND p.ListId=@listId ORDER BY p.BookId,p.Id`, { userId, listId });
  const sections: GeneratedSection[] = [];
  for (const row of rows) {
    const membership = await query(transaction, "SELECT BookId FROM dbo.Memberships WHERE BookId=@bookId AND UserId=@userId",
      { bookId: row.bookId, userId });
    if (!membership.length) {
      // Revocation must not return stored ingredient snapshots or provenance.
      await query(transaction, "DELETE dbo.WeeklyPlans WHERE Id=@id AND UserId=@userId", { id: row.id, userId });
      await bumpList(transaction, listId);
      continue;
    }
    await bookAccess(transaction, row.bookId, userId);
    const stored = decoded(row);
    const result = reconcilePlan(stored.plan, await recipes(transaction, row.bookId), stored.generated);
    if (JSON.stringify(result.generated) !== JSON.stringify(stored.generated)) {
      stored.plan.version++;
      await query(transaction, "UPDATE dbo.WeeklyPlans SET Generated=@generated,PlanData=@plan,Version=@version WHERE Id=@id",
        { id: row.id, generated: JSON.stringify(result.generated), plan: JSON.stringify(stored.plan), version: stored.plan.version });
      await bumpList(transaction, listId);
    }
    sections.push({ planId: stored.plan.id, bookId: stored.plan.bookId, weekStart: stored.plan.weekStart,
      planVersion: stored.plan.version, items: result.generated });
  }
  return sections;
}
