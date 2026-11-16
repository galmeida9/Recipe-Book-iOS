import test from "node:test";
import assert from "node:assert/strict";
import { approvedAzureModel, AzureRecipeExtractor } from "../src/azure-extraction.js";

function configure() {
  Object.assign(process.env, {
    AZURE_MODEL_CREDITS_VERIFIED: "true", AZURE_MODEL_SPENDING_LIMIT_VERIFIED: "true", AZURE_MODEL_DEPLOYMENT_VERIFIED: "true",
    AZURE_OPENAI_ENDPOINT: "https://synthetic-model.openai.azure.com/", AZURE_OPENAI_DEPLOYMENT: "recipe-extractor",
    AZURE_MODEL_RUN_CAP_MICROS: "50000"
  });
}
const url = "https://www.instagram.com/reel/publicRecipe/";
const evidence = { caption: "400 g tomatoes; Boil tomatoes for 8-10 minutes.", transcript: null, comments: [] };
const output = () => ({
  id: "synthetic-response", model: "gpt-4.1-mini-2025-04-14",
  usage: { prompt_tokens: 500, completion_tokens: 300 },
  choices: [{ finish_reason: "stop", message: { content: JSON.stringify({
    title: "Tomatoes", source_url: url, servings: null, total_minutes: null, requires_review: true, warnings: [],
    ingredients: [{ name: "tomatoes", quantity: 400, unit: "g", notes: null, evidence_ids: ["C0"] }],
    steps: [{ instruction: "Boil tomatoes for 8-10 minutes.", duration_minutes_min: 8, duration_minutes_max: 10, temperature_c: null, evidence_ids: ["C0"] }]
  }), refusal: null, tool_calls: [] } }]
});
test("Azure extraction requires actual credit/limit/deployment review and rejects arbitrary hosts", () => {
  configure();
  delete process.env["AZURE_MODEL_SPENDING_LIMIT_VERIFIED"];
  assert.throws(() => approvedAzureModel(), /requires verified/);
  configure();
  process.env["AZURE_OPENAI_ENDPOINT"] = "https://unrelated.invalid/";
  assert.throws(() => approvedAzureModel(), /owned Azure/);
});
test("MI-only fixed model request is schema constrained, byte/token/cost bounded and makes one call", async () => {
  configure();
  let calls = 0;
  const provider = new AzureRecipeExtractor(async (input, options) => {
    calls++;
    assert.equal(String(input), "https://synthetic-model.openai.azure.com/openai/deployments/recipe-extractor/chat/completions?api-version=2024-10-21");
    const headers = new Headers(options?.headers);
    assert.equal(headers.get("authorization"), "Bearer synthetic-mi-token");
    assert.equal(headers.get("api-key"), null);
    const body = JSON.parse(String(options?.body));
    assert.equal(body.max_tokens, 6000);
    assert.equal(body.n, 1);
    assert.equal(body.temperature, 0);
    assert.equal(body.tools, undefined);
    assert.equal(body.response_format.json_schema.strict, true);
    return Response.json(output());
  }, async () => "synthetic-mi-token");
  const result = await provider.extract(url, evidence);
  assert.equal(result.review.draft.ingredients[0]!.quantity, "400");
  assert.equal(result.evidence.modelExecution.provider, "azure-credits");
  assert.equal(result.evidence.modelExecution.inputTokens, 500);
  assert.equal(calls, 1);
});
test("oversized input, rate limits and mismatched/refused/truncated results fail without a second paid attempt", async () => {
  configure();
  let calls = 0;
  const limited = new AzureRecipeExtractor(async () => { calls++; return Response.json({}, { status: 429 }); }, async () => "synthetic");
  await assert.rejects(() => limited.extract(url, evidence), /No paid fallback or automatic retry/);
  assert.equal(calls, 1);
  await assert.rejects(() => limited.extract(url, { ...evidence, caption: "tomatoes ".repeat(3500) }), /request\/cost bound/);
  assert.equal(calls, 1);
  for (const change of [
    (value: ReturnType<typeof output>) => { value.model = "different-model"; },
    (value: ReturnType<typeof output>) => { value.choices[0]!.finish_reason = "length"; }
  ]) {
    const value = output(); change(value);
    await assert.rejects(() => new AzureRecipeExtractor(async () => Response.json(value), async () => "synthetic").extract(url, evidence));
  }
});
test("completed model output is journaled before semantic validation, avoiding a paid rerun to inspect a rejection", async () => {
  configure();
  const value = output();
  const recipe = JSON.parse(value.choices[0]!.message.content);
  recipe.ingredients[0].name = "unsupported sugar";
  value.choices[0]!.message.content = JSON.stringify(recipe);
  let preserved = "";
  const provider = new AzureRecipeExtractor(async () => Response.json(value), async () => "synthetic");
  await assert.rejects(() => provider.extract(url, evidence, async result => { preserved = result.response; }), /ingredient is not supported/);
  assert.match(preserved, /unsupported sugar/);
});
