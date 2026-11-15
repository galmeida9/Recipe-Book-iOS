import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPair, exportJWK, createLocalJWKSet, SignJWT, type JWTPayload } from "jose";
import { googleAuthenticator, googleIssuer } from "../src/auth.js";
import { AppError } from "../src/contracts.js";

const configuration = {
  serverClientID: "123456789-serverfixture.apps.googleusercontent.com",
  iosClientID: "123456789-iosfixture.apps.googleusercontent.com"
};
test("Google ID tokens require exact audience, authorized iOS client, issuer, lifetime and signed stable subject", async () => {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const keys = createLocalJWKSet({ keys: [{ ...await exportJWK(publicKey), kid: "fixture" }] });
  const verify = googleAuthenticator(configuration, keys);
  const now = Math.floor(Date.now() / 1000);
  const claims = { iss: googleIssuer, aud: configuration.serverClientID, azp: configuration.iosClientID,
    sub: "100000000000000000001", iat: now, exp: now + 3600 };
  const token = async (payload: JWTPayload) => "Bearer " + await new SignJWT(payload).setProtectedHeader({ alg: "RS256", kid: "fixture" }).sign(privateKey);
  assert.deepEqual(await verify(await token(claims)), { issuer: googleIssuer, subject: claims.sub });
  assert.deepEqual(await verify(await token({ ...claims, iss: "accounts.google.com", email: "ignored@example.invalid" })),
    { issuer: googleIssuer, subject: claims.sub });
  for (const changed of [
    { aud: configuration.iosClientID }, { aud: [configuration.serverClientID] },
    { azp: "123456789-other.apps.googleusercontent.com" }, { azp: undefined },
    { iss: "https://login.microsoftonline.com/fixture" }, { sub: undefined }, { sub: "email@example.invalid" },
    { exp: now - 10 }, { exp: now + 7200 }, { exp: undefined }, { iat: undefined }, { iat: now + 120 }
  ]) {
    await assert.rejects(() => token({ ...claims, ...changed }).then(verify),
      (error: unknown) => error instanceof AppError && error.status === 401);
  }
  await assert.rejects(() => verify("Bearer opaque-google-access-token"), (error: unknown) => error instanceof AppError && error.status === 401);
  const other = await generateKeyPair("RS256");
  const forged = await new SignJWT(claims).setProtectedHeader({ alg: "RS256", kid: "fixture" }).sign(other.privateKey);
  await assert.rejects(() => verify("Bearer " + forged), (error: unknown) => error instanceof AppError && error.status === 401);
  const unavailable = googleAuthenticator(configuration, async () => { throw new TypeError("Synthetic unavailable key endpoint"); });
  await assert.rejects(() => token(claims).then(unavailable),
    (error: unknown) => error instanceof AppError && error.status === 503 && error.code === "identity_unavailable");
  assert.throws(() => googleAuthenticator({ ...configuration, serverClientID: "" }),
    (error: unknown) => error instanceof AppError && error.status === 503);
});
