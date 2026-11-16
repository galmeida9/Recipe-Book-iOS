import { z } from "zod";
import { createHash } from "node:crypto";
import { ApifyProvider, runSchema, type ProviderRun } from "./apify.js";
import { canonicalReelURL, invariant, requiredSetting, type Evidence } from "./contracts.js";
import { evidenceSchema } from "./import-evidence.js";
import { extractionInput, extractionJSONSchema, extractionRules, validateExtraction } from "./recipe-extraction.js";
import { approvedGemini, GeminiExtractor } from "./gemini.js";
import { approvedAzureModel, AzureRecipeExtractor } from "./azure-extraction.js";

export const pipelineSchema = z.object({
  stage: z.enum(["metadata", "audio", "model"]),
  evidence: evidenceSchema.nullable(),
  thumbnailURL: z.string().max(8192).nullable().default(null),
  configuration: z.string().regex(/^[a-f0-9]{64}$/),
  runs: z.array(z.string().regex(/^[A-Za-z0-9_-]{1,100}$/)).max(3),
  resumedFrom: z.string().uuid().optional()
}).strict();
export type Pipeline = z.infer<typeof pipelineSchema>;
const configuration = () => createHash("sha256").update(JSON.stringify(approvedPipeline())).digest("hex");
export const initialPipeline = (): Pipeline => ({ stage: "metadata", evidence: null, thumbnailURL: null, runs: [], configuration: configuration() });
const stageActors = {
  metadata: "apify~instagram-reel-scraper",
  audio: "apple_yang~instagram-transcripts-scraper",
  model: "fayoussef~bulk-llm-runner"
} as const;
export function reviewedPipeline() {
  invariant(["APIFY_FREE_PLAN_VERIFIED", "APIFY_NO_OVERAGES_VERIFIED", "APIFY_BACKEND_LEDGER_VERIFIED",
    "APIFY_PIPELINE_REVIEW_ACKNOWLEDGED", "APIFY_PIPELINE_PRICING_VERIFIED"].every(name => process.env[name] === "true"),
  503, "provider_not_approved", "Instagram imports are disabled until account limits and pricing are verified and the operator acknowledges the provider/data review.");
  const modelProvider = process.env["MODEL_PROVIDER"] ?? "apify";
  invariant(["apify", "gemini-free", "azure-credits"].includes(modelProvider), 503, "configuration", "Select an explicitly reviewed model provider.");
  if (modelProvider === "gemini-free") approvedGemini();
  const stages = Object.fromEntries(Object.keys(stageActors).map(key => {
    const stage = key as keyof typeof stageActors;
    if (stage === "model" && modelProvider === "gemini-free") return [stage, { actor: "gemini-free", build: "gemini-2.5-flash-lite", cap: 0 }];
    if (stage === "model" && modelProvider === "azure-credits") {
      const model = approvedAzureModel();
      return [stage, { actor: "azure-credits", build: `${model.model}-${model.version}`, cap: model.cap }];
    }
    const build = requiredSetting(`APIFY_${stage.toUpperCase()}_BUILD`);
    const cap = Number(requiredSetting(`APIFY_${stage.toUpperCase()}_CAP_MICROS`));
    invariant(/^\d+\.\d+\.\d+$/.test(build) && Number.isSafeInteger(cap) && cap > 0 && cap <= 1_000_000,
      503, "configuration", "Each reviewed actor needs a pinned numeric build and bounded hard charge cap.");
    return [stage, { actor: stageActors[stage], build, cap }];
  })) as Record<Pipeline["stage"], { actor: string; build: string; cap: number }>;
  const reserveMicros = stages.metadata.cap + stages.audio.cap + stages.model.cap;
  invariant(reserveMicros <= 1_000_000, 503, "configuration", "The entire three-stage import must be capped at USD 1 or less.");
  return { stages, reserveMicros, modelProvider };
}
export function approvedPipeline() {
  invariant(process.env["APIFY_ENABLED"] === "true", 503, "provider_not_approved", "Instagram imports are disabled.");
  return reviewedPipeline();
}
export class ImportPipelineProvider extends ApifyProvider {
  override async budget() { return this.selectedBudget(approvedPipeline().reserveMicros); }
  async preflightBudget() { return this.selectedBudget(reviewedPipeline().reserveMicros); }
  async preflightAccess(): Promise<string[]> {
    const config = reviewedPipeline();
    const accessible: string[] = [];
    for (const stage of Object.values(config.stages)) {
      if (["gemini-free", "azure-credits"].includes(stage.actor)) continue;
      z.object({ data: z.object({ items: z.array(z.object({ id: z.string() })).max(1) }) })
        .parse(await this.request(`actors/${stage.actor}/runs?limit=1&desc=true`));
      accessible.push(stage.actor);
    }
    return accessible;
  }
  async extractDirect(sourceURL: string, pipeline: Pipeline) {
    const config = reviewedPipeline();
    invariant(config.modelProvider !== "apify", 503, "configuration", "A reviewed direct model is not selected.");
    invariant(pipeline.configuration === configuration() && pipeline.evidence, 503, "provider_changed", "The reviewed model configuration or cached evidence changed.");
    return config.modelProvider === "azure-credits" ? new AzureRecipeExtractor().extract(sourceURL, pipeline.evidence)
      : new GeminiExtractor().extract(sourceURL, pipeline.evidence);
  }
  async startStage(sourceURL: string, pipeline: Pipeline, reservation: number): Promise<ProviderRun> {
    const config = approvedPipeline();
    invariant(pipeline.stage !== "model" || config.modelProvider === "apify", 503, "configuration", "The direct free model is not an Apify actor run.");
    invariant(pipeline.configuration === configuration(), 503, "provider_changed", "The reviewed provider configuration changed; no new stage was charged.");
    invariant(reservation === config.reserveMicros, 503, "provider_changed", "The approved import spending cap changed.");
    const source = canonicalReelURL(sourceURL);
    const stage = config.stages[pipeline.stage];
    let input: Record<string, unknown>;
    if (pipeline.stage === "metadata") input = {
      username: [source], resultsLimit: 1, includeSharesCount: false, includeTranscript: false, includeDownloadedVideo: false
    };
    else if (pipeline.stage === "audio") input = {
      videoUrl: source, bulkUrls: [], usernames: [], resultsLimit: 1, enhancedcrawl: false, includeSharesCount: false
    };
    else {
      invariant(pipeline.evidence, 502, "evidence_missing", "Transcription has not completed.");
      const evidence = extractionInput(source, pipeline.evidence);
      input = {
        model: "google/gemini-2.5-flash-lite", custom_model: "", compare_models: [], fallback_models: [],
        prompts: [extractionRules + "\nInput:\n" + JSON.stringify(evidence)], system_prompt: extractionRules,
        enable_web_search: false, enable_file_parser: false, image_urls: [], checklist_items: [],
        max_retries: 0, concurrency: 1, temperature: 0, max_tokens: 6000, response_format: "json_schema",
        json_schema: extractionJSONSchema(evidence.evidence.map(item => item.id))
      };
    }
    const parameters = new URLSearchParams({
      build: stage.build, timeout: "180", memory: pipeline.stage === "audio" ? "512" : "256", maxItems: "1",
      maxTotalChargeUsd: (stage.cap / 1_000_000).toFixed(6), restartOnError: "false",
      forcePermissionLevel: "LIMITED_PERMISSIONS"
    });
    const run = z.object({ data: runSchema }).parse(await this.request(`actors/${stage.actor}/runs?${parameters}`, "POST", input)).data;
    if (!run.options.isMaxTotalChargeUsdSetByUser || run.options.maxTotalChargeUsd <= 0 ||
      run.options.maxTotalChargeUsd > stage.cap / 1_000_000) {
      await this.abort(run.id);
      invariant(false, 502, "provider_cap", "The actor did not confirm the requested spending cap; cancellation was requested and it must not be retried.");
    }
    return run;
  }
  private async result(run: ProviderRun): Promise<Record<string, unknown>> {
    const rows = z.array(z.record(z.unknown())).length(1).parse(
      await this.request(`datasets/${run.defaultDatasetId}/items?limit=2&clean=true`));
    return rows[0]!;
  }
  async completeStage(run: ProviderRun, sourceURL: string, pipeline: Pipeline): Promise<{
    next: Pipeline | null; evidence: Evidence; review: ReturnType<typeof validateExtraction> | null
  }> {
    const item = await this.result(run);
    if (pipeline.stage === "metadata") {
      invariant(typeof item["url"] === "string" && samePost(item["url"], sourceURL) && !item["error"],
        502, "provider_source", "Instagram metadata did not match the requested public video.");
      const metadata = z.object({
        caption: z.string().max(40_000).nullable().optional(),
        displayUrl: z.string().max(8192).optional(),
        latestComments: z.array(z.object({ text: z.string().max(10_000) })).max(100).optional()
      }).parse(item);
      const evidence = evidenceSchema.parse({
        caption: metadata.caption ?? null, transcript: null, comments: (metadata.latestComments ?? []).slice(0, 20).map(comment => comment.text)
      });
      return { next: { ...pipeline, stage: "audio", evidence, thumbnailURL: metadata.displayUrl ?? null }, evidence, review: null };
    }
    invariant(pipeline.evidence, 502, "evidence_missing", "The prior stage's evidence is missing.");
    if (pipeline.stage === "audio") {
      const transcript = z.object({
        url: z.string(), errMsg: z.string().optional(), segments: z.array(z.object({
          start: z.number().nonnegative(), end: z.number().nonnegative(), text: z.string().trim().min(1).max(4000)
        })).min(1).max(500)
      }).parse(item);
      invariant(samePost(transcript.url, sourceURL) && !transcript.errMsg &&
        transcript.segments.every(segment => segment.end >= segment.start),
      502, "provider_transcript", "Audio transcription did not match the requested video.");
      const evidence = evidenceSchema.parse({ ...pipeline.evidence, transcript: transcript.segments.map(segment => segment.text).join("\n") });
      // Only text, not video duration/ASR offsets, is passed to the model.
      extractionInput(sourceURL, evidence);
      return { next: { ...pipeline, stage: "model", evidence }, evidence, review: null };
    }
    if (typeof item["error"] === "string" && item["error"].includes('"actor-restricted-access-permission-mode-not-supported"')) {
      invariant(false, 502, "provider_model_unavailable",
        "The model provider does not support the restricted runtime token. No recipe was generated and no automatic paid retry was made.");
    }
    invariant(item["model"] === "google/gemini-2.5-flash-lite" && item["error"] == null &&
      Array.isArray(item["tools_used"]) && item["tools_used"].length === 0 &&
      Array.isArray(item["tool_calls"]) && item["tool_calls"].length === 0,
    502, "provider_model", "The extraction provider changed model, used tools, or reported an error.");
    const input = extractionInput(sourceURL, pipeline.evidence);
    invariant(typeof item["response"] === "string", 502, "provider_model", "The model did not return a JSON response.");
    const review = validateExtraction(JSON.parse(item["response"]), sourceURL, input.evidence);
    return { next: null, evidence: { ...pipeline.evidence, warnings: review.warnings,
      sources: input.evidence, extraction: review.extraction }, review };
  }
}
function samePost(actual: string, expected: string): boolean {
  try {
    const url = new URL(actual);
    const wanted = new URL(canonicalReelURL(expected));
    return url.protocol === "https:" && ["instagram.com", "www.instagram.com"].includes(url.hostname) &&
      !url.port && !url.username && !url.password && /^\/(?:p|reel)\/[A-Za-z0-9_-]+\/?$/.test(url.pathname) &&
      url.pathname.split("/")[2] === wanted.pathname.split("/")[2];
  } catch { return false; }
}
