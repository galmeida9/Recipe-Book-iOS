import test from "node:test";
import assert from "node:assert/strict";
import { HttpRequest, InvocationContext } from "@azure/functions";
import { api } from "../src/functions.js";

test("public OAuth config is routed before account bearer authentication; data stays protected", async () => {
  const saved = { id: process.env.GOOGLE_SERVER_CLIENT_ID, secret: process.env.GOOGLE_OAUTH_CLIENT_SECRET, host: process.env.WEBSITE_HOSTNAME };
  Object.assign(process.env, { GOOGLE_SERVER_CLIENT_ID: "123456789-serverfixture.apps.googleusercontent.com",
    GOOGLE_OAUTH_CLIENT_SECRET: "synthetic-test-only-secret", WEBSITE_HOSTNAME: "fixture.azurewebsites.net" });
  try {
    const context = new InvocationContext({ functionName: "fixture" });
    const config = await api(new HttpRequest({ url: "https://fixture.azurewebsites.net/api/auth/google/config", method: "GET" }), context);
    assert.equal(config.status, 200);
    assert.deepEqual(config.jsonBody, { clientID: process.env.GOOGLE_SERVER_CLIENT_ID, callbackURL: "recipebook://oauth" });
    const data = await api(new HttpRequest({ url: "https://fixture.azurewebsites.net/api/me", method: "GET" }), context);
    assert.equal(data.status, 401);
  } finally {
    for (const [key, value] of Object.entries({ GOOGLE_SERVER_CLIENT_ID: saved.id, GOOGLE_OAUTH_CLIENT_SECRET: saved.secret, WEBSITE_HOSTNAME: saved.host })) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  }
});
