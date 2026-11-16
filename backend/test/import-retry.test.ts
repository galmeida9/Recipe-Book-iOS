import test from "node:test";
import assert from "node:assert/strict";
import { importRetryDisposition } from "../src/imports.js";

const failed = { state: "failed" as const, dispatchStarted: true, pipelineData: null,
  modelResultJson: null, supersededById: null, operatorOnly: false };
test("a definitely retained completed model result offers zero-charge local review retry", () => {
  const result = importRetryDisposition({ ...failed, modelResultJson: "retained", pipelineData: "present" });
  assert.equal(result.canRetry, true);
  assert.match(result.retryReason!, /locally.*no new transcription or model request/);
});
test("unknown charged outcomes, superseded and operator jobs never offer unsafe repeat-charge retry", () => {
  const unknown = importRetryDisposition(failed);
  assert.equal(unknown.canRetry, false);
  assert.match(unknown.retryReason!, /may already have been charged/);
  assert.equal(importRetryDisposition({ ...failed, supersededById: "replacement" }).canRetry, false);
  assert.equal(importRetryDisposition({ ...failed, operatorOnly: true }).canRetry, false);
  assert.equal(importRetryDisposition({ ...failed, state: "review" }).canRetry, false);
});
test("only pre-dispatch failure permits a new budget-checked queue attempt", () => {
  const result = importRetryDisposition({ ...failed, dispatchStarted: false });
  assert.equal(result.canRetry, true);
  assert.match(result.retryReason!, /allowance will be checked again/);
});
