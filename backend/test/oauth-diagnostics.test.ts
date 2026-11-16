import test from "node:test";
import assert from "node:assert/strict";
import { HttpRequest } from "@azure/functions";
import { beginOAuthTrace, oauthTransportSnapshot } from "../src/oauth-diagnostics.js";
import { readOAuthForm } from "../src/oauth.js";

test("phase diagnostics are default-off, process-local, short-lived, capped and contain no caller-controlled fields", () => {
  delete process.env["AUTH_TRANSPORT_DIAGNOSTICS_ENABLED"];
  beginOAuthTrace()("http_received");
  assert.deepEqual(oauthTransportSnapshot(), []);
  process.env["AUTH_TRANSPORT_DIAGNOSTICS_ENABLED"] = "true";
  for (let i = 0; i < 40; i++) beginOAuthTrace()("http_received");
  const events = oauthTransportSnapshot();
  assert.equal(events.length, 32);
  assert(events.every(event => Object.keys(event).sort().join(",") === "at,elapsedMs,phase,requestId"));
  assert.deepEqual(oauthTransportSnapshot(Date.now() + 6 * 60_000), []);
  delete process.env["AUTH_TRANSPORT_DIAGNOSTICS_ENABLED"];
});
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
