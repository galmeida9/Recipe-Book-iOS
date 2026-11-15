import { createRemoteJWKSet, jwtVerify } from "jose";
import { invariant, requiredSetting, type Principal } from "./contracts.js";

let verifier: ReturnType<typeof createRemoteJWKSet> | undefined;
export async function authenticate(authorization: string | null): Promise<Principal> {
  invariant(authorization !== null && authorization.startsWith("Bearer "), 401, "unauthenticated", "Sign in to Recipe Book.");
  const issuer = requiredSetting("OIDC_ISSUER");
  const audience = requiredSetting("OIDC_AUDIENCE");
  const scope = requiredSetting("OIDC_SCOPE");
  const jwksURL = new URL(requiredSetting("OIDC_JWKS_URL"));
  invariant(jwksURL.protocol === "https:", 503, "configuration", "OIDC keys require HTTPS.");
  verifier ??= createRemoteJWKSet(jwksURL, { timeoutDuration: 5000, cooldownDuration: 30_000 });
  let payload;
  try {
    ({ payload } = await jwtVerify(authorization.slice(7), verifier, { issuer, audience, algorithms: ["RS256"] }));
  } catch {
    invariant(false, 401, "invalid_token", "Sign in again with a valid API access token.");
  }
  invariant(typeof payload.sub === "string" && payload.sub.length > 0 && payload.sub.length <= 200
    && typeof payload.exp === "number"
    && typeof payload["scp"] === "string" && payload["scp"].split(" ").includes(scope),
  401, "invalid_token", "The token is not authorized for the Recipe Book API.");
  return { issuer, subject: payload.sub };
}
