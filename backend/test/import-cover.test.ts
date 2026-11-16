import test from "node:test";
import assert from "node:assert/strict";
import jpeg from "jpeg-js";
import { downloadInstagramCover } from "../src/import-cover.js";

const publicDNS = async () => [{ address: "157.240.1.1", family: 4 }];
test("imported covers use only bounded public CDN JPEGs and resize tall video thumbnails", async () => {
  const image = jpeg.encode({ width: 900, height: 1700, data: Buffer.alloc(900 * 1700 * 4) }, 85).data;
  const result = await downloadInstagramCover("https://scontent.cdninstagram.com/public.jpg", async (_input, options) => {
    assert.equal(options?.redirect, "error");
    assert.equal(new Headers(options?.headers).get("authorization"), null);
    return new Response(image, { headers: { "content-type": "image/jpeg" } });
  }, publicDNS);
  const decoded = jpeg.decode(result);
  assert.equal(decoded.height, 1600);
  assert(decoded.width < 900);
});
test("remote image URL authority tricks, private DNS, redirects and oversized/unsupported bodies fail closed", async () => {
  let fetched = false;
  const transport: typeof fetch = async () => { fetched = true; return new Response("no"); };
  for (const url of ["http://scontent.cdninstagram.com/x", "https://cdninstagram.com.attacker.invalid/x",
    "https://attacker@x.cdninstagram.com/x", "https://x.cdninstagram.com:444/x", "https://127.0.0.1/x"]) {
    await assert.rejects(() => downloadInstagramCover(url, transport, publicDNS));
  }
  await assert.rejects(() => downloadInstagramCover("https://scontent.cdninstagram.com/x", transport,
    async () => [{ address: "127.0.0.1", family: 4 }]));
  assert.equal(fetched, false);
  await assert.rejects(() => downloadInstagramCover("https://scontent.fbcdn.net/x",
    async () => new Response(null, { status: 302, headers: { location: "http://127.0.0.1/" } }), publicDNS));
  await assert.rejects(() => downloadInstagramCover("https://scontent.fbcdn.net/x",
    async () => new Response("gif", { headers: { "content-type": "image/gif" } }), publicDNS));
  await assert.rejects(() => downloadInstagramCover("https://scontent.fbcdn.net/x",
    async () => new Response(Buffer.alloc(2_097_153), { headers: { "content-type": "image/jpeg" } }), publicDNS));
});
