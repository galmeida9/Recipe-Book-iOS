import { z } from "zod";
import { AppError, invariant, requiredSetting, type Evidence } from "./contracts.js";
import { extractionInput, extractionJSONSchema, extractionRules, validateExtraction } from "./recipe-extraction.js";

const model = "gemini-2.5-flash-lite";
const root = `https://generativelanguage.googleapis.com/v1beta/models/${model}`;
export function approvedGemini() {
  invariant(["GEMINI_FREE_TIER_VERIFIED", "GEMINI_NO_BILLING_VERIFIED", "GEMINI_PUBLIC_EVIDENCE_ACKNOWLEDGED"]
    .every(name => process.env[name] === "true"), 503, "gemini_not_approved",
  "Direct model extraction is disabled until the unbilled Free tier and public-evidence data policy are reviewed.");
  return { model, endpoint: root + ":generateContent" };
}
export class GeminiExtractor {
  constructor(private readonly transport: typeof fetch = fetch) {}
  private async request(method: "GET" | "POST", body?: unknown): Promise<unknown> {
    approvedGemini();
    const response = await this.transport(root + (method === "POST" ? ":generateContent" : ""), {
      method, redirect: "error", signal: AbortSignal.timeout(method === "POST" ? 90_000 : 20_000),
      headers: { "x-goog-api-key": requiredSetting("GEMINI_API_KEY"), "Content-Type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    });
    if (response.status === 429) throw new AppError(429, "model_quota_exhausted", "The free transcription-to-recipe model quota is exhausted. No paid fallback or automatic retry was started.");
    invariant(response.ok, 502, "model_http", `The free model returned HTTP ${response.status}; no automatic retry was made.`);
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
    const result = z.object({ name: z.literal(`models/${model}`), supportedGenerationMethods: z.array(z.string()) })
      .parse(await this.request("GET"));
    invariant(result.supportedGenerationMethods.includes("generateContent"), 503, "model_unavailable", "The reviewed free model does not support recipe generation.");
    return { model, reachable: true, billing: "operator-verified-unbilled-free-tier" };
  }
  async extract(sourceURL: string, evidence: Evidence) {
    const input = extractionInput(sourceURL, evidence);
    const output = z.object({
      modelVersion: z.string(),
      responseId: z.string().max(200).optional(),
      usageMetadata: z.object({ promptTokenCount: z.number().int().nonnegative().optional(),
        candidatesTokenCount: z.number().int().nonnegative().optional(), totalTokenCount: z.number().int().nonnegative().optional() }).optional(),
      candidates: z.array(z.object({
        finishReason: z.literal("STOP"), groundingMetadata: z.unknown().optional(),
        content: z.object({ parts: z.array(z.object({ text: z.string().max(400_000), thought: z.boolean().optional() }).strict()).length(1) })
      })).length(1)
    }).parse(await this.request("POST", {
      systemInstruction: { parts: [{ text: extractionRules }] },
      contents: [{ role: "user", parts: [{ text: extractionRules + "\nInput:\n" + JSON.stringify(input) }] }],
      generationConfig: { candidateCount: 1, temperature: 0, maxOutputTokens: 6000, responseMimeType: "application/json",
        responseJsonSchema: extractionJSONSchema(input.evidence.map(item => item.id)), thinkingConfig: { thinkingBudget: 0 } }
    }));
    invariant(output.modelVersion === model || output.modelVersion.startsWith(model + "-"), 502, "model_changed", "The response did not come from the selected model.");
    const candidate = output.candidates[0]!;
    invariant(!candidate.groundingMetadata && candidate.content.parts[0]!.thought !== true,
      502, "model_tools", "Unexpected model grounding or tool output was refused.");
    const review = validateExtraction(JSON.parse(candidate.content.parts[0]!.text), sourceURL, input.evidence);
    return { review, evidence: { ...evidence, sources: input.evidence, extraction: review.extraction, warnings: review.warnings,
      modelExecution: { provider: "gemini-free" as const, model: output.modelVersion, requestId: output.responseId ?? null,
        inputTokens: output.usageMetadata?.promptTokenCount ?? null, outputTokens: output.usageMetadata?.candidatesTokenCount ?? null } } };
  }
}
