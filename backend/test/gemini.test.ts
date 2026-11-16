import test from "node:test";
import assert from "node:assert/strict";
import { approvedGemini, GeminiExtractor } from "../src/gemini.js";
import { reviewedPipeline } from "../src/import-pipeline.js";

function configure() {
  Object.assign(process.env, {
    GEMINI_FREE_TIER_VERIFIED: "true", GEMINI_NO_BILLING_VERIFIED: "true", GEMINI_PUBLIC_EVIDENCE_ACKNOWLEDGED: "true",
    GEMINI_API_KEY: "synthetic-private-key"
  });
}
const url = "https://www.instagram.com/reel/publicRecipe/";
const evidence = { caption: "400 g tomatoes; Boil tomatoes for 8-10 minutes.", transcript: "Boil tomatoes.", comments: [] };
const output = () => ({
  modelVersion: "gemini-2.5-flash-lite", responseId: "synthetic-response",
  usageMetadata: { promptTokenCount: 400, candidatesTokenCount: 300, totalTokenCount: 700 },
  candidates: [{ finishReason: "STOP", content: { parts: [{ text: JSON.stringify({
    title: "Tomatoes", source_url: url, servings: null, total_minutes: null, requires_review: true, warnings: [],
    ingredients: [{ name: "tomatoes", quantity: 400, unit: "g", notes: null, evidence_ids: ["C0"] }],
    steps: [{ instruction: "Boil tomatoes for 8-10 minutes.", duration_minutes_min: 8, duration_minutes_max: 10,
      temperature_c: null, evidence_ids: ["C0"] }]
  }) }] } }]
});
test("direct generation is disabled unless actual unbilled Free tier and public-source processing are acknowledged", () => {
  configure();
  delete process.env["GEMINI_NO_BILLING_VERIFIED"];
  assert.throws(() => approvedGemini(), /disabled/);
});
test("direct Flash Lite uses private header, bounded JSON/schema and no tools, retries, media or paid relay", async () => {
  configure();
  let calls = 0;
  const provider = new GeminiExtractor(async (input, options) => {
    calls++;
    assert.equal(String(input), "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent");
    const headers = new Headers(options?.headers);
    assert.equal(headers.get("x-goog-api-key"), "synthetic-private-key");
    assert(!String(input).includes("key="));
    assert.equal(options?.redirect, "error");
    const body = JSON.parse(String(options?.body));
    assert.equal(body.generationConfig.maxOutputTokens, 6000);
    assert.equal(body.generationConfig.candidateCount, 1);
    assert.equal(body.generationConfig.responseMimeType, "application/json");
    assert.equal(body.generationConfig.thinkingConfig.thinkingBudget, 0);
    assert.equal(body.tools, undefined);
    assert(JSON.stringify(body.generationConfig.responseJsonSchema).includes('"enum":["C0","T1"]'));
    return Response.json(output());
  });
  const result = await provider.extract(url, evidence);
  assert.equal(calls, 1);
  assert.equal(result.review.draft.ingredients[0]!.quantity, "400");
  assert.equal(result.review.draft.servings, null);
  assert.equal(result.evidence.modelExecution.inputTokens, 400);
});
test("free-tier 429 and malformed/truncated/tool/refusal responses never retry or produce a success-shaped draft", async () => {
  configure();
  let calls = 0;
  const quota = new GeminiExtractor(async () => { calls++; return Response.json({ error: "quota" }, { status: 429 }); });
  await assert.rejects(() => quota.extract(url, evidence), /free.*quota is exhausted/);
  assert.equal(calls, 1);
  for (const change of [
    (value: ReturnType<typeof output>) => { value.candidates[0]!.finishReason = "MAX_TOKENS"; },
    (value: ReturnType<typeof output>) => { value.modelVersion = "another-model"; },
    (value: ReturnType<typeof output>) => { value.candidates[0]!.content.parts[0]!.text = "not json"; }
  ]) {
    const value = output(); change(value);
    const provider = new GeminiExtractor(async () => Response.json(value));
    await assert.rejects(() => provider.extract(url, evidence));
  }
});
test("direct model reserves only bounded Apify metadata/ASR and no obsolete relay permissions or fee", () => {
  configure();
  Object.assign(process.env, {
    MODEL_PROVIDER: "gemini-free", APIFY_FREE_PLAN_VERIFIED: "true", APIFY_NO_OVERAGES_VERIFIED: "true",
    APIFY_BACKEND_LEDGER_VERIFIED: "true", APIFY_PIPELINE_REVIEW_ACKNOWLEDGED: "true", APIFY_PIPELINE_PRICING_VERIFIED: "true",
    APIFY_METADATA_BUILD: "0.0.653", APIFY_AUDIO_BUILD: "0.0.83", APIFY_METADATA_CAP_MICROS: "10000", APIFY_AUDIO_CAP_MICROS: "20000"
  });
  delete process.env["APIFY_MODEL_BUILD"];
  delete process.env["APIFY_MODEL_CAP_MICROS"];
  const config = reviewedPipeline();
  assert.equal(config.reserveMicros, 30_000);
  assert.equal(config.stages.model.cap, 0);
  assert.equal(config.modelProvider, "gemini-free");
});
