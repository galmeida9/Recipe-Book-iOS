import test from "node:test";
import assert from "node:assert/strict";
import { ApifyProvider, approvedProvider } from "../src/apify.js";
import { AppError } from "../src/contracts.js";

test("provider is disabled by default, not a fake success fallback", () => {
  delete process.env["APIFY_ENABLED"];
  assert.throws(() => approvedProvider(), (error: unknown) => error instanceof AppError && error.code === "provider_not_approved");
});
test("approved dispatch pins build, hard charge cap, one URL, no restarts and restricted permissions", async () => {
  Object.assign(process.env, {
    APIFY_ENABLED: "true", APIFY_FREE_PLAN_VERIFIED: "true", APIFY_NO_OVERAGES_VERIFIED: "true",
    APIFY_ACCOUNT_EXCLUSIVE: "true", APIFY_ACTOR_ID: "test~actor", APIFY_ACTOR_BUILD: "1.2.3",
    APIFY_RUN_CAP_MICROS: "100000", APIFY_INPUT_URL_FIELD: "urls", APIFY_TOKEN: "test-fixture"
  });
  const provider = new ApifyProvider(async (input, options) => {
    const url = new URL(String(input));
    assert.equal(url.searchParams.get("maxTotalChargeUsd"), "0.100000");
    assert.equal(url.searchParams.get("restartOnError"), "false");
    assert.equal(url.searchParams.get("maxItems"), "1");
    assert.equal(url.searchParams.get("build"), "1.2.3");
    assert.equal(url.searchParams.get("forcePermissionLevel"), "LIMITED_PERMISSIONS");
    assert.deepEqual(JSON.parse(String(options?.body)), { urls: ["https://www.instagram.com/reel/a/"] });
    return Response.json({ data: { id: "run-1", status: "RUNNING", defaultDatasetId: "dataset-1", options: { maxTotalChargeUsd: 0.1, isMaxTotalChargeUsdSetByUser: true } } });
  });
  assert.equal((await provider.start("https://www.instagram.com/reel/a/", 100_000)).id, "run-1");
});
test("provider rejects undocumented evidence shapes instead of assuming transcript/comments", async () => {
  Object.assign(process.env, { APIFY_TOKEN: "test-fixture", APIFY_OUTPUT_CAPTION_FIELD: "caption", APIFY_OUTPUT_COMMENTS_FIELD: "comments" });
  const provider = new ApifyProvider(async () => Response.json([{ caption: "Soup", comments: [{ text: "not our reviewed string shape" }] }]));
  await assert.rejects(() => provider.evidence({ id: "r", status: "SUCCEEDED", defaultDatasetId: "d", options: { maxTotalChargeUsd: 0.1, isMaxTotalChargeUsdSetByUser: true } }),
    (error: unknown) => error instanceof AppError && error.code === "provider_shape");
});
