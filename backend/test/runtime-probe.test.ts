import test from "node:test";
import assert from "node:assert/strict";
import { HttpRequest, InvocationContext } from "@azure/functions";
import { importRuntimeProbe } from "../src/bootstrap.js";
import { ImportService } from "../src/imports.js";
import { RecipeBookService } from "../src/service.js";
import { api, dispatch } from "../src/functions.js";

test("runtime workload proof is unavailable by default, including charged POST attempts", async () => {
  delete process.env["IMPORT_RUNTIME_PROBE_ENABLED"];
  for (const method of ["GET", "POST"]) {
    const response = await importRuntimeProbe(new HttpRequest({ method, url: "https://probe.invalid/api/_bootstrap/import" }));
    assert.equal(response.status, 404);
    assert.deepEqual(response.jsonBody, { code: "probe_disabled", message: "Runtime probe is disabled." });
  }
});
test("authenticated import capability route exposes dated pilot limits without routing through shopping or UUID parsing", async t => {
  const capability = { enabled: false, budgetMode: "verified-free-stop", globalUsageVisible: false,
    pilotExpiresAt: "2026-11-17T20:34:00.000Z", reservationMicros: 80_000, availablePilotMicros: 730_000 };
  t.mock.method(ImportService.prototype, "capabilities", async () => capability);
  const response = await dispatch(new HttpRequest({ method: "GET", url: "https://probe.invalid/api/imports/capabilities",
    params: { path: "imports/capabilities" } }), new RecipeBookService({ issuer: "https://probe.invalid", subject: "synthetic" }));
  assert.equal(response.status, 200);
  assert.deepEqual(response.jsonBody, capability);
});
test("operator runtime dispatch cannot accidentally enable ordinary customer creates or retries", async () => {
  process.env["APIFY_ENABLED"] = "true";
  delete process.env["APIFY_CUSTOMER_IMPORTS_ENABLED"];
  const service = new ImportService(new RecipeBookService({ issuer: "https://probe.invalid", subject: "synthetic" }));
  await assert.rejects(() => service.create({ sourceURL: "https://www.instagram.com/reel/synthetic/" }, "synthetic"), /not enabled for customer/);
  await assert.rejects(() => service.retry("synthetic", 1), /not enabled for customer/);
});
test("public capability metadata never admits a customer when its feature gate is off", async () => {
  process.env["APIFY_ENABLED"] = "true";
  process.env["APIFY_CUSTOMER_IMPORTS_ENABLED"] = "false";
  const response = await api(new HttpRequest({ method: "GET", url: "https://probe.invalid/api/import-capabilities",
    params: { path: "import-capabilities" } }), new InvocationContext());
  assert.equal(response.status, 200);
  assert.deepEqual(response.jsonBody, { enabled: false, reason: "Instagram importing is not enabled.", reviewRequired: true });
});
