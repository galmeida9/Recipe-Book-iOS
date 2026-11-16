import { randomUUID } from "node:crypto";
import type sql from "mssql";
import { z } from "zod";
import { AppError, assertVersion, canonicalReelURL, draftSchema, idSchema, invariant, type ImportJob, type Evidence, type Principal, type RecipeDraft } from "./contracts.js";
import { query, serializable } from "./database.js";
import { account, bindCover, bookAccess, RecipeBookService } from "./service.js";
import { type ProviderBudget } from "./apify.js";
import { evidenceSchema } from "./import-evidence.js";
import { ImportPipelineProvider, approvedPipeline, initialPipeline, pipelineSchema } from "./import-pipeline.js";
import type { ImportDelivery } from "./queue.js";
import { downloadInstagramCover } from "./import-cover.js";
import { uploadRecipeImage } from "./images.js";

export function reserveBudget(spent: number, reserved: number, cap: number, amount: number): number {
  invariant([spent, reserved, cap, amount].every(Number.isSafeInteger) && spent >= 0 && reserved >= 0 && amount > 0,
    503, "budget_invalid", "Import budget accounting is invalid.");
  invariant(spent + reserved + amount <= cap, 429, "budget_exhausted", "The shared monthly import allowance is exhausted.");
  return reserved + amount;
}
interface JobRow {
  id: string; userId: string; sourceURL: string; state: ImportJob["state"]; draft: string | null;
  evidence: string | null; error: string | null; version: number; createdAt: Date;
  recipeId: string | null; bookId: string | null; budgetMonth: string; reservedMicros: number;
  providerRunId: string | null; dispatchStarted: boolean; dispatchStartedAt: Date | null; deadline: Date;
  pipelineData: string | null;
  destinationBookId: string | null; reviewSeenVersion: number;
  operatorOnly: boolean; supersededById: string | null;
}
const columns = `CONVERT(varchar(36),Id) AS id,CONVERT(varchar(36),UserId) AS userId,SourceURL AS sourceURL,
 State AS state,Draft AS draft,Evidence AS evidence,Error AS error,Version AS version,CreatedAt AS createdAt,
 CONVERT(varchar(36),CompletedRecipeId) AS recipeId,CONVERT(varchar(36),CompletedBookId) AS bookId,
 BudgetMonth AS budgetMonth,ReservedMicros AS reservedMicros,ProviderRunId AS providerRunId,
 DispatchStarted AS dispatchStarted,DispatchStartedAt AS dispatchStartedAt,Deadline AS deadline,PipelineData AS pipelineData,
 CONVERT(varchar(36),DestinationBookId) AS destinationBookId,ReviewSeenVersion AS reviewSeenVersion,
 OperatorOnly AS operatorOnly,CONVERT(varchar(36),SupersededById) AS supersededById`;
function job(row: JobRow): ImportJob {
  return {
    id: row.id.toLowerCase(), sourceURL: row.sourceURL, state: row.state, version: row.version,
    draft: row.draft === null ? null : draftSchema.parse(JSON.parse(row.draft)),
    evidence: row.evidence === null ? null : evidenceSchema.parse(JSON.parse(row.evidence)),
    error: row.error, createdAt: row.createdAt.toISOString(),
    recipeId: row.recipeId?.toLowerCase() ?? null, bookId: row.bookId?.toLowerCase() ?? null,
    destinationBookId: row.destinationBookId?.toLowerCase() ?? null,
    stage: row.state === "running" ? row.pipelineData ? pipelineSchema.parse(JSON.parse(row.pipelineData)).stage : "metadata" : row.state,
    isUnseen: row.state === "review" && row.reviewSeenVersion < row.version
  };
}
async function getJob(transaction: sql.Transaction, id: string, userId: string): Promise<JobRow> {
  const rows = await query<JobRow>(transaction,
    `SELECT ${columns} FROM dbo.ImportJobs WITH(UPDLOCK,HOLDLOCK) WHERE Id=@id AND UserId=@userId`, { id, userId });
  invariant(rows[0], 404, "import_not_found", "Import job not found.");
  if (rows[0].destinationBookId) await bookAccess(transaction, rows[0].destinationBookId, userId);
  return rows[0];
}
async function reserve(transaction: sql.Transaction, budget: ProviderBudget): Promise<void> {
  const rows = await query<{ spent: number; reserved: number; cap: number }>(transaction,
    "SELECT SpentMicros AS spent,ReservedMicros AS reserved,CapMicros AS cap FROM dbo.ImportBudget WITH(UPDLOCK,HOLDLOCK) WHERE Month=@month",
    { month: budget.month });
  if (!rows[0]) {
    reserveBudget(budget.spentMicros, 0, budget.capMicros, budget.reserveMicros);
    await query(transaction, "INSERT dbo.ImportBudget(Month,CapMicros,SpentMicros,ReservedMicros) VALUES(@month,@cap,@spent,@reserve)",
      { month: budget.month, cap: budget.capMicros, spent: budget.spentMicros, reserve: budget.reserveMicros });
  } else {
    const spent = Math.max(rows[0].spent, budget.spentMicros);
    const cap = Math.min(rows[0].cap, budget.capMicros);
    const reserved = reserveBudget(spent, rows[0].reserved, cap, budget.reserveMicros);
    await query(transaction, "UPDATE dbo.ImportBudget SET SpentMicros=@spent,ReservedMicros=@reserved,CapMicros=@cap WHERE Month=@month",
      { month: budget.month, cap, spent, reserved });
  }
}
async function settleReservation(transaction: sql.Transaction, row: JobRow): Promise<void> {
  await query(transaction, `UPDATE dbo.ImportBudget SET ReservedMicros=ReservedMicros-@reserve,
    SpentMicros=SpentMicros+@reserve WHERE Month=@month`, { month: row.budgetMonth, reserve: row.reservedMicros });
}
async function expireUndelivered(transaction: sql.Transaction, userId: string): Promise<void> {
  const rows = await query<JobRow>(transaction, `SELECT TOP(3) ${columns} FROM dbo.ImportJobs WITH(UPDLOCK,HOLDLOCK)
    WHERE UserId=@userId AND State IN('queued','running') AND Deadline<=SYSUTCDATETIME() ORDER BY Id`, { userId });
  for (const row of rows) {
    await query(transaction, `UPDATE dbo.ImportJobs SET State='failed',Version=Version+1,
      Error='Import deadline elapsed while delivery was unavailable. The full spending cap remains accounted; dispatched runs are not restarted.' WHERE Id=@id`, { id: row.id });
    await settleReservation(transaction, row);
  }
}

export class ImportService {
  constructor(private readonly service: RecipeBookService, private readonly provider = new ImportPipelineProvider(),
    private readonly admission: "customer" | "operator-proof" = "customer") {}
  private requireAdmission() {
    invariant(this.admission === "operator-proof"
      ? process.env["IMPORT_RUNTIME_PROBE_ENABLED"] === "true"
      : process.env["APIFY_CUSTOMER_IMPORTS_ENABLED"] === "true",
    503, "imports_not_enabled", "Instagram importing is not enabled for customer requests yet.");
  }
  async capabilities() {
    const budget = await this.provider.preflightBudget();
    return this.service.execute(async (transaction) => {
      const current = (await query<{ spent: number; reserved: number; cap: number }>(transaction,
        "SELECT SpentMicros AS spent,ReservedMicros AS reserved,CapMicros AS cap FROM dbo.ImportBudget WHERE Month=@month",
        { month: budget.month }))[0];
      const available = Math.max(0, Math.min(budget.capMicros, current?.cap ?? budget.capMicros) -
        Math.max(budget.spentMicros, current?.spent ?? 0) - (current?.reserved ?? 0));
      return {
        enabled: process.env["APIFY_ENABLED"] === "true" && process.env["APIFY_CUSTOMER_IMPORTS_ENABLED"] === "true" && available >= budget.reserveMicros,
        budgetMode: budget.visibility, globalUsageVisible: budget.visibility === "api-usage",
        pilotExpiresAt: budget.endsAt.toISOString(), operatorProofAt: budget.verifiedAt ?? null,
        reservationMicros: budget.reserveMicros, availablePilotMicros: available
      };
    });
  }
  list(bookId?: string) {
    return this.service.execute(async (transaction, userId) => {
      await expireUndelivered(transaction, userId);
      if (bookId) await bookAccess(transaction, bookId, userId);
      return (await query<JobRow>(transaction,
        `SELECT TOP(100) ${columns} FROM dbo.ImportJobs WHERE UserId=@userId AND State<>'discarded'
        AND OperatorOnly=0 AND SupersededById IS NULL
        AND (@bookId IS NULL OR DestinationBookId=@bookId)
        AND (DestinationBookId IS NULL OR EXISTS(
          SELECT 1 FROM dbo.Books b JOIN dbo.Memberships m ON m.BookId=b.Id
          WHERE b.Id=DestinationBookId AND m.UserId=@userId))
        ORDER BY CreatedAt DESC`, { userId, bookId: bookId ?? null })).map(job);
    });
  }
  get(id: string) {
    return this.service.execute(async (transaction, userId) => {
      await expireUndelivered(transaction, userId);
      const row = await getJob(transaction, id, userId);
      invariant(!row.operatorOnly || this.admission === "operator-proof", 404, "import_not_found", "Import job not found.");
      return job(row);
    });
  }
  async create(input: unknown, key: string, expectedAccountId?: string) {
    this.requireAdmission();
    const { sourceURL: raw, bookId: destination } = z.object({ sourceURL: z.string().max(2048), bookId: idSchema.optional() }).strict().parse(input);
    invariant(destination || this.admission === "operator-proof", 400, "destination_required", "Choose a recipe book before importing.");
    const sourceURL = canonicalReelURL(raw);
    // Check persisted idempotency before making even uncharged provider calls.
    const existing = await this.service.execute(async (transaction, userId) => {
      invariant(!expectedAccountId || expectedAccountId === userId, 409, "account_changed", "Sign-in changed before the import was submitted.");
      await expireUndelivered(transaction, userId);
      if (destination) await bookAccess(transaction, destination, userId);
      const requests = await query<{ jobId: string; sourceURL: string }>(transaction,
        "SELECT CONVERT(varchar(36),JobId) AS jobId,SourceURL AS sourceURL FROM dbo.ImportRequests WHERE UserId=@userId AND IdempotencyKey=@key", { userId, key });
      if (!requests[0]) return null;
      invariant(requests[0].sourceURL === sourceURL, 409, "idempotency_conflict", "This idempotency key belongs to a different Reel.");
      const current = await getJob(transaction, requests[0].jobId, userId);
      invariant(!current.operatorOnly || this.admission === "operator-proof", 404, "import_not_found", "Import job not found.");
      invariant((current.destinationBookId?.toLowerCase() ?? null) === (destination ?? null), 409, "idempotency_conflict", "This import key belongs to a different destination book.");
      return job(current);
    });
    if (existing) return existing;
    const budget = await this.provider.budget();
    return this.service.execute(async (transaction, userId) => {
      invariant(!expectedAccountId || expectedAccountId === userId, 409, "account_changed", "Sign-in changed before the import was submitted.");
      if (destination) await bookAccess(transaction, destination, userId);
      const requests = await query<{ jobId: string; sourceURL: string }>(transaction,
        "SELECT CONVERT(varchar(36),JobId) AS jobId,SourceURL AS sourceURL FROM dbo.ImportRequests WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@userId AND IdempotencyKey=@key", { userId, key });
      if (requests[0]) {
        invariant(requests[0].sourceURL === sourceURL, 409, "idempotency_conflict", "This idempotency key belongs to a different Reel.");
        const current = await getJob(transaction, requests[0].jobId, userId);
        invariant(!current.operatorOnly || this.admission === "operator-proof", 404, "import_not_found", "Import job not found.");
        invariant((current.destinationBookId?.toLowerCase() ?? null) === (destination ?? null), 409, "idempotency_conflict", "This import key belongs to a different destination book.");
        return job(current);
      }
      const duplicate = await query<JobRow>(transaction,
        `SELECT TOP(1) ${columns} FROM dbo.ImportJobs WITH(UPDLOCK,HOLDLOCK)
        WHERE UserId=@userId AND SourceURL=@sourceURL AND BudgetMonth=@month AND OperatorOnly=@operatorOnly
        AND (DestinationBookId=@destination OR (DestinationBookId IS NULL AND @destination IS NULL)) ORDER BY CreatedAt DESC`,
        { userId, sourceURL, month: budget.month, destination: destination ?? null, operatorOnly: this.admission === "operator-proof" });
      if (duplicate[0]) {
        await query(transaction, "INSERT dbo.ImportRequests(UserId,IdempotencyKey,JobId,SourceURL) VALUES(@userId,@key,@id,@sourceURL)",
          { userId, key, id: duplicate[0].id, sourceURL });
        return job(duplicate[0]);
      }
      const counts = await query<{ count: number }>(transaction,
        "SELECT COUNT(*) AS count FROM dbo.ImportJobs WHERE UserId=@userId AND State IN('queued','running')", { userId });
      invariant(counts[0]!.count < 3, 429, "import_limit", "At most three imports may be in progress.");
      await reserve(transaction, budget);
      const id = randomUUID();
      const deadline = new Date(Math.min(Date.now() + 10 * 60_000, budget.endsAt.getTime()));
      await query(transaction, `INSERT dbo.ImportJobs(Id,UserId,IdempotencyKey,SourceURL,State,BudgetMonth,ReservedMicros,Deadline,PipelineData,DestinationBookId,OperatorOnly)
        VALUES(@id,@userId,@key,@sourceURL,'queued',@month,@reserve,@deadline,@pipeline,@destination,@operatorOnly)`,
        { id, userId, key, sourceURL, month: budget.month, reserve: budget.reserveMicros, deadline, pipeline: JSON.stringify(initialPipeline()),
          destination: destination ?? null, operatorOnly: this.admission === "operator-proof" });
      await query(transaction, "INSERT dbo.ImportRequests(UserId,IdempotencyKey,JobId,SourceURL) VALUES(@userId,@key,@id,@sourceURL)", { userId, key, id, sourceURL });
      return job(await getJob(transaction, id, userId));
    });
  }
  async retry(id: string, version: number) {
    this.requireAdmission();
    const budget = await this.provider.budget();
    return this.service.execute(async (transaction, userId) => {
      const row = await getJob(transaction, id, userId);
      assertVersion(row.version, version);
      invariant(row.state === "failed" && !row.dispatchStarted &&
        (!row.pipelineData || pipelineSchema.parse(JSON.parse(row.pipelineData)).runs.length === 0),
      409, "retry_unsafe", "This job cannot be retried because a provider charge may already exist.");
      const counts = await query<{ count: number }>(transaction,
        "SELECT COUNT(*) AS count FROM dbo.ImportJobs WHERE UserId=@userId AND State IN('queued','running')", { userId });
      invariant(counts[0]!.count < 3, 429, "import_limit", "At most three imports may be in progress.");
      const config = approvedPipeline();
      invariant(config.reserveMicros === row.reservedMicros, 409, "provider_changed", "The approved spending cap changed.");
      await reserve(transaction, budget);
      await query(transaction, `UPDATE dbo.ImportJobs SET State='queued',Error=NULL,Version=Version+1,Deadline=@deadline,PipelineData=@pipeline WHERE Id=@id`,
        { id, deadline: new Date(Math.min(Date.now() + 10 * 60_000, budget.endsAt.getTime())), pipeline: JSON.stringify(initialPipeline()) });
      await query(transaction, "UPDATE dbo.ImportJobs SET BudgetMonth=@month WHERE Id=@id", { id, month: budget.month });
      return job(await getJob(transaction, id, userId));
    });
  }
  discard(id: string, version: number) {
    return this.service.execute(async (transaction, userId) => {
      const row = await getJob(transaction, id, userId);
      invariant(!row.operatorOnly, 404, "import_not_found", "Import job not found.");
      assertVersion(row.version, version);
      invariant(!["queued", "running", "completed"].includes(row.state), 409, "import_busy", "Only review drafts or failed jobs can be discarded.");
      await query(transaction, "UPDATE dbo.ImportJobs SET State='discarded',Draft=NULL,Evidence=NULL,Version=Version+1 WHERE Id=@id", { id });
      return { id: userId };
    });
  }
  markSeen(id: string, version: number) {
    return this.service.execute(async (transaction, userId) => {
      const row = await getJob(transaction, id, userId);
      invariant(!row.operatorOnly, 404, "import_not_found", "Import job not found.");
      assertVersion(row.version, version);
      invariant(row.state === "review", 409, "review_required", "Only a ready review draft can be marked as seen.");
      await query(transaction, "UPDATE dbo.ImportJobs SET ReviewSeenVersion=Version WHERE Id=@id", { id });
      return job(await getJob(transaction, id, userId));
    });
  }
  async resumeCachedModel(id: string, key: string) {
    invariant(this.admission === "operator-proof" && process.env["IMPORT_RUNTIME_PROBE_ENABLED"] === "true" &&
      approvedPipeline().modelProvider !== "apify", 403, "resume_not_approved", "Cached model recovery requires an explicitly authorized direct-model proof.");
    const cached = await this.service.execute(async (transaction, userId) => {
      const row = await getJob(transaction, id, userId);
      invariant(row.state === "failed" && row.pipelineData &&
        row.createdAt.getTime() > Date.now() - 24 * 60 * 60_000, 409, "resume_unsafe", "This failed import does not have recent, definite model-stage evidence.");
      const pipeline = pipelineSchema.parse(JSON.parse(row.pipelineData));
      invariant(pipeline.stage === "model" && pipeline.evidence?.transcript && pipeline.runs.length === 2,
        409, "resume_unsafe", "Both completed metadata and audio stages are required; they will not be charged again.");
      return { row, pipeline };
    });
    if (cached.row.providerRunId) {
      const previous = await this.provider.run(cached.row.providerRunId);
      invariant(previous.status === "SUCCEEDED", 409, "resume_unsafe", "The prior provider outcome is not definitively terminal.");
    } else {
      invariant(cached.row.dispatchStarted &&
        cached.row.error === "An ingredient amount/unit is not explicitly supported by its cited source.",
      409, "resume_unsafe", "Only the explicitly verified completed quantity-validation failure can be recovered; unknown model POST outcomes are not retried.");
    }
    const budget = await this.provider.budget();
    return this.service.execute(async (transaction, userId) => {
      const row = await getJob(transaction, id, userId);
      assertVersion(row.version, cached.row.version);
      const existing = await query<{ id: string }>(transaction,
        "SELECT CONVERT(varchar(36),JobId) AS id FROM dbo.ImportRequests WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@userId AND IdempotencyKey=@key", { userId, key });
      if (existing[0]) {
        const found = await getJob(transaction, existing[0].id, userId);
        invariant(found.pipelineData && pipelineSchema.parse(JSON.parse(found.pipelineData)).resumedFrom === id,
          409, "idempotency_conflict", "This model-resume key belongs to a different source job.");
        return job(found);
      }
      await reserve(transaction, budget);
      const newId = randomUUID();
      const pipeline = { ...initialPipeline(), stage: "model" as const, evidence: cached.pipeline.evidence,
        thumbnailURL: cached.pipeline.thumbnailURL, runs: cached.pipeline.runs, resumedFrom: row.id.toLowerCase() };
      await query(transaction, `INSERT dbo.ImportJobs(Id,UserId,IdempotencyKey,SourceURL,State,BudgetMonth,ReservedMicros,Deadline,PipelineData,DestinationBookId,OperatorOnly)
        VALUES(@newId,@userId,@key,@sourceURL,'queued',@month,@reserve,@deadline,@pipeline,@destination,@operatorOnly)`,
      { newId, userId, key, sourceURL: row.sourceURL, month: budget.month, reserve: budget.reserveMicros,
        deadline: new Date(Math.min(Date.now() + 10 * 60_000, budget.endsAt.getTime())),
        pipeline: JSON.stringify(pipeline), destination: row.destinationBookId, operatorOnly: row.operatorOnly });
      await query(transaction, "INSERT dbo.ImportRequests(UserId,IdempotencyKey,JobId,SourceURL) VALUES(@userId,@key,@newId,@sourceURL)",
        { userId, key, newId, sourceURL: row.sourceURL });
      await query(transaction, "UPDATE dbo.ImportJobs SET SupersededById=@newId WHERE Id=@id", { id, newId });
      return job(await getJob(transaction, newId, userId));
    });
  }
  approve(id: string, bookId: string, input: unknown, version: number) {
    const draft = draftSchema.parse(input);
    return this.service.execute(async (transaction, userId) => {
      const row = await getJob(transaction, id, userId);
      invariant(!row.operatorOnly, 404, "import_not_found", "Import job not found.");
      assertVersion(row.version, version);
      invariant(row.state === "review", 409, "review_required", "This job is not ready for review.");
      invariant(!row.destinationBookId || row.destinationBookId.toLowerCase() === bookId.toLowerCase(),
        409, "destination_changed", "Save this import to the recipe book selected when it was shared.");
      draft.sourceURL = row.sourceURL;
      await bookAccess(transaction, bookId, userId);
      const counts = await query<{ count: number }>(transaction, "SELECT COUNT(*) AS count FROM dbo.Recipes WHERE BookId=@bookId", { bookId });
      invariant(counts[0]!.count < 1000, 409, "recipe_limit", "A book can contain at most 1000 recipes.");
      const recipeId = randomUUID();
      await query(transaction, "INSERT dbo.Recipes(Id,BookId,AuthorId,Draft) VALUES(@id,@bookId,@userId,@draft)",
        { id: recipeId, bookId, userId, draft: JSON.stringify(draft) });
      await bindCover(transaction, userId, recipeId, draft.coverImageID);
      await query(transaction, `UPDATE dbo.ImportJobs SET State='completed',CompletedRecipeId=@recipeId,
        CompletedBookId=@bookId,Version=Version+1 WHERE Id=@id`, { id, recipeId, bookId });
      return { id: recipeId, bookId, authorId: userId, draft, version: 1 };
    });
  }
}

export async function importDelivery(id: string, expectedDeadline?: string): Promise<ImportDelivery | null> {
  return serializable(async transaction => {
    const row = (await query<{ deadline: Date }>(transaction,
      "SELECT Deadline AS deadline FROM dbo.ImportJobs WHERE Id=@id AND State IN('queued','running')", { id }))[0];
    if (!row || (expectedDeadline !== undefined && row.deadline.toISOString() !== expectedDeadline)) return null;
    return { id, deadline: row.deadline.toISOString() };
  });
}
export async function failImportDelivery(id: string, provider = new ImportPipelineProvider(), expectedDeadline?: string): Promise<void> {
  const row = await serializable(async transaction => (await query<JobRow>(transaction,
    `SELECT ${columns} FROM dbo.ImportJobs WHERE Id=@id AND State IN('queued','running')`, { id }))[0]);
  if (!row || (expectedDeadline !== undefined && row.deadline.toISOString() !== expectedDeadline)) return;
  if (row.providerRunId) {
    try { await provider.abort(row.providerRunId); }
    catch (error) {
      await finishImport(row, null, null, "Import delivery retries were exhausted and provider cancellation could not be confirmed. The full spending cap remains accounted.");
      throw error;
    }
  }
  await finishImport(row, null, null, "Import queue delivery retries were exhausted. No new charged job was started.");
}

export async function processImport(id: string, provider = new ImportPipelineProvider(), expectedDeadline?: string): Promise<void> {
  const action = await serializable(async transaction => {
    const rows = await query<JobRow>(transaction, `SELECT ${columns} FROM dbo.ImportJobs WITH(UPDLOCK,HOLDLOCK) WHERE Id=@id`, { id });
    const row = rows[0];
    if (!row || !["queued", "running"].includes(row.state)
      || (expectedDeadline !== undefined && row.deadline.toISOString() !== expectedDeadline)) return null;
    const identities = await query<{ issuer: string; subject: string }>(transaction,
      "SELECT Issuer AS issuer,Subject AS subject FROM dbo.Accounts WHERE Id=@userId AND Active=1", { userId: row.userId });
    let allowed = false;
    if (identities[0]) {
      const invitations = await query<{ count: number }>(transaction,
        `SELECT COUNT(*) AS count FROM dbo.AccessInvites WHERE Issuer=@issuer AND Subject=@subject
        AND Revoked=0 AND ExpiresAt>SYSUTCDATETIME()`, { ...identities[0] });
      allowed = invitations[0]!.count > 0;
    }
    if (allowed && row.destinationBookId) {
      try { await bookAccess(transaction, row.destinationBookId, row.userId); }
      catch (error) {
        if (!(error instanceof AppError) || error.code !== "book_not_found") throw error;
        allowed = false;
      }
    }
    if (!allowed || row.deadline.getTime() <= Date.now()) return { kind: "expired" as const, row };
    if (row.providerRunId) return { kind: "poll" as const, row, principal: identities[0]! };
    if (row.dispatchStarted) {
      const grace = row.pipelineData && pipelineSchema.parse(JSON.parse(row.pipelineData)).stage === "model" ? 180_000 : 60_000;
      if ((row.dispatchStartedAt?.getTime() ?? 0) < Date.now() - grace) return { kind: "ambiguous" as const, row };
      return null;
    }
    const config = approvedPipeline();
    invariant(row.pipelineData, 409, "pipeline_missing", "This old import predates model-assisted extraction. It will not be automatically charged again.");
    pipelineSchema.parse(JSON.parse(row.pipelineData));
    // Commit dispatch intent before the charged POST. A crash/timeout cannot
    // trigger another POST; unknown outcomes consume the full reservation.
    await query(transaction, `UPDATE dbo.ImportJobs SET DispatchStarted=1,DispatchStartedAt=SYSUTCDATETIME(),
      State='running',Version=Version+1 WHERE Id=@id`, { id });
    const pipeline = pipelineSchema.parse(JSON.parse(row.pipelineData));
    return pipeline.stage === "model" && config.modelProvider !== "apify"
      ? { kind: "extract" as const, row, principal: identities[0]! }
      : { kind: "start" as const, row };
  });
  if (!action) return;
  if (action.kind === "expired" || action.kind === "ambiguous") {
    if (action.row.providerRunId) {
      try { await provider.abort(action.row.providerRunId); }
      catch (error) {
        await finishImport(action.row, null, null, "Import expired and provider cancellation could not be confirmed. The full spending cap remains accounted.");
        throw error;
      }
    }
    await finishImport(action.row, null, null, action.kind === "ambiguous"
      ? "Provider dispatch outcome is unknown. No automatic retry was attempted."
      : "Import expired or app access was revoked.");
    return;
  }
  if (action.kind === "extract") {
    try {
      const pipeline = pipelineSchema.parse(JSON.parse(action.row.pipelineData!));
      const result = await provider.extractDirect(action.row.sourceURL, pipeline, async model => {
        await serializable(async transaction => {
          await query(transaction, `UPDATE dbo.ImportJobs SET ModelResultJson=@model
            WHERE Id=@id AND State='running' AND Deadline=@deadline`,
          { id: action.row.id, model: JSON.stringify(model), deadline: action.row.deadline });
        });
      });
      await finishReviewedImport(action.row, result.review.draft, result.evidence, pipeline.thumbnailURL, action.principal);
    } catch (error) {
      await finishImport(action.row, null, null, error instanceof AppError ? error.message :
        "The direct model result could not be validated. No automatic retry was made.");
      throw error;
    }
    return;
  }
  if (action.kind === "start") {
    let run;
    try { run = await provider.startStage(action.row.sourceURL, pipelineSchema.parse(JSON.parse(action.row.pipelineData!)), action.row.reservedMicros); }
    catch (error) {
      await finishImport(action.row, null, null, "Provider dispatch failed or its result is unknown. No automatic retry was attempted.");
      throw error;
    }
    await serializable(async transaction => {
      const rows = await query<{ state: ImportJob["state"] }>(transaction,
        "SELECT State AS state FROM dbo.ImportJobs WITH(UPDLOCK,HOLDLOCK) WHERE Id=@id", { id });
      if (rows[0]?.state !== "running") {
        await provider.abort(run.id);
        return;
      }
      await query(transaction, "UPDATE dbo.ImportJobs SET ProviderRunId=@runId,Version=Version+1 WHERE Id=@id",
        { id, runId: run.id });
    });
    return;
  }
  const run = await provider.run(action.row.providerRunId!);
  if (["READY", "RUNNING", "TIMING-OUT", "ABORTING"].includes(run.status)) return;
  if (run.status !== "SUCCEEDED") {
    await finishImport(action.row, null, null, `Provider run ended with ${run.status}.`);
    return;
  }
  try {
    invariant(action.row.pipelineData, 409, "pipeline_missing", "The extraction stage is missing; no automatic provider retry is allowed.");
    const pipeline = pipelineSchema.parse(JSON.parse(action.row.pipelineData));
    const completed = await provider.completeStage(run, action.row.sourceURL, pipeline);
    if (completed.next) {
      completed.next.runs = [...pipeline.runs, run.id];
      await serializable(async transaction => {
        const current = (await query<JobRow>(transaction, `SELECT ${columns} FROM dbo.ImportJobs WITH(UPDLOCK,HOLDLOCK) WHERE Id=@id`, { id }))[0];
        if (!current || current.state !== "running" || current.providerRunId !== run.id ||
          current.deadline.getTime() !== action.row.deadline.getTime()) return;
        await query(transaction, `UPDATE dbo.ImportJobs SET PipelineData=@pipeline,Evidence=@evidence,
          ProviderRunId=NULL,DispatchStarted=0,DispatchStartedAt=NULL,Version=Version+1 WHERE Id=@id`,
        { id, pipeline: JSON.stringify(completed.next), evidence: JSON.stringify(completed.evidence) });
      });
    } else {
      invariant(completed.review, 502, "extraction_missing", "The model did not return a validated editable draft.");
      await finishReviewedImport(action.row, completed.review.draft, completed.evidence, pipeline.thumbnailURL, action.principal);
    }
  } catch (error) {
    const message = error instanceof AppError ? error.message : "Provider evidence could not be validated. Review is unavailable.";
    await finishImport(action.row, null, null, message);
    throw error;
  }
}
async function finishReviewedImport(row: JobRow, draft: RecipeDraft, evidence: Evidence, thumbnail: string | null, principal: Principal) {
  if (thumbnail) {
    try {
      const bytes = await downloadInstagramCover(thumbnail);
      const cover = await uploadRecipeImage(new RecipeBookService(principal),
        { jpegBase64: bytes.toString("base64") }, row.id.toLowerCase(), row.userId.toLowerCase());
      draft.coverImageID = cover.id;
    } catch (error) {
      if (!(error instanceof AppError) || !["thumbnail_unavailable", "invalid_cover", "image_limit"].includes(error.code)) throw error;
      evidence.warnings = ["Cover photo unavailable: " + error.message, ...(evidence.warnings ?? [])].slice(0, 100);
    }
  }
  await finishImport(row, JSON.stringify(draft), JSON.stringify(evidence), null);
}
async function finishImport(row: JobRow, draft: string | null, evidence: string | null, error: string | null): Promise<void> {
  await serializable(async transaction => {
    const current = (await query<JobRow>(transaction, `SELECT ${columns} FROM dbo.ImportJobs WITH(UPDLOCK,HOLDLOCK) WHERE Id=@id`, { id: row.id }))[0];
    if (!current || !["queued", "running"].includes(current.state)
      || current.deadline.getTime() !== row.deadline.getTime()) return;
    if (draft && current.deadline.getTime() <= Date.now()) {
      draft = null;
      evidence = null;
      error = "The import deadline elapsed before its recipe draft was committed.";
    }
    if (draft && current.destinationBookId) {
      try { await bookAccess(transaction, current.destinationBookId, current.userId); }
      catch (failure) {
        if (!(failure instanceof AppError) || failure.code !== "book_not_found") throw failure;
        draft = null;
        evidence = null;
        error = "The destination book is no longer accessible. No recipe was saved.";
      }
    }
    await query(transaction, `UPDATE dbo.ImportJobs SET State=@state,Draft=@draft,Evidence=@evidence,Error=@error,Version=Version+1 WHERE Id=@id`,
      { id: row.id, state: error ? "failed" : "review", draft, evidence, error });
    // Conservative settlement: reserve the entire hard cap as spent even if the
    // actor used less, because retrieval/storage and unknown outcomes can lag.
    await settleReservation(transaction, current);
  });
}
