import test from "node:test";
import assert from "node:assert/strict";
import { HttpRequest } from "@azure/functions";
import { importRuntimeProbe } from "../src/bootstrap.js";

test("runtime workload proof is unavailable by default, including charged POST attempts", async () => {
  delete process.env["IMPORT_RUNTIME_PROBE_ENABLED"];
  for (const method of ["GET", "POST"]) {
    const response = await importRuntimeProbe(new HttpRequest({ method, url: "https://probe.invalid/api/_bootstrap/import" }));
    assert.equal(response.status, 404);
    assert.deepEqual(response.jsonBody, { code: "probe_disabled", message: "Runtime probe is disabled." });
  }
});
