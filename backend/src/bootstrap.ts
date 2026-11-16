import { app, type HttpRequest, type HttpResponseInit } from "@azure/functions";
import { serializable, query } from "./database.js";
import { z } from "zod";
import { AppError, idSchema, invariant, requiredSetting } from "./contracts.js";
import { ImportPipelineProvider, reviewedPipeline } from "./import-pipeline.js";
import { ImportService, importDelivery } from "./imports.js";
import { RecipeBookService } from "./service.js";
import { enqueueImport } from "./queue.js";

export async function importRuntimeProbe(request: HttpRequest): Promise<HttpResponseInit> {
  const headers = { "Cache-Control": "no-store", "Content-Type": "application/json" };
  try {
    invariant(process.env["IMPORT_RUNTIME_PROBE_ENABLED"] === "true", 404, "probe_disabled", "Runtime probe is disabled.");
    const userId = idSchema.parse(requiredSetting("IMPORT_RUNTIME_PROBE_ACCOUNT"));
    const key = idSchema.parse(requiredSetting("IMPORT_RUNTIME_PROBE_KEY"));
    const config = reviewedPipeline();
    invariant(config.reserveMicros <= 80_000, 503, "probe_cap", "This one-video proof is limited to a total USD 0.08 reservation.");
    const provider = new ImportPipelineProvider();
    if (request.method === "GET" && request.query.get("mode") !== "status") {
      const budget = await provider.preflightBudget();
      invariant(budget.spentMicros + budget.reserveMicros <= budget.capMicros,
        429, "budget_exhausted", "The shared allowance cannot cover this bounded proof.");
      const actors = await provider.preflightAccess();
      return { status: 200, jsonBody: {
        ready: true, importsEnabled: process.env["APIFY_ENABLED"] === "true", reserveMicros: budget.reserveMicros,
        observedSpentMicros: budget.spentMicros, cycle: budget.month, endsAt: budget.endsAt.toISOString(),
        ledgerCapMicros: budget.capMicros, usageVisibility: budget.visibility,
        globalUsageVisible: budget.visibility === "api-usage", operatorProofAt: budget.verifiedAt ?? null,
        readableActorRuns: actors
      }, headers };
    }
    const owner = await serializable(async transaction => {
      const rows = await query<{ issuer: string; subject: string }>(transaction,
        "SELECT Issuer AS issuer,Subject AS subject FROM dbo.Accounts WHERE Id=@userId AND Active=1 AND Deleted=0", { userId });
      invariant(rows[0], 404, "probe_account", "The configured existing app account is unavailable.");
      return rows[0];
    });
    const service = new RecipeBookService(owner);
    const imports = new ImportService(service, provider);
    if (request.method === "POST") {
      const input = await request.text();
      invariant(Buffer.byteLength(input) <= 100, 400, "probe_input", "Only the explicit proof confirmation is accepted.");
      z.object({ confirm: z.literal(true) }).strict().parse(JSON.parse(input));
      // Same public video as the authorized benchmark; normalize its /p/ alias
      // to the app's supported /reel/ route, never an arbitrary operator URL.
      const job = await imports.create({ sourceURL: "https://www.instagram.com/reel/Dfn_CirxcyU/" }, key);
      const delivery = await importDelivery(job.id);
      if (delivery) await enqueueImport(delivery);
      return { status: 200, jsonBody: { id: job.id, state: job.state }, headers };
    }
    const jobId = await service.execute(async (transaction, accountId) => {
      invariant(accountId === userId, 409, "account_changed", "The configured app identity changed.");
      const rows = await query<{ id: string }>(transaction,
        "SELECT CONVERT(varchar(36),JobId) AS id FROM dbo.ImportRequests WHERE UserId=@userId AND IdempotencyKey=@key", { userId, key });
      return rows[0]?.id.toLowerCase() ?? null;
    });
    return { status: 200, jsonBody: jobId ? await imports.get(jobId) : { state: "not_started" }, headers };
  } catch (error) {
    if (error instanceof AppError) return { status: error.status, jsonBody: { code: error.code, message: error.message }, headers };
    return { status: 503, jsonBody: { code: "runtime_probe_failed", errorType: error instanceof Error ? error.name : "UnknownError" }, headers };
  }
}
if (process.env["IMPORT_RUNTIME_PROBE_ENABLED"] === "true") {
  app.http("importRuntimeProbe", {
    route: "_bootstrap/import", methods: ["GET", "POST"], authLevel: "admin", handler: importRuntimeProbe
  });
}

// Opt-in owner-only read probe. Disabled for ordinary deployment and never a
// customer-auth fallback; the platform requires its administrative host key.
if (process.env["CORE_SQL_PROBE_ENABLED"] === "true") {
  app.http("coreBootstrapSqlProbe", {
    route: "_bootstrap/sql", methods: ["GET"], authLevel: "admin",
    handler: async () => {
      try {
        const rows = await serializable(async transaction => {
          await query(transaction, "SELECT TOP(0) Id FROM dbo.Accounts");
          return query<{ principal: string }>(transaction, "SELECT USER_NAME() AS principal");
        });
        return { status: 200, jsonBody: { principal: rows[0]!.principal, sqlReadSucceeded: true }, headers: { "Cache-Control": "no-store" } };
      } catch (error) {
        return { status: 503, jsonBody: {
          code: error instanceof Error && "code" in error ? String(error.code) : "sql_probe_failed",
          number: error instanceof Error && "number" in error ? error.number : null,
          message: error instanceof Error ? error.message : "SQL probe failed"
        }, headers: { "Cache-Control": "no-store" } };
      }
    }
  });
}
