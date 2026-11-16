import { randomUUID } from "node:crypto";
import { app } from "@azure/functions";

const phases = ["http_received", "body_read", "body_timeout", "body_cancel_failed", "token_received",
  "flow_claim_started", "flow_claimed", "google_exchange_started", "google_exchange_completed",
  "token_verified", "token_failed"] as const;
type Phase = typeof phases[number];
interface Entry { phase: Phase; at: string; elapsedMs: number; requestId: string }
const ring: Entry[] = [];
const ttl = 5 * 60_000;
export function beginOAuthTrace() {
  const requestId = randomUUID();
  const start = Date.now();
  return (phase: Phase) => {
    if (process.env["AUTH_TRANSPORT_DIAGNOSTICS_ENABLED"] !== "true") return;
    while (ring[0] && Date.parse(ring[0].at) < Date.now() - ttl) ring.shift();
    ring.push({ phase, at: new Date().toISOString(), elapsedMs: Date.now() - start, requestId });
    if (ring.length > 32) ring.splice(0, ring.length - 32);
  };
}
export function oauthTransportSnapshot(now = Date.now()) {
  if (process.env["AUTH_TRANSPORT_DIAGNOSTICS_ENABLED"] !== "true") return [];
  return ring.filter(entry => Date.parse(entry.at) >= now - ttl).map(entry => ({ ...entry }));
}
if (process.env["AUTH_TRANSPORT_DIAGNOSTICS_ENABLED"] === "true") {
  app.http("authTransportDiagnostics", {
    route: "_bootstrap/auth-transport", methods: ["GET"], authLevel: "admin",
    handler: async () => ({ status: 200, jsonBody: {
      events: oauthTransportSnapshot(), maxEvents: 32, ttlSeconds: ttl / 1000,
      note: "Process-local diagnostic; absence is not evidence that another instance received no request."
    }, headers: { "Cache-Control": "no-store" } })
  });
}
