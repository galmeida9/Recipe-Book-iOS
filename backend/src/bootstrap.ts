import { app } from "@azure/functions";
import { serializable, query } from "./database.js";

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
