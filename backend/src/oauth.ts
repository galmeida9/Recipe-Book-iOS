import { createHash } from "node:crypto";
import { OAuth2Client, CodeChallengeMethod, type Credentials } from "google-auth-library";
import { z } from "zod";
import type { HttpRequest, HttpResponseInit } from "@azure/functions";
import { AppError, invariant, requiredSetting, type Principal } from "./contracts.js";
import { googleAuthenticator } from "./auth.js";
import { serializable, query } from "./database.js";

export const nativeOAuthCallback = "recipebook://oauth";
const digest = (value: string) => createHash("sha256").update(value).digest("hex");
const randomParameter = z.string().regex(/^[A-Za-z0-9_-]{16,256}$/);
const verifierSchema = z.string().regex(/^[A-Za-z0-9._~-]{43,128}$/);
const challengeSchema = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const headers = { "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff" };

export interface OAuthFlowStore {
  create(state: string, nonce: string, challenge: string): Promise<void>;
  bind(state: string, code: string): Promise<void>;
  cancel(state: string): Promise<void>;
  consume(code: string, challenge: string): Promise<string>;
}
export class SQLFlowStore implements OAuthFlowStore {
  create(state: string, nonce: string, challenge: string) {
    return serializable(async transaction => {
      await query(transaction, "DELETE TOP(100) FROM dbo.OAuthFlows WHERE ExpiresAt<=SYSUTCDATETIME()");
      const rows = await query<{ count: number }>(transaction, "SELECT COUNT(*) AS count FROM dbo.OAuthFlows WITH(UPDLOCK,HOLDLOCK)");
      invariant(rows[0]!.count < 100, 503, "auth_capacity", "Sign-in capacity is temporarily full. Try again shortly.");
      const existing = await query<{ count: number }>(transaction, "SELECT COUNT(*) AS count FROM dbo.OAuthFlows WHERE StateHash=@state", { state: digest(state) });
      invariant(existing[0]!.count === 0, 400, "invalid_oauth_state", "Start a new sign-in request.");
      await query(transaction, "INSERT dbo.OAuthFlows(StateHash,Nonce,Challenge,ExpiresAt) VALUES(@state,@nonce,@challenge,DATEADD(MINUTE,10,SYSUTCDATETIME()))",
        { state: digest(state), nonce, challenge });
    });
  }
  bind(state: string, code: string) {
    return serializable(async transaction => {
      const rows = await query<{ nonce: string }>(transaction, `UPDATE dbo.OAuthFlows WITH(UPDLOCK,HOLDLOCK)
        SET CodeHash=@code,ExpiresAt=DATEADD(SECOND,90,SYSUTCDATETIME()) OUTPUT inserted.Nonce AS nonce
        WHERE StateHash=@state AND CodeHash IS NULL AND ExpiresAt>SYSUTCDATETIME()`, { state: digest(state), code: digest(code) });
      invariant(rows.length === 1, 400, "invalid_oauth_state", "The sign-in callback expired or was already used.");
    });
  }
  cancel(state: string) {
    return serializable(async transaction => {
      const rows = await query<{ nonce: string }>(transaction, `DELETE dbo.OAuthFlows OUTPUT deleted.Nonce AS nonce
        WHERE StateHash=@state AND CodeHash IS NULL AND ExpiresAt>SYSUTCDATETIME()`, { state: digest(state) });
      invariant(rows.length === 1, 400, "invalid_oauth_state", "The sign-in callback could not be verified.");
    });
  }
  consume(code: string, challenge: string) {
    return serializable(async transaction => {
      const rows = await query<{ nonce: string; challenge: string }>(transaction, `SELECT Nonce AS nonce,Challenge AS challenge
        FROM dbo.OAuthFlows WITH(UPDLOCK,HOLDLOCK) WHERE CodeHash=@code AND ExpiresAt>SYSUTCDATETIME()`, { code: digest(code) });
      invariant(rows[0] && rows[0].challenge === challenge, 400, "invalid_grant", "The sign-in code expired, was used, or does not match this app's challenge.");
      await query(transaction, "DELETE dbo.OAuthFlows WHERE CodeHash=@code", { code: digest(code) });
      return rows[0].nonce;
    });
  }
}

export interface OAuthProvider {
  authorize(state: string, nonce: string, challenge: string): string;
  exchange(code: string, verifier: string): Promise<Credentials>;
  refresh(token: string): Promise<Credentials>;
}
export interface OAuthDiagnostic {
  phase: "token_received" | "flow_claim_started" | "flow_claimed" | "google_exchange_started" | "google_exchange_completed" | "token_verified" | "token_failed";
  elapsedMs: number;
  outcome?: string;
}
export class GoogleOAuthProvider implements OAuthProvider {
  constructor(private readonly clientID: string, private readonly secret: string, private readonly callback: string,
    private readonly transport?: typeof fetch) {}
  private client() {
    const client = new OAuth2Client({
      clientId: this.clientID, clientSecret: this.secret, redirectUri: this.callback,
      transporterOptions: { timeout: 30_000, ...(this.transport ? { fetchImplementation: this.transport } : {}) }
    });
    // The SDK otherwise opts token POSTs into transient-error retries. A
    // one-use Google code with an unknown outcome must never be replayed.
    client.transporter.interceptors.request.add({
      resolved: async options => {
        options.timeout = 30_000;
        options.retry = false;
        options.retryConfig = { retry: 0, noResponseRetries: 0 };
        return options;
      }
    });
    return client;
  }
  authorize(state: string, nonce: string, challenge: string) {
    return this.client().generateAuthUrl({ scope: ["openid", "profile", "email"], response_type: "code",
      state, nonce, code_challenge: challenge, code_challenge_method: CodeChallengeMethod.S256,
      access_type: "offline", prompt: "select_account consent" });
  }
  async exchange(code: string, verifier: string) {
    return (await this.client().getToken({ code, codeVerifier: verifier })).tokens;
  }
  async refresh(token: string) {
    const client = this.client();
    client.setCredentials({ refresh_token: token });
    return (await client.refreshAccessToken()).credentials;
  }
}

export class OAuthBroker {
  constructor(private readonly clientID: string, private readonly flows: OAuthFlowStore,
    private readonly provider: OAuthProvider,
    private readonly verify: (token: string, nonce?: string) => Promise<Principal>,
    private readonly diagnose: (event: OAuthDiagnostic) => void = () => {}) {}
  config() { return { clientID: this.clientID, callbackURL: nativeOAuthCallback }; }
  async authorize(input: Record<string, string>) {
    const value = z.object({
      client_id: z.literal(this.clientID), redirect_uri: z.literal(nativeOAuthCallback),
      response_type: z.literal("code"), scope: z.string(), state: randomParameter, nonce: randomParameter,
      code_challenge: challengeSchema, code_challenge_method: z.literal("S256")
    }).strict().parse(input);
    invariant(value.scope.split(" ").sort().join(" ") === "email openid profile", 400, "invalid_scope", "Only basic Google sign-in scopes are supported.");
    await this.flows.create(value.state, value.nonce, value.code_challenge);
    return this.provider.authorize(value.state, value.nonce, value.code_challenge);
  }
  async callback(input: Record<string, string>) {
    const state = randomParameter.parse(input.state);
    const callback = new URL(nativeOAuthCallback);
    callback.searchParams.set("state", state);
    if (input.error) {
      await this.flows.cancel(state);
      callback.searchParams.set("error", "access_denied");
    } else {
      const code = z.string().min(1).max(4096).parse(input.code);
      await this.flows.bind(state, code);
      callback.searchParams.set("code", code);
    }
    return callback.href;
  }
  async token(input: Record<string, string>) {
    const started = Date.now();
    const phase = (value: OAuthDiagnostic["phase"]) => this.diagnose({ phase: value, elapsedMs: Date.now() - started });
    phase("token_received");
    invariant(input.client_id === this.clientID && input.client_secret === undefined, 400, "invalid_client", "Use the configured public client without a mobile secret.");
    let credentials: Credentials;
    let nonce: string | undefined;
    if (input.grant_type === "authorization_code") {
      const value = z.object({ grant_type: z.literal("authorization_code"), client_id: z.literal(this.clientID),
        redirect_uri: z.literal(nativeOAuthCallback), code: z.string().min(1).max(4096), code_verifier: verifierSchema }).strict().parse(input);
      const challenge = createHash("sha256").update(value.code_verifier).digest("base64url");
      phase("flow_claim_started");
      nonce = await this.flows.consume(value.code, challenge);
      phase("flow_claimed");
      phase("google_exchange_started");
      try { credentials = await this.provider.exchange(value.code, value.code_verifier); }
      catch (error) { throw providerError(error, "Google sign-in could not be completed. Start sign-in again."); }
      phase("google_exchange_completed");
    } else {
      const value = z.object({ grant_type: z.literal("refresh_token"), client_id: z.literal(this.clientID),
        refresh_token: z.string().min(1).max(8192), scope: z.string().optional() }).strict().parse(input);
      if (value.scope !== undefined) invariant(value.scope.split(" ").sort().join(" ") === "email openid profile", 400, "invalid_scope", "Only basic sign-in scopes are supported.");
      try { credentials = await this.provider.refresh(value.refresh_token); }
      catch (error) { throw providerError(error, "Your Google sign-in could not be refreshed. Sign in again."); }
    }
    invariant(credentials.id_token && credentials.access_token && credentials.token_type?.toLowerCase() === "bearer" &&
      typeof credentials.expiry_date === "number" && credentials.expiry_date > Date.now(),
    401, "invalid_google_response", "Google returned no valid sign-in credentials.");
    await this.verify(credentials.id_token, nonce);
    phase("token_verified");
    return { access_token: credentials.access_token, id_token: credentials.id_token,
      ...(credentials.refresh_token ? { refresh_token: credentials.refresh_token } : {}),
      token_type: "Bearer", expires_in: Math.floor((credentials.expiry_date - Date.now()) / 1000),
      scope: "openid profile email" };
  }
}

function unique(parameters: URLSearchParams) {
  const result = new Map<string, string>();
  for (const [key, value] of parameters) {
    invariant(!result.has(key), 400, "invalid_request", "Duplicate sign-in parameters are not supported.");
    result.set(key, value);
  }
  return Object.fromEntries(result);
}
function providerError(error: unknown, message: string) {
  if (error instanceof Error && "response" in error && typeof error.response === "object" && error.response !== null &&
      "status" in error.response && typeof error.response.status === "number" &&
      error.response.status >= 400 && error.response.status < 500) return new AppError(400, "invalid_grant", message);
  return new AppError(503, "identity_unavailable", "Google sign-in is temporarily unavailable. Try again with a new sign-in request.");
}
export async function oauthRoute(request: HttpRequest, diagnose: (event: OAuthDiagnostic) => void = () => {}): Promise<HttpResponseInit | null> {
  const url = new URL(request.url);
  const path = url.pathname.replace(/^\/api\//, "/");
  if (!path.startsWith("/auth/google/")) return null;
  const clientID = requiredSetting("GOOGLE_SERVER_CLIENT_ID");
  googleAuthenticator({ serverClientID: clientID });
  const secret = requiredSetting("GOOGLE_OAUTH_CLIENT_SECRET");
  invariant(!secret.startsWith("@Microsoft.KeyVault") && secret.length >= 8, 503, "configuration", "Configure the Google Web client secret securely in the existing vault.");
  const host = requiredSetting("WEBSITE_HOSTNAME");
  invariant(/^[a-z0-9.-]+\.azurewebsites\.net$/.test(host), 503, "configuration", "The verified HTTPS server callback host is required.");
  const provider = new GoogleOAuthProvider(clientID, secret, `https://${host}/api/auth/google/callback`);
  const broker = new OAuthBroker(clientID, new SQLFlowStore(), provider,
    (token, nonce) => googleAuthenticator({ serverClientID: clientID, ...(nonce === undefined ? {} : { nonce }) })("Bearer " + token), diagnose);
  if (request.method === "GET" && path === "/auth/google/config") return { status: 200, jsonBody: broker.config(), headers };
  if (request.method === "GET" && path === "/auth/google/authorize") return { status: 302, headers: { ...headers, Location: await broker.authorize(unique(url.searchParams)) } };
  if (request.method === "GET" && path === "/auth/google/callback") return { status: 302, headers: { ...headers, Location: await broker.callback(unique(url.searchParams)) } };
  if (request.method === "POST" && path === "/auth/google/token") {
    invariant(request.headers.get("content-type")?.split(";")[0]?.trim() === "application/x-www-form-urlencoded", 415, "content_type", "Send a standard OAuth form.");
    const text = await request.text();
    invariant(Buffer.byteLength(text) <= 16384, 413, "request_limit", "Sign-in request exceeded the limit.");
    try { return { status: 200, jsonBody: await broker.token(unique(new URLSearchParams(text))), headers }; }
    catch (error) {
      diagnose({ phase: "token_failed", elapsedMs: 0, outcome: error instanceof AppError ? error.code : "server_error" });
      if (error instanceof AppError) return {
        status: error.status < 500 ? 400 : error.status,
        jsonBody: { error: error.status < 500 ? error.code : "temporarily_unavailable", error_description: error.message }, headers
      };
      throw error;
    }
  }
  throw new AppError(404, "route_not_found", "Sign-in route not found.");
}
