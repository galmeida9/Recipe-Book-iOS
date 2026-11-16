import test from "node:test";
import assert from "node:assert/strict";
import { verifiedFreeStopBudget } from "../src/apify.js";
import { ImportPipelineProvider } from "../src/import-pipeline.js";

const now = Date.parse("2026-11-16T20:30:00.000Z");
function proof() {
  Object.assign(process.env, {
    APIFY_FREE_PLAN_VERIFIED: "true", APIFY_NO_OVERAGES_VERIFIED: "true", APIFY_ACCOUNT_EXCLUSIVE: "false",
    APIFY_BACKEND_LEDGER_VERIFIED: "true",
    APIFY_FREE_STOP_VERIFIED_AT: "2026-11-16T20:00:00.000Z",
    APIFY_VERIFIED_CYCLE_START: "2026-11-13T00:00:00.000Z", APIFY_VERIFIED_CYCLE_END: "2026-12-12T00:00:00.000Z",
    APIFY_VERIFIED_SPENT_MICROS: "110000", APIFY_PILOT_CAP_MICROS: "1000000"
  });
}
test("operator-attested Free stop is explicit, short-lived, conservative and does not claim global usage visibility", () => {
  proof();
  const budget = verifiedFreeStopBudget(80_000, now);
  assert.equal(budget.visibility, "verified-free-stop");
  assert.equal(budget.spentMicros, 110_000);
  assert.equal(budget.capMicros, 1_000_000);
  assert.equal(budget.endsAt.toISOString(), "2026-11-17T20:00:00.000Z");
  assert.equal(budget.month, "2026-11");
});
test("stale/future/missing/cross-cycle evidence and excessive pilot caps fail closed", () => {
  const changes = [
    { APIFY_FREE_STOP_VERIFIED_AT: "2026-11-15T20:00:00.000Z" },
    { APIFY_FREE_STOP_VERIFIED_AT: "2026-11-15T20:40:00.000Z" },
    { APIFY_FREE_STOP_VERIFIED_AT: "2026-11-16T21:00:00.000Z" },
    { APIFY_NO_OVERAGES_VERIFIED: "false" }, { APIFY_PILOT_CAP_MICROS: "5000000" },
    { APIFY_PILOT_CAP_MICROS: "100000" }, { APIFY_VERIFIED_SPENT_MICROS: "-1" },
    { APIFY_VERIFIED_CYCLE_START: "2026-11-17T00:00:00.000Z" }
  ];
  for (const change of changes) { proof(); Object.assign(process.env, change); assert.throws(() => verifiedFreeStopBudget(80_000, now)); }
  proof();
  delete process.env["APIFY_FREE_STOP_VERIFIED_AT"];
  assert.throws(() => verifiedFreeStopBudget(80_000, now));
});
test("default API-usage mode never silently replaces a scoped-token 403 with an attestation", async () => {
  proof();
  Object.assign(process.env, {
    APIFY_PIPELINE_REVIEW_ACKNOWLEDGED: "true", APIFY_PIPELINE_PRICING_VERIFIED: "true", APIFY_TOKEN: "synthetic-only",
    APIFY_METADATA_BUILD: "0.0.653", APIFY_AUDIO_BUILD: "0.0.83", APIFY_MODEL_BUILD: "0.1.65",
    APIFY_METADATA_CAP_MICROS: "10000", APIFY_AUDIO_CAP_MICROS: "20000", APIFY_MODEL_CAP_MICROS: "50000"
  });
  delete process.env["APIFY_BUDGET_MODE"];
  process.env["APIFY_ACCOUNT_EXCLUSIVE"] = "true";
  const provider = new ImportPipelineProvider(async () =>
    Response.json({ error: { type: "insufficient-permissions" } }, { status: 403 }));
  await assert.rejects(() => provider.preflightBudget(), /403 \(insufficient-permissions\)/);
});
