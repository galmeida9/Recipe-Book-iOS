import { createRemoteJWKSet, jwtVerify, errors, type JWTVerifyGetKey } from "jose";
import { AppError, invariant, requiredSetting, type Principal } from "./contracts.js";

export const googleIssuer = "https://accounts.google.com";
const clientPattern = /^\d+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/;
const googleKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"),
  { timeoutDuration: 5000, cooldownDuration: 30_000 });

export function googleAuthenticator(configuration: { serverClientID: string; iosClientID: string }, keys: JWTVerifyGetKey = googleKeys) {
  const { serverClientID, iosClientID } = configuration;
  invariant(clientPattern.test(serverClientID) && clientPattern.test(iosClientID) && serverClientID !== iosClientID,
    503, "configuration", "Separate Google web/server and iOS OAuth client IDs must be configured.");
  return async (authorization: string | null): Promise<Principal> => {
    invariant(authorization && authorization.length <= 16384 &&
      /^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(authorization),
    401, "unauthenticated", "Sign in to Recipe Book with Google.");
    let payload;
    try {
      ({ payload } = await jwtVerify(authorization.slice(7), keys, {
        issuer: [googleIssuer, "accounts.google.com"], audience: serverClientID, algorithms: ["RS256"],
        requiredClaims: ["iss", "aud", "sub", "exp", "iat", "azp"], maxTokenAge: "65m", clockTolerance: 5
      }));
    } catch (error) {
      if (error instanceof errors.JOSEError && !(error instanceof errors.JWKSTimeout) &&
        !(error instanceof errors.JWKSInvalid) && !(error instanceof errors.JWKSMultipleMatchingKeys)) {
        throw new AppError(401, "invalid_token", "Sign in again with a valid Google ID token for Recipe Book.");
      }
      throw new AppError(503, "identity_unavailable", "Google identity verification is temporarily unavailable. Try again.");
    }
    invariant(payload.aud === serverClientID && payload["azp"] === iosClientID &&
      typeof payload.sub === "string" && /^\d{1,200}$/.test(payload.sub) &&
      typeof payload.exp === "number" && typeof payload.iat === "number" &&
      Number.isInteger(payload.exp) && Number.isInteger(payload.iat) &&
      payload.exp > payload.iat && payload.exp - payload.iat <= 3600,
    401, "invalid_token", "The Google ID token is not authorized for the Recipe Book API.");
    // Google's two documented issuer spellings represent the same immutable identity.
    return { issuer: googleIssuer, subject: payload.sub };
  };
}

export async function authenticate(authorization: string | null): Promise<Principal> {
  return googleAuthenticator({
    serverClientID: requiredSetting("GOOGLE_SERVER_CLIENT_ID"),
    iosClientID: requiredSetting("GOOGLE_IOS_CLIENT_ID")
  })(authorization);
}
