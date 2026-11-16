import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import { OAuthBroker, GoogleOAuthProvider, type OAuthFlowStore, type OAuthProvider } from "../src/oauth.js";
import { googleAuthenticator, googleIssuer } from "../src/auth.js";
import type { Credentials } from "google-auth-library";

// Explicit test-only flow storage, never selected by the production route.
class FlowFixture implements OAuthFlowStore {
  clock = 0;
  rows = new Map<string, { nonce: string; challenge: string; code?: string; expires: number }>();
  async create(state: string, nonce: string, challenge: string) {
    assert.ok(!this.rows.has(state) && this.rows.size < 100);
    this.rows.set(state, { nonce, challenge, expires: this.clock + 600000 });
  }
  async bind(state: string, code: string) {
    const row = this.rows.get(state);
    assert.ok(row && !row.code && row.expires > this.clock);
    row.code = code; row.expires = this.clock + 90000;
  }
  async cancel(state: string) { assert.ok(this.rows.delete(state)); }
  async consume(code: string, challenge: string) {
    const pair = [...this.rows].find(([, row]) => row.code === code);
    assert.ok(pair && pair[1].expires > this.clock && pair[1].challenge === challenge);
    this.rows.delete(pair[0]);
    return pair[1].nonce;
  }
}
const clientID = "123456789-serverfixture.apps.googleusercontent.com";
const verifier = "v".repeat(43);
const nonce = "n".repeat(43);
const state = "s".repeat(43);
const request = { client_id: clientID, redirect_uri: "recipebook://oauth", response_type: "code",
  scope: "openid profile email", state, nonce,
  code_challenge: createHash("sha256").update(verifier).digest("base64url"), code_challenge_method: "S256" };
const exchange = { grant_type: "authorization_code", client_id: clientID, redirect_uri: "recipebook://oauth",
  code: "synthetic-short-code", code_verifier: verifier };

test("central broker binds state/nonce/PKCE, never puts tokens in callbacks, and consumes code once", async () => {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const keys = createLocalJWKSet({ keys: [{ ...await exportJWK(publicKey), kid: "fixture" }] });
  const flows = new FlowFixture();
  let calls = 0;
  let wrongNonce = false;
  const tokens = async (): Promise<Credentials> => ({
    access_token: "inert-google-services-token", refresh_token: "inert-refresh-token", token_type: "Bearer",
    expiry_date: Date.now() + 3600000,
    id_token: await new SignJWT({ nonce: wrongNonce ? "wrong" : nonce, azp: clientID })
      .setProtectedHeader({ alg: "RS256", kid: "fixture" }).setIssuer(googleIssuer).setAudience(clientID)
      .setSubject("10000000001").setIssuedAt().setExpirationTime("1h").sign(privateKey)
  });
  const provider: OAuthProvider = {
    authorize: () => "https://accounts.google.com/o/oauth2/v2/auth",
    exchange: async () => { calls++; return tokens(); },
    refresh: async () => tokens()
  };
  const broker = new OAuthBroker(clientID, flows, provider, (token, expectedNonce) =>
    googleAuthenticator({ serverClientID: clientID, ...(expectedNonce === undefined ? {} : { nonce: expectedNonce }) }, keys)("Bearer " + token));
  await assert.rejects(() => broker.authorize({ ...request, redirect_uri: "evil://callback" }));
  await broker.authorize(request);
  const callback = new URL(await broker.callback({ state, code: exchange.code }));
  assert.equal(callback.protocol, "recipebook:");
  assert.equal(callback.searchParams.get("code"), exchange.code);
  assert.equal(callback.searchParams.get("state"), state);
  assert.ok(!callback.searchParams.has("id_token") && !callback.searchParams.has("access_token"));
  await assert.rejects(() => broker.callback({ state, code: exchange.code }));
  await assert.rejects(() => broker.token({ ...exchange, code_verifier: "x".repeat(43) }));
  await assert.rejects(() => broker.token({ ...exchange, client_secret: "never-a-mobile-secret" }));
  const outcomes = await Promise.allSettled([broker.token(exchange), broker.token(exchange)]);
  assert.equal(outcomes.filter(value => value.status === "fulfilled").length, 1);
  assert.equal(calls, 1);
  assert.equal((await broker.token({ grant_type: "refresh_token", client_id: clientID, refresh_token: "inert-refresh-token" })).token_type, "Bearer");
  await broker.authorize(request);
  await broker.callback({ state, code: exchange.code });
  flows.clock += 90001;
  await assert.rejects(() => broker.token(exchange));
  flows.rows.clear();
  await broker.authorize(request);
  await broker.callback({ state, code: exchange.code });
  wrongNonce = true;
  await assert.rejects(() => broker.token(exchange));
  await assert.rejects(() => broker.token(exchange));
});

test("official provider URL exposes only standard public authorization parameters", () => {
  const provider = new GoogleOAuthProvider(clientID, "synthetic-server-only-secret", "https://fixture.invalid/api/auth/google/callback");
  const url = new URL(provider.authorize(state, nonce, request.code_challenge));
  assert.equal(url.searchParams.get("redirect_uri"), "https://fixture.invalid/api/auth/google/callback");
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  assert.equal(url.searchParams.get("nonce"), nonce);
  assert.equal(url.searchParams.get("client_secret"), null);
});
test("slow provider exchange remains single-use and records only non-sensitive phases", async () => {
  const flows = new FlowFixture();
  const diagnostics: unknown[] = [];
  let release!: () => void;
  let started!: () => void;
  const entered = new Promise<void>(resolve => { started = resolve; });
  let calls = 0;
  const provider: OAuthProvider = {
    authorize: () => "https://accounts.google.com/o/oauth2/v2/auth",
    exchange: async () => {
      calls++; started();
      await new Promise<void>(resolve => { release = resolve; });
      return { id_token: "sensitive-id-token", access_token: "sensitive-access-token", token_type: "Bearer", expiry_date: Date.now() + 3600000 };
    },
    refresh: async () => { throw new Error("Not used"); }
  };
  const broker = new OAuthBroker(clientID, flows, provider, async () => ({ issuer: googleIssuer, subject: "synthetic" }),
    event => diagnostics.push(event));
  await broker.authorize(request);
  await broker.callback({ state, code: exchange.code });
  const first = broker.token(exchange);
  await entered;
  await assert.rejects(() => broker.token(exchange));
  assert.equal(calls, 1, "A waiting token exchange cannot be replayed to Google.");
  release();
  assert.equal((await first).token_type, "Bearer");
  const log = JSON.stringify(diagnostics);
  for (const secret of [state, nonce, verifier, exchange.code, "sensitive-id-token", "sensitive-access-token"]) assert(!log.includes(secret));
  assert(log.includes("flow_claimed") && log.includes("google_exchange_completed") && log.includes("token_verified"));
});
