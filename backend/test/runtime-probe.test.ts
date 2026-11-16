import test from "node:test";
import assert from "node:assert/strict";
import { HttpRequest } from "@azure/functions";
import { importRuntimeProbe } from "../src/bootstrap.js";
import { ImportService } from "../src/imports.js";
import { RecipeBookService } from "../src/service.js";

test("runtime workload proof is unavailable by default, including charged POST attempts", async () => {
  delete process.env["IMPORT_RUNTIME_PROBE_ENABLED"];
  for (const method of ["GET", "POST"]) {
    const response = await importRuntimeProbe(new HttpRequest({ method, url: "https://probe.invalid/api/_bootstrap/import" }));
    assert.equal(response.status, 404);
    assert.deepEqual(response.jsonBody, { code: "probe_disabled", message: "Runtime probe is disabled." });
  }
});
test("operator runtime dispatch cannot accidentally enable ordinary customer creates or retries", async () => {
  process.env["APIFY_ENABLED"] = "true";
  delete process.env["APIFY_CUSTOMER_IMPORTS_ENABLED"];
  const service = new ImportService(new RecipeBookService({ issuer: "https://probe.invalid", subject: "synthetic" }));
  await assert.rejects(() => service.create({ sourceURL: "https://www.instagram.com/reel/synthetic/" }, "synthetic"), /not enabled for customer/);
  await assert.rejects(() => service.retry("synthetic", 1), /not enabled for customer/);
});
