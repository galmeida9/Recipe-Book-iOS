import test from "node:test";
import assert from "node:assert/strict";
import jpeg from "jpeg-js";
import { sanitizeCoverJPEG } from "../src/images.js";

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
