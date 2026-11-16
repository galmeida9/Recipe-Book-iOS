import { app } from "@azure/functions";
import { query, serializable } from "./database.js";
import { AppError, idSchema, invariant, requiredSetting } from "./contracts.js";
import { RecipeBookService } from "./service.js";
import { ImportService } from "./imports.js";
import { PlannerService } from "./planner-service.js";

if (process.env["OWNER_READ_DIAGNOSTICS_ENABLED"] === "true") {
  app.http("ownerReadDiagnostics", {
    route: "_bootstrap/read-timings", methods: ["GET"], authLevel: "admin",
    handler: async () => {
      const entries: { operation: string; elapsedMs: number; count: number | null }[] = [];
      const measure = async <T>(operation: string, work: () => Promise<T>): Promise<T> => {
        const start = Date.now();
        const result = await work();
        entries.push({ operation, elapsedMs: Date.now() - start, count: Array.isArray(result) ? result.length : null });
        return result;
      };
      try {
        const userId = idSchema.parse(requiredSetting("OWNER_READ_DIAGNOSTICS_ACCOUNT"));
        const principal = await measure("existing_account_binding", () => serializable(async transaction => {
          const rows = await query<{ issuer: string; subject: string }>(transaction,
            "SELECT Issuer AS issuer,Subject AS subject FROM dbo.Accounts WHERE Id=@userId AND Active=1 AND Deleted=0", { userId });
          invariant(rows[0], 404, "diagnostic_account", "The configured existing app account is unavailable.");
          return rows[0];
        }));
        const service = new RecipeBookService(principal);
        const account = await measure("account", () => service.me());
        invariant(account.id === userId, 409, "account_changed", "The configured existing identity changed.");
        const books = await measure("books", () => service.books());
        if (books[0]) {
          await measure("first_book_recipes", () => service.recipes(books[0]!.id));
          await measure("first_book_members", () => service.members(books[0]!.id));
          const monday = new Date();
          monday.setUTCHours(0, 0, 0, 0);
          monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7));
          await measure("first_book_week", () => new PlannerService(service).get(books[0]!.id, monday.toISOString().slice(0, 10)));
        }
        await measure("shopping_lists", () => service.shoppingLists());
        await measure("book_import_jobs", () => new ImportService(service).list());
        return { status: 200, jsonBody: { completed: true, entries, note: "Real workload identity/business-service read timings; no customer credentials or content returned." },
          headers: { "Cache-Control": "no-store" } };
      } catch (error) {
        return { status: 503, jsonBody: { completed: false, entries,
          code: error instanceof AppError ? error.code : "owner_read_failed",
          errorType: error instanceof Error ? error.name : "UnknownError" }, headers: { "Cache-Control": "no-store" } };
      }
    }
  });
}
