import test from "node:test";
import assert from "node:assert/strict";
import { HttpRequest } from "@azure/functions";
import { readOAuthForm } from "../src/oauth.js";

test("OAuth form input is size/deadline bounded and cancellation does not replay a token request", async () => {
  assert.equal(await readOAuthForm(new HttpRequest({ method: "POST", url: "https://fixture.invalid/token",
    body: { string: "grant_type=synthetic" } })), "grant_type=synthetic");
  await assert.rejects(() => readOAuthForm(new HttpRequest({ method: "POST", url: "https://fixture.invalid/token",
    body: { string: "x".repeat(16385) } })), /exceeded/);
  let cancelled = false;
  const stalled = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } });
  await assert.rejects(() => readOAuthForm({ body: stalled }, 10), /body did not arrive in time/);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(cancelled, true);
});
