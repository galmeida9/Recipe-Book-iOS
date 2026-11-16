import { DefaultAzureCredential } from "@azure/identity";
import { z } from "zod";
import { AppError, invariant, requiredSetting, type Evidence } from "./contracts.js";
import { extractionInput, extractionJSONSchema, extractionRules, validateExtraction } from "./recipe-extraction.js";

const model = "gpt-4.1-mini";
const version = "2025-04-14";
export function approvedAzureModel() {
  invariant(["AZURE_MODEL_CREDITS_VERIFIED", "AZURE_MODEL_SPENDING_LIMIT_VERIFIED", "AZURE_MODEL_DEPLOYMENT_VERIFIED"]
    .every(name => process.env[name] === "true"), 503, "azure_model_not_approved",
  "Azure model extraction requires verified credit eligibility, spending hard stop and the bounded managed-identity deployment.");
  const endpoint = new URL(requiredSetting("AZURE_OPENAI_ENDPOINT"));
  invariant(endpoint.protocol === "https:" && /^[a-z0-9-]+\.openai\.azure\.com$/.test(endpoint.hostname) &&
    !endpoint.port && !endpoint.username && !endpoint.password && !endpoint.search && !endpoint.hash && endpoint.pathname === "/",
  503, "configuration", "Use the reviewed owned Azure OpenAI HTTPS endpoint.");
  const deployment = requiredSetting("AZURE_OPENAI_DEPLOYMENT");
  invariant(/^[a-zA-Z0-9_-]{1,60}$/.test(deployment), 503, "configuration", "The model deployment name is invalid.");
  const cap = Number(requiredSetting("AZURE_MODEL_RUN_CAP_MICROS"));
  invariant(Number.isSafeInteger(cap) && cap >= 20_000 && cap <= 50_000, 503, "model_cap",
    "Azure extraction must reserve a verified hard upper estimate between USD 0.02 and USD 0.05.");
  return { endpoint: endpoint.toString(), deployment, model, version, cap };
}
export class AzureRecipeExtractor {
  constructor(private readonly transport: typeof fetch = fetch,
    private readonly token: () => Promise<string> = async () => {
      const credential = new DefaultAzureCredential();
      const access = await credential.getToken("https://cognitiveservices.azure.com/.default");
      invariant(access?.token, 503, "model_identity", "The workload managed identity could not obtain a model access token.");
      return access.token;
    }) {}
  private async request(path: string, method: "GET" | "POST", body?: unknown): Promise<unknown> {
    const config = approvedAzureModel();
    const payload = body === undefined ? undefined : JSON.stringify(body);
    if (payload) {
      const upperInputTokens = Buffer.byteLength(payload) + 1024;
      invariant(Buffer.byteLength(payload) <= 24_000 &&
        Math.ceil(upperInputTokens * 0.4 + 6000 * 1.6) <= config.cap,
      422, "model_input_limit", "Recipe evidence exceeds the reviewed model request/cost bound.");
    }
    const response = await this.transport(new URL(path, config.endpoint), {
      method, redirect: "error", signal: AbortSignal.timeout(method === "POST" ? 90_000 : 20_000),
      headers: { Authorization: `Bearer ${await this.token()}`, "Content-Type": "application/json" },
      ...(payload === undefined ? {} : { body: payload })
    });
    if (response.status === 429) throw new AppError(429, "model_rate_limit", "The model's bounded capacity or credit allowance is unavailable. No paid fallback or automatic retry was made.");
    invariant(response.ok, 502, "model_http", `The managed-identity model request returned HTTP ${response.status}; no automatic retry was made.`);
    invariant(response.body, 502, "model_response", "The model returned no response.");
    const reader = response.body.getReader(), chunks: Uint8Array[] = [];
    let size = 0;
    try {
      for (;;) {
        const part = await reader.read();
        if (part.done) break;
        size += part.value.length;
        invariant(size <= 500_000, 502, "model_response", "The model response exceeded its bounded size.");
        chunks.push(part.value);
      }
    } finally { await reader.cancel(); }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  }
  async preflight() {
    z.object({ data: z.array(z.object({ id: z.string() })) }).parse(await this.request("openai/models?api-version=2024-10-21", "GET"));
    return { model, version, reachable: true, billing: "verified-Azure-credits-token-consumption" };
  }
  async extract(sourceURL: string, evidence: Evidence) {
    const config = approvedAzureModel();
    const input = extractionInput(sourceURL, evidence);
    const response = z.object({
      id: z.string().max(200), model: z.literal(`${model}-${version}`),
      usage: z.object({ prompt_tokens: z.number().int().nonnegative(), completion_tokens: z.number().int().nonnegative() }),
      choices: z.array(z.object({
        finish_reason: z.literal("stop"),
        message: z.object({ content: z.string().max(400_000), refusal: z.string().nullable().optional(),
          tool_calls: z.array(z.unknown()).max(0).optional(), function_call: z.unknown().optional() })
      })).length(1)
    }).parse(await this.request(`openai/deployments/${config.deployment}/chat/completions?api-version=2024-10-21`, "POST", {
      messages: [{ role: "system", content: extractionRules }, { role: "user", content: extractionRules + "\nInput:\n" + JSON.stringify(input) }],
      temperature: 0, max_tokens: 6000, n: 1,
      response_format: { type: "json_schema", json_schema: {
        name: "evidence_grounded_recipe", strict: true, schema: extractionJSONSchema(input.evidence.map(item => item.id))
      } }
    }));
    const message = response.choices[0]!.message;
    invariant(!message.refusal && !message.function_call, 502, "model_refusal", "The model refused extraction or returned an unsupported function call.");
    const review = validateExtraction(JSON.parse(message.content), sourceURL, input.evidence);
    return { review, evidence: { ...evidence, sources: input.evidence, extraction: review.extraction, warnings: review.warnings,
      modelExecution: { provider: "azure-credits" as const, model: response.model, requestId: response.id,
        inputTokens: response.usage.prompt_tokens, outputTokens: response.usage.completion_tokens } } };
  }
}
