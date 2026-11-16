import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { names, collectFixtures, encodeFrames, decodeFrames } from "./native-preview-transfer.mjs";

function images() {
  const png = Buffer.alloc(33);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(png);
  png.writeUInt32BE(13, 8);
  png.write("IHDR", 12);
  png.writeUInt32BE(1, 16);
  png.writeUInt32BE(1, 20);
  return new Map(names.map(name => [name, Buffer.from(png)]));
}

test("known fixtures round-trip through timestamp-prefixed logs with exact checksums", () => {
  const source = images();
  source.set(names[0], Buffer.concat([source.get(names[0]), Buffer.alloc(5000)]));
  const log = encodeFrames(source).map(line => `compile\tPreview transfer\t2026-11-15T00:00:00Z ${line}`).join("\n");
  const decoded = decodeFrames(log);
  for (const name of names) assert.deepEqual(decoded.get(name), source.get(name));
});

test("truncation, wrong lengths/hashes, reordered chunks and unexpected names fail closed", () => {
  const frames = encodeFrames(images());
  for (const log of [
    frames.slice(0, -1).join("\n"),
    frames.join("\n").replace("|33|", "|34|"),
    frames.join("\n").replace(/([a-f0-9]{64})/, "0".repeat(64)),
    frames.join("\n").replace("|0|", "|1|"),
    frames.join("\n").replaceAll(names[0], "arbitrary.png"),
    [...frames, frames[0]].join("\n"),
    frames.join("\n").replace("RBPREVIEW_END", "RBPREVIEW_UNKNOWN")
  ]) assert.throws(() => decodeFrames(log));
  assert.throws(() => encodeFrames(new Map([...images()].slice(1))));
  const invalid = images();
  invalid.get(names[0])[0] = 0;
  assert.throws(() => encodeFrames(invalid));
  const oversized = images();
  oversized.set(names[0], Buffer.alloc(512 * 1024 + 1));
  assert.throws(() => encodeFrames(oversized));
  const totalExceeded = images();
  for (const name of names) totalExceeded.set(name, Buffer.concat([totalExceeded.get(name), Buffer.alloc(300000)]));
  assert.throws(() => encodeFrames(totalExceeded));
});

test("export manifest permits only known passed capture attachments and ordinary bounded files", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "recipe-preview-transfer-test-"));
  try {
    const attachments = names.map((name, index) => {
      const exportedFileName = `fixture-${index}.png`;
      fs.writeFileSync(path.join(directory, exportedFileName), images().get(name));
      return { exportedFileName, suggestedHumanReadableName: name, isAssociatedWithFailure: false };
    });

    test("Plan-only capture has its own exact allowlist without weakening the four-screen profile or byte limits", () => {
      const name = "Fixture-preview-plan.png";
      const plan = new Map([[name, images().get(names[0])]]);
      const frames = encodeFrames(plan, "plan").join("\n");
      assert.deepEqual(decodeFrames(frames, "plan"), plan);
      assert.throws(() => decodeFrames(frames));
      assert.throws(() => encodeFrames(images(), "plan"));
      assert.throws(() => encodeFrames(plan, "arbitrary"));
      assert.throws(() => encodeFrames(new Map([[name, Buffer.alloc(512 * 1024 + 1)]]), "plan"));
      const directory = fs.mkdtempSync(path.join(os.tmpdir(), "recipe-plan-transfer-test-"));
      try {
        fs.writeFileSync(path.join(directory, "plan.png"), plan.get(name));
        const manifest = [{ testIdentifier: "PreviewCaptureTests/testCaptureDisclosedPlanScreen()", attachments: [{
          exportedFileName: "plan.png", suggestedHumanReadableName: name, isAssociatedWithFailure: false
        }] }];
        fs.writeFileSync(path.join(directory, "manifest.json"), JSON.stringify(manifest));
        assert.equal(collectFixtures(directory, "plan").size, 1);
        assert.throws(() => collectFixtures(directory));
        manifest[0].testIdentifier = "PreviewCaptureTests/testCaptureDisclosedFixtureScreens()";
        fs.writeFileSync(path.join(directory, "manifest.json"), JSON.stringify(manifest));
        assert.throws(() => collectFixtures(directory, "plan"));
      } finally { fs.rmSync(directory, { recursive: true }); }
    });
    const manifest = [{ testIdentifier: "PreviewCaptureTests/testCaptureDisclosedFixtureScreens()", attachments }];
    const writeManifest = () => fs.writeFileSync(path.join(directory, "manifest.json"), JSON.stringify(manifest));
    writeManifest();
    assert.equal(collectFixtures(directory).size, 4);
    fs.writeFileSync(path.join(directory, "unexpected.txt"), "not a screenshot");
    assert.throws(() => collectFixtures(directory));
    fs.unlinkSync(path.join(directory, "unexpected.txt"));
    attachments[0].suggestedHumanReadableName = "arbitrary.png";
    writeManifest();
    assert.throws(() => collectFixtures(directory));
    attachments[0].suggestedHumanReadableName = names[0];
    attachments[0].exportedFileName = "../outside.png";
    writeManifest();
    assert.throws(() => collectFixtures(directory));
    attachments[0].exportedFileName = "fixture-0.png";
    manifest[0].testIdentifier = "LaunchTests/otherTest()";
    writeManifest();
    assert.throws(() => collectFixtures(directory));
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
});
