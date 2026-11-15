import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";
import path from "node:path";

const require = createRequire(import.meta.url);
interface ProjectNode {
  isa: string;
  name?: string;
  productType?: string;
  productName?: string;
  productReference?: string;
  target?: string;
  fileRef?: string;
  dstSubfolderSpec?: string;
  dependencies?: string[];
  files?: string[];
}
interface ParsedProject {
  parseSync(): void;
  hash: { project: { objects: Record<string, ProjectNode> } };
}
const xcode = require("xcode") as { project(file: string): ParsedProject };
const projectPath = fileURLToPath(new URL("../../ios/RecipeBook.xcodeproj/project.pbxproj", import.meta.url));
test("checked-in Xcode artifact parses and explicitly embeds the native share extension", () => {
  const project = xcode.project(projectPath);
  project.parseSync();
  const objects = project.hash.project.objects;
  const targets = Object.values(objects).filter(value => value.isa === "PBXNativeTarget");
  assert.equal(targets.length, 2);
  const app = targets.find(target => target.name === "RecipeBook");
  const share = targets.find(target => target.name === "RecipeBookShare");
  assert.ok(app && share);
  assert.equal(share.productType, '"com.apple.product-type.app-extension"');
  assert.ok(app.dependencies?.some(dependency => objects[dependency]?.target === "A50000000000000000000002"));
  const embed = objects["A40000000000000000000003"]!;
  assert.equal(Number(embed.dstSubfolderSpec), 13);
  assert.ok(embed.files?.[0]);
  assert.equal(objects[embed.files[0]]!.fileRef, share.productReference);
  const packages = Object.values(objects).filter(value => value.isa === "XCSwiftPackageProductDependency");
  assert.ok(packages.some(value => value.productName === "RecipeBookAuth"));
  assert.ok(packages.some(value => value.productName === "RecipeBookUI"));
  const root = path.resolve(path.dirname(projectPath), "..");
  for (const file of ["RecipeBook/RecipeBookApp.swift", "RecipeBook/UIServiceAdapter.swift", "RecipeBook/AppConfiguration.swift", "RecipeBookShare/ShareViewController.swift", "RecipeBook/Info.plist", "RecipeBookShare/Info.plist", "RecipeBookUI/Package.swift"]) {
    assert.ok(existsSync(path.join(root, file)), `Missing project input ${file}`);
  }
});
