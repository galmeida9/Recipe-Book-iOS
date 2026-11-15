import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

export const names = ["sign-in", "library", "recipe-detail", "shopping"].map(screen => `Fixture-preview-${screen}.png`);
const allowed = new Set(names);
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const maxTotal = 1024 * 1024;
const maxImage = 512 * 1024;
const chunkLength = 3072;
const hash = data => createHash("sha256").update(data).digest("hex");
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };

function validateImages(images) {
  requireValue(images.size === 4 && [...images.keys()].every(name => allowed.has(name)), "Exactly four known fixture PNGs are required.");
  let total = 0;
  for (const [name, data] of images) {
    requireValue(data.length >= 33 && data.length <= maxImage, `Unexpected PNG size: ${name}`);
    requireValue(data.subarray(0, 8).equals(signature) && data.readUInt32BE(8) === 13 &&
      data.subarray(12, 16).toString("ascii") === "IHDR", `Invalid PNG header: ${name}`);
    requireValue(data.readUInt32BE(16) > 0 && data.readUInt32BE(16) <= 4096 &&
      data.readUInt32BE(20) > 0 && data.readUInt32BE(20) <= 4096, `Unexpected PNG dimensions: ${name}`);
    total += data.length;
  }
  requireValue(total <= maxTotal, "Fixture PNGs exceed the 1 MiB total bound.");
  return total;
}

export function collectFixtures(directory) {
  const files = fs.readdirSync(directory, { withFileTypes: true });
  requireValue(files.every(file => file.isFile()) && files.length === 5, "Only the manifest and four ordinary PNG files are permitted.");
  const manifestPath = path.join(directory, "manifest.json");
  requireValue(fs.statSync(manifestPath).size <= 65536, "Attachment manifest exceeds its bound.");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  requireValue(Array.isArray(manifest), "Unsupported attachment manifest.");
  const images = new Map();
  const exports = new Set(["manifest.json"]);
  for (const entry of manifest) {
    requireValue(Array.isArray(entry.attachments), "Missing manifest attachment list.");
    if (entry.attachments.length === 0) continue;
    const parts = String(entry.testIdentifier).split("/");
    requireValue(["PreviewCaptureTests", "RecipeBookUITests.PreviewCaptureTests"].includes(parts.at(-2)) &&
      ["testCaptureDisclosedFixtureScreens()", "testCaptureDisclosedFixtureScreens"].includes(parts.at(-1)),
      "Attachments from an unexpected test are refused.");
    for (const attachment of entry.attachments) {
      const suggested = attachment.suggestedHumanReadableName;
      const match = typeof suggested === "string" && suggested.length <= 256 &&
        /^(Fixture-preview-(?:sign-in|library|recipe-detail|shopping))(?:_[A-Za-z0-9_.-]+)?(?:\.png)?$/.exec(suggested);
      requireValue(match && attachment.isAssociatedWithFailure === false, `Unexpected fixture attachment: ${JSON.stringify(suggested)}`);
      const name = `${match[1]}.png`;
      const exported = attachment.exportedFileName;
      requireValue(typeof exported === "string" && /^[A-Za-z0-9_-]+\.png$/.test(exported) &&
        files.some(file => file.name === exported), "Unexpected exported PNG filename.");
      requireValue(!images.has(name) && !exports.has(exported), "Duplicate fixture screenshot.");
      requireValue(fs.statSync(path.join(directory, exported)).size <= maxImage, "Exported PNG exceeds its bound.");
      images.set(name, fs.readFileSync(path.join(directory, exported)));
      exports.add(exported);
    }
  }
  requireValue(exports.size === files.length && files.every(file => exports.has(file.name)), "Unexpected files in screenshot export.");
  validateImages(images);
  return images;
}

export function encodeFrames(images) {
  validateImages(images);
  const lines = [];
  for (const name of names) {
    const data = images.get(name);
    lines.push(`RBPREVIEW_BEGIN|${name}|${data.length}|${hash(data)}`);
    const encoded = data.toString("base64");
    let count = 0;
    for (let offset = 0; offset < encoded.length; offset += chunkLength) {
      lines.push(`RBPREVIEW_CHUNK|${name}|${count++}|${encoded.slice(offset, offset + chunkLength)}`);
    }
    lines.push(`RBPREVIEW_END|${name}|${count}`);
  }
  return lines;
}

export function decodeFrames(log) {
  const records = new Map();
  let total = 0;
  for (const line of log.split(/\r?\n/)) {
    const marker = line.indexOf("RBPREVIEW_");
    if (marker < 0) continue;
    const frame = line.slice(marker);
    requireValue(frame.length <= chunkLength + 200, "Screenshot log frame exceeds its bound.");
    const [type, name, value, payload, ...extra] = frame.split("|");
    requireValue(extra.length === 0 && allowed.has(name), "Unexpected screenshot log filename/frame.");
    if (type === "RBPREVIEW_BEGIN") {
      requireValue(!records.has(name) && /^[1-9][0-9]*$/.test(value) &&
        /^[0-9a-f]{64}$/.test(payload ?? ""), "Invalid or duplicate screenshot header.");
      const size = Number(value);
      total += size;
      requireValue(Number.isSafeInteger(size) && size <= maxImage && total <= maxTotal, "Screenshot log size exceeds its bound.");
      records.set(name, { size, digest: payload, chunks: [], complete: false, encodedLength: 0 });
    } else {
      const record = records.get(name);
      requireValue(record && !record.complete && /^(0|[1-9][0-9]*)$/.test(value), "Missing, repeated or invalid screenshot frame.");
      requireValue(Number(value) === record.chunks.length, "Screenshot chunks are missing or out of order.");
      if (type === "RBPREVIEW_CHUNK") {
        requireValue(typeof payload === "string" && payload.length > 0 && payload.length <= chunkLength &&
          /^[A-Za-z0-9+/=]+$/.test(payload), "Invalid screenshot base64 chunk.");
        record.encodedLength += payload.length;
        requireValue(record.encodedLength <= Math.ceil(record.size / 3) * 4, "Screenshot payload exceeds declared size.");
        record.chunks.push(payload);
      } else {
        requireValue(type === "RBPREVIEW_END" && payload === undefined && record.chunks.length > 0, "Unexpected screenshot trailer.");
        record.complete = true;
      }
    }
  }
  const images = new Map();
  for (const [name, record] of records) {
    requireValue(record.complete, `Screenshot log is truncated: ${name}`);
    const encoded = record.chunks.join("");
    const data = Buffer.from(encoded, "base64");
    requireValue(data.toString("base64") === encoded && data.length === record.size && hash(data) === record.digest,
      `Screenshot integrity verification failed: ${name}`);
    images.set(name, data);
  }
  validateImages(images);
  return images;
}

function main() {
  const [command, input, output] = process.argv.slice(2);
  requireValue(input && ((command === "decode" && output && process.argv.length === 5) ||
    (["check", "emit"].includes(command) && process.argv.length === 4)), "Use check/emit <export-directory>, or decode <run-log> <empty-output-directory>.");
  if (command !== "decode") {
    const images = collectFixtures(input);
    if (command === "emit") for (const line of encodeFrames(images)) console.log(line);
    else console.log(`Verified fixture PNGs: ${images.size}; total bytes: ${validateImages(images)}`);
    return;
  }
  requireValue(fs.statSync(input).size <= 32 * 1024 * 1024, "Run log exceeds the 32 MiB decoder bound.");
  const images = decodeFrames(fs.readFileSync(input, "utf8"));
  fs.mkdirSync(output, { recursive: true });
  requireValue(fs.readdirSync(output).length === 0, "Output directory must be empty; existing files will not be overwritten.");
  for (const name of names) {
    const data = images.get(name);
    fs.writeFileSync(path.join(output, name), data, { flag: "wx" });
    console.log(`${name}: ${data.length} bytes; SHA256 ${hash(data)}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main();
