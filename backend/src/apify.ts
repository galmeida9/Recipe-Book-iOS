import { z } from "zod";
import { requiredSetting, invariant, AppError, type Evidence } from "./contracts.js";
import { evidenceSchema } from "./import-evidence.js";

const safeId = z.string().regex(/^[A-Za-z0-9_-]{1,100}$/);
export const runSchema = z.object({
  id: safeId,
  status: z.enum(["READY", "RUNNING", "SUCCEEDED", "FAILED", "TIMING-OUT", "TIMED-OUT", "ABORTING", "ABORTED"]),
  defaultDatasetId: safeId,
  options: z.object({ maxTotalChargeUsd: z.number(), isMaxTotalChargeUsdSetByUser: z.boolean() })
});
const usageSchema = z.object({
  data: z.object({
    usageCycle: z.object({ startAt: z.string().datetime(), endAt: z.string().datetime() }),
    totalUsageCreditsUsdAfterVolumeDiscount: z.number().finite().nonnegative()
  })
});
export type ProviderRun = z.infer<typeof runSchema>;
export interface ProviderBudget {
  month: string; spentMicros: number; endsAt: Date; capMicros: number; reserveMicros: number;
  visibility?: "api-usage" | "verified-free-stop";
  verifiedAt?: string;
}

export function verifiedFreeStopBudget(reserveMicros: number, now = Date.now()): ProviderBudget {
  invariant(process.env["APIFY_FREE_PLAN_VERIFIED"] === "true" && process.env["APIFY_NO_OVERAGES_VERIFIED"] === "true" &&
    process.env["APIFY_BACKEND_LEDGER_VERIFIED"] === "true", 503, "budget_proof", "The restricted-token budget requires a verified Free-plan hard stop and one transactional backend ledger.");
  const timestamp = (name: string) => new Date(z.string().datetime().parse(requiredSetting(name)));
  const verifiedAt = timestamp("APIFY_FREE_STOP_VERIFIED_AT");
  const startsAt = timestamp("APIFY_VERIFIED_CYCLE_START");
  const endsAt = timestamp("APIFY_VERIFIED_CYCLE_END");
  const proofEndsAt = Math.min(endsAt.getTime(), verifiedAt.getTime() + 24 * 60 * 60_000);
  invariant(verifiedAt.getTime() <= now && now - verifiedAt.getTime() <= 24 * 60 * 60_000 &&
    startsAt.getTime() <= verifiedAt.getTime() && verifiedAt.getTime() < endsAt.getTime() &&
    proofEndsAt > now + 15 * 60_000, 503, "budget_proof_stale", "The operator's Free-stop proof is missing, expired, or outside its reviewed billing cycle. Recheck the account's Free hard stop and update the dated proof before importing.");
  const spentMicros = Number(requiredSetting("APIFY_VERIFIED_SPENT_MICROS"));
  const capMicros = Number(requiredSetting("APIFY_PILOT_CAP_MICROS"));
  invariant(Number.isSafeInteger(spentMicros) && spentMicros >= 0 && spentMicros < 5_000_000 &&
    Number.isSafeInteger(capMicros) && capMicros > spentMicros && capMicros <= 1_000_000 &&
    Number.isSafeInteger(reserveMicros) && reserveMicros > 0 && reserveMicros <= capMicros,
  503, "budget_proof", "The explicitly reviewed pilot ledger must be bounded to USD 1 or less, including observed usage and each full job reservation.");
  return {
    month: startsAt.toISOString().slice(0, 7), spentMicros, capMicros, reserveMicros,
    endsAt: new Date(proofEndsAt),
    visibility: "verified-free-stop", verifiedAt: verifiedAt.toISOString()
  };
}

export function approvedProvider(): { actor: string; build: string; reserveMicros: number; inputKey: string } {
  invariant(process.env["APIFY_ENABLED"] === "true"
    && process.env["APIFY_FREE_PLAN_VERIFIED"] === "true"
    && process.env["APIFY_NO_OVERAGES_VERIFIED"] === "true"
    && process.env["APIFY_ACCOUNT_EXCLUSIVE"] === "true",
  503, "provider_not_approved", "Imports are disabled until the provider, free allowance and no-overage limits are verified.");
  const actor = requiredSetting("APIFY_ACTOR_ID");
  invariant(/^[A-Za-z0-9_-]+(?:~[A-Za-z0-9_-]+)?$/.test(actor), 503, "configuration", "Invalid approved actor identifier.");
  const build = requiredSetting("APIFY_ACTOR_BUILD");
  invariant(/^\d+\.\d+\.\d+$/.test(build), 503, "configuration", "Pin a reviewed numeric actor build.");
  const reserveMicros = Number(requiredSetting("APIFY_RUN_CAP_MICROS"));
  invariant(Number.isInteger(reserveMicros) && reserveMicros > 0 && reserveMicros <= 1_000_000,
    503, "configuration", "Run cap must be between one microdollar and USD 1.");
  const inputKey = requiredSetting("APIFY_INPUT_URL_FIELD");
  invariant(/^[A-Za-z][A-Za-z0-9_]{0,60}$/.test(inputKey), 503, "configuration", "Invalid actor input field.");
  return { actor, build, reserveMicros, inputKey };
}

export class ApifyProvider {
  constructor(private readonly transport: typeof fetch = fetch) {}
  protected async request(path: string, method = "GET", body?: unknown): Promise<unknown> {
    const response = await this.transport(`https://api.apify.com/v2/${path}`, {
      method,
      headers: { Authorization: `Bearer ${requiredSetting("APIFY_TOKEN")}`, "Content-Type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(20_000),
      redirect: "error"
    });
    if (!response.ok && !response.headers.get("content-type")?.includes("application/json")) {
      throw new AppError(502, "provider_http", `Import provider returned HTTP ${response.status}.`);
    }
    invariant(response.body, 502, "provider_response", "Import provider returned no response body.");
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        invariant(size <= 2_000_000, 502, "provider_response", "Import provider response exceeded the limit.");
        chunks.push(value);
      }
    } finally { await reader.cancel(); }
    const result: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!response.ok) {
      const failure = z.object({ error: z.object({ type: z.string().regex(/^[a-z0-9-]{1,100}$/) }) }).safeParse(result);
      throw new AppError(502, "provider_http", `Import provider returned HTTP ${response.status}${failure.success ? ` (${failure.data.error.type})` : ""}.`);
    }
    return result;
  }
  async budget(): Promise<ProviderBudget> {
    const config = approvedProvider();
    return this.usageBudget(config.reserveMicros);
  }
  protected async usageBudget(reserveMicros: number): Promise<ProviderBudget> {
    const usage = usageSchema.parse(await this.request("users/me/usage/monthly")).data;
    const now = Date.now();
    const startsAt = new Date(usage.usageCycle.startAt);
    const endsAt = new Date(usage.usageCycle.endAt);
    invariant(startsAt.getTime() <= now && endsAt.getTime() > now + 15 * 60_000,
      503, "budget_cycle", "The provider budget cycle is unavailable or is about to reset.");
    // Leave USD 0.25 for bounded dataset reads/storage outside actor run billing.
    return {
      month: usage.usageCycle.startAt.slice(0, 7),
      spentMicros: Math.ceil(usage.totalUsageCreditsUsdAfterVolumeDiscount * 1_000_000),
      endsAt, capMicros: 4_750_000, reserveMicros, visibility: "api-usage"
    };
  }
  protected async selectedBudget(reserveMicros: number): Promise<ProviderBudget> {
    const mode = process.env["APIFY_BUDGET_MODE"] ?? "api-usage";
    invariant(["api-usage", "verified-free-stop"].includes(mode), 503, "configuration", "Choose an explicit supported provider budget mode.");
    if (mode === "verified-free-stop") return verifiedFreeStopBudget(reserveMicros);
    invariant(process.env["APIFY_ACCOUNT_EXCLUSIVE"] === "true", 503, "budget_proof", "API-usage accounting requires verified account exclusivity.");
    // Permission errors are never converted into an operator-attested budget.
    return this.usageBudget(reserveMicros);
  }
  async start(sourceURL: string, reserveMicros: number): Promise<ProviderRun> {
    const config = approvedProvider();
    invariant(reserveMicros === config.reserveMicros, 503, "provider_changed", "The approved provider price cap changed.");
    const parameters = new URLSearchParams({
      build: config.build, timeout: "300", memory: "256", maxItems: "1",
      maxTotalChargeUsd: (reserveMicros / 1_000_000).toFixed(6),
      restartOnError: "false", forcePermissionLevel: "LIMITED_PERMISSIONS"
    });
    const input = { [config.inputKey]: [sourceURL] };
    const result = z.object({ data: runSchema }).parse(await this.request(`actors/${config.actor}/runs?${parameters}`, "POST", input)).data;
    invariant(result.options.isMaxTotalChargeUsdSetByUser
      && result.options.maxTotalChargeUsd <= reserveMicros / 1_000_000,
    502, "provider_cap", "The provider did not confirm the requested spending cap.");
    return result;
  }
  async run(id: string): Promise<ProviderRun> {
    safeId.parse(id);
    return z.object({ data: runSchema }).parse(await this.request(`actor-runs/${id}`)).data;
  }
  async abort(id: string): Promise<void> {
    safeId.parse(id);
    await this.request(`actor-runs/${id}/abort`, "POST");
  }
  async evidence(run: ProviderRun): Promise<Evidence> {
    safeId.parse(run.defaultDatasetId);
    const result = z.array(z.record(z.unknown())).min(1).max(1)
      .parse(await this.request(`datasets/${run.defaultDatasetId}/items?limit=1&clean=true`));
    const item = result[0]!;
    const field = (setting: string): unknown => {
      const path = process.env[setting];
      if (!path) return null;
      invariant(/^[A-Za-z][A-Za-z0-9_]{0,60}$/.test(path), 503, "configuration", "Evidence mappings must be reviewed top-level fields.");
      return item[path] ?? null;
    };
    const comments = field("APIFY_OUTPUT_COMMENTS_FIELD");
    const evidence = evidenceSchema.safeParse({
      caption: field("APIFY_OUTPUT_CAPTION_FIELD"),
      comments: comments ?? [],
      transcript: field("APIFY_OUTPUT_TRANSCRIPT_FIELD")
    });
    if (!evidence.success) throw new AppError(502, "provider_shape", "Provider evidence did not match the reviewed caption/comments/transcript contract.");
    return evidence.data;
  }
}
