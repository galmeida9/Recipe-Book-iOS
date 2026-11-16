import test from "node:test";
import assert from "node:assert/strict";
import jpeg from "jpeg-js";
import { randomUUID } from "node:crypto";
import sql from "mssql";
import { BlockBlobClient } from "@azure/storage-blob";
import { sanitizeCoverJPEG, uploadRecipeImage } from "../src/images.js";
import { RecipeBookService } from "../src/service.js";

test("cover upload decodes/re-encodes real bounded pixels and strips EXIF metadata", () => {
  const source = jpeg.encode({ width: 1, height: 1, data: Buffer.from([255, 0, 0, 255]), exifBuffer: Buffer.from("private-location-marker") }, 85).data;
  assert(source.includes(Buffer.from("private-location-marker")));
  const sanitized = sanitizeCoverJPEG(source);
  assert(!sanitized.includes(Buffer.from("private-location-marker")));
  const decoded = jpeg.decode(sanitized);
  assert.equal(decoded.width, 1);
  assert.equal(decoded.height, 1);
});
test("invalid JPEG payloads, misleading/truncated dimensions, oversized pixels and byte limits are rejected", () => {
  assert.throws(() => sanitizeCoverJPEG(Buffer.from("not jpeg")));
  const fake = Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0, 8, 8, 0, 1, 0, 1, 1, 0xff, 0xd9]);
  assert.throws(() => sanitizeCoverJPEG(fake), /decoded/);
  const oversized = jpeg.encode({ width: 1601, height: 1, data: Buffer.alloc(1601 * 4) }, 85).data;
  assert.throws(() => sanitizeCoverJPEG(oversized), /1600/);
  assert.throws(() => sanitizeCoverJPEG(Buffer.alloc(2_097_153)));
});
test("photo-upload retries preserve one reservation and image ID; changed account/pixels/deleted image fail before blob writes", async t => {
  const userId = randomUUID(), key = randomUUID();
  const service = new RecipeBookService({ issuer: "https://image-fixture.invalid", subject: "synthetic" });
  t.mock.method(service, "execute", async function<T>(work: (transaction: sql.Transaction, id: string) => Promise<T>) {
    return work(new sql.Transaction(), userId);
  });
  let stored: { imageId: string; hash: string } | null = null;
  let exists = true, reservations = 0, writes = 0;
  t.mock.method(sql.Request.prototype, "query", async function(this: sql.Request, text: string) {
    let rows: unknown[] = [];
    if (text.includes("ContentHash AS hash")) rows = stored ? [stored] : [];
    else if (text.includes("COUNT(*)")) rows = [{ count: stored ? 1 : 0 }];
    else if (text.includes("UPDATE dbo.Accounts")) { reservations++; rows = [{ id: userId }]; }
    else if (text.includes("INSERT dbo.ImageUploadRequests")) {
      stored = { imageId: String(this.parameters["id"]!.value), hash: String(this.parameters["hash"]!.value) };
    } else if (text.includes("SELECT Id FROM dbo.RecipeImages")) rows = exists ? [{ id: stored!.imageId }] : [];
    else if (!text.includes("INSERT dbo.RecipeImages")) throw new Error("Unexpected synthetic photo query");
    return { recordset: rows };
  });
  process.env["BLOB_SERVICE_URL"] = "https://syntheticimages.blob.core.windows.net";
  t.mock.method(BlockBlobClient.prototype, "uploadData", async function() { writes++; return { etag: "synthetic-only" }; });
  const body = (red: number) => ({ jpegBase64: jpeg.encode({ width: 1, height: 1, data: Buffer.from([red, 0, 0, 255]) }, 85).data.toString("base64") });
  await assert.rejects(() => uploadRecipeImage(service, body(255), key, randomUUID()), /account changed/);
  const first = await uploadRecipeImage(service, body(255), key, userId);
  const retry = await uploadRecipeImage(service, body(255), key, userId);
  assert.equal(first.id, retry.id);
  assert.equal(reservations, 1);
  assert.equal(writes, 2, "Repeated PUTs use the same authorized blob and identical pixels.");
  await assert.rejects(() => uploadRecipeImage(service, body(0), key, userId), /different pixels/);
  exists = false;
  await assert.rejects(() => uploadRecipeImage(service, body(255), key, userId), /deleted/);
  assert.equal(writes, 2);
  assert.equal(reservations, 1);
});
