import test from "node:test";
import assert from "node:assert/strict";
import { ImportPipelineProvider, approvedPipeline, initialPipeline, type Pipeline } from "../src/import-pipeline.js";
import type { ProviderRun } from "../src/apify.js";

function configure() {
  Object.assign(process.env, {
    APIFY_ENABLED: "true", APIFY_FREE_PLAN_VERIFIED: "true", APIFY_NO_OVERAGES_VERIFIED: "true",
    APIFY_ACCOUNT_EXCLUSIVE: "true", APIFY_BACKEND_LEDGER_VERIFIED: "true", APIFY_PIPELINE_REVIEW_ACKNOWLEDGED: "true", APIFY_PIPELINE_PRICING_VERIFIED: "true",
    APIFY_METADATA_BUILD: "1.2.3", APIFY_AUDIO_BUILD: "2.3.4", APIFY_MODEL_BUILD: "3.4.5",
    APIFY_METADATA_CAP_MICROS: "10000", APIFY_AUDIO_CAP_MICROS: "10000", APIFY_MODEL_CAP_MICROS: "10000",
    APIFY_TOKEN: "synthetic-test-only"
  });
}
const url = "https://www.instagram.com/reel/publicRecipe/";
const run: ProviderRun = { id: "run", status: "SUCCEEDED", defaultDatasetId: "dataset",
  options: { maxTotalChargeUsd: 0.01, isMaxTotalChargeUsdSetByUser: true } };
test("production pipeline requires explicit account/data/pricing approval and reserves all three stages", () => {
  configure();
  delete process.env["APIFY_PIPELINE_REVIEW_ACKNOWLEDGED"];
  process.env["APIFY_PIPELINE_TERMS_VERIFIED"] = "true";
  assert.throws(() => approvedPipeline(), /disabled/);
  configure();
  delete process.env["APIFY_PIPELINE_PRICING_VERIFIED"];
  assert.throws(() => approvedPipeline(), /disabled/);
  configure();
  assert.equal(approvedPipeline().reserveMicros, 30_000);
});
test("nonbillable preflight reads actual cycle usage with imports disabled but never enables a charged dispatch", async () => {
  configure();
  process.env["APIFY_ENABLED"] = "false";
  const requests: string[] = [];
  const provider = new ImportPipelineProvider(async (input, options) => {
    requests.push(String(input));
    assert.equal(options?.method, "GET");
    const now = Date.now();
    return Response.json({ data: {
      usageCycle: { startAt: new Date(now - 3_600_000).toISOString(), endAt: new Date(now + 3_600_000).toISOString() },
      totalUsageCreditsUsdAfterVolumeDiscount: 0.11
    } });
  });
  const budget = await provider.preflightBudget();
  assert.equal(budget.spentMicros, 110_000);
  assert.equal(budget.reserveMicros, 30_000);
  assert.equal(requests.length, 1);
  assert(requests[0]!.endsWith("/users/me/usage/monthly"));
  await assert.rejects(() => provider.budget(), /disabled/);
  assert.equal(requests.length, 1);
  process.env["APIFY_ENABLED"] = "true";
});
test("each stage pins actual actor/build/cap and disables expensive optional work, retries and model tools", async () => {
  configure();
  const stages: Pipeline["stage"][] = ["metadata", "audio", "model"];
  let index = 0;
  const provider = new ImportPipelineProvider(async (input, options) => {
    const request = new URL(String(input));
    const body = JSON.parse(String(options?.body));
    assert.equal(request.searchParams.get("maxTotalChargeUsd"), "0.010000");
    assert.equal(request.searchParams.get("restartOnError"), "false");
    assert.equal(request.searchParams.get("forcePermissionLevel"), "LIMITED_PERMISSIONS");
    assert.equal(request.searchParams.get("maxItems"), "1");
    const stage = stages[index++]!;
    assert.equal(request.searchParams.get("memory"), stage === "audio" ? "512" : "256");
    if (stage === "metadata") {
      assert(request.pathname.includes("apify~instagram-reel-scraper"));
      assert.equal(request.searchParams.get("build"), "1.2.3");
      assert.deepEqual(body.username, [url]);
      assert.equal(body.includeTranscript, false);
      assert.equal(body.includeDownloadedVideo, false);
    } else if (stage === "audio") {
      assert(request.pathname.includes("apple_yang~instagram-transcripts-scraper"));
      assert.equal(body.videoUrl, url);
      assert.equal(body.enhancedcrawl, false);
      assert.deepEqual(body.usernames, []);
    } else {
      assert(request.pathname.includes("fayoussef~bulk-llm-runner"));
      assert.equal(body.model, "google/gemini-2.5-flash-lite");
      assert.equal(body.enable_web_search, false);
      assert.equal(body.enable_file_parser, false);
      assert.equal(body.max_retries, 0);
      assert.equal(body.concurrency, 1);
      assert.deepEqual(body.fallback_models, []);
      assert.deepEqual(body.compare_models, []);
      assert.equal(body.prompts.length, 1);
      assert(body.prompts[0].includes("C0"));
      assert(!body.prompts[0].includes("start_seconds"));
    }
    return Response.json({ data: run });
  });
  for (const stage of stages) {
    await provider.startStage(url, { ...initialPipeline(), stage,
      evidence: { caption: "400g tomatoes", comments: [], transcript: "Boil tomatoes." } }, 30_000);
  }
  assert.equal(index, 3);
});
test("changed per-stage caps/builds cannot spend against an existing reservation even if total is equal", async () => {
  configure();
  const pipeline = initialPipeline();
  process.env["APIFY_METADATA_CAP_MICROS"] = "15000";
  process.env["APIFY_AUDIO_CAP_MICROS"] = "5000";
  const provider = new ImportPipelineProvider(async () => { throw new Error("Must not dispatch"); });
  await assert.rejects(() => provider.startStage(url, pipeline, 30_000), /configuration changed/);
});
test("unconfirmed hard caps trigger an abort, never another charged POST", async () => {
  configure();
  const requests: string[] = [];
  const provider = new ImportPipelineProvider(async input => {
    const path = new URL(String(input)).pathname;
    requests.push(path);
    return Response.json({ data: { ...run, options: { maxTotalChargeUsd: 1, isMaxTotalChargeUsdSetByUser: false } } });
  });
  await assert.rejects(() => provider.startStage(url, initialPipeline(), 30_000), /spending cap/);
  assert.equal(requests.length, 2);
  assert.equal(requests[1], "/v2/actor-runs/run/abort");
});
test("real ASR segments are required, timing offsets are not sent as cooking facts, model/citation output is validated", async () => {
  configure();
  const outputs: unknown[][] = [
    [{ url, caption: "400 g tomatoes; Boil tomatoes for 8-10 minutes.", latestComments: [] }],
    [{ url, segments: [{ start: 0, end: 22.336, text: "Boil tomatoes." }] }],
    [{ model: "google/gemini-2.5-flash-lite", error: null, tools_used: [], tool_calls: [], response: JSON.stringify({
      title: "Tomatoes", source_url: url, servings: null, total_minutes: null, requires_review: true, warnings: [],
      ingredients: [{ name: "tomatoes", quantity: 400, unit: "g", notes: null, evidence_ids: ["C0"] }],
      steps: [{ instruction: "Boil tomatoes for 8-10 minutes.", duration_minutes_min: 8, duration_minutes_max: 10, temperature_c: null, evidence_ids: ["C0"] }]
    }) }]
  ];
  const provider = new ImportPipelineProvider(async () => Response.json(outputs.shift()));
  const metadata = await provider.completeStage(run, url, initialPipeline());
  assert.equal(metadata.next?.stage, "audio");
  const audio = await provider.completeStage(run, url, metadata.next!);
  assert.equal(audio.next?.stage, "model");
  assert.equal(audio.evidence.transcript, "Boil tomatoes.");
  assert(!JSON.stringify(audio.evidence).includes("22.336"));
  const model = await provider.completeStage(run, url, audio.next!);
  assert.equal(model.next, null);
  assert.equal(model.review?.draft.ingredients[0]!.quantity, "400");
  assert.equal(model.review?.draft.totalMinutes, null);
});
test("no silent caption-only fallback when audio is missing or belongs to a different video", async () => {
  configure();
  const pipeline: Pipeline = { ...initialPipeline(), stage: "audio", evidence: { caption: "Soup", transcript: null, comments: [] } };
  const provider = new ImportPipelineProvider(async () => Response.json([{ url: "https://www.instagram.com/reel/other/", segments: [] }]));
  await assert.rejects(() => provider.completeStage(run, url, pipeline));
});
